package converger

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

// statusCodes are the default error codes by HTTP status, used when the body
// does not carry one (packages/conformance/errors.json).
var statusCodes = map[int]string{
	400: "bad_request",
	401: "unauthorized",
	403: "forbidden",
	404: "not_found",
	406: "not_acceptable",
	409: "conflict",
	413: "payload_too_large",
	415: "unsupported_media_type",
	422: "validation_failed",
	429: "rate_limited",
	500: "internal",
	502: "bad_gateway",
	503: "unavailable",
}

// APIError is a non-2xx HTTP response. Its fields are the same whatever error
// shape the server used: the standard envelope
// {"error": {"code", "message", "details", "request_id"}} (#45) or one of the
// legacy shapes.
type APIError struct {
	Status    int
	Code      string
	Message   string
	Details   any
	RequestID string
	// RetryAfter is the Retry-After header in seconds, 0 when absent.
	RetryAfter int
	// Body is the raw response body.
	Body []byte
}

func (e *APIError) Error() string {
	if e.Message == "" {
		return fmt.Sprintf("converger: %d %s", e.Status, e.Code)
	}
	return fmt.Sprintf("converger: %d %s: %s", e.Status, e.Code, e.Message)
}

// ParseAPIError normalizes an error response.
func ParseAPIError(status int, header http.Header, body []byte) *APIError {
	e := &APIError{Status: status, Body: body}
	var doc any
	isJSON := true
	if strings.TrimSpace(string(body)) == "" {
		doc = nil
	} else if err := json.Unmarshal(body, &doc); err != nil {
		isJSON = false
	}
	obj, _ := doc.(map[string]any)

	switch errv := obj["error"].(type) {
	case map[string]any:
		if c, ok := errv["code"].(string); ok {
			e.Code = c
		}
		if m, ok := errv["message"].(string); ok {
			e.Message = m
		}
		e.Details = errv["details"]
		if r, ok := errv["request_id"].(string); ok {
			e.RequestID = r
		}
	case string:
		if d, ok := obj["detail"].(string); ok {
			e.Code, e.Message = errv, d
		} else {
			e.Message = errv
		}
	default:
		if errs, ok := obj["errors"].(map[string]any); ok {
			if d, ok := errs["detail"].(string); ok {
				e.Message = d
			} else {
				e.Message, e.Details = "validation failed", errs
			}
		} else if !isJSON {
			msg := strings.TrimSpace(string(body))
			if len(msg) > 200 {
				msg = msg[:200]
			}
			e.Message = msg
		}
	}

	if e.Code == "" {
		if c, ok := statusCodes[status]; ok {
			e.Code = c
		} else {
			e.Code = fmt.Sprintf("http_%d", status)
		}
	}
	if e.RequestID == "" {
		e.RequestID = header.Get("X-Request-Id")
	}
	if ra := strings.TrimSpace(header.Get("Retry-After")); ra != "" {
		if n, err := strconv.Atoi(ra); err == nil && n >= 0 && !strings.HasPrefix(ra, "+") {
			e.RetryAfter = n
		}
	}
	return e
}

// ProtocolError is an error frame from the Protocol v1 socket, or a refused send.
type ProtocolError struct {
	Code         string
	Message      string
	Retryable    bool
	RetryAfterMs int
	Data         map[string]any
}

func (e *ProtocolError) Error() string {
	return fmt.Sprintf("converger: protocol error %s: %s", e.Code, e.Message)
}

func newProtocolError(data map[string]any) *ProtocolError {
	e := &ProtocolError{Data: data}
	e.Code, _ = data["code"].(string)
	e.Message, _ = data["message"].(string)
	e.Retryable, _ = data["retryable"].(bool)
	if n, ok := asInt(data["retryAfterMs"]); ok {
		e.RetryAfterMs = n
	}
	return e
}

// CloseError reports that the socket closed for good.
type CloseError struct {
	Code   int
	Reason string
}

func (e *CloseError) Error() string {
	return fmt.Sprintf("converger: connection closed (%d) %s", e.Code, e.Reason)
}
