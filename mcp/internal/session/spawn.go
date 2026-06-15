// spawn.go holds the injectable seams the supervised attach session is built
// from: minting the per-session auth token, the per-session handshake temp
// files, and the (process-group) child spawn. Factoring these into struct-valued
// procs is what makes [Open] testable without a live funpack runtime — a test
// swaps in a fake long-running command that writes the port-file and an in-memory
// dialer, and the lifecycle (spawn → poll port-file → dial → handshake → demux →
// Close kills the group + clears the temp files) drives identically.
//
// THE REAL ATTACH CONTRACT THESE SEAMS TARGET (runtime/introspect_attach.odin):
//
//   - PORT: `funpack attach <artifact> --port 0 --port-file P` binds a
//     KERNEL-ASSIGNED ephemeral loopback port (--port 0), then writes the ACTUAL
//     bound port to P as a bare decimal ASCII integer + trailing newline, whole-
//     file in one truncating write, BEFORE accepting. So the supervisor never
//     probes a host-side port (no TOCTOU): it hands the child an empty port-file
//     path and POLLS that file for the kernel-assigned port, then dials it. A
//     reader sees either an absent file or complete contents — never a torn
//     partial — so trim + parse-int is the whole read contract.
//   - AUTH: `funpack attach ... --token-file T` reads the per-session token from
//     file T (whole file, trimmed), with PRECEDENCE over FUNPACK_ATTACH_TOKEN; an
//     empty/whitespace token refuses (the auth-required floor is unchanged). So
//     the token rides a 0600 file, NEVER the argv (the path is on the argv, but
//     the path is not the secret — the file contents are) and NEVER the env.
//   - LOOPBACK: the runtime hardcodes net.IP4_Loopback; we dial 127.0.0.1:<port>.
//   - BUILD GATE: the real server only exists when funpack is built with
//     -define:FUNPACK_LIVE=true; otherwise `attach` is a refuse-stub exiting 2 —
//     which the port-file poll observes as a child-exit and surfaces promptly
//     rather than blocking the full timeout.
package session

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// envAttachToken is the deployment-config env var the funpack runtime reads its
// shared auth token from (mirrors runtime/introspect_attach.odin ATTACH_AUTH_ENV
// "FUNPACK_ATTACH_TOKEN"). The supervisor supplies the token through a --token-file
// instead (which takes precedence over this env), so it is referenced here only to
// assert the var is NOT set in the child env — the secret rides the file, not the
// environment.
const envAttachToken = "FUNPACK_ATTACH_TOKEN"

// loopbackHost is the only interface a supervised attach session ever binds or
// dials (§28.2: remote attach is reachability for a local agent, never an
// exposed surface). The runtime enforces this server-side; we mirror it on the
// dial so a misconfigured port can never reach a non-loopback address.
const loopbackHost = "127.0.0.1"

// tokenBytes sizes the per-session auth token's entropy. 32 bytes of crypto/rand
// rendered base64-url is ~43 unguessable characters — far beyond any brute-force
// window for a session that lives seconds to minutes on loopback.
const tokenBytes = 32

// tokenFilePerm is the mode of the per-session token-file: owner read/write only,
// no group/other bits. The token-file path is on the child argv (visible in `ps`)
// but the path is not the secret — the contents are — so the file must be readable
// by this user alone.
const tokenFilePerm = 0o600

// portFilePoll is the interval between port-file existence/parse checks while the
// supervisor waits for the child to bind its kernel-assigned port and report it.
// Small enough that a fast child is dialed promptly, large enough not to spin.
const portFilePoll = 5 * time.Millisecond

// portFileTimeout bounds how long the supervisor waits for the child to write the
// port-file before giving up. A live child binds + reports within a few
// milliseconds; this guards only against a child that hangs without ever binding.
// A child that EXITS before writing short-circuits this bound (see awaitPortFile).
const portFileTimeout = 5 * time.Second

