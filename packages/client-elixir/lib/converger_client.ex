defmodule ConvergerClient do
  @moduledoc """
  Elixir client for [Converger](https://converger.aimtune.dev).

    * `ConvergerClient.ClientAPI` - the client API (`/api/v1/converger`, converger tokens)
    * `ConvergerClient.TenantAPI` - the tenant API (`/api/v1`, `x-api-key`)
    * `ConvergerClient.Socket` - Protocol v1 WebSocket client with resume
    * `ConvergerClient.Webhook` - outbound webhook signature verification

      client = ConvergerClient.new("https://chat.example.com", api_key: "cvg_live_...", channel_secret: "...")
      {:ok, token} = ConvergerClient.ClientAPI.generate_token(client, user_id: "user-42")
      {:ok, conv} = ConvergerClient.ClientAPI.create_conversation(client, token.token)
      {:ok, activity} = ConvergerClient.TenantAPI.post_activity(client, conv.conversation_id, %{sender: "bot", text: "Hi!"})

  Every call returns `{:ok, struct}` or `{:error, %ConvergerClient.Error{}}`
  (or `{:error, exception}` for transport failures).
  """

  @version Mix.Project.config()[:version]

  defstruct [:base_url, :api_key, :channel_secret, req_options: []]

  @type t :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t() | nil,
          channel_secret: String.t() | nil,
          req_options: keyword()
        }

  @doc """
  Creates a client.

  Options: `:api_key` (tenant API key), `:channel_secret` (for
  `ClientAPI.generate_token/2`), `:req_options` (merged into every `Req`
  request, for example `plug:` in tests or `receive_timeout:`).
  """
  @spec new(String.t(), keyword()) :: t()
  def new(base_url, opts \\ []) do
    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      api_key: opts[:api_key],
      channel_secret: opts[:channel_secret],
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @doc false
  def version, do: @version

  @doc false
  # Performs a request and decodes a 2xx JSON body; errors are normalized.
  def request(%__MODULE__{} = client, method, path, opts) do
    headers = [{"accept", "application/json"}, {"user-agent", "converger-elixir/#{@version}"}]

    req_opts =
      [
        method: method,
        url: client.base_url <> path,
        headers: headers ++ Keyword.get(opts, :headers, []),
        params: Keyword.get(opts, :params, []),
        retry: false,
        decode_body: false
      ]
      |> then(fn o ->
        if Keyword.has_key?(opts, :json), do: Keyword.put(o, :json, opts[:json]), else: o
      end)
      |> Keyword.merge(client.req_options)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, decode(body)}

      {:ok, %Req.Response{status: status, headers: resp_headers, body: body}} ->
        {:error,
         ConvergerClient.Error.from_response(status, resp_headers, IO.iodata_to_binary(body))}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp decode(""), do: nil
  defp decode(body) when is_binary(body), do: Jason.decode!(body)
  defp decode(body), do: body

  @doc false
  def compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  @doc false
  def params(kw),
    do:
      kw
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)

  @doc false
  def seg(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
