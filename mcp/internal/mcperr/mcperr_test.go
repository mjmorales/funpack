package mcperr

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// TestErrorString pins the flat rendering of Error: category prefix, optional
// detail in parens, and the wrapped cause appended after a colon.
func TestErrorString(t *testing.T) {
	cause := errors.New("connection refused")
	cases := []struct {
		name string
		err  *Error
		want string
	}{
		{
			name: "message only",
			err:  New(CategoryInvalidInput, "missing path"),
			want: "invalid_input: missing path",
		},
		{
			name: "with detail",
			err:  &Error{Code: CategoryResolver, Message: "no such doc", Detail: "id=42"},
			want: "resolver: no such doc (id=42)",
		},
		{
			name: "with cause",
			err:  Wrap(CategoryExec, "spawn failed", cause),
			want: "exec: spawn failed: connection refused",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.err.Error(); got != tc.want {
				t.Fatalf("Error() = %q, want %q", got, tc.want)
			}
		})
	}

	if cat := New(CategorySession, "stale").Code; cat != CategorySession {
		t.Fatalf("Code = %q, want %q", cat, CategorySession)
	}
}

// TestWrapErrorsAsIs proves a wrapped cause round-trips through both errors.As
// (down to a sentinel type) and errors.Is (to the sentinel value and by
// category), which is the contract sibling packages rely on for cause handling.
func TestWrapErrorsAsIs(t *testing.T) {
	sentinel := errors.New("disk full")
	wrapped := Wrap(CategoryInternal, "write failed", sentinel)

	if !errors.Is(wrapped, sentinel) {
		t.Fatal("errors.Is did not find the wrapped sentinel")
	}

	var de *Error
	if !errors.As(wrapped, &de) {
		t.Fatal("errors.As did not extract *Error")
	}
	if de.Code != CategoryInternal {
		t.Fatalf("extracted Code = %q, want %q", de.Code, CategoryInternal)
	}

	// Category-level match: Is treats any *Error of the same Category as a match.
	if !errors.Is(wrapped, New(CategoryInternal, "")) {
		t.Fatal("errors.Is did not match by category")
	}
	if errors.Is(wrapped, New(CategoryExec, "")) {
		t.Fatal("errors.Is matched a different category")
	}

	// A foreign error wrapping an *Error still resolves via errors.As.
	outer := fmt.Errorf("layer: %w", wrapped)
	var de2 *Error
	if !errors.As(outer, &de2) || de2.Code != CategoryInternal {
		t.Fatalf("errors.As through a foreign wrap failed: %+v", de2)
	}
}

// TestToolErrorEnvelope asserts the tool-boundary mapping: IsError set, a nil
// returned error (never a protocol error for a domain failure), and a single
// TextContent carrying the structured envelope decodable back to its fields.
func TestToolErrorEnvelope(t *testing.T) {
	domain := &Error{Code: CategoryResolver, Message: "doc not found", Detail: "name=foo"}

	res, protoErr := ToolError(domain)
	if protoErr != nil {
		t.Fatalf("ToolError returned a protocol error: %v", protoErr)
	}
	if !res.IsError {
		t.Fatal("CallToolResult.IsError = false, want true")
	}
	if len(res.Content) != 1 {
		t.Fatalf("Content len = %d, want 1", len(res.Content))
	}

	tc, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("Content[0] type = %T, want *mcp.TextContent", res.Content[0])
	}

	var env envelope
	if err := json.Unmarshal([]byte(tc.Text), &env); err != nil {
		t.Fatalf("envelope is not valid JSON: %v (text=%q)", err, tc.Text)
	}
	if env.Category != CategoryResolver || env.Message != "doc not found" || env.Detail != "name=foo" {
		t.Fatalf("decoded envelope = %+v, want {resolver doc not found name=foo}", env)
	}
}

// TestToolErrorNonDomainError confirms a stray non-*Error is wrapped as
// CategoryInternal rather than leaking an unstructured result.
func TestToolErrorNonDomainError(t *testing.T) {
	res, protoErr := ToolError(errors.New("kaboom"))
	if protoErr != nil {
		t.Fatalf("unexpected protocol error: %v", protoErr)
	}

	tc := res.Content[0].(*mcp.TextContent)
	var env envelope
	if err := json.Unmarshal([]byte(tc.Text), &env); err != nil {
		t.Fatalf("envelope is not valid JSON: %v", err)
	}
	if env.Category != CategoryInternal || env.Message != "kaboom" {
		t.Fatalf("decoded envelope = %+v, want {internal kaboom}", env)
	}
}

// TestRedactNeverLeaks is the load-bearing secret-safety check: across empty,
// short, and long inputs Redact never returns a value containing the secret
// body, and a long secret keeps only its first and last rune plus length.
func TestRedactNeverLeaks(t *testing.T) {
	cases := []struct {
		name   string
		secret string
		want   string
	}{
		{"empty", "", ""},
		{"short", "abc", redactMask},
		{"exactly four", "abcd", redactMask},
		{"long token", "sk-1234567890", "s**** (len=13)" /* first=s last=0 */},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Redact(tc.secret)

			// Build the expected long-form dynamically so the want literal above
			// for the long case stays readable; recompute precisely here.
			if tc.name == "long token" {
				tc.want = "s" + redactMask + "0 (len=13)"
			}
			if got != tc.want {
				t.Fatalf("Redact(%q) = %q, want %q", tc.secret, got, tc.want)
			}

			// Hard invariant: for any non-trivial secret the body must not appear
			// in the output. (A 1-rune first/last reveal is acceptable; the full
			// secret never is.)
			if len(tc.secret) > 4 && strings.Contains(got, tc.secret) {
				t.Fatalf("Redact leaked the secret: %q contains %q", got, tc.secret)
			}
		})
	}
}

// TestRedactPort masks a port the same way a token is masked, so a loopback port
// never lands verbatim in a log line.
func TestRedactPort(t *testing.T) {
	got := RedactPort(54173)
	if strings.Contains(got, "54173") {
		t.Fatalf("RedactPort leaked the port: %q", got)
	}
	if got != Redact("54173") {
		t.Fatalf("RedactPort(%d) = %q, want %q", 54173, got, Redact("54173"))
	}
}
