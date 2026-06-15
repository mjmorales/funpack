// handshake.go is the §28.2 attach handshake: the auth + protocol-version
// negotiation a client performs over an already-connected stream BEFORE it sends
// a single session command.
//
// THE WIRE FORM (mirrored from runtime/introspect_attach.odin):
//
//   - The client's FIRST line is the auth envelope `{"v":N,"auth":"<token>"}`
//     (Odin parse_attach_auth_line): `v` is the client's protocol version (the
//     version it offers to negotiate), `auth` is the bearer token. Auth is
//     REQUIRED and is sent first — there is no unauthenticated probe.
//   - The server replies with ONE handshake envelope
//     `{"v":<n>,"handshake":true,"ok":<bool>}` (Odin attach_handshake_response),
//     carrying `,"error":"..."` when ok is false. The reply's `v` is the version
//     the server negotiated; `ok` is the auth+version verdict.
//
// THE HANDSHAKE REPLY IS A TRANSPORT PRE-AMBLE, NOT A §28 MESSAGE KIND. It carries
// `handshake:true` and correlates to no request id, so it does NOT pass through
// the codec's three-kind classifier (Reader.Decode / DecodeMessage) — that
// classifier would see `ok` and try to decode it as a response, then fail the
// response exactly-one `result`/`error` invariant. This file parses the reply
// envelope directly so the pre-amble stays outside the command surface, exactly
// as the Odin side keeps it outside the three closed session kinds.
//
// REFUSE, NEVER BEST-EFFORT (§28.2 auth-required floor): a malformed reply, a
// missing/false `ok`, or a negotiated `v` != contract.ProtocolVersion all return
// a refusal error rather than proceeding. A negotiation that does not land on the
// version this build speaks is a hard stop.
//
// TRANSPORT-AGNOSTIC: Handshake drives a generic io.ReadWriter. The process
// spawn, loopback dial, and token minting live in package session;
// nothing here opens a socket or spawns a process.
//
// SECRET-SAFETY: the auth token is never logged in cleartext — every log site
// routes it through mcperr.Redact / mcperr.LogRedacted.
package introspect

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/rs/zerolog"
)

// authEnvelope is the client's first line: the §28.2 auth pre-amble. `V` is the
// protocol version this build offers to negotiate; `Auth` is the bearer token.
// It mirrors the Odin parse_attach_auth_line shape exactly.
type authEnvelope struct {
	V    int    `json:"v"`
	Auth string `json:"auth"`
}

// handshakeReply is the server's handshake response: the §28.2 transport
// pre-amble that marks itself with Handshake=true and correlates to no request
// id. It mirrors the Odin attach_handshake_response shape; Error is set only when
// Ok is false. Decoded directly here, never through the §28 command codec.
type handshakeReply struct {
	V         int    `json:"v"`
	Handshake bool   `json:"handshake"`
	Ok        bool   `json:"ok"`
	Error     string `json:"error"`
}

// Handshaker performs the §28.2 attach handshake over a generic stream. It holds
// only the optional logger; the stream and token are passed per-handshake so one
// Handshaker can drive successive connections (each its own auth + negotiation).
type Handshaker struct {
	log zerolog.Logger
}

// NewHandshaker builds a Handshaker that logs through log. Pass a zero
// zerolog.Logger (zerolog.Nop()) to silence it. The logger NEVER receives the
// auth token in cleartext — token log sites route through mcperr.LogRedacted.
func NewHandshaker(log zerolog.Logger) *Handshaker {
	return &Handshaker{log: log}
}

// Handshake performs the §28.2 attach handshake over rw and returns the
// negotiated protocol version on success.
//
// It (1) sends the auth envelope `{"v":<ProtocolVersion>,"auth":<authToken>}` as
// the FIRST line, (2) reads the single handshake reply line, and (3) accepts ONLY
// a reply with `ok:true` whose negotiated `v` equals contract.ProtocolVersion.
//
// Refusals (all hard stops, never best-effort):
//   - an empty authToken is a CategorySession refusal — the auth-required floor
//     forbids handshaking with no secret;
//   - a write/read transport fault is a CategoryProtocol refusal;
//   - a malformed or non-handshake reply is a CategoryProtocol refusal;
//   - `ok:false` is a CategorySession refusal (auth/version rejected by the
//     server), carrying the server's error detail;
//   - a negotiated `v` != contract.ProtocolVersion is a CategoryProtocol refusal
//     even when ok:true — this build will not speak a version it did not offer.
//
// The auth token is never logged in cleartext.
func (h *Handshaker) Handshake(rw io.ReadWriter, authToken string) (negotiated int, err error) {
	if authToken == "" {
		return 0, mcperr.New(mcperr.CategorySession,
			"attach handshake requires an auth token (the §28.2 auth-required floor)")
	}

	if err := h.sendAuth(rw, authToken); err != nil {
		return 0, err
	}

	reply, err := readHandshakeReply(rw)
	if err != nil {
		return 0, err
	}

	return h.verify(reply, authToken)
}

