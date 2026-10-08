defmodule Converger.Uploads.S3Compatible do
  @moduledoc """
  Shared implementation of the S3 XML object API used by
  `Converger.Uploads.S3Storage` (AWS SigV4) and
  `Converger.Uploads.GCSStorage` (GCS XML API with HMAC keys).

  Expects a normalized config with `:endpoint`, `:bucket`, `:region`,
  `:service`, `:flavor`, `:path_style`, `:access_key_id`,
  `:secret_access_key` and optional `:session_token` / `:req_options`.
  """

  alias Converger.Uploads.Signers.SigV4

  def put(config, key, binary, opts) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    url = object_url(config, key)

    headers =
      SigV4.sign_headers(
        "PUT",
        url,
        [{"content-type", content_type}],
        binary,
        signer_opts(config)
      )

    config
    |> request(method: :put, url: url, headers: headers, body: binary)
    |> handle_response(fn _ -> :ok end)
  end

  def get(config, key) do
    url = object_url(config, key)

    headers =
      SigV4.sign_headers("GET", url, [], {:hash, SigV4.empty_payload_hash()}, signer_opts(config))

    config
    |> request(method: :get, url: url, headers: headers)
    |> handle_response(fn resp -> {:ok, resp.body} end)
  end

  def delete(config, key) do
    url = object_url(config, key)

    headers =
      SigV4.sign_headers(
        "DELETE",
        url,
        [],
        {:hash, SigV4.empty_payload_hash()},
        signer_opts(config)
      )

    case request(config, method: :delete, url: url, headers: headers) do
      {:ok, %Req.Response{status: 404}} -> :ok
      other -> handle_response(other, fn _ -> :ok end)
    end
  end

  def signed_get_url(config, key, opts) do
    expires_in = Keyword.get(opts, :expires_in, 300)

    overrides =
      [
        {"response-content-type", Keyword.get(opts, :content_type)},
        {"response-content-disposition", Keyword.get(opts, :content_disposition)}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    url =
      case overrides do
        [] -> object_url(config, key)
        _ -> object_url(config, key) <> "?" <> URI.encode_query(overrides, :rfc3986)
      end

    {:ok, SigV4.presign_url("GET", url, expires_in, signer_opts(config))}
  end

  def presigned_put_url(config, key, opts) do
    expires_in = Keyword.get(opts, :expires_in, 900)
    url = SigV4.presign_url("PUT", object_url(config, key), expires_in, signer_opts(config))
    headers = maybe_content_type(Keyword.get(opts, :content_type))
    {:ok, %{method: "PUT", url: url, headers: headers}}
  end

  @doc "The (unsigned) URL of an object."
  def object_url(config, key) do
    endpoint = config |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/")
    bucket = Keyword.fetch!(config, :bucket)
    encoded = SigV4.encode_key(key)

    if Keyword.get(config, :path_style, true) do
      "#{endpoint}/#{bucket}/#{encoded}"
    else
      uri = URI.parse(endpoint)
      URI.to_string(%{uri | host: "#{bucket}.#{uri.host}", path: "/#{encoded}"})
    end
  end

  defp maybe_content_type(nil), do: %{}
  defp maybe_content_type(ct), do: %{"content-type" => ct}

  defp signer_opts(config) do
    [
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: Keyword.fetch!(config, :secret_access_key),
      region: Keyword.fetch!(config, :region),
      service: Keyword.fetch!(config, :service),
      flavor: Keyword.fetch!(config, :flavor),
      session_token: Keyword.get(config, :session_token)
    ]
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
