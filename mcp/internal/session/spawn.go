// spawn.go holds the injectable seams the supervised attach session is built
// from: minting the per-session auth token, choosing the loopback endpoint, and
// the (process-group) child spawn. Factoring these into struct-valued procs is
// what makes [Open] testable without a live funpack runtime — a test swaps in a
// fake long-running command and an in-memory dialer, and the lifecycle
// (spawn → dial → handshake → demux → Close kills the group) drives identically.
//
// THE REAL ATTACH CONTRACT THESE SEAMS TARGET (runtime/introspect_attach.odin):
//
//   - PORT: `funpack attach <artifact> [--port N]` binds a FIXED loopback port
//     (default ATTACH_DEFAULT_PORT=7341); there is NO "bind :0, report the
//     chosen port" path. So mintPort below probes the kernel for a free
//     ephemeral port (listen 127.0.0.1:0, read the assigned port, close) and
//     passes it as --port. This carries an unavoidable TOCTOU window — between
//     our close and the child's listen another process could grab the port — but
//     it is the only ephemeral-port path the contract offers. See the package
//     friction note.
//   - AUTH: the token is supplied ONLY through the FUNPACK_ATTACH_TOKEN env var
//     (ATTACH_AUTH_ENV, read once at child startup). There is NO --token flag. So
//     buildCmd sets it in the child's environment, never on the argv.
//   - LOOPBACK: the runtime hardcodes net.IP4_Loopback; we dial 127.0.0.1:<port>.
//   - BUILD GATE: the real server only exists when funpack is built with
//     -define:FUNPACK_LIVE=true; otherwise `attach` is a refuse-stub exiting 2.
package session

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// envAttachToken is the deployment-config env var the funpack runtime reads its
// shared auth token from (mirrors runtime/introspect_attach.odin ATTACH_AUTH_ENV
// "FUNPACK_ATTACH_TOKEN"). The MCP server mints a per-session token and supplies
// it here — the only channel the attach contract exposes for the credential.
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

// mintPort claims a free ephemeral loopback port from the kernel and returns it.
//
// The funpack attach contract has no "bind :0, report the port" path — `attach`
// binds a FIXED --port — so we approximate ephemeral binding host-side: listen on
// 127.0.0.1:0, read the kernel-assigned port, close immediately, and hand that
// port to the child's --port. This is a TOCTOU window (the port is free when we
// read it but the child binds it a moment later); on loopback in a single-agent
// dev session the race is small and the only one the contract permits.
func mintPort() (int, error) {
	l, err := net.Listen("tcp", net.JoinHostPort(loopbackHost, "0"))
	if err != nil {
		return 0, mcperr.Wrap(mcperr.CategorySession,
			"claiming a free loopback port for attach failed", err)
	}
	defer l.Close()
	addr, ok := l.Addr().(*net.TCPAddr)
	if !ok {
		return 0, mcperr.New(mcperr.CategorySession,
			"loopback listener returned a non-TCP address")
	}
	return addr.Port, nil
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

// buildCmd constructs the `funpack attach <artifact> --port <port>` child as an
// *exec.Cmd in its OWN process group (SysProcAttr.Setpgid), with the minted token
// injected via FUNPACK_ATTACH_TOKEN in the child env. The own-group placement is
// what lets Close signal the whole tree (negative-PID kill) rather than just the
// immediate child. It is the default Spawner; tests swap in a fake long-running
// command via the Config.spawn seam.
//
// The token rides the environment, NEVER the argv — argv is visible in `ps` and
// process listings, env is not exported there. The port is on the argv because
// the contract requires --port; it is not a secret (a redacted form is what logs
// see).
func buildCmd(bin, artifact string, port int, token string) *exec.Cmd {
	cmd := exec.Command(bin, "attach", artifact, "--port", fmt.Sprintf("%d", port))
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Env = append(os.Environ(), envAttachToken+"="+token)
	// The child's stdio is inherited stderr-only intentionally: stdout/stderr of
	// the attach process carry no protocol (the protocol is the TCP socket), so we
	// route them to the parent's stderr for operator visibility and leave stdin
	// closed. A token never appears in this output — it is in the env, not argv.
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd
}

// killGroup terminates the process GROUP led by the child (SIGKILL to -pgid),
// then reaps the child so it does not linger as a zombie. A nil cmd or a never-
// started process is a no-op. Killing the group (not just the PID) tears down any
// grandchildren the attach process forked. The reap Wait is bounded so Close
// never blocks indefinitely on a child that ignores the signal.
func killGroup(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	pid := cmd.Process.Pid
	// Negative pid targets the whole group; Setpgid made the child its own leader,
	// so -pid is the group id. Best-effort: a finished child is already gone.
	_ = syscall.Kill(-pid, syscall.SIGKILL)

	done := make(chan struct{})
	go func() {
		_, _ = cmd.Process.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(killReapTimeout):
		// The group was SIGKILLed; if Wait still has not returned we abandon the
		// reap rather than block Close. The OS reclaims the killed process.
	}
}

// killReapTimeout bounds how long Close waits to reap a SIGKILLed child. A
// killed process exits promptly; the bound only guards against a Wait that hangs
// on a wedged child so Close stays responsive.
const killReapTimeout = 2 * time.Second
