defmodule Converger.Channels.Email.SNS do
  @moduledoc """
  Amazon SNS messages, the transport of Amazon SES inbound mail and of SES
  bounce / complaint / delivery notifications.

  Every SNS message is signed by AWS. `verify/2` checks:

    1. the `TopicArn` is the channel's configured `ses_topic_arn` - SNS signs
       messages of *any* topic, so without this check anyone could subscribe
       their own topic to the channel's endpoint;
    2. the signing certificate URL is an `https://sns.<region>.amazonaws.com`
       `.pem` URL;
    3. the RSA signature (`SignatureVersion` 1 = SHA1, 2 = SHA256) over the
       canonical string of the message.

  Certificates are fetched once per URL and cached in `:persistent_term`
  (AWS rotates them rarely; the URL changes when it does).
  """

  require Logger

  @cert_host ~r/\Asns\.[a-z0-9-]+\.amazonaws\.com(\.cn)?\z/

  @notification_keys ~w(Message MessageId Subject Timestamp TopicArn Type)
  @subscription_keys ~w(Message MessageId SubscribeURL Timestamp Token TopicArn Type)

  @doc """
  The SNS message of a request: the already-decoded params when they carry a
  `Type`, else the JSON request body (SNS posts `text/plain`).
  """
  @spec envelope(map()) :: {:ok, map()} | {:error, :invalid_payload}
  def envelope(%{"Type" => type} = params) when is_binary(type), do: {:ok, params}

  def envelope(%{"_body" => body}) when is_binary(body), do: decode(body)
  def envelope(_params), do: {:error, :invalid_payload}

  @doc "Decode a raw SNS JSON body."
  def decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"Type" => type} = message} when is_binary(type) -> {:ok, message}
      _ -> {:error, :invalid_payload}
    end
  end

  def decode(_), do: {:error, :invalid_payload}

  @doc "Verify an SNS message for a channel whose topic is `topic_arn`."
  @spec verify(map(), String.t() | nil) :: :ok | {:error, term()}
  def verify(message, topic_arn) do
    with :ok <- check_topic(message, topic_arn),
         {:ok, cert_url} <- trusted_url(message["SigningCertURL"], ".pem"),
         {:ok, public_key} <- public_key(cert_url),
         {:ok, digest} <- digest(message["SignatureVersion"]),
         {:ok, signature} <- decode_signature(message["Signature"]),
         {:ok, canonical} <- canonical(message) do
      if :public_key.verify(canonical, digest, signature, public_key),
        do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  @doc """
  Confirm a `SubscriptionConfirmation` by visiting its `SubscribeURL` (an
  `https://sns.<region>.amazonaws.com` URL only).
  """
  def confirm_subscription(%{"SubscribeURL" => url}) do
    with {:ok, url} <- trusted_url(url, nil) do
      case Req.get(url, req_options()) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status}} ->
          {:error, {:subscribe_failed, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def confirm_subscription(_message), do: {:error, :invalid_payload}

  defp check_topic(%{"TopicArn" => arn}, expected)
       when is_binary(arn) and is_binary(expected) and expected != "" do
    if Plug.Crypto.secure_compare(arn, expected), do: :ok, else: {:error, :unexpected_topic}
  end

  defp check_topic(_message, _expected), do: {:error, :unexpected_topic}

  @doc false
  def trusted_url(url, suffix) when is_binary(url) do
    uri = URI.parse(url)

    trusted? =
      uri.scheme == "https" and is_binary(uri.host) and Regex.match?(@cert_host, uri.host) and
        (suffix == nil or String.ends_with?(uri.path || "", suffix))

    if trusted?, do: {:ok, url}, else: {:error, :untrusted_url}
  end

  def trusted_url(_url, _suffix), do: {:error, :untrusted_url}

  defp public_key(url) do
    key = {__MODULE__, :cert, url}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, public_key} <- fetch_public_key(url) do
          :persistent_term.put(key, public_key)
          {:ok, public_key}
        end

      public_key ->
        {:ok, public_key}
    end
  end

  defp fetch_public_key(url) do
    case Req.get(url, req_options()) do
      {:ok, %Req.Response{status: 200, body: pem}} when is_binary(pem) ->
        extract_public_key(pem)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:certificate_unavailable, status}}

      {:error, reason} ->
        Logger.warning("Could not fetch SNS signing certificate", reason: inspect(reason))
        {:error, :certificate_unavailable}
    end
  end

  @doc false
  def extract_public_key(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] ->
        cert = :public_key.pkix_decode_cert(der, :otp)
        # OTPCertificate -> tbsCertificate -> subjectPublicKeyInfo -> key
        spki = cert |> elem(1) |> elem(7)
        {:ok, elem(spki, 2)}

      _ ->
        {:error, :invalid_certificate}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  defp digest("1"), do: {:ok, :sha}
  defp digest("2"), do: {:ok, :sha256}
  defp digest(_), do: {:error, :unsupported_signature_version}

  defp decode_signature(signature) when is_binary(signature) do
    case Base.decode64(signature) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_signature}
    end
  end

  defp decode_signature(_), do: {:error, :invalid_signature}

  @doc "The string AWS signs for `message` (see the SNS docs)."
  def canonical(%{"Type" => "Notification"} = message),
    do: {:ok, build_canonical(message, @notification_keys)}

  def canonical(%{"Type" => type} = message)
      when type in ["SubscriptionConfirmation", "UnsubscribeConfirmation"],
      do: {:ok, build_canonical(message, @subscription_keys)}

  def canonical(_message), do: {:error, :invalid_payload}

  defp build_canonical(message, keys) do
    for key <- keys, is_binary(message[key]), into: "" do
      key <> "\n" <> message[key] <> "\n"
    end
  end

  defp req_options do
    [receive_timeout: 5_000, retry: false]
    |> Keyword.merge(Application.get_env(:converger, :email_req_options, []))
  end
end
