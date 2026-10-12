package converger

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// SignatureHeader carries the outbound webhook signature:
//
//	x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>
const SignatureHeader = "X-Converger-Signature"

// DefaultTolerance is the accepted clock skew for webhook signatures.
const DefaultTolerance = 300 * time.Second

// SignatureError reports why a webhook signature did not verify. Compare
// with errors.Is against the Err* values.
type SignatureError struct{ Reason string }

func (e *SignatureError) Error() string { return "converger: webhook signature: " + e.Reason }

var (
	ErrMissingSignature        = &SignatureError{"missing_signature"}
	ErrNoSecret                = &SignatureError{"no_secret"}
	ErrMalformedSignature      = &SignatureError{"malformed_signature"}
	ErrTimestampOutOfTolerance = &SignatureError{"timestamp_out_of_tolerance"}
	ErrInvalidSignature        = &SignatureError{"invalid_signature"}
)

var intRe = regexp.MustCompile(`^[+-]?[0-9]+$`)

type verifyConfig struct {
	tolerance time.Duration
	now       func() time.Time
}

// VerifyOption configures VerifySignature.
type VerifyOption func(*verifyConfig)

// WithTolerance changes the accepted clock skew (default 5 minutes).
func WithTolerance(d time.Duration) VerifyOption { return func(c *verifyConfig) { c.tolerance = d } }

// WithNow replaces the clock (for tests).
func WithNow(now func() time.Time) VerifyOption { return func(c *verifyConfig) { c.now = now } }

// Sign builds an x-converger-signature value (useful for tests).
func Sign(secret string, body []byte, t time.Time) string {
	ts := t.Unix()
	return "t=" + strconv.FormatInt(ts, 10) + ",v1=" + signatureHex(secret, ts, body)
}

func signatureHex(secret string, t int64, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(strconv.FormatInt(t, 10) + "."))
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

func headerValue(h http.Header, name string) string {
	if v := h.Get(name); v != "" {
		return v
	}
	for k, vs := range h {
		if strings.EqualFold(k, name) && len(vs) > 0 {
			return vs[0]
		}
	}
	return ""
}

// VerifySignature checks the x-converger-signature header of a webhook
// request against the raw body (exactly as received, before JSON decoding)
// and the channel secret. It returns nil or a *SignatureError.
func VerifySignature(header http.Header, body []byte, secret string, opts ...VerifyOption) error {
	return VerifySignatureSecrets(header, body, []string{secret}, opts...)
}

// VerifySignatureSecrets is VerifySignature with several secrets (rotation):
// a match with any of them is accepted. The comparison is constant-time.
func VerifySignatureSecrets(header http.Header, body []byte, secrets []string, opts ...VerifyOption) error {
	cfg := verifyConfig{tolerance: DefaultTolerance, now: time.Now}
	for _, o := range opts {
		o(&cfg)
	}

	value := headerValue(header, SignatureHeader)
	if value == "" {
		return ErrMissingSignature
	}
	var keys []string
	for _, s := range secrets {
		if s != "" {
			keys = append(keys, s)
		}
	}
	if len(keys) == 0 {
		return ErrNoSecret
	}

	var ts string
	haveT := false
	var v1 []string
	for _, part := range strings.Split(value, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			continue
		}
		switch {
		case k == "t" && !haveT:
			ts, haveT = v, true
		case k == "v1":
			v1 = append(v1, v)
		}
	}
	if !haveT || !intRe.MatchString(ts) || len(v1) == 0 {
		return ErrMalformedSignature
	}
	t, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return ErrMalformedSignature
	}

	skew := cfg.now().Unix() - t
	if skew < 0 {
		skew = -skew
	}
	if skew > int64(cfg.tolerance/time.Second) {
		return ErrTimestampOutOfTolerance
	}

	matched := 0
	for _, k := range keys {
		expected := []byte(signatureHex(k, t, body))
		for _, candidate := range v1 {
			matched |= subtle.ConstantTimeCompare(expected, []byte(candidate))
		}
	}
	if matched != 1 {
		return ErrInvalidSignature
	}
	return nil
}
