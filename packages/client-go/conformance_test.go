package converger

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func conformanceDir() string {
	if d := os.Getenv("CONVERGER_CONFORMANCE_DIR"); d != "" {
		return d
	}
	return filepath.Join("..", "conformance")
}

func loadJSON(t *testing.T, name string, out any) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(conformanceDir(), name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, out); err != nil {
		t.Fatal(err)
	}
}

// ------------------------------------------------------------- signatures

type signatureVectors struct {
	DefaultTolerance int `json:"default_tolerance_seconds"`
	Sign             []struct {
		Name      string `json:"name"`
		Secret    string `json:"secret"`
		Timestamp int64  `json:"timestamp"`
		Body      string `json:"body"`
		Header    string `json:"header"`
	} `json:"sign"`
	Verify []struct {
		Name      string            `json:"name"`
		Secret    any               `json:"secret"`
		Body      string            `json:"body"`
		Now       int64             `json:"now"`
		Headers   map[string]string `json:"headers"`
		Tolerance *int              `json:"tolerance"`
		Valid     bool              `json:"valid"`
		Error     *string           `json:"error"`
	} `json:"verify"`
}

func TestSignatureVectors(t *testing.T) {
	var v signatureVectors
	loadJSON(t, "webhook-signatures.json", &v)

	for _, s := range v.Sign {
		t.Run("sign/"+s.Name, func(t *testing.T) {
			if got := Sign(s.Secret, []byte(s.Body), time.Unix(s.Timestamp, 0)); got != s.Header {
				t.Fatalf("got %s, want %s", got, s.Header)
			}
		})
	}
	for _, c := range v.Verify {
		t.Run("verify/"+c.Name, func(t *testing.T) {
			h := http.Header{}
			for k, val := range c.Headers {
				h.Add(k, val)
			}
			var secrets []string
			switch sec := c.Secret.(type) {
			case string:
				secrets = []string{sec}
			case []any:
				for _, x := range sec {
					secrets = append(secrets, x.(string))
				}
			}
			tol := v.DefaultTolerance
			if c.Tolerance != nil {
				tol = *c.Tolerance
			}
			err := VerifySignatureSecrets(h, []byte(c.Body), secrets,
				WithTolerance(time.Duration(tol)*time.Second),
				WithNow(func() time.Time { return time.Unix(c.Now, 0) }))
			if c.Valid {
				if err != nil {
					t.Fatalf("expected valid, got %v", err)
				}
				return
			}
			var se *SignatureError
			if !errors.As(err, &se) || se.Reason != *c.Error {
				t.Fatalf("expected %s, got %v", *c.Error, err)
			}
		})
	}
}

func TestVerifySignatureWithTheClock(t *testing.T) {
	body := []byte(`{"id":"x"}`)
	h := http.Header{}
	h.Set(SignatureHeader, Sign("whsec_x", body, time.Now()))
	if err := VerifySignature(h, body, "whsec_x"); err != nil {
		t.Fatal(err)
	}
	if err := VerifySignature(h, body, "other"); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("got %v", err)
	}
}

// ------------------------------------------------------------------ errors

