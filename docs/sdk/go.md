---
title: Go SDK (converger-go)
description: The server-side Go SDK - REST client for the client and tenant APIs, the Protocol v1 WebSocket client with resume, and webhook signature verification.
sidebar_position: 4
---

The Go SDK is a REST client for the client API and the tenant API, a [Protocol v1](../protocol/v1.md) WebSocket
client with resume built on [`github.com/coder/websocket`](https://github.com/coder/websocket) (the maintained
successor of `nhooyr.io/websocket`), and webhook signature verification. Source:
[`packages/client-go`](https://github.com/AimTune/converger/tree/main/packages/client-go). What all SDKs share is
described in [Server-side SDKs](server-sdks.md).

```bash
go get github.com/AimTune/converger/packages/client-go
```

Go 1.22 or later. The module lives in a subdirectory of the monorepo, so its versions are tags named
`packages/client-go/vX.Y.Z`.

## Client

```go
import converger "github.com/AimTune/converger/packages/client-go"

c := converger.New("https://chat.example.com",
	converger.WithAPIKey(os.Getenv("CONVERGER_API_KEY")),
	converger.WithChannelSecret(os.Getenv("CONVERGER_CHANNEL_SECRET")))
```

Options: `WithAPIKey` (tenant API), `WithChannelSecret` (`ClientAPI.GenerateToken`), `WithHTTPClient` (default:
10 s timeout). Every method takes a `context.Context`.

### `c.ClientAPI`

| Method | Endpoint | Returns |
| --- | --- | --- |
| `GenerateToken(ctx, GenerateTokenParams{UserID, Scope})` | `POST /api/v1/converger/tokens/generate` | `*TokenResponse` |
| `RefreshToken(ctx, token)` | `POST /api/v1/converger/tokens/refresh` | `*TokenResponse` |
| `CreateConversation(ctx, token)` | `POST /api/v1/converger/conversations` | `*ConversationToken` |
| `GetConversation(ctx, token, id, watermark)` | `GET /api/v1/converger/conversations/:id` | `*ConversationToken` |
| `CloseConversation`, `ReopenConversation(ctx, token, id)` | `POST .../close`, `.../reopen` | `*ConversationStatus` |
| `PostActivity(ctx, token, id, ClientActivityInput{Type, Text, FromID, Attachments, ReplyToID, ChannelData, IdempotencyKey})` | `POST .../activities` | `*ResourceResponse` |
| `ListActivities(ctx, token, id, ListActivitiesParams{Watermark, Limit})` | `GET .../activities` | `*ClientActivityPage` |

### `c.TenantAPI`

| Method | Endpoint | Returns |
| --- | --- | --- |
| `ListConversations(ctx, ListConversationsParams{Limit, Cursor, Status, ChannelID, ExternalID})` | `GET /api/v1/conversations` | `*ConversationPage` |
| `GetConversation`, `CloseConversation`, `ReopenConversation(ctx, id)` | `/api/v1/conversations/:id[...]` | `*Conversation` |
| `PostActivity(ctx, id, ActivityInput{Type, Sender, Text, Attachments, Metadata, ReplyToID, IdempotencyKey})` | `POST .../activities` | `*Activity` |
| `ListActivities(ctx, id, ListActivitiesParams{Watermark, Limit})` | `GET .../activities` | `*ActivityPage` |

Page watermarks are a `converger.Watermark`, which decodes the integer seq of v3.0 servers (a JSON number) and the
opaque string of older ones ([migration](../protocol/v1.md#65-the-watermark-and-its-migration)). Pass it back
unchanged (`ListActivitiesParams{Watermark: *page.Watermark}`); `Seq()` returns the integer, `SeqWatermark(n)`
builds one from a socket's `Watermark()`.

Errors from the server are `*converger.APIError` (`Status`, `Code`, `Message`, `Details`, `RequestID`,
`RetryAfter`, `Body`), normalized as described in [Server-side SDKs](server-sdks.md#errors):

```go
var apiErr *converger.APIError
if errors.As(err, &apiErr) && apiErr.Code == "conversation_closed" { ... }
```

## WebSocket (Protocol v1)

```go
s, err := c.Dial(ctx, converger.StaticToken(conv.Token), converger.WithConversationID(conv.ConversationID))
if err != nil {
	return err
}
defer s.Close()

ack, err := s.SendText(ctx, "Where is my order?") // *Ack{ClientID, ID, Seq, Duplicate}
for {
	frame, err := s.Recv(ctx) // map[string]any; persistent frames in seq order, exactly once
	if err != nil {
		return err // *converger.CloseError{Code, Reason} once the socket ended for good
	}
	fmt.Println(frame["type"], frame["data"])
}
```

| | |
| --- | --- |
| `c.Dial(ctx, TokenSource, ...SocketOption)` / `converger.Dial(ctx, url, ...)` | waits for the first `welcome` |
| `TokenSource` | `func(ctx) (string, error)`, called on every connect; `StaticToken(t)` for a fixed token |
| options | `WithWatermark`, `WithConversationID`, `WithReconnect`, `WithMaxRetries`, `WithBackoff(initial, max)`, `WithAckTimeout`, `WithSocketHeader` |
| `SendText`, `SendMessage(ctx, type, data, SendOptions{ClientID, Metadata, ReplyTo})` | wait for the `ack`; a refusal is a `*ProtocolError` (`Code`, `Retryable`, `RetryAfterMs`) |
| `Recv(ctx)`, `Typing(bool)`, `Read(watermark)`, `Watermark()`, `ConversationID()`, `Welcome()`, `Close()` | |

The methods are safe for concurrent use. `converger.Session` is the transport-independent resume state machine.

## Webhook signature verification

```go
http.HandleFunc("/converger/webhook", func(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	if err := converger.VerifySignature(r.Header, body, secret); err != nil {
		http.Error(w, err.Error(), http.StatusUnauthorized)
		return
	}
	var ev converger.WebhookEvent
	_ = json.Unmarshal(body, &ev)
	// deduplicate on r.Header.Get("X-Converger-Delivery-Id")
	w.WriteHeader(http.StatusOK)
})
```

`VerifySignatureSecrets(header, body, []string{newSecret, oldSecret})` accepts several secrets while rotating.
Options: `WithTolerance(d)` (default 5 minutes), `WithNow(fn)`. The errors are `ErrMissingSignature`,
`ErrNoSecret`, `ErrMalformedSignature`, `ErrTimestampOutOfTolerance` and `ErrInvalidSignature` (compare with
`errors.Is`). `Sign(secret, body, time)` builds a header for tests.

## Development

```bash
cd packages/client-go
go test -race ./...          # unit, transport and conformance tests
```

Releases: push a tag `packages/client-go/vX.Y.Z` (matching `Version` in `client.go`).
