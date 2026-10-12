package converger

import "math"

// Protocol is the Converger Protocol v1 identifier sent in hello.
const Protocol = "converger/1"

// Frame is one Protocol v1 frame, decoded from JSON.
type Frame = map[string]any

// Scheduled is a frame the transport sends after a delay.
type Scheduled struct {
	AfterMs int
	Frame   Frame
}

// Step is what the session asks of the transport after a frame.
type Step struct {
	Deliver  []Frame
	Send     []Frame
	Schedule []Scheduled
}

// Session is the transport-independent Protocol v1 resume state machine
// (rules in packages/conformance/README.md, scenarios in
// packages/conformance/protocol.json). It is not safe for concurrent use.
type Session struct {
	Watermark      int
	ConversationID string
	SyncPending    bool
	own            map[int]bool
}

// NewSession starts from a stored watermark and conversation id (both may be zero).
func NewSession(watermark int, conversationID string) *Session {
	return &Session{Watermark: watermark, ConversationID: conversationID, own: map[int]bool{}}
}

// Hello is the first frame of a connection.
func (s *Session) Hello() Frame {
	f := Frame{"type": "hello", "protocol": Protocol, "watermark": s.Watermark}
	if s.ConversationID != "" {
		f["conversationId"] = s.ConversationID
	}
	return f
}

// SyncFrame asks for a replay after the current watermark.
func (s *Session) SyncFrame() Frame { return Frame{"type": "sync", "watermark": s.Watermark} }

func asInt(v any) (int, bool) {
	switch n := v.(type) {
	case int:
		return n, true
	case int64:
		return int(n), true
	case float64:
		if n == math.Trunc(n) {
			return int(n), true
		}
	}
	return 0, false
}

func (s *Session) advance(seq int) {
	s.Watermark = seq
	for s.own[s.Watermark+1] {
		s.Watermark++
		delete(s.own, s.Watermark)
	}
	for k := range s.own {
		if k <= s.Watermark {
			delete(s.own, k)
		}
	}
}

func (s *Session) sync(step *Step) {
	if !s.SyncPending {
		step.Send = append(step.Send, s.SyncFrame())
		s.SyncPending = true
	}
}

// OnFrame applies one received frame.
func (s *Session) OnFrame(f Frame) Step {
	var step Step
	if s.own == nil {
		s.own = map[int]bool{}
	}
	typ, _ := f["type"].(string)
	seq, hasSeq := asInt(f["seq"])

	switch {
	case typ == "welcome":
		data, _ := f["data"].(map[string]any)
		newID, _ := data["conversationId"].(string)
		if s.ConversationID != "" && newID != s.ConversationID {
			s.Watermark = 0
			s.own = map[int]bool{}
		}
		if newID != "" {
			s.ConversationID = newID
		}
		s.SyncPending = false
		step.Deliver = append(step.Deliver, f)
	case typ == "ack":
		if hasSeq {
			if seq == s.Watermark+1 {
				s.advance(seq)
			} else if seq > s.Watermark+1 {
				s.own[seq] = true
			}
		}
	case hasSeq:
		switch {
		case seq <= s.Watermark || s.own[seq]:
		case seq == s.Watermark+1:
			step.Deliver = append(step.Deliver, f)
			s.advance(seq)
			s.SyncPending = false
		default:
			s.sync(&step)
		}
	case typ == "heartbeat":
		if head, ok := asInt(f["headSeq"]); ok && head > s.Watermark {
			s.sync(&step)
		}
	case typ == "replayTruncated":
		step.Deliver = append(step.Deliver, f)
		step.Send = append(step.Send, s.SyncFrame())
		s.SyncPending = true
	case typ == "error":
		data, _ := f["data"].(map[string]any)
		code, _ := data["code"].(string)
		step.Deliver = append(step.Deliver, f)
		_, hasClient := data["clientId"]
		switch {
		case code == "replay_unavailable":
			after, ok := asInt(data["retryAfterMs"])
			if !ok {
				after = 1000
			}
			step.Schedule = append(step.Schedule, Scheduled{AfterMs: after, Frame: s.SyncFrame()})
			s.SyncPending = true
		case code == "invalid_watermark" && !hasClient:
			s.Watermark = 0
			s.own = map[int]bool{}
			step.Send = append(step.Send, s.SyncFrame())
			s.SyncPending = true
		}
	case typ == "tokenRefreshed":
	default:
		step.Deliver = append(step.Deliver, f)
	}
	return step
}
