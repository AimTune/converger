package converger

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Subprotocol is the WebSocket subprotocol of Protocol v1 (JSON).
const Subprotocol = "converger.v1"

// SocketPath is the native Protocol v1 endpoint.
const SocketPath = "/socket/converger/v1"

// terminalCloseCodes end the socket: reconnecting cannot help (docs/protocol/v1.md 12.3).
var terminalCloseCodes = map[int]bool{1008: true, 4400: true, 4401: true, 4403: true}

// TokenSource returns the converger token for a connection attempt. It is
// called on every connect, so a token that expired (close 4401) can be
// replaced.
type TokenSource func(ctx context.Context) (string, error)

// StaticToken always returns token. After a 4401 close the socket retries
// once and then ends.
func StaticToken(token string) TokenSource {
	return func(context.Context) (string, error) { return token, nil }
}

type socketConfig struct {
	url            string
	watermark      int
	conversationID string
	reconnect      bool
	maxRetries     int
	backoffInitial time.Duration
	backoffMax     time.Duration
	ackTimeout     time.Duration
	header         http.Header
}

// SocketOption configures Dial.
type SocketOption func(*socketConfig)

// WithWatermark resumes from a stored watermark (the last seq processed).
func WithWatermark(seq int) SocketOption { return func(c *socketConfig) { c.watermark = seq } }

// WithConversationID asserts the conversation (needed with channel-level tokens).
func WithConversationID(id string) SocketOption {
	return func(c *socketConfig) { c.conversationID = id }
}

// WithReconnect turns automatic reconnects on (default) or off.
func WithReconnect(on bool) SocketOption { return func(c *socketConfig) { c.reconnect = on } }

// WithMaxRetries bounds consecutive failed connection attempts (default unlimited).
func WithMaxRetries(n int) SocketOption { return func(c *socketConfig) { c.maxRetries = n } }

// WithBackoff sets the jittered exponential reconnect backoff (default 500 ms to 30 s).
func WithBackoff(initial, max time.Duration) SocketOption {
	return func(c *socketConfig) { c.backoffInitial, c.backoffMax = initial, max }
}

// WithAckTimeout bounds how long a send waits for its ack (default 30 s).
func WithAckTimeout(d time.Duration) SocketOption { return func(c *socketConfig) { c.ackTimeout = d } }

// WithSocketHeader adds HTTP headers to the upgrade request.
func WithSocketHeader(h http.Header) SocketOption { return func(c *socketConfig) { c.header = h } }

// SocketURL is the native endpoint URL for a REST base URL
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

type sendResult struct {
	ack *Ack
	err error
}

type pendingSend struct {
	frame Frame
	ch    chan sendResult
}

// Socket is one conversation over the native Protocol v1 endpoint. It
// reconnects with jittered exponential backoff, resumes from the watermark
// (persistent frames arrive in seq order, exactly once), answers gaps with
// sync and re-sends unacknowledged sends with their original clientId.
// Its methods are safe for concurrent use.
type Socket struct {
	cfg   socketConfig
	token TokenSource

	mu       sync.Mutex
	session  *Session
	conn     *websocket.Conn
	ready    bool
	welcome  map[string]any
	pending  map[string]*pendingSend
	order    []string
	closeErr error

	frames   chan Frame
	welcomed chan struct{}
	done     chan struct{}
	ctx      context.Context
	cancel   context.CancelFunc
	once     sync.Once
}

// Dial opens a socket to this client's server and waits for the first welcome.
func (c *Client) Dial(ctx context.Context, token TokenSource, opts ...SocketOption) (*Socket, error) {
	return Dial(ctx, SocketURL(c.baseURL), token, opts...)
}

