# Converger — Product Requirements Document (PRD)

## Version
v2.0 (Channel Routing Hub)

## Document Status
Active — Channel Adapter Architecture

---

# 1. Overview

## 1.1 Purpose

Converger is a multi-tenant, real-time message routing hub that receives messages from various channels (webhook, WebSocket, WhatsApp, etc.) and routes them to target channels with customizable channel adapters.

The platform provides:

- Multi-tenant isolation with configurable channels
- Channel Adapter framework for pluggable integrations
- Inbound webhook endpoints for receiving external messages
- Outbound delivery system with retry and status tracking
- Real-time WebSocket streaming via Phoenix Channels
- WhatsApp integration (Meta Cloud API, Infobip)
- JWT token-based authentication
- IP-restricted admin panel with delivery monitoring

## 1.2 Architecture

Converger operates as a **message routing hub**:

1. **Receive** messages from multiple channel types (webhook inbound, WebSocket, REST API)
2. **Persist** them as activities within conversations
3. **Broadcast** to connected WebSocket clients via PubSub
4. **Deliver** to external channels via adapter-based Oban workers with retry

---

# 2. Objectives

## 2.1 Business Objectives

- Enable integrators to route messages across communication channels.
- Support WhatsApp, webhook, and WebSocket channels out of the box.
- Provide reliable message delivery with status tracking and retry.
- Maintain multi-tenant data isolation.

## 2.2 Technical Objectives

- Pluggable channel adapter architecture.
- Reliable delivery via Oban with exponential backoff.
- Stateless API layer with horizontal scaling support.
- Tenant-scoped data model with configurable channels.
- Real-time WebSocket streaming with reconnect support.

---

# 3. Scope

## 3.1 In Scope

- Tenant creation and management
- Channel creation with type-specific configuration (JSONB)
- Channel adapter framework (behaviour-based)
- Supported channel types: echo, webhook, websocket, whatsapp_meta, whatsapp_infobip
- Conversation creation and retrieval
- Activity creation with idempotency support
- Inbound webhook endpoints for external message reception
- Outbound delivery system with Oban workers
- Delivery status tracking (pending/delivered/failed)
- Real-time streaming via WebSocket
- Short-lived client token issuance (JWT)
- Admin panel with IP restriction and delivery monitoring
- Webhook signature verification (HMAC-SHA256)

## 3.2 Out of Scope

- Multi-region deployment
- Event streaming backbone (e.g., Kafka)
- Advanced analytics dashboards
- SLA tiering
- Cross-tenant sharding
- Enterprise RBAC
- Media message support (images, documents, audio)
- Template message support (WhatsApp HSM)

---

# 4. User Personas

## 4.1 Platform Integrator

Description: Developer integrating Converger into an application.

Needs:
- Stable REST API for conversations and activities
- Real-time WebSocket streaming
- Inbound webhook endpoint for receiving external messages
- Simple authentication model (API key + JWT)
- Reliable message delivery to external channels
- Channel-specific configuration

## 4.2 System Administrator

Description: Internal operator managing tenants and monitoring usage.

Needs:
- Admin interface for tenant/channel management
- Delivery status monitoring (pending/delivered/failed)
- Conversation overview
- Channel configuration management

---

# 5. Functional Requirements

---

# 5.1 Tenant Management

The system must:

- Allow creation of tenants.
- Allow enabling/disabling tenants.
- Generate a unique API key per tenant.
- Isolate all tenant data.
- Prevent cross-tenant data access.
- Validate tenant status on token generation.

Each tenant must have:
- Unique identifier
- Name
- API key
- Status (active/inactive)
- Timestamps

---

# 5.2 Channel Management

Each tenant may create multiple channels.

A channel must include:
- Unique ID
- Tenant ID
- Name
- Type (echo, webhook, websocket, whatsapp_meta, whatsapp_infobip)
- Secret (auto-generated)
- Configuration (JSONB, type-specific)
- Status (active/inactive)

