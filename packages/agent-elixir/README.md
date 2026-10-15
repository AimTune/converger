# ConvergerAgent

Elixir agent SDK for [Converger](https://converger.aimtune.dev): a bot backend that answers the conversations of a
Converger channel over one channel-scoped [Protocol v1](https://converger.aimtune.dev/protocol/v1) WebSocket
(`Mint.WebSocket`). It turns user messages into turns, runs your handler per turn, and takes care of acks, interrupts,
reconnects and per-conversation watermarks.

```elixir
def deps do
  # Not yet published on Hex; use a path or git dependency until then.
  [{:converger_agent, "~> 0.1"}]
end
```

Full documentation: [converger.aimtune.dev/sdk/agent-elixir](https://converger.aimtune.dev/sdk/agent-elixir).

## Quick start

```elixir
defmodule MyBot do
  use ConvergerAgent
  alias ConvergerAgent.Reply

  @impl true
  def handle_turn(%{text: "refund"}, reply) do
    with {:ok, "yes"} <-
           Reply.ask(reply, %{"title" => "Refund 249.90 TRY?"},
             actions: [%{label: "Yes", value: "yes"}, %{label: "No", value: "no"}]
           ) do
      Reply.text(reply, "Refund started.")
    end
  end

  def handle_turn(turn, reply), do: Reply.text(reply, "You said: " <> turn.text)

  # optional
  @impl true
  def handle_error(error), do: IO.warn(Exception.message(error))
end

children = [
  {MyBot,
   url: ConvergerAgent.socket_url("https://chat.example.com"),
   token: fn -> MyApp.channel_token() end,
   group: "workers"}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The token is channel-scoped (`POST /api/v1/converger/tokens/generate` with `{"scope": "channel"}`). It may be a
string, a 0-arity function or an `{m, f, a}` returning a token (or `{:ok, token}`); functions are called on every
connect, so an expired token can be replaced.

Without a module:

```elixir
ConvergerAgent.start_link(
  url: ConvergerAgent.socket_url("https://chat.example.com"),
  token: token,
  handler: fn turn, reply -> ConvergerAgent.Reply.text(reply, "Hi " <> turn.text) end,
  on_error: &IO.inspect/1
)
```

## API

- `ConvergerAgent.start_link/1`, `child_spec/1` (and the ones `use ConvergerAgent` injects). Options: `:url`,
  `:token`, `:handler`, `:on_error`, `:group`, `:user_id`, `:watermarks`, `:backoff_initial` / `:backoff_max` (ms,
  default 500 / 30 000), `:ack_timeout` (ms, default 30 000), `:connect_timeout`, `:shutdown_timeout` (ms, default
  5 000), `:headers`, `:name`.
- `ConvergerAgent.watermarks(server)`: the last seq seen per conversation; persist it and pass it as `:watermarks` to
  resume after a restart.
- `ConvergerAgent.stop(server)`: graceful stop (waits up to `:shutdown_timeout` for running handlers).
- `ConvergerAgent.socket_url(base_url)`: `https://h` becomes `wss://h/socket/converger/v1`.
- `%ConvergerAgent.Turn{conversation_id, id, seq, text, message: %{type, data, raw}, participant, meta, metadata,
  action, reply_to, timestamp}`.
- `ConvergerAgent.Reply` (call from the handler or any process it starts):
  - `text(reply, text, actions: [...])` and `message(reply, type, data)`: send a message with a `clientId`, wait for
    its ack: `{:ok, %ConvergerAgent.Ack{}}`, `{:error, %ConvergerAgent.Error{}}` (refused) or `{:error, :timeout}`.
  - `ask(reply, payload, actions: [...], ui: %{...}, timeout: :infinity)`: send an `interrupt`, wait for the
    user's answer, send `interrupt_resolved`, return `{:ok, answer}`.
  - `tool_call(reply, %{id, name, status, params, result, ...})`, `typing(reply, true)`, `send_frame(reply, frame)`
    (raw), `end_run(reply)`.

## Semantics

- **Turns.** A turn is a frame with `from: "user"`, an integer `seq` and a message type (not typing, presence,
  receipts, events, runs and other signals). Bot frames are never turns. Turns of one conversation run one at a time,
  in order (one task per busy conversation, under a `Task.Supervisor`); conversations run concurrently. An `ask`
  waits inside the handler while the next turn of that conversation stays queued.
- **Runs.** Around each handler the agent sends `run` `started`, then `finished` (unless `end_run/1` already did),
  or `error` when the handler returns `{:error, reason}`, raises, throws or exits; the failure is passed to
  `handle_error/1` as a `ConvergerAgent.HandlerError`.
- **Watermarks and duplicates.** Every frame with a `seq` advances the conversation's watermark; a frame at or below
  it is a replayed duplicate and is dropped. `hello` carries the watermarks, so the server replays what was missed.
- **Zero loss.** Message sends stay pending until their ack (or error) and are re-sent with the same `clientId`
  after a reconnect (stored exactly once). Other frames written while disconnected are kept and flushed after the
  next `welcome`, in original order; typing is dropped.
- **Reconnect.** Jittered exponential backoff; a close reason `{"retryAfterMs": n}` (1012, 4503) sets the delay.
  Close 4401 gets one immediate retry with a fresh token; a second 4401 in a row is terminal, as are 1008, 4400 and
  4403. A terminal close calls `handle_error/1` with a `ConvergerAgent.CloseError` and stops the process with
  `{:shutdown, {:closed, code, last_error}}`. `child_spec/1` uses `restart: :transient`, so the supervisor does not
  restart it; override the child spec if you want it restarted.
- **Errors.** Connection-level `error` frames, errors about a conversation and answers to unknown interrupts
  (`code: "unknown_interrupt"`) go to `handle_error/1` (or `:on_error`), which must not block.

## Testing

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors --force
mix test --warnings-as-errors
```

The tests run the shared conformance fixture (`packages/conformance/agent.json`) against an in-process Bandit fake
server and validate every frame the agent sends against the Protocol v1 JSON Schemas (`priv/protocol/v1`). Set
`CONVERGER_CONFORMANCE_DIR` / `CONVERGER_SCHEMA_DIR` to use other copies.
