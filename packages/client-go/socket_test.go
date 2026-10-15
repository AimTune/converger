package converger

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeServer is an in-process stand-in for the native endpoint.
type fakeServer struct {
	mu               sync.Mutex
	frames           []Frame
	hellos           []Frame
	received         []Frame
	subprotocols     []string
	closeAfterReplay []websocket.StatusCode
	dropFirstText    bool
	acked            map[string]Frame
	conns            map[*websocket.Conn]bool
}

func newFakeServer(n int) *fakeServer {
	f := &fakeServer{acked: map[string]Frame{}, conns: map[*websocket.Conn]bool{}}
	for i := 1; i <= n; i++ {
		f.frames = append(f.frames, textFrame(i, "bot", fmt.Sprintf("m%d", i), ""))
	}
	return f
}

func textFrame(seq int, from, text, clientID string) Frame {
	f := Frame{"type": "text", "id": fmt.Sprintf("a-%d", seq), "seq": seq, "from": from, "data": map[string]any{"text": text}}
	if clientID != "" {
		f["clientId"] = clientID
	}
	return f
}

func send(ctx context.Context, c *websocket.Conn, f Frame) {
	b, _ := json.Marshal(f)
	_ = c.Write(ctx, websocket.MessageText, b)
}

func (f *fakeServer) push(ctx context.Context, from, text string) {
	f.mu.Lock()
	frame := textFrame(len(f.frames)+1, from, text, "")
	f.frames = append(f.frames, frame)
	conns := []*websocket.Conn{}
	for c := range f.conns {
		conns = append(conns, c)
	}
	f.mu.Unlock()
	for _, c := range conns {
		send(ctx, c, frame)
	}
}

func (f *fakeServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{Subprotocol}})
	if err != nil {
		return
	}
	defer c.CloseNow()
	ctx := r.Context()
	f.mu.Lock()
	f.subprotocols = append(f.subprotocols, c.Subprotocol())
	f.mu.Unlock()

	_, data, err := c.Read(ctx)
	if err != nil {
		return
	}
	var hello Frame
	_ = json.Unmarshal(data, &hello)
	f.mu.Lock()
	f.hellos = append(f.hellos, hello)
	f.mu.Unlock()

	if r.Header.Get("Authorization") != "Bearer good" {
		send(ctx, c, Frame{"type": "error", "data": map[string]any{"code": "unauthorized"}})
		_ = c.Close(4401, "unauthorized")
		return
	}
	wm, _ := asInt(hello["watermark"])
	f.mu.Lock()
	head := len(f.frames)
	replay := []Frame{}
	for _, fr := range f.frames {
		if s, _ := asInt(fr["seq"]); s > wm {
			replay = append(replay, fr)
		}
	}
	var closeCode websocket.StatusCode = -1
	if len(f.closeAfterReplay) > 0 {
		closeCode, f.closeAfterReplay = f.closeAfterReplay[0], f.closeAfterReplay[1:]
	}
	f.mu.Unlock()

	send(ctx, c, Frame{"type": "welcome", "data": map[string]any{"protocol": Protocol, "conversationId": "c-1", "watermark": head, "limits": map[string]any{"idleTimeoutMs": 60000}}})
	for _, fr := range replay {
		send(ctx, c, fr)
	}
	if closeCode != -1 {
		_ = c.Close(closeCode, `{"reason":"unavailable","retryAfterMs":10}`)
		return
	}
	f.mu.Lock()
	f.conns[c] = true
	f.mu.Unlock()
	defer func() { f.mu.Lock(); delete(f.conns, c); f.mu.Unlock() }()

	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			return
		}
		var fr Frame
		_ = json.Unmarshal(data, &fr)
		f.mu.Lock()
		f.received = append(f.received, fr)
		drop := false
		if fr["type"] == "text" && f.dropFirstText {
			f.dropFirstText, drop = false, true
		}
		f.mu.Unlock()
		if drop {
			_ = c.Close(websocket.StatusInternalError, "boom")
			return
		}
		switch fr["type"] {
		case "text":
			cid := fr["clientId"].(string)
			f.mu.Lock()
			ack, dup := f.acked[cid]
			if !dup {
				seq := len(f.frames) + 1
				f.frames = append(f.frames, textFrame(seq, "user", fr["data"].(map[string]any)["text"].(string), cid))
				ack = Frame{"type": "ack", "clientId": cid, "id": fmt.Sprintf("a-%d", seq), "seq": seq, "timestamp": 1}
				f.acked[cid] = ack
			}
			f.mu.Unlock()
			if dup {
				ack = Frame{"type": "ack", "clientId": cid, "id": ack["id"], "seq": ack["seq"], "duplicate": true}
			}
			send(ctx, c, ack)
		case "sync":
			from, _ := asInt(fr["watermark"])
			f.mu.Lock()
			out := []Frame{}
			for _, x := range f.frames {
				if s, _ := asInt(x["seq"]); s > from {
					out = append(out, x)
				}
			}
			f.mu.Unlock()
			for _, x := range out {
				send(ctx, c, x)
			}
		}
	}
}

