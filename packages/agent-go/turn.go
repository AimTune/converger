package agent

import (
	"context"
	"fmt"
	"sync/atomic"
)

// Turn is one user turn: a message frame with from "user" of one conversation.
type Turn struct {
	ConversationID string
	// ID and Seq are the activity id and its seq in the conversation.
	ID  string
	Seq int
	// Text is data.text ("" for messages without text).
	Text    string
	Message Message
	// Participant is the frame's sender, nil when absent.
	Participant *Participant
	// Meta is the turn's per-turn context (mekik/1 meta), never stored.
	Meta map[string]any
	// Metadata is the stored activity metadata.
	Metadata map[string]any
	// Action is metadata.action: the button or chip the user tapped, if any.
	Action *Action
	// ReplyTo is the frame's replyTo ({id, seq}) when the turn answers an activity.
	ReplyTo   map[string]any
	Timestamp int64
}

// Message is the turn's typed message.
type Message struct {
	Type string
	Data map[string]any
	// Raw is the whole frame as received.
	Raw map[string]any
}

// Participant is a frame's sender.
type Participant struct {
	ID   string `json:"id"`
	Role string `json:"role"`
	Name string `json:"name,omitempty"`
}

// Action is a tappable chip or button: Value omitted means the answer is Label.
type Action struct {
	Label string `json:"label"`
	Value any    `json:"value,omitempty"`
	URL   string `json:"url,omitempty"`
}

// Ack confirms a stored message send.
type Ack struct {
	ClientID  string
	ID        string
	Seq       int
	Timestamp int64
	Duplicate bool
}

// ToolCall is the data of a tool_call frame, upserted by ID as it advances
// running -> completed / error.
type ToolCall struct {
	ID          string         `json:"id"`
	Name        string         `json:"name"`
	Status      string         `json:"status"`
	Description string         `json:"description,omitempty"`
	Params      map[string]any `json:"params,omitempty"`
	Result      any            `json:"result,omitempty"`
	Error       string         `json:"error,omitempty"`
	StartedAt   int64          `json:"startedAt,omitempty"`
	EndedAt     int64          `json:"endedAt,omitempty"`
}

// AskOptions are the optional parts of an interrupt.
type AskOptions struct {
	Actions []Action
	// UI is a GenUI component rendering the question: {"component": ..., "props": ...}.
	UI map[string]any
}

func newTurn(id string, frame map[string]any) *Turn {
	t := &Turn{ConversationID: id}
	t.ID, _ = frame["id"].(string)
	t.Seq, _ = asInt(frame["seq"])
	typ, _ := frame["type"].(string)
	data, _ := frame["data"].(map[string]any)
	t.Message = Message{Type: typ, Data: data, Raw: frame}
	t.Text, _ = data["text"].(string)
	if s, ok := frame["sender"].(map[string]any); ok {
		p := &Participant{}
		p.ID, _ = s["id"].(string)
		p.Role, _ = s["role"].(string)
		p.Name, _ = s["name"].(string)
		t.Participant = p
	}
	t.Meta, _ = frame["meta"].(map[string]any)
	t.Metadata, _ = frame["metadata"].(map[string]any)
	if act, ok := t.Metadata["action"].(map[string]any); ok {
		label, _ := act["label"].(string)
		url, _ := act["url"].(string)
		t.Action = &Action{Label: label, Value: act["value"], URL: url}
	}
	t.ReplyTo, _ = frame["replyTo"].(map[string]any)
	if ts, ok := frame["timestamp"].(float64); ok {
		t.Timestamp = int64(ts)
	}
	return t
}

func parseAck(frame map[string]any) *Ack {
	a := &Ack{}
	a.ClientID, _ = frame["clientId"].(string)
	a.ID, _ = frame["id"].(string)
	a.Seq, _ = asInt(frame["seq"])
	if ts, ok := frame["timestamp"].(float64); ok {
		a.Timestamp = int64(ts)
	}
	a.Duplicate, _ = frame["duplicate"].(bool)
	return a
}

// Reply sends the agent's frames into the turn's conversation. Its methods
// are safe for concurrent use.
type Reply struct {
	agent          *Agent
	conversationID string
	ended          atomic.Bool
	asks           atomic.Int64
}

