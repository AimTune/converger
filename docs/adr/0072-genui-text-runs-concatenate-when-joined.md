---
title: "ADR-0072: GenUI text runs concatenate when a stream is joined for a channel"
sidebar_label: "0072 GenUI text runs"
description: When a GenUI stream is joined into one message for a channel without GenUI, text chunks that share a chunk id are concatenated deltas (a text run, as mekik streams them and chativa renders them), not successive versions of one element.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-15 |
| **Issue** | [#67](https://github.com/AimTune/converger/issues/67) |
| **Pull request** | (this PR) |
| **Related** | Supersedes the `genui` joining rule of [ADR-0064](0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md); [ADR-0065](0065-chativa-as-reference-client-and-history-cursor.md), [ADR-0067](0067-agent-sdk-api-and-wire-mapping.md) |

## Context and problem statement

[ADR-0064](0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md) sends a `genui` stream to a channel
without GenUI (WhatsApp, Telegram, email, SMS) as one text message when the stream is `done`: "the latest content of
each `text` chunk of the stream (a chunk id seen again replaces its element)".

Token streams do not work that way. A mekik server sends every token delta of a text run with the **same** chunk id
(mekik PROTOCOL.md 4.1, "consecutive text deltas share one chunk id: one growing bubble"), the TypeScript agent SDK
does the same ([ADR-0067](0067-agent-sdk-api-and-wire-mapping.md): "one chunk id per stream"), and chativa, the
reference client ([ADR-0065](0065-chativa-as-reference-client-and-history-cursor.md)), concatenates same-id text
deltas into one bubble. With the replace rule, a WhatsApp user received only the **last delta** of a streamed answer.
The live check of [#67](https://github.com/AimTune/converger/issues/67)'s first acceptance criterion
(`examples/agents/langchain-faq` behind a WhatsApp channel) showed it: the web widget streamed "Orders ship within 1
business day and arrive in 2-4 business days.", WhatsApp got "business days.". The existing tests used a single chunk
or cumulative contents, so they did not see it.

## Decision drivers

- A channel without GenUI must get the same text a web user sees.
- One wire meaning for `text` chunks, the one existing producers (mekik, the agent SDKs) and the reference client use.
- No change for streams whose text chunks all have distinct ids.

## Considered options

1. **Concatenate same-id text chunks** (a text run) when joining.
2. **Keep replace semantics** and require producers to resend the cumulative text under the same id.
3. **Require a distinct id per delta** and join every chunk without separators.

### Pros and cons of the options

#### Option 1

- Good, because it matches mekik, the TypeScript and Python agent SDKs and chativa's rendering.
- Good, because streams with distinct ids per text element join exactly as before.
- Bad, because a producer that meant "replace" by resending cumulative text under the same id would see the text
  repeated; none does (chativa would show the repetition on the web too).

#### Option 2

- Good, because the ADR-0064 code stays.
- Bad, because every token stream would cost quadratic bytes on the wire and in storage, and mekik servers and
  chativa would both have to change.

#### Option 3

- Good, because joining stays a plain concatenation.
- Bad, because chativa opens one bubble per chunk id, so a web user would see one bubble per token.

## Decision

Chosen option: **"Concatenate same-id text chunks"**. When a stream is `done`, `Converger.Activities.Downgrade` reads
its stored payloads in `seq` order, groups `text` chunks by chunk id in order of first appearance, concatenates each
group's contents (a text run), trims each run, drops empty runs and joins the runs with blank lines. The `done`
payload, which is already stored when the delivery is planned, is counted once. `ui` and `event` chunks are still
never sent.

## Consequences

### Positive

- Streamed answers from mekik, the agent SDKs and LangChain graphs reach WhatsApp, Telegram, email and SMS whole.
- The joined text equals the bubbles chativa shows.

### Negative and trade-offs

- `text` chunks are deltas, never replacements: a producer that wants to correct text it already streamed must send
  a new run (a new chunk id) or a separate message.

### Follow-ups

- None.

## Implementation

- `Converger.Activities.Downgrade` (`genui_text/1`, `collect_text_chunk/2`).
- The Python agent SDK sends one chunk id per text run and closes streams with a `stream_done` event chunk, like the
  TypeScript SDK (`packages/agent-python/src/converger_agent/turn.py`).
- Tests: `test/converger/activities/typed_message_test.exs` (a run of deltas, a `done` chunk carrying the last
  delta) and the live check `test/acceptance/langchain_faq_live_test.exs` (tag `:langchain_faq`).

## Links

- [Message types, sections 3 and 5](../protocol/messages.md)
- [Python agent SDK, streams](../sdk/agent-python.md#streams)
