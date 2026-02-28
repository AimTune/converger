# Converger Version Roadmap

## v1.0 — MVP (Completed)

- [x] Multi-tenant data model (tenants, channels, conversations, activities)
- [x] REST API for conversations and activities
- [x] Real-time WebSocket streaming via Phoenix Channels
- [x] JWT token authentication (conversation + channel tokens)
- [x] Tenant API key authentication
- [x] Activity idempotency (x-idempotency-key)
- [x] Admin panel (LiveView, IP-restricted)
- [x] Background jobs (Oban: conversation expiration)
- [x] Observability stack (OpenTelemetry, Prometheus, Grafana, Jaeger, Loki)
- [x] Echo channel type for testing
- [x] Rate limiting (IP + tenant scoped)
- [x] Activity ordering per conversation
- [x] JavaScript client library (converger_js)

## v1.1 — Bug Fixes & Foundation (Completed)

- [x] Fix IO.puts in workers — use Logger.info instead
- [x] Fix bare rescue in TenantAuth plug — catch only Ecto.NoResultsError
- [x] Configurable CORS origins (CORS_ORIGINS env variable)
- [x] Configurable admin IP whitelist (ADMIN_IP_WHITELIST env variable)
- [x] Channel status validation on conversation creation
- [x] Tenant status validation on token creation
- [x] Remove unused TokenCleanupWorker
- [x] Add `config` JSONB field to channels table
- [x] Channel Adapter behaviour (`Converger.Channels.Adapter`)
- [x] Echo adapter implementation
- [x] WebSocket adapter implementation
- [x] Expanded channel types: echo, webhook, websocket, whatsapp_meta, whatsapp_infobip
- [x] Channel config validation in changeset via adapter

## v1.2 — Webhook Channel (Completed)

- [x] Webhook adapter: outbound HTTP POST delivery via Req
- [x] Webhook adapter: config validation (url required, valid HTTP/HTTPS)
- [x] Webhook adapter: inbound payload parsing
- [x] Inbound webhook endpoint (POST /api/v1/channels/:id/inbound)
- [x] Webhook verification endpoint (GET /api/v1/channels/:id/inbound)
- [x] Auto-conversation creation for inbound messages
- [x] Webhook signature verification (HMAC-SHA256 via x-converger-signature)
- [x] Raw body caching for signature verification (CacheBodyReader)
- [x] Channel inactive error handler in FallbackController

## v1.3 — Delivery System (Completed)

- [x] Deliveries table (status tracking per activity per channel)
- [x] Delivery schema and context module (Converger.Deliveries)
- [x] ActivityDeliveryWorker (Oban, deliveries queue, max 5 attempts)
- [x] Exponential backoff for failed deliveries (3^attempt * 10 seconds)
- [x] Automatic delivery enqueue on activity creation for external channels
- [x] Delivery status counts in admin dashboard
- [x] Oban deliveries queue (20 concurrent workers)

## v2.0 — WhatsApp Integration (Completed)

- [x] WhatsApp Meta adapter (Cloud API v18.0)
  - [x] Config validation (phone_number_id, access_token, verify_token)
  - [x] Outbound text message delivery
  - [x] Inbound message parsing (webhook notification format)
  - [x] Webhook verification (hub.verify_token challenge)
- [x] WhatsApp Infobip adapter
  - [x] Config validation (base_url, api_key, sender)
  - [x] Outbound text message delivery
  - [x] Inbound message parsing
- [x] Admin panel: dynamic channel type dropdown from schema
- [x] Updated PRD for v2.0

## v2.1 — Parametric Pipeline (Completed)

- [x] Parametric activity processing pipeline (`Converger.Pipeline` behaviour)
- [x] Pipeline.Oban backend (default — persistent job queue with Oban)
- [x] Pipeline.Broadway backend (stream processing with configurable producers)
  - [x] In-memory GenStage producer (MemoryProducer)
  - [x] Kafka producer via :brod (optional dependency)
  - [x] RabbitMQ producer via :amqp (optional dependency)
  - [x] Custom producer support
- [x] Pipeline.Inline backend (synchronous — for testing/development)
- [x] Activities.create_activity refactored: broadcast+delivery moved outside DB transaction
- [x] Pipeline child_specs integrated into Application supervision tree
- [x] Config-driven backend selection (`config :converger, pipeline: [backend: ...]`)
- [x] Test env uses Pipeline.Inline for deterministic testing

## v2.2 — Message Routing & Fan-Out (Completed)

- [x] Routing rules data model (`routing_rules` table with UUID array targets)
- [x] RoutingRule schema + context with full CRUD
- [x] Tenant isolation validation (all channels must belong to same tenant)
- [x] Cycle detection (BFS-based write-time validation prevents routing loops)
- [x] Self-reference validation (source channel cannot be in targets)
- [x] Pipeline multi-channel fan-out (`resolve_delivery_channels` returns list)
- [x] All 3 pipeline backends updated (Oban, Broadway, Inline)
- [x] REST API: `GET/POST/PUT/DELETE /api/v1/routing_rules`
- [x] Admin LiveView: `/admin/routing_rules` (create, toggle, delete with tenant-filtered dropdowns)
- [x] Router updated with API + admin routes

## v2.3 — Future Enhancements (Planned)

- [ ] Media message support (images, documents, audio, video)
- [ ] Template message support (WhatsApp HSM templates)
- [x] Delivery receipts / read receipts
- [x] Channel health monitoring and alerting
- [ ] Webhook retry dashboard in admin panel
- [ ] Message transformation pipeline (middleware)
- [ ] Per-channel rate limiting
- [ ] SDK updates (JS client for inbound webhooks, delivery status)
- [ ] Channel config encryption at rest

## v3.0 — Enterprise (Planned)

- [ ] Tenant sharding for horizontal data scaling
- [ ] Multi-region replication
- [ ] Advanced analytics dashboards
- [ ] SLA tiers per tenant
- [ ] Enterprise RBAC (role-based access control)
- [ ] Audit logging
- [ ] API versioning strategy
- [ ] SMS channel adapters (Twilio, Vonage)
- [ ] Email channel adapter (SMTP/SendGrid)
- [ ] Telegram/Slack channel adapters
