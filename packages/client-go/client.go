// Package converger is the server-side Go SDK for Converger: a REST client
// for the client API (ClientAPI) and the tenant API (TenantAPI), a Protocol
// v1 WebSocket client with resume (Socket), and outbound webhook signature
// verification (VerifySignature).
package converger

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Version is the SDK version, sent in the User-Agent.
const Version = "0.1.0"

// Client talks to one Converger server.
type Client struct {
	baseURL       string
	apiKey        string
	channelSecret string
	http          *http.Client
	userAgent     string

	// ClientAPI is the client API under /api/v1/converger (converger tokens).
	ClientAPI *ClientAPI
	// TenantAPI is the tenant API under /api/v1 (x-api-key).
	TenantAPI *TenantAPI
}

// Option configures a Client.
type Option func(*Client)

// WithAPIKey sets the tenant API key (needed for TenantAPI). Server-side only.
func WithAPIKey(key string) Option { return func(c *Client) { c.apiKey = key } }

// WithChannelSecret sets the channel secret (needed for ClientAPI.GenerateToken). Server-side only.
func WithChannelSecret(secret string) Option { return func(c *Client) { c.channelSecret = secret } }

// WithHTTPClient replaces the HTTP client (default: 10 s timeout).
func WithHTTPClient(h *http.Client) Option { return func(c *Client) { c.http = h } }

// New creates a client for baseURL (for example https://chat.example.com).
func New(baseURL string, opts ...Option) *Client {
	c := &Client{
		baseURL:   strings.TrimRight(baseURL, "/"),
		http:      &http.Client{Timeout: 10 * time.Second},
		userAgent: "converger-go/" + Version,
	}
	for _, o := range opts {
		o(c)
	}
	c.ClientAPI = &ClientAPI{c}
	c.TenantAPI = &TenantAPI{c}
	return c
}

// BaseURL returns the server base URL.
func (c *Client) BaseURL() string { return c.baseURL }

type request struct {
	method  string
	path    string
	query   url.Values
	headers map[string]string
	body    any
}

func seg(s string) string { return url.PathEscape(s) }

func (c *Client) do(ctx context.Context, r request, out any) error {
	u := c.baseURL + r.path
	if len(r.query) > 0 {
		u += "?" + r.query.Encode()
	}
	var body io.Reader
	if r.body != nil {
		b, err := json.Marshal(r.body)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, r.method, u, body)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", c.userAgent)
	if r.body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range r.headers {
		req.Header.Set(k, v)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode >= 400 {
		return ParseAPIError(resp.StatusCode, resp.Header, raw)
	}
	if out == nil || len(raw) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("converger: decoding %s %s: %w", r.method, r.path, err)
	}
	return nil
}

func bearer(token, what string) (map[string]string, error) {
	if token == "" {
		return nil, fmt.Errorf("converger: %s is required", what)
	}
	return map[string]string{"Authorization": "Bearer " + token}, nil
}

func (c *Client) apiKeyHeader() (map[string]string, error) {
	if c.apiKey == "" {
		return nil, errors.New("converger: an API key is required for the tenant API (WithAPIKey)")
	}
	return map[string]string{"X-Api-Key": c.apiKey}, nil
}

func query(kv ...string) url.Values {
	q := url.Values{}
	for i := 0; i+1 < len(kv); i += 2 {
		if kv[i+1] != "" {
			q.Set(kv[i], kv[i+1])
		}
	}
	return q
}

func itoa(n int) string {
	if n <= 0 {
		return ""
	}
	return strconv.Itoa(n)
}

// ListActivitiesParams pages activities after a watermark.
type ListActivitiesParams struct {
	// Watermark is the watermark of the previous page (an opaque string or an integer seq).
	Watermark string
	// Limit is the page size (server default 100, max 1000).
	Limit int
}

// ---------------------------------------------------------------- client API

// ClientAPI is the client API under /api/v1/converger.
type ClientAPI struct{ c *Client }

// GenerateTokenParams are the optional fields of GenerateToken.
type GenerateTokenParams struct {
	// UserID becomes the token's user_id claim.
	UserID string
	// Scope "channel" issues a channel-scoped token (agent sockets).
	Scope string
}

