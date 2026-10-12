---
title: Benchmarks and load testing
description: The k6 load harness (REST to WebSocket fan-out, inbound webhook burst, idle sockets, reconnect storm, rolling restart, node kill), how to run it, what it measures, the zero-loss check, the nightly regression gate and the published results.
sidebar_position: 1
---

# Benchmarks and load testing

Converger's performance numbers come from a load harness that drives the **production release** over HTTP and
WebSocket, the same way clients and providers do. Each run records the hardware it ran on, and it fails if any
message the server acknowledged is lost. The decision and its trade-offs are in
[ADR-0043](../adr/0043-k6-load-harness-on-the-release-image-with-seq-based-loss-checks.md).

## Published results

| Run | Topologies | Notes |
| --- | --- | --- |
| [2026-10-12, `612ec15`](2026-10-12-612ec15.md) | 1 node and 3 nodes, native backbone | First run of the harness, on a developer machine (Docker Desktop). Before #35. |

The nightly `Load` workflow publishes a report for every run as its job summary and as the `load-results-*`
artifacts. Pages here are the runs worth keeping: a new baseline, a release, or a before/after comparison.

:::note Planned
The backbone dimension has one value today, `native` (Phoenix.PubSub over Erlang distribution plus Oban on
Postgres). Kafka, NATS and RabbitMQ columns come with [#66](https://github.com/AimTune/converger/issues/66). The
full matrix is re-run and published after the scale work
([#29](https://github.com/AimTune/converger/issues/29), [#30](https://github.com/AimTune/converger/issues/30),
[#31](https://github.com/AimTune/converger/issues/31), [#35](https://github.com/AimTune/converger/issues/35)) with a
before/after comparison against the first run.
:::

## Scenarios

| Scenario | Script | What it does | Main numbers |
| --- | --- | --- | --- |
| `e2e` | `load/e2e.js` | One VU per conversation opens `SUBSCRIBERS` Protocol v1 sockets on it, then POSTs `RATE` activities per second over the tenant REST API. | REST → WebSocket p50/p95/p99, REST POST p95, sustained acked msgs/s, frames/s delivered, connections |
| `webhook_burst` | `load/webhook_burst.js` | Signed generic inbound webhooks at `BURST_RATE`/s for `BURST_S` s from 200 external users. A routing rule fans every message out to three outbound webhook channels on the mock provider. | inbound accepted/s and POST p95, inbound → provider p50/p95/p99 (slowest target), deliveries/s, time for the queue to drain |
| `idle` | `load/idle.js` | Opens `SOCKETS` connections (10 000) at `CONNECT_RATE`/s and holds them idle (a `ping` every 25 s). | connections, connect p95, RSS growth and memory per idle socket |
| `reconnect_storm` | `load/reconnect.js` (`MODE=storm`) | `e2e` traffic, and every 15 s every socket drops and reconnects at once with its last `seq` as the watermark. | reconnect (close → `welcome`) p95/max, REST → WebSocket p95 during storms |
| `rolling_restart` | `load/reconnect.js` (`MODE=restart`) | `e2e` traffic while `run.sh` restarts each node in turn with SIGTERM (readiness flips, sockets drain, the node comes back). Clients reconnect to the next node. | time until each node is ready again, client reconnect max |
| `node_kill` | `load/reconnect.js` (`MODE=restart`) | `e2e` traffic while `run.sh` SIGKILLs one node and starts it again. | time until the killed node is ready, client reconnect max |

Every scenario that sends messages also runs the [zero-loss check](#zero-loss-check). Senders retry each message
with the same idempotency key until it is acknowledged, so a restart delays messages but must not lose them.

## Metrics

| Metric | Source |
| --- | --- |
| End-to-end latency p50/p95/p99 (ms) | REST and inbound texts carry their send time (`load <unix ms> <key>`); subscriber sockets and the mock provider subtract it from the arrival time. All clients run on the same host. |
| Sustained msgs/s | Messages acknowledged by the server divided by the sending time. |
| WebSocket connections | `welcome` frames received (`ws_connected`). |
| CPU and RSS per node | `docker stats`, streamed about once a second for every node and Postgres. |
| DB pool wait | `converger_repo_query_queue_time` (the last Ecto queue time) from each node's `/metrics`, sampled every second; the report shows the highest value seen. |
| Oban queue depth | Open jobs (`available`, `scheduled`, `executing`, `retryable`) in `oban_jobs`, every second. |
| Recovery time after a restart or kill (s) | From the restart or `SIGKILL` until `GET /health/ready` answers 200 again. |
| Reconnect time (ms) | From a socket closing to the `welcome` of its next connection. |
| **Lost acked messages** | See below. Must be 0. |
| Hardware | vCPUs and memory visible to Docker, OS, kernel, Docker and Postgres versions, per-node CPU and memory limits, pool size, database size after the run. |

## Zero-loss check

Each subscriber socket only reads. Because `seq` is allocated gap-free per conversation
([ADR-0006](../adr/0006-per-conversation-seq-and-opaque-watermarks.md)), and the server fills gaps and drops
duplicates on every connection ([Protocol v1, section 6.3](../protocol/v1.md#63-gap-detection)), a correct server
delivers every `seq` exactly once and in order. When the sending stops, each subscriber sends a `ping` and reads the
conversation head (`headSeq`) from the `heartbeat`. The harness counts:

- `seq_gaps`: a frame arrived whose `seq` is more than one above the last one seen;
- `seq_duplicates`: a frame arrived with a `seq` already seen;
- `lost_acked_messages`: `headSeq` minus the last `seq` seen, plus the gaps;
- `subscribers_unverified`: subscribers that could not reach the head within 60 s.

Reconnects resume with `hello.watermark` set to the last `seq`, so a socket that was disconnected for a restart
must still end with every message. For webhook deliveries, the harness compares the inbound messages accepted (2xx)
with the activities stored in Postgres and with what the mock provider received on each target channel. It also
checks that every REST activity reached the fan-out channel's outbound webhook.

## Running it

Requirements: Docker with Compose 2.24 or newer, `bash`, `curl` and `openssl`. These are present in Git Bash on
Windows and on GitHub's Ubuntu runners. Nothing else needs to be installed: k6, the mock provider and the report
run in containers.

```bash
load/run.sh                                  # 1 node, every scenario, full sizes
LOAD_NODES=3 load/run.sh                     # three clustered nodes (gossip)
LOAD_PROFILE=smoke load/run.sh               # small sizes, about 8 minutes
LOAD_SCENARIOS="e2e idle" LOAD_SKIP_BUILD=1 load/run.sh
```

The script:

1. Writes throwaway secrets to `load/.run/.env` (gitignored; nothing is reused between runs).
2. Builds the release image `converger-load:local` from the `Dockerfile` and starts Postgres, the migration step,
   the node(s) and the mock provider as compose project `converger-load`. Nodes listen on `127.0.0.1:14100`
   (and `14101`, `14102`). Postgres is not published, so the harness runs next to a development stack.
3. Creates the fixtures on a node with `bin/converger rpc` (`load/setup.exs`). It makes a tenant with raised
   rate limits, an outbound webhook channel with the e2e conversations and one socket token per subscriber, the
   idle conversations, and the ingress channel with a routing rule to the target channels.
4. Starts the sampler and runs each scenario with `grafana/k6:1.8.1`. For `rolling_restart` and `node_kill` it
   restarts or kills nodes meanwhile.
5. Waits until no delivery job is open, collects the mock provider's statistics and the database counts, records
   the hardware, and writes `load/.run/out/results.json` and `report.md` (`load/results.js`).
6. Tears the stack down, volumes included (`LOAD_KEEP=1` keeps it).

The exit code is non-zero when a loss check or a correctness threshold failed, or k6 crashed (see [thresholds](#running-a-scenario-with-k6-directly)); missed performance targets are only reported. The output directory also holds each
scenario's k6 log and summary JSON, `samples.csv`, `mock_stats.json`, the node logs and `setup.json`.

### Tunables

| Variable | `full` | `smoke` | Meaning |
| --- | --- | --- | --- |
| `LOAD_NODES` | `1` | | `1` or `3` nodes. |
| `LOAD_BACKBONE` | `native` | | Only `native` runs today; `kafka`, `nats`, `rabbitmq` exit with a pointer to #66. |
| `LOAD_SCENARIOS` | all six | | Space-separated subset, in order. |
| `LOAD_CONVERSATIONS` / `LOAD_SUBSCRIBERS` | `100` / `10` | `10` / `3` | e2e and reconnect conversations, and sockets per conversation (1 000 sockets by default). |
| `LOAD_RATE` | `1` | `2` | REST messages per second per conversation. |
| `LOAD_DURATION_S` | `60` | `20` | Sending time of `e2e` and `reconnect_storm`. The restart scenarios run long enough for every restart. |
| `LOAD_BURST_RATE` / `LOAD_BURST_S` | `500` / `30` | `50` / `10` | Inbound webhook burst. |
| `LOAD_TARGETS` | `3` | | Outbound channels the burst fans out to. |
| `LOAD_IDLE_SOCKETS` / `LOAD_IDLE_HOLD_S` | `10000` / `60` | `500` / `15` | Idle connections and how long they are held. |
| `LOAD_IDLE_CONVERSATIONS` | `1000` | `50` | Conversations the idle sockets share. |
| `LOAD_CONNECT_RATE` | `100` | | New idle connections per second. Every handshake reads the database, so at much higher rates the pool, not memory, is what is measured. |
| `LOAD_RESTART_GAP_S` | `10` | | Pause between node restarts. |
| `LOAD_APP_CPUS` / `LOAD_APP_MEMORY` | unlimited | | Per-node limits (`2`, `2g`) for capacity runs. |
| `LOAD_POOL_SIZE` | `20` | | `POOL_SIZE` of each node. |
| `MOCK_LATENCY_MS` / `MOCK_JITTER_MS` / `MOCK_ERROR_RATE` | `20` / `10` / `0` | | Mock provider answer time and the fraction of requests it fails with 500. |
| `LOAD_SKIP_BUILD` / `LOAD_KEEP` | `0` | | Reuse the image; keep the stack after the run. |

The load stack sets `OBAN_LIFELINE_RESCUE_AFTER_SECONDS=30` (`LOAD_LIFELINE_RESCUE_AFTER_SECONDS`), as the
[chaos test](../chaos.md) does. Otherwise deliveries that were executing on a SIGKILLed node would wait for the
30-minute default before they are retried.

### Running a scenario with k6 directly

Against a stack you already run (for example `LOAD_KEEP=1`), with fixtures from `load/setup.exs`:

```bash
k6 run -e SETUP_JSON=load/.run/out/setup.json -e APP_URLS=http://127.0.0.1:14100 -e OUT_DIR=load/.run/out load/e2e.js
```

k6 prints the end-to-end p95 (`e2e_latency_ms`), the connections (`ws_connected`) and the loss counters, and
exits with 99 when a threshold is crossed. Each script lists its variables at the top.

The thresholds are of two kinds:

- **Correctness** (`lost_acked_messages`, `seq_gaps`, `seq_duplicates`, `messages_never_acked`,
  `subscribers_unverified`, and for `idle`, `ws_connected` and `ws_unexpected_closes`): a miss fails the run.
- **Performance targets** from the PRD and the scenario sizes: REST → WebSocket p95 below `E2E_P95_MS` (250),
  REST POST p95 below `REST_P95_MS` (1000), inbound POST p95 below 500 ms, no burst iteration dropped and no inbound
  request rejected. A miss is reported as "⚠️ performance targets" in the report, but does not fail the run. The
  [baseline comparison](#nightly-job-and-regression-gate) is what gates performance, so the nightly job stays green
  while a known gap (such as [#35](https://github.com/AimTune/converger/issues/35)) is open and still catches
  regressions.

### The mock provider

`load/mock_provider/server.js` stands in for every endpoint Converger delivers to (it has no dependencies and runs
in `node:22-alpine`). It answers `POST /hook/<path>` after `MOCK_LATENCY_MS` plus up to `MOCK_JITTER_MS`, fails a
`MOCK_ERROR_RATE` fraction of requests with 500 (Converger retries them), and records per path the requests,
failures, unique deliveries, duplicates and the latency of each first successful delivery. It serves them at
`GET /stats` and clears them with `POST /reset`.

## Nightly job and regression gate

`.github/workflows/load.yml` runs every night at 02:00 UTC, on demand (`workflow_dispatch`, with a `profile`
input), and on pull requests that change `load/`. It runs the `full` profile on 1 and 3 nodes on `ubuntu-24.04`
runners, writes the report to the job summary and uploads `load/.run/out/` as `load-results-1node` and
`load-results-3node`.

Each run is compared with `load/baselines/ubuntu-24.04-<n>node.json` (the `results.json` of an accepted run on the
same runner image):

```bash
node load/report.js --baseline load/baselines/ubuntu-24.04-1node.json load/.run/out/results.json
```

The job fails when:

- any run has a lost acked message, a failed loss check, a failed correctness threshold or a k6 crash, or
- a gated metric got worse by more than **15 %** and by more than its noise floor. The gated metrics are the
  REST → WebSocket p95, REST POST p95, inbound POST p95, inbound → provider p95, reconnect p95 and memory per idle
  socket. The noise floor is an absolute change below which the metric counts as unchanged: 5 ms for most
  latencies, 10 ms for delivery, 50 ms for reconnects, 2 KiB for memory.

With no baseline for the runner, the comparison is skipped with a notice. To accept new numbers (other hardware,
or a deliberate trade-off), download `results.json` from a nightly artifact and commit it as the baseline, saying
why in the pull request.

GitHub-hosted runners are shared machines. k6, Postgres and every node also share the runner's 4 vCPUs. Treat the
nightly numbers as a regression signal and use dedicated hardware with `LOAD_APP_CPUS` for capacity planning.

## Publishing a run

`load/report.js` merges several runs (one per topology) into one page, optionally with a baseline column:

```bash
LOAD_NODES=1 load/run.sh && cp load/.run/out/results.json load/results/<date>-<commit>-1node.json
LOAD_NODES=3 load/run.sh && cp load/.run/out/results.json load/results/<date>-<commit>-3node.json
node load/report.js --out docs/benchmarks/<date>-<commit>.md \
  load/results/<date>-<commit>-1node.json load/results/<date>-<commit>-3node.json
```

Add front matter, the hardware context and the findings to the page, a row to
[Published results](#published-results), and update the summary table in the README. Keep the `results.json`
files in `load/results/`: a later run shows its before/after columns against them, for example after
[#35](https://github.com/AimTune/converger/issues/35):

```bash
node load/report.js --baseline load/results/2026-10-12-612ec15-1node.json \
  --baseline load/results/2026-10-12-612ec15-3node.json \
  load/results/<new>-1node.json load/results/<new>-3node.json
```

Compare runs from the same machine only; the report prints both hardware records.

## In-process write-path benchmark

`mix converger.loadtest` replaces the former `test/load/performance_test.exs`. It calls
`Converger.Activities.create_activity/2` concurrently against the configured database, with no HTTP, WebSocket or
deliveries, and prints throughput and p50/p95/p99. Use it to see the cost of the per-conversation `seq` lock and
the insert on a given database. It is not a system benchmark.

```bash
mix converger.loadtest --conversations 50 --messages 200 --concurrency 50
```

It creates a throwaway tenant on an inbound-only channel and deletes it afterwards (`--keep` keeps it). Run it
against a development or scratch database (for example `DB_NAME=converger_bench`). In the `dev` environment every
query is logged, which slows it down noticeably.