func TestErrorNormalization(t *testing.T) {
	var doc struct {
		Cases []struct {
			Name     string            `json:"name"`
			Status   int               `json:"status"`
			Headers  map[string]string `json:"headers"`
			Body     string            `json:"body"`
			Expected map[string]any    `json:"expected"`
		} `json:"cases"`
	}
	loadJSON(t, "errors.json", &doc)
	for _, c := range doc.Cases {
		t.Run(c.Name, func(t *testing.T) {
			h := http.Header{}
			for k, v := range c.Headers {
				h.Set(k, v)
			}
			e := ParseAPIError(c.Status, h, []byte(c.Body))
			got := map[string]any{
				"status":      e.Status,
				"code":        e.Code,
				"message":     e.Message,
				"details":     e.Details,
				"request_id":  nilIfEmpty(e.RequestID),
				"retry_after": nilIfZero(e.RetryAfter),
			}
			assertJSONEqual(t, got, c.Expected)
		})
	}
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nilIfZero(n int) any {
	if n == 0 {
		return nil
	}
	return n
}

func assertJSONEqual(t *testing.T, got, want any) {
	t.Helper()
	gb, _ := json.Marshal(got)
	wb, _ := json.Marshal(want)
	var g, w any
	_ = json.Unmarshal(gb, &g)
	_ = json.Unmarshal(wb, &w)
	if !reflect.DeepEqual(g, w) {
		t.Fatalf("got %s\nwant %s", gb, wb)
	}
}

// -------------------------------------------------------------------- REST

type restCase struct {
	Name      string         `json:"name"`
	Operation string         `json:"operation"`
	Args      map[string]any `json:"args"`
	Request   struct {
		Method  string            `json:"method"`
		Path    string            `json:"path"`
		Query   map[string]string `json:"query"`
		Headers map[string]string `json:"headers"`
		JSON    json.RawMessage   `json:"json"`
	} `json:"request"`
	Response struct {
		Status  int               `json:"status"`
		Headers map[string]string `json:"headers"`
		Body    json.RawMessage   `json:"body"`
	} `json:"response"`
	Result map[string]any `json:"result"`
	Error  map[string]any `json:"error"`
}

func str(m map[string]any, k string) string { s, _ := m[k].(string); return s }

func num(m map[string]any, k string) int { n, _ := asInt(m[k]); return n }

// wmArg is the `watermark` argument as sent: an integer seq or an opaque string.
func wmArg(m map[string]any) string {
	if n, ok := asInt(m["watermark"]); ok {
		return strconv.Itoa(n)
	}
	return str(m, "watermark")
}

func mapOf(m map[string]any, k string) map[string]any { v, _ := m[k].(map[string]any); return v }

func listOfMaps(m map[string]any, k string) []map[string]any {
	raw, ok := m[k].([]any)
	if !ok {
		return nil
	}
	out := make([]map[string]any, 0, len(raw))
	for _, x := range raw {
		out = append(out, x.(map[string]any))
	}
	return out
}

func callOperation(ctx context.Context, c *Client, op string, a map[string]any) (any, error) {
	act := mapOf(a, "activity")
	switch op {
	case "client_api.generate_token":
		return c.ClientAPI.GenerateToken(ctx, GenerateTokenParams{UserID: str(a, "user_id"), Scope: str(a, "scope")})
	case "client_api.refresh_token":
		return c.ClientAPI.RefreshToken(ctx, str(a, "token"))
	case "client_api.create_conversation":
		return c.ClientAPI.CreateConversation(ctx, str(a, "token"))
	case "client_api.get_conversation":
		return c.ClientAPI.GetConversation(ctx, str(a, "token"), str(a, "conversation_id"), wmArg(a))
	case "client_api.close_conversation":
		return c.ClientAPI.CloseConversation(ctx, str(a, "token"), str(a, "conversation_id"))
	case "client_api.reopen_conversation":
		return c.ClientAPI.ReopenConversation(ctx, str(a, "token"), str(a, "conversation_id"))
	case "client_api.post_activity":
		return c.ClientAPI.PostActivity(ctx, str(a, "token"), str(a, "conversation_id"), ClientActivityInput{
			Type: str(act, "type"), Text: str(act, "text"), FromID: str(act, "from_id"),
			Attachments: listOfMaps(act, "attachments"), ReplyToID: str(act, "reply_to_id"),
			ChannelData: mapOf(act, "channel_data"), IdempotencyKey: str(a, "idempotency_key"),
		})
	case "client_api.list_activities":
		return c.ClientAPI.ListActivities(ctx, str(a, "token"), str(a, "conversation_id"),
			ListActivitiesParams{Watermark: Watermark(wmArg(a)), Limit: num(a, "limit")})
	case "tenant_api.list_conversations":
		return c.TenantAPI.ListConversations(ctx, ListConversationsParams{
			Limit: num(a, "limit"), Cursor: str(a, "cursor"), Status: str(a, "status"),
			ChannelID: str(a, "channel_id"), ExternalID: str(a, "external_id"),
		})
	case "tenant_api.get_conversation":
		return c.TenantAPI.GetConversation(ctx, str(a, "conversation_id"))
	case "tenant_api.close_conversation":
		return c.TenantAPI.CloseConversation(ctx, str(a, "conversation_id"))
	case "tenant_api.reopen_conversation":
		return c.TenantAPI.ReopenConversation(ctx, str(a, "conversation_id"))
	case "tenant_api.post_activity":
		return c.TenantAPI.PostActivity(ctx, str(a, "conversation_id"), ActivityInput{
			Type: str(act, "type"), Sender: str(act, "sender"), Text: str(act, "text"),
			Attachments: listOfMaps(act, "attachments"), Metadata: mapOf(act, "metadata"),
			ReplyToID: str(act, "reply_to_id"), IdempotencyKey: str(a, "idempotency_key"),
		})
	case "tenant_api.list_activities":
		return c.TenantAPI.ListActivities(ctx, str(a, "conversation_id"),
			ListActivitiesParams{Watermark: Watermark(wmArg(a)), Limit: num(a, "limit")})
	}
	return nil, fmt.Errorf("unknown operation %s", op)
}

func normName(s string) string { return strings.ToLower(strings.ReplaceAll(s, "_", "")) }

// resolve follows a conformance result path through structs, maps and slices.
func resolve(v reflect.Value, path string) (any, error) {
	for _, seg := range strings.Split(path, ".") {
		for v.Kind() == reflect.Pointer || v.Kind() == reflect.Interface {
			if v.IsNil() {
				return nil, fmt.Errorf("nil before %q", seg)
			}
			v = v.Elem()
		}
		switch v.Kind() {
		case reflect.Slice:
			i, err := strconv.Atoi(seg)
			if err != nil || i >= v.Len() {
				return nil, fmt.Errorf("bad index %q", seg)
			}
			v = v.Index(i)
		case reflect.Map:
			found := false
			for _, k := range v.MapKeys() {
				if normName(k.String()) == normName(seg) {
					v, found = v.MapIndex(k), true
					break
				}
			}
			if !found {
				return nil, fmt.Errorf("no key %q", seg)
			}
		case reflect.Struct:
			f := v.FieldByNameFunc(func(n string) bool { return normName(n) == normName(seg) })
			if !f.IsValid() {
				return nil, fmt.Errorf("no field %q in %s", seg, v.Type())
			}
			v = f
		default:
			return nil, fmt.Errorf("cannot descend into %s at %q", v.Kind(), seg)
		}
	}
	return v.Interface(), nil
}

func TestRESTConformance(t *testing.T) {
	var doc struct {
		Client map[string]string `json:"client"`
		Cases  []restCase        `json:"cases"`
	}
	loadJSON(t, "rest.json", &doc)

	for _, c := range doc.Cases {
		t.Run(c.Name, func(t *testing.T) {
			var seen *http.Request
			var seenBody []byte
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				seen = r
				seenBody, _ = io.ReadAll(r.Body)
				for k, v := range c.Response.Headers {
					w.Header().Set(k, v)
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(c.Response.Status)
				_, _ = w.Write(c.Response.Body)
			}))
			defer srv.Close()

			client := New(srv.URL, WithAPIKey(doc.Client["api_key"]), WithChannelSecret(doc.Client["channel_secret"]))
			result, err := callOperation(context.Background(), client, c.Operation, c.Args)

			if seen == nil {
				t.Fatal("no request sent")
			}
			if seen.Method != c.Request.Method || seen.URL.Path != c.Request.Path {
				t.Fatalf("request %s %s, want %s %s", seen.Method, seen.URL.Path, c.Request.Method, c.Request.Path)
			}
			gotQuery := map[string]string{}
			for k, vs := range seen.URL.Query() {
				gotQuery[k] = vs[0]
			}
			assertJSONEqual(t, gotQuery, c.Request.Query)
			for k, want := range c.Request.Headers {
				if got := strings.Split(seen.Header.Get(k), ";")[0]; got != want {
					t.Fatalf("header %s = %q, want %q", k, got, want)
				}
			}
			if len(c.Request.JSON) > 0 {
				var got, want any
				if err := json.Unmarshal(seenBody, &got); err != nil {
					t.Fatalf("body %q: %v", seenBody, err)
				}
				_ = json.Unmarshal(c.Request.JSON, &want)
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("body %s, want %s", seenBody, c.Request.JSON)
				}
			}

			if c.Error != nil {
				var apiErr *APIError
				if !errors.As(err, &apiErr) {
					t.Fatalf("expected APIError, got %v", err)
				}
				got := map[string]any{"status": apiErr.Status, "code": apiErr.Code, "message": apiErr.Message, "request_id": apiErr.RequestID}
				for k, want := range c.Error {
					assertJSONEqual(t, got[k], want)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			for path, want := range c.Result {
				got, err := resolve(reflect.ValueOf(result), path)
				if err != nil {
					// a nil pointer on the way means null
					if want == nil {
						continue
					}
					t.Fatalf("%s: %v", path, err)
				}
				assertJSONEqual(t, got, want)
			}
		})
	}
}