// GenerateToken exchanges the channel secret for a converger token.
func (a *ClientAPI) GenerateToken(ctx context.Context, p GenerateTokenParams) (*TokenResponse, error) {
	h, err := bearer(a.c.channelSecret, "channel secret (WithChannelSecret)")
	if err != nil {
		return nil, err
	}
	body := map[string]any{}
	if p.UserID != "" {
		body["user"] = map[string]string{"id": p.UserID}
	}
	if p.Scope != "" {
		body["scope"] = p.Scope
	}
	var out TokenResponse
	if err := a.c.do(ctx, request{method: "POST", path: "/api/v1/converger/tokens/generate", headers: h, body: body}, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// RefreshToken exchanges a valid token for a fresh one.
func (a *ClientAPI) RefreshToken(ctx context.Context, token string) (*TokenResponse, error) {
	h, err := bearer(token, "token")
	if err != nil {
		return nil, err
	}
	var out TokenResponse
	if err := a.c.do(ctx, request{method: "POST", path: "/api/v1/converger/tokens/refresh", headers: h}, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// CreateConversation starts a conversation; the returned token is bound to it.
func (a *ClientAPI) CreateConversation(ctx context.Context, token string) (*ConversationToken, error) {
	h, err := bearer(token, "token")
	if err != nil {
		return nil, err
	}
	var out ConversationToken
	if err := a.c.do(ctx, request{method: "POST", path: "/api/v1/converger/conversations", headers: h}, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// GetConversation returns a new conversation-bound token for an existing
// conversation. watermark may be empty.
func (a *ClientAPI) GetConversation(ctx context.Context, token, conversationID, watermark string) (*ConversationToken, error) {
	h, err := bearer(token, "token")
	if err != nil {
		return nil, err
	}
	var out ConversationToken
	r := request{method: "GET", path: "/api/v1/converger/conversations/" + seg(conversationID), query: query("watermark", watermark), headers: h}
	if err := a.c.do(ctx, r, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (a *ClientAPI) transition(ctx context.Context, token, conversationID, action string) (*ConversationStatus, error) {
	h, err := bearer(token, "token")
	if err != nil {
		return nil, err
	}
	var out ConversationStatus
	r := request{method: "POST", path: "/api/v1/converger/conversations/" + seg(conversationID) + "/" + action, headers: h}
	if err := a.c.do(ctx, r, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// CloseConversation closes a conversation.
func (a *ClientAPI) CloseConversation(ctx context.Context, token, conversationID string) (*ConversationStatus, error) {
	return a.transition(ctx, token, conversationID, "close")
}

// ReopenConversation reopens a closed conversation.
func (a *ClientAPI) ReopenConversation(ctx context.Context, token, conversationID string) (*ConversationStatus, error) {
	return a.transition(ctx, token, conversationID, "reopen")
}

// PostActivity posts an activity as the end user.
func (a *ClientAPI) PostActivity(ctx context.Context, token, conversationID string, in ClientActivityInput) (*ResourceResponse, error) {
	h, err := bearer(token, "token")
	if err != nil {
		return nil, err
	}
	if in.IdempotencyKey != "" {
		h["X-Idempotency-Key"] = in.IdempotencyKey
	}
	var out ResourceResponse
	r := request{method: "POST", path: "/api/v1/converger/conversations/" + seg(conversationID) + "/activities", headers: h, body: in}
	if err := a.c.do(ctx, r, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// ListActivities lists activities after a watermark, oldest first.
func (a *ClientAPI) ListActivities(ctx context.Context, token, conversationID string, p ListActivitiesParams) (*ClientActivityPage, error) {
	h, err := bearer(token, "token")
	if err != nil {
		return nil, err
	}
	var out ClientActivityPage
	r := request{
		method:  "GET",
		path:    "/api/v1/converger/conversations/" + seg(conversationID) + "/activities",
		query:   query("watermark", p.Watermark, "limit", itoa(p.Limit)),
		headers: h,
	}
	if err := a.c.do(ctx, r, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// ---------------------------------------------------------------- tenant API

// TenantAPI is the tenant API under /api/v1.
type TenantAPI struct{ c *Client }

// ListConversationsParams filters and pages TenantAPI.ListConversations.
type ListConversationsParams struct {
	Limit      int
	Cursor     string
	Status     string
	ChannelID  string
	ExternalID string
}

type dataEnvelope[T any] struct {
	Data T `json:"data"`
}

type listEnvelope[T any] struct {
	Data []T `json:"data"`
	Meta struct {
		NextCursor *string `json:"next_cursor"`
		Watermark  *string `json:"watermark"`
		HasMore    bool    `json:"has_more"`
		Limit      int     `json:"limit"`
	} `json:"meta"`
}

// ListConversations lists the tenant's conversations, newest first.
func (a *TenantAPI) ListConversations(ctx context.Context, p ListConversationsParams) (*ConversationPage, error) {
	h, err := a.c.apiKeyHeader()
	if err != nil {
		return nil, err
	}
	var env listEnvelope[Conversation]
	q := query("limit", itoa(p.Limit), "cursor", p.Cursor, "status", p.Status, "channel_id", p.ChannelID, "external_id", p.ExternalID)
	if err := a.c.do(ctx, request{method: "GET", path: "/api/v1/conversations", query: q, headers: h}, &env); err != nil {
		return nil, err
	}
	return &ConversationPage{Data: env.Data, NextCursor: env.Meta.NextCursor, HasMore: env.Meta.HasMore, Limit: env.Meta.Limit}, nil
}

func (a *TenantAPI) conversation(ctx context.Context, method, path string) (*Conversation, error) {
	h, err := a.c.apiKeyHeader()
	if err != nil {
		return nil, err
	}
	var env dataEnvelope[Conversation]
	if err := a.c.do(ctx, request{method: method, path: path, headers: h}, &env); err != nil {
		return nil, err
	}
	return &env.Data, nil
}

// GetConversation returns a conversation with its participant.
func (a *TenantAPI) GetConversation(ctx context.Context, conversationID string) (*Conversation, error) {
	return a.conversation(ctx, "GET", "/api/v1/conversations/"+seg(conversationID))
}

// CloseConversation closes a conversation.
func (a *TenantAPI) CloseConversation(ctx context.Context, conversationID string) (*Conversation, error) {
	return a.conversation(ctx, "POST", "/api/v1/conversations/"+seg(conversationID)+"/close")
}

// ReopenConversation reopens a closed conversation.
func (a *TenantAPI) ReopenConversation(ctx context.Context, conversationID string) (*Conversation, error) {
	return a.conversation(ctx, "POST", "/api/v1/conversations/"+seg(conversationID)+"/reopen")
}

// PostActivity posts an activity (for example a bot reply with Sender "bot").
func (a *TenantAPI) PostActivity(ctx context.Context, conversationID string, in ActivityInput) (*Activity, error) {
	h, err := a.c.apiKeyHeader()
	if err != nil {
		return nil, err
	}
	if in.IdempotencyKey != "" {
		h["X-Idempotency-Key"] = in.IdempotencyKey
	}
	var env dataEnvelope[Activity]
	r := request{method: "POST", path: "/api/v1/conversations/" + seg(conversationID) + "/activities", headers: h, body: in}
	if err := a.c.do(ctx, r, &env); err != nil {
		return nil, err
	}
	return &env.Data, nil
}

// ListActivities lists a conversation's activities after a watermark, oldest first.
func (a *TenantAPI) ListActivities(ctx context.Context, conversationID string, p ListActivitiesParams) (*ActivityPage, error) {
	h, err := a.c.apiKeyHeader()
	if err != nil {
		return nil, err
	}
	var env listEnvelope[Activity]
	r := request{
		method:  "GET",
		path:    "/api/v1/conversations/" + seg(conversationID) + "/activities",
		query:   query("watermark", p.Watermark, "limit", itoa(p.Limit)),
		headers: h,
	}
	if err := a.c.do(ctx, r, &env); err != nil {
		return nil, err
	}
	return &ActivityPage{Data: env.Data, Watermark: env.Meta.Watermark, HasMore: env.Meta.HasMore, Limit: env.Meta.Limit}, nil
}
