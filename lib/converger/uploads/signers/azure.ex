defmodule Converger.Uploads.Signers.Azure do
  @moduledoc """
  Azure Storage request signing.

    * `shared_key_headers/5` - `Authorization: SharedKey account:signature`
      for Blob service REST calls (version 2015-02-21 and later string-to-sign).
    * `service_sas/2` - Service SAS query string for a single blob
      (string-to-sign for `sv` 2020-12-06 and later).

  See https://learn.microsoft.com/rest/api/storageservices/authorize-with-shared-key
  and https://learn.microsoft.com/rest/api/storageservices/create-service-sas
  """

  @sas_version "2020-12-06"

  @standard_headers ~w(content-encoding content-language content-length content-md5
                       content-type date if-modified-since if-match if-none-match
                       if-unmodified-since range)

  @doc """
  Returns the headers to send (lowercase names), including `x-ms-date`,
  `x-ms-version` and `authorization`.

  `headers` must contain every standard header that will be sent and is part
  of the string-to-sign (notably `content-length` and `content-type` for
  PUT requests).
  """
  def shared_key_headers(method, url, headers, account, account_key, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    version = Keyword.get(opts, :version, "2021-12-02")

    headers =
      (Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end) ++
         [{"x-ms-date", http_date(now)}, {"x-ms-version", version}])
      |> Enum.uniq_by(&elem(&1, 0))

    sts = shared_key_string_to_sign(method, url, headers, account)
    signature = hmac_b64(account_key, sts)
    headers ++ [{"authorization", "SharedKey #{account}:#{signature}"}]
  end

  @doc "Builds the Shared Key string-to-sign for the Blob service."
  def shared_key_string_to_sign(method, url, headers, account) do
    headers = Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
    uri = URI.parse(url)

    standard =
      Enum.map(@standard_headers, fn
        # Since version 2015-02-21 a zero Content-Length is signed as empty.
        "content-length" ->
          case Map.get(headers, "content-length") do
            "0" -> ""
            nil -> ""
            v -> v
          end

        name ->
          Map.get(headers, name, "")
      end)

    canonical_headers =
      headers
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "x-ms-") end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("", fn {k, v} -> "#{k}:#{String.trim(v)}\n" end)

    Enum.join([String.upcase(to_string(method)) | standard], "\n") <>
      "\n" <> canonical_headers <> canonicalized_resource(uri, account)
  end

  defp canonicalized_resource(%URI{path: path, query: query}, account) do
    base = "/#{account}#{path || "/"}"

    params =
      (query || "")
      |> URI.query_decoder()
      |> Enum.group_by(fn {k, _} -> String.downcase(k) end, &elem(&1, 1))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("", fn {k, vs} -> "\n#{k}:#{vs |> Enum.sort() |> Enum.join(",")}" end)

    base <> params
  end

  @doc """
  Builds a Service SAS query string (without leading `?`) for a blob.

  Options:

    * `:account`, `:account_key`, `:container`, `:blob` (required)
    * `:permissions` - e.g. `"r"` (default) or `"cw"`
    * `:expires_in` - seconds (default 300)
    * `:start` - `DateTime` start (optional, omitted by default)
    * `:protocol` - `"https"` (default) or `"https,http"`
    * `:content_type` / `:content_disposition` - response header overrides
    * `:now` - `DateTime` (tests)
  """
  def service_sas(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    expiry = DateTime.add(now, Keyword.get(opts, :expires_in, 300), :second)

    fields = %{
      sp: Keyword.get(opts, :permissions, "r"),
      st: opts |> Keyword.get(:start) |> iso8601(),
      se: iso8601(expiry),
      spr: Keyword.get(opts, :protocol, "https"),
      sv: @sas_version,
      sr: "b",
      rscd: Keyword.get(opts, :content_disposition, ""),
      rsct: Keyword.get(opts, :content_type, "")
    }

    sts =
      sas_string_to_sign(
        fields,
        Keyword.fetch!(opts, :account),
        Keyword.fetch!(opts, :container),
        Keyword.fetch!(opts, :blob)
      )

    sig = hmac_b64(Keyword.fetch!(opts, :account_key), sts)

    [
      sv: fields.sv,
      st: fields.st,
      se: fields.se,
      sr: fields.sr,
      sp: fields.sp,
      spr: fields.spr,
      rscd: fields.rscd,
      rsct: fields.rsct,
      sig: sig
    ]
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> URI.encode_query(:rfc3986)
  end

  @doc "Service SAS string-to-sign (version 2020-12-06 and later)."
  def sas_string_to_sign(fields, account, container, blob) do
    Enum.join(
      [
        fields.sp,
        fields.st,
        fields.se,
        "/blob/#{account}/#{container}/#{blob}",
        # signedIdentifier, signedIP
        "",
        "",
        fields.spr,
        fields.sv,
        fields.sr,
        # signedSnapshotTime, signedEncryptionScope
        "",
        "",
        # rscc
        "",
        fields.rscd,
        # rsce, rscl
        "",
        "",
        fields.rsct
      ],
      "\n"
    )
  end

  def sas_version, do: @sas_version

  defp hmac_b64(account_key, data) do
    :crypto.mac(:hmac, :sha256, Base.decode64!(account_key), data) |> Base.encode64()
  end

  defp iso8601(nil), do: ""

  defp iso8601(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp http_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
end
