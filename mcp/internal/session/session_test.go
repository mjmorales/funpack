package session

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/introspect"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/rs/zerolog"
)

// --- token minting: non-empty, unguessable, never logged ---------------------

// TestMintTokenIsUnguessable asserts the per-session token carries real entropy:
// it is non-empty, of the expected base64-url length, and two successive mints
// never collide (the crypto/rand draw, not a fixed string).
func TestMintTokenIsUnguessable(t *testing.T) {
	seen := make(map[string]struct{}, 64)
	for i := 0; i < 64; i++ {
		tok, err := mintToken()
		if err != nil {
			t.Fatalf("mintToken: unexpected error: %v", err)
		}
		if tok == "" {
			t.Fatal("mintToken returned an empty token")
		}
		// base64-RawURLEncoding of 32 bytes is 43 chars; anything shorter is a
		// weak secret.
		if len(tok) < 40 {
			t.Fatalf("mintToken returned a short token (len=%d): %q", len(tok), tok)
		}
		if _, dup := seen[tok]; dup {
			t.Fatalf("mintToken produced a duplicate token on draw %d — not unguessable", i)
		}
		seen[tok] = struct{}{}
	}
}

// TestOpenNeverLogsTokenOrPortInCleartext drives a full fake-seam Open with a
// known token and port and asserts neither the token nor the raw port digits
// appear anywhere in the captured log output — the §28.2 secret-safety floor on
// the lifecycle, not just the handshake.
func TestOpenNeverLogsTokenOrPortInCleartext(t *testing.T) {
	const token = "TOPSECRET-session-token-do-not-leak-0123456789"
	const port = 54321

	var logBuf bytes.Buffer
	log := zerolog.New(&logBuf).Level(zerolog.DebugLevel)

	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	// A trivial server that the injected handshake bypasses; the conn just needs
	// to be a live net.Conn for the demux to read from until Close.
	go func() { _, _ = serverConn.Read(make([]byte, 1)) }()

	cfg := Config{
		Log:       log,
		mintToken: func() (string, error) { return token, nil },
		mintPort:  func() (int, error) { return port, nil },
		spawn:     fakeSleepCmd,
		dial:      func(context.Context, int) (net.Conn, error) { return clientConn, nil },
		handshake: func(net.Conn, string) (int, error) { return contract.ProtocolVersion, nil },
	}

	s, err := Open(context.Background(), funpack.Binary{Path: "/bin/true"}, "artifact.fp", cfg)
	if err != nil {
		t.Fatalf("Open: unexpected error: %v", err)
	}
	defer s.Close()

	out := logBuf.String()
	if strings.Contains(out, token) {
		t.Fatalf("auth token leaked into session log output: %q", out)
	}
	if strings.Contains(out, "54321") {
		t.Fatalf("raw loopback port leaked into session log output: %q", out)
	}
}

// --- lifecycle: spawned in its own group, Close kills the group --------------

// TestOpenSpawnsInOwnGroupAndCloseKillsIt is the lifecycle spine: a fake
// long-running child is spawned in its own process group, Open completes the
// dial+handshake+demux over an in-memory conn, and Close KILLS the group so the
// child is gone afterward. No live funpack runtime is involved.
func TestOpenSpawnsInOwnGroupAndCloseKillsIt(t *testing.T) {
	var captured *exec.Cmd
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	go func() { _, _ = serverConn.Read(make([]byte, 1)) }()

	cfg := Config{
		Log:       zerolog.Nop(),
		mintToken: func() (string, error) { return "tok", nil },
		mintPort:  func() (int, error) { return 1, nil },
		spawn: func(bin, artifact string, port int, token string) *exec.Cmd {
			captured = fakeSleepCmd(bin, artifact, port, token)
			return captured
		},
		dial:      func(context.Context, int) (net.Conn, error) { return clientConn, nil },
		handshake: func(net.Conn, string) (int, error) { return contract.ProtocolVersion, nil },
	}

	s, err := Open(context.Background(), funpack.Binary{Path: "/bin/sh"}, "artifact.fp", cfg)
	if err != nil {
		t.Fatalf("Open: unexpected error: %v", err)
	}

	// The child must be its own process-group leader: its pgid equals its pid.
	pid := captured.Process.Pid
	pgid, err := syscall.Getpgid(pid)
	if err != nil {
		t.Fatalf("Getpgid(%d): %v", pid, err)
	}
	if pgid != pid {
		t.Fatalf("child is not its own process-group leader: pid=%d pgid=%d", pid, pgid)
	}

	// Accessors expose the established state.
	if s.ID() == "" {
		t.Error("Session.ID() is empty")
	}
	if s.NegotiatedVersion() != contract.ProtocolVersion {
		t.Errorf("NegotiatedVersion: got %d, want %d", s.NegotiatedVersion(), contract.ProtocolVersion)
	}
	if s.Demux() == nil {
		t.Error("Session.Demux() is nil")
	}
	if s.Conn() == nil {
		t.Error("Session.Conn() is nil")
	}

	// Close kills the GROUP. After it returns, signalling the group must fail with
	// ESRCH (no such process) — proof the child is reaped, not lingering.
	if err := s.Close(); err != nil {
		// net.Pipe Close returns nil; a non-nil here is a real conn-close fault.
		t.Fatalf("Close: unexpected error: %v", err)
	}
	if alive := groupAlive(pid); alive {
		t.Fatalf("process group %d is still alive after Close — the group was not killed", pid)
	}
}

