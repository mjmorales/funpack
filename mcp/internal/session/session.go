// Package session is the supervised funpack-attach primitive: it spawns
// `funpack attach` in its own process group, dials the auth-gated loopback
// endpoint, performs the §28.2 handshake, and starts a read-side demux over the
// connection — handing back a *Session the registry + reaper (a later task)
// build on. It does NOT implement the registry, the reaper, or any MCP tool;
// it is exactly the one supervised-spawn handle those layers compose.
//
// SECURITY FLOOR (spec §28.2), enforced by construction here:
//
//   - Auth is REQUIRED: a fresh per-session token is minted from crypto/rand and
//     supplied to the child via FUNPACK_ATTACH_TOKEN (the only channel the attach
//     contract exposes). [introspect.Handshake] refuses an empty token, so a
//     session can never come up unauthenticated.
//   - Loopback ONLY: the child binds 127.0.0.1 (runtime-enforced) and we dial
//     127.0.0.1; no public interface is ever touched.
//   - The token and port are NEVER logged in cleartext — every log site routes
//     them through mcperr.Redact / mcperr.RedactPort.
//
// TESTABILITY: the spawn, dial, port, and token steps are [Config] seams (proc
// fields), so the full lifecycle — including "Close kills the process group" —
// drives against a fake long-running command and an in-memory connection with no
// live funpack runtime. See spawn.go for the default seam implementations and
// the real-contract notes.
package session

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net"
	"os/exec"
	"sync"
	"sync/atomic"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/introspect"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/rs/zerolog"
)

// callSeq is the process-wide §28 request-id source. Ids only need to be unique
// within a single session's in-flight set (each session owns its own demux and
// sees only its own responses), and a monotonic global counter trivially is.
var callSeq atomic.Int64

// Session is a live supervised attach: the spawned child, the loopback
// connection, the read-side demux, and the negotiated protocol version, behind
// an opaque session id. It is the supervised-spawn handle the registry + reaper
// compose; this package does not pool, time out, or route tools over it.
//
// Concurrency: the demux (Await/Events) is its own concurrency-safe surface;
// Close is idempotent and safe to call concurrently with in-flight Await calls
// (closing the connection unblocks the demux read loop, which finalizes every
// pending Await). Field access is read-only after Open returns.
type Session struct {
	id         string
	cmd        *exec.Cmd
	conn       net.Conn
	demux      *introspect.Demux
	negotiated int
	// artifact is the built-game path this attach loads, retained so the registry
	// can report it in non-secret SessionInfo without re-deriving it. It is NOT a
	// secret (the token is) and is safe to surface.
	artifact  string
	createdAt time.Time

	// cancel stops the demux Run goroutine (the loop honors ctx cancel); Close
	// invokes it before tearing down the connection and the process group.
	cancel context.CancelFunc
	// runErr is the demux Run goroutine's terminal error, readable after wait
	// closes. Not surfaced by Close (Close is lifecycle, not result), but retained
	// for an accessor a higher layer may consult.
	runErr  error
	wait    chan struct{}
	closeMu sync.Once
}

