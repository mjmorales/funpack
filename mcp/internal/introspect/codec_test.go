package introspect

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// TestEncodeRequestStampsVersionAndFrames covers the outgoing path: EncodeRequest
// must overwrite V with the protocol version, emit exactly one line terminated by
// a single newline, and produce a line that decodes back to an equal request.
func TestEncodeRequestStampsVersionAndFrames(t *testing.T) {
	tests := []struct {
		name string
		req  contract.Request
	}{
		{
			name: "with args",
			req:  contract.Request{V: 999, ID: 7, Cmd: string(contract.CmdSignals), Args: json.RawMessage(`{"entity":42}`)},
		},
		{
			name: "no args",
			req:  contract.Request{ID: 1, Cmd: string(contract.CmdStatus)},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var buf bytes.Buffer
			if err := EncodeRequest(&buf, tt.req); err != nil {
				t.Fatalf("EncodeRequest: %v", err)
			}

			out := buf.String()
			if strings.Count(out, "\n") != 1 || !strings.HasSuffix(out, "\n") {
				t.Fatalf("framing: want exactly one trailing newline, got %q", out)
			}

			dec, err := DecodeMessage([]byte(out))
			if err != nil {
				t.Fatalf("round-trip DecodeMessage: %v", err)
			}
			if dec.Kind != KindRequest || dec.Request == nil {
				t.Fatalf("round-trip kind: got %q (req=%v)", dec.Kind, dec.Request)
			}
			got := *dec.Request
			if got.V != contract.ProtocolVersion {
				t.Errorf("V: codec must stamp ProtocolVersion=%d, got %d", contract.ProtocolVersion, got.V)
			}
			if got.ID != tt.req.ID || got.Cmd != tt.req.Cmd {
				t.Errorf("round-trip id/cmd: got (%d,%q), want (%d,%q)", got.ID, got.Cmd, tt.req.ID, tt.req.Cmd)
			}
			if !bytes.Equal(got.Args, tt.req.Args) {
				t.Errorf("round-trip args: got %s, want %s", got.Args, tt.req.Args)
			}
		})
	}
}

// TestDecodeMessageAcceptsValidEnvelopes covers the happy path for all three
// closed kinds: an ok response (result set), an error response (error set), and
// an event carrying an open payload.
func TestDecodeMessageAcceptsValidEnvelopes(t *testing.T) {
	tests := []struct {
		name     string
		line     string
		wantKind Kind
		assert   func(t *testing.T, d Decoded)
	}{
		{
			name:     "ok response with result",
			line:     `{"v":1,"id":7,"ok":true,"cmd":"inspect","result":{"entity":42}}`,
			wantKind: KindResponse,
			assert: func(t *testing.T, d Decoded) {
				if !d.Response.Ok {
					t.Error("Ok: want true")
				}
				if d.Response.Result == nil || d.Response.Error != nil {
					t.Errorf("oneof: want result set, error nil; got result=%v error=%v", d.Response.Result, d.Response.Error)
				}
				if string(*d.Response.Result) != `{"entity":42}` {
					t.Errorf("result body: got %s", *d.Response.Result)
				}
			},
		},
		{
			name:     "error response with error",
			line:     `{"v":1,"id":8,"ok":false,"cmd":"set","error":"unknown entity"}`,
			wantKind: KindResponse,
			assert: func(t *testing.T, d Decoded) {
				if d.Response.Ok {
					t.Error("Ok: want false")
				}
				if d.Response.Error == nil || d.Response.Result != nil {
					t.Errorf("oneof: want error set, result nil; got result=%v error=%v", d.Response.Result, d.Response.Error)
				}
				if *d.Response.Error != "unknown entity" {
					t.Errorf("error body: got %q", *d.Response.Error)
				}
			},
		},
		{
			name:     "event with payload",
			line:     `{"v":1,"event":"breakpoint_hit","target":"sprite_update","value":3}`,
			wantKind: KindEvent,
			assert: func(t *testing.T, d Decoded) {
				if d.Event.Name != string(contract.EventBreakpointHit) {
					t.Errorf("event name: got %q", d.Event.Name)
				}
				if len(d.Event.Payload) != 2 {
					t.Fatalf("payload: want 2 keys (target,value), got %v", d.Event.Payload)
				}
				if string(d.Event.Payload["target"]) != `"sprite_update"` {
					t.Errorf("payload.target: got %s", d.Event.Payload["target"])
				}
				if string(d.Event.Payload["value"]) != `3` {
					t.Errorf("payload.value: got %s", d.Event.Payload["value"])
				}
				if _, leaked := d.Event.Payload["v"]; leaked {
					t.Error("payload must not carry the reserved `v` key")
				}
				if _, leaked := d.Event.Payload["event"]; leaked {
					t.Error("payload must not carry the reserved `event` key")
				}
			},
		},
		{
			name:     "event with no payload",
			line:     `{"v":1,"event":"diverged"}`,
			wantKind: KindEvent,
			assert: func(t *testing.T, d Decoded) {
				if d.Event.Name != string(contract.EventDiverged) {
					t.Errorf("event name: got %q", d.Event.Name)
				}
				if len(d.Event.Payload) != 0 {
					t.Errorf("payload: want empty, got %v", d.Event.Payload)
				}
			},
		},
		{
			// A request and a response both carry id+cmd; absence of `ok` is what
			// makes this a request, not a response.
			name:     "request (id, cmd, no ok)",
			line:     `{"v":1,"id":5,"cmd":"status","args":{"branch":"main"}}`,
			wantKind: KindRequest,
			assert: func(t *testing.T, d Decoded) {
				if d.Request.ID != 5 || d.Request.Cmd != string(contract.CmdStatus) {
					t.Errorf("id/cmd: got (%d,%q)", d.Request.ID, d.Request.Cmd)
				}
				if string(d.Request.Args) != `{"branch":"main"}` {
					t.Errorf("args: got %s", d.Request.Args)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			d, err := DecodeMessage([]byte(tt.line))
			if err != nil {
				t.Fatalf("DecodeMessage: %v", err)
			}
			if d.Kind != tt.wantKind {
				t.Fatalf("kind: got %q, want %q", d.Kind, tt.wantKind)
			}
			tt.assert(t, d)
		})
	}
}

// TestDecodeMessageRefusals covers every §28 exact-match refusal: version
// mismatch, the response exactly-one invariant (both / neither), an ambiguous or
// kindless line, and a non-object line. Every refusal must be CategoryProtocol.
func TestDecodeMessageRefusals(t *testing.T) {
	tests := []struct {
		name string
		line string
	}{
		{"version mismatch", `{"v":2,"id":1,"ok":true,"cmd":"status","result":{}}`},
		{"version missing", `{"id":1,"ok":true,"cmd":"status","result":{}}`},
		{"version not int", `{"v":"1","id":1,"ok":true,"cmd":"status","result":{}}`},
		{"response both result and error", `{"v":1,"id":1,"ok":false,"cmd":"set","result":{},"error":"boom"}`},
		{"response neither result nor error", `{"v":1,"id":1,"ok":true,"cmd":"status"}`},
		{"response result explicit null", `{"v":1,"id":1,"ok":true,"cmd":"status","result":null}`},
		{"ambiguous event and ok", `{"v":1,"event":"diverged","ok":true}`},
		{"no kind discriminator", `{"v":1,"id":1}`},
		{"not a json object", `["v",1]`},
		{"empty line", ``},
		{"garbage", `not json`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := DecodeMessage([]byte(tt.line))
			if err == nil {
				t.Fatalf("want refusal for %q", tt.line)
			}
			if !IsProtocolError(err) {
				t.Fatalf("refusal must be CategoryProtocol, got %v", err)
			}
			var de *mcperr.Error
			if !errors.As(err, &de) || de.Code != mcperr.CategoryProtocol {
				t.Fatalf("error must be *mcperr.Error/protocol, got %T %v", err, err)
			}
		})
	}
}

