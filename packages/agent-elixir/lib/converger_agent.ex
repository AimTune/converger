defmodule ConvergerAgent do
  @moduledoc """
  The Converger agent SDK: a bot backend that answers the conversations of a
  Converger channel over one channel-scoped Protocol v1 WebSocket
  (docs/protocol/v1.md, sections 9 and 10).

      defmodule MyBot do
        use ConvergerAgent
        require Logger

        @impl true
        def handle_turn(turn, reply) do
          ConvergerAgent.Reply.text(reply, "You said: " <> turn.text)
        end

        @impl true
        def handle_error(error), do: Logger.warning(Exception.message(error))
      end

      children = [
        {MyBot,
         url: ConvergerAgent.socket_url("https://chat.example.com"),
         token: fn -> MyApp.fetch_channel_token() end,
         group: "workers"}
      ]

  Or without a module:

      ConvergerAgent.start_link(
        url: ConvergerAgent.socket_url("https://chat.example.com"),
        token: token,
        handler: fn turn, reply -> ConvergerAgent.Reply.text(reply, "Hi") end
      )

  Turns of one conversation run one at a time, in order; turns of different
  conversations run concurrently, each in a task. Around each handler the
  agent sends `run` `started` and `finished` (or `error` when the handler
  returns `{:error, reason}`, raises, throws or exits).

  The connection reconnects with jittered exponential backoff and resumes every
  conversation from its watermark. When the server closes the connection with
  a code reconnecting cannot help (1008, 4400, 4401 twice in a row, 4403) the
  process stops with `{:shutdown, {:closed, code, last_error}}`; under a
  supervisor with `restart: :transient` (the default of `child_spec/1`) it is
  then not restarted.
  """

  alias ConvergerAgent.{Connection, Reply, Turn}

  @version Mix.Project.config()[:version]

  @doc "Answers one user turn. A returned `{:error, reason}` ends the run with status `\"error\"`."
  @callback handle_turn(Turn.t(), Reply.t()) :: term()

  @doc """
  Receives the errors no call returns: connection-level `error` frames and
  errors about a conversation (`ConvergerAgent.Error`), handler failures
  (`ConvergerAgent.HandlerError`), the terminal close
  (`ConvergerAgent.CloseError`), token function failures
  (`{:token, returned}`). It runs in the connection process (handler failures:
  in the turn's task) and must not block.
  """
  @callback handle_error(error :: term()) :: term()

  @optional_callbacks handle_error: 1

  @doc "The SDK version, sent in the user-agent header."
  def version, do: @version

  defmacro __using__(_opts) do
    quote do
      @behaviour ConvergerAgent

      @doc "A child spec starting this agent (`ConvergerAgent.start_link/1` options)."
      def child_spec(opts) do
        opts
        |> Keyword.put(:handler, __MODULE__)
        |> ConvergerAgent.child_spec()
        |> Map.merge(%{
          id: Keyword.get(opts, :id, __MODULE__),
          start: {__MODULE__, :start_link, [opts]}
        })
      end

      @doc "Starts this agent (`ConvergerAgent.start_link/1` options)."
      def start_link(opts), do: ConvergerAgent.start_link(Keyword.put(opts, :handler, __MODULE__))

      defoverridable child_spec: 1, start_link: 1
    end
  end

  @doc """
  The native endpoint URL for a server base URL
  (`https://h` becomes `wss://h/socket/converger/v1`).
  """
  @spec socket_url(String.t()) :: String.t()
  def socket_url(base_url) do
    uri = URI.parse(String.trim_trailing(base_url, "/"))
    scheme = %{"http" => "ws", "https" => "wss"}[uri.scheme] || uri.scheme
    URI.to_string(%{uri | scheme: scheme, path: (uri.path || "") <> "/socket/converger/v1"})
  end

  @doc """
  Starts an agent connection, linked to the caller.

  Options:

    * `:url` (required) - the native endpoint, see `socket_url/1`
    * `:token` (required) - a channel-scoped token
      (`POST /api/v1/converger/tokens/generate` with `{"scope": "channel"}`):
      a string, a 0-arity function or `{m, f, a}` returning a token or
      `{:ok, token}`, called on every connect so an expired token (close
      4401) can be replaced
    * `:handler` (required) - a module implementing `ConvergerAgent` or a
      2-arity function `fn turn, reply -> ... end`
    * `:on_error` - a 1-arity function receiving errors (see
      `c:handle_error/1`); overrides the module's `handle_error/1`
    * `:group` - join an agent group (`hello.group`)
    * `:user_id` - the sender of the agent's replies when the token has none
      (`hello.userId`)
    * `:watermarks` - `%{conversation_id => seq}` to resume from, as returned
      by `watermarks/1`
    * `:backoff_initial`, `:backoff_max` - reconnect backoff in ms (default
      500 and 30_000)
    * `:ack_timeout` - how long a message send waits for its ack (ms, default
      30_000)
    * `:connect_timeout` - TCP connect timeout (ms, default 10_000)
    * `:shutdown_timeout` - how long running handlers get to return when the
      agent stops (ms, default 5_000)
    * `:headers` - extra upgrade request headers (`[{name, value}]`)
    * `:name` - a process name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Connection.start_link(opts)

  @doc """
  A child spec for `start_link/1`, with `restart: :transient`: a terminal close
  (`{:shutdown, {:closed, code, last_error}}`) is not restarted.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: Keyword.get(opts, :shutdown_timeout, 5_000) + 1_000,
      type: :worker
    }
  end

  @doc """
  The last seq seen per conversation. Persist it and pass it as `:watermarks`
  to resume after a restart.
  """
  @spec watermarks(GenServer.server()) :: %{String.t() => integer()}
  def watermarks(server), do: GenServer.call(server, :watermarks)

  @doc """
  Stops the agent: waits for the sends and asks to fail with
  `{:error, :stopped}` and for running handlers to return (up to
  `:shutdown_timeout`), then closes the connection.
  """
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(server, timeout \\ :infinity), do: GenServer.stop(server, :normal, timeout)
end