// Config injects the otherwise-IO seams of [Open] so the lifecycle is testable
// without a live funpack runtime. A zero Config (or any nil field) falls back to
// the production seam: spawn the real `funpack attach` child group, mint a
// crypto/rand token + a kernel ephemeral port, and dial the real loopback
// socket. Tests set the fields to drive a fake command and an in-memory conn.
//
// The seams mirror the discovered attach contract (see spawn.go): mintPort
// approximates ephemeral binding the contract lacks, mintToken feeds the
// env-only credential, spawn places the child in its own group, and dial reaches
// the loopback port.
type Config struct {
	// Log receives lifecycle events. The token and port are NEVER logged through
	// it in cleartext — they route through mcperr.Redact / RedactPort. A zero
	// logger (zerolog.Nop()) silences it.
	Log zerolog.Logger

	// mintToken returns the per-session auth token. Default: crypto/rand.
	mintToken func() (string, error)
	// mintPort claims a free loopback port for the child's --port. Default: a
	// kernel ephemeral-port probe.
	mintPort func() (int, error)
	// spawn builds the (unstarted) child *exec.Cmd given the resolved binary,
	// artifact, port, and minted token. Default: the own-process-group
	// `funpack attach` command with FUNPACK_ATTACH_TOKEN in its env.
	spawn func(bin, artifact string, port int, token string) *exec.Cmd
	// dial connects to the child's loopback attach port. Default: a deadline TCP
	// dial of 127.0.0.1:<port>.
	dial func(ctx context.Context, port int) (net.Conn, error)
	// handshake performs the §28.2 auth+version handshake over conn. Default:
	// introspect.Handshake. Injectable so a test drives the lifecycle without a
	// real server scripting the reply.
	handshake func(rw net.Conn, token string) (negotiated int, err error)
}

// withDefaults returns a Config with every nil seam filled by its production
// implementation, so Open works against the real runtime when handed a zero
// Config and against fakes when handed a populated one.
func (c Config) withDefaults() Config {
	if c.mintToken == nil {
		c.mintToken = mintToken
	}
	if c.mintPort == nil {
		c.mintPort = mintPort
	}
	if c.spawn == nil {
		c.spawn = buildCmd
	}
	if c.dial == nil {
		c.dial = dialLoopback
	}
	if c.handshake == nil {
		c.handshake = func(rw net.Conn, token string) (int, error) {
			return introspect.NewHandshaker(c.Log).Handshake(rw, token)
		}
	}
	return c
}

// Open spawns a supervised `funpack attach` over artifact, dials its loopback
// endpoint, performs the §28.2 handshake with a freshly-minted token, and starts
// a demux over the connection. On success it returns a live *Session whose demux
// is already running; on any failure it tears down whatever it had started (kill
// the group, close the conn) and returns an *mcperr.Error of CategorySession.
//
// The ctx governs only the dial and the demux Run loop lifetime; cancelling it
// after a successful Open stops the read loop exactly as Close does (Close also
// kills the group). The resolved bin.Path is the executable; artifact is the
// built-game path `funpack attach` loads.
//
// SEQUENCE (each step a named checkpoint, each failure a CategorySession refusal):
//
//	mint token → mint port → spawn group → start child → dial loopback →
//	handshake(token) → start demux → return Session
func Open(ctx context.Context, bin funpack.Binary, artifact string, cfg Config) (*Session, error) {
	cfg = cfg.withDefaults()

	token, err := cfg.mintToken()
	if err != nil {
		return nil, err
	}

	port, err := cfg.mintPort()
	if err != nil {
		return nil, err
	}

	cmd := cfg.spawn(bin.Path, artifact, port, token)
	if err := cmd.Start(); err != nil {
		return nil, mcperr.Wrap(mcperr.CategorySession, "spawning funpack attach failed", err)
	}
	cfg.Log.Info().
		Str("attach_port", mcperr.RedactPort(port)).
		Str("artifact", artifact).
		Int("pid", cmd.Process.Pid).
		Msg("spawned supervised funpack attach")

	// From here a failure must reap the child group, or it leaks as an orphan.
	conn, err := cfg.dial(ctx, port)
	if err != nil {
		killGroup(cmd)
		return nil, err
	}

	negotiated, err := cfg.handshake(conn, token)
	if err != nil {
		_ = conn.Close()
		killGroup(cmd)
		return nil, err
	}

	id, err := mintID()
	if err != nil {
		_ = conn.Close()
		killGroup(cmd)
		return nil, err
	}

	runCtx, cancel := context.WithCancel(ctx)
	demux := introspect.NewDemux(introspect.NewReader(conn))
	s := &Session{
		id:         id,
		cmd:        cmd,
		conn:       conn,
		demux:      demux,
		negotiated: negotiated,
		artifact:   artifact,
		createdAt:  time.Now(),
		cancel:     cancel,
		wait:       make(chan struct{}),
	}
	go func() {
		s.runErr = demux.Run(runCtx)
		close(s.wait)
	}()

	cfg.Log.Info().
		Str("session_id", id).
		Int("negotiated_v", negotiated).
		Msg("supervised attach session established")
	return s, nil
}

