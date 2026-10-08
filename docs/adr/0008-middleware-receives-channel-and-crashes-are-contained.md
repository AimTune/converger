---
title: "ADR-0008: Middleware receives the channel, and middleware crashes are contained"
sidebar_label: "0008 Middleware contract"
description: Each middleware is called with the real Channel struct, and an exception inside a middleware halts the chain and dead-letters the delivery instead of crashing the job.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#8](https://github.com/AimTune/converger/issues/8) |
| **Pull request** | [#74](https://github.com/AimTune/converger/pull/74) |
| **Related** | [ADR-0002](0002-broadway-for-throughput-oban-for-retries.md), [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md) |

Every channel can carry a list of `transformations` (for example `add_prefix`, `truncate_text`, `content_filter`). Before an activity is handed to the channel's adapter, `Converger.Pipeline.Middleware.run/2` applies them in order. This ADR records the calling contract for middleware modules and what happens when one of them fails.

## Context and problem statement

The middleware behaviour is `call(activity, channel, opts)`, but `Middleware.run/2` called `module.call(acc_activity, config, config)`. Every middleware therefore received the transformation map where the behaviour promised a `%Channel{}`.

None of the built-in middleware reads the channel, so nothing failed visibly. Any custom middleware that does (a per-channel prefix, a per-channel template, a rule keyed on the channel type) would have raised or silently misbehaved.

The second problem was failure handling. An exception inside a middleware propagated straight to the caller. Under the Oban backend that meant the delivery job crashed, Oban retried it with backoff, and **the same deterministic bug crashed it again on every retry**, until the job ran out of attempts. The delivery record never got a meaningful `last_error`, and the operator saw only a stack of identical job errors.

## Decision drivers

- The implementation must match the documented behaviour.
- A bug in one transformation must not crash the delivery worker or the Broadway batch.
- Deterministic failures must not be retried; they should end in a visible terminal state with a descriptive error.
- Operators need a signal (telemetry) when a middleware crashes, including the stack trace.
- Tests and forks must be able to register their own middleware without editing core.

## Considered options

For the argument bug there was one sensible fix: pass the channel. For crash handling:

1. **Rescue and catch per middleware call, convert to a halt** - a crash becomes `{:halt, "middleware crashed: ..."}`, which the pipeline already dead-letters, plus telemetry.
2. **Let it crash** - rely on the Oban (or Broadway hand-off) retry policy to eventually give up.
3. **Rescue, log, and skip the failing middleware** - continue the chain without that transformation and deliver anyway.
4. **Run each middleware in a separate supervised task with a timeout** - isolate crashes and hangs at the process level.

### Pros and cons of the options

#### Option 1: Rescue and convert to halt

- Good: reuses the existing halt semantics: `Pipeline.deliver/2` dead-letters halts through `Deliveries.mark_dead/2` and does not retry them ([ADR-0002](0002-broadway-for-throughput-oban-for-retries.md)).
- Good: the delivery ends `failed` with a `last_error` that names the middleware and the exception.
- Good: no process overhead per call.
- Bad: a transient failure inside a middleware (one that calls out to another service) is also treated as permanent.
- Bad: does not protect against a middleware that hangs.

#### Option 2: Let it crash

- Good: no code.
- Bad: the observed failure mode: identical crashes until attempts run out, with no descriptive delivery error.

#### Option 3: Skip the failing middleware

- Good: the message still goes out.
- Bad: delivers an untransformed message. If the failing step was a `content_filter`, skipping it would deliver content the operator meant to block. Failing closed is safer.

#### Option 4: Supervised task per call

- Good: also covers hangs via timeouts.
- Bad: a process spawn and message copy for every middleware on every delivery, for a problem (pure functions over a map) that does not need process isolation today.

## Decision

Chosen option: **pass the real channel, and "rescue and catch per middleware call, convert to a halt"** (option 1). Middleware are, by design, deterministic functions of the activity, the channel and the options. A crash in such a function will recur on every retry, so retrying is wasted work, and delivering without the transformation could violate the operator's intent. Halting and dead-lettering fails closed, records why, and lets the operator fix the configuration and replay.

Specifically:

- `run/2` calls `module.call(acc_activity, channel, config)`.
- Each call goes through a private `safe_call/5` that uses `rescue` for exceptions and `catch` for throws and exits:
  - an exception becomes `{:halt, "middleware crashed: <type>: <Exception.message>"}`;
  - a throw or exit becomes `{:halt, "middleware crashed: <type>: <Exception.format_banner>"}`.
- A crash emits the `[:converger, :middleware, :exception]` telemetry event with measurements `%{count: 1}` and metadata `middleware`, `type`, `activity_id`, `channel_id`, `kind`, `reason` and `stacktrace`.
- `Pipeline.deliver/2` marks the halted delivery dead with `last_error` set to `halted: ` plus the reason, and returns `{:error, {:halted, reason}}`, which `Pipeline.retryable?/1` treats as terminal. The Oban worker cancels the job; Broadway marks the message failed without a retry hand-off.
- The middleware registry can be extended with `config :converger, :extra_middleware, %{"type" => Module}`, merged over the built-ins. This is how tests register test-only middleware, and how a fork can add its own without editing core.
- An unknown transformation type at run time is skipped; unknown types are rejected earlier by `validate_chain/1` in the channel changeset.

## Consequences

### Positive

- Custom middleware can rely on `%Channel{}` (name, type, config) as documented.
- A buggy transformation dead-letters only the affected deliveries, with a clear `last_error`, instead of crash-looping jobs.
- Crashes are observable through telemetry with full context.
- Middleware can be added through configuration.

### Negative and trade-offs

- A middleware that performs I/O and fails transiently is dead-lettered on the first failure, not retried. Middleware that need retries must return a value instead of raising, or the contract must grow a retryable result.
- Hanging middleware are not bounded by a timeout.
- `:extra_middleware` can override a built-in type with the same name, which is powerful but easy to misuse.

### Follow-ups

- Replaying dead-lettered deliveries after fixing a channel's transformations: [#32](https://github.com/AimTune/converger/issues/32).
- Per-rule transformations on routing rules will reuse this chain: [#43](https://github.com/AimTune/converger/issues/43).
- Telemetry dashboards and alerts that include `[:converger, :middleware, :exception]`: [#33](https://github.com/AimTune/converger/issues/33).

## Implementation

- [`Converger.Pipeline.Middleware`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline/middleware.ex): the behaviour (`call/3`, `validate_opts/1`), built-in `@registry`, `middleware_for/1`, `registered_types/0`, `run/2`, `safe_call/5`, `report_exception/7`, `validate_chain/1`.
- Built-in middleware in [`lib/converger/pipeline/middleware/`](https://github.com/AimTune/converger/tree/main/lib/converger/pipeline/middleware): `add_prefix`, `add_suffix`, `text_replace`, `truncate_text`, `set_metadata`, `content_filter`.
- [`Converger.Pipeline.deliver/2`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex): halts become `Deliveries.mark_dead/2`.

Tests: test-only middleware in [`test/support/middleware/`](https://github.com/AimTune/converger/tree/main/test/support/middleware): `ChannelNamePrefix` pattern-matches `%Channel{name: name}`, and `Crashing` raises `"boom"`. [`test/converger/pipeline/middleware_integration_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/pipeline/middleware_integration_test.exs) checks that a custom middleware receives the channel and prefixes text with `channel.name`, and that a crashing middleware leaves the delivery `failed` with `last_error` matching `middleware crashed: crashing: boom`, that `Pipeline.deliver/2` returns `{:error, {:halted, ...}}`, and that the telemetry event fires.

## Links

- Issue [#8](https://github.com/AimTune/converger/issues/8), pull request [#74](https://github.com/AimTune/converger/pull/74)
