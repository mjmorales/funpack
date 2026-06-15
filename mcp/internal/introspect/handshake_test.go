package introspect

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/rs/zerolog"
)

// fakeOdin emulates the runtime/introspect_attach.odin server side over an
// io.ReadWriter: it reads the client's first auth line, records the presented
// auth envelope, and writes back a scripted handshake reply. The scripted reply
// lets each test drive the accept rule (ok:true matching version, ok:false,
// version mismatch) the real Odin attach_handshake_response produces.
type fakeOdin struct {
	io.Reader // server -> client (the scripted reply)
	io.Writer // client -> server (the auth line lands here)
}

// serveFakeOdin wires a fakeOdin whose reply is a fixed line and whose received
// auth line is captured into authSink. The returned ReadWriter is the client's
// view of the stream.
func serveFakeOdin(reply string, authSink *bytes.Buffer) io.ReadWriter {
	return fakeOdin{
		Reader: strings.NewReader(reply),
		Writer: authSink,
	}
}

// odinReply renders the handshake reply envelope byte-identically to the Odin
// attach_handshake_response form: `{"v":N,"handshake":true,"ok":<bool>}` with an
// `error` field only on refusal.
func odinReply(v int, ok bool, errMsg string) string {
	if ok {
		return fmt.Sprintf("{\"v\":%d,\"handshake\":true,\"ok\":true}\n", v)
	}
	return fmt.Sprintf("{\"v\":%d,\"handshake\":true,\"ok\":false,\"error\":%q}\n", v, errMsg)
}

// TestHandshakeSendsAuthFirstThenAccepts covers the happy path: the auth token is
// sent as the FIRST line in the exact Odin envelope shape, and a matching-version
// ok:true reply yields the negotiated version.
func TestHandshakeSendsAuthFirstThenAccepts(t *testing.T) {
	const token = "s3cr3t-bearer-token"
	var authSink bytes.Buffer
	rw := serveFakeOdin(odinReply(contract.ProtocolVersion, true, ""), &authSink)

	negotiated, err := Handshake(rw, token)
	if err != nil {
		t.Fatalf("Handshake: unexpected error: %v", err)
	}
	if negotiated != contract.ProtocolVersion {
		t.Fatalf("negotiated version: got %d, want %d", negotiated, contract.ProtocolVersion)
	}

	// The first (and only) line the client sent MUST be the auth envelope carrying
	// the offered version and the token — sent BEFORE reading the reply.
	sent := authSink.String()
	if strings.Count(sent, "\n") != 1 || !strings.HasSuffix(sent, "\n") {
		t.Fatalf("auth framing: want exactly one trailing newline, got %q", sent)
	}
	var env authEnvelope
	if uErr := json.Unmarshal([]byte(strings.TrimSpace(sent)), &env); uErr != nil {
		t.Fatalf("auth line is not a JSON object: %v (line=%q)", uErr, sent)
	}
	if env.V != contract.ProtocolVersion {
		t.Errorf("auth offered version: got %d, want %d", env.V, contract.ProtocolVersion)
	}
	if env.Auth != token {
		t.Errorf("auth token in envelope: got %q, want %q", env.Auth, token)
	}
}

// TestHandshakeRefusesOnOkFalse covers an authentication rejection: an ok:false
// reply is refused as a CategorySession error carrying the server's detail, and
// no version is negotiated.
func TestHandshakeRefusesOnOkFalse(t *testing.T) {
	const serverErr = "auth required — connection refused"
	var authSink bytes.Buffer
	rw := serveFakeOdin(odinReply(contract.ProtocolVersion, false, serverErr), &authSink)

	negotiated, err := Handshake(rw, "wrong-token")
	if err == nil {
		t.Fatalf("Handshake: want refusal on ok:false, got negotiated=%d", negotiated)
	}
	if negotiated != 0 {
		t.Errorf("negotiated on refusal: want 0, got %d", negotiated)
	}
	var de *mcperr.Error
	if !errors.As(err, &de) || de.Code != mcperr.CategorySession {
		t.Fatalf("refusal category: want CategorySession, got %v", err)
	}
	if !strings.Contains(de.Error(), serverErr) {
		t.Errorf("refusal must surface the server detail %q, got %q", serverErr, de.Error())
	}
}

// TestHandshakeRefusesOnVersionMismatch covers the negotiate floor: an ok:true
// reply whose negotiated `v` differs from this build's ProtocolVersion is refused
// as a CategoryProtocol error — the build will not speak a version it did not
// agree to.
func TestHandshakeRefusesOnVersionMismatch(t *testing.T) {
	mismatch := contract.ProtocolVersion + 1
	var authSink bytes.Buffer
	rw := serveFakeOdin(odinReply(mismatch, true, ""), &authSink)

	negotiated, err := Handshake(rw, "tok")
	if err == nil {
		t.Fatalf("Handshake: want refusal on version mismatch, got negotiated=%d", negotiated)
	}
	if !IsProtocolError(err) {
		t.Fatalf("version-mismatch refusal must be a protocol error, got %v", err)
	}
	if !strings.Contains(err.Error(), fmt.Sprintf("v=%d", mismatch)) {
		t.Errorf("refusal must name the negotiated version %d, got %q", mismatch, err.Error())
	}
}

