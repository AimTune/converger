---
title: Chaos testing
---

# Chaos testing

The chaos test kills the Converger node with `SIGKILL` while clients send
messages over REST and WebSocket. It then checks that **no message the server
acknowledged was lost**, none was stored twice, the per-conversation `seq` has
no gaps, and every acknowledged message reached its outbound webhook. This is
the exit criterion of the v2.5 hardening epic (#57).

The harness lives in [`test/chaos/`](https://github.com/AimTune/converger/tree/main/test/chaos):

| File | Role |
| --- | --- |
| `run.sh` | Orchestrates the run: secrets, stack, fixtures, load, kills, verification, teardown. |
| `docker-compose.chaos.yml` | Override of the root `docker-compose.yml`: only `db`, `migrate`, `app`, plus `sink` and `driver`. |
| `setup.exs` | Creates a tenant, an outbound webhook channel pointing at the sink, and the conversations. Evaluated on the running node with `bin/converger rpc`. |
| `driver.js` | Load driver: REST and WebSocket clients that retry until acknowledged. |
| `sink.js` | Webhook receiver that records every request it gets. |
| `verify.js` | Compares what was acknowledged with Postgres and the sink, writes `report.json`. |

The driver and the sink are plain Node.js scripts with no dependencies (Node 22
ships `fetch` and `WebSocket`). They run in the stock `node:22-alpine` image,
so nothing has to be installed on the host and the same harness runs on
Windows (Docker Desktop, Git Bash) and Linux CI. The app runs from the
production `Dockerfile` release.

## Running it

Requirements: Docker with Compose 2.24 or newer, `bash`, `curl` and
`openssl` (all present in Git Bash on Windows and on GitHub's Ubuntu runners).

```bash
test/chaos/run.sh
```

The script:

1. Writes throwaway secrets (`POSTGRES_PASSWORD`, `SECRET_KEY_BASE`,
   `CLOAK_KEY`, ...) to `test/chaos/.run/.env`. The directory is gitignored;
   nothing is reused between runs.
2. Builds the image (`converger-chaos:local`) and starts the stack as compose
   project `converger-chaos`. The app listens on `127.0.0.1:14000`; Postgres is
   not published, so it does not clash with a development stack on 5432.
3. Creates the fixtures: 8 REST and 8 WebSocket conversations on one outbound
   webhook channel whose URL is the sink (`WEBHOOK_ALLOWED_TARGETS=sink` lets it
   past the SSRF guard).
4. Starts the driver for 60 s. Each REST conversation has 2 concurrent senders;
   each WebSocket conversation has one socket with up to 4 pushes in flight.
5. Kills the app container with `docker kill -s KILL` 3 times (10 s in, then
   every 15 s), waits 3 s and starts it again.
6. Lets the driver re-send everything that was not acknowledged, waits until
   the `deliveries` queue in `oban_jobs` is empty, dumps the tables with
   `psql` and runs `verify.js`.
7. Tears the stack down, volumes included (`CHAOS_KEEP=1` keeps it).

The exit code is non-zero when any check fails. Results are in
`test/chaos/.run/out/`: `report.json`, `driver.log`, `app.log` and the CSV
dumps.

### Tunables

| Variable | Default | Meaning |
| --- | --- | --- |
| `CHAOS_KILLS` | `3` | Number of kills. |
| `CHAOS_FIRST_KILL_S` / `CHAOS_KILL_INTERVAL_S` | `10` / `15` | When to kill. |
| `CHAOS_DOWN_S` | `3` | Seconds the node stays dead. |
| `CHAOS_DURATION_S` | `60` | Seconds of load. |
| `CHAOS_DRAIN_S` | `180` | Extra seconds to get unacknowledged messages acknowledged. |
| `CHAOS_REST_CONVERSATIONS` / `CHAOS_WS_CONVERSATIONS` | `8` / `8` | Conversations per transport. |
| `CHAOS_DELIVERY_TIMEOUT_S` | `300` | How long to wait for the delivery queue to drain. |
| `CHAOS_LIFELINE_RESCUE_AFTER_SECONDS` | `30` | Passed to the app as `OBAN_LIFELINE_RESCUE_AFTER_SECONDS`. |
| `CHAOS_APP_PORT` | `14000` | Host port of the app. |
| `CHAOS_SKIP_BUILD` | `0` | `1` reuses the existing image. |
| `CHAOS_KEEP` | `0` | `1` leaves the stack running after the run. |

### In CI

[`.github/workflows/chaos.yml`](https://github.com/AimTune/converger/blob/main/.github/workflows/chaos.yml) runs the
same script on `ubuntu-latest`: on demand (`workflow_dispatch`, with the
number of kills and the duration as inputs), nightly, and on pull requests
that change the harness. The results directory is uploaded as the
`chaos-results` artifact. It is not part of the regular CI workflow because it
builds the release image.

## What counts as acknowledged

| Transport | Request | Acknowledged when |
| --- | --- | --- |
| REST | `POST /api/v1/conversations/:id/activities` with `x-api-key` and `x-idempotency-key` | `2xx` response with the activity id |
| WebSocket | legacy socket `/socket/websocket`, channel `conversation:ID`, push `new_activity` with `idempotency_key` | `phx_reply` with status `ok` (the response carries the activity `id` and `seq`) |

Every message keeps its idempotency key across retries. Connection errors,
timeouts and `5xx` responses are retried with backoff. A WebSocket push whose
socket closes before the reply is re-pushed after reconnecting and rejoining.
The message text contains the key, so the verifier can count stored copies
even if the server ignored the key.

## Checks

`verify.js` fails the run when any of these is not zero (or not true):

- **lost**: acknowledged messages missing from `activities`.
- **duplicates**: messages stored more than once (acknowledged or not).
- **ack id mismatch**: an acknowledgement carried a different activity id than
  the stored row.
- **seq problems**: conversations whose `seq` values are not exactly
  1, 2, ..., `last_seq`.
- **deliveries not sent**: acknowledged messages whose delivery row is not
  `sent` (or `delivered` / `read`).
- **not at sink**: acknowledged messages the sink never received.

Redeliveries to the sink (same `x-converger-delivery-id` twice) are reported
but allowed: delivery is at-least-once, and receivers de-duplicate by that
header (see [webhooks](webhooks.md)).

## Results

Measured on 2026-10-09 on Docker Desktop (Windows 11, WSL2), image built from
this branch. Numbers are messages.

| Run | Kills | Sent | Acked | Retried | Persisted (acked) | Duplicates | Lost | Delivered | Sink redeliveries | Delivery jobs run twice | Queue empty after last restart |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Before the fixes (main) | 3 | 10,439 | 10,439 | 96 | 10,439 | **14** (WS) | 0 | **10,422** | 0 | 0 | **not within 150 s** (37 jobs stuck `executing`) |
| After, default | 3 | 7,056 | 7,056 | 96 | 7,056 | 0 | 0 | 7,056 | 0 | 27 | 4 s |
| After, default, with latest main merged | 3 | 6,932 | 6,932 | 96 | 6,932 | 0 | 0 | 6,932 | 1 | 34 | 13 s |
| After, 5 kills, 90 s | 5 | 11,344 | 11,344 | 192 | 11,344 | 0 | 0 | 11,344 | 8 | 59 | 13 s |

Split by transport for the 5-kill run: REST 6,161 sent / 6,161 acked /
6,161 persisted / 6,161 delivered; WebSocket 5,183 / 5,183 / 5,183 / 5,183.
All 16 conversations had gap-free `seq`.

"Retried" means messages sent more than once because the node died before the
client got the answer. Every one of them was eventually acknowledged and
stored exactly once.

## Bugs found

### WebSocket re-push created duplicates

The legacy `new_activity` push had no idempotency: the server ignored any key
in the payload. When the node died after committing an activity but before the
reply reached the client, the client's re-push stored the message a second
time (14 duplicates in the baseline run).

The push now accepts an optional `idempotency_key` (a non-empty string of at
most 255 bytes). A repeated key returns the stored activity instead of
creating a new one, also after a reconnect. Keys are scoped to the
conversation and the sender: the server stores them as `ws:SENDER:KEY`, so a
WebSocket client cannot claim a key used by the tenant's REST API, an inbound
webhook or another participant. The `ok` reply now carries the activity's
`id` and `seq`. Clients that push without a key behave as before.

```js
channel
  .push("new_activity", { text: "hi", idempotency_key: crypto.randomUUID() })
  .receive("ok", ({ id, seq }) => console.log("stored", id, seq));
```

Keep the key when re-sending after a timeout or reconnect; use a new one per
message.

### Deliveries stuck for 30 minutes after a crash

A delivery job that was running when the node was killed stays `executing` in
`oban_jobs` until Oban's Lifeline plugin rescues it, 30 minutes later by
default. In the baseline run, 37 jobs (21 messages not marked sent, 17 never
at the sink) were still stuck when the 150 s wait ran out. Nothing is lost (the
job row is durable), but the delivery is late.

The production default stays at 30 minutes, which is safe for any job length.
Operators can now shorten it with `OBAN_LIFELINE_RESCUE_AFTER_SECONDS` and
`OBAN_LIFELINE_INTERVAL_SECONDS` (see
[deployment](deployment.md#background-jobs-oban)). The chaos stack uses 30 s and
10 s, so every acknowledged message reached the sink within about 40 s of the
restart. Keep the value well above the longest job runtime: a webhook delivery
takes at most about 90 s. A rescued job may re-send a request that the
receiver already got before the crash (8 such redeliveries in the 5-kill
run), which is why receivers must de-duplicate by `x-converger-delivery-id`.

## Not covered

- Killing Postgres. The test assumes a durable database; see
  [backups and restore](deployment.md#backups-and-restore).
- Several app nodes behind a load balancer (the run uses one node that is
  killed and restarted).
- The Converger API WebSocket (`/socket/converger`). It only delivers
  activities to the client; clients send over REST
  (`POST /api/v1/converger/conversations/:id/activities` with
  `x-idempotency-key`), which uses the same idempotent create path as the REST
  driver.
