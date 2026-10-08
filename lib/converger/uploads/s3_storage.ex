defmodule Converger.Uploads.S3Storage do
  @moduledoc """
  Amazon S3 storage backend (also MinIO, Cloudflare R2 and other
  S3-compatible services), using `Req` and AWS Signature V4.

  Options:

    * `:bucket` (required)
    * `:access_key_id` / `:secret_access_key` (required)
    * `:session_token` - optional STS token
    * `:region` - default `"us-east-1"` (`"auto"` for R2)
    * `:endpoint` - default `"https://s3.<region>.amazonaws.com"`;
      e.g. `"http://localhost:9000"` for MinIO or
      `"https://<account>.r2.cloudflarestorage.com"` for R2
    * `:path_style` - `true` for `endpoint/bucket/key` URLs (MinIO, R2),
      `false` (default) for virtual-hosted `bucket.endpoint/key`
    * `:req_options` - extra `Req` options (tests use `plug:`)
  """

  @behaviour Converger.Uploads.Storage

  alias Converger.Uploads.S3Compatible

  @impl true
  def put(config, key, binary, opts \\ []),
    do: S3Compatible.put(normalize(config), key, binary, opts)

  @impl true
  def get(config, key), do: S3Compatible.get(normalize(config), key)

  @impl true
  def delete(config, key), do: S3Compatible.delete(normalize(config), key)

  @impl true
  def signed_get_url(config, key, opts \\ []),
    do: S3Compatible.signed_get_url(normalize(config), key, opts)

  @impl true
  def presigned_put_url(config, key, opts \\ []),
    do: S3Compatible.presigned_put_url(normalize(config), key, opts)

  @doc false
  def normalize(config) do
    region = Keyword.get(config, :region) || "us-east-1"

    config
    |> Keyword.put(:region, region)
    |> Keyword.put(:endpoint, config[:endpoint] || "https://s3.#{region}.amazonaws.com")
    |> Keyword.put(:path_style, config[:path_style] || false)
    |> Keyword.put(:service, "s3")
    |> Keyword.put(:flavor, :aws)
  end
end
