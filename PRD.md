# Converger MVP — Product Requirements Document (PRD)

## Version
v1.0 (MVP)

## Document Status
Draft – Product Baseline

---

# 1. Overview

## 1.1 Purpose

Converger is a multi-tenant, real-time conversation messaging backbone that enables applications to create conversations, exchange activities, and stream messages in real time.

The MVP provides:

- Tenant isolation
- Channel-based access control
- Conversation lifecycle management
- Activity persistence
- Real-time WebSocket streaming
- Token-based authentication
- IP-restricted admin panel

The MVP validates product viability and supports early production workloads (up to ~10M messages/day).

---

# 2. Objectives

## 2.1 Business Objectives

- Enable early adopters to integrate messaging via API.
- Validate multi-tenant architecture.
- Provide stable real-time infrastructure.
- Establish foundation for horizontal scalability.

## 2.2 Technical Objectives

- Stateless API layer.
- Tenant-scoped data model.
- Ordered activity delivery per conversation.
- WebSocket-based real-time streaming.
- Secure token issuance and validation.

---

# 3. Scope

## 3.1 In Scope

- Tenant creation and management
- Channel creation and secret-based authentication
- Conversation creation and retrieval
- Activity creation and listing
- Real-time streaming via WebSocket
- Short-lived client token issuance
- Admin panel with IP restriction
- Horizontal scaling support

## 3.2 Out of Scope (MVP)

- Multi-region deployment
- Event streaming backbone (e.g., Kafka)
- Advanced analytics dashboards
- SLA tiering
- Cross-tenant sharding
- Enterprise RBAC
- Third-party channel adapters

---

# 4. User Personas

## 4.1 Platform Integrator

Description: Developer integrating Converger into an application.

Needs:
- Stable REST API
- Real-time streaming
- Simple authentication model
- Reliable ordering

---

## 4.2 System Administrator

Description: Internal operator managing tenants and monitoring usage.

Needs:
- Admin interface
- Tenant visibility
- Conversation overview
- Basic operational metrics

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
- Secret
- Status (active/inactive)

The system must:
- Validate channel secret on requests.
- Scope conversations to a specific channel.
- Reject requests for inactive channels.

---

# 5.3 Conversation Management

The system must allow:

- Create conversation
- Retrieve conversation
- List conversation activities
- Optionally close conversation

Each conversation must:
- Belong to exactly one tenant
- Belong to exactly one channel
- Have a unique ID
- Have status (active/closed)
- Have timestamps

---

# 5.4 Activity Management

The system must allow:

- Create activity within conversation
- Retrieve ordered activities

Activity must support:
- type (message, event, typing)
- text (optional)
- attachments (optional URL)
- sender identifier
- timestamp

Each activity must:
- Belong to one conversation
- Belong to one tenant
- Have unique ID
- Preserve order within conversation

Ordering guarantee:
- Activities must be returned in creation order per conversation.

---

# 5.5 Real-Time Streaming

The system must provide a WebSocket endpoint that:

- Authenticates via client token
- Subscribes client to conversation topic
- Streams new activities in real time
- Supports reconnect and resume

Requirements:

- Maintain per-conversation ordering.
- Allow multiple concurrent connections.
- Broadcast new activities immediately after persistence.
- Support client reconnect with watermark (last activity ID).

---

# 5.6 Authentication

The system must support two authentication layers:

## 5.6.1 Tenant API Key (Server-to-Server)

- Required for REST API calls.
- Scoped to tenant.
- Must be validated per request.

## 5.6.2 Client Token (JWT)

- Short-lived (e.g., 1 hour).
- Issued via secure endpoint.
- Scoped to specific conversation.
- Signed and verifiable.
- Must be validated on WebSocket connection.

---

# 5.7 Admin Panel

The system must provide an internal admin panel that:

- Is accessible only from whitelisted IP(s).
- Is not publicly exposed.
- Allows:
  - Viewing tenants
  - Creating tenants
  - Viewing channels
  - Viewing conversations
  - Inspecting activities

Admin access must not interfere with core messaging performance.

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
- Recover gracefully from node restart.
- Guarantee at-least-once persistence.

---

# 6.4 Security

The system must:

- Enforce HTTPS.
- Validate JWT signatures.
- Enforce tenant isolation in all queries.
- Restrict admin access by IP.
- Store secrets securely.

---

# 6.5 Data Integrity

- Foreign key constraints must be enforced.
- Activities must reference valid conversations.
- Conversations must reference valid channels.
- Channels must reference valid tenants.

---

# 7. Data Model (High-Level)

Entities:

- Tenant
- Channel
- Conversation
- Activity

Relationships:

- Tenant → Channels (1:N)
- Channel → Conversations (1:N)
- Conversation → Activities (1:N)

Activities expected to be highest growth entity.

---

# 8. Deployment Model (MVP)

The system must support:

- Single service deployment (API + WebSocket)
- Separate admin interface (logical or physical separation)
- PostgreSQL as primary datastore
- Horizontal scaling across multiple nodes

---

# 9. Acceptance Criteria

MVP is considered complete when:

- Tenants can be created and managed.
- Channels validate via secret.
- Conversations can be created and retrieved.
- Activities are persisted and ordered.
- WebSocket streaming works reliably.
- Admin panel is IP-restricted.
- System sustains 1,000 concurrent connections without degradation.
- No cross-tenant data leakage occurs.

---

# 10. Success Metrics

- First production integration live.
- Zero cross-tenant isolation incidents.
- Stable load test at target concurrency.
- <1% message processing errors.
- No message loss events.

---

# 11. Risks and Mitigation

| Risk | Mitigation |
|------|------------|
| Database growth | Proper indexing |
| Cross-tenant data leak | Strict tenant scoping |
| WebSocket overload | Horizontal scaling |
| Abuse/spam | Rate limiting |
| Ordering inconsistency | Conversation-level ordering strategy |

---

# 12. Future Evolution (Post-MVP)

- Event streaming backbone
- Tenant sharding
- Multi-region replication
- Advanced analytics
- Adapter framework
- SLA tiers
- Enterprise access control

---

# 13. Product Principles

Converger MVP is:

- Infrastructure-focused
- Multi-tenant by design
- Real-time first
- Secure by default
- Horizontally scalable
- Minimal but production-ready
