defmodule Converger.Channels.Email.Providers do
  @moduledoc """
  Inbound payloads of the email providers, normalized:

    * `emails/2` - the inbound emails of a request, as
      `Converger.Channels.Email.Mime.t:email/0` maps
    * `events/2` - the delivery events of a request (delivered, opened,
      bounced, complained), as status update maps for
      `Converger.Deliveries.apply_status_update/2`

  | provider   | inbound mail                                 | events                       |
  | ---------- | -------------------------------------------- | ---------------------------- |
  | `ses`      | SNS notification, `notificationType: Received` (SNS receipt action) | SNS `Bounce`, `Complaint`, `Delivery` |
  | `sendgrid` | Inbound Parse (multipart; raw `email` or parsed fields) | Event Webhook (JSON array) |
  | `mailgun`  | Routes `forward()` / `store()` (form fields or `body-mime`) | Webhooks (`event-data`) |
  | `postmark` | Inbound webhook (JSON)                       | Delivery / Bounce / SpamComplaint / Open webhooks |
  | `rfc822`   | raw `message/rfc822` request body            | delivery status notifications (bounce mails) |

  A bounce report received as an email (any provider) is an event, not a
  message.
  """

  alias Converger.Channels.Email.{Address, Mime, SNS}

  @providers ~w(ses sendgrid mailgun postmark rfc822)

  @doc "The inbound providers."
  def providers, do: @providers

  ## Inbound mail

  @doc """
  The inbound emails of a request. `{:ok, []}` for a well-formed request
  without mail (an event, a subscription confirmation).
  """
  @spec emails(String.t(), map()) :: {:ok, [Mime.email()]} | {:error, term()}
  def emails("ses", params) do
    with {:ok, envelope} <- SNS.envelope(params) do
      case ses_notification(envelope) do
        {:ok, %{"notificationType" => "Received"} = notification} -> ses_received(notification)
        {:ok, _other} -> {:ok, []}
        :not_notification -> {:ok, []}
        {:error, _} = error -> error
      end
    end
  end

  def emails("sendgrid", params) do
    cond do
      is_list(params["_json"]) ->
        {:ok, []}

      raw = raw_field(params["email"]) ->
        raw_email(raw)

      is_binary(params["headers"]) or is_binary(params["from"]) ->
        {:ok, [sendgrid_fields(params)]}

      true ->
        {:error, "unable to parse SendGrid Inbound Parse payload"}
    end
  end

  def emails("mailgun", params) do
    cond do
      is_map(params["event-data"]) ->
        {:ok, []}

      raw = raw_field(params["body-mime"]) ->
        raw_email(raw)

      is_binary(params["body-plain"]) or is_binary(params["from"]) ->
        {:ok, [mailgun_fields(params)]}

      true ->
        {:error, "unable to parse Mailgun route payload"}
    end
  end

  def emails("postmark", params) do
    cond do
      is_binary(params["RecordType"]) and params["RecordType"] != "Inbound" -> {:ok, []}
      raw = raw_field(params["RawEmail"]) -> raw_email(raw)
      is_binary(params["From"]) or is_map(params["FromFull"]) -> {:ok, [postmark_fields(params)]}
      true -> {:error, "unable to parse Postmark inbound payload"}
    end
  end

  def emails("rfc822", params) do
    case raw_field(params["_body"]) || raw_field(params["raw"]) || raw_field(params["email"]) do
      nil -> {:error, "expected a message/rfc822 request body"}
      raw -> raw_email(raw)
    end
  end

  def emails(provider, _params),
    do: {:error, "unknown email inbound provider: #{inspect(provider)}"}

  defp raw_email(raw) do
    case Mime.parse(raw) do
      {:ok, %{report: nil} = email} -> {:ok, [email]}
      {:ok, _report} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  # A form field holding a whole message: a string, or an uploaded file
  # (SendGrid / Mailgun send large ones as files).
  # sobelow_skip ["Traversal.FileModule"]
  defp raw_field(%Plug.Upload{path: path}) do
    case File.read(path) do
      {:ok, raw} when raw != "" -> raw
      _ -> nil
    end
  end

  defp raw_field(raw) when is_binary(raw) and raw != "", do: raw
  defp raw_field(_), do: nil

  defp ses_notification(%{"Type" => "Notification", "Message" => message})
       when is_binary(message) do
    case Jason.decode(message) do
      {:ok, %{} = notification} -> {:ok, notification}
      _ -> {:error, :invalid_payload}
    end
  end

  defp ses_notification(_envelope), do: :not_notification

  # The SNS receipt rule action embeds the message (up to 150 KB) in
  # `content`, UTF-8 or Base64 encoded. An S3 action does not: those
  # notifications carry no content and are skipped.
  defp ses_received(%{"content" => content} = notification) when is_binary(content) do
    raw =
      case get_in(notification, ["receipt", "action", "encoding"]) do
        "BASE64" -> Base.decode64(content, ignore: :whitespace)
        _ -> {:ok, content}
      end

    case raw do
      {:ok, raw} -> raw_email(raw)
      :error -> {:error, :invalid_payload}
    end
  end

  defp ses_received(_notification),
    do: {:error, "SES notification has no content: use an SNS receipt rule action"}

  defp sendgrid_fields(params) do
    headers = Mime.parse_headers(params["headers"])
    {from_name, from} = Address.parse(params["from"]) || {headers.from_name, headers.from}

    %{
      headers
      | from: from,
        from_name: from_name,
        to: present_list(Address.addresses(params["to"]), headers.to),
        cc: present_list(Address.addresses(params["cc"]), headers.cc),
        subject: params["subject"] || headers.subject,
        text: params["text"],
        html: params["html"],
        attachments: uploads(params, ~r/\Aattachment\d+\z/)
    }
  end

  defp mailgun_fields(params) do
    headers = mailgun_headers(params["message-headers"])

    {from_name, from} = Address.parse(params["from"]) || {headers.from_name, headers.from}

    %{
      headers
      | message_id: Address.normalize_id(params["Message-Id"]) || headers.message_id,
        in_reply_to: present_list(Address.ids(params["In-Reply-To"]), headers.in_reply_to),
        references: present_list(Address.ids(params["References"]), headers.references),
        from: from,
        from_name: from_name,
        to: present_list(Address.addresses(params["To"] || params["recipient"]), headers.to),
        cc: present_list(Address.addresses(params["Cc"]), headers.cc),
        subject: params["subject"] || headers.subject,
        text: params["body-plain"],
        html: params["body-html"],
        stripped_text: params["stripped-text"],
        attachments: uploads(params, ~r/\Aattachment-\d+\z/)
    }
  end

  defp mailgun_headers(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, pairs} when is_list(pairs) -> Mime.from_header_pairs(for [k, v] <- pairs, do: {k, v})
      _ -> Mime.empty()
    end
  end

  defp mailgun_headers(_json), do: Mime.empty()

  defp postmark_fields(params) do
    pairs =
      for %{"Name" => name, "Value" => value} <- List.wrap(params["Headers"]), do: {name, value}

    headers = Mime.from_header_pairs(pairs)

    {from_name, from} =
      case params["FromFull"] do
        %{"Email" => email} = full -> Address.parse({full["Name"], email}) || {nil, nil}
        _ -> Address.parse(params["From"]) || {nil, nil}
      end

    %{
      headers
      | message_id: headers.message_id || Address.normalize_id(params["MessageID"]),
        from: from,
        from_name: from_name,
        to: full_addresses(params["ToFull"], params["To"]),
        cc: full_addresses(params["CcFull"], params["Cc"]),
        subject: params["Subject"],
        text: params["TextBody"],
        html: params["HtmlBody"],
        stripped_text: blank_to_nil(params["StrippedTextReply"]),
        attachments: postmark_attachments(params["Attachments"])
    }
  end

  defp full_addresses(full, fallback) when is_list(full) do
    case for(%{"Email" => email} <- full, address = Address.address(email), do: address) do
      [] -> Address.addresses(fallback)
      addresses -> addresses
    end
  end

  defp full_addresses(_full, fallback), do: Address.addresses(fallback)

  defp postmark_attachments(attachments) when is_list(attachments) do
    for %{"Name" => name, "Content" => content} <- attachments,
        is_binary(content),
        {:ok, data} <- [Base.decode64(content, ignore: :whitespace)],
        do: {name, data}
  end

  defp postmark_attachments(_), do: []

  defp uploads(params, pattern) do
    params
    |> Enum.filter(fn {key, value} ->
      Regex.match?(pattern, key) and match?(%Plug.Upload{}, value)
    end)
    |> Enum.sort_by(fn {key, _} -> key |> String.replace(~r/\D/, "") |> String.to_integer() end)
    |> Enum.map(fn {_key, upload} -> {upload.filename, upload} end)
  end

  defp present_list([], fallback), do: fallback
  defp present_list(list, _fallback), do: list

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  ## Events

  @doc """
  The delivery events of a request as status updates (`"provider_message_id"`,
  `"status"`, `"timestamp"`, `"error"`). Bounces and complaints are
  `"failed"` with the reason in `"error"`. Unknown events are skipped.
  """
  @spec events(String.t(), map()) :: [map()]
  def events("ses", params) do
    with {:ok, envelope} <- SNS.envelope(params),
         {:ok, notification} <- ses_notification(envelope) do
      ses_event(notification)
    else
      _ -> []
    end
  end

  def events("sendgrid", %{"_json" => events}) when is_list(events),
    do: events |> Enum.filter(&is_map/1) |> Enum.flat_map(&sendgrid_event/1)

  def events("mailgun", %{"event-data" => data}) when is_map(data), do: mailgun_event(data)

  def events("postmark", %{"RecordType" => type} = params) when type != "Inbound",
    do: postmark_event(type, params)

  def events(provider, params) when provider in @providers do
    # A bounce report delivered as an email, by any provider.
    case raw_report(provider, params) do
      %{original_message_id: id, reason: reason} when is_binary(id) ->
        [%{"provider_message_id" => id, "status" => "failed", "error" => reason}]

      _ ->
        []
    end
  end

  def events(_provider, _params), do: []

  defp raw_report("ses", _params), do: nil

  defp raw_report(provider, params) do
    raw =
      case provider do
        "sendgrid" ->
          raw_field(params["email"])

        "mailgun" ->
          raw_field(params["body-mime"])

        "postmark" ->
          raw_field(params["RawEmail"])

        "rfc822" ->
          raw_field(params["_body"]) || raw_field(params["raw"]) || raw_field(params["email"])
      end

    with raw when is_binary(raw) <- raw,
         {:ok, %{report: report}} <- Mime.parse(raw) do
      report
    else
      _ -> nil
    end
  end

  defp ses_event(%{"notificationType" => "Bounce", "bounce" => bounce} = n) do
    reason = reason(["bounce", bounce["bounceType"], bounce["bounceSubType"], diagnostic(bounce)])
    ses_update(n, "failed", reason, bounce["timestamp"])
  end

  defp ses_event(%{"notificationType" => "Complaint", "complaint" => complaint} = n),
    do:
      ses_update(
        n,
        "failed",
        reason(["complaint", complaint["complaintFeedbackType"]]),
        complaint["timestamp"]
      )

  defp ses_event(%{"notificationType" => "Delivery"} = n),
    do: ses_update(n, "delivered", nil, get_in(n, ["delivery", "timestamp"]))

  defp ses_event(_notification), do: []

  defp diagnostic(%{"bouncedRecipients" => [%{} = recipient | _]}),
    do: recipient["diagnosticCode"]

  defp diagnostic(_bounce), do: nil

  defp ses_update(notification, status, error, timestamp),
    do: update(get_in(notification, ["mail", "messageId"]), status, error, timestamp)

  @sendgrid_statuses %{
    "delivered" => "delivered",
    "open" => "read",
    "bounce" => "failed",
    "dropped" => "failed",
    "spamreport" => "failed"
  }

  defp sendgrid_event(%{"event" => event} = e) do
    # sg_message_id is "<X-Message-Id>.filter...": the delivery stores the
    # X-Message-Id returned when the mail was sent.
    id = if is_binary(e["sg_message_id"]), do: e["sg_message_id"] |> String.split(".") |> hd()
    status = @sendgrid_statuses[event]

    reason =
      if status == "failed" do
        kind = if event == "spamreport", do: "complaint", else: e["type"] || event
        reason([kind, e["reason"] || e["response"]])
      end

    update(id, status, reason, e["timestamp"])
  end

  defp sendgrid_event(_event), do: []

  defp mailgun_event(data) do
    id = data |> get_in(["message", "headers", "message-id"]) |> Address.normalize_id()

    {status, kind} =
      case {data["event"], data["severity"]} do
        {"delivered", _} -> {"delivered", nil}
        {"opened", _} -> {"read", nil}
        # Temporary failures are retried by Mailgun; only the final one counts.
        {"failed", "permanent"} -> {"failed", "bounce"}
        {"complained", _} -> {"failed", "complaint"}
        _ -> {nil, nil}
      end

    reason = kind && reason([kind, mailgun_detail(data)])
    update(id, status, reason, unix(data["timestamp"]))
  end

  defp mailgun_detail(data) do
    blank_to_nil(get_in(data, ["delivery-status", "description"])) ||
      blank_to_nil(get_in(data, ["delivery-status", "message"])) || data["reason"]
  end

  defp postmark_event(type, params) do
    {status, reason, timestamp} =
      case type do
        "Delivery" ->
          {"delivered", nil, params["DeliveredAt"]}

        "Open" ->
          {"read", nil, params["ReceivedAt"]}

        "Bounce" ->
          detail = blank_to_nil(params["Description"]) || params["Details"]
          {"failed", reason(["bounce", params["Type"], detail]), params["BouncedAt"]}

        "SpamComplaint" ->
          {"failed", "complaint", params["BouncedAt"]}

        _ ->
          {nil, nil, nil}
      end

    update(params["MessageID"], status, reason, timestamp)
  end

  # One status update, or none without an id or a status.
  defp update(id, status, error, timestamp)
       when is_binary(id) and id != "" and is_binary(status) do
    [
      reject_nil(%{
        "provider_message_id" => id,
        "status" => status,
        "error" => error,
        "timestamp" => timestamp
      })
    ]
  end

  defp update(_id, _status, _error, _timestamp), do: []

  defp reason(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(": ")

  defp unix(ts) when is_float(ts), do: trunc(ts)
  defp unix(ts), do: ts

  defp reject_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