The system must:
- Validate channel-specific configuration via adapter on creation.
- Validate channel secret on requests.
- Scope conversations to a specific channel.
- Reject requests for inactive channels.

### Channel Configuration by Type

| Type | Required Config |
|------|----------------|
| echo | None |
| websocket | None |
| webhook | `url` (HTTP/HTTPS), optional `headers`, `method` |
| whatsapp_meta | `phone_number_id`, `access_token`, `verify_token` |
| whatsapp_infobip | `base_url`, `api_key`, `sender` |

---

# 5.3 Conversation Management

The system must allow:

- Create conversation (validates channel is active)
- Retrieve conversation
- List conversation activities
- Optionally close conversation

Each conversation must:
- Belong to exactly one tenant
- Belong to exactly one channel
- Have a unique ID
- Have status (active/closed)
- Have metadata (JSONB)
- Have timestamps

---

# 5.4 Activity Management

The system must allow:

- Create activity within conversation (with idempotency support)
- Retrieve ordered activities

Activity must support:
- type (message, event, typing)
- text (optional)
- attachments (optional, array of maps)
- sender identifier
- metadata (JSONB)
- idempotency_key (unique per conversation)
- timestamp

On creation, the system must:
1. Persist activity to database
2. Broadcast via PubSub to WebSocket clients
3. Enqueue delivery to external channels (webhook, WhatsApp) via Oban

---

# 5.5 Real-Time Streaming

The system must provide a WebSocket endpoint that:

- Authenticates via client token (JWT)
- Subscribes client to conversation topic
- Streams new activities in real time
- Supports reconnect and resume via last_activity_id watermark

---

# 5.6 Authentication

The system must support two authentication layers:

## 5.6.1 Tenant API Key (Server-to-Server)

- Required for REST API calls.
- Scoped to tenant.
- Must be validated per request.
- Tenant must be active.

## 5.6.2 Client Token (JWT)

- Short-lived (1 hour).
- Issued via secure endpoint.
- Scoped to specific conversation.
- Signed and verifiable.
- Must be validated on WebSocket connection.

---

# 5.7 Inbound Message Handling

The system must provide inbound webhook endpoints:

- `POST /api/v1/channels/:channel_id/inbound` — Receive messages from external services
- `GET /api/v1/channels/:channel_id/inbound` — Webhook verification (for WhatsApp Meta)

The system must:
- Validate channel is active
- Verify inbound signature (HMAC-SHA256, optional)
- Parse payload via channel adapter
- Create or resolve conversation
- Create activity and trigger delivery pipeline

---

# 5.8 Message Delivery System

The system must reliably deliver activities to external channels:

- Use Oban background workers with dedicated `deliveries` queue
- Support exponential backoff (3^attempt * 10 seconds)
- Maximum 5 delivery attempts before marking as failed
- Track delivery status per activity per channel

Delivery entity must include:
- Activity reference
- Channel reference
- Status (pending/delivered/failed)
- Attempt count
- Last error message
- Delivered timestamp
- Metadata

---

# 5.9 Channel Adapter Framework

The system must implement a behaviour-based adapter pattern:

Each adapter must implement:
- `validate_config/1` — Validate type-specific channel configuration
- `deliver_activity/2` — Deliver activity to external service
- `parse_inbound/2` — Parse incoming webhook payload

Supported adapters:
- **Echo** — Echoes messages back as bot responses (testing)
- **WebSocket** — No-op delivery (PubSub handles it)
- **Webhook** — HTTP POST to configured URL
- **WhatsApp Meta** — Meta Cloud API (Graph API v18.0)
- **WhatsApp Infobip** — Infobip WhatsApp API

---

# 5.10 Admin Panel

The system must provide an internal admin panel that:

- Is accessible only from whitelisted IP(s) (configurable via env)
- Allows managing tenants, channels, conversations
- Displays delivery statistics (pending/delivered/failed)
- Shows all channel types in channel creation form

---

# 6. Non-Functional Requirements

---

# 6.1 Performance

The system must support:

