defmodule Converger.Channels.Meta.Graph do
  @moduledoc """
  Graph API plumbing shared by the Meta adapters (`whatsapp_meta`,
  `messenger`, `instagram`): API version resolution, request options,
  `X-Hub-Signature-256` webhook signatures, the `hub.challenge` handshake,
  Graph error classification and inbound media downloads.

  Every adapter keeps its own request-option key (e.g.
  `config :converger, :whatsapp_req_options`), so tests and operators can
  stub or tune one provider without touching the others. See ADR-0048.
  """

  alias Converger.Channels.{DeliveryError, InboundSignature, MediaDownload}
  alias Converger.Uploads

  # Latest Graph API version as of 2026-07-29 (v26.0); override per channel
  # with `graph_api_version` or per adapter in config.
  @default_version "v26.0"

  # Graph error codes that mean "slow down" or "try again" even though the
  # HTTP status is 400 or 403: API too many calls (4), user request limit
  # (17), page request limit (32), rate limit (613, 80006 for Messenger and
  # 80002 for Instagram), and the generic transient errors 1 and 2.
  @retryable_codes [1, 2, 4, 17, 32, 613, 80_002, 80_006]

  @doc "The default Graph API version (#{@default_version})."
  def default_version, do: @default_version

  @doc """
  Graph API version of `channel`: the channel config key
  `"graph_api_version"`, then `config :converger, adapter, graph_api_version:
  "..."`, then #{@default_version}.
  """
  def version(channel, adapter) do
    config = Map.get(channel, :config) || %{}

    case config["graph_api_version"] do
      version when is_binary(version) and version != "" ->
        version

      _ ->
        :converger
        |> Application.get_env(adapter, [])
        |> Keyword.get(:graph_api_version, @default_version)
    end
  end

  @doc "`https://<host>/<version>/<path>`."
  def url(host \\ "graph.facebook.com", version, path),
    do: "https://#{host}/#{version}/#{path}"

  @doc """
  Req options with the bearer `token`, merged with `options` and the
  application env `req_options_key` (test stubs, operator tuning).
  """
  def request_options(token, options, req_options_key) do
    [headers: [{"authorization", "Bearer #{token}"}]]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:converger, req_options_key, []))
  end

  @doc """
  Verifies Meta's `X-Hub-Signature-256` header (`sha256=<hex HMAC-SHA256 of
  the raw body, keyed with the app secret>`).

  Returns `:missing` when the header is absent or no `app_secret` is
  configured, so the inbound controller applies the channel's
  `require_signature` policy.
  """
  def verify_signature(app_secret, headers, raw_body) do
    case InboundSignature.get_header(headers, "x-hub-signature-256") do
      nil ->
        :missing

      _signature when not is_binary(app_secret) or app_secret == "" ->
        :missing

      signature ->
        expected = "sha256=" <> InboundSignature.hmac_hex(app_secret, raw_body || "")

        if Plug.Crypto.secure_compare(expected, String.downcase(signature)),
          do: :ok,
          else: {:error, :invalid_signature}
    end
  end

  @doc """
  Meta's webhook handshake: `hub.challenge` is echoed verbatim once
  `hub.verify_token` matches `verify_token` (constant-time compare).
  """
  def verify_subscription(verify_token, params) do
    provided = params["hub.verify_token"]

    if is_binary(verify_token) and verify_token != "" and is_binary(provided) and
         Plug.Crypto.secure_compare(provided, verify_token),
       do: {:ok, params["hub.challenge"] || ""},
       else: :error
  end

  @doc "The Graph error code of a response body (`error.code`), or nil."
  def error_code(%{"error" => %{"code" => code}}), do: code
  def error_code(_body), do: nil

  @doc "The Graph error subcode of a response body (`error.error_subcode`), or nil."
  def error_subcode(%{"error" => %{"error_subcode" => code}}), do: code
  def error_subcode(_body), do: nil

  @doc """
  Classifies a non-2xx Graph response: `DeliveryError.from_http/4`, except
  that the throttling and transient error codes (#{inspect(@retryable_codes)})
  are retryable whatever the HTTP status.
  """
  def classify_http(status, headers, body, label) do
    error = DeliveryError.from_http(status, headers, body, label)

    if error_code(body) in @retryable_codes,
      do: %{error | retryable?: true},
      else: error
  end

  @doc """
  Downloads a media file Meta hosts by id (WhatsApp): `GET /<version>/<id>`
  returns a short-lived URL and the file size (checked against the upload
  limit), and the URL is fetched with the same access token.
  """
  def fetch_media_by_id(media_id, token, version, req_options_key) do
    url = url(version, URI.encode(media_id, &URI.char_unreserved?/1))
    options = [receive_timeout: MediaDownload.timeout_ms(), retry: false]

    case Req.get(url, request_options(token, options, req_options_key)) do
      {:ok, %Req.Response{status: 200, body: %{"url" => media_url} = media}} ->
        if is_integer(media["file_size"]) and media["file_size"] > Uploads.max_file_size() do
          {:error, :too_large}
        else
          headers = [{"authorization", "Bearer #{token}"}]

          with {:ok, data} <- MediaDownload.get(media_url, [headers: headers], req_options_key) do
            {:ok, %{data: data, filename: nil}}
          end
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Downloads a media file from the CDN URL of a webhook payload (Messenger,
  Instagram). The URL is checked by `Converger.Channels.UrlGuard` first, so a
  forged payload on an unsigned channel cannot make Converger fetch an
  internal address; the download is bounded by the upload size limit.
  """
  def fetch_media_url(url, req_options_key) when is_binary(url),
    do: MediaDownload.get_public(url, req_options_key)
end
