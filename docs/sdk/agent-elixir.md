---
title: Agent SDK for Elixir (converger_agent)
description: Write a Converger agent in Elixir - a supervised connection process serves every conversation of a channel over one channel-scoped WebSocket, with handle_turn, text and rich replies, tool-call traces, ask, reconnect and per-conversation watermarks.
sidebar_position: 9
---

# Agent SDK for Elixir

**Implemented (#67)**, published on [Hex](https://hex.pm/packages/converger_agent) from 0.1.0. `packages/agent-elixir` is the `converger_agent` package (Mint and
Mint.WebSocket, Jason). It has the same model and wire behaviour as the [Go agent SDK](agent-go.md): one
channel-scoped Protocol v1 connection
([section 10](../protocol/v1.md#10-channel-scoped-sockets-implemented-64-on-the-native-endpoint)) serves every
conversation routed to the agent's `websocket` channel.

## Install

```elixir
{:converger_agent, "~> 0.1"}
```

## Usage

```elixir
defmodule MyBot do
  use ConvergerAgent
  alias ConvergerAgent.Reply

  @impl true
  def handle_turn(%{text: "refund"}, reply) do
    with {:ok, answer} <-
           Reply.ask(reply, %{"title" => "Refund 249.90 TRY?"},
             actions: [%{label: "Yes", value: "yes"}, %{label: "No", value: "no"}]
           ) do
      Reply.text(reply, "You answered #{answer}.")
    end
  end

  def handle_turn(turn, reply) do
    Reply.typing(reply, true)
    Reply.text(reply, "You said: " <> turn.text, actions: [%{label: "Talk to a human", value: "/human"}])
  end

  @impl true
  def handle_error(error), do: Logger.warning(Exception.message(error))
end

children = [
  {MyBot,
   url: ConvergerAgent.socket_url("https://chat.example.com"),
   token: fn -> MyApp.channel_token() end,
   group: "faq-bot"}
]
```

The token is a channel-scoped token of the agent's `websocket` channel (`POST /api/v1/converger/tokens/generate`
with `{"scope": "channel"}`); a function or `{m, f, a}` is called on every connect. The functional form is
`ConvergerAgent.start_link(handler: fn turn, reply -> ... end, url: ..., token: ...)`.

| API | |
| --- | --- |
| options | `:url`, `:token`, `:handler`, `:on_error`, `:group`, `:user_id`, `:watermarks`, `:backoff_initial` / `:backoff_max` (ms, 500 / 30 000), `:ack_timeout` (30 000), `:headers`, `:name` |
| `ConvergerAgent.watermarks(agent)`, `ConvergerAgent.stop(agent)` | last seq seen per conversation; graceful stop |
| `%ConvergerAgent.Turn{}` | `conversation_id`, `id`, `seq`, `text`, `message` (`type`, `data`, `raw`), `participant`, `meta`, `metadata`, `action`, `reply_to`, `timestamp` |
| `Reply.text(reply, text, actions: [...])`, `Reply.message(reply, type, data)` | wait for the `ack`: `{:ok, %Ack{}}`, `{:error, %ConvergerAgent.Error{}}` or `{:error, :timeout}` |
| `Reply.ask(reply, payload, actions: ..., ui: ..., timeout: ...)` | `interrupt`, the user's answer, `interrupt_resolved`; `{:ok, answer}` |
| `Reply.tool_call/2`, `Reply.typing/2`, `Reply.send_frame/2`, `Reply.end_run/1` | tool trace, typing, raw frame, `run finished` now |

`handle_turn/2` returning `{:error, reason}`, raising, throwing or exiting ends the run with
`run {status: "error"}` and calls `handle_error/1`. Each turn runs in a task under the agent's
`Task.Supervisor`; the connection process keeps the per-conversation queues.

## Behaviour

Identical to the [Go SDK](agent-go.md#behaviour): runs framed by `run started` / `finished` / `error`, turns of
one conversation serialised (an `ask` answer is never queued), acked message sends re-sent with their
`clientId` after a reconnect, jittered backoff honouring `retryAfterMs`, `hello.watermarks` resume with
duplicates dropped, agent groups, and frames from the bot side never treated as turns. On 1008, 4400, 4403 or a
second consecutive 4401 the connection process calls `handle_error(%ConvergerAgent.CloseError{})` and stops
with `{:shutdown, {:closed, code, last_error}}`; its child spec is `restart: :transient`, so a supervisor does
not restart it.

## Tests and conformance

```bash
cd packages/agent-elixir && mix deps.get && mix test --warnings-as-errors
```

One ExUnit test per scenario of `packages/conformance/agent.json` runs against a Bandit + WebSock fake server,
and every agent frame is validated against the Protocol v1 schemas with JSV. The SDK was also run against a
local server: a widget user's turn and an `ask` answered with `resume` round-tripped.
