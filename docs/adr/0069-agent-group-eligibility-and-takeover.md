---
title: "ADR-0069: Agent group eligibility times and takeover of passed turns"
sidebar_label: "0069 Agent group eligibility and takeover"
description: An agent group member owns the user turns committed after its published eligibility time (join plus a settle delay), and on a member's departure the new owner receives the unanswered turns that were passed to it, so a membership change neither duplicates nor loses a turn.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-14 |
| **Issue** | [#67](https://github.com/AimTune/converger/issues/67) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0063](0063-channel-scoped-agent-sockets-and-the-bot-relay.md), [ADR-0067](0067-agent-sdk-api-and-wire-mapping.md), [ADR-0037](0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md) |

## Context and problem statement

ADR-0063 shares a channel's conversations among the connections of an agent group (`hello.group`): every member
receives every turn delivered to the channel and delivers it only if it is the rendezvous-hash winner over the
current `:pg` members. #67 requires that "a second agent process joining the same channel takes over conversations
without duplicate replies". Two windows broke that while the membership changed:

- **Join (duplicates).** Each member read `:pg` when it processed a turn. A turn committed just before a new member
  joined could be processed by the old owner before the join was visible to it (it delivered) and by the new member
  after (it won the hash and delivered too). Across nodes `:pg` propagation widens the window to milliseconds.
- **Leave (loss).** A member whose connection died stays in `:pg` until the scope's monitor fires (on another node,
  until the leave is propagated or the node is declared down). A turn committed meanwhile was passed by every live
  member to the dead one: delivered to nobody. A turn the departed member had received but not answered was lost to
  the agent as well.

ADR-0063 accepted that "two members may briefly both serve a conversation"; for an agent that answers with an LLM
that is a duplicate reply to the end user.

## Decision drivers

- No duplicate delivery of a turn when a member joins, on one node or across nodes.
- No turn delivered to nobody when a member leaves or dies, and no turn answered twice because of the takeover.
- No coordination round trip per turn and no new infrastructure (no database table, no leader).
- Membership changes keep moving only the conversations of the member that came or went (rendezvous hashing).

## Considered options

1. **Eligibility times published with the member, decided against the turn's commit time, plus takeover of passed
   turns on leave.**
2. **Sticky assignment in the database** (conversation to member), claimed by the first member that sees a turn.
3. **Leader-assigned ownership** (one `:global` process per group that assigns conversations).

### Pros and cons of the options

#### Option 1

- Good, because every member decides the owner of a turn from the same numbers (the turn's `inserted_at` and each
  member's published eligibility time), whenever it processes the turn, so a join cannot make two members deliver it.
- Good, because the decision stays local and costs nothing per turn.
- Bad, because a new member serves nothing for the settle delay, and correctness of the join depends on `:pg`
  propagating within that delay.
- Bad, because the takeover's "unanswered" is a transcript heuristic (no bot or agent frame after the turn).

#### Option 2

- Good, because assignments survive restarts and are exact.
- Bad, because every turn needs a write, and a dead member's claims must be reaped (the loss problem moves to the
  reaper).

#### Option 3

- Good, because there is one decision maker.
- Bad, because it adds a round trip per new conversation and a single point that must fail over (netsplits).

## Decision

Chosen option: **"Option 1"**, because it removes the duplicate window and closes the loss window without adding work
per turn.

- **Eligibility.** On `hello.group` a connection picks `since = now + group_settle_ms` (default 1000) and joins the
  `:pg` group `{:since, {channel_id, group}, pid, since}` before the group `{channel_id, group}` itself; the scope
  applies joins in order, so whoever sees the member can look its `since` up (`:pg.which_groups/1`). It then monitors
  the group (`:pg.monitor/2`) and keeps its own view of the members and their `since`.
- **Owner of a turn.** Among the members whose `since` is at or before the turn's `inserted_at`, the one with the
  highest `phash2({conversation_id, pid})`; when no member is eligible yet (a group that just started), every member
  counts. Frames that are not turns (a forwarded `resume`, the replay of `hello.watermarks`) use the current time.
- **Passed turns.** A member that does not own a turn remembers it per conversation: the owner and the first passed
  `seq` (at most `max_conversations` entries, oldest dropped).
- **Takeover.** When members leave, each remaining member takes the conversations it passed to them and now owns (the
  owner decided at the time of the last passed turn, as every member decides it): it follows the conversation and
  receives the user turns after the first passed one that no bot or agent frame follows (the trailing `from: user`
  frames). A turn the departed member answered is not delivered again.
- A member that is no longer the owner keeps sending: its in-flight answer to a conversation that moved is stored as
  usual.

## Consequences

### Positive

- A second agent process joining takes only turns committed after it became eligible, so a turn already being
  answered by the first is never delivered to it; a process that leaves or dies hands its unanswered turns to exactly
  one remaining member. Tested over real sockets and on two nodes (`test/cluster`).
- No change to the wire protocol: agents see ordinary user turns.

### Negative and trade-offs

- A new member serves nothing for `group_settle_ms`.
- If `:pg` takes longer than the settle delay to propagate a join to another node, a turn in that window can still be
  delivered twice. Clock skew between nodes shifts the effective delay (every member compares the same two numbers,
  so it does not make members disagree).
- A netsplit is indistinguishable from a departure: both sides may answer the turns they consider unanswered.
- The takeover covers turns the remaining member saw passing: routed conversations always, owned conversations (the
  agent channel is the conversation's own channel) only while followed. A forwarded `resume` passed to a dead member
  is not taken over; the end user answers again.
- Replayed turns carry `meta.channel` and `meta.participant` but not a relayed mekik `meta`, which lives only in the
  memory of the connections that saw the turn live.
- Ownership is per connection: an agent that reconnects is a new member and starts a new settle delay.

### Follow-ups

- None planned.

## Implementation

- `ConvergerWeb.Protocol.GroupMembership` (join with the since group, `:pg.monitor/2`, eligibility lookup, `owner/3`,
  `serves?/3`), used by `ConvergerWeb.Protocol.ChannelSession` (`pass/4`, `take_over/2`, `handle_group/2`) and
  `ConvergerWeb.Protocol.Session` (the monitor messages).
- `group_settle_ms` under `config :converger, ConvergerWeb.Protocol` (`ConvergerWeb.Protocol.config/1`); 100 ms in
  `config/test.exs`.
- Tests: `test/converger_web/protocol_agent_groups_test.exs` (affinity, takeover of an unanswered turn, no
  redelivery of an answered one, the dead-but-listed member gap, join during and after the settle delay, `busy`
  relayed to the end user) and the agent group test of `test/cluster/multi_node_test.exs` (one member per node).

## Links

- [Converger Protocol v1, section 10](../protocol/v1.md#10-channel-scoped-sockets-implemented-64-on-the-native-endpoint)
- [Agent SDK, groups](../sdk/agent.md#groups)
- [`:pg`](https://www.erlang.org/doc/apps/kernel/pg.html)