// TestHandshakeRefusesEmptyToken covers the auth-required floor at the client:
// handshaking with no secret is refused before any byte is written.
func TestHandshakeRefusesEmptyToken(t *testing.T) {
	var authSink bytes.Buffer
	rw := serveFakeOdin(odinReply(contract.ProtocolVersion, true, ""), &authSink)

	if _, err := Handshake(rw, ""); err == nil {
		t.Fatal("Handshake: want refusal on empty token")
	} else {
		var de *mcperr.Error
		if !errors.As(err, &de) || de.Code != mcperr.CategorySession {
			t.Fatalf("empty-token refusal category: want CategorySession, got %v", err)
		}
	}
	if authSink.Len() != 0 {
		t.Errorf("empty-token handshake must not write any auth bytes, wrote %q", authSink.String())
	}
}

// TestHandshakeRefusesNonHandshakeReply covers a reply that is well-formed JSON
// but is NOT a handshake envelope (no handshake:true) — e.g. the server wrote a
// session response onto the pre-amble slot. It is refused as a protocol fault
// rather than misread as success.
func TestHandshakeRefusesNonHandshakeReply(t *testing.T) {
	var authSink bytes.Buffer
	// A §28 response-shaped line: carries ok but no handshake marker.
	rw := serveFakeOdin(fmt.Sprintf("{\"v\":%d,\"id\":1,\"ok\":true,\"cmd\":\"status\",\"result\":{}}\n",
		contract.ProtocolVersion), &authSink)

	if _, err := Handshake(rw, "tok"); err == nil {
		t.Fatal("Handshake: want refusal on a non-handshake reply")
	} else if !IsProtocolError(err) {
		t.Fatalf("non-handshake refusal must be a protocol error, got %v", err)
	}
}

// TestHandshakeRefusesMalformedReply covers a garbage (non-JSON) reply line: a
// protocol refusal, never a best-effort proceed.
func TestHandshakeRefusesMalformedReply(t *testing.T) {
	var authSink bytes.Buffer
	rw := serveFakeOdin("this is not json\n", &authSink)

	if _, err := Handshake(rw, "tok"); err == nil {
		t.Fatal("Handshake: want refusal on a malformed reply")
	} else if !IsProtocolError(err) {
		t.Fatalf("malformed-reply refusal must be a protocol error, got %v", err)
	}
}

// TestHandshakeRefusesShortStream covers a peer that closes before sending any
// reply (EOF with no line): a protocol refusal.
func TestHandshakeRefusesShortStream(t *testing.T) {
	var authSink bytes.Buffer
	rw := serveFakeOdin("", &authSink) // EOF immediately

	if _, err := Handshake(rw, "tok"); err == nil {
		t.Fatal("Handshake: want refusal on a short stream")
	} else if !IsProtocolError(err) {
		t.Fatalf("short-stream refusal must be a protocol error, got %v", err)
	}
}

// TestHandshakeNeverLogsTokenInCleartext drives the handshake over a real
// net.Pipe with a logger writing to a buffer and asserts the token never appears
// in any logged output — on the accept path AND the refusal path. The auth token
// is the secret §28.2 must never leak to a captured stderr.
func TestHandshakeNeverLogsTokenInCleartext(t *testing.T) {
	const token = "TOPSECRET-do-not-leak-0123456789"

	cases := []struct {
		name  string
		reply string
	}{
		{"accept", odinReply(contract.ProtocolVersion, true, "")},
		{"refuse", odinReply(contract.ProtocolVersion, false, "auth required — connection refused")},
		{"version_mismatch", odinReply(contract.ProtocolVersion+1, true, "")},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var logBuf bytes.Buffer
			// Debug level so even the most verbose log site fires and is checked.
			log := zerolog.New(&logBuf).Level(zerolog.DebugLevel)
			h := NewHandshaker(log)

			client, server := net.Pipe()
			defer client.Close()
			defer server.Close()

			// Server side: drain the client's auth line, then write the scripted reply.
			go func() {
				br := bufio.NewReader(server)
				_, _ = br.ReadBytes('\n')
				_, _ = io.WriteString(server, tc.reply)
			}()

			// Ignore the verdict — this test asserts only the no-leak property, which
			// must hold on every path.
			_, _ = h.Handshake(client, token)

			if strings.Contains(logBuf.String(), token) {
				t.Fatalf("auth token leaked into log output: %q", logBuf.String())
			}
		})
	}
}