- Up to 10M messages/day.
- 1,000+ concurrent WebSocket connections.
- <250ms p95 API latency.
- <250ms end-to-end activity propagation latency.

---

# 6.2 Scalability

The system must:

- Support horizontal scaling of API nodes.
- Be stateless at API layer.
- Use shared PubSub across nodes.
- Support multi-node deployment.

---

# 6.3 Reliability

The system must:

- Prevent message loss.
- Ensure activity persistence before broadcast.
- Retry failed external deliveries with exponential backoff.
- Track delivery status for auditability.
- Recover gracefully from node restart.

---

# 6.4 Security

The system must:

- Enforce HTTPS.
- Validate JWT signatures.
- Enforce tenant isolation in all queries.
- Validate channel status on conversation creation.
- Validate tenant status on token generation.
- Restrict admin access by configurable IP whitelist.
- Support webhook signature verification (HMAC-SHA256).
- Store secrets securely (encrypted channel configs in future).
- Configurable CORS origins via environment variable.

---

# 6.5 Data Integrity

- Foreign key constraints must be enforced.
- Activities must reference valid conversations.
- Conversations must reference valid active channels.
- Channels must reference valid tenants.
- Deliveries must reference valid activities and channels.
- Unique constraint on delivery per activity per channel.

---

# 7. Data Model (High-Level)

Entities:

- Tenant
- Channel (with type-specific config)
- Conversation
- Activity
- Delivery

Relationships:

- Tenant → Channels (1:N)
- Channel → Conversations (1:N)
- Conversation → Activities (1:N)
- Activity → Deliveries (1:N)
- Channel → Deliveries (1:N)

Activities and Deliveries expected to be highest growth entities.

---

# 8. Deployment Model

The system must support:

- Single service deployment (API + WebSocket)
- Separate admin interface (logical separation)
- PostgreSQL as primary datastore
- Oban for background job processing
- Horizontal scaling across multiple nodes
- Docker Compose for observability stack

---

# 9. Acceptance Criteria

The system is considered complete when:

- Tenants can be created and managed.
- Channels support all 5 types with configuration validation.
- Conversations validate channel status on creation.
- Activities are persisted, ordered, and delivered to external channels.
- WebSocket streaming works reliably with reconnect support.
- Inbound webhooks create activities correctly.
- Delivery system retries failed deliveries with backoff.
- Delivery status is tracked and visible in admin panel.
- Admin panel is IP-restricted (configurable).
- System sustains 1,000 concurrent connections without degradation.
- No cross-tenant data leakage occurs.

---

# 10. Success Metrics

- First production integration live.
- Zero cross-tenant isolation incidents.
- Stable load test at target concurrency.
- <1% message processing errors.
- No message loss events.
- >99% delivery success rate for external channels.
- <5s average delivery latency to external channels.

---

# 11. Risks and Mitigation

| Risk | Mitigation |
|------|------------|
| Database growth | Proper indexing, activity archival strategy |
| Cross-tenant data leak | Strict tenant scoping in all queries |
| WebSocket overload | Horizontal scaling |
| Abuse/spam | Rate limiting (IP + tenant scoped) |
| Ordering inconsistency | Conversation-level ordering strategy |
| External API failures | Oban retry with exponential backoff |
| Delivery data growth | Pruning old delivered records |
| WhatsApp API rate limits | Per-channel rate limiting |

---

# 12. Future Evolution

- Message routing rules (source channel -> target channels)
- Multi-channel conversations (fan-out)
- Media message support (images, documents, audio)
- Template message support (WhatsApp HSM)
- Delivery receipts / read receipts
- Channel health monitoring
- Message transformation pipeline
- Event streaming backbone (Kafka)
- Tenant sharding
- Multi-region replication
- Advanced analytics
- SLA tiers
- Enterprise access control (RBAC)

---

# 13. Product Principles

Converger is:

- A message routing hub, not just a messaging backbone
- Infrastructure-focused with pluggable adapters
- Multi-tenant by design
- Real-time first with reliable delivery
- Secure by default
- Horizontally scalable
- Customizable per channel type