// TestCloseIsIdempotent asserts a second Close is a safe no-op (the sync.Once
// guard) — the registry/reaper may both call it.
func TestCloseIsIdempotent(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	go func() { _, _ = serverConn.Read(make([]byte, 1)) }()

	cfg := Config{
		Log:       zerolog.Nop(),
		mintToken: func() (string, error) { return "tok", nil },
		mintPort:  func() (int, error) { return 1, nil },
		spawn:     fakeSleepCmd,
		dial:      func(context.Context, int) (net.Conn, error) { return clientConn, nil },
		handshake: func(net.Conn, string) (int, error) { return contract.ProtocolVersion, nil },
	}
	s, err := Open(context.Background(), funpack.Binary{Path: "/bin/sh"}, "a.fp", cfg)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("first Close: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("second Close must be a no-op, got: %v", err)
	}
}

// --- failure teardown: a failed handshake reaps the child group --------------

// TestOpenReapsChildOnHandshakeFailure asserts a handshake refusal AFTER a
// successful spawn does not leak the child: Open returns the error AND the group
// is dead.
func TestOpenReapsChildOnHandshakeFailure(t *testing.T) {
	var captured *exec.Cmd
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	go func() { _, _ = serverConn.Read(make([]byte, 1)) }()

	wantErr := mcperr.New(mcperr.CategorySession, "scripted handshake refusal")
	cfg := Config{
		Log:       zerolog.Nop(),
		mintToken: func() (string, error) { return "tok", nil },
		mintPort:  func() (int, error) { return 1, nil },
		spawn: func(bin, artifact string, port int, token string) *exec.Cmd {
			captured = fakeSleepCmd(bin, artifact, port, token)
			return captured
		},
		dial:      func(context.Context, int) (net.Conn, error) { return clientConn, nil },
		handshake: func(net.Conn, string) (int, error) { return 0, wantErr },
	}

	s, err := Open(context.Background(), funpack.Binary{Path: "/bin/sh"}, "a.fp", cfg)
	if err == nil {
		_ = s.Close()
		t.Fatal("Open: want handshake refusal, got nil")
	}
	if !errors.Is(err, wantErr) {
		t.Fatalf("Open error: want the scripted refusal, got %v", err)
	}
	pid := captured.Process.Pid
	// killGroup ran synchronously in Open; the child must be gone.
	deadline := time.Now().Add(2 * time.Second)
	for groupAlive(pid) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if groupAlive(pid) {
		t.Fatalf("child group %d leaked after a failed Open", pid)
	}
}

// TestMintPortIsLoopbackAndFree asserts the host-side ephemeral-port probe
// returns a usable, currently-free loopback port (the runtime binds it next).
func TestMintPortIsLoopbackAndFree(t *testing.T) {
	port, err := mintPort()
	if err != nil {
		t.Fatalf("mintPort: %v", err)
	}
	if port <= 0 || port > 65535 {
		t.Fatalf("mintPort returned an out-of-range port: %d", port)
	}
	// The probe closed its listener, so the port must now be re-bindable on
	// loopback — confirming it was a real free port, not a stale handle.
	l, err := net.Listen("tcp", net.JoinHostPort(loopbackHost, intStr(port)))
	if err != nil {
		t.Fatalf("minted port %d is not free on loopback: %v", port, err)
	}
	_ = l.Close()
}

