# converger-go

Server-side Go SDK for [Converger](https://converger.aimtune.dev): a REST client for the client API and the
tenant API, a [Protocol v1](https://converger.aimtune.dev/protocol/v1) WebSocket client with resume
(`github.com/coder/websocket`), and outbound webhook signature verification.

```bash
go get github.com/AimTune/converger/packages/client-go
```

Go 1.22+. Releases are tags `packages/client-go/vX.Y.Z` (the module lives in a subdirectory of the monorepo).
Full documentation: [converger.aimtune.dev/sdk/go](https://converger.aimtune.dev/sdk/go).

## REST

```go
import converger "github.com/AimTune/converger/packages/client-go"

c := converger.New("https://chat.example.com",
	converger.WithAPIKey(os.Getenv("CONVERGER_API_KEY")),
	converger.WithChannelSecret(os.Getenv("CONVERGER_CHANNEL_SECRET")))

tok, err := c.ClientAPI.GenerateToken(ctx, converger.GenerateTokenParams{UserID: "user-42"})
conv, err := c.ClientAPI.CreateConversation(ctx, tok.Token)
_, err = c.ClientAPI.PostActivity(ctx, conv.Token, conv.ConversationID,
	converger.ClientActivityInput{Text: "Hi!", IdempotencyKey: "msg-1"})

reply, err := c.TenantAPI.PostActivity(ctx, conv.ConversationID,
	converger.ActivityInput{Sender: "bot", Text: "Hello, how can I help?"})
```

Errors are `*converger.APIError` (`Status`, `Code`, `Message`, `Details`, `RequestID`, `RetryAfter`), the same
whatever error shape the server used.

## WebSocket (Protocol v1)

```go
s, err := c.Dial(ctx, converger.StaticToken(conv.Token), converger.WithConversationID(conv.ConversationID))
if err != nil { return err }
defer s.Close()

ack, err := s.SendText(ctx, "Where is my order?")   // waits for the ack (ID, Seq)
for {
	frame, err := s.Recv(ctx)                         // persistent frames in seq order, exactly once
	if err != nil { return err }                      // *converger.CloseError when the socket ended for good
	fmt.Println(frame["type"], frame["data"])
}
```

The socket reconnects with jittered backoff, resumes from `s.Watermark()` (pass `WithWatermark` to resume a
stored position), re-sends unacknowledged sends with their original `clientId`, and answers gaps with `sync`.
Pass a `TokenSource` that fetches a fresh token to survive token expiry (close 4401).

## Webhook signature verification

```go
http.HandleFunc("/converger/webhook", func(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	if err := converger.VerifySignature(r.Header, body, secret); err != nil {
		http.Error(w, err.Error(), http.StatusUnauthorized) // errors.Is(err, converger.ErrInvalidSignature), ...
		return
	}
	var ev converger.WebhookEvent
	_ = json.Unmarshal(body, &ev)
	// deduplicate on r.Header.Get("X-Converger-Delivery-Id")
	w.WriteHeader(http.StatusOK)
})
```

`VerifySignatureSecrets` accepts several secrets while rotating; `WithTolerance` changes the 5 minute window.

## Development

```bash
go test ./...                                                     # unit + conformance (packages/conformance)
CONVERGER_FIXTURES=../conformance/integration/fixtures.json go test -run TestIntegration ./...
```

Types are hand-written today; `scripts/generate.sh` generates models and a low-level client with oapi-codegen
(`oapi-codegen.yaml`) once [#45](https://github.com/AimTune/converger/issues/45) ships `priv/static/openapi.json`.
