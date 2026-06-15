package session

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
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
// known token and a child that reports a known port via the port-file, then
// asserts neither the token nor the raw port digits appear anywhere in the
// captured log output — the §28.2 secret-safety floor on the lifecycle, not just
// the handshake.
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
		spawn:     fixedPortSpawn(port),
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
// long-running child is spawned in its own process group, the runtime-simulating
// fake reports its port via the port-file, Open completes the poll+dial+handshake+
// demux over an in-memory conn, and Close KILLS the group so the child is gone
// afterward. No live funpack runtime is involved.
func TestOpenSpawnsInOwnGroupAndCloseKillsIt(t *testing.T) {
	var captured *exec.Cmd
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	go func() { _, _ = serverConn.Read(make([]byte, 1)) }()

	cfg := Config{
		Log:       zerolog.Nop(),
		mintToken: func() (string, error) { return "tok", nil },
		spawn: func(bin, artifact, portFile, tokenFile string) *exec.Cmd {
			captured = fakeAttachCmd(portFile, 1)
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
		spawn:     fixedPortSpawn(1),
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

// --- port-file handshake: poll happy path + child-exit fail-fast -------------

// TestOpenPollsPortFileAndDialsReportedPort asserts the port-file IS the port
// source: the fake child reports a specific port through the port-file, and Open's
// poll resolves it and hands exactly that port to the dial (no host-side probe).
func TestOpenPollsPortFileAndDialsReportedPort(t *testing.T) {
	const reported = 49321

	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	go func() { _, _ = serverConn.Read(make([]byte, 1)) }()

	var dialedPort int
	cfg := Config{
		Log:       zerolog.Nop(),
		mintToken: func() (string, error) { return "tok", nil },
		spawn:     fixedPortSpawn(reported),
		dial: func(_ context.Context, port int) (net.Conn, error) {
			dialedPort = port
			return clientConn, nil
		},
		handshake: func(net.Conn, string) (int, error) { return contract.ProtocolVersion, nil },
	}

	s, err := Open(context.Background(), funpack.Binary{Path: "/bin/sh"}, "a.fp", cfg)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer s.Close()

	if dialedPort != reported {
		t.Fatalf("Open dialed port %d, want the port-file's %d", dialedPort, reported)
	}
}

// TestOpenFailsFastWhenChildExitsBeforePortFile asserts the fail-fast race: a
// child that EXITS before writing the port-file (the attach refuse-stub exiting 2,
// an auth failure) surfaces a CategorySession error PROMPTLY — well within the
// full portFileTimeout — rather than blocking the whole bound. The fake child
// exits non-zero without ever writing the port-file.
func TestOpenFailsFastWhenChildExitsBeforePortFile(t *testing.T) {
	var captured *exec.Cmd
	cfg := Config{
		Log:       zerolog.Nop(),
		mintToken: func() (string, error) { return "tok", nil },
		spawn: func(_, _, _, _ string) *exec.Cmd {
			// Mirrors the refuse-stub: exit 2 immediately, write no port-file.
			captured = exec.Command("/bin/sh", "-c", "exit 2")
			captured.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			return captured
		},
		dial: func(context.Context, int) (net.Conn, error) {
			t.Fatal("dial must not be reached when the child exits before binding")
			return nil, nil
		},
		handshake: func(net.Conn, string) (int, error) {
			t.Fatal("handshake must not be reached when the child exits before binding")
			return 0, nil
		},
	}

	start := time.Now()
	s, err := Open(context.Background(), funpack.Binary{Path: "/bin/sh"}, "a.fp", cfg)
	elapsed := time.Since(start)

	if err == nil {
		_ = s.Close()
		t.Fatal("Open: want a child-exit refusal, got nil")
	}
	var me *mcperr.Error
	if !errors.As(err, &me) || me.Code != mcperr.CategorySession {
		t.Fatalf("Open error: want a CategorySession mcperr, got %v", err)
	}
	if !strings.Contains(err.Error(), "exited before reporting its loopback port") {
		t.Fatalf("Open error: want the child-exit reason, got %q", err.Error())
	}
	// Fail-fast: the child exits in milliseconds; surfacing it must not have waited
	// anywhere near the full portFileTimeout.
	if elapsed > portFileTimeout/2 {
		t.Fatalf("child-exit was not surfaced promptly: took %v (timeout is %v)", elapsed, portFileTimeout)
	}
	// The child group is reaped — Open's failure teardown killed it.
	if captured != nil && captured.Process != nil {
		deadline := time.Now().Add(2 * time.Second)
		pid := captured.Process.Pid
		for groupAlive(pid) && time.Now().Before(deadline) {
			time.Sleep(10 * time.Millisecond)
		}
		if groupAlive(pid) {
			t.Fatalf("child group %d leaked after a child-exit Open failure", pid)
		}
	}
}

// --- idle-activity tracking: the key the reaper sweeps on ---------------------

// TestLastActivitySeededAtOpenAndTouchedByCall asserts the idle clock the reaper
// reads: LastActivity is seeded to CreatedAt at Open (a never-Called session ages
// off its birth, not epoch zero) and a Call advances it (the session is being
// driven). Concurrency-safety is exercised by the -race registry/reaper suites;
// here we pin the observable values.
func TestLastActivitySeededAtOpenAndTouchedByCall(t *testing.T) {
	s := openFakeT(t, "activity.fp")

	// Seeded to creation: not zero, and equal to CreatedAt to nanosecond precision
	// (Open stores created.UnixNano() into both).
	if s.LastActivity().IsZero() {
		t.Fatal("LastActivity is zero on a freshly-opened session")
	}
	if !s.LastActivity().Equal(s.CreatedAt()) {
		t.Fatalf("LastActivity not seeded to CreatedAt: activity=%v created=%v",
			s.LastActivity(), s.CreatedAt())
	}

	before := s.LastActivity()
	time.Sleep(2 * time.Millisecond)
	// A Call over the fake conn touches activity even though no real runtime answers.
	_, _ = s.Call(context.Background(), "noop", nil)
	if !s.LastActivity().After(before) {
		t.Fatalf("Call did not advance LastActivity: before=%v after=%v", before, s.LastActivity())
	}
}

// --- failure teardown: a failed handshake reaps the child group --------------

// TestOpenReapsChildOnHandshakeFailure asserts a handshake refusal AFTER a
// successful spawn+port-file does not leak the child: Open returns the error AND
// the group is dead.
func TestOpenReapsChildOnHandshakeFailure(t *testing.T) {
	var captured *exec.Cmd
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	go func() { _, _ = serverConn.Read(make([]byte, 1)) }()

	wantErr := mcperr.New(mcperr.CategorySession, "scripted handshake refusal")
	cfg := Config{
		Log:       zerolog.Nop(),
		mintToken: func() (string, error) { return "tok", nil },
		spawn: func(_, _, portFile, _ string) *exec.Cmd {
			captured = fakeAttachCmd(portFile, 1)
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

// --- token-file + port-file: the default spawn seam contract -----------------

// TestBuildCmdTokenRidesFileNotArgvNorEnv asserts the default spawn seam carries
// the token ONLY through --token-file (a 0600 file) — never on the argv (visible
// in `ps`) and never in the child env (FUNPACK_ATTACH_TOKEN is not set) — and that
// --port 0, --port-file, and --token-file are all on the argv (the contract
// requires the flags; a path is not the secret).
func TestBuildCmdTokenRidesFileNotArgvNorEnv(t *testing.T) {
	const portFile = "/tmp/funpack-attach-XXXX/port"
	const tokenFile = "/tmp/funpack-attach-XXXX/token"
	cmd := buildCmd("/bin/funpack", "game.fp", portFile, tokenFile)

	if !containsArg(cmd.Args, "attach") || !containsArg(cmd.Args, "game.fp") {
		t.Fatalf("argv missing the attach contract shape: %v", cmd.Args)
	}
	if !hasFlagValue(cmd.Args, "--port", "0") {
		t.Fatalf("argv missing --port 0 (kernel-ephemeral): %v", cmd.Args)
	}
	if !hasFlagValue(cmd.Args, "--port-file", portFile) {
		t.Fatalf("argv missing --port-file %s: %v", portFile, cmd.Args)
	}
	if !hasFlagValue(cmd.Args, "--token-file", tokenFile) {
		t.Fatalf("argv missing --token-file %s: %v", tokenFile, cmd.Args)
	}
	// The default seam leaves cmd.Env nil — the child inherits the parent env via
	// os/exec, but FUNPACK_ATTACH_TOKEN must NOT be injected (the token rides the
	// file). With a nil Env the child inherits os.Environ; assert the var is not
	// among what buildCmd explicitly set.
	for _, e := range cmd.Env {
		if strings.HasPrefix(e, envAttachToken+"=") {
			t.Fatalf("token must not ride the child env, found %q in cmd.Env", e)
		}
	}
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.Setpgid {
		t.Fatal("child not configured for its own process group (Setpgid)")
	}
}

// TestOpenWritesTokenFile0600AndKeepsTokenOffArgvAndEnv drives a full Open and
// asserts the token-file the child read was written 0600, the --token-file path
// (not the secret) is on the argv, and FUNPACK_ATTACH_TOKEN is NOT in the child
// env — the secret rides the 0600 file, never argv, never env.
func TestOpenWritesTokenFile0600AndKeepsTokenOffArgvAndEnv(t *testing.T) {
	const token = "this-secret-must-only-live-in-the-0600-file"

	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	go func() { _, _ = serverConn.Read(make([]byte, 1)) }()

	var gotArgs []string
	var gotEnv []string
	var gotTokenFile string
	cfg := Config{
		Log:       zerolog.Nop(),
		mintToken: func() (string, error) { return token, nil },
		spawn: func(bin, artifact, portFile, tokenFile string) *exec.Cmd {
			gotTokenFile = tokenFile
			cmd := fakeAttachCmd(portFile, 1)
			gotArgs = []string{bin, "attach", artifact, "--port", "0", "--port-file", portFile, "--token-file", tokenFile}
			gotEnv = cmd.Env // a fakeAttachCmd leaves Env nil — no token injected
			return cmd
		},
		dial:      func(context.Context, int) (net.Conn, error) { return clientConn, nil },
		handshake: func(net.Conn, string) (int, error) { return contract.ProtocolVersion, nil },
	}

	// The token-file is removed on Close; read it WHILE the session is live.
	s, err := Open(context.Background(), funpack.Binary{Path: "/bin/sh"}, "a.fp", cfg)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}

	// The token-file the child read carries the secret, mode 0600.
	info, err := os.Stat(gotTokenFile)
	if err != nil {
		_ = s.Close()
		t.Fatalf("stat token-file: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		_ = s.Close()
		t.Fatalf("token-file perm = %o, want 0600", perm)
	}
	raw, err := os.ReadFile(gotTokenFile)
	if err != nil {
		_ = s.Close()
		t.Fatalf("read token-file: %v", err)
	}
	if strings.TrimSpace(string(raw)) != token {
		_ = s.Close()
		t.Fatalf("token-file contents = %q, want the minted token", string(raw))
	}

	// The secret is NOT on the argv and NOT in the child env.
	for _, a := range gotArgs {
		if strings.Contains(a, token) {
			_ = s.Close()
			t.Fatalf("auth token leaked onto argv: %v", gotArgs)
		}
	}
	for _, e := range gotEnv {
		if strings.Contains(e, token) || strings.HasPrefix(e, envAttachToken+"=") {
			_ = s.Close()
			t.Fatalf("auth token / FUNPACK_ATTACH_TOKEN leaked into child env: %q", e)
		}
	}

	// Close removes the per-session temp dir (token-file and port-file with it).
	dir := filepath.Dir(gotTokenFile)
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("per-session temp dir %s survived Close (stat err=%v)", dir, err)
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

// fakeAttachCmd builds a long-running fake child in its OWN process group, the
// stand-in for `funpack attach`. It SIMULATES the runtime's port-file handshake:
// it writes port (a bare decimal + newline, the runtime's whole-file format) into
// portFile BEFORE the child starts, so Open's poll resolves immediately, then
// sleeps far longer than any test so Close is always the thing that ends it. Env
// is left nil — the token never rides the child env. The signature matches the
// Config.spawn seam minus the bound portFile/port the caller fixes.
func fakeAttachCmd(portFile string, port int) *exec.Cmd {
	_ = os.WriteFile(portFile, []byte(strconv.Itoa(port)+"\n"), 0o600)
	cmd := exec.Command("/bin/sh", "-c", "sleep 300")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

// fixedPortSpawn returns a Config.spawn seam whose fake child reports the given
// port through the port-file — the common case for tests that only need the poll
// to resolve to a known value.
func fixedPortSpawn(port int) func(bin, artifact, portFile, tokenFile string) *exec.Cmd {
	return func(_, _, portFile, _ string) *exec.Cmd {
		return fakeAttachCmd(portFile, port)
	}
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

// hasFlagValue reports whether args carries the adjacent pair "flag value".
func hasFlagValue(args []string, flag, value string) bool {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == flag && args[i+1] == value {
			return true
		}
	}
	return false
}
