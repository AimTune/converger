defmodule Converger.Uploads.AzureBlobStorage do
  @moduledoc """
  Azure Blob Storage backend using `Req`, Shared Key authorization for
  PUT/GET/DELETE and Service SAS tokens for signed URLs.

  Options:

    * `:account` - storage account name (required)
    * `:account_key` - base64 account key (required)
    * `:container` (required)
    * `:endpoint` - default `"https://<account>.blob.core.windows.net"`;
      for Azurite use `"http://127.0.0.1:10000/devstoreaccount1"`
    * `:req_options` - extra `Req` options
  """

  @behaviour Converger.Uploads.Storage

  alias Converger.Uploads.Signers.{Azure, SigV4}

  @impl true
  def put(config, key, binary, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    url = blob_url(config, key)

    headers =
      sign("PUT", url, config, [
        {"content-length", Integer.to_string(byte_size(binary))},
        {"content-type", content_type},
        {"x-ms-blob-type", "BlockBlob"}
      ])

    config
    |> request(method: :put, url: url, headers: headers, body: binary)
    |> handle_response(fn _ -> :ok end)
  end

  @impl true
  def get(config, key) do
    url = blob_url(config, key)

    config
    |> request(method: :get, url: url, headers: sign("GET", url, config, []))
    |> handle_response(fn resp -> {:ok, resp.body} end)
  end

  @impl true
  def delete(config, key) do
    url = blob_url(config, key)

    case request(config, method: :delete, url: url, headers: sign("DELETE", url, config, [])) do
      {:ok, %Req.Response{status: 404}} -> :ok
      other -> handle_response(other, fn _ -> :ok end)
    end
  end

  @impl true
  def signed_get_url(config, key, opts \\ []) do
    sas =
      sas(config, key,
        permissions: "r",
        expires_in: Keyword.get(opts, :expires_in, 300),
        content_type: Keyword.get(opts, :content_type, ""),
        content_disposition: Keyword.get(opts, :content_disposition, "")
      )

    {:ok, blob_url(config, key) <> "?" <> sas}
  end

  @impl true
  def presigned_put_url(config, key, opts \\ []) do
    sas = sas(config, key, permissions: "cw", expires_in: Keyword.get(opts, :expires_in, 900))

    headers =
      %{"x-ms-blob-type" => "BlockBlob"}
      |> then(fn h ->
        case Keyword.get(opts, :content_type) do
          nil -> h
          ct -> Map.put(h, "content-type", ct)
        end
      end)

    {:ok, %{method: "PUT", url: blob_url(config, key) <> "?" <> sas, headers: headers}}
  end

  @doc "The (unsigned) URL of a blob."
  def blob_url(config, key) do
    "#{endpoint(config)}/#{Keyword.fetch!(config, :container)}/#{SigV4.encode_key(key)}"
  end

  defp sas(config, key, opts) do
    protocol =
      if String.starts_with?(endpoint(config), "https://"), do: "https", else: "https,http"

    Azure.service_sas(
      [
        account: Keyword.fetch!(config, :account),
        account_key: Keyword.fetch!(config, :account_key),
        container: Keyword.fetch!(config, :container),
        blob: key,
        protocol: protocol
      ] ++ opts
    )
  end

  defp sign(method, url, config, headers) do
    Azure.shared_key_headers(
      method,
      url,
      headers,
      Keyword.fetch!(config, :account),
      Keyword.fetch!(config, :account_key)
    )
  end

  defp endpoint(config) do
    (config[:endpoint] || "https://#{Keyword.fetch!(config, :account)}.blob.core.windows.net")
    |> String.trim_trailing("/")
  end

  defp request(config, opts) do
    [retry: :transient, max_retries: 2, decode_body: false, compressed: false]
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.request()
  end

  defp handle_response({:ok, %Req.Response{status: status} = resp}, on_success)
       when status in 200..299,
       do: on_success.(resp)

  defp handle_response({:ok, %Req.Response{status: 404}}, _), do: {:error, :not_found}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _),
    do: {:error, {:http_error, status, body}}

  defp handle_response({:error, reason}, _), do: {:error, reason}
end
