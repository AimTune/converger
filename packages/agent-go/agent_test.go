package agent

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const conv = "c0a8012e-7d3b-4c5e-9f1a-2b3c4d5e6f70"

func welcome() map[string]any {
	return map[string]any{"type": "welcome", "data": map[string]any{"protocol": "converger/1", "scope": "channel", "limits": map[string]any{}}}
}

func userTurn(seq int, text string) map[string]any {
	return map[string]any{"conversationId": conv, "frame": map[string]any{
		"type": "text", "id": "m", "seq": seq, "from": "user", "data": map[string]any{"text": text},
	}}
}

func start(t *testing.T, server *fakeServer, token TokenSource, h Handler, opts ...Option) (*Agent, chan error, context.CancelFunc) {
	t.Helper()
	opts = append([]Option{WithBackoff(5*time.Millisecond, 20*time.Millisecond)}, opts...)
	a := New(server.url(), token, opts...)
	a.OnTurn(h)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- a.Run(ctx) }()
	t.Cleanup(cancel)
	return a, done, cancel
}

func wait(t *testing.T, done chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return")
		return nil
	}
}

func TestMatcherAndSchemaRejectMismatches(t *testing.T) {
	caps := map[string]string{}
	if match(map[string]any{"type": "run"}, map[string]any{"type": "run", "extra": 1.0}, caps, "f") == nil {
		t.Error("extra keys must not match")
	}
	if match(map[string]any{"id": "{{x}}"}, map[string]any{"id": "y"}, map[string]string{"x": "z"}, "f") == nil {
		t.Error("a captured value must be compared")
	}
	envelope, _ := schemas(t)
	bad := map[string]any{"conversationId": conv, "frame": map[string]any{"type": "interrupt", "data": map[string]any{}}}
	if envelope.Validate(bad) == nil {
		t.Error("an interrupt without id and payload must not validate")
	}
}

func TestUnauthorizedTwiceEndsRun(t *testing.T) {
	server := newFakeServer(t, "tok")
	var calls atomic.Int32
	token := func(context.Context) (string, error) { calls.Add(1); return "tok", nil }
	_, done, _ := start(t, server, token, func(context.Context, *Turn, *Reply) error { return nil })

	for i := 0; i < 2; i++ {
		conn := server.accept()
		server.next(conn) // hello
		server.write(conn, map[string]any{"type": "error", "data": map[string]any{"code": "token_expired", "message": "expired", "retryable": true}})
		_ = conn.Close(4401, "")
	}
	err := wait(t, done)
	var ce *CloseError
	if !errors.As(err, &ce) || ce.Code != 4401 || ce.Last == nil || ce.Last.Code != "token_expired" {
		t.Fatalf("Run returned %v", err)
	}
	if calls.Load() != 2 {
		t.Fatalf("token source called %d times, want 2", calls.Load())
	}
}

func TestForbiddenEndsRun(t *testing.T) {
	server := newFakeServer(t, "tok")
	_, done, _ := start(t, server, StaticToken("tok"), func(context.Context, *Turn, *Reply) error { return nil })
	conn := server.accept()
	server.next(conn)
	_ = conn.Close(4403, "")
	var ce *CloseError
	if err := wait(t, done); !errors.As(err, &ce) || ce.Code != 4403 {
		t.Fatalf("Run returned %v", err)
	}
}

func TestPanickingHandlerEndsRunWithError(t *testing.T) {
	server := newFakeServer(t, "tok")
	reported := make(chan error, 1)
	_, _, _ = start(t, server, StaticToken("tok"),
		func(context.Context, *Turn, *Reply) error { panic("boom") },
		OnError(func(err error) { reported <- err }))
	conn := server.accept()
	server.next(conn)
	server.write(conn, welcome())
	server.write(conn, userTurn(1, "hi"))
	caps := map[string]string{}
	for _, status := range []string{"started", "error"} {
		got := server.next(conn)
		want := map[string]any{"conversationId": conv, "frame": map[string]any{"type": "run", "data": map[string]any{"status": status}}}
		if err := match(want, got, caps, "frame"); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case err := <-reported:
		if err == nil {
			t.Fatal("nil error reported")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the panic was not reported")
	}
}

func TestConversationsRunConcurrently(t *testing.T) {
	server := newFakeServer(t, "tok")
	release := make(chan struct{})
	started := make(chan string, 2)
	_, _, _ = start(t, server, StaticToken("tok"), func(ctx context.Context, turn *Turn, reply *Reply) error {
		started <- turn.ConversationID
		<-release
		return nil
	})
	conn := server.accept()
	server.next(conn)
	server.write(conn, welcome())
	server.write(conn, userTurn(1, "a"))
	other := userTurn(1, "b")
	other["conversationId"] = "other"
	server.write(conn, other)
	seen := map[string]bool{}
	for i := 0; i < 2; i++ {
		select {
		case id := <-started:
			seen[id] = true
		case <-time.After(2 * time.Second):
			t.Fatalf("only %v started", seen)
		}
	}
	close(release)
}

func TestCancelStopsWaitingAsk(t *testing.T) {
	server := newFakeServer(t, "tok")
	askErr := make(chan error, 1)
	_, done, cancel := start(t, server, StaticToken("tok"), func(ctx context.Context, turn *Turn, reply *Reply) error {
		_, err := reply.Ask(ctx, map[string]any{"title": "?"})
		askErr <- err
		return err
	})
	conn := server.accept()
	server.next(conn)
	server.write(conn, welcome())
	server.write(conn, userTurn(1, "hi"))
	server.next(conn) // run started
	if got := server.next(conn); got["frame"].(map[string]any)["type"] != "interrupt" {
		t.Fatalf("expected an interrupt, got %v", got)
	}
	cancel()
	if err := wait(t, done); err != nil {
		t.Fatalf("Run returned %v", err)
	}
	if err := <-askErr; err == nil {
		t.Fatal("Ask returned no error after cancel")
	}
	_ = conn.Close(websocket.StatusNormalClosure, "")
}
