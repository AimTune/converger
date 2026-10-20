# Converger threat model for Anthropic's OSS Scanner

Converger is a multi-tenant, real-time messaging backbone written in Elixir (Phoenix 1.8, Ecto, PostgreSQL,
Oban). A tenant's channels (its own WebSocket clients, inbound/outbound webhooks, WhatsApp, Telegram, Slack,
Discord, Teams, Messenger, Instagram, Viber, SMS, email, Kafka, RabbitMQ, NATS, Redis Streams, MQTT) are joined
through conversations: every activity is persisted first, streamed to connected clients, and delivered to the
conversation's channel and any routed channels with retries. Many tenants share one database and one cluster,
so **tenant isolation is the property we care about most**, followed by authentication, server-side request
forgery and secret handling.

The security model is documented at https://converger.aimtune.dev/security/overview (source:
`docs/security/overview.md`), the disclosure process in `SECURITY.md`. Design decisions are in `docs/adr/`.

## Where untrusted input enters

All of these are reachable by anyone on the internet unless noted; the credential in brackets is what the request
is supposed to carry.

| Surface | Code | Credential |
| --- | --- | --- |
| Tenant REST API `/api/v1/**` (conversations, activities, deliveries, routing rules, uploads) | `lib/converger_web/controllers/*.ex`, `lib/converger_web/plugs/tenant_auth.ex` | `x-api-key` primary or scoped key (`read` / `write` / `manage`) |
| Management API `/api/v1/manage/**` | `lib/converger_web/controllers/manage/` | scoped key with `manage` |
| Admin API `/api/v1/admin/**` (tenants, key issuance) | `lib/converger_web/controllers/admin_api/`, `lib/converger_web/plugs/admin_api_auth.ex` | `ADMIN_API_TOKEN` bearer, admin IP whitelist |
| Client API `/api/v1/converger/**` (token generate / refresh / revoke, publishable tokens, activities, uploads, downloads) | `lib/converger_web/controllers/converger/`, `lib/converger_web/plugs/converger_auth.ex` | channel secret, publishable key + `Origin`, or a Converger JWT |
| Protocol v1 WebSocket `/socket/converger` and the Phoenix channel | `lib/converger_web/protocol_socket.ex`, `lib/converger_web/protocol/`, `lib/converger_web/channels/` | Converger JWT (`token` param) |
| Protocol v1 over gRPC (off unless `GRPC_ENABLED`) | `lib/converger_web/grpc/` | Converger JWT in metadata or `Hello.token` |
| Inbound webhooks `POST /api/v1/channels/:id/inbound` and `/status` | `lib/converger_web/controllers/inbound_controller.ex`, `lib/converger/channels/inbound_signature.ex`, `lib/converger/channels/adapters/*.ex` (inbound parsing, provider signature checks) | HMAC over the raw body (generic `x-converger-signature`, Meta `X-Hub-Signature-256`, Slack signing secret, ...) |
| Payloads fetched from providers (media downloads, Telegram / Discord / Slack API responses, broker messages) | `lib/converger/channels/media_download.ex`, the adapters, `lib/converger/channels/broker/`, `lib/converger/channels/consumers/` | none: provider data is untrusted |
| Admin panel `/admin` (LiveView) | `lib/converger_web/live/`, `lib/converger_web/plugs/admin_auth.ex`, `lib/converger_web/plugs/auth.ex`, `lib/converger_web/user_auth.ex` | session cookie + admin IP whitelist (default: loopback only) |
| Tenant portal `/portal` (LiveView, **not** behind the IP whitelist) | `lib/converger_web/live/`, `lib/converger_web/plugs/auth.ex` | session cookie (tenant staff) |
| Uploads and downloads | `lib/converger/uploads/` (MIME sniffing, storage backends, signed CDN URLs), `lib/converger_web/multipart_parser.ex` | Converger JWT; the bytes are untrusted |
| Health `/health/live`, `/health/ready`, metrics `/metrics` | `lib/converger_web/plugs/health.ex`, `lib/converger_web/plugs/metrics.ex` | none / `METRICS_TOKEN` |
| Forwarded-header handling, rate limiting | `lib/converger_web/plugs/trusted_proxies.ex`, `lib/converger_web/plugs/rate_limit.ex`, `lib/converger/rate_limit/` | n/a |

Server-side requests Converger makes to operator- or tenant-supplied URLs: outbound `webhook` channel
deliveries, platform event webhooks, tenant alert webhooks, the WhatsApp Infobip `base_url`, the `http_pull`
adapter, media downloads, and the S3 / GCS / Azure storage clients. All must pass `Converger.Channels.UrlGuard`
(`lib/converger/channels/url_guard.ex`): private, loopback, link-local and cloud-metadata addresses are refused,
DNS answers are pinned to the checked address, redirects are not followed.

## Trust boundaries and security goals