// Handshake is the one-shot convenience form: it drives a silent handshake over
// rw with no logger. Use the Handshaker form when a logger is available.
func Handshake(rw io.ReadWriter, authToken string) (negotiated int, err error) {
	return NewHandshaker(zerolog.Nop()).Handshake(rw, authToken)
}

// sendAuth writes the auth envelope as the first NDJSON line. The token rides the
// `auth` field; the envelope marshals through encoding/json (no manual string
// interpolation), so a token with JSON-special characters is escaped correctly
// and never breaks the frame.
func (h *Handshaker) sendAuth(w io.Writer, authToken string) error {
	mcperr.LogRedacted(h.log.Debug(), "auth_token", authToken).
		Int("offered_v", contract.ProtocolVersion).
		Msg("sending attach auth handshake")

	payload, err := json.Marshal(authEnvelope{V: contract.ProtocolVersion, Auth: authToken})
	if err != nil {
		// Marshalling an int + string cannot realistically fail; surface it as a
		// protocol fault rather than masking it.
		return mcperr.Wrap(mcperr.CategoryProtocol, "marshal auth envelope", err)
	}
	payload = append(payload, '\n')
	if _, err := w.Write(payload); err != nil {
		return mcperr.Wrap(mcperr.CategoryProtocol, "write auth handshake line", err)
	}
	return nil
}

// readHandshakeReply reads exactly the first NDJSON line off r and decodes it as
// the handshake reply envelope. It uses a fresh bufio.Reader's ReadBytes rather
// than the §28 codec Reader: the reply is a transport pre-amble carrying
// `handshake:true` and no id, so it is not one of the three closed command kinds
// the codec classifies.
//
// A short stream (peer closed before sending the reply) and a non-handshake
// object both refuse — the auth-required floor never proceeds on an ambiguous
// reply.
func readHandshakeReply(r io.Reader) (handshakeReply, error) {
	line, err := bufio.NewReader(r).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return handshakeReply{}, mcperr.Wrap(mcperr.CategoryProtocol,
			"read handshake reply line", err)
	}

	var reply handshakeReply
	if uErr := json.Unmarshal(line, &reply); uErr != nil {
		return handshakeReply{}, mcperr.Wrap(mcperr.CategoryProtocol,
			"handshake reply is not a JSON object", uErr)
	}
	if !reply.Handshake {
		return handshakeReply{}, mcperr.New(mcperr.CategoryProtocol,
			"first reply line is not a handshake envelope (missing handshake:true)")
	}
	return reply, nil
}

// verify applies the §28.2 accept rule to a parsed reply: ok must be true AND the
// negotiated version must equal this build's contract.ProtocolVersion. Anything
// else refuses. authToken is taken only so a refusal log can confirm WHICH
// (redacted) token was rejected — it is never logged in cleartext.
func (h *Handshaker) verify(reply handshakeReply, authToken string) (int, error) {
	if !reply.Ok {
		detail := reply.Error
		if detail == "" {
			detail = "server refused the attach handshake (ok:false, no detail)"
		}
		mcperr.LogRedacted(h.log.Warn(), "auth_token", authToken).
			Msg("attach handshake refused by server")
		return 0, &mcperr.Error{
			Code:    mcperr.CategorySession,
			Message: "attach handshake refused: auth or version rejected by server",
			Detail:  detail,
		}
	}
	if reply.V != contract.ProtocolVersion {
		return 0, mcperr.New(mcperr.CategoryProtocol,
			fmt.Sprintf("attach version negotiation failed: server negotiated v=%d, this build speaks v=%d",
				reply.V, contract.ProtocolVersion))
	}

	h.log.Debug().Int("negotiated_v", reply.V).Msg("attach handshake accepted")
	return reply.V, nil
}
