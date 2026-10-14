// Package agent is the Converger agent SDK for Go: a bot backend that answers
// the conversations of a Converger channel over one channel-scoped Protocol v1
// WebSocket (docs/protocol/v1.md, sections 9 and 10).
//
//	a := agent.New(agent.SocketURL("https://chat.example.com"), agent.StaticToken(token))
//	a.OnTurn(func(ctx context.Context, turn *agent.Turn, reply *agent.Reply) error {
//		_, err := reply.Text(ctx, "You said: "+turn.Text)
//		return err
//	})
//	err := a.Run(ctx)
package agent

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	mrand "math/rand"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// Version of this SDK, sent in the User-Agent header.
const Version = "0.1.0"

// Protocol is the protocol version sent in hello.
const Protocol = "converger/1"

// Subprotocol is the WebSocket subprotocol of Protocol v1 (JSON).
const Subprotocol = "converger.v1"

// SocketPath is the native Protocol v1 endpoint.
const SocketPath = "/socket/converger/v1"

// SocketURL is the native endpoint URL for a server base URL
// (https://h becomes wss://h/socket/converger/v1).
func SocketURL(baseURL string) string {
	u := strings.TrimRight(baseURL, "/")
	switch {
	case strings.HasPrefix(u, "https://"):
		u = "wss://" + strings.TrimPrefix(u, "https://")
	case strings.HasPrefix(u, "http://"):
		u = "ws://" + strings.TrimPrefix(u, "http://")
	}
	return u + SocketPath
}

// TokenSource returns the channel-scoped token for a connection attempt. It is
// called on every connect, so an expired token (close 4401) can be replaced.
type TokenSource func(ctx context.Context) (string, error)

// StaticToken always returns token.
func StaticToken(token string) TokenSource {
	return func(context.Context) (string, error) { return token, nil }
}

// Handler answers one user turn. Turns of one conversation run one at a time,
// in order; turns of different conversations run concurrently. A returned
// error ends the run with status "error" and is passed to the error callback.
type Handler func(ctx context.Context, turn *Turn, reply *Reply) error

type config struct {
	group          string
	userID         string
	watermarks     map[string]int
	backoffInitial time.Duration
	backoffMax     time.Duration
	ackTimeout     time.Duration
	header         http.Header
	onError        func(error)
}

// Option configures New.
type Option func(*config)

// WithGroup joins an agent group: the connections of a group share the
// channel's conversations, each served by one member (hello.group).
func WithGroup(group string) Option { return func(c *config) { c.group = group } }

// WithUserID names the agent as the sender of its replies when the token has
// no user_id (hello.userId).
func WithUserID(id string) Option { return func(c *config) { c.userID = id } }

// WithWatermarks resumes conversations from stored watermarks (the last seq
// seen per conversation, as returned by Agent.Watermarks).
func WithWatermarks(w map[string]int) Option {
	return func(c *config) {
		for k, v := range w {
			c.watermarks[k] = v
		}
	}
}

// WithBackoff sets the jittered exponential reconnect backoff (default 500 ms to 30 s).
func WithBackoff(initial, max time.Duration) Option {
	return func(c *config) { c.backoffInitial, c.backoffMax = initial, max }
}

// WithAckTimeout bounds how long a message send waits for its ack (default 30 s).
func WithAckTimeout(d time.Duration) Option { return func(c *config) { c.ackTimeout = d } }

// WithHeader adds HTTP headers to the upgrade request.
func WithHeader(h http.Header) Option { return func(c *config) { c.header = h } }

// OnError receives errors that no call returns: connection-level error
// frames, errors about a conversation, handler errors, unknown interrupt
// answers. It must not block.
func OnError(f func(error)) Option { return func(c *config) { c.onError = f } }

type sendResult struct {
	ack *Ack
	err error
}

type outgoing struct {
	n        uint64
	envelope map[string]any
	clientID string
	result   chan sendResult
}

type queue struct {
	turns   []*Turn
	running bool
}

// Agent is one channel-scoped connection and its turn dispatcher.
type Agent struct {
	url     string
	token   TokenSource
	cfg     config
	handler Handler

	writeMu sync.Mutex // serialises writes and the flush after welcome
	mu      sync.Mutex
	conn    *websocket.Conn // set once welcomed
	pending map[string]*outgoing
	backlog []*outgoing
	asks    map[string]chan any
	queues  map[string]*queue
	marks   map[string]int
	lastErr *Error
	stopped bool
	idle    time.Duration

	seq     atomic.Uint64
	running atomic.Bool
	ctx     context.Context
	done    chan struct{}
	wg      sync.WaitGroup
}

