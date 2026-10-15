defmodule Converger.Channels.Adapters.SmsTwilio do
  @moduledoc """
  SMS / MMS through Twilio Programmable Messaging.

    * Outbound: `POST /2010-04-01/Accounts/<sid>/Messages.json` (form
      encoded, basic auth with the account SID and auth token), from `from`
      or through `messaging_service_sid`. Attachments with an absolute
      `contentUrl` are sent as MMS media (`MediaUrl`, at most 10). Every
      message asks Twilio for status callbacks to the channel's `/status`
      URL.
    * Inbound: Twilio's form-encoded messaging webhook. MMS media become
      attachments; `NumSegments` is kept as `channelData.sms_segments`.
    * Receipts: status callbacks (`sent`, `delivered`, `undelivered`,
      `failed`, `read`) advance the delivery.
    * Signatures: `X-Twilio-Signature`, see `verify_inbound_signature/3`.
    * Opt-out: Twilio's `OptOutType` (Advanced Opt-Out) or the keywords of
      `Converger.Channels.Sms`.
  """
  use Converger.Channels.Adapter, type: "sms_twilio"

  alias Converger.Channels.{DeliveryError, InboundSignature, Sms}
  alias Converger.Participants
  alias Converger.Pipeline.RetryPolicy

  @api_base "https://api.twilio.com"
  @max_media 10
  # Twilio error 21610: the recipient replied STOP to this sender.
  @unsubscribed_recipient 21_610

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :receipts,
      :provider_ack,
      :media,
      activity_types: ~w(message)
    ]
  end

  @impl true
  def config_schema do
    [
      %{
        name: "account_sid",
        type: :string,
        required: true,
        label: "Account SID",
        placeholder: "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        summary: true
      },
      %{
        name: "auth_token",
        type: :string,
        required: true,
        secret: true,
        label: "Auth Token",
        placeholder: "Signs X-Twilio-Signature"
      },
      %{
        name: "from",
        type: :string,
        label: "From",
        placeholder: "+15017122661 (or set a Messaging Service SID)",
        summary: true
      },
      %{
        name: "messaging_service_sid",
        type: :string,
        label: "Messaging Service SID",
        placeholder: "MGxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      },
      %{
        name: "webhook_base_url",
        type: :url,
        label: "Public base URL",
        placeholder: "https://converger.example.com",
        help:
          "The base URL Twilio calls, when it differs from the server's own URL (signatures cover the full URL)"
      },
      %{
        name: "default_country_code",
        type: :string,
        label: "Default country code",
        placeholder: "e.g. 1 or 90, for national numbers"
      },
      %{
        name: "max_segments",
        type: :integer,
        label: "Max segments",
        placeholder: "#{Sms.default_max_segments()}"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    cond do
      not String.starts_with?(config["account_sid"] || "", "AC") ->
        {:error, "sms_twilio config account_sid must start with AC"}

      blank?(config["from"]) and blank?(config["messaging_service_sid"]) ->
        {:error, "sms_twilio config needs from or messaging_service_sid"}

      true ->
        :ok
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  @impl true
  def deliver_activity(channel, activity) do
    config = channel.config || %{}
    media = media_urls(activity.attachments)
    text = activity.text || ""

    with {:ok, to} <- Sms.recipient(channel, activity),
         :ok <- check_not_opted_out(channel, to),
         :ok <- check_content(text, media),
         {:ok, segments} <- check_length(channel, text) do
      form =
        [{"To", to}, {"Body", text}]
        |> Kernel.++(sender(config))
        |> Kernel.++(status_callback(channel))
        |> Kernel.++(Enum.map(media, &{"MediaUrl", &1}))

      case Req.post(api_url(config, "/Messages.json"), request_options(channel, form: form)) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          sid = body["sid"]

          {:ok,
           Sms.reject_nil_values(%{
             provider_message_id: sid,
             twilio_message_sid: sid,
             sms_segments: integer(body["num_segments"]) || segments
           })}

        {:ok, %Req.Response{status: 400, body: %{"code" => @unsubscribed_recipient}}} ->
          # Twilio already blocks the number: keep Converger in line with it.
          _ = Participants.set_opted_out(channel, to, true)

          {:error,
           DeliveryError.permanent(
             "recipient #{to} opted out (Twilio error #{@unsubscribed_recipient})"
           )}

        {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
          {:error, DeliveryError.from_http(status, headers, body, "Twilio API")}

        {:error, reason} ->
          {:error, DeliveryError.from_transport(reason, "Twilio API")}
      end
    end
  end

  # The pipeline checks the participant before calling the adapter; this
  # also covers an explicit `to` written differently from the stored E.164.
  defp check_not_opted_out(channel, to) do
    if Participants.opted_out?(Map.get(channel, :id), to),
      do: {:error, DeliveryError.permanent("recipient #{to} opted out")},
      else: :ok
  end

  defp check_content(text, media) do
    if String.trim(text) == "" and media == [],
      do: {:error, DeliveryError.permanent("nothing to send: no text and no media URL")},
      else: :ok
  end

  defp check_length(channel, text) do
    case Sms.check_length(channel, text) do
      {:ok, segments} -> {:ok, segments}
      {:error, message} -> {:error, DeliveryError.permanent(message)}
    end
  end

  defp sender(config) do
    if blank?(config["messaging_service_sid"]),
      do: [{"From", config["from"]}],
      else: [{"MessagingServiceSid", config["messaging_service_sid"]}]
  end

  defp status_callback(%{id: id} = channel) when is_binary(id),
    do: [{"StatusCallback", channel_url(channel, "status")}]

  defp status_callback(_channel), do: []

  # Twilio fetches media itself: only absolute http(s) URLs can be sent.
  defp media_urls(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&(is_map(&1) && &1["contentUrl"]))
    |> Enum.filter(&absolute_url?/1)
    |> Enum.take(@max_media)
  end

  defp media_urls(_attachments), do: []

  defp absolute_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp absolute_url?(_url), do: false

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer(_value), do: nil

  defp api_url(config, path),
    do: "#{@api_base}/2010-04-01/Accounts/#{config["account_sid"]}#{path}"

  defp request_options(channel, options) do
    config = channel.config || %{}

    [
      auth: {:basic, "#{config["account_sid"]}:#{config["auth_token"]}"},
      receive_timeout: RetryPolicy.for_channel(channel).timeout_ms
    ]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:converger, :sms_req_options, []))
  end

  @doc """
  The public URL of the channel's `inbound` or `status` endpoint, built on
  the channel's `webhook_base_url` or the server URL.
  """
  def channel_url(channel, endpoint) when endpoint in ["inbound", "status"] do
    "#{public_base_url(channel)}/api/v1/channels/#{channel.id}/#{endpoint}"
  end

  defp public_base_url(channel) do
    case (channel.config || %{})["webhook_base_url"] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> ConvergerWeb.Endpoint.url()
    end
  end

  @doc """
  Verifies `X-Twilio-Signature`: the Base64 HMAC-SHA1, keyed with the auth
  token, of the full request URL followed by every POST parameter (sorted by
  name) as name and value concatenated.

  The request URL is not known to adapters; the signature is checked against
  the channel's `inbound` and `status` URLs on the channel's
  `webhook_base_url`, the server URL (`PHX_HOST`) and the request's `Host`
  (`X-Forwarded-Proto` or `https`). Only someone holding the auth token can
  produce a match for any of them.

  Returns `:missing` without the header or without an `auth_token`.
  """
  @impl true
  def verify_inbound_signature(channel, headers, raw_body) do
    auth_token = (channel.config || %{})["auth_token"]

    case InboundSignature.get_header(headers, "x-twilio-signature") do
      nil ->
        :missing

      _signature when not is_binary(auth_token) or auth_token == "" ->
        :missing

      signature ->
        params =
          (raw_body || "")
          |> URI.query_decoder()
          |> Enum.sort()
          |> Enum.map_join(fn {name, value} -> name <> value end)

        valid? =
          channel
          |> candidate_urls(headers)
          |> Enum.any?(fn url ->
            expected = Base.encode64(:crypto.mac(:hmac, :sha, auth_token, url <> params))
            Plug.Crypto.secure_compare(expected, signature)
          end)

        if valid?, do: :ok, else: {:error, :invalid_signature}
    end
  end

  defp candidate_urls(channel, headers) do
    host_base =
      case InboundSignature.get_header(headers, "host") do
        nil ->
          []

        host ->
          scheme = InboundSignature.get_header(headers, "x-forwarded-proto") || "https"
          ["#{scheme}://#{host}"]
      end

    bases = Enum.uniq([public_base_url(channel), ConvergerWeb.Endpoint.url() | host_base])

    for base <- bases,
        endpoint <- ["inbound", "status"],
        do: "#{base}/api/v1/channels/#{channel.id}/#{endpoint}"
  end

  @doc """
  Parses Twilio's messaging webhook: one message per request. A status
  callback (a `MessageStatus` other than `received`) carries no message and
  parses to `{:ok, []}`.
  """
  @impl true
  def parse_inbound(channel, %{"MessageSid" => sid, "From" => from} = params)
      when is_binary(sid) and is_binary(from) do
    if status_callback?(params) do
      {:ok, []}
    else
      {:ok, [parse_message(channel, params)]}
    end
  end

  def parse_inbound(_channel, _params), do: {:error, "unable to parse Twilio webhook payload"}

  defp status_callback?(params),
    do: (params["MessageStatus"] || "received") != "received"

  defp parse_message(channel, params) do
    config = channel.config || %{}
    sender = Sms.participant_id(params["From"], config["default_country_code"])

    metadata =
      Sms.reject_nil_values(%{
        "twilio_message_sid" => params["MessageSid"],
        "to" => params["To"],
        "sms_segments" => integer(params["NumSegments"]),
        "from_country" => params["FromCountry"],
        "messaging_service_sid" => params["MessagingServiceSid"]
      })

    %{
      "sender" => sender,
      "type" => "message",
      "text" => params["Body"] || "",
      "attachments" => media_attachments(params),
      "metadata" => metadata,
      "idempotency_key" => params["MessageSid"],
      "participant" => %{"external_id" => sender}
    }
    |> Sms.apply_opt_keyword(opt_out_type(params["OptOutType"]))
  end

  # Twilio's Advanced Opt-Out classifies the keyword itself (custom keywords
  # included); HELP is answered by Twilio and stays a message.
  defp opt_out_type("STOP"), do: :opt_out
  defp opt_out_type("START"), do: :opt_in
  defp opt_out_type(_), do: nil

  defp media_attachments(params) do
    count = min(integer(params["NumMedia"]) || 0, @max_media)

    for index <- 0..(count - 1)//1,
        url = params["MediaUrl#{index}"],
        is_binary(url) do
      %{
        "contentType" => params["MediaContentType#{index}"] || "application/octet-stream",
        "contentUrl" => url,
        "channelData" => %{"provider" => "sms_twilio"}
      }
    end
  end

  @doc """
  Parses a status callback. `queued`, `accepted`, `scheduled` and `sending`
  are acknowledged without an update (the delivery is already `sent` once Twilio
  accepted it).
  """
  @impl true
  def parse_status_update(_channel, %{"MessageSid" => sid, "MessageStatus" => status} = params)
      when is_binary(sid) do
    case normalize_status(status) do
      nil ->
        # Acknowledged (200) without an update: `:ignore` would fail a
        # request posted to `/status`.
        {:ok, []}

      status ->
        {:ok,
         [
           Sms.reject_nil_values(%{
             "provider_message_id" => sid,
             "status" => status,
             "recipient_id" => params["To"],
             "error" => error(params)
           })
         ]}
    end
  end

  def parse_status_update(_channel, _params), do: :ignore

  defp normalize_status("sent"), do: "sent"
  defp normalize_status("delivered"), do: "delivered"
  defp normalize_status("read"), do: "read"
  defp normalize_status(status) when status in ~w(undelivered failed canceled), do: "failed"
  defp normalize_status(_status), do: nil

  defp error(%{"ErrorCode" => code} = params) when is_binary(code) and code != "",
    do:
      "Twilio error #{code}" <>
        if(params["ErrorMessage"], do: ": #{params["ErrorMessage"]}", else: "")

  defp error(_params), do: nil

  @doc "Twilio expects TwiML: an empty `<Response/>` sends no reply."
  @impl true
  def inbound_response(_channel) do
    {"text/xml", ~s(<?xml version="1.0" encoding="UTF-8"?><Response></Response>)}
  end

  @doc "Reads the account (`GET /2010-04-01/Accounts/<sid>.json`)."
  @impl true
  def health_probe(channel) do
    options = request_options(channel, receive_timeout: 5_000, retry: false)

    case Req.get(api_url(channel.config || %{}, ".json"), options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "Twilio API returned #{status}"}
      {:error, reason} -> {:error, "Twilio API request failed: #{inspect(reason)}"}
    end
  end
end
