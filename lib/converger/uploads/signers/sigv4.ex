defmodule Converger.Uploads.Signers.SigV4 do
  @moduledoc """
  AWS Signature Version 4 request signing and URL presigning.

  Also implements the Google Cloud Storage HMAC variant (`GOOG4-HMAC-SHA256`),
  which is the same algorithm with different prefixes. Select it with
  `flavor: :goog`.

  Options (all signing functions):

    * `:access_key_id` / `:secret_access_key` - credentials (required)
    * `:region` - e.g. `"us-east-1"`, `"auto"` for R2/GCS
    * `:service` - `"s3"` (default) or `"storage"` for GCS
    * `:flavor` - `:aws` (default) or `:goog`
    * `:session_token` - optional STS session token (AWS only)
    * `:now` - `DateTime` used as the request time (defaults to now; tests)

  URLs passed in must already have their path percent-encoded (as sent on
  the wire). The path is used verbatim as the canonical URI, which is the
  S3 rule (no double encoding).
  """

  @unsigned_payload "UNSIGNED-PAYLOAD"

  @doc "Hex encoded SHA-256 of an empty payload."
  def empty_payload_hash, do: sha256_hex("")

  @doc "Marker used as payload hash for presigned URLs."
  def unsigned_payload, do: @unsigned_payload

  @doc """
  Signs a request using the `Authorization` header.

  `headers` is a list of `{name, value}` tuples that will be signed (host and
  the date / content hash headers are added automatically). `payload` is
  either `{:hash, hex}` or the raw body binary.

  Returns the full list of headers to send (lowercase names), including
  `authorization`.
  """
  def sign_headers(method, url, headers, payload, opts) do
    flavor = flavor(opts)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    amz_date = format_datetime(now)
    payload_hash = payload_hash(payload)
    uri = URI.parse(url)

    base_headers =
      [
        {"host", host_header(uri)},
        {"#{flavor.header_prefix}-date", amz_date},
        {"#{flavor.header_prefix}-content-sha256", payload_hash}
      ] ++
        session_token_header(opts, flavor)

    headers =
      (Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end) ++
         base_headers)
      |> Enum.uniq_by(&elem(&1, 0))

    {canonical_request, signed_headers} =
      canonical_request(method, uri.path, uri.query, headers, payload_hash)

    scope = credential_scope(now, opts, flavor)
    sts = string_to_sign(canonical_request, amz_date, scope, flavor)
    signature = signature(sts, now, opts, flavor)

    authorization =
      "#{flavor.algorithm} Credential=#{Keyword.fetch!(opts, :access_key_id)}/#{scope}, " <>
        "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    headers ++ [{"authorization", authorization}]
  end

  @doc """
  Builds a presigned URL valid for `expires_in` seconds. Only the `host`
  header is signed and the payload is `UNSIGNED-PAYLOAD`.
  """
  def presign_url(method, url, expires_in, opts) do
    flavor = flavor(opts)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    amz_date = format_datetime(now)
    uri = URI.parse(url)
    scope = credential_scope(now, opts, flavor)
    p = flavor.query_prefix

    auth_params =
      [
        {"#{p}-Algorithm", flavor.algorithm},
        {"#{p}-Credential", "#{Keyword.fetch!(opts, :access_key_id)}/#{scope}"},
        {"#{p}-Date", amz_date},
        {"#{p}-Expires", Integer.to_string(expires_in)},
        {"#{p}-SignedHeaders", "host"}
      ] ++
        case {flavor.name, Keyword.get(opts, :session_token)} do
          {:aws, token} when is_binary(token) and token != "" -> [{"X-Amz-Security-Token", token}]
          _ -> []
        end

    existing = decode_query(uri.query)
    query = encode_query(existing ++ auth_params)

    {canonical_request, _signed} =
      canonical_request(method, uri.path, query, [{"host", host_header(uri)}], @unsigned_payload)

    sts = string_to_sign(canonical_request, amz_date, scope, flavor)
    signature = signature(sts, now, opts, flavor)

    URI.to_string(%{uri | query: query <> "&#{p}-Signature=#{signature}"})
  end

  @doc """
  Builds the canonical request. Returns `{canonical_request, signed_headers}`.
  """
  def canonical_request(method, path, query, headers, payload_hash) do
    canonical_headers =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), normalize_value(v)} end)
      |> Enum.sort_by(&elem(&1, 0))

    signed_headers = Enum.map_join(canonical_headers, ";", &elem(&1, 0))
    header_block = Enum.map_join(canonical_headers, "", fn {k, v} -> "#{k}:#{v}\n" end)

    canonical =
      Enum.join(
        [
          method |> to_string() |> String.upcase(),
          canonical_uri(path),
          canonical_query(query),
          header_block,
          signed_headers,
          payload_hash
        ],
        "\n"
      )

    {canonical, signed_headers}
  end

  @doc false
  def string_to_sign(canonical_request, amz_date, scope, flavor) do
    Enum.join([flavor.algorithm, amz_date, scope, sha256_hex(canonical_request)], "\n")
  end

  @doc """
  Derives the signing key for a date (`"YYYYMMDD"`), region and service.
  """
  def signing_key(secret, date, region, service, flavor_name \\ :aws) do
    flavor = flavor(flavor: flavor_name)

    (flavor.key_prefix <> secret)
    |> hmac(date)
    |> hmac(region)
    |> hmac(service)
    |> hmac(flavor.terminator)
  end

  @doc "Percent-encodes a string per RFC 3986 (unreserved characters kept)."
  def uri_encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  @doc "Encodes an object key for use in a URL path (slashes are kept)."
  def encode_key(key) do
    key |> String.split("/") |> Enum.map_join("/", &uri_encode/1)
  end

  def sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  ## Internals

  defp signature(sts, now, opts, flavor) do
    key =
      signing_key(
        Keyword.fetch!(opts, :secret_access_key),
        Calendar.strftime(now, "%Y%m%d"),
        Keyword.fetch!(opts, :region),
        Keyword.get(opts, :service, "s3"),
        flavor.name
      )

    key |> hmac(sts) |> Base.encode16(case: :lower)
  end

  defp credential_scope(now, opts, flavor) do
    Enum.join(
      [
        Calendar.strftime(now, "%Y%m%d"),
        Keyword.fetch!(opts, :region),
        Keyword.get(opts, :service, "s3"),
        flavor.terminator
      ],
      "/"
    )
  end

  defp session_token_header(opts, %{name: :aws}) do
    case Keyword.get(opts, :session_token) do
      token when is_binary(token) and token != "" -> [{"x-amz-security-token", token}]
      _ -> []
    end
  end

  defp session_token_header(_opts, _flavor), do: []

  defp payload_hash({:hash, hash}), do: hash
  defp payload_hash(body) when is_binary(body), do: sha256_hex(body)
  defp payload_hash(iodata), do: iodata |> IO.iodata_to_binary() |> sha256_hex()

  defp canonical_uri(nil), do: "/"
  defp canonical_uri(""), do: "/"
  defp canonical_uri(path), do: path

  defp canonical_query(nil), do: ""
  defp canonical_query(""), do: ""
  defp canonical_query(query), do: query |> decode_query() |> encode_query()

  defp decode_query(nil), do: []
  defp decode_query(""), do: []

  defp decode_query(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {URI.decode(k), URI.decode(v)}
        [k] -> {URI.decode(k), ""}
      end
    end)
  end

  defp encode_query(pairs) do
    pairs
    |> Enum.map(fn {k, v} -> {uri_encode(k), uri_encode(v)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp normalize_value(value) do
    value |> to_string() |> String.split() |> Enum.join(" ")
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if port == nil or URI.default_port(scheme) == port, do: host, else: "#{host}:#{port}"
  end

  defp format_datetime(%DateTime{} = now), do: Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp flavor(opts) do
    case Keyword.get(opts, :flavor, :aws) do
      :aws ->
        %{
          name: :aws,
          algorithm: "AWS4-HMAC-SHA256",
          key_prefix: "AWS4",
          terminator: "aws4_request",
          header_prefix: "x-amz",
          query_prefix: "X-Amz"
        }

      :goog ->
        %{
          name: :goog,
          algorithm: "GOOG4-HMAC-SHA256",
          key_prefix: "GOOG4",
          terminator: "goog4_request",
          header_prefix: "x-goog",
          query_prefix: "X-Goog"
        }
    end
  end
end
