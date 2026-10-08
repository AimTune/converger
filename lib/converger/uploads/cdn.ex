defmodule Converger.Uploads.CDN do
  @moduledoc """
  Config-driven public URL generation for a CDN placed in front of any
  storage backend.

      config :converger, Converger.Uploads,
        cdn: [
          type: :cloudfront,               # :cloudfront | :google_cdn | :plain
          base_url: "https://dxxxx.cloudfront.net",
          path_prefix: "",                 # optional, prepended to the object key
          key_pair_id: "K2JCJMDEHXQW5F",   # :cloudfront
          private_key: "-----BEGIN RSA PRIVATE KEY-----...",
          key_name: "my-key",              # :google_cdn
          key: "base64url-key",
          sign_origin: false               # :plain only, see below
        ]

  Types:

    * `:cloudfront` - CloudFront signed URL with a canned policy.
    * `:google_cdn` - Google Cloud CDN signed URL.
    * `:plain` - unsigned `base_url/key` URL. Suitable for Cloudflare in front
      of a public R2 bucket / custom domain, a public Azure CDN / Front Door
      endpoint, or any CDN that does its own access control. With
      `sign_origin: true` the storage backend's signed query string is
      appended (useful for Azure CDN / Front Door forwarding a SAS token to
      a private container).
  """

  alias Converger.Uploads.Signers
  alias Converger.Uploads.Signers.SigV4

  @doc """
  Returns `{:ok, url}` for the object, or `:none` when no CDN is configured.

  `origin_query` is a function returning the storage backend's signed query
  string; it is only invoked for `type: :plain, sign_origin: true`.
  """
  def url(cdn, key, expires_in, origin_query \\ fn -> nil end)

  def url(nil, _key, _expires_in, _origin_query), do: :none
  def url([], _key, _expires_in, _origin_query), do: :none

  def url(cdn, key, expires_in, origin_query) do
    base = unsigned_url(cdn, key)
    expires_at = System.os_time(:second) + expires_in

    case Keyword.get(cdn, :type, :plain) do
      :cloudfront ->
        {:ok,
         Signers.CDN.cloudfront_sign(
           base,
           expires_at,
           Keyword.fetch!(cdn, :key_pair_id),
           Keyword.fetch!(cdn, :private_key)
         )}

      :google_cdn ->
        {:ok,
         Signers.CDN.google_cdn_sign(
           base,
           expires_at,
           Keyword.fetch!(cdn, :key_name),
           Keyword.fetch!(cdn, :key)
         )}

      :plain ->
        if Keyword.get(cdn, :sign_origin, false) do
          case origin_query.() do
            q when is_binary(q) and q != "" -> {:ok, base <> "?" <> q}
            _ -> {:ok, base}
          end
        else
          {:ok, base}
        end

      other ->
        raise ArgumentError, "unknown CDN type #{inspect(other)}"
    end
  end

  @doc "The unsigned CDN URL for a key."
  def unsigned_url(cdn, key) do
    base = cdn |> Keyword.fetch!(:base_url) |> String.trim_trailing("/")

    prefix =
      case cdn |> Keyword.get(:path_prefix, "") |> to_string() |> String.trim("/") do
        "" -> ""
        p -> p <> "/"
      end

    "#{base}/#{SigV4.encode_key(prefix <> key)}"
  end
end
