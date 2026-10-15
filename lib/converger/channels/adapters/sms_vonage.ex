defmodule Converger.Channels.Adapters.SmsVonage do
  @moduledoc """
  SMS through the Vonage Messages API.

    * Outbound: `POST /v1/messages` (`channel: "sms"`, `message_type:
      "text"`), authenticated with basic auth (`api_key` / `api_secret`) or,
      for a Vonage application, a JWT signed with its `private_key`
      (`application_id`). The activity id is sent as `client_ref`.
    * Inbound and status webhooks: the application's Inbound URL and Status
      URL, both JSON. `sms.num_messages` is kept as
      `channelData.sms_segments`.
    * Receipts: `submitted`, `delivered`, `rejected`, `undeliverable`,
      `read` advance the delivery.
    * Signatures: the `Authorization: Bearer` JWT Vonage signs with the
      account's signature secret, see `verify_inbound_signature/3`.
    * Opt-out: the keywords of `Converger.Channels.Sms`.
  """
  use Converger.Channels.Adapter, type: "sms_vonage"

  alias Converger.Channels.{DeliveryError, InboundSignature, Sms}
  alias Converger.Participants
  alias Converger.Pipeline.RetryPolicy

  @api_url "https://api.nexmo.com/v1/messages"
  @balance_url "https://rest.nexmo.com/account/get-balance"
  @jwt_ttl_seconds 900

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :receipts,
      :provider_ack,
      activity_types: ~w(message)
    ]
  end

  @impl true
  def config_schema do
    [
      %{
        name: "from",
        type: :string,
        required: true,
        label: "From",
        placeholder: "Vonage number or alphanumeric sender id",
        summary: true
      },
      %{name: "api_key", type: :string, label: "API key", summary: true},
      %{
        name: "api_secret",
        type: :string,
        secret: true,
        label: "API secret",
        placeholder: "Basic auth (or use an application)"
      },
      %{
        name: "application_id",
        type: :string,
        label: "Application ID",
        placeholder: "JWT auth (with the private key)"
      },
      %{
        name: "private_key",
        type: :string,
        secret: true,
        label: "Application private key",
        placeholder: "-----BEGIN PRIVATE KEY-----"
      },
      # Vonage signs webhooks with the account's signature secret, so a
      # channel that requires signatures cannot accept anything without it.
      %{
        name: "signature_secret",
        type: :string,
        required: :with_signature,
        secret: true,
        label: "Signature secret",
        placeholder: "Signs the webhook JWT"
      },
      %{
        name: "default_country_code",
        type: :string,
        label: "Default country code",
        placeholder: "e.g. 44 or 90, for national numbers"
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
    case auth_mode(config) do
      :jwt ->
        case signer(config["private_key"]) do
          {:ok, _signer} -> :ok
          :error -> {:error, "sms_vonage config private_key is not a valid PEM private key"}
        end

      :basic ->
        :ok

      nil ->
        {:error,
         "sms_vonage config needs api_key and api_secret, or application_id and private_key"}
    end
  end

  defp auth_mode(config) do
    cond do
      present?(config["application_id"]) and present?(config["private_key"]) -> :jwt
      present?(config["api_key"]) and present?(config["api_secret"]) -> :basic
      true -> nil
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # Joken builds the signer lazily, so the PEM is decoded here first.
  defp signer(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        _key = :public_key.pem_entry_decode(entry)
        {:ok, Joken.Signer.create("RS256", %{"pem" => pem})}

      [] ->
        :error
    end
  rescue
    _ -> :error
  end

  defp signer(_pem), do: :error

  @impl true
  def deliver_activity(channel, activity) do
    config = channel.config || %{}
    text = activity.text || ""

    with {:ok, to} <- Sms.recipient(channel, activity),
         :ok <- check_not_opted_out(channel, to),
         :ok <- check_content(text),
         {:ok, segments} <- check_length(channel, text),
         {:ok, auth} <- auth(config) do
      payload =
        Sms.reject_nil_values(%{
          message_type: "text",
          channel: "sms",
          # Vonage takes E.164 without the leading +.
          to: String.trim_leading(to, "+"),
          from: config["from"],
          text: text,
          client_ref: Map.get(activity, :id)
        })

      options =
        [json: payload, receive_timeout: RetryPolicy.for_channel(channel).timeout_ms]
        |> Keyword.merge(auth)
        |> Keyword.merge(Application.get_env(:converger, :sms_req_options, []))

      case Req.post(@api_url, options) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          uuid = body["message_uuid"]

          {:ok,
           Sms.reject_nil_values(%{
             provider_message_id: uuid,
             vonage_message_uuid: uuid,
             sms_segments: segments
           })}

        {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
          {:error, DeliveryError.from_http(status, headers, body, "Vonage API")}

        {:error, reason} ->
          {:error, DeliveryError.from_transport(reason, "Vonage API")}
      end
    end
  end

  defp check_not_opted_out(channel, to) do
    if Participants.opted_out?(Map.get(channel, :id), to),
      do: {:error, DeliveryError.permanent("recipient #{to} opted out")},
      else: :ok
  end

  defp check_content(text) do
    if String.trim(text) == "",
      do: {:error, DeliveryError.permanent("nothing to send: empty text")},
      else: :ok
  end

  defp check_length(channel, text) do
    case Sms.check_length(channel, text) do
      {:ok, segments} -> {:ok, segments}
      {:error, message} -> {:error, DeliveryError.permanent(message)}
    end
  end

  defp auth(config) do
    case auth_mode(config) do
      :basic ->
        {:ok, [auth: {:basic, "#{config["api_key"]}:#{config["api_secret"]}"}]}

      :jwt ->
        case application_jwt(config) do
          {:ok, token} -> {:ok, [auth: {:bearer, token}]}
          :error -> {:error, DeliveryError.permanent("Vonage private_key cannot sign a JWT")}
        end

      nil ->
        {:error, DeliveryError.permanent("Vonage credentials are not configured")}
    end
  end

  @doc false
  def application_jwt(config) do
    now = System.system_time(:second)

    claims = %{
      "application_id" => config["application_id"],
      "iat" => now,
      "exp" => now + @jwt_ttl_seconds,
      "jti" => Ecto.UUID.generate()
    }

    with {:ok, signer} <- signer(config["private_key"]),
         {:ok, token, _claims} <- Joken.encode_and_sign(claims, signer) do
      {:ok, token}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Verifies a signed Messages API webhook: `Authorization: Bearer <JWT>`,
  HS256-signed with the account's signature secret (`signature_secret`),
  whose `payload_hash` claim is the SHA-256 (hex) of the raw body.

  Returns `:missing` without a bearer token or without a `signature_secret`.
  """
  @impl true
  def verify_inbound_signature(channel, headers, raw_body) do
    secret = (channel.config || %{})["signature_secret"]

    case bearer_token(headers) do
      nil ->
        :missing

      _token when not is_binary(secret) or secret == "" ->
        :missing

      token ->
        with {:ok, claims} <- Joken.verify(token, Joken.Signer.create("HS256", secret)),
             :ok <- check_payload_hash(claims, raw_body || "") do
          :ok
        else
          _ -> {:error, :invalid_signature}
        end
    end
  end

  defp bearer_token(headers) do
    case InboundSignature.get_header(headers, "authorization") do
      "Bearer " <> token -> String.trim(token)
      _ -> nil
    end
  end

  defp check_payload_hash(%{"payload_hash" => hash}, raw_body) when is_binary(hash) do
    expected = :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(hash)),
      do: :ok,
      else: :error
  end

  # Without a payload hash the token would authenticate any body.
  defp check_payload_hash(_claims, _raw_body), do: :error

  @doc """
  Parses an inbound SMS of the Messages API. A status webhook (it has a
  `status`) carries no message and parses to `{:ok, []}`.
  """
  @impl true
  def parse_inbound(_channel, %{"message_uuid" => uuid, "status" => _}) when is_binary(uuid),
    do: {:ok, []}

  def parse_inbound(channel, %{"message_uuid" => uuid, "from" => from} = params)
      when is_binary(uuid) and is_binary(from) do
    config = channel.config || %{}
    sender = Sms.participant_id(from, config["default_country_code"])

    metadata =
      Sms.reject_nil_values(%{
        "vonage_message_uuid" => uuid,
        "to" => params["to"],
        "sms_segments" => integer(get_in(params, ["sms", "num_messages"])),
        "timestamp" => params["timestamp"]
      })

    message =
      %{
        "sender" => sender,
        "type" => "message",
        "text" => params["text"] || "",
        "attachments" => [],
        "metadata" => metadata,
        "idempotency_key" => uuid,
        "participant" => %{"external_id" => sender}
      }
      |> Sms.apply_opt_keyword()

    {:ok, [message]}
  end

  def parse_inbound(_channel, _params), do: {:error, "unable to parse Vonage webhook payload"}

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer(_value), do: nil

  @impl true
  def parse_status_update(_channel, %{"message_uuid" => uuid, "status" => status} = params)
      when is_binary(uuid) do
    case normalize_status(status) do
      nil ->
        # Acknowledged (200) without an update: `:ignore` would fail a
        # request posted to `/status`.
        {:ok, []}

      status ->
        {:ok,
         [
           Sms.reject_nil_values(%{
             "provider_message_id" => uuid,
             "status" => status,
             "timestamp" => params["timestamp"],
             "recipient_id" => params["to"],
             "error" => error(params["error"])
           })
         ]}
    end
  end

  def parse_status_update(_channel, _params), do: :ignore

  defp normalize_status("submitted"), do: "sent"
  defp normalize_status("delivered"), do: "delivered"
  defp normalize_status("read"), do: "read"
  defp normalize_status(status) when status in ~w(rejected undeliverable failed), do: "failed"
  defp normalize_status(_status), do: nil

  defp error(%{} = error) do
    [error["title"], error["detail"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(": ")
    |> case do
      "" -> nil
      message -> "Vonage: " <> message
    end
  end

  defp error(_error), do: nil

  @doc """
  With an API key and secret, reads the account balance; with an
  application, checks that the private key signs a JWT (Vonage has no
  credential check endpoint for applications).
  """
  @impl true
  def health_probe(channel) do
    config = channel.config || %{}

    case auth_mode(config) do
      :basic ->
        probe_balance(config)

      :jwt ->
        case application_jwt(config) do
          {:ok, _token} -> :ok
          :error -> {:error, "Vonage private_key cannot sign a JWT"}
        end

      nil ->
        {:error, "Vonage credentials are not configured"}
    end
  end

  defp probe_balance(config) do
    options =
      [
        auth: {:basic, "#{config["api_key"]}:#{config["api_secret"]}"},
        receive_timeout: 5_000,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:converger, :sms_req_options, []))

    case Req.get(@balance_url, options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "Vonage API returned #{status}"}
      {:error, reason} -> {:error, "Vonage API request failed: #{inspect(reason)}"}
    end
  end
end
