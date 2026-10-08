defmodule Converger.Uploads.Signers.CDN do
  @moduledoc """
  Signed URL generation for CDNs.

    * `cloudfront_sign/4` - Amazon CloudFront canned-policy signed URL
      (RSA-SHA1, `Expires` / `Signature` / `Key-Pair-Id` query parameters).
    * `google_cdn_sign/4` - Google Cloud CDN signed URL
      (HMAC-SHA1, `Expires` / `KeyName` / `Signature` query parameters).
  """

  @doc """
  Signs `url` with a CloudFront canned policy expiring at `expires_at`
  (unix seconds). `private_key` is a PEM string (PKCS#1 or PKCS#8 RSA key)
  or an already decoded key record.
  """
  def cloudfront_sign(url, expires_at, key_pair_id, private_key) do
    policy = cloudfront_canned_policy(url, expires_at)
    signature = policy |> :public_key.sign(:sha, decode_private_key(private_key)) |> cf_base64()

    url <>
      separator(url) <>
      "Expires=#{expires_at}&Signature=#{signature}&Key-Pair-Id=#{key_pair_id}"
  end

  @doc "The canned policy JSON CloudFront expects (no whitespace)."
  def cloudfront_canned_policy(url, expires_at) do
    ~s({"Statement":[{"Resource":"#{url}","Condition":{"DateLessThan":{"AWS:EpochTime":#{expires_at}}}}]})
  end

  @doc "CloudFront URL-safe base64: `+` -> `-`, `=` -> `_`, `/` -> `~`."
  def cf_base64(binary) do
    binary
    |> Base.encode64()
    |> String.replace(["+", "=", "/"], fn
      "+" -> "-"
      "=" -> "_"
      "/" -> "~"
    end)
  end

  @doc """
  Signs `url` for Google Cloud CDN. `key` is the base64url encoded 128-bit
  key as shown by `gcloud compute backend-buckets add-signed-url-key`.
  """
  def google_cdn_sign(url, expires_at, key_name, key) do
    to_sign = url <> separator(url) <> "Expires=#{expires_at}&KeyName=#{key_name}"

    decoded_key =
      key |> String.trim() |> String.trim_trailing("=") |> Base.url_decode64!(padding: false)

    signature = :crypto.mac(:hmac, :sha, decoded_key, to_sign) |> Base.url_encode64()
    to_sign <> "&Signature=" <> signature
  end

  defp separator(url), do: if(String.contains?(url, "?"), do: "&", else: "?")

  defp decode_private_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> :public_key.pem_entry_decode(entry)
      [] -> raise ArgumentError, "invalid CloudFront private key PEM"
    end
  end

  defp decode_private_key(key), do: key
end
