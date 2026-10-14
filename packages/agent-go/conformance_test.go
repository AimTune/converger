package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

// The shared agent conformance fixture (packages/conformance/agent.json) and
// the Protocol v1 schemas every frame the agent sends is validated against.
const (
	fixturePath = "../conformance/agent.json"
	schemaRoot  = "../../priv/protocol/v1"
	schemaBase  = "https://converger.aimtune.dev/schemas/protocol/v1/"
)

type fixture struct {
	Token     string                      `json:"token"`
	Handlers  map[string][]map[string]any `json:"handlers"`
	Scenarios []struct {
		Name  string `json:"name"`
		Agent struct {
			Group      string         `json:"group"`
			Watermarks map[string]int `json:"watermarks"`
		} `json:"agent"`
		Steps []map[string]any `json:"steps"`
	} `json:"scenarios"`
}

var (
	schemasOnce sync.Once
	envelopeSch *jsonschema.Schema
	helloSch    *jsonschema.Schema
	schemaErr   error
)

func schemas(t *testing.T) (*jsonschema.Schema, *jsonschema.Schema) {
	t.Helper()
	schemasOnce.Do(func() {
		c := jsonschema.NewCompiler()
		schemaErr = filepath.WalkDir(schemaRoot, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() || !strings.HasSuffix(path, ".schema.json") {
				return err
			}
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			defer f.Close()
			doc, err := jsonschema.UnmarshalJSON(f)
			if err != nil {
				return fmt.Errorf("%s: %w", path, err)
			}
			id, _ := doc.(map[string]any)["$id"].(string)
			if id == "" {
				return nil
			}
			return c.AddResource(id, doc)
		})
		if schemaErr != nil {
			return
		}
		if envelopeSch, schemaErr = c.Compile(schemaBase + "frames/channel/client-envelope.schema.json"); schemaErr != nil {
			return
		}
		helloSch, schemaErr = c.Compile(schemaBase + "frames/client/hello.schema.json")
	})
	if schemaErr != nil {
		t.Fatalf("schemas: %v", schemaErr)
	}
	return envelopeSch, helloSch
}

// validate checks a frame the agent sent against the v1 schemas.
func validate(t *testing.T, raw []byte) {
	t.Helper()
	envelope, hello := schemas(t)
	inst, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("agent sent invalid JSON: %s", raw)
	}
	m, _ := inst.(map[string]any)
	switch m["type"] {
	case "hello":
		err = hello.Validate(inst)
	case "ping":
		return
	default:
		err = envelope.Validate(inst)
	}
	if err != nil {
		t.Fatalf("agent frame does not match the v1 schema: %s\n%v", raw, err)
	}
}

// fakeServer accepts agent connections; the test drives them one at a time.
type fakeServer struct {
	t     *testing.T
	srv   *httptest.Server
	token string
	conns chan *websocket.Conn
	auths chan string
}

func newFakeServer(t *testing.T, token string) *fakeServer {
	f := &fakeServer{t: t, token: token, conns: make(chan *websocket.Conn, 8), auths: make(chan string, 8)}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != SocketPath {
			http.NotFound(w, r)
			return
		}
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{Subprotocol}})
		if err != nil {
			return
		}
		f.auths <- r.Header.Get("Authorization")
		f.conns <- conn
		<-r.Context().Done()
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeServer) url() string { return SocketURL(f.srv.URL) }

func (f *fakeServer) accept() *websocket.Conn {
	f.t.Helper()
	select {
	case conn := <-f.conns:
		if auth := <-f.auths; auth != "Bearer "+f.token {
			f.t.Fatalf("Authorization header = %q", auth)
		}
		return conn
	case <-time.After(5 * time.Second):
		f.t.Fatal("the agent did not connect")
		return nil
	}
}

// next reads the next frame the agent sent, skipping pings.
func (f *fakeServer) next(conn *websocket.Conn) map[string]any {
	f.t.Helper()
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_, data, err := conn.Read(ctx)
		cancel()
		if err != nil {
			f.t.Fatalf("reading the agent's next frame: %v", err)
		}
		validate(f.t, data)
		var m map[string]any
		if err := json.Unmarshal(data, &m); err != nil {
			f.t.Fatal(err)
		}
		if m["type"] != "ping" {
			return m
		}
	}
}

func (f *fakeServer) write(conn *websocket.Conn, v any) {
	f.t.Helper()
	b, _ := json.Marshal(v)
	if err := conn.Write(context.Background(), websocket.MessageText, b); err != nil {
		f.t.Fatalf("write: %v", err)
	}
}

// subst replaces {{name}} with captured values, in keys and string values.
func subst(v any, caps map[string]string) any {
	switch x := v.(type) {
	case string:
		for k, val := range caps {
			x = strings.ReplaceAll(x, "{{"+k+"}}", val)
		}
		return x
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			out[subst(k, caps).(string)] = subst(val, caps)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = subst(val, caps)
		}
		return out
	}
	return v
}

