defmodule Converger.Channels.MediaDownload do
  @moduledoc """
  Bounded download of provider media (inbound WhatsApp images, voice notes,
  documents). The body is streamed and the request is stopped as soon as it
  exceeds the upload size limit (`Converger.Uploads.max_file_size/0`), so a
  large file never sits in memory whole.

  Timeout: `config :converger, Converger.Channels.MediaDownload,
  timeout_ms: 10_000` (default). Tests inject Req options through
  `config :converger, :whatsapp_req_options`.
  """

  alias Converger.Uploads

  @default_timeout_ms 10_000

  @doc "Per-request receive timeout of media downloads, in milliseconds."
  def timeout_ms do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:timeout_ms, @default_timeout_ms)
  end

  @doc """
  `GET url` with `options` (headers etc.). Returns `{:ok, binary}`,
  `{:error, :too_large}`, `{:error, {:http_error, status}}` or
  `{:error, reason}`.
  """
  def get(url, options) do
    max = Uploads.max_file_size()

    collect = fn {:data, data}, {req, resp} ->
      size = Req.Response.get_private(resp, :converger_size, 0) + byte_size(data)

      resp =
        resp
        |> Req.Response.put_private(:converger_size, size)
        |> Req.Response.update_private(:converger_chunks, [data], &[data | &1])

      if size > max, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}
    end

    options =
      [receive_timeout: timeout_ms(), retry: false, into: collect, decode_body: false]
      |> Keyword.merge(options)
      |> Keyword.merge(Application.get_env(:converger, :whatsapp_req_options, []))

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200} = resp} ->
        if Req.Response.get_private(resp, :converger_size, 0) > max do
          {:error, :too_large}
        else
          chunks = Req.Response.get_private(resp, :converger_chunks, [])
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
