// Package introspect is the §28 wire codec for the funpack introspection
// protocol: a line-oriented NDJSON framing over arbitrary byte streams, plus
// the exact-match decode of the three closed envelope kinds the contract
// declares (request, response, event).
//
// It is transport-agnostic. There is no socket, spawn, or dial here — those
// land in later §28 tasks. This package only frames JSON objects onto an
// io.Writer and classifies/validates JSON objects read from an io.Reader,
// stamping and enforcing contract.ProtocolVersion on every message.
//
// The §28 discipline this codec enforces (spec §28 §2):
//
//   - Versioned exact-match: every envelope carries `v`; a `v` that is not
//     contract.ProtocolVersion is refused, never best-effort parsed.
//   - Three closed kinds, discriminated structurally: a line is an event when it
//     carries `event`; otherwise a response when it carries `ok` (the response's
//     success boolean — both requests and responses carry `id`/`cmd`, so `ok` is
//     the distinguishing field); otherwise a request when it carries `cmd`. A
//     line matching no kind (or carrying `event` alongside `ok`) is refused.
//   - Response exactly-one invariant: a response carries exactly one of `result`
//     or `error` — never both, never neither.
//
// Every refusal is an *mcperr.Error of CategoryProtocol: a wire-contract
// violation is a protocol fault, not a domain error.
package introspect

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// Kind is the closed §28 envelope discriminant a decoded line resolves to.
type Kind string

const (
	// KindRequest is a request envelope (carries `cmd`, no `id`, no `event`).
	KindRequest Kind = "request"
	// KindResponse is a response envelope (carries `id`).
	KindResponse Kind = "response"
	// KindEvent is an async event envelope (carries `event`).
	KindEvent Kind = "event"
)

// Writer frames outgoing envelopes as NDJSON: one JSON object per line on the
// underlying stream. It buffers writes; call Flush to push them through.
type Writer struct {
	bw *bufio.Writer
}

// NewWriter wraps w with NDJSON framing.
func NewWriter(w io.Writer) *Writer { return &Writer{bw: bufio.NewWriter(w)} }

// EncodeRequest stamps the request with contract.ProtocolVersion and writes it
// as one NDJSON line. The caller's V is overwritten — the codec owns the wire
// version so a handler never has to remember to set it.
func (w *Writer) EncodeRequest(req contract.Request) error {
	req.V = contract.ProtocolVersion

	payload, err := json.Marshal(req)
	if err != nil {
		return mcperr.Wrap(mcperr.CategoryProtocol, "marshal request envelope", err)
	}
	if _, err := w.bw.Write(payload); err != nil {
		return mcperr.Wrap(mcperr.CategoryProtocol, "write request line", err)
	}
	if err := w.bw.WriteByte('\n'); err != nil {
		return mcperr.Wrap(mcperr.CategoryProtocol, "write request newline", err)
	}
	return w.bw.Flush()
}

// EncodeRequest stamps req with contract.ProtocolVersion and writes one NDJSON
// line to w. It is the convenience form for a one-shot write over a raw stream;
// the Writer form amortizes buffering across many sends.
func EncodeRequest(w io.Writer, req contract.Request) error {
	return NewWriter(w).EncodeRequest(req)
}

// Reader reads NDJSON lines from an underlying stream. Each Decode call consumes
// one line and classifies it into a §28 kind.
type Reader struct {
	sc *bufio.Scanner
}

// NewReader wraps r with NDJSON line framing. A single object may not exceed
// maxLineBytes; the default bufio.Scanner token cap is raised so a large probe
// payload (a draw_list or screenshot result) is not truncated mid-line.
func NewReader(r io.Reader) *Reader {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), maxLineBytes)
	return &Reader{sc: sc}
}

// maxLineBytes bounds a single NDJSON object. §28 results can be large (draw
// lists, screenshots) but a single line over 16 MiB signals a framing fault, not
// a legitimate message.
const maxLineBytes = 16 * 1024 * 1024

// Decode reads the next NDJSON line and classifies it. On a clean end of stream
// it returns io.EOF (with a zero Decoded). A framing or contract violation
// returns an *mcperr.Error of CategoryProtocol.
func (r *Reader) Decode() (Decoded, error) {
	if !r.sc.Scan() {
		if err := r.sc.Err(); err != nil {
			return Decoded{}, mcperr.Wrap(mcperr.CategoryProtocol, "read ndjson line", err)
		}
		return Decoded{}, io.EOF
	}
	return DecodeMessage(r.sc.Bytes())
}

// Decoded is the typed result of classifying one §28 line. Exactly one of
// Request, Response, or Event is non-nil, selected by Kind.
type Decoded struct {
	Kind     Kind
	Request  *contract.Request
	Response *contract.Response
	Event    *contract.Event
}

// reserved discriminator and field keys the codec inspects on every line.
const (
	keyV      = "v"
	keyEvent  = "event"
	keyOk     = "ok"
	keyCmd    = "cmd"
	keyResult = "result"
	keyError  = "error"
)