// mintToken returns a fresh, unguessable per-session auth token: tokenBytes of
// crypto/rand rendered URL-safe-base64 (no padding, so it carries no JSON- or
// shell-special characters). A read failure from the OS CSPRNG is a hard
// CategorySession refusal — a session cannot be gated by a weak secret.
func mintToken() (string, error) {
	buf := make([]byte, tokenBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", mcperr.Wrap(mcperr.CategorySession,
			"minting the per-session attach token failed (crypto/rand)", err)
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// handshakeFiles is the pair of per-session temp paths the file-based attach
// handshake rides on: the child writes its kernel-assigned port to portFile and
// reads its auth token from tokenFile. Both live in a private per-session temp
// dir so concurrent sessions never collide, and the whole dir is removed on
// cleanup.
type handshakeFiles struct {
	dir       string
	portFile  string
	tokenFile string
}

// newHandshakeFiles provisions the per-session temp dir and writes the token into
// a 0600 token-file (the child reads it at startup, so it must exist at spawn).
// The port-file is left ABSENT — the child creates it when it binds, and the
// supervisor's poll treats an absent file as "not bound yet" rather than an error.
// On any failure it removes whatever it created so a half-provisioned session
// leaves no temp litter.
func newHandshakeFiles(token string) (handshakeFiles, error) {
	dir, err := os.MkdirTemp("", "funpack-attach-")
	if err != nil {
		return handshakeFiles{}, mcperr.Wrap(mcperr.CategorySession,
			"creating the per-session attach handshake temp dir failed", err)
	}
	hf := handshakeFiles{
		dir:       dir,
		portFile:  filepath.Join(dir, "port"),
		tokenFile: filepath.Join(dir, "token"),
	}
	if err := os.WriteFile(hf.tokenFile, []byte(token), tokenFilePerm); err != nil {
		_ = os.RemoveAll(dir)
		return handshakeFiles{}, mcperr.Wrap(mcperr.CategorySession,
			"writing the per-session attach token-file failed", err)
	}
	return hf, nil
}

// cleanup removes the per-session temp dir (and both handshake files with it). It
// is best-effort and safe on a zero handshakeFiles (an empty dir is a no-op), so
// Close can call it unconditionally during teardown.
func (hf handshakeFiles) cleanup() {
	if hf.dir == "" {
		return
	}
	_ = os.RemoveAll(hf.dir)
}

// childWaiter owns the SINGLE cmd.Wait for a spawned child: a process may be
// Waited exactly once, but both the port-file poll (which races the child's exit)
// and Close's group-reap need to observe that exit. So one goroutine runs Wait,
// caches its result, and closes done — a closed channel is readable repeatably and
// never blocks, so every observer selects on done and reads err() after.
type childWaiter struct {
	done chan struct{}
	err  error
}

// watchChild starts the one Wait goroutine for cmd and returns the waiter. A child
// that was never started (Process nil) yields an already-closed waiter so callers
// treat it as "already exited" without blocking.
func watchChild(cmd *exec.Cmd) *childWaiter {
	w := &childWaiter{done: make(chan struct{})}
	if cmd == nil || cmd.Process == nil {
		close(w.done)
		return w
	}
	go func() {
		w.err = cmd.Wait()
		close(w.done)
	}()
	return w
}

// awaitPortFile blocks until the child writes its kernel-assigned port to portFile
// and returns that port, or fails fast when the child exits first. It races a poll
// ticker (read+parse the port-file) against the child's exit (waiter.done). A child
// that EXITS before reporting a port — the attach refuse-stub exiting 2, an
// auth-required refusal — surfaces immediately as a CategorySession error rather
// than blocking the full timeout. The ctx and a hard timeout bound the wait so a
// child that hangs without ever binding cannot wedge Open.
//
// A read race is benign: the runtime writes the whole file in one truncating
// write, so the poll sees either an absent file (retry) or the complete decimal —
// trim + ParseInt is the full contract.
func awaitPortFile(ctx context.Context, portFile string, waiter *childWaiter) (int, error) {
	ticker := time.NewTicker(portFilePoll)
	defer ticker.Stop()
	deadline := time.After(portFileTimeout)

	for {
		// Probe once up front and on each tick so a child that binds between ticks
		// is not made to wait a full interval.
		if port, ok := readPortFile(portFile); ok {
			return port, nil
		}
		select {
		case <-waiter.done:
			// The child is gone before it reported a port. One more read closes the
			// race where it wrote the file and exited in the same breath; otherwise
			// the exit IS the failure.
			if port, ok := readPortFile(portFile); ok {
				return port, nil
			}
			return 0, mcperr.Wrap(mcperr.CategorySession,
				"funpack attach exited before reporting its loopback port", childExitErr(waiter.err))
		case <-ticker.C:
		case <-deadline:
			return 0, mcperr.New(mcperr.CategorySession,
				"timed out waiting for funpack attach to report its loopback port")
		case <-ctx.Done():
			return 0, mcperr.Wrap(mcperr.CategorySession,
				"context cancelled waiting for funpack attach to report its loopback port", ctx.Err())
		}
	}
}

// readPortFile reads portFile and parses the bare decimal port the runtime wrote
// (whole-file truncating write + trailing newline). An absent file or an
// unparseable/out-of-range value reports (0, false) — "not bound yet" — so the
// caller retries; a valid 1..65535 reports (port, true).
func readPortFile(portFile string) (int, bool) {
	raw, err := os.ReadFile(portFile)
	if err != nil {
		return 0, false // absent (or transiently unreadable) — not bound yet.
	}
	port, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || port <= 0 || port > 65535 {
		return 0, false
	}
	return port, true
}

// childExitErr renders a child-exit cause for the surfaced error: a non-nil Wait
// error (a non-zero exit code) is the cause, and a clean exit-0-before-binding
// gets a synthetic cause so the wrap always carries a reason.
func childExitErr(waitErr error) error {
	if waitErr != nil {
		return waitErr
	}
	return mcperr.New(mcperr.CategorySession, "child exited 0 without binding a port")
}

// dialLoopback dials the supervised child's loopback attach port with a deadline.
// It is the default Dialer; tests swap in an in-memory connection so the
// lifecycle drives without a real socket. The endpoint is always loopbackHost —
// the dialer never composes a non-loopback address even if handed a stray host.
func dialLoopback(ctx context.Context, port int) (net.Conn, error) {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(loopbackHost, fmt.Sprintf("%d", port)))
	if err != nil {
		return nil, mcperr.Wrap(mcperr.CategorySession,
			fmt.Sprintf("dialing the attach loopback port %s failed", mcperr.RedactPort(port)), err)
	}
	return conn, nil
}