1. **Tenant isolation.** A credential of tenant A must never read, write, list, deliver to, or infer the existence
   of tenant B's data (conversations, activities, attachments, channels, routing rules, deliveries, users, audit
   logs, webhook subscriptions, API keys). The tenant always comes from the credential, never from the request.
2. **Channel and conversation binding.** A Converger client token is bound to its channel, and usually to one
   conversation; a `scope: "channel"` token may reach the conversations of its own `websocket` channel and the ones
   routed to it, nothing else. Legacy conversation tokens and client tokens must never be accepted where a tenant
   API key or channel token is required (the shape checks in `TenantAuth`, ADR-0026).
3. **Scopes fail closed.** A scoped API key without `write` cannot mutate and without `manage` cannot configure; a
   key can only issue keys with a subset of its own scopes; the `perms` claim on client tokens (`read`, `write`,
   `typing`) is enforced on REST, the Phoenix channel and the Protocol v1 session.
4. **Authentication cannot be bypassed or brute-forced.** Password login (bcrypt / PBKDF2), TOTP 2FA (single use,
   lockout), server-side sessions (absolute and idle expiry, revocation), password reset tokens (single use, one
   hour, hashed), JWT verification (`kid`, `type`, revocation list, refresh-token reuse detection), constant-time
   comparison of API keys, admin tokens and signatures.
5. **Inbound signatures are mandatory and correct.** A present-but-invalid signature is always `401`; when
   `require_signature` is set a missing signature is rejected too; timestamps are bounded (300 s). Verification
   uses the raw body kept by `ConvergerWeb.CacheBodyReader`, not re-encoded JSON.
6. **No SSRF.** See the `UrlGuard` list above; a bypass (DNS rebinding, redirects, IPv6 or IPv4-mapped forms,
   decimal or octal IPs, `0.0.0.0`, link-local, metadata endpoints) is a real finding.
7. **Secrets stay secret.** Channel secrets, provider tokens, webhook secrets and headers, and TOTP secrets are
   AES-256-GCM encrypted (`Converger.Vault`); API keys, session and reset tokens are stored as SHA-256 digests only;
   the audit log and production logs redact secret-like keys recursively. A path that returns, logs or audits a
   plaintext secret (other than the documented one-time return on create or rotate) is a finding.
8. **Uploads are safe to store and serve.** Type by magic bytes against an allowlist, size limits, served only
   through the authenticated tenant-scoped endpoint with `nosniff`, a sandboxing CSP and `Content-Disposition`;
   SVG and HTML as `text/plain`. Path traversal in the local storage backend, or an attachment of another tenant
   or conversation being served, is a finding.
9. **Client IP handling.** Forwarding headers are only honoured from `TRUSTED_PROXIES`; a client that can spoof
   its IP defeats the admin whitelist and the rate limits, so that is a finding.
10. **Availability within reason.** Unauthenticated requests that crash a node, exhaust memory or block the
    schedulers (decompression, deeply nested JSON or MessagePack, unbounded WebSocket frames, pathological regex)
    are in scope; the gRPC transport refuses messages above 1 MiB, WebSocket limits are in ADR-0027.

## Components that matter most / least

Most: `lib/converger_web/plugs/` (every auth plug), `lib/converger_web/protocol/` and `protocol_socket.ex`,
`lib/converger/auth/` (JWT signer, tokens, revocation cache), `lib/converger/channels/url_guard.ex`,
`lib/converger/channels/inbound_signature.ex` and the adapters' inbound parsing and signature code,
`lib/converger/uploads/`, `lib/converger_web/controllers/converger/`, `lib/converger/accounts/` (passwords,
sessions, TOTP, reset), `lib/converger/vault.ex` and `lib/converger/secrets.ex`, `lib/converger_web/live/`
(LiveView authorisation hooks, HTML rendering), `lib/converger_web/router.ex`.

Still in scope, lower priority: the delivery pipeline and Oban workers (`lib/converger/pipeline/`,
`lib/converger/deliveries/`, `lib/converger/workers/`), the broker adapters (they talk to trusted
infrastructure), telemetry, release tasks (`lib/converger/release.ex`), the Helm chart and Kubernetes manifests
under `deploy/`.

Out of scope here: the SDKs and example apps under `packages/` and `examples/` (not copied into this image), the
Docusaurus site under `website/`, the load and chaos harnesses under `load/` and `test/load/`, generated files
(`priv/static/openapi.json`, the `*.pb.ex` files under `lib/converger_web/grpc/`).

## How to exercise it

The image is a development build with PostgreSQL inside. Everything runs as root from `/src`:

- `.oss-scanner/with-postgres.sh mix test` runs the ExUnit suite (`MIX_ENV=test`). The broker, storage-emulator,
  cluster and live-provider suites are tagged and excluded by default (see `test/test_helper.exs`); they need
  services that are not in the image.
