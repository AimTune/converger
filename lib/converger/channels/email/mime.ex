defmodule Converger.Channels.Email.Mime do
  @moduledoc """
  Parses a raw RFC 5322 / MIME message (with the `mail` library) into the
  normalized email map the `email` channel adapter works with, see
  `t:email/0`.

  A delivery status notification (`multipart/report;
  report-type=delivery-status`, the bounce an SMTP server sends back) is
  recognised: its `:report` carries the `Message-ID` of the message that
  bounced and the failure reason.
  """

  alias Converger.Channels.Email.Address

  @typedoc """
  A normalized inbound email:

    * `:message_id` - `Message-ID` without angle brackets (may be nil)
    * `:in_reply_to`, `:references` - normalized message ids
    * `:from`, `:from_name` - normalized sender address and display name
    * `:to`, `:cc` - normalized addresses
    * `:subject`, `:text`, `:html` - decoded content (may be nil)
    * `:stripped_text` - the reply without quotes, when the provider already
      computed it (Mailgun `stripped-text`, Postmark `StrippedTextReply`)
    * `:attachments` - `[{filename, binary | %Plug.Upload{}}]`
    * `:auto_submitted` - an auto-reply (`Auto-Submitted` other than `no`)
    * `:report` - `%{original_message_id, reason}` for a bounce report
  """
  @type email :: %{
          message_id: String.t() | nil,
          in_reply_to: [String.t()],
          references: [String.t()],
          from: String.t() | nil,
          from_name: String.t() | nil,
          to: [String.t()],
          cc: [String.t()],
          subject: String.t() | nil,
          text: String.t() | nil,
          html: String.t() | nil,
          stripped_text: String.t() | nil,
          attachments: [{String.t(), binary() | Plug.Upload.t()}],
          auto_submitted: boolean(),
          report: %{original_message_id: String.t() | nil, reason: String.t()} | nil
        }

  @doc "An email map with every field empty."
  def empty do
    %{
      message_id: nil,
      in_reply_to: [],
      references: [],
      from: nil,
      from_name: nil,
      to: [],
      cc: [],
      subject: nil,
      text: nil,
      html: nil,
      stripped_text: nil,
      attachments: [],
      auto_submitted: false,
      report: nil
    }
  end

  @doc "Parse a raw message. `{:error, :invalid_mime}` when it cannot be parsed."
  @spec parse(binary()) :: {:ok, email()} | {:error, :invalid_mime}
  def parse(raw) when is_binary(raw) and raw != "" do
    message = raw |> crlf() |> Mail.parse()
    {:ok, from_message(message)}
  rescue
    _ -> {:error, :invalid_mime}
  end

  def parse(_), do: {:error, :invalid_mime}

  @doc """
  Parse a raw header block (as sent by SendGrid Inbound Parse in `headers`)
  into the header fields of an email map.
  """
  @spec parse_headers(binary() | nil) :: email()
  def parse_headers(headers) when is_binary(headers) and headers != "" do
    headers
    |> crlf()
    |> String.trim_trailing()
    |> Kernel.<>("\r\n\r\n")
    |> Mail.parse()
    |> header_fields()
  rescue
    _ -> empty()
  end

  def parse_headers(_), do: empty()

  # The parser splits lines on CRLF; mail stored or posted with bare LF
  # (SendGrid's `headers` field, files saved on Unix) is converted.
  defp crlf(text), do: String.replace(text, ~r/\r?\n/, "\r\n")

  @doc """
  The header fields of an email map from a list of `{name, value}` pairs
  (Mailgun `message-headers`, Postmark `Headers`). Names are matched
  case-insensitively.
  """
  @spec from_header_pairs([{String.t(), String.t()}]) :: email()
  def from_header_pairs(pairs) do
    headers =
      for {name, value} <- pairs, is_binary(name), is_binary(value), into: %{} do
        {String.downcase(name), value}
      end

    header_fields(%{headers: headers})
  end

  defp from_message(%Mail.Message{} = message) do
    email = header_fields(message)

    email
    |> Map.merge(%{
      text: text_body(message),
      html: html_body(message),
      attachments: attachments(message)
    })
    |> Map.put(:report, report(message))
  end

  defp header_fields(%{headers: headers}) do
    {from_name, from} = Address.parse(headers["from"]) || {nil, nil}

    %{
      empty()
      | message_id: headers |> header("message-id") |> Address.normalize_id(),
        in_reply_to: Address.ids(header(headers, "in-reply-to")),
        references: Address.ids(header(headers, "references")),
        from: from,
        from_name: from_name,
        to: Address.addresses(headers["to"]),
        cc: Address.addresses(headers["cc"]),
        subject: header(headers, "subject"),
        auto_submitted: auto_submitted?(header(headers, "auto-submitted"))
    }
  end

  defp header(headers, key) do
    case headers[key] do
      value when is_binary(value) -> value
      [value | _] when is_binary(value) -> value
      _ -> nil
    end
  end

  defp auto_submitted?(nil), do: false
  defp auto_submitted?(value), do: String.downcase(String.trim(value)) != "no"

  defp text_body(message) do
    case Mail.get_text(message) do
      %Mail.Message{body: body} when is_binary(body) ->
        body

      _ ->
        # A single-part message without Content-Type is text/plain.
        if not message.multipart and is_binary(message.body) and
             content_type(message) in [nil, "text/plain"],
           do: message.body
    end
  end

  defp html_body(message) do
    case Mail.get_html(message) do
      %Mail.Message{body: body} when is_binary(body) -> body
      _ -> nil
    end
  end

  defp attachments(message) do
    message
    |> Mail.get_attachments()
    |> Enum.filter(fn {name, data} -> is_binary(name) and is_binary(data) end)
  rescue
    _ -> []
  end

  defp content_type(%Mail.Message{headers: headers}) do
    case headers["content-type"] do
      [type | _] when is_binary(type) -> String.downcase(type)
      type when is_binary(type) -> String.downcase(type)
      _ -> nil
    end
  end

  defp report(%Mail.Message{multipart: true} = message) do
    if content_type(message) == "multipart/report" do
      parts = flatten(message)

      status = Enum.find(parts, &(content_type(&1) == "message/delivery-status"))

      original =
        Enum.find(parts, &(content_type(&1) in ["text/rfc822-headers", "message/rfc822"]))

      %{
        original_message_id: original_message_id(original),
        reason: report_reason(status)
      }
    end
  end

  defp report(_message), do: nil

  defp flatten(%Mail.Message{parts: parts}) when is_list(parts),
    do: Enum.flat_map(parts, fn part -> [part | flatten(part)] end)

  defp flatten(_), do: []

  defp original_message_id(nil), do: nil

  defp original_message_id(%Mail.Message{body: body} = part) do
    headers =
      case body do
        %Mail.Message{headers: headers} ->
          headers

        body when is_binary(body) ->
          case parse_headers(body) do
            %{message_id: id} when is_binary(id) -> %{"message-id" => id}
            _ -> %{}
          end

        _ ->
          part.headers
      end

    headers |> header("message-id") |> Address.normalize_id()
  end

  defp report_reason(%Mail.Message{body: body}) when is_binary(body) do
    fields =
      for line <- String.split(body, ~r/\r?\n/),
          [name, value] <- [String.split(line, ":", parts: 2)],
          into: %{} do
        {String.downcase(String.trim(name)), String.trim(value)}
      end

    ["bounce", fields["status"], fields["diagnostic-code"] || fields["action"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(": ")
  end

  defp report_reason(_), do: "bounce"
end