// New creates an agent for the native endpoint url (see SocketURL) with a
// channel-scoped token (POST /api/v1/converger/tokens/generate with
// {"scope": "channel"}). Register a handler with OnTurn, then call Run.
func New(url string, token TokenSource, opts ...Option) *Agent {
	cfg := config{
		watermarks:     map[string]int{},
		backoffInitial: 500 * time.Millisecond,
		backoffMax:     30 * time.Second,
		ackTimeout:     30 * time.Second,
	}
	for _, o := range opts {
		o(&cfg)
	}
	marks := make(map[string]int, len(cfg.watermarks))
	for k, v := range cfg.watermarks {
		marks[k] = v
	}
	return &Agent{
		url:     url,
		token:   token,
		cfg:     cfg,
		pending: map[string]*outgoing{},
		asks:    map[string]chan any{},
		queues:  map[string]*queue{},
		marks:   marks,
		idle:    60 * time.Second,
		done:    make(chan struct{}),
	}
}

// OnTurn sets the handler of user turns. Call it before Run.
func (a *Agent) OnTurn(h Handler) { a.handler = h }

// Watermarks is the last seq seen per conversation; persist it and pass it to
// WithWatermarks to resume after a restart.
func (a *Agent) Watermarks() map[string]int {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make(map[string]int, len(a.marks))
	for k, v := range a.marks {
		out[k] = v
	}
	return out
}

// Run connects, reconnects with jittered backoff and dispatches turns until
// ctx is cancelled (it then returns nil) or the server closes the connection
// for good (a *CloseError). Running handlers are cancelled and awaited.
func (a *Agent) Run(ctx context.Context) error {
	if a.handler == nil {
		return errors.New("converger: OnTurn was not called")
	}
	if !a.running.CompareAndSwap(false, true) {
		return errors.New("converger: Run was already called")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	a.ctx = ctx
	err := a.loop(ctx)
	cancel()
	a.stop(err)
	a.wg.Wait()
	if ctx.Err() != nil && err == nil {
		return nil
	}
	return err
}

func (a *Agent) loop(ctx context.Context) error {
	attempt, authRetried := 0, false
	for {
		code, reason, welcomed := a.connectOnce(ctx)
		if ctx.Err() != nil {
			return nil
		}
		if welcomed {
			attempt, authRetried = 0, false
		}
		a.mu.Lock()
		last := a.lastErr
		a.lastErr = nil
		a.mu.Unlock()
		if code == 4401 && !authRetried {
			// One immediate retry lets the TokenSource hand out a fresh token.
			authRetried = true
			continue
		}
		if code == 1008 || code == 4400 || code == 4401 || code == 4403 {
			return &CloseError{Code: code, Reason: reason, Last: last}
		}
		attempt++
		delay := a.backoff(attempt)
		if ms, ok := retryAfterMs(reason); ok {
			delay = time.Duration(ms) * time.Millisecond
		}
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return nil
		}
	}
}

func (a *Agent) backoff(attempt int) time.Duration {
	d := a.cfg.backoffInitial << uint(min(attempt-1, 20))
	if d > a.cfg.backoffMax || d <= 0 {
		d = a.cfg.backoffMax
	}
	return d/2 + time.Duration(mrand.Int63n(int64(d/2)+1))
}

func retryAfterMs(reason string) (int, bool) {
	var v map[string]any
	if json.Unmarshal([]byte(reason), &v) != nil {
		return 0, false
	}
	return asInt(v["retryAfterMs"])
}