// TestBuildCmdInjectsTokenInEnvNotArgv asserts the default spawn seam carries the
// auth token in FUNPACK_ATTACH_TOKEN and NEVER on the argv (argv is visible in
// `ps`), and that the port IS on the argv as --port (the contract requires it),
// and the child is configured for its own process group.
func TestBuildCmdInjectsTokenInEnvNotArgv(t *testing.T) {
	const token = "argv-must-not-carry-this-secret"
	cmd := buildCmd("/bin/funpack", "game.fp", 7341, token)

	for _, a := range cmd.Args {
		if strings.Contains(a, token) {
			t.Fatalf("auth token leaked onto argv: %v", cmd.Args)
		}
	}
	if !containsArg(cmd.Args, "attach") || !containsArg(cmd.Args, "game.fp") || !containsArg(cmd.Args, "--port") {
		t.Fatalf("argv missing the attach contract shape: %v", cmd.Args)
	}
	wantEnv := envAttachToken + "=" + token
	found := false
	for _, e := range cmd.Env {
		if e == wantEnv {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("FUNPACK_ATTACH_TOKEN not injected into the child env")
	}
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.Setpgid {
		t.Fatal("child not configured for its own process group (Setpgid)")
	}
}

// --- end-to-end against a real funpack: skipped without a live build ---------

// TestEndToEndAgainstRealFunpack drives a real `funpack attach` over a real
// loopback socket — the only path that exercises the wire handshake against the
// actual runtime. It REQUIRES a funpack binary built with -define:FUNPACK_LIVE
// (the headless build's attach is a refuse-stub exiting 2) plus a real built
// artifact, neither of which is available in a hermetic unit-test run, so it
// skips by default. Set FUNPACK_E2E_ATTACH=<artifact-path> with a FUNPACK_BIN (or
// PATH) funpack to run it.
func TestEndToEndAgainstRealFunpack(t *testing.T) {
	artifact := os.Getenv("FUNPACK_E2E_ATTACH")
	if artifact == "" {
		t.Skip("end-to-end attach needs a FUNPACK_LIVE funpack build + a built artifact; " +
			"set FUNPACK_E2E_ATTACH=<artifact-path> to run (the headless attach is a refuse-stub)")
	}
	bin, err := funpack.Resolve()
	if err != nil {
		t.Skipf("no funpack binary resolved for the e2e attach: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	s, err := Open(ctx, bin, artifact, Config{Log: zerolog.Nop()})
	if err != nil {
		t.Fatalf("Open against real funpack attach: %v", err)
	}
	defer s.Close()

	if s.NegotiatedVersion() != contract.ProtocolVersion {
		t.Fatalf("negotiated version: got %d, want %d", s.NegotiatedVersion(), contract.ProtocolVersion)
	}
	// A single observe round-trip confirms the demux + conn are live end-to-end.
	if err := introspect.EncodeRequest(s.Conn(), contract.Request{ID: 1, Cmd: "status"}); err != nil {
		t.Fatalf("EncodeRequest over the live session: %v", err)
	}
	resp, err := s.Demux().Await(ctx, 1)
	if err != nil {
		t.Fatalf("Await status response: %v", err)
	}
	if !resp.Ok {
		t.Fatalf("status response not ok: %+v", resp)
	}
}

// --- test helpers ------------------------------------------------------------

// fakeSleepCmd builds a long-running fake child in its OWN process group, the
// stand-in for `funpack attach` so the lifecycle (spawn → Close kills the group)
// drives without a live runtime. It sleeps far longer than any test so Close is
// always the thing that ends it. The signature matches the Config.spawn seam.
func fakeSleepCmd(_, _ string, _ int, _ string) *exec.Cmd {
	cmd := exec.Command("/bin/sh", "-c", "sleep 300")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

// groupAlive reports whether the process group led by pid still has a live
// member, probed with signal 0 (the existence check that sends no signal). ESRCH
// means the group is gone (Close reaped it); any other result means it lingers.
func groupAlive(pid int) bool {
	err := syscall.Kill(-pid, syscall.Signal(0))
	return !errors.Is(err, syscall.ESRCH)
}

// containsArg reports whether want appears in args.
func containsArg(args []string, want string) bool {
	for _, a := range args {
		if a == want {
			return true
		}
	}
	return false
}

// intStr renders an int as a decimal string for net.JoinHostPort in tests.
func intStr(n int) string {
	return strconv.Itoa(n)
}
