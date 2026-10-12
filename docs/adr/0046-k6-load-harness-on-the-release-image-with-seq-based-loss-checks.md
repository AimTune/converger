---
title: "ADR-0046: k6 load harness on the release image, with seq-based loss checks and a nightly regression gate"
sidebar_label: "0046 Load harness"
description: Performance is measured end to end with k6 against the production release in Docker Compose (1 or 3 nodes), lost messages are detected from per-conversation seq on every subscriber, results are published as markdown under docs/benchmarks, and a nightly job fails on a p95 regression beyond 15 % against a baseline recorded on the same runner.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#34](https://github.com/AimTune/converger/issues/34) |
| **Pull request** | to be opened |
| **Related** | [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0027](0027-websocket-limits-backpressure-and-draining.md), [ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md), [ADR-0037](0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md) |

## Context and problem statement

The only performance test was `test/load/performance_test.exs`, which called `Activities.create_activity/1`
in-process. It measured database inserts, not the system: no HTTP, no WebSocket, no adapters, no network. The
README's "5,200 msgs/sec" came from it. There was no reproducible way to check the PRD targets (1 000 concurrent
WebSocket clients, p95 below 250 ms end to end) or to notice a regression.

Issue #34 asks for k6 scenarios (REST → WebSocket latency, 10 000 idle sockets, inbound webhook burst, reconnect
storm with watermark replay), a mock provider, a nightly job with a regression threshold, and published numbers. The
follow-up comment widens it to a matrix: 1 and 3 nodes, the Elixir-native and Kafka backbones (#66), a rolling
restart scenario, per-node CPU and RSS, DB pool wait, Oban queue depth, recovery time after a node kill, and **lost
acked messages, which must be 0**, with the hardware recorded so runs can be compared.

## Decision drivers

- Measure what users see: real HTTP and WebSocket clients against the production release, not internal calls.
- Detect lost messages exactly, not by comparing approximate counters.
- Run the same way on a developer machine (Windows with Docker Desktop, Git Bash) and in GitHub Actions.
- Numbers are only comparable on the same hardware, so the hardware is part of every result.
- No new runtime dependency for Converger, and nothing to install on the host besides Docker.

## Considered options

1. **k6 in Docker against the release image in Docker Compose**, with a Node.js mock provider, orchestrated by a
   bash script modelled on the chaos harness (`test/chaos`).
2. **An Elixir load generator** (a Mix task or a separate OTP app with Mint/`Req` and a WebSocket client).
3. **Hosted load testing** (Grafana Cloud k6, or a cluster of load generators on a cloud provider).

### Pros and cons of the options

#### Option 1: k6 in Docker

- Good, because k6 is a standard tool with HTTP, WebSocket (`k6/websockets`, an event loop per VU so one VU can hold
  hundreds of sockets), HMAC signing, thresholds and arrival-rate executors, so the scenarios are short.
- Good, because the pinned `grafana/k6` image needs nothing on the host, and the chaos harness already shows that a
  compose-based harness runs on Windows and Linux CI.
- Bad, because k6 metrics are per run; anything measured outside k6 (RSS, Oban depth, delivery latency at the
  provider) needs its own sampling and a separate merge step.

#### Option 2: an Elixir load generator

- Good, because it reuses the codebase's language and could share the protocol code.
- Bad, because a generator in the same language and runtime as the system under test tends to share its blind
  spots, and it is more code to write and maintain than k6 scripts.

#### Option 3: hosted load testing

- Good, because it scales beyond one machine.
- Bad, because it costs money, needs credentials in CI, and runs on hardware we do not control or record.

## Decision

Chosen option: **"k6 in Docker against the release image"**, because it measures the real system with standard,
pinned tooling, needs only Docker, and follows a pattern the project already runs in CI.

Details of the decision:

- **Scenarios** (`load/*.js`): `e2e` (REST → WebSocket fan-out), `webhook_burst` (signed inbound webhooks routed to
  three outbound channels), `idle` (10 000 idle sockets), `reconnect_storm` (every socket drops and resumes at
  once), `rolling_restart` (each node restarted with SIGTERM under load), `node_kill` (one node SIGKILLed under
  load). Clients use the native Protocol v1 endpoint, the recommended one.
- **Loss detection by `seq`.** Every subscriber socket is read-only and must end with every `seq` of its conversation
  up to the head it learns from a final `ping`/`heartbeat`. Everything above its last contiguous `seq` is a lost
  acked message, and a frame repeated outside a resync is a duplicate. Like a real client, it recovers holes the
  server reports it could not replay under database pressure (`replay_unavailable`, ADR-0044) with `sync`; those
  are reported, not counted as loss. This is exact because `seq` is gap-free per conversation
  ([ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)) and the server already fills gaps and drops
  duplicates per connection, so a correct server shows zero. Senders retry with the same idempotency key until
  acked, as the chaos harness does, so restarts do not count as loss. For webhook deliveries, the harness compares
  what was accepted, what Postgres stored and what the mock provider received on each target.
- **Mock provider in Node.js**, not the "small Bandit app" the issue suggested: it needs no build step or Hex
  download, starts in the stock `node:22-alpine` image like the chaos sink, and measures delivery latency from a
  timestamp in the message text.
- **Resources** are sampled outside k6 every second: `docker stats` per node, open Oban jobs from Postgres, and
  `converger_repo_query_queue_time` from each node's `/metrics`.
- **Results** are one `results.json` per run (one topology) and a markdown report. `load/report.js` merges runs into
  the page published under `docs/benchmarks/`, and the README links to the latest one instead of hardcoding numbers.
- **Regression gate.** The nightly `Load` workflow runs 1 and 3 nodes on a fixed runner image (`ubuntu-24.04`) and
  compares each run with `load/baselines/ubuntu-24.04-<n>node.json`. It fails on lost acked messages, failed
  correctness thresholds, or a gated p95 (or memory per socket) worse by more than 15 % **and** by more than that metric's
  absolute noise floor (for example 5 ms), so a jump from 4 ms to 5 ms is not reported as a 25 % regression.
- **Correctness fails, targets warn.** k6 thresholds on loss (gaps, duplicates, lost or never-acked messages,
  unverified subscribers, and for idle sockets, failed or dropped connections) fail the run. The PRD performance
  targets (REST → WebSocket p95 below 250 ms, burst capacity) are reported as missed targets. The first run misses
  them ([2026-10-12](../benchmarks/2026-10-12-612ec15.md)): failing on them would keep the nightly job red until #35
  lands and hide real regressions, so the baseline comparison is the performance gate.
- **Clients behave like real clients.** Subscribers reconnect with exponential backoff and jitter, and idle sockets
  connect at 100/s. Otherwise the harness itself turns an overloaded node into a reconnect storm, and the idle
  scenario would measure handshake capacity (every handshake reads the database) instead of memory. A 15 s e2e
  warm-up, not measured, runs first: on a cold node the first seconds were up to ten times slower.
- **Results are kept.** Published runs keep their `results.json` in `load/results/`, so a later run gets
  before/after columns against them (`report.js --baseline`).
- **Backbone dimension.** `LOAD_BACKBONE=native` is the only value that runs. Kafka, NATS and RabbitMQ are rejected
  with a pointer to #66, and the report's topology label carries the backbone so the matrix extends without format
  changes.
- `test/load/performance_test.exs` becomes `mix converger.loadtest` in `lib/mix/tasks`, documented as a write-path
  micro-benchmark, so `mix test` no longer compiles it.

## Consequences

### Positive

- Published numbers come from the real system and say which hardware they come from.
- A message lost anywhere (persistence, PubSub, replay, reconnect) fails the run with an exact count.
- Regressions show up the night after they merge, with the report in the job summary.

### Negative and trade-offs

- A GitHub-hosted runner is shared and noisy, and k6, Postgres and the nodes share its 4 vCPUs. The numbers are a
  regression signal, not a capacity statement; capacity runs should use dedicated hardware and per-node CPU limits
  (`LOAD_APP_CPUS`).
- Baselines are per runner image and must be refreshed deliberately (copy `results.json` from a nightly artifact)
  when the hardware or an accepted performance trade-off changes.
- The three nodes of the 3-node topology run on one host, so it measures clustering overhead and failover, not
  horizontal scale.
- The load stack shortens Oban's lifeline rescue to 30 s (as the chaos harness does). Otherwise deliveries that were
  executing on a SIGKILLed node would wait for the 30 minute default.

### Follow-ups

- [#66](https://github.com/AimTune/converger/issues/66): the Kafka backbone and its column in the matrix.
- [#35](https://github.com/AimTune/converger/issues/35): re-run and publish the full matrix after the degradation
  work, as the issue requires (after #29, #30, #31, #35).

## Implementation

- `load/` - k6 scenarios, `lib/converger.js` (Protocol v1 subscriber with resume and loss accounting, REST sender),
  `mock_provider/server.js`, `setup.exs` (fixtures over `bin/converger rpc`), `run.sh` (stack, sampler,
  restarts), `results.js` and `report.js`, compose overrides for 1 and 3 nodes.
- `.github/workflows/load.yml` - nightly and on pull requests that touch `load/`.
- `lib/mix/tasks/converger.loadtest.ex` - the in-process write-path benchmark.

## Links

- [Benchmarks](../benchmarks/index.md)
- [Chaos testing](../chaos.md)
- [WebSocket limits and draining](../operations/websocket-limits.md)
- [k6 WebSockets module](https://grafana.com/docs/k6/latest/javascript-api/k6-websockets/)
