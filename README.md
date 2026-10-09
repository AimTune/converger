# 🚀 Converger

**Multi-tenant, high-performance real-time messaging backbone.**

Converger is a scalable messaging infrastructure built with **Elixir** and **Phoenix Channels**. It connects a tenant's channels (webhooks, WhatsApp, WebSocket clients) through conversations: every activity is persisted first, streamed to connected clients in real time, and delivered to the conversation's channel and any routed channels with retries.

## Documentation

Full documentation lives at **[converger.aimtune.dev](https://converger.aimtune.dev)**: getting started, concepts,
architecture, channel adapters, REST and WebSocket APIs, security and operations.

- [Getting started](https://converger.aimtune.dev/getting-started)
- [Architecture decision records (ADR index)](https://converger.aimtune.dev/adr) ([source](docs/adr/index.md))
- [Contributing](https://converger.aimtune.dev/contributing): every PR updates the relevant `docs/` pages and adds an
  ADR for architectural decisions.

The site is built with Docusaurus from [`website/`](website/) and uses [`docs/`](docs/) as its content.

---

## ✨ Key Features

- **Multi-tenant by Design**: Full data isolation and tenant-scoped authentication via API Keys.
- **Real-time Engine**: Powered by Phoenix Channels for instant, bidirectional messaging.
- **Channels and routing**: Pluggable channel adapters with `inbound`, `outbound` or `duplex` modes, and routing rules that fan activities out to other channels.
- **Observability Stack**: Built-in support for **OpenTelemetry**, Prometheus, Grafana, Jaeger, and Loki.
- **Reliability & Safety**:
    - **Idempotency**: `x-idempotency-key` header (REST) and `idempotency_key` field on the legacy WebSocket `new_activity` push, so clients can retry after a lost reply without duplicates.
    - **Crash-tested**: a [chaos test](docs/chaos.md) kills the node under REST + WebSocket load and checks that no acknowledged message is lost.
    - **Transaction Safety**: Atomic persistence before real-time broadcast.
    - **Rate Limiting**: Tenant and IP-level throttling.
- **Admin Panel**: IP-restricted LiveView interface for managing tenants, channels, and conversations.

---

## 🛠️ Tech Stack

- **Language/Framework**: [Elixir](https://elixir-lang.org/) / [Phoenix Framework](https://www.phoenixframework.org/)
- **Database**: [PostgreSQL](https://www.postgresql.org/)
- **Background Jobs**: [Oban](https://github.com/oban-bg/oban)
- **Monitoring**: OpenTelemetry, Prometheus, Grafana
- **Traces**: Jaeger
- **Logs**: Loki

---

## 🏎️ Performance

There are no published throughput numbers yet. Earlier figures in this README came from an in-process test and
were removed because they did not reflect a real deployment. A load testing harness with published baselines is
planned in [#34](https://github.com/AimTune/converger/issues/34). Durability under failure is tested today by the
[chaos test](docs/chaos.md).

---

## 🚀 Quick Start

### Prerequisites
- Elixir 1.19 / OTP 28 (see `.tool-versions`; the `Dockerfile` uses the same versions)
- PostgreSQL 14+
- Docker (optional, for observability stack)

### Installation
1.  **Clone the repository**:
    ```bash
    git clone https://github.com/AimTune/converger.git
    cd converger
    ```
2.  **Install dependencies**:
    ```bash
    mix deps.get
    ```
3.  **Setup the database**:
    ```bash
    mix ecto.setup
    ```
4.  **Start the server**:
    ```bash
    mix phx.server
    ```

The API will be available at `http://localhost:4000`.

---

## 🔐 Inbound Webhook Signatures

`POST /api/v1/channels/:id/inbound` and `POST /api/v1/channels/:id/status` verify a signature over the raw request body.

- **Generic (webhook, infobip, ...)**: send `x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256("<t>.<raw body>", channel secret)>`. The timestamp must be within 300 seconds of the server clock (`config :converger, :inbound_signature_tolerance_seconds`).
- **WhatsApp Meta**: Meta's `X-Hub-Signature-256` is verified with the `app_secret` channel config key.
- Each channel has a `require_signature` flag. It defaults to `true` for new channels: unsigned requests and the legacy `sha256=<hex HMAC(raw body)>` format get `401`. Channels created before this flag existed were migrated with `require_signature: false`. They still accept unsigned or legacy-signed requests and log a deprecation warning. An invalid signature always gets `401`.

---

## 📄 Pagination

Every list endpoint and admin table is bounded. Page sizes are set in `config :converger, :pagination` (`config/config.exs`) and can be overridden at runtime with `PAGINATION_DEFAULT_LIMIT`, `PAGINATION_MAX_LIMIT`, `PAGINATION_ACTIVITY_DEFAULT_LIMIT`, `PAGINATION_ACTIVITY_MAX_LIMIT`, `PAGINATION_WS_REPLAY_LIMIT` and `PAGINATION_LOOKUP_LIMIT`. A `limit` above the max is capped. A missing or invalid `limit` uses the default.

| Endpoint | Params | Pagination fields in the response |
|---|---|---|
| `GET /api/v1/converger/conversations/:id/activities` | `watermark`, `limit` (default 100, max 1000) | `watermark`, `has_more` (new) |
| `GET /api/v1/conversations/:id/activities` (tenant API key) | `watermark`, `limit` (default 100, max 1000) | `meta: {watermark, has_more, limit}` (new) |
| `GET /api/v1/conversations` (tenant API key, new) | `cursor`, `limit` (default 50, max 500), `status`, `channel_id` | `meta: {next_cursor, has_more, limit}` |

- Activities are paged by their per-conversation `seq`. The `watermark` is opaque. To read the whole conversation, pass back the `watermark` you received until `has_more` is `false`.
- Conversations are paged newest first with keyset pagination on `(inserted_at, id)`. To get the next page, pass back `next_cursor`. A malformed `cursor` or `watermark` on the tenant API returns `400`. On the Converger API, an invalid watermark starts from the beginning, as it did before.
- **Behaviour change:** before this change, both activity endpoints returned the whole history when no watermark was given. They now return one page. Clients that need everything must follow `has_more`.
- **WebSocket replay on join** is capped at `ws_replay_limit` (100) activities. The Converger channel's replayed `activitySet` frame now carries `has_more`. When it is `true`, fetch the rest over REST from that frame's `watermark` and de-duplicate by activity id against live frames. On the legacy `conversation:*` channel, a `replay_truncated` event (`{has_more, last_activity_id}`) follows a truncated replay. Rejoin with that `last_activity_id` to continue.

---

## 📊 Observability

Converger comes pre-configured with a full observability stack. To launch it:

```bash
cp .env.example .env   # then fill in every secret; compose refuses to start without them
docker compose up -d
```

`mix ecto.setup` (and `bin/converger eval "Converger.Release.seed_admin()"` in a
release) creates the first super admin. Set `ADMIN_EMAIL` / `ADMIN_PASSWORD`, or
a random password is printed once and must be changed at first login.
Production setup, migrations, backups and upgrades are covered in
[docs/deployment.md](docs/deployment.md).

- **Grafana**: `http://localhost:3000` (Dashboards enabled)
- **Jaeger**: `http://localhost:16686` (Distributed Tracing)
- **Prometheus**: `http://localhost:9090`

---

## 🏗️ Architecture

```mermaid
flowchart LR
    subgraph In["Inbound (channel mode inbound or duplex)"]
        Client["Client app / SDK<br/>REST or WebSocket"]
        Provider["Provider webhook<br/>WhatsApp, generic webhook"]
    end

    subgraph Converger
        API["API and sockets<br/>auth, rate limits, signatures"]
        Conv["Conversation<br/>activity stored with seq"]
        Pipe["Delivery pipeline<br/>Oban, Broadway or Inline"]
        Rules["Routing rules"]
    end

    PG[("PostgreSQL<br/>activities, outbox, deliveries")]
    PubSub["Phoenix PubSub"]

    subgraph Out["Outbound (channel mode outbound or duplex)"]
        Own["Conversation's channel<br/>adapter"]
        Routed["Routed target channels<br/>adapters"]
        WS["WebSocket clients"]
    end

    Client --> API
    Provider --> API
    API --> Conv
    Conv -->|"same transaction"| PG
    Conv --> PubSub --> WS
    Conv --> Pipe
    Pipe --> Rules
    Pipe -->|"retries, dead letters"| Own
    Rules -->|"fan-out"| Routed
```

Every activity is committed together with its outbox job before anything is broadcast or delivered, so a crash
cannot lose an acknowledged message ([ADR-0001](docs/adr/0001-transactional-outbox-with-oban.md)). The full picture
is in the [architecture overview](https://converger.aimtune.dev/architecture/overview). Telemetry goes to
OpenTelemetry, Prometheus, Jaeger and Loki ([Observability](https://converger.aimtune.dev/operations/observability)).

The WebSocket wire protocol (Converger Protocol v1, a superset of mekik/1) is specified in
[docs/protocol/v1.md](docs/protocol/v1.md), with the rich message vocabulary in
[docs/protocol/messages.md](docs/protocol/messages.md) and JSON Schemas in `priv/protocol/v1/`.

---

## 🤝 Contributing and community

- [Contributing guide](CONTRIBUTING.md) and [code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md): report vulnerabilities privately, never in a public issue
- [Changelog](CHANGELOG.md) and [roadmap](https://converger.aimtune.dev/roadmap)

---

## 📄 License

Converger is released under the [MIT License](LICENSE).