// Dial opens a socket to url and waits for the first welcome.
func Dial(ctx context.Context, url string, token TokenSource, opts ...SocketOption) (*Socket, error) {
	cfg := socketConfig{
		url:            url,
		reconnect:      true,
		maxRetries:     -1,
		backoffInitial: 500 * time.Millisecond,
		backoffMax:     30 * time.Second,
		ackTimeout:     30 * time.Second,
	}
	for _, o := range opts {
		o(&cfg)
	}
	runCtx, cancel := context.WithCancel(context.Background())
	s := &Socket{
		cfg:      cfg,
		token:    token,
		session:  NewSession(cfg.watermark, cfg.conversationID),
		pending:  map[string]*pendingSend{},
		frames:   make(chan Frame, 1024),
		welcomed: make(chan struct{}),
		done:     make(chan struct{}),
		ctx:      runCtx,
		cancel:   cancel,
	}
	go s.run()
	select {
	case <-s.welcomed:
		return s, nil
	case <-s.done:
		return nil, s.err()
	case <-ctx.Done():
		s.Close()
		return nil, ctx.Err()
	}
}

// Watermark is the highest seq processed in order.
func (s *Socket) Watermark() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.session.Watermark
}

// ConversationID is the conversation of the session.
func (s *Socket) ConversationID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.session.ConversationID
}

// Welcome is the data of the latest welcome frame.
func (s *Socket) Welcome() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.welcome
}

// Recv returns the next frame for the application. After the socket ended
// for good it returns a *CloseError.
func (s *Socket) Recv(ctx context.Context) (Frame, error) {
	select {
	case f := <-s.frames:
		return f, nil
	default:
	}
	select {
	case f := <-s.frames:
		return f, nil
	case <-s.done:
		select {
		case f := <-s.frames:
			return f, nil
		default:
			return nil, s.err()
		}
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// SendOptions are the optional fields of a send.
type SendOptions struct {
	// ClientID makes the send idempotent; generated when empty.
	ClientID string
	// Metadata is stored with the activity.
	Metadata map[string]any
	// ReplyTo is the activity a tapped button answers.
	ReplyTo string
}

// SendText sends a text turn and waits for its ack.
func (s *Socket) SendText(ctx context.Context, text string, opts ...SendOptions) (*Ack, error) {
	return s.SendMessage(ctx, "text", map[string]any{"text": text}, opts...)
}

// SendMessage sends a message frame of any type and waits for its ack. A
// refused send returns a *ProtocolError.
func (s *Socket) SendMessage(ctx context.Context, typ string, data map[string]any, opts ...SendOptions) (*Ack, error) {
	var o SendOptions
	if len(opts) > 0 {
		o = opts[0]
	}
	if o.ClientID == "" {
		o.ClientID = fmt.Sprintf("go-%d-%d", time.Now().UnixNano(), rand.Int63())
	}
	frame := Frame{"type": typ, "clientId": o.ClientID, "data": data}
	if o.Metadata != nil {
		frame["metadata"] = o.Metadata
	}
	if o.ReplyTo != "" {
		frame["replyTo"] = map[string]any{"id": o.ReplyTo}
	}
	p := &pendingSend{frame: frame, ch: make(chan sendResult, 1)}

	s.mu.Lock()
	if s.closeErr != nil {
		err := s.closeErr
		s.mu.Unlock()
		return nil, err
	}
	s.pending[o.ClientID] = p
	s.order = append(s.order, o.ClientID)
	conn, ready := s.conn, s.ready
	s.mu.Unlock()

	if ready {
		_ = s.write(conn, frame)
	}
	timer := time.NewTimer(s.cfg.ackTimeout)
	defer timer.Stop()
	select {
	case r := <-p.ch:
		return r.ack, r.err
	case <-ctx.Done():
		s.forget(o.ClientID)
		return nil, ctx.Err()
	case <-timer.C:
		s.forget(o.ClientID)
		return nil, fmt.Errorf("converger: no ack for %s within %s", o.ClientID, s.cfg.ackTimeout)
	}
}

// Typing sends a typing indicator.
func (s *Socket) Typing(isTyping bool) error {
	return s.writeCurrent(Frame{"type": "typing", "isTyping": isTyping})
}

// Read marks everything up to watermark as read.
func (s *Socket) Read(watermark int) error {
	return s.writeCurrent(Frame{"type": "read", "watermark": watermark})
}

// Close ends the socket.
func (s *Socket) Close() error {
	s.mu.Lock()
	conn := s.conn
	s.mu.Unlock()
	s.finish(&CloseError{Code: 1000, Reason: "closed by client"})
	if conn != nil {
		_ = conn.Close(websocket.StatusNormalClosure, "")
	}
	s.cancel()
	return nil
}

func (s *Socket) err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closeErr
}

func (s *Socket) forget(clientID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.pending, clientID)
}