// idBytes sizes the opaque session id's entropy. 16 bytes hex-rendered is a
// 32-char collision-free handle; the id is not a secret (it is not the auth
// token) so it is logged in cleartext.
const idBytes = 16

// mintID returns an opaque, collision-free session id (idBytes of crypto/rand,
// hex). A CSPRNG read failure is a CategorySession refusal — the same hard floor
// the token mint applies, since a session without a stable handle cannot be
// tracked by the registry.
func mintID() (string, error) {
	buf := make([]byte, idBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", mcperr.Wrap(mcperr.CategorySession,
			"minting the session id failed (crypto/rand)", err)
	}
	return hex.EncodeToString(buf), nil
}

// ID returns the session's opaque, stable handle (NOT the auth token — safe to
// log and to key a registry on).
func (s *Session) ID() string { return s.id }

// NegotiatedVersion returns the §28 protocol version the handshake negotiated
// with the runtime.
func (s *Session) NegotiatedVersion() int { return s.negotiated }

// Artifact returns the built-game path this attach loads — non-secret metadata
// the registry surfaces in SessionInfo.
func (s *Session) Artifact() string { return s.artifact }

// CreatedAt returns the wall-clock instant Open established the session, the
// age key the reaper and session_list read.
func (s *Session) CreatedAt() time.Time { return s.createdAt }

// Demux returns the read-side multiplexer over the session stream — the
// Await(ctx,id) / Events() surface the tool layer correlates responses and
// async events on. The demux is already running; do not call its Run.
func (s *Session) Demux() *introspect.Demux { return s.demux }

// Conn returns the live loopback connection, for the tool layer to write request
// envelopes through (introspect.EncodeRequest). Reads are owned by the demux —
// callers MUST NOT read from this conn directly or they race the demux loop.
func (s *Session) Conn() net.Conn { return s.conn }

// Call issues one §28 request on the session and blocks for its correlated
// response: it allocates a fresh request id, writes the request envelope to the
// connection (introspect.EncodeRequest stamps the protocol version), and awaits
// the matching response on the demux. It is the single seam the session-scoped
// tools (time/inspect/control/self-heal) build every command on, so request-id
// allocation and response correlation live in one place rather than three.
// ctx bounds the wait; a closed stream or protocol fault surfaces as the demux's
// error. args may be nil for a no-argument command.
func (s *Session) Call(ctx context.Context, cmd string, args json.RawMessage) (*contract.Response, error) {
	id := callSeq.Add(1)
	if err := introspect.EncodeRequest(s.conn, contract.Request{ID: id, Cmd: cmd, Args: args}); err != nil {
		return nil, err
	}
	return s.demux.Await(ctx, id)
}

// Close tears the session down: it stops the demux read loop, closes the
// loopback connection, and KILLS THE PROCESS GROUP (not just the immediate child,
// so any grandchildren the attach process forked are reaped too). It is
// idempotent — safe to call more than once and concurrently with in-flight Await
// calls, which unblock when the connection close finalizes the demux. Returns the
// connection-close error if any; the group kill is best-effort.
func (s *Session) Close() error {
	var closeErr error
	s.closeMu.Do(func() {
		// Stop the demux loop first so it does not observe the conn close as a
		// protocol fault during teardown, then close the conn (unblocking any
		// awaiter), then kill the whole child group.
		if s.cancel != nil {
			s.cancel()
		}
		if s.conn != nil {
			closeErr = s.conn.Close()
		}
		<-s.wait // the demux Run goroutine has returned; runErr is now stable.
		killGroup(s.cmd)
	})
	return closeErr
}
