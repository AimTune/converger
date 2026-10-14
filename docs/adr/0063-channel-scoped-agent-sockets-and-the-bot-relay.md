---
title: "ADR-0063: Channel-scoped agent sockets and the bot relay"
sidebar_label: "0063 Agent sockets and bot relay"
description: A channel-scoped token opens one native v1 connection that serves every routed conversation in {conversationId, frame} envelopes; bot channels are routing targets with a connected agent, and bot-only frames are relayed over PubSub.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-14 |
| **Issue** | [#64](https://github.com/AimTune/converger/issues/64), [#67](https://github.com/AimTune/converger/issues/67) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0046](0046-conditional-routing-rules-and-reply-back-routing.md), [ADR-0062](0062-typed-message-payloads-on-message-activities.md) |

## Context and problem statement

Protocol v1 specified channel-scoped sockets (section 10) and the bot relay (section 9) but left them
Planned. Without them an AI backend can only be a `webhook` (request/response, no streaming, no
interrupts), mekik cannot run behind Converger with Converger as the transcript (#64 Mode B), and the
agent SDKs of #67 have nothing to connect to. The end user's bot-only frames (`resume`,
`genui_event`, ...) were answered with `bot_unavailable`.

Three questions had to be settled: what a conversation's "bot channel" is, how one connection follows
thousands of conversations, and how several agent processes share a channel without answering one
turn twice.

## Decision drivers

- Reuse routing: which channel serves which conversation is already expressed by routing rules and
  reply-back routing (ADR-0046).
- One transcript and one `seq`: the agent's frames are stored like any message (ADR-0062).
- Work across nodes without new infrastructure.
- No duplicate replies when several agent processes connect.

## Considered options

1. **Bot channel = routing target with a connected agent; a channel-scoped native session that
   follows conversations on demand; `:pg` groups with rendezvous hashing for sharing.**
2. **A per-conversation "bot channel" setting** on the conversation or channel config.
3. **Sticky assignment stored in the database** (a conversation → connection table).

### Pros and cons of the options

#### Option 1

- Good, because no new configuration: a `websocket` channel routed from WhatsApp and a connected agent
  is the whole setup, and the same rules already route replies back.
- Good, because `:pg` and Phoenix PubSub already span the cluster.
- Bad, because membership changes move conversations between members (only those of the member that
  came or went), and during a membership change two members may briefly both serve a conversation.

#### Option 2

- Good, because it is explicit.
- Bad, because it duplicates what routing rules say, and goes stale when rules change.

#### Option 3

- Good, because assignments survive restarts.
- Bad, because every turn needs a database lookup, and dead connections must be reaped.

## Decision

Chosen option: **"Option 1"**.

- `ConvergerWeb.Protocol.ChannelSession` runs inside the native `Session` when the token has
  `scope: "channel"` and no conversation. The token's channel must be a `websocket` channel.
  - Conversations are followed when they are listed in `hello.watermarks`, when something is delivered
    for them to the channel, or when the agent sends a frame for them.
  - Access is the Phoenix binding's rule, now `ConvergerWeb.Protocol.Access`: the conversation is
    owned (of this channel) or routed (a rule targets this channel from its channel).
  - Owned conversations receive every committed activity. Routed ones receive the pipeline's
    deliveries, already through the channel's middleware; replays and gap fills go through
    `Pipeline.transform/2` (the feed's `prepare` hook).
  - At most `max_conversations` are followed (least recently active evicted with
    `too_many_subscriptions`).
- From the agent's view `from` is `user` for activities that came in on the conversation's origin
  channel, so the canonical activity now carries `source_channel_id`.
- Agent frames are stored through `Converger.Inbound` with the agent's channel as source, so
  reply-back routing delivers them. A message `id` is kept, and the idempotency key
  (`bot:<sender>:<conversation>:<clientId>`) names the conversation, because mekik numbers
  `msg-1, msg-2, ...` per conversation.
- `ConvergerWeb.Protocol.BotRelay`:
  - **Bot channels:** a conversation's bot channels are the active targets of enabled rules from its
    origin channel that are `websocket` channels with a channel-scoped connection
    (`ConvergerWeb.Sockets.count_agents/1`), or whose adapter has the `:bot_relay` capability (the
    mekik adapter).
  - **To the bot:** forwarded frames and a turn's `meta` are broadcast on the channel topic as
    `bot_frame` and `turn_meta`. The meta goes ahead of the turn, keyed by its idempotency key.
  - **To the end users:** transient bot frames are broadcast on the conversation topic as
    `bot_transient`.
  - **Interrupt answers:** a delivered user turn whose `replyTo` names an open interrupt becomes
    `resume`.
- `hello.group` joins the `:pg` group `{channel_id, group}` (scope `ConvergerWeb.Protocol.AgentGroups`).
  Every member computes the owner of a conversation as the member with the highest
  `phash2({conversation_id, pid})`, and only the owner delivers.

## Consequences

### Positive

- A mekik server, a LangChain agent or a human console serves WhatsApp, Telegram and web users
  through one socket. The SDKs of #67 and mekik's transport (mekik#47) build on it.
- Agent processes scale horizontally behind one channel.

### Negative and trade-offs

- A bot's `error` frames reach every connection of the conversation, not only the one whose frame
  caused it (the bot does not say which).
- Owned conversations are discovered only when listed, delivered or written to; a console finds the
  rest over REST.
- Group membership is eventually consistent across nodes.
- The canonical activity gains `source_channel_id` (tenant API, outbound webhooks, PubSub broadcast).

### Follow-ups

- [#64](https://github.com/AimTune/converger/issues/64) Mode A: the `mekik` adapter (`:bot_relay`) dials a
  mekik server per conversation.
- [#67](https://github.com/AimTune/converger/issues/67): the agent SDKs.

## Implementation

- `lib/converger_web/protocol/channel_session.ex`, `bot_relay.ex`, `access.ex`; `session.ex`
  (mode `:channel`, forwarding, `bot_transient`, `meta`); `feed.ex` (`prepare`); `frames.ex`
  (`channel_welcome/1`, `envelope/2`, agent viewer); `converger_channel.ex` (forwarding and relay on the
  Phoenix binding).
- `ConvergerWeb.Sockets.count_agents/1`, `Converger.Activities.interrupt_open?/2`, the `:pg` scope in
  `Converger.Application`, `max_conversations` in `ConvergerWeb.Protocol`.
- Schemas: `frames/channel/agent-frame.schema.json` (new), the client and server envelopes, `hello.group`.
- Tests: `test/converger_web/protocol_channel_session_test.exs` over a real socket, every frame
  validated against the schemas.

## Links

- [Converger Protocol v1](../protocol/v1.md), sections 9 and 10
- [WebSocket channel type](../channels/websocket.md)