func (s *Socket) writeCurrent(f Frame) error {
	s.mu.Lock()
	conn := s.conn
	s.mu.Unlock()
	if conn == nil {
		return errors.New("converger: socket is not connected")
	}
	return s.write(conn, f)
}

func (s *Socket) write(conn *websocket.Conn, f Frame) error {
	b, err := json.Marshal(f)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(s.ctx, 10*time.Second)
	defer cancel()
	return conn.Write(ctx, websocket.MessageText, b)
}

func (s *Socket) finish(err error) {
	s.once.Do(func() {
		s.mu.Lock()
		s.closeErr = err
		for _, p := range s.pending {
			p.ch <- sendResult{err: err}
		}
		s.pending = map[string]*pendingSend{}
		s.mu.Unlock()
		close(s.done)
	})
}

func (s *Socket) backoff(attempt int) time.Duration {
	d := s.cfg.backoffInitial << uint(min(attempt, 20))
	if d > s.cfg.backoffMax || d <= 0 {
		d = s.cfg.backoffMax
	}
	return d/2 + time.Duration(rand.Int63n(int64(d/2)+1))
}

func (s *Socket) run() {
	attempt, authRetries := 0, 0
	for {
		if s.ctx.Err() != nil {
			s.finish(&CloseError{Code: 1000, Reason: "closed by client"})
			return
		}
		code, reason, welcomed := s.connectOnce()
		if s.ctx.Err() != nil {
			s.finish(&CloseError{Code: 1000, Reason: "closed by client"})
			return
		}
		if welcomed {
			attempt, authRetries = 0, 0
		}
		// One immediate retry after 4401 lets a TokenSource hand out a fresh
		// token; a second consecutive 4401 ends the socket.
		if code == 4401 && authRetries == 0 {
			authRetries++
			continue
		}
		if !s.cfg.reconnect || terminalCloseCodes[code] {
			s.finish(&CloseError{Code: code, Reason: reason})
			return
		}
		if !welcomed {
			attempt++
		}
		if s.cfg.maxRetries >= 0 && attempt > s.cfg.maxRetries {
			s.finish(&CloseError{Code: code, Reason: "too many reconnect attempts: " + reason})
			return
		}
		delay := s.backoff(attempt)
		if ms, ok := retryAfterMs(reason); ok {
			delay = time.Duration(ms) * time.Millisecond
		}
		select {
		case <-time.After(delay):
		case <-s.ctx.Done():
		}
	}
}

