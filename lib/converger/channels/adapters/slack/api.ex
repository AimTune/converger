defmodule Converger.Channels.Adapters.Slack.Api do
  @moduledoc """
  Slack Web API calls of the `slack` channel adapter.

  Every method is a `POST https://slack.com/api/<method>` with the channel's
  bot token as `Authorization: Bearer`. Slack answers most failures with
  `200 {"ok": false, "error": "..."}`; `call/3` turns them into a
  `Converger.Channels.DeliveryError`:

    * HTTP 429 (`Retry-After` honoured) and 5xx are retryable;
    * `ok: false` errors in `@retryable_errors` (Slack-side failures) are
      retryable, every other one (`invalid_auth`, `channel_not_found`,
      `not_in_channel`, `msg_too_long`, ...) is permanent.

  Tests and deployments can pass extra `Req` options (e.g. a `Req.Test` plug)
  with `config :converger, :slack_req_options, [...]`.
  """

  alias Converger.Channels.DeliveryError

  @base_url "https://slack.com/api/"

  @retryable_errors ~w(ratelimited rate_limited internal_error fatal_error
                       service_unavailable request_timeout)

  @doc """
  Call a Web API method. `body` is sent as JSON, or as a form with
  `form: true` in `opts` (methods such as `files.getUploadURLExternal` do not
  accept JSON). Other options: `:timeout` (receive timeout, ms).

  Returns `{:ok, response_body}` for `ok: true`, else
  `{:error, %DeliveryError{}}`.
  """
  def call(channel, method, body, opts \\ []) do
    payload = if Keyword.get(opts, :form, false), do: [form: body], else: [json: body]

    options =
      [
        method: :post,
        url: @base_url <> method,
        headers: [{"authorization", "Bearer #{token(channel)}"}],
        receive_timeout: Keyword.get(opts, :timeout, 10_000),
        retry: false
      ]
      |> Keyword.merge(payload)
      |> Keyword.merge(req_options())

    options
    |> Converger.HTTP.request()
    |> handle_response(method)
  end

  @doc """
  Upload `data` to an upload URL returned by `files.getUploadURLExternal`
  (step two of Slack's `files.uploadV2` flow).
  """
  def upload_bytes(channel, upload_url, data, opts \\ []) do
    options =
      [
        method: :post,
        url: upload_url,
        body: data,
        headers: [
          {"authorization", "Bearer #{token(channel)}"},
          {"content-type", "application/octet-stream"}
        ],
        receive_timeout: Keyword.get(opts, :timeout, 30_000),
        retry: false
      ]
      |> Keyword.merge(req_options())

    case Converger.HTTP.request(options) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:error, DeliveryError.from_http(status, headers, body, "Slack file upload")}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "Slack file upload")}
    end
  end

  @doc """
  Download a private Slack file (`url_private_download`) with the bot token.
  Returns `{:ok, binary}` or `{:error, reason}`. Bodies larger than
  `:max_bytes` are refused.
  """
  def download(channel, url, opts \\ []) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)

    options =
      [
        method: :get,
        url: url,
        headers: [{"authorization", "Bearer #{token(channel)}"}],
        receive_timeout: Keyword.get(opts, :timeout, 5_000),
        retry: false,
        decode_body: false
      ]
      |> Keyword.merge(req_options())

    case Converger.HTTP.request(options) do
      {:ok, %Req.Response{status: 200, body: body}} when byte_size(body) <= max_bytes ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :too_large}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Whether a Slack `ok: false` error code is transient."
  def retryable_error?(error), do: error in @retryable_errors

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"ok" => true} = body}}, _method),
    do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"ok" => false} = body}}, method) do
    error = body["error"] || "unknown_error"
    reason = "Slack #{method} failed: #{error}"

    if retryable_error?(error),
      do: {:error, %DeliveryError{reason: reason, status: 200}},
      else: {:error, %DeliveryError{reason: reason, status: 200, retryable?: false}}
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, method),
    do: {:error, %DeliveryError{reason: "Slack #{method} returned #{inspect(body)}"}}

  defp handle_response(
         {:ok, %Req.Response{status: status, headers: headers, body: body}},
         method
       ),
       do: {:error, DeliveryError.from_http(status, headers, body, "Slack #{method}")}

  defp handle_response({:error, reason}, method),
    do: {:error, DeliveryError.from_transport(reason, "Slack #{method}")}

  defp token(channel), do: (Map.get(channel, :config) || %{})["bot_token"]

  defp req_options, do: Application.get_env(:converger, :slack_req_options, [])
end
