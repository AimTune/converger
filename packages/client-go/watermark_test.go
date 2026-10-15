package converger

import (
	"encoding/json"
	"testing"
)

func TestWatermarkDecodesNumberAndString(t *testing.T) {
	var page ClientActivityPage
	if err := json.Unmarshal([]byte(`{"activities":[],"watermark":42,"has_more":false}`), &page); err != nil {
		t.Fatal(err)
	}
	if page.Watermark == nil || page.Watermark.String() != "42" {
		t.Fatalf("watermark %v, want 42", page.Watermark)
	}
	if seq, ok := page.Watermark.Seq(); !ok || seq != 42 {
		t.Fatalf("seq %d %v, want 42", seq, ok)
	}
	if out, _ := json.Marshal(page.Watermark); string(out) != "42" {
		t.Fatalf("marshal %s, want 42", out)
	}

	if err := json.Unmarshal([]byte(`{"activities":[],"watermark":"c2VxOjQy"}`), &page); err != nil {
		t.Fatal(err)
	}
	if page.Watermark.String() != "c2VxOjQy" {
		t.Fatalf("legacy watermark %q not kept", page.Watermark.String())
	}
	if seq, ok := page.Watermark.Seq(); !ok || seq != 42 {
		t.Fatalf("legacy seq %d %v, want 42", seq, ok)
	}
	if out, _ := json.Marshal(page.Watermark); string(out) != `"c2VxOjQy"` {
		t.Fatalf("marshal %s, want the string", out)
	}

	if err := json.Unmarshal([]byte(`{"activities":[],"watermark":null}`), &page); err != nil || page.Watermark != nil {
		t.Fatalf("null watermark: %v %v", page.Watermark, err)
	}
	for _, bad := range []string{`-1`, `1.5`, `{}`} {
		var w Watermark
		if err := json.Unmarshal([]byte(bad), &w); err == nil {
			t.Fatalf("%s: expected an error", bad)
		}
	}
	if _, ok := Watermark("not-a-watermark").Seq(); ok {
		t.Fatal("opaque garbage has no seq")
	}
	if SeqWatermark(7) != "7" {
		t.Fatal("SeqWatermark")
	}
}