// ConversationID is the conversation this reply writes to.
func (r *Reply) ConversationID() string { return r.conversationID }

// Text sends a text message, with optional quick-reply chips, and waits for
// its ack. A refused send returns an *Error.
func (r *Reply) Text(ctx context.Context, text string, actions ...Action) (*Ack, error) {
	frame := map[string]any{"type": "text", "data": map[string]any{"text": text}}
	if len(actions) > 0 {
		frame["actions"] = actions
	}
	return r.sendMessage(ctx, frame)
}

// Message sends a message of any type (buttons, quick-reply, card, carousel,
// image, file, ... see docs/protocol/messages.md) and waits for its ack.
func (r *Reply) Message(ctx context.Context, typ string, data map[string]any) (*Ack, error) {
	return r.sendMessage(ctx, map[string]any{"type": typ, "data": data})
}

func (r *Reply) sendMessage(ctx context.Context, frame map[string]any) (*Ack, error) {
	clientID := "agent-" + randomID()
	frame["clientId"] = clientID
	o, err := r.agent.send(r.conversationID, frame, clientID)
	if err != nil {
		return nil, err
	}
	return r.agent.await(ctx, o)
}

// Ask sends an interrupt and waits for the user's answer (a tapped button, a
// chip or a resume frame), then marks the interrupt resolved. The answer is
// the action's value (any JSON value), else its label or the user's text.
func (r *Reply) Ask(ctx context.Context, payload any, actions ...Action) (any, error) {
	return r.AskWith(ctx, payload, AskOptions{Actions: actions})
}

// AskWith is Ask with a GenUI component.
func (r *Reply) AskWith(ctx context.Context, payload any, opts AskOptions) (any, error) {
	a := r.agent
	// Not of the clientId syntax ('/' and '#'), so the server keys neither the
	// interrupt nor its interrupt_resolved by it (v1 section 7).
	id := fmt.Sprintf("ask/%s#%d", randomID(), r.asks.Add(1)-1)
	if payload == nil {
		payload = map[string]any{}
	}
	data := map[string]any{"payload": payload}
	if len(opts.Actions) > 0 {
		data["actions"] = opts.Actions
	}
	if opts.UI != nil {
		data["ui"] = opts.UI
	}
	ch := make(chan any, 1)
	a.mu.Lock()
	a.asks[id] = ch
	a.mu.Unlock()
	if _, err := a.send(r.conversationID, map[string]any{"type": "interrupt", "id": id, "data": data}, ""); err != nil {
		a.dropAsk(id)
		return nil, err
	}
	var answer any
	select {
	case answer = <-ch:
	case <-ctx.Done():
		a.dropAsk(id)
		return nil, ctx.Err()
	case <-a.done:
		return nil, ErrStopped
	}
	resolved := map[string]any{"type": "interrupt_resolved", "id": id, "data": map[string]any{"answer": answer}}
	if _, err := a.send(r.conversationID, resolved, ""); err != nil {
		return answer, err
	}
	return answer, nil
}

func (a *Agent) dropAsk(id string) {
	a.mu.Lock()
	delete(a.asks, id)
	a.mu.Unlock()
}

// ToolCall sends a tool_call frame (stored, upserted by ID on the client).
func (r *Reply) ToolCall(ctx context.Context, call ToolCall) error {
	_, err := r.agent.send(r.conversationID, map[string]any{"type": "tool_call", "data": call}, "")
	return err
}

// Typing starts or stops the typing indicator (dropped while disconnected).
func (r *Reply) Typing(ctx context.Context, on bool) error {
	_, err := r.agent.send(r.conversationID, map[string]any{"type": "typing", "isTyping": on}, "")
	return err
}

// Send writes a raw agent frame (frames/channel/agent-frame.schema.json)
// without waiting for an ack.
func (r *Reply) Send(ctx context.Context, frame map[string]any) error {
	_, err := r.agent.send(r.conversationID, frame, "")
	return err
}

// End finishes the run now (run "finished"); later calls are no-ops. It is
// called for you when the handler returns.
func (r *Reply) End() {
	if !r.ended.Swap(true) {
		_ = r.run(r.agent.ctx, "finished")
	}
}

func (r *Reply) run(ctx context.Context, status string) error {
	return r.Send(ctx, map[string]any{"type": "run", "data": map[string]any{"status": status}})
}
