defmodule Converger.Uploads.GCSStorage do
  @moduledoc """
  Google Cloud Storage backend using the XML API and **HMAC keys**
  (`GOOG4-HMAC-SHA256`, the SigV4-compatible signing scheme), via `Req`.

  Create HMAC keys for a service account with
  `gcloud storage hmac create SERVICE_ACCOUNT_EMAIL`. Service-account RSA
  key (JSON key file) signing is not implemented.

  Options:

    * `:bucket` (required)
    * `:access_key_id` - the HMAC access ID (required)
    * `:secret_access_key` - the HMAC secret (required)
    * `:endpoint` - default `"https://storage.googleapis.com"`
    * `:region` - credential scope location, default `"auto"`
    * `:req_options` - extra `Req` options
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
    config
    |> Keyword.put(:region, Keyword.get(config, :region) || "auto")
    |> Keyword.put(:endpoint, config[:endpoint] || "https://storage.googleapis.com")
    |> Keyword.put(:path_style, true)
    |> Keyword.put(:service, "storage")
    |> Keyword.put(:flavor, :goog)
  end
end