func TestTenantAPIRequiresAPIKey(t *testing.T) {
	_, err := New("http://x").TenantAPI.GetConversation(context.Background(), "c")
	if err == nil {
		t.Fatal("expected an error")
	}
}

// --------------------------------------------------------------- protocol

func TestProtocolScenarios(t *testing.T) {
	var doc struct {
		Scenarios []struct {
			Name    string         `json:"name"`
			Initial map[string]any `json:"initial"`
			Hello   map[string]any `json:"hello"`
			Steps   []struct {
				Recv   map[string]any `json:"recv"`
				Expect struct {
					Deliver   []string         `json:"deliver"`
					Send      []map[string]any `json:"send"`
					Schedule  []map[string]any `json:"schedule"`
					Watermark *int             `json:"watermark"`
				} `json:"expect"`
			} `json:"steps"`
		} `json:"scenarios"`
	}
	loadJSON(t, "protocol.json", &doc)

	for _, sc := range doc.Scenarios {
		t.Run(sc.Name, func(t *testing.T) {
			s := NewSession(num(sc.Initial, "watermark"), str(sc.Initial, "conversation_id"))
			assertJSONEqual(t, s.Hello(), sc.Hello)
			for i, st := range sc.Steps {
				step := s.OnFrame(st.Recv)
				labels := []string{}
				for _, f := range step.Deliver {
					if seq, ok := asInt(f["seq"]); ok {
						labels = append(labels, fmt.Sprintf("%s:%d", f["type"], seq))
					} else {
						labels = append(labels, f["type"].(string))
					}
				}
				want := st.Expect.Deliver
				if want == nil {
					want = []string{}
				}
				if !reflect.DeepEqual(labels, want) {
					t.Fatalf("step %d deliver %v, want %v", i, labels, want)
				}
				sends := []map[string]any{}
				for _, f := range step.Send {
					sends = append(sends, f)
				}
				wantSend := st.Expect.Send
				if wantSend == nil {
					wantSend = []map[string]any{}
				}
				assertJSONEqual(t, sends, wantSend)
				sched := []map[string]any{}
				for _, x := range step.Schedule {
					sched = append(sched, map[string]any{"after_ms": x.AfterMs, "frame": x.Frame})
				}
				wantSched := st.Expect.Schedule
				if wantSched == nil {
					wantSched = []map[string]any{}
				}
				assertJSONEqual(t, sched, wantSched)
				if st.Expect.Watermark != nil && s.Watermark != *st.Expect.Watermark {
					t.Fatalf("step %d watermark %d, want %d", i, s.Watermark, *st.Expect.Watermark)
				}
			}
		})
	}
}
