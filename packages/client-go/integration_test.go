package converger

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"testing"
	"time"
)

// TestIntegration runs against a real server started by
// packages/conformance/integration/run.sh. It is skipped unless
// CONVERGER_FIXTURES points at the fixtures file.
func TestIntegration(t *testing.T) {
	path := os.Getenv("CONVERGER_FIXTURES")
	if path == "" {
		t.Skip("set CONVERGER_FIXTURES to run against a real server")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]json.RawMessage
	_ = json.Unmarshal(raw, &doc)
	var fx struct {
		APIKey        string `json:"api_key"`
		ChannelSecret string `json:"channel_secret"`
		WebhookSecret string `json:"webhook_secret"`
		WebhookPort   int    `json:"webhook_port"`
	}
	_ = json.Unmarshal(doc["go"], &fx)
	var baseURL string
	_ = json.Unmarshal(doc["base_url"], &baseURL)
	if v := os.Getenv("CONVERGER_BASE_URL"); v != "" {
		baseURL = v
	}

	type hook struct {
		header http.Header
		body   []byte
	}
	hooks := make(chan hook, 16)
	ln, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", fx.WebhookPort))
	if err != nil {
		t.Fatal(err)
	}
	hookSrv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		hooks <- hook{r.Header.Clone(), b}
		w.WriteHeader(http.StatusOK)
	})}
	go func() { _ = hookSrv.Serve(ln) }()
	defer hookSrv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	c := New(baseURL, WithAPIKey(fx.APIKey), WithChannelSecret(fx.ChannelSecret))
	marker := fmt.Sprintf("go-%d", time.Now().UnixNano())

	// create a conversation
	tok, err := c.ClientAPI.GenerateToken(ctx, GenerateTokenParams{UserID: "sdk-go"})
	if err != nil {
		t.Fatal(err)
	}
	conv, err := c.ClientAPI.CreateConversation(ctx, tok.Token)
	if err != nil {
		t.Fatal(err)
	}

	// send over the socket and receive a bot reply on it
	s, err := c.Dial(ctx, StaticToken(conv.Token), WithConversationID(conv.ConversationID))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ack, err := s.SendText(ctx, marker+" ws")
	if err != nil || ack.Seq < 1 {
		t.Fatalf("ack %+v err %v", ack, err)
	}
	reply, err := c.TenantAPI.PostActivity(ctx, conv.ConversationID, ActivityInput{Sender: "bot", Text: marker + " bot"})
	if err != nil {
		t.Fatal(err)
	}
	for {
		f, err := s.Recv(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if seq, ok := asInt(f["seq"]); ok && seq == reply.Seq {
			if f["data"].(map[string]any)["text"] != marker+" bot" {
				t.Fatalf("frame %v", f)
			}
			break
		}
	}
	if s.Watermark() != reply.Seq {
		t.Fatalf("watermark %d, want %d", s.Watermark(), reply.Seq)
	}

	// REST read-back and idempotency
	page, err := c.ClientAPI.ListActivities(ctx, conv.Token, conv.ConversationID, ListActivitiesParams{})
	if err != nil || len(page.Activities) < 2 || *page.Activities[0].Text != marker+" ws" {
		t.Fatalf("page %+v err %v", page, err)
	}
	a1, err := c.ClientAPI.PostActivity(ctx, conv.Token, conv.ConversationID, ClientActivityInput{Text: "hi", IdempotencyKey: "k-1"})
	if err != nil {
		t.Fatal(err)
	}
	a2, _ := c.ClientAPI.PostActivity(ctx, conv.Token, conv.ConversationID, ClientActivityInput{Text: "hi", IdempotencyKey: "k-1"})
	if a1.ID != a2.ID {
		t.Fatalf("idempotency: %s != %s", a1.ID, a2.ID)
	}

	// the webhook channel receives the activity, signed with its secret
	for {
		select {
		case h := <-hooks:
			if err := VerifySignature(h.header, h.body, fx.WebhookSecret); err != nil {
				t.Fatal(err)
			}
			var ev WebhookEvent
			if err := json.Unmarshal(h.body, &ev); err != nil {
				t.Fatal(err)
			}
			if ev.ConversationID != conv.ConversationID {
				continue
			}
		case <-ctx.Done():
			t.Fatal("no webhook delivery")
		}
		break
	}

	// closed conversations refuse sends with the normalized error
	if _, err := c.TenantAPI.CloseConversation(ctx, conv.ConversationID); err != nil {
		t.Fatal(err)
	}
	_, err = c.ClientAPI.PostActivity(ctx, conv.Token, conv.ConversationID, ClientActivityInput{Text: "late"})
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Status != 409 || apiErr.Code != "conversation_closed" {
		t.Fatalf("got %v", err)
	}
}