// match checks actual against a fixture pattern ("$any", "$capture:name",
// "{{name}}"; objects need exactly the same keys).
func match(pattern, actual any, caps map[string]string, path string) error {
	switch p := pattern.(type) {
	case string:
		if p == "$any" {
			return nil
		}
		if name, ok := strings.CutPrefix(p, "$capture:"); ok {
			s, isStr := actual.(string)
			if !isStr || s == "" {
				return fmt.Errorf("%s: expected a string to capture, got %v", path, actual)
			}
			caps[name] = s
			return nil
		}
		if want := subst(p, caps); actual != want {
			return fmt.Errorf("%s: expected %q, got %v", path, want, actual)
		}
		return nil
	case map[string]any:
		a, ok := actual.(map[string]any)
		if !ok {
			return fmt.Errorf("%s: expected an object, got %v", path, actual)
		}
		keys := func(m map[string]any) []string {
			ks := make([]string, 0, len(m))
			for k := range m {
				ks = append(ks, k)
			}
			sort.Strings(ks)
			return ks
		}
		substKeys := map[string]any{}
		for k, v := range p {
			substKeys[subst(k, caps).(string)] = v
		}
		if !reflect.DeepEqual(keys(substKeys), keys(a)) {
			return fmt.Errorf("%s: expected keys %v, got %v", path, keys(substKeys), keys(a))
		}
		for _, k := range keys(substKeys) {
			if err := match(substKeys[k], a[k], caps, path+"."+k); err != nil {
				return err
			}
		}
		return nil
	case []any:
		a, ok := actual.([]any)
		if !ok || len(a) != len(p) {
			return fmt.Errorf("%s: expected %v, got %v", path, p, actual)
		}
		for i := range p {
			if err := match(p[i], a[i], caps, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
		return nil
	default:
		if !reflect.DeepEqual(pattern, actual) {
			return fmt.Errorf("%s: expected %v, got %v", path, pattern, actual)
		}
		return nil
	}
}

// fixtureHandler runs the ops of handlers[turn.Text] (or handlers["*"]).
func fixtureHandler(handlers map[string][]map[string]any) Handler {
	return func(ctx context.Context, turn *Turn, reply *Reply) error {
		ops, ok := handlers[turn.Text]
		if !ok {
			ops = handlers["*"]
		}
		answer := ""
		fill := func(s string) string {
			return strings.NewReplacer("{text}", turn.Text, "{answer}", answer).Replace(s)
		}
		for _, op := range ops {
			var err error
			switch op["op"] {
			case "text":
				_, err = reply.Text(ctx, fill(op["text"].(string)), actions(op["actions"])...)
			case "ask":
				var a any
				a, err = reply.Ask(ctx, op["payload"], actions(op["actions"])...)
				answer = fmt.Sprint(a)
			case "typing":
				err = reply.Typing(ctx, op["on"].(bool))
			case "toolCall":
				call := ToolCall{ID: op["id"].(string), Name: op["name"].(string), Status: op["status"].(string), Result: op["result"]}
				call.Params, _ = op["params"].(map[string]any)
				err = reply.ToolCall(ctx, call)
			case "message":
				_, err = reply.Message(ctx, op["type"].(string), op["data"].(map[string]any))
			default:
				return fmt.Errorf("unknown op %v", op["op"])
			}
			if err != nil {
				return err
			}
		}
		return nil
	}
}

func actions(v any) []Action {
	list, _ := v.([]any)
	out := make([]Action, 0, len(list))
	for _, item := range list {
		m := item.(map[string]any)
		out = append(out, Action{Label: m["label"].(string), Value: m["value"]})
	}
	return out
}

func loadFixture(t *testing.T) fixture {
	t.Helper()
	raw, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var fx fixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	return fx
}

func TestConformance(t *testing.T) {
	fx := loadFixture(t)
	for _, sc := range fx.Scenarios {
		t.Run(sc.Name, func(t *testing.T) {
			server := newFakeServer(t, fx.Token)
			opts := []Option{WithBackoff(10*time.Millisecond, 50*time.Millisecond), WithWatermarks(sc.Agent.Watermarks)}
			if sc.Agent.Group != "" {
				opts = append(opts, WithGroup(sc.Agent.Group))
			}
			a := New(server.url(), StaticToken(fx.Token), opts...)
			a.OnTurn(fixtureHandler(fx.Handlers))
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			go func() { done <- a.Run(ctx) }()
			defer func() {
				cancel()
				select {
				case err := <-done:
					if err != nil {
						t.Errorf("Run returned %v", err)
					}
				case <-time.After(5 * time.Second):
					t.Error("Run did not return after cancel")
				}
			}()

			caps := map[string]string{}
			var conn *websocket.Conn
			for i, step := range sc.Steps {
				switch {
				case step["expect"] != nil:
					if conn == nil {
						conn = server.accept()
					}
					got := server.next(conn)
					if err := match(step["expect"], got, caps, "frame"); err != nil {
						t.Fatalf("step %d: %v\nagent sent: %v", i, err, got)
					}
				case step["send"] != nil:
					server.write(conn, subst(step["send"], caps))
				case step["close"] != nil:
					code, _ := asInt(step["close"])
					_ = conn.Close(websocket.StatusCode(code), "")
					conn = nil
				}
			}
		})
	}
}
