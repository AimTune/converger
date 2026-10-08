defmodule Converger.Channels.InboundSignature do
  @moduledoc """
  Generic signature scheme for inbound channel webhooks
  (`POST /api/v1/channels/:id/inbound` and `POST /api/v1/channels/:id/status`).

  Senders sign the raw request body with the channel `secret` and send the
  result in the `x-converger-signature` header:

      x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">

  The timestamp must be within the tolerance window (default 300 seconds,
  configurable with `config :converger, :inbound_signature_tolerance_seconds`)
  of the server clock, which limits replay of captured requests.

  The legacy format `sha256=<hex HMAC-SHA256 of raw body>` has no replay
  protection. It is still recognised, but only accepted (with a deprecation
  warning) for channels that have `require_signature: false`.

  Adapters with a provider-native scheme (e.g. WhatsApp Meta's
  `X-Hub-Signature-256`) implement the optional
  `c:Converger.Channels.Adapter.verify_inbound_signature/3` callback instead.

  Verification results:

    * `:ok` - a valid signature using a current scheme
    * `:legacy` - a valid signature using a deprecated scheme
    * `:missing` - no signature was sent (or the channel cannot verify one)
    * `{:error, reason}` - a signature was sent but is invalid
  """

  @header "x-converger-signature"
  @default_tolerance 300

  @type headers :: [{String.t(), String.t()}]
  @type result :: :ok | :legacy | :missing | {:error, term()}

  @doc "Verify the generic `x-converger-signature` header for `channel`."
  @spec verify(map(), headers(), binary() | nil) :: result()
  def verify(channel, headers, raw_body) do
    case get_header(headers, @header) do
      nil -> :missing
      "" -> :missing
      signature -> verify_signature(channel.secret, signature, raw_body || "")
    end
  end

  @doc """
  Build an `x-converger-signature` header value for `raw_body`.
  Useful for clients and tests.
  """
  @spec sign(String.t(), binary(), integer()) :: String.t()
  def sign(secret, raw_body, timestamp \\ System.system_time(:second)) do
    "t=#{timestamp},v1=#{hmac_hex(secret, "#{timestamp}.#{raw_body}")}"
  end

  @doc "Build a legacy (`sha256=<hex>`) signature for `raw_body`."
  @spec sign_legacy(String.t(), binary()) :: String.t()
  def sign_legacy(secret, raw_body), do: "sha256=" <> hmac_hex(secret, raw_body)

  @doc "Allowed clock skew, in seconds, for timestamped signatures."
  def tolerance_seconds do
    Application.get_env(:converger, :inbound_signature_tolerance_seconds, @default_tolerance)
  end

  @doc "Hex-encoded HMAC-SHA256."
  def hmac_hex(secret, data) do
    :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)
  end

  @doc "Returns the first value of a (lowercase) request header."
  def get_header(headers, name) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp verify_signature(secret, _signature, _raw_body) when not is_binary(secret) or secret == "",
    do: {:error, :no_secret}

  defp verify_signature(secret, "sha256=" <> _ = signature, raw_body) do
    if Plug.Crypto.secure_compare(sign_legacy(secret, raw_body), signature),
      do: :legacy,
      else: {:error, :invalid_signature}
  end

  defp verify_signature(secret, signature, raw_body) do
    with {:ok, timestamp, v1_signatures} <- parse(signature),
         :ok <- check_timestamp(timestamp) do
      expected = hmac_hex(secret, "#{timestamp}.#{raw_body}")

      if Enum.any?(v1_signatures, &Plug.Crypto.secure_compare(expected, &1)),
        do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  # Parses "t=123,v1=abc[,v1=def]". Multiple v1 values allow secret rotation.
  defp parse(signature) do
    pairs =
      signature
      |> String.split(",", trim: true)
      |> Enum.map(fn part ->
        case String.split(String.trim(part), "=", parts: 2) do
          [k, v] -> {k, v}
          _ -> {nil, nil}
        end
      end)

    timestamp =
      Enum.find_value(pairs, fn
        {"t", v} -> v
        _ -> nil
      end)

    v1 = for {"v1", v} <- pairs, do: v

    with ts when is_binary(ts) <- timestamp,
         {int, ""} <- Integer.parse(ts),
         [_ | _] <- v1 do
      {:ok, int, v1}
    else
      _ -> {:error, :malformed_signature}
    end
  end

  defp check_timestamp(timestamp) do
    if abs(System.system_time(:second) - timestamp) <= tolerance_seconds(),
      do: :ok,
      else: {:error, :timestamp_out_of_tolerance}
  end
end