// DecodeMessage classifies a single NDJSON line into one of the three closed
// §28 kinds, enforcing the exact-match discipline:
//
//   - the line must be a JSON object;
//   - `v` must be present and equal to contract.ProtocolVersion;
//   - exactly one kind must match — `event` => event, else `ok` => response,
//     else `cmd` => request; a kindless line, or an `event` line that also
//     carries `ok`, is refused;
//   - a response must carry exactly one of `result` / `error`.
//
// Every refusal is an *mcperr.Error of CategoryProtocol.
func DecodeMessage(line []byte) (Decoded, error) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return Decoded{}, mcperr.New(mcperr.CategoryProtocol, "empty ndjson line is not a valid envelope")
	}

	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil {
		return Decoded{}, mcperr.Wrap(mcperr.CategoryProtocol, "envelope is not a JSON object", err)
	}

	if err := checkVersion(fields); err != nil {
		return Decoded{}, err
	}

	kind, err := classify(fields)
	if err != nil {
		return Decoded{}, err
	}

	switch kind {
	case KindResponse:
		resp, err := decodeResponse(line, fields)
		if err != nil {
			return Decoded{}, err
		}
		return Decoded{Kind: KindResponse, Response: resp}, nil
	case KindEvent:
		ev, err := decodeEvent(line, fields)
		if err != nil {
			return Decoded{}, err
		}
		return Decoded{Kind: KindEvent, Event: ev}, nil
	default:
		req, err := decodeRequest(line)
		if err != nil {
			return Decoded{}, err
		}
		return Decoded{Kind: KindRequest, Request: req}, nil
	}
}

// checkVersion enforces the §28 versioned exact-match: `v` must be present and
// equal to contract.ProtocolVersion.
func checkVersion(fields map[string]json.RawMessage) error {
	raw, ok := fields[keyV]
	if !ok {
		return mcperr.New(mcperr.CategoryProtocol, "envelope missing required `v` version field")
	}
	var v int
	if err := json.Unmarshal(raw, &v); err != nil {
		return mcperr.Wrap(mcperr.CategoryProtocol, "envelope `v` is not an integer", err)
	}
	if v != contract.ProtocolVersion {
		return mcperr.New(mcperr.CategoryProtocol,
			fmt.Sprintf("protocol version mismatch: got v=%d, this build speaks v=%d", v, contract.ProtocolVersion))
	}
	return nil
}

// classify resolves a line to exactly one §28 kind. `event` is the unique event
// discriminator; both request and response carry `id`/`cmd`, so `ok` (the
// response success boolean) is what separates a response from a request. An
// `event` line that also carries `ok` is ambiguous; a line with none of
// `event`/`ok`/`cmd` matches no closed kind.
func classify(fields map[string]json.RawMessage) (Kind, error) {
	_, hasEvent := fields[keyEvent]
	_, hasOk := fields[keyOk]
	_, hasCmd := fields[keyCmd]

	switch {
	case hasEvent && hasOk:
		return "", mcperr.New(mcperr.CategoryProtocol,
			"ambiguous envelope: carries both `event` and `ok` (response) discriminators")
	case hasEvent:
		return KindEvent, nil
	case hasOk:
		return KindResponse, nil
	case hasCmd:
		return KindRequest, nil
	default:
		return "", mcperr.New(mcperr.CategoryProtocol,
			"envelope matches no §28 kind: missing `event`, `ok`, and `cmd` discriminators")
	}
}

// decodeRequest unmarshals a request envelope. `v` is already validated.
func decodeRequest(line []byte) (*contract.Request, error) {
	var req contract.Request
	if err := json.Unmarshal(line, &req); err != nil {
		return nil, mcperr.Wrap(mcperr.CategoryProtocol, "decode request envelope", err)
	}
	return &req, nil
}

// decodeResponse unmarshals a response envelope and enforces the §28
// exactly-one invariant: exactly one of `result` / `error` is present.
func decodeResponse(line []byte, fields map[string]json.RawMessage) (*contract.Response, error) {
	hasResult := isPresent(fields[keyResult])
	hasError := isPresent(fields[keyError])

	switch {
	case hasResult && hasError:
		return nil, mcperr.New(mcperr.CategoryProtocol,
			"response violates §28 exactly-one: both `result` and `error` are present")
	case !hasResult && !hasError:
		return nil, mcperr.New(mcperr.CategoryProtocol,
			"response violates §28 exactly-one: neither `result` nor `error` is present")
	}

	var resp contract.Response
	if err := json.Unmarshal(line, &resp); err != nil {
		return nil, mcperr.Wrap(mcperr.CategoryProtocol, "decode response envelope", err)
	}
	return &resp, nil
}

// decodeEvent unmarshals an event envelope. contract.Event tags Payload as
// json:"-", so the standard decode never fills it; the codec captures every key
// beyond the reserved `v`/`event` into Payload here, honoring the open-payload
// shape the contract declares for events.
func decodeEvent(line []byte, fields map[string]json.RawMessage) (*contract.Event, error) {
	var ev contract.Event
	if err := json.Unmarshal(line, &ev); err != nil {
		return nil, mcperr.Wrap(mcperr.CategoryProtocol, "decode event envelope", err)
	}

	payload := make(map[string]json.RawMessage, len(fields))
	for k, v := range fields {
		if k == keyV || k == keyEvent {
			continue
		}
		payload[k] = v
	}
	if len(payload) > 0 {
		ev.Payload = payload
	}
	return &ev, nil
}

// isPresent reports whether a raw field is present AND not JSON null. A field
// explicitly set to null counts as absent for the exactly-one invariant, so a
// `{"result":null}` response is refused as "neither present" rather than
// silently treated as a present empty result.
func isPresent(raw json.RawMessage) bool {
	if raw == nil {
		return false
	}
	return !bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

// IsProtocolError reports whether err is (or wraps) an *mcperr.Error of
// CategoryProtocol — the category every codec refusal carries. It is the
// predicate callers use to distinguish a wire-contract violation from a clean
// io.EOF or a transport read error.
func IsProtocolError(err error) bool {
	var de *mcperr.Error
	return errors.As(err, &de) && de.Code == mcperr.CategoryProtocol
}