func startFake(t *testing.T, f *fakeServer) string {
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http") + SocketPath
}

func recvLabels(t *testing.T, s *Socket, n int) []string {
	t.Helper()
	out := []string{}
	for i := 0; i < n; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		f, err := s.Recv(ctx)
		cancel()
		if err != nil {
			t.Fatalf("recv %d: %v (have %v)", i, err, out)
		}
		if seq, ok := asInt(f["seq"]); ok {
			out = append(out, fmt.Sprintf("%s:%d", f["type"], seq))
		} else {
			out = append(out, f["type"].(string))
		}
	}
	return out
}

func eq(t *testing.T, got, want []string) {
	t.Helper()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestSocketHandshakeReplaySendAndLive(t *testing.T) {
	fake := newFakeServer(2)
	url := startFake(t, fake)
	ctx := context.Background()
	s, err := Dial(ctx, url, StaticToken("good"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	eq(t, recvLabels(t, s, 3), []string{"welcome", "text:1", "text:2"})
	ack, err := s.SendText(ctx, "hello")
	if err != nil || ack.Seq != 3 || !strings.HasPrefix(ack.ClientID, "go-") {
		t.Fatalf("ack %+v err %v", ack, err)
	}
	fake.push(ctx, "bot", "live")
	eq(t, recvLabels(t, s, 1), []string{"text:4"})
	if s.Watermark() != 4 || s.ConversationID() != "c-1" {
		t.Fatalf("watermark %d conversation %s", s.Watermark(), s.ConversationID())
	}
	if fake.subprotocols[0] != Subprotocol {
		t.Fatalf("subprotocol %q", fake.subprotocols[0])
	}
	assertJSONEqual(t, fake.hellos[0], map[string]any{"type": "hello", "protocol": "converger/1", "watermark": 0})
}

func TestSocketReconnectResumesFromTheWatermark(t *testing.T) {
	fake := newFakeServer(2)
	fake.closeAfterReplay = []websocket.StatusCode{websocket.StatusServiceRestart}
	url := startFake(t, fake)
	ctx := context.Background()
	s, err := Dial(ctx, url, StaticToken("good"), WithBackoff(10*time.Millisecond, 50*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	eq(t, recvLabels(t, s, 4), []string{"welcome", "text:1", "text:2", "welcome"})
	fake.push(ctx, "bot", "after reconnect")
	eq(t, recvLabels(t, s, 1), []string{"text:3"})
	fake.mu.Lock()
	defer fake.mu.Unlock()
	assertJSONEqual(t, fake.hellos[1], map[string]any{"type": "hello", "protocol": "converger/1", "watermark": 2, "conversationId": "c-1"})
}

func TestSocketResendsUnackedSendWithSameClientID(t *testing.T) {
	fake := newFakeServer(0)
	fake.dropFirstText = true
	url := startFake(t, fake)
	ctx := context.Background()
	s, err := Dial(ctx, url, StaticToken("good"), WithBackoff(10*time.Millisecond, 50*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ack, err := s.SendText(ctx, "exactly once", SendOptions{ClientID: "cid-1"})
	if err != nil || ack.Seq != 1 {
		t.Fatalf("ack %+v err %v", ack, err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	ids := []string{}
	for _, f := range fake.received {
		if f["type"] == "text" {
			ids = append(ids, f["clientId"].(string))
		}
	}
	eq(t, ids, []string{"cid-1", "cid-1"})
	if len(fake.frames) != 1 {
		t.Fatalf("stored %d frames", len(fake.frames))
	}
}

func TestSocketUnauthorizedIsTerminal(t *testing.T) {
	url := startFake(t, newFakeServer(0))
	_, err := Dial(context.Background(), url, StaticToken("bad"), WithBackoff(10*time.Millisecond, 50*time.Millisecond))
	var ce *CloseError
	if !errors.As(err, &ce) || ce.Code != 4401 {
		t.Fatalf("got %v", err)
	}
}

func TestSocketTokenSourceIsAskedAgainAfter4401(t *testing.T) {
	fake := newFakeServer(0)
	url := startFake(t, fake)
	tokens := []string{"bad", "good"}
	var mu sync.Mutex
	src := func(context.Context) (string, error) {
		mu.Lock()
		defer mu.Unlock()
		tok := tokens[0]
		tokens = tokens[1:]
		return tok, nil
	}
	s, err := Dial(context.Background(), url, src, WithBackoff(10*time.Millisecond, 50*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	eq(t, recvLabels(t, s, 2), []string{"error", "welcome"})
}

func TestSocketURL(t *testing.T) {
	if got := SocketURL("https://chat.example.com/"); got != "wss://chat.example.com/socket/converger/v1" {
		t.Fatal(got)
	}
	if got := SocketURL("http://localhost:4000"); got != "ws://localhost:4000/socket/converger/v1" {
		t.Fatal(got)
	}
}
