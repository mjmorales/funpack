// Package mcperr is the coherence-critical error and logging foundation every
// funpack MCP tool builds on: one canonical error envelope, one tool-boundary
// mapping, and one secret-safe logging helper.
//
// It is deliberately GENERIC. It imports only the go-sdk mcp package and the
// standard library and MUST NOT import any other internal package, so sibling
// packages (resolvers, exec, session) can depend on it without import cycles.
//
// Three pieces fit together:
//
//   - [Error] / [Category] — a structured domain error with a closed category
//     enum, usable with errors.Is / errors.As, that wraps causes with %w.
//   - [ToolError] — the single mapping every tool handler uses to turn a domain
//     error into an mcp.CallToolResult{IsError: true} carrying the structured
//     envelope as JSON text. See its doc comment for the precise convention.
//   - [Redact] — masks a secret so it never reaches a log line. §28 session
//     tasks MUST route auth tokens and loopback ports through it before logging.
package mcperr

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Category classifies a domain error into a closed, documented set. The set is
// intentionally tight: adding a value is a deliberate change, not an ad-hoc
// addition, so the model and the engine share one fixed error vocabulary.
type Category string

// The closed Category enum. Every domain error carries exactly one of these.
const (
	// CategoryInvalidInput marks a malformed or out-of-contract tool argument —
	// the caller sent something the tool cannot accept.
	CategoryInvalidInput Category = "invalid_input"

	// CategoryResolver marks a failure resolving a funpack path, document, or
	// index entry the tool was asked to operate on.
	CategoryResolver Category = "resolver"

	// CategoryExec marks a failure executing an underlying funpack command or
	// child process the tool drives.
	CategoryExec Category = "exec"

	// CategoryProtocol marks an MCP-protocol-level fault — a violation of the
	// transport or request contract rather than a domain failure.
	CategoryProtocol Category = "protocol"

	// CategorySession marks a session-lifecycle failure — attach, detach, or a
	// stale/absent session the tool needs.
	CategorySession Category = "session"

	// CategoryInternal marks an unexpected internal fault that is not the
	// caller's responsibility — the catch-all for bugs and broken invariants.
	CategoryInternal Category = "internal"
)

// Error is the canonical funpack MCP domain error. Message is the
// human-and-model-readable summary; Detail is optional extra context (an
// underlying message, an offending value already redacted, etc.); cause, when
// set, is the wrapped error and is reachable via Unwrap / errors.As / errors.Is.
type Error struct {
	Code    Category
	Message string
	Detail  string
	cause   error
}

// New builds an Error with no wrapped cause.
func New(cat Category, msg string) *Error {
	return &Error{Code: cat, Message: msg}
}

// Wrap builds an Error that wraps cause, preserving the chain for errors.As /
// errors.Is. The cause is exposed through Unwrap and rendered with %w in Error.
func Wrap(cat Category, msg string, cause error) *Error {
	return &Error{Code: cat, Message: msg, cause: cause}
}

// Error renders "<category>: <message>", appending "(<detail>)" when Detail is
// set and ": <cause>" when a cause is wrapped, so a flat log line keeps the full
// context.
func (e *Error) Error() string {
	out := string(e.Code) + ": " + e.Message
	if e.Detail != "" {
		out += " (" + e.Detail + ")"
	}
	if e.cause != nil {
		out = fmt.Errorf("%s: %w", out, e.cause).Error()
	}
	return out
}

// Unwrap returns the wrapped cause (nil when New was used), enabling
// errors.Unwrap / errors.As traversal down the chain.
func (e *Error) Unwrap() error { return e.cause }

// Is reports a match when target is an *Error of the same Category, so
// errors.Is(err, mcperr.New(cat, "")) tests the category regardless of message.
// Falls through to the wrapped cause via the standard errors.Is chain otherwise.
func (e *Error) Is(target error) bool {
	var t *Error
	if errors.As(target, &t) {
		return e.Code == t.Code
	}
	return false
}

// envelope is the wire shape ToolError marshals into the result's TextContent —
// the structured payload a client parses to recover category, message, and
// detail.
type envelope struct {
	Category Category `json:"category"`
	Message  string   `json:"message"`
	Detail   string   `json:"detail,omitempty"`
}

// ToolError is the single tool-boundary mapping every funpack MCP tool handler
// uses to report a failure.
//
// CONVENTION: A tool handler returns (*mcp.CallToolResult, Out, error). A
// non-nil returned error is a PROTOCOL error — reserve it only for truly
// internal or exceptional conditions the client cannot act on (the SDK turns it
// into an MCP error response, which the model cannot self-correct from). For
// every domain failure — bad input, a failed resolve or exec, a stale session —
// the handler instead returns ToolError(err): a CallToolResult with IsError set
// to true whose first TextContent carries the structured envelope (category,
// message, optional detail) as JSON. The model sees the error in the tool
// result, reads the category, and self-corrects. ToolError always returns a nil
// second value, so a handler writes `return mcperr.ToolError(err)`.
//
// If err is already an *Error its fields populate the envelope directly;
// otherwise it is wrapped as CategoryInternal with err.Error() as the message,
// so a stray non-domain error still surfaces a well-formed envelope.
func ToolError(err error) (*mcp.CallToolResult, error) {
	var de *Error
	if !errors.As(err, &de) {
		de = New(CategoryInternal, err.Error())
	}

	env := envelope{Category: de.Code, Message: de.Message, Detail: de.Detail}
	payload, mErr := json.Marshal(env)
	if mErr != nil {
		// Marshalling a three-string struct cannot realistically fail; degrade to
		// a plain text envelope rather than masking the original error.
		payload = []byte(de.Error())
	}

	return &mcp.CallToolResult{
		IsError: true,
		Content: []mcp.Content{&mcp.TextContent{Text: string(payload)}},
	}, nil
}
