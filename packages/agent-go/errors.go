package agent

import (
	"errors"
	"fmt"
	"time"
)

// Error is an `error` frame of Protocol v1 (docs/protocol/v1.md section 12):
// a refused send, an error about one conversation, or a connection-level error.
type Error struct {
	Code           string
	Message        string
	Number         int
	Retryable      bool
	RetryAfter     time.Duration
	ClientID       string
	FrameType      string
	Details        map[string]any
	ConversationID string
}

func (e *Error) Error() string {
	if e.ConversationID != "" {
		return fmt.Sprintf("converger: %s (conversation %s): %s", e.Code, e.ConversationID, e.Message)
	}
	return fmt.Sprintf("converger: %s: %s", e.Code, e.Message)
}

// CloseError ends Run: the server closed the connection with a code that
// reconnecting cannot help (1008, 4400, 4401 without a fresh token, 4403).
type CloseError struct {
	Code   int
	Reason string
	// Last is the last connection-level error frame before the close, if any.
	Last *Error
}

func (e *CloseError) Error() string {
	if e.Last != nil {
		return fmt.Sprintf("converger: connection closed (%d): %s", e.Code, e.Last.Message)
	}
	return fmt.Sprintf("converger: connection closed (%d) %s", e.Code, e.Reason)
}

// ErrAckTimeout is returned by a send whose ack did not arrive in time.
var ErrAckTimeout = errors.New("converger: no ack within the ack timeout")

// ErrStopped is returned by sends and asks after Run returned.
var ErrStopped = errors.New("converger: agent stopped")

func parseError(conversationID string, frame map[string]any) *Error {
	data, _ := frame["data"].(map[string]any)
	e := &Error{ConversationID: conversationID}
	e.Code, _ = data["code"].(string)
	e.Message, _ = data["message"].(string)
	if n, ok := asInt(data["number"]); ok {
		e.Number = n
	}
	e.Retryable, _ = data["retryable"].(bool)
	if ms, ok := asInt(data["retryAfterMs"]); ok {
		e.RetryAfter = time.Duration(ms) * time.Millisecond
	}
	e.ClientID, _ = data["clientId"].(string)
	e.FrameType, _ = data["frameType"].(string)
	e.Details, _ = data["details"].(map[string]any)
	return e
}

func asInt(v any) (int, bool) {
	switch n := v.(type) {
	case float64:
		return int(n), n == float64(int(n))
	case int:
		return n, true
	case int64:
		return int(n), true
	}
	return 0, false
}