// TestReaderStreamsLines covers the framing reader: consecutive NDJSON lines
// decode in order and a clean end of stream returns io.EOF.
func TestReaderStreamsLines(t *testing.T) {
	stream := strings.Join([]string{
		`{"v":1,"event":"diverged"}`,
		`{"v":1,"id":1,"ok":true,"cmd":"status","result":{"frame":10}}`,
	}, "\n") + "\n"

	r := NewReader(strings.NewReader(stream))

	first, err := r.Decode()
	if err != nil {
		t.Fatalf("Decode 1: %v", err)
	}
	if first.Kind != KindEvent || first.Event.Name != string(contract.EventDiverged) {
		t.Fatalf("Decode 1: got kind=%q", first.Kind)
	}

	second, err := r.Decode()
	if err != nil {
		t.Fatalf("Decode 2: %v", err)
	}
	if second.Kind != KindResponse || !second.Response.Ok {
		t.Fatalf("Decode 2: got kind=%q ok=%v", second.Kind, second.Response.Ok)
	}

	if _, err := r.Decode(); !errors.Is(err, io.EOF) {
		t.Fatalf("Decode 3: want io.EOF, got %v", err)
	}
}

// TestWriterAmortizesAndFlushes covers the buffered Writer form: two sequential
// EncodeRequest calls produce two framed lines on the same stream.
func TestWriterAmortizesAndFlushes(t *testing.T) {
	var buf bytes.Buffer
	w := NewWriter(&buf)

	if err := w.EncodeRequest(contract.Request{ID: 1, Cmd: string(contract.CmdRun)}); err != nil {
		t.Fatalf("EncodeRequest 1: %v", err)
	}
	if err := w.EncodeRequest(contract.Request{ID: 2, Cmd: string(contract.CmdPause)}); err != nil {
		t.Fatalf("EncodeRequest 2: %v", err)
	}

	lines := strings.Split(strings.TrimRight(buf.String(), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("want 2 framed lines, got %d: %q", len(lines), buf.String())
	}
	for i, ln := range lines {
		d, err := DecodeMessage([]byte(ln))
		if err != nil {
			t.Fatalf("line %d decode: %v", i, err)
		}
		if d.Kind != KindRequest {
			t.Errorf("line %d kind: got %q", i, d.Kind)
		}
	}
}