func (s *Socket) connectOnce() (code int, reason string, welcomed bool) {
	token, err := s.token(s.ctx)
	if err != nil {
		return 0, err.Error(), false
	}
	header := http.Header{}
	for k, vs := range s.cfg.header {
		header[k] = vs
	}
	header.Set("Authorization", "Bearer "+token)
	header.Set("User-Agent", "converger-go/"+Version)

	dialCtx, cancelDial := context.WithTimeout(s.ctx, 10*time.Second)
	conn, _, err := websocket.Dial(dialCtx, s.cfg.url, &websocket.DialOptions{
		Subprotocols: []string{Subprotocol},
		HTTPHeader:   header,
	})
	cancelDial()
	if err != nil {
		return 0, err.Error(), false
	}
	conn.SetReadLimit(2 << 20)
	connCtx, cancelConn := context.WithCancel(s.ctx)
	defer cancelConn()

	s.mu.Lock()
	s.conn = conn
	hello := s.session.Hello()
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		if s.conn == conn {
			s.conn, s.ready = nil, false
		}
		s.mu.Unlock()
		conn.CloseNow()
	}()

	if err := s.write(conn, hello); err != nil {
		return closeInfo(err)
	}
	for {
		_, data, err := conn.Read(connCtx)
		if err != nil {
			c, r, _ := closeInfo(err)
			return c, r, welcomed
		}
		var f Frame
		if json.Unmarshal(data, &f) != nil {
			continue
		}
		if f["type"] == "welcome" {
			welcomed = true
		}
		s.handle(connCtx, conn, f)
	}
}

func closeInfo(err error) (int, string, bool) {
	var ce websocket.CloseError
	if errors.As(err, &ce) {
		return int(ce.Code), ce.Reason, false
	}
	return 0, err.Error(), false
}

func (s *Socket) handle(connCtx context.Context, conn *websocket.Conn, f Frame) {
	typ, _ := f["type"].(string)
	resolvedSend := false

	s.mu.Lock()
	switch typ {
	case "ack":
		cid, _ := f["clientId"].(string)
		if p, ok := s.pending[cid]; ok {
			delete(s.pending, cid)
			var ack Ack
			b, _ := json.Marshal(f)
			_ = json.Unmarshal(b, &ack)
			p.ch <- sendResult{ack: &ack}
		}
	case "error":
		data, _ := f["data"].(map[string]any)
		if cid, ok := data["clientId"].(string); ok {
			if p, ok := s.pending[cid]; ok {
				delete(s.pending, cid)
				p.ch <- sendResult{err: newProtocolError(data)}
				resolvedSend = true
			}
		}
	}
	step := s.session.OnFrame(f)
	var resend []Frame
	if typ == "welcome" {
		s.welcome, _ = f["data"].(map[string]any)
		s.ready = true
		var order []string
		for _, cid := range s.order {
			if p, ok := s.pending[cid]; ok {
				resend = append(resend, p.frame)
				order = append(order, cid)
			}
		}
		s.order = order
		go s.ping(connCtx, conn, s.welcome)
	}
	s.mu.Unlock()

	if typ == "welcome" {
		select {
		case <-s.welcomed:
		default:
			close(s.welcomed)
		}
	}
	for _, out := range resend {
		_ = s.write(conn, out)
	}
	for _, out := range step.Send {
		_ = s.write(conn, out)
	}
	for _, sch := range step.Schedule {
		time.AfterFunc(time.Duration(sch.AfterMs)*time.Millisecond, func() {
			s.mu.Lock()
			current := s.conn == conn
			sync := s.session.SyncFrame()
			s.mu.Unlock()
			if current {
				_ = s.write(conn, sync)
			}
		})
	}
	for _, d := range step.Deliver {
		if resolvedSend && typ == "error" {
			continue
		}
		select {
		case s.frames <- d:
		case <-connCtx.Done():
			return
		}
	}
}

func (s *Socket) ping(ctx context.Context, conn *websocket.Conn, welcome map[string]any) {
	idle := 60000
	if limits, ok := welcome["limits"].(map[string]any); ok {
		if n, ok := asInt(limits["idleTimeoutMs"]); ok && n > 0 {
			idle = n
		}
	}
	interval := time.Duration(idle/2) * time.Millisecond
	if interval < time.Second {
		interval = time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = s.write(conn, Frame{"type": "ping"})
		}
	}
}

// retryAfterMs reads {"retryAfterMs": N} from a 1012 or 4503 close reason.
func retryAfterMs(reason string) (int, bool) {
	var v map[string]any
	if json.Unmarshal([]byte(reason), &v) != nil {
		return 0, false
	}
	return asInt(v["retryAfterMs"])
}
