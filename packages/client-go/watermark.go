package converger

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Watermark is the position a REST page ends at (ClientActivityPage.Watermark,
// ActivityPage.Watermark) and the one to continue after
// (ListActivitiesParams.Watermark).
//
// Since server v3.0 (#63, docs/protocol/v1.md section 6.5) the server emits
// the integer seq of the last activity, a JSON number. Older servers emit an
// opaque base64url string, which the server keeps accepting for one release.
// Both decode into a Watermark; pass it back unchanged.
type Watermark string

// SeqWatermark is the watermark of the integer seq (for example the
// Socket's Watermark()).
func SeqWatermark(seq int) Watermark { return Watermark(strconv.Itoa(seq)) }

// String is the watermark as sent in the `watermark` query parameter.
func (w Watermark) String() string { return string(w) }

// Seq is the integer seq of the watermark: the number itself, or the seq of
// an opaque `seq:N` watermark. ok is false for a legacy activity-id watermark,
// which names no seq.
func (w Watermark) Seq() (seq int, ok bool) {
	if n, err := strconv.Atoi(string(w)); err == nil && n >= 0 && isDecimal(string(w)) {
		return n, true
	}
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(string(w), "="))
	if err != nil || !strings.HasPrefix(string(decoded), "seq:") {
		return 0, false
	}
	digits := strings.TrimPrefix(string(decoded), "seq:")
	n, err := strconv.Atoi(digits)
	if err != nil || n < 0 || !isDecimal(digits) {
		return 0, false
	}
	return n, true
}

// UnmarshalJSON accepts the integer seq (a JSON number) and the opaque string.
func (w *Watermark) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		*w = Watermark(s)
		return nil
	}
	var n json.Number
	if err := json.Unmarshal(data, &n); err != nil {
		return fmt.Errorf("converger: watermark must be a number or a string: %w", err)
	}
	if _, err := strconv.ParseUint(n.String(), 10, 63); err != nil {
		return fmt.Errorf("converger: watermark %s is not a non-negative integer", n)
	}
	*w = Watermark(n.String())
	return nil
}

// MarshalJSON writes an integer seq as a JSON number and anything else as a
// string, the form the server sent.
func (w Watermark) MarshalJSON() ([]byte, error) {
	if isDecimal(string(w)) {
		return []byte(w), nil
	}
	return json.Marshal(string(w))
}

func isDecimal(s string) bool {
	if s == "" || len(s) > 18 || (len(s) > 1 && s[0] == '0') {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