func (a *Agent) connectOnce(ctx context.Context) (code int, reason string, welcomed bool) {
	token, err := a.token(ctx)
	if err != nil {
		a.report(fmt.Errorf("converger: token source: %w", err))
		return 0, err.Error(), false
	}
	header := http.Header{}
	for k, vs := range a.cfg.header {
		header[k] = vs
	}
	header.Set("Authorization", "Bearer "+token)
	header.Set("User-Agent", "converger-agent-go/"+Version)

	dialCtx, cancelDial := context.WithTimeout(ctx, 10*time.Second)
	conn, _, err := websocket.Dial(dialCtx, a.url, &websocket.DialOptions{
		Subprotocols: []string{Subprotocol},
		HTTPHeader:   header,
	})
	cancelDial()
	if err != nil {
		return 0, err.Error(), false
	}
	conn.SetReadLimit(4 << 20)
	connCtx, cancelConn := context.WithCancel(ctx)
	defer cancelConn()
	defer conn.CloseNow()

	if err := writeJSON(connCtx, conn, a.hello()); err != nil {
		return 0, err.Error(), false
	}
	go a.pinger(connCtx, conn)

	for {
		_, data, err := conn.Read(connCtx)
		if err != nil {
			a.mu.Lock()
			if a.conn == conn {
				a.conn = nil
			}
			a.mu.Unlock()
			var ce websocket.CloseError
			if errors.As(err, &ce) {
				return int(ce.Code), ce.Reason, welcomed
			}
			return 0, err.Error(), welcomed
		}
		var msg map[string]any
		if json.Unmarshal(data, &msg) != nil {
			continue
		}
		if _, typed := msg["type"]; !typed {
			id, _ := msg["conversationId"].(string)
			frame, _ := msg["frame"].(map[string]any)
			if id != "" && frame != nil && welcomed {
				a.dispatch(id, frame)
			}
			continue
		}
		switch msg["type"] {
		case "welcome":
			if !welcomed {
				welcomed = true
				a.welcomed(conn, msg)
			}
		case "error":
			e := parseError("", msg)
			a.mu.Lock()
			a.lastErr = e
			a.mu.Unlock()
			a.report(e)
		}
	}
}

func (a *Agent) hello() map[string]any {
	hello := map[string]any{"type": "hello", "protocol": Protocol}
	if a.cfg.group != "" {
		hello["group"] = a.cfg.group
	}
	if a.cfg.userID != "" {
		hello["userId"] = a.cfg.userID
	}
	a.mu.Lock()
	if len(a.marks) > 0 {
		marks := make(map[string]any, len(a.marks))
		for k, v := range a.marks {
			marks[k] = v
		}
		hello["watermarks"] = marks
	}
	a.mu.Unlock()
	return hello
}

func (a *Agent) pinger(ctx context.Context, conn *websocket.Conn) {
	for {
		a.mu.Lock()
		interval := a.idle / 2
		a.mu.Unlock()
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
			_ = writeJSON(ctx, conn, map[string]any{"type": "ping"})
		}
	}
}

// welcomed flushes, in their original order, the sends not yet acked and the
// frames written while disconnected, then makes conn the live connection.
func (a *Agent) welcomed(conn *websocket.Conn, welcome map[string]any) {
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	a.mu.Lock()
	if data, ok := welcome["data"].(map[string]any); ok {
		if limits, ok := data["limits"].(map[string]any); ok {
			if ms, ok := asInt(limits["idleTimeoutMs"]); ok && ms > 0 {
				a.idle = time.Duration(ms) * time.Millisecond
			}
		}
	}
	out := append([]*outgoing{}, a.backlog...)
	for _, p := range a.pending {
		out = append(out, p)
	}
	a.backlog = nil
	a.conn = conn
	a.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].n < out[j].n })
	for _, o := range out {
		_ = writeJSON(a.ctx, conn, o.envelope)
	}
}

// dispatch handles one enveloped frame of a conversation.
func (a *Agent) dispatch(id string, frame map[string]any) {
	typ, _ := frame["type"].(string)
	a.mu.Lock()
	if seq, ok := asInt(frame["seq"]); ok && typ != "ack" {
		if seq <= a.marks[id] {
			a.mu.Unlock()
			return // a duplicate (replay overlap)
		}
		a.marks[id] = seq
	}
	switch typ {
	case "ack":
		clientID, _ := frame["clientId"].(string)
		p := a.pending[clientID]
		delete(a.pending, clientID)
		a.mu.Unlock()
		if p != nil {
			p.result <- sendResult{ack: parseAck(frame)}
		}
	case "error":
		e := parseError(id, frame)
		p := a.pending[e.ClientID]
		if e.ClientID != "" {
			delete(a.pending, e.ClientID)
		}
		a.mu.Unlock()
		if p != nil {
			p.result <- sendResult{err: e}
		} else {
			a.report(e)
		}
	case "resume":
		answers, _ := frame["answers"].(map[string]any)
		var unknown []string
		for interruptID, answer := range answers {
			if ch, ok := a.asks[interruptID]; ok {
				delete(a.asks, interruptID)
				ch <- answer
			} else {
				unknown = append(unknown, interruptID)
			}
		}
		a.mu.Unlock()
		for _, interruptID := range unknown {
			a.report(&Error{Code: "unknown_interrupt", Message: "an answer to an interrupt this agent is not waiting for: " + interruptID, ConversationID: id})
		}
	default:
		if from, _ := frame["from"].(string); from == "user" && isTurn(typ) {
			if _, ok := asInt(frame["seq"]); ok {
				a.enqueueLocked(newTurn(id, frame))
			}
		}
		a.mu.Unlock()
	}
}

