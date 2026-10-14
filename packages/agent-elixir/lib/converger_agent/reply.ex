defmodule ConvergerAgent.Reply do
  @moduledoc """
  Sends the agent's frames into the conversation of one turn.

  A reply is handed to `c:ConvergerAgent.handle_turn/2`. Its functions talk to
  the connection process, so they may be called from the handler's process or
  from any process it starts. Every function returns `{:error, :stopped}` once
  the agent has stopped; sends and asks still waiting when the server closes
  the connection for good return `{:error, %ConvergerAgent.CloseError{}}`.

  Message sends (`text/3`, `message/3`) carry a `clientId` and wait for the
  server's `ack`: they survive reconnects (re-sent with the same `clientId`,
  stored exactly once). Other frames are written without an ack; while
  disconnected they are kept and written after the next `welcome`, except
  typing, which is dropped.
  """

  alias ConvergerAgent.{Ack, Error}

  @enforce_keys [:conn, :conversation_id, :run]
  defstruct [:conn, :conversation_id, :run]

  @type t :: %__MODULE__{conn: GenServer.server(), conversation_id: String.t(), run: reference()}

  @typedoc "A chip or button: `value` omitted means the answer is the label."
  @type action :: %{
          required(:label) => String.t(),
          optional(:value) => term(),
          optional(:url) => String.t()
        }

  @doc """
  Sends a text message and waits for its ack.

  Options: `:actions`, a list of quick-reply chips (`t:action/0`, atom or
  string keys), sent as the frame's `actions`.
  """
  @spec text(t(), String.t(), keyword()) ::
          {:ok, Ack.t()} | {:error, Error.t() | :timeout | :stopped}
  def text(%__MODULE__{} = reply, text, opts \\ []) when is_binary(text) do
    frame = %{"type" => "text", "data" => %{"text" => text}}

    frame =
      case opts[:actions] do
        list when is_list(list) and list != [] -> Map.put(frame, "actions", actions(list))
        _ -> frame
      end

    send_message(reply, frame)
  end

  @doc """
  Sends a message of any type (`buttons`, `quick-reply`, `card`, `carousel`,
  `image`, `file`, ... see docs/protocol/messages.md) and waits for its ack.
  """
  @spec message(t(), String.t(), map()) ::
          {:ok, Ack.t()} | {:error, Error.t() | :timeout | :stopped}
  def message(%__MODULE__{} = reply, type, data) when is_binary(type) and is_map(data),
    do: send_message(reply, %{"type" => type, "data" => data})

  defp send_message(reply, frame) do
    client_id = "agent-" <> random_id()
    call(reply.conn, {:send, reply.conversation_id, Map.put(frame, "clientId", client_id)})
  end

  @doc """
  Sends an interrupt and waits for the user's answer (a tapped button, a chip
  or a `resume` frame), then marks the interrupt resolved. The answer is the
  action's value (any JSON value), else its label or the user's text.

  The next turn of the conversation waits until the handler returns.

  Options: `:actions` (`t:action/0`), `:ui` (a GenUI component rendering the
  question: `%{"component" => ..., "props" => ...}`), `:timeout` (ms, default
  `:infinity`; `{:error, :timeout}` when no answer arrived in time).
  """
  @spec ask(t(), term(), keyword()) :: {:ok, term()} | {:error, :timeout | :stopped}
  def ask(%__MODULE__{} = reply, payload, opts \\ []) do
    data =
      %{"payload" => if(is_nil(payload), do: %{}, else: payload)}
      |> put_if("actions", nonempty(opts[:actions]) && actions(opts[:actions]))
      |> put_if("ui", opts[:ui])

    timeout = Keyword.get(opts, :timeout, :infinity)

    with {:ok, id, answer} <-
           call(reply.conn, {:ask, reply.run, reply.conversation_id, data, timeout}),
         :ok <-
           send_frame(reply, %{
             "type" => "interrupt_resolved",
             "id" => id,
             "data" => %{"answer" => answer}
           }) do
      {:ok, answer}
    end
  end

  @doc """
  Sends a `tool_call` frame (stored, upserted by `id` on the client as it
  advances `running` -> `completed` / `error`).

  Keys (atoms or strings): `id`, `name`, `status`, and optionally
  `description`, `params`, `result`, `error`, `started_at`, `ended_at`. Nil
  values are left out.
  """
  @spec tool_call(t(), map()) :: :ok | {:error, :stopped}
  def tool_call(%__MODULE__{} = reply, call) when is_map(call) do
    data =
      for {k, v} <- call, not is_nil(v), into: %{} do
        {camel(to_string(k)), v}
      end

    send_frame(reply, %{"type" => "tool_call", "data" => data})
  end

  @doc "Starts or stops the typing indicator (dropped while disconnected)."
  @spec typing(t(), boolean()) :: :ok | {:error, :stopped}
  def typing(%__MODULE__{} = reply, on?) when is_boolean(on?),
    do: send_frame(reply, %{"type" => "typing", "isTyping" => on?})

  @doc """
  Writes a raw agent frame (frames/channel/agent-frame.schema.json) with
  string keys, without waiting for an ack.
  """
  @spec send_frame(t(), map()) :: :ok | {:error, :stopped}
  def send_frame(%__MODULE__{} = reply, frame) when is_map(frame),
    do: call(reply.conn, {:frame, reply.conversation_id, frame})

  @doc """
  Finishes the run now (`run` `"finished"`); later calls are no-ops. It is
  called for you when the handler returns.
  """
  @spec end_run(t()) :: :ok | {:error, :stopped}
  def end_run(%__MODULE__{} = reply), do: call(reply.conn, {:end_run, reply.run, "finished"})

  @doc false
  def call(conn, request) do
    GenServer.call(conn, request, :infinity)
  catch
    :exit, _ -> {:error, :stopped}
  end

  @doc false
  def random_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp actions(list) do
    for action <- list do
      for {k, v} <- action, not is_nil(v), into: %{}, do: {to_string(k), v}
    end
  end

  defp nonempty([_ | _]), do: true
  defp nonempty(_), do: false

  defp camel("started_at"), do: "startedAt"
  defp camel("ended_at"), do: "endedAt"
  defp camel(key), do: key

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, false), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
