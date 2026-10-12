package converger

// Models are hand-written to match the server today (docs/api/client-api.md
// and docs/api/tenant-api.md). Once the OpenAPI document of #45 ships at
// priv/static/openapi.json, scripts/generate.sh generates equivalent types
// with oapi-codegen into internal/gen; the names below stay the public API.

import (
	"encoding/json"
	"time"
)

// TokenResponse is returned by ClientAPI.GenerateToken and RefreshToken.
type TokenResponse struct {
	ConversationID *string `json:"conversationId"`
	Token          string  `json:"token"`
	ExpiresIn      int     `json:"expires_in"`
}

// ConversationToken is a conversation-bound token (ClientAPI.CreateConversation, GetConversation).
type ConversationToken struct {
	ConversationID string `json:"conversationId"`
	Token          string `json:"token"`
	ExpiresIn      int    `json:"expires_in"`
	StreamURL      string `json:"streamUrl,omitempty"`
}

// ConversationStatus is returned by ClientAPI.CloseConversation and ReopenConversation.
type ConversationStatus struct {
	ConversationID string `json:"conversationId"`
	Status         string `json:"status"`
}

// ResourceResponse is returned by ClientAPI.PostActivity.
type ResourceResponse struct {
	ID string `json:"id"`
}

// ChannelAccount identifies the sender of a client API activity.
type ChannelAccount struct {
	ID   string `json:"id"`
	Name string `json:"name,omitempty"`
}

// ClientActivity is an activity as the client API renders it.
type ClientActivity struct {
	ID             string           `json:"id"`
	Type           string           `json:"type"`
	From           *ChannelAccount  `json:"from"`
	Text           *string          `json:"text"`
	Timestamp      *time.Time       `json:"timestamp"`
	Attachments    []map[string]any `json:"attachments"`
	ConversationID string           `json:"conversationId"`
	ChannelData    map[string]any   `json:"channelData"`
	ReplyToID      *string          `json:"replyToId"`
	EditedAt       *time.Time       `json:"editedAt"`
	DeletedAt      *time.Time       `json:"deletedAt"`
}

// ClientActivityPage is a page of ClientAPI.ListActivities.
type ClientActivityPage struct {
	Activities []ClientActivity `json:"activities"`
	Watermark  *string          `json:"watermark"`
	HasMore    bool             `json:"has_more"`
}

// ClientActivityInput is the body of ClientAPI.PostActivity. Empty fields are omitted.
type ClientActivityInput struct {
	Type        string
	Text        string
	FromID      string
	Attachments []map[string]any
	ReplyToID   string
	ChannelData map[string]any
	// IdempotencyKey is sent as x-idempotency-key.
	IdempotencyKey string
}

// MarshalJSON renders the client API wire shape (camelCase, from.id).
func (a ClientActivityInput) MarshalJSON() ([]byte, error) {
	m := map[string]any{}
	put(m, "type", a.Type)
	put(m, "text", a.Text)
	if a.FromID != "" {
		m["from"] = map[string]string{"id": a.FromID}
	}
	if a.Attachments != nil {
		m["attachments"] = a.Attachments
	}
	put(m, "replyToId", a.ReplyToID)
	if a.ChannelData != nil {
		m["channelData"] = a.ChannelData
	}
	return json.Marshal(m)
}

// Participant is the external party of a conversation (for example a WhatsApp number).
type Participant struct {
	ID          string     `json:"id"`
	ExternalID  string     `json:"external_id"`
	DisplayName *string    `json:"display_name"`
	OptedOutAt  *time.Time `json:"opted_out_at"`
}

// Conversation is a conversation as the tenant API renders it.
type Conversation struct {
	ID              string           `json:"id"`
	Status          string           `json:"status"`
	Metadata        map[string]any   `json:"metadata"`
	ChannelID       string           `json:"channel_id"`
	OriginChannelID *string          `json:"origin_channel_id"`
	TenantID        string           `json:"tenant_id"`
	ParticipantID   *string          `json:"participant_id"`
	Participant     *Participant     `json:"participant"`
	Channels        []map[string]any `json:"channels,omitempty"`
	InsertedAt      *time.Time       `json:"inserted_at"`
	UpdatedAt       *time.Time       `json:"updated_at"`
}

// Activity is the canonical activity (tenant API, webhooks, delivery payloads).
type Activity struct {
	ID             string           `json:"id"`
	Type           string           `json:"type"`
	Sender         string           `json:"sender"`
	Text           *string          `json:"text"`
	Attachments    []map[string]any `json:"attachments"`
	Metadata       map[string]any   `json:"metadata"`
	IdempotencyKey *string          `json:"idempotency_key"`
	Seq            int              `json:"seq"`
	ReplyToID      *string          `json:"reply_to_id"`
	EditedAt       *time.Time       `json:"edited_at"`
	DeletedAt      *time.Time       `json:"deleted_at"`
	ConversationID string           `json:"conversation_id"`
	TenantID       string           `json:"tenant_id"`
	InsertedAt     *time.Time       `json:"inserted_at"`
}

// WebhookEvent is the body of an outbound webhook: the canonical activity plus timestamp.
type WebhookEvent struct {
	Activity
	Timestamp *time.Time `json:"timestamp"`
}

// ActivityInput is the body of TenantAPI.PostActivity. Empty fields are omitted.
type ActivityInput struct {
	Type        string           `json:"type,omitempty"`
	Sender      string           `json:"sender,omitempty"`
	Text        string           `json:"text,omitempty"`
	Attachments []map[string]any `json:"attachments,omitempty"`
	Metadata    map[string]any   `json:"metadata,omitempty"`
	ReplyToID   string           `json:"reply_to_id,omitempty"`
	// IdempotencyKey is sent as x-idempotency-key.
	IdempotencyKey string `json:"-"`
}

// ConversationPage is a keyset page of TenantAPI.ListConversations.
type ConversationPage struct {
	Data       []Conversation
	NextCursor *string
	HasMore    bool
	Limit      int
}

// ActivityPage is a watermark page of TenantAPI.ListActivities.
type ActivityPage struct {
	Data      []Activity
	Watermark *string
	HasMore   bool
	Limit     int
}

// Ack is the server's ack for a socket send with a clientId.
type Ack struct {
	ClientID  string `json:"clientId"`
	ID        string `json:"id"`
	Seq       int    `json:"seq"`
	Timestamp int64  `json:"timestamp"`
	Duplicate bool   `json:"duplicate"`
}

func put(m map[string]any, k, v string) {
	if v != "" {
		m[k] = v
	}
}