// Frame types from the user's side that are not turns.
var notTurns = map[string]bool{
	"typing": true, "presence": true, "deliveryStatus": true, "event": true, "conversationUpdate": true,
	"run": true, "genui_components": true, "skills": true, "heartbeat": true, "replayTruncated": true,
}

func isTurn(typ string) bool { return typ != "" && !notTurns[typ] }

func (a *Agent) enqueueLocked(t *Turn) {
	if a.stopped {
		return
	}
	q := a.queues[t.ConversationID]
	if q == nil {
		q = &queue{}
		a.queues[t.ConversationID] = q
	}
	q.turns = append(q.turns, t)
	if !q.running {
		q.running = true
		a.wg.Add(1)
		go a.drain(t.ConversationID, q)
	}
}

func (a *Agent) drain(id string, q *queue) {
	defer a.wg.Done()
	for {
		a.mu.Lock()
		if len(q.turns) == 0 || a.stopped {
			q.running = false
			delete(a.queues, id)
			a.mu.Unlock()
			return
		}
		t := q.turns[0]
		q.turns = q.turns[1:]
		a.mu.Unlock()
		a.runTurn(t)
	}
}

func (a *Agent) runTurn(t *Turn) {
	ctx := a.ctx
	r := &Reply{agent: a, conversationID: t.ConversationID}
	_ = r.run(ctx, "started")
	err := func() (err error) {
		defer func() {
			if p := recover(); p != nil {
				err = fmt.Errorf("converger: turn handler panicked: %v", p)
			}
		}()
		return a.handler(ctx, t, r)
	}()
	if ctx.Err() != nil {
		return
	}
	if err != nil {
		if !r.ended.Swap(true) {
			_ = r.run(ctx, "error")
		}
		a.report(err)
		return
	}
	r.End()
}

// send writes a frame of conversation id, or keeps it for the next connection.
// With a clientID the frame stays pending until its ack (or error) arrives.
// Typing is dropped while disconnected.
func (a *Agent) send(id string, frame map[string]any, clientID string) (*outgoing, error) {
	o := &outgoing{
		n:        a.seq.Add(1),
		envelope: map[string]any{"conversationId": id, "frame": frame},
		clientID: clientID,
	}
	if clientID != "" {
		o.result = make(chan sendResult, 1)
	}
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	a.mu.Lock()
	if a.stopped {
		a.mu.Unlock()
		return nil, ErrStopped
	}
	conn := a.conn
	if clientID != "" {
		a.pending[clientID] = o
	} else if conn == nil && frame["type"] != "typing" {
		a.backlog = append(a.backlog, o)
	}
	a.mu.Unlock()
	if conn != nil {
		if err := writeJSON(a.ctx, conn, o.envelope); err != nil && clientID == "" && frame["type"] != "typing" {
			a.mu.Lock()
			a.backlog = append(a.backlog, o)
			a.mu.Unlock()
		}
	}
	return o, nil
}

func (a *Agent) await(ctx context.Context, o *outgoing) (*Ack, error) {
	timer := time.NewTimer(a.cfg.ackTimeout)
	defer timer.Stop()
	select {
	case r := <-o.result:
		return r.ack, r.err
	case <-timer.C:
		a.forget(o.clientID)
		return nil, ErrAckTimeout
	case <-ctx.Done():
		a.forget(o.clientID)
		return nil, ctx.Err()
	case <-a.done:
		return nil, ErrStopped
	}
}

func (a *Agent) forget(clientID string) {
	a.mu.Lock()
	delete(a.pending, clientID)
	a.mu.Unlock()
}

func (a *Agent) stop(err error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.stopped {
		return
	}
	a.stopped = true
	if err == nil {
		err = ErrStopped
	}
	for k, p := range a.pending {
		p.result <- sendResult{err: err}
		delete(a.pending, k)
	}
	close(a.done)
}

func (a *Agent) report(err error) {
	if a.cfg.onError != nil {
		a.cfg.onError(err)
	}
}

func writeJSON(ctx context.Context, conn *websocket.Conn, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return conn.Write(ctx, websocket.MessageText, b)
}

func randomID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