// buildCmd constructs the `funpack attach <artifact> --port 0 --port-file P
// --token-file T` child as an *exec.Cmd in its OWN process group
// (SysProcAttr.Setpgid). The own-group placement is what lets Close signal the
// whole tree (negative-PID kill) rather than just the immediate child. It is the
// default Spawner; tests swap in a fake long-running command via the Config.spawn
// seam.
//
// The token rides a 0600 token-file, NEVER the argv and NEVER the env: argv is
// visible in `ps`, the env is inheritable, but a 0600 file is readable by this
// user alone. The port-file and token-file PATHS are on the argv (the contract
// requires the flags), but a path is not a secret — the token-file's CONTENTS are.
// --port 0 asks the kernel for an ephemeral port; the child reports the actual
// bound port back through the port-file.
func buildCmd(bin, artifact, portFile, tokenFile string) *exec.Cmd {
	cmd := exec.Command(bin, "attach", artifact,
		"--port", "0",
		"--port-file", portFile,
		"--token-file", tokenFile)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// The child's stdio is inherited stderr-only intentionally: stdout/stderr of
	// the attach process carry no protocol (the protocol is the TCP socket), so we
	// route them to the parent's stderr for operator visibility and leave stdin
	// closed. No secret appears in this output — the token is in a 0600 file, the
	// operator-facing "listening on 127.0.0.1:<port>" line is not parsed.
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd
}

// killGroup terminates the process GROUP led by the child (SIGKILL to -pgid),
// then reaps it by waiting on the child's single Wait goroutine (waiter.done). A
// nil cmd or a never-started process is a no-op. Killing the group (not just the
// PID) tears down any grandchildren the attach process forked.
//
// The reap observes waiter.done rather than calling cmd.Wait itself: a process may
// be Waited exactly once, watchChild owns that Wait (so the port-file poll can race
// the same exit), and waiter.done is a closed-channel broadcast every observer can
// read. The bound guards against a Wait that never returns on a wedged child so
// Close stays responsive.
func killGroup(cmd *exec.Cmd, waiter *childWaiter) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	pid := cmd.Process.Pid
	// Negative pid targets the whole group; Setpgid made the child its own leader,
	// so -pid is the group id. Best-effort: a finished child is already gone.
	_ = syscall.Kill(-pid, syscall.SIGKILL)

	if waiter == nil {
		return
	}
	select {
	case <-waiter.done:
	case <-time.After(killReapTimeout):
		// SIGKILLed; if the Wait goroutine still has not delivered we abandon the
		// reap rather than block Close. The OS reclaims the killed process.
	}
}

// killReapTimeout bounds how long Close waits to reap a SIGKILLed child. A
// killed process exits promptly; the bound only guards against a Wait that hangs
// on a wedged child so Close stays responsive.
const killReapTimeout = 2 * time.Second