- The same wrapper runs a single file (`.oss-scanner/with-postgres.sh mix test test/converger_web/...`). The
  existing tests under `test/converger_web/` and `test/protocol/` show how to drive REST, the Phoenix channel and
  Protocol v1 over WebSocket (`mint_web_socket`) with `Phoenix.ConnTest` and `Phoenix.ChannelTest`.
- `MIX_ENV=dev .oss-scanner/with-postgres.sh mix phx.server` boots the application on `http://127.0.0.1:4000`
  (the dev database is created and migrated at build time). `MIX_ENV=dev mix run priv/repo/seeds.exs` creates a
  `super_admin` from `ADMIN_EMAIL` / `ADMIN_PASSWORD` (or prints a one-time password). The admin panel is on
  `/admin` (loopback is whitelisted by default), the portal on `/portal`, Swagger UI on `/api/docs`.
- `MIX_ENV=dev .oss-scanner/with-postgres.sh iex -S mix` gives a shell with the contexts (`Converger.Tenants`,
  `Converger.Channels`, `Converger.Auth.ConvergerToken`, ...) to create tenants, channels and tokens directly.

Ideal reproducers are an ExUnit test (added under `test/`) or a short sequence of HTTP / WebSocket requests
against `mix phx.server`, run against two tenants when the finding is about isolation.

## How we rate severity

- **Critical**: unauthenticated or cross-tenant remote code execution; any authentication bypass of the admin
  panel, the admin API or the tenant API; cross-tenant read or write of conversation content, attachments or
  secrets by a holder of another tenant's ordinary credential; disclosure of encryption keys, `SECRET_KEY_BASE`,
  `ADMIN_API_TOKEN` or channel secrets to a tenant or end user; SSRF reaching cloud metadata or the private
  network with a response readable by the attacker.
- **High**: an end-user client token reaching conversations it is not bound to (same tenant, other channel or
  conversation); privilege escalation within a tenant (viewer to admin, `read` key to `write` or `manage`); forging
  or bypassing inbound signatures so an attacker can inject messages or delivery receipts into a channel; session
  fixation or takeover; TOTP or lockout bypass; stored XSS in the admin panel or portal that executes for another
  user; blind SSRF; path traversal in storage; an unauthenticated crash of a node (memory exhaustion, unbounded
  work) reachable with one or a handful of requests.
- **Medium**: tenant-internal information leaks between roles; missing authorisation on a low-impact endpoint;
  reflected XSS; CSRF on state-changing browser routes; rate-limit bypasses that enable credential stuffing; a
  denial of service that needs an authenticated credential or a sustained flood; timing side channels that
  reveal account existence beyond the documented "deactivated account" message.
- **Low**: verbose errors, missing headers without demonstrated impact, disclosure of non-sensitive data
  (versions, timing), issues that require an already-compromised operator or host.

Any SQL injection is at least High, and Critical when it crosses tenants or reaches secrets. A finding that only
applies with a non-default setting that the documentation already marks as dangerous
(`WEBHOOK_ALLOW_PRIVATE_TARGETS=true`, `CHECK_ORIGIN` disabled, `TRUSTED_PROXIES` covering untrusted networks,
plaintext gRPC on the internet) is Low unless the documentation says the setting is safe.

## Anything to leave alone

- Vulnerabilities in third-party services and providers (WhatsApp, Infobip, Slack, ...) and in dependencies that
  are not exploitable through Converger; the acknowledged advisories listed under `hex: [ignore_advisories: ...]`
  in `mix.exs` (each has a test proving the affected code path is unused).
- Findings that need a malicious operator, a compromised host or database, or access to the Erlang distribution
  port and `RELEASE_COOKIE` (documented as private-network only).
- The deprecated legacy surfaces (`/socket`, `/api/v1/tokens`, `x-channel-token`) are still in scope, but rate
  their findings one level lower unless they also affect Protocol v1.
- The admin panel's `'unsafe-inline'` CSP allowance for the theme script and Oban Web is known and documented.
- Missing hardening without a concrete impact (no recovery codes for 2FA, the login form saying that an account
  is deactivated): these are documented known limitations.
- Development-only configuration in `config/dev.exs` and `config/test.exs` (fixed non-secret keys, loopback
  binding, a disabled origin check) and the `/dev` routes that exist only in the dev environment.

## Reports and patches

- Reports go to the primary contact by email; please include the affected module and line, a reproducer (an
  ExUnit test is ideal), the credential the attacker holds, and the impact in terms of the goals above.
- Patches are welcome as unified diffs against `main`; keep the Elixir style (`mix format`, Credo strict), add or
  adjust a test next to the fix, and do not change `CHANGELOG.md` (it is written at release time).
- Deduplicate on the root cause: one report per missing check or vulnerable function, not one per endpoint that
  calls it. Several endpoints missing the same scope check are one report with the list.
