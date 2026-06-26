// §28.2 REMOTE ATTACH — the introspection contract served on an auth-gated port.
//
// The §28 duplex contract (introspect.odin's session_request fold) is, by its own
// design, transport-agnostic: "one NDJSON line in, one NDJSON line out, no socket
// — the duplex transport is a thin adapter a live host wires over this seam".
// Today only the pure fold exists (the loopback-stream contract, harness-tested
// without a transport). This file adds the NETWORK transport — the SAME envelope
// request/response contract over a TCP socket, gated by a REQUIRED auth handshake
// (§28.2: "auth is required, never optional; the auth mechanism (token, mTLS) is
// operator deployment configuration, not language doctrine").
//
// THE SPLIT MIRRORS session_live.odin (the SDL driver): everything above the
// `when #config(FUNPACK_LIVE)` block at the foot is PURE — the auth seam, the
// NDJSON handshake framing, the loopback-bind endpoint decision, and the
// serve-one-connection loop driven over an abstract Line_Transport — so the whole
// transport+auth wrapper is headless-testable (introspect_attach_test.odin feeds
// serve_attach_connection an IN-MEMORY transport and asserts no-auth/wrong-auth is
// refused and an authed connection serves an identical observe round-trip). The
// blocking core:net listen/accept loop in the when-block is a THIN adapter: it
// constructs a Line_Transport over a TCP_Socket and calls the SAME
// serve_attach_connection the test drives. ODIN-FIRST: core:net supplies the
// socket primitives (listen_tcp / accept_tcp / recv_tcp / send_tcp / close /
// Endpoint / IP4_Loopback) — no custom socket code, no new dependency.
//
// DETERMINISM WARRANTY UNTOUCHED (§28 §2): remote attach changes TRANSPORT, not the
// recorded simulation. It drives the SAME session_request fold; observe stays a
// pure read of the retained COW chain; no recorded state is mutated. The auth gate
// and the framing sit entirely OUTSIDE session_request, so the existing
// non-perturbation digest pin (introspect_test.odin) holds unchanged.
package funpack_runtime

import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

// ATTACH_AUTH_ENV is the deployment-config env var carrying the default
// shared-token credential (§28.2: the auth MECHANISM is operator deployment
// configuration, not language doctrine). The server reads it ONCE at startup; an
// absent or empty value means NO server is started (the auth-required floor — you
// cannot serve remote attach without a secret). The specific var name is a
// deployment convention, not part of the wire contract.
ATTACH_AUTH_ENV :: "FUNPACK_ATTACH_TOKEN"

// ATTACH_DEFAULT_PORT is the default loopback TCP port remote attach listens on
// when the operator passes no override. A dev-only debug channel, so a fixed
// default is convenience, not contract — the bind is always loopback (§28.2 serves
// the SAME contract; remote attach is reachability, never a public surface).
ATTACH_DEFAULT_PORT :: 7341

// --- The auth seam (auth-REQUIRED enforced by construction) -----------------

// Attach_Auth is the §28.2 pluggable auth seam. auth-REQUIRED is language doctrine
// and is enforced BY CONSTRUCTION: there is no "no-auth" variant — an Attach_Auth
// always carries a non-empty `expected` credential and a `check` predicate, and
// the only constructors (attach_auth_from_token / attach_auth_from_env) REFUSE to
// produce one without a secret. The MECHANISM is the seam: `check` is a proc field
// an operator deployment can replace (mTLS, an HMAC scheme, an external verifier)
// without touching the auth-required floor — the default is a constant-shape shared
// bearer-token compare (attach_token_check).
Attach_Auth :: struct {
	expected: string,
	check:    proc(expected: string, presented: string) -> bool,
}

// attach_token_check is the DEFAULT auth mechanism: an exact shared-token compare.
// It runs the comparison over the full expected length regardless of an early
// mismatch (a fixed-shape compare, so the accept/reject decision does not branch on
// a prefix) — a deployment swapping in mTLS replaces this proc wholesale via the
// Attach_Auth.check seam.
attach_token_check :: proc(expected: string, presented: string) -> bool {
	if len(expected) != len(presented) {
		return false
	}
	diff := 0
	for i in 0 ..< len(expected) {
		diff |= int(expected[i] ~ presented[i])
	}
	return diff == 0
}

// attach_auth_from_token builds the shared-token auth seam from an explicit
// credential. ok=false on an EMPTY token — the auth-required floor: a server cannot
// be gated by an empty secret, so the caller must refuse to listen. The expected
// token is cloned onto `allocator` so the seam owns its credential independently of
// the caller's buffer.
attach_auth_from_token :: proc(token: string, allocator := context.allocator) -> (auth: Attach_Auth, ok: bool) {
	if token == "" {
		return {}, false
	}
	return Attach_Auth{expected = strings.clone(token, allocator), check = attach_token_check}, true
}

// attach_auth_from_env builds the default auth seam from the ATTACH_AUTH_ENV
// deployment-config variable. ok=false when the variable is ABSENT or EMPTY
// (os.lookup_env distinguishes the two, but both fail the auth-required floor the
// same way) — the server then refuses to listen. This is the one place the default
// MECHANISM (shared token) meets its CONFIG source (the env); a deployment using a
// different mechanism constructs its own Attach_Auth and never calls this.
attach_auth_from_env :: proc(allocator := context.allocator) -> (auth: Attach_Auth, ok: bool) {
	token, found := os.lookup_env(ATTACH_AUTH_ENV, allocator)
	if !found || token == "" {
		return {}, false
	}
	return attach_auth_from_token(token, allocator)
}

// attach_auth_from_file builds the default auth seam from a TOKEN FILE — the secret
// read out-of-band from a 0600 file the supervisor controls, NOT through the
// inherited environment (a coarse, leak-prone channel every child process and a
// `/proc/<pid>/environ` reader sees). The whole file is the token, trimmed of
// surrounding whitespace (a trailing newline from `echo "$tok" > file` is the common
// case). ok=false when the file is unreadable OR the trimmed contents are empty — the
// SAME auth-required floor attach_auth_from_env enforces, so the secret's CHANNEL
// changed but the floor did not.
attach_auth_from_file :: proc(path: string, allocator := context.allocator) -> (auth: Attach_Auth, ok: bool) {
	raw, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil {
		return {}, false
	}
	token := strings.trim_space(string(raw))
	if token == "" {
		return {}, false
	}
	return attach_auth_from_token(token, allocator)
}

// attach_auth_resolve picks the token SOURCE for the server: a --token-file PATH
// (when the operator passed one) takes PRECEDENCE over the ATTACH_AUTH_ENV fallback.
// PRECEDENCE is total, not "merge" — a passed --token-file is the sole source, so a
// file that exists-but-is-empty REFUSES (it does not silently fall back to the env);
// only an UNSET --token-file consults the env. Either way the auth-required floor is
// the same (empty-from-either ⇒ ok=false ⇒ the caller refuses to listen). Pure
// dispatch over (has_file, path) — the source decision is headless-testable apart
// from the FUNPACK_LIVE listen.
attach_auth_resolve :: proc(token_file: string, has_token_file: bool, allocator := context.allocator) -> (auth: Attach_Auth, ok: bool) {
	if has_token_file {
		return attach_auth_from_file(token_file, allocator)
	}
	return attach_auth_from_env(allocator)
}

// attach_auth_decide runs the seam's check on a presented credential. Pure over the
// auth value — the accept/reject decision the handshake gate consumes, isolated from
// any transport so it is headless-testable on its own.
attach_auth_decide :: proc(auth: Attach_Auth, presented: string) -> bool {
	if auth.check == nil {
		return false
	}
	return auth.check(auth.expected, presented)
}

// --- The handshake wire form (a transport pre-amble, NOT a §28 message kind) ---

// parse_attach_auth_line extracts the presented credential from the FIRST NDJSON
// line on a connection: the auth envelope `{"v":N,"auth":"<token>"}`. It is the
// transport-layer handshake pre-amble — gated and consumed BEFORE any session
// command, so it does NOT touch the three closed §28 message kinds and the command
// surface stays unchanged. The envelope is version-checked exactly as a request is
// (§28 §2 exact-match): a foreign `v` is ok=false. A malformed line, a non-object, a
// missing `auth`, or a non-string `auth` is ok=false — the gate then refuses the
// connection rather than best-effort parsing.
parse_attach_auth_line :: proc(line: string, allocator := context.allocator) -> (token: string, ok: bool) {
	parsed, parse_err := json.parse(transmute([]u8)line, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return "", false
	}
	object, is_object := parsed.(json.Object)
	if !is_object {
		return "", false
	}
	if declared, has_version := json_int_field(object, "v"); has_version {
		if declared != INTROSPECT_PROTOCOL_VERSION {
			return "", false
		}
	}
	presented, has_auth := json_string_field(object, "auth")
	if !has_auth {
		return "", false
	}
	return presented, true
}

// attach_handshake_response renders the handshake reply envelope: a success/refusal
// the client reads before sending any request. It reuses the §28 envelope skeleton
// (versioned, `ok` boolean) so a client parses it with the same reader, but carries
// `"handshake":true` to mark it the transport pre-amble rather than a command
// response (it correlates to no request id). A refusal is the last line the server
// writes before closing the connection — the auth-required floor made observable.
attach_handshake_response :: proc(ok: bool, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "{{\"v\":%d,\"handshake\":true,\"ok\":%s", INTROSPECT_PROTOCOL_VERSION, ok ? "true" : "false")
	if !ok {
		strings.write_string(&b, ",\"error\":")
		write_json_string(&b, "auth required — connection refused")
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// --- The loopback-bind decision (pure; the socket call is when-gated) -------

// attach_listen_endpoint is the §28.2 bind decision: remote attach ALWAYS binds the
// loopback interface (127.0.0.1), never a public address — reachability for a local
// agent/CI attaching to a running dev build, never an exposed surface. Pure (returns
// the core:net Endpoint without opening a socket), so the loopback-only choice is
// headless-tested; the when-gated server passes this straight to listen_tcp.
attach_listen_endpoint :: proc(port: int) -> net.Endpoint {
	return net.Endpoint{address = net.IP4_Loopback, port = port}
}

// --- The abstract line transport seam ---------------------------------------

// Line_Transport is the byte-stream seam serve_attach_connection drives, factored
// out so the connection loop is PURE and headless-testable: the in-memory test
// supplies a buffer-backed transport, the when-gated socket loop supplies one over a
// core:net TCP_Socket. `recv` reads up to len(buf) bytes (returns 0 on a graceful
// peer close, matching recv_tcp); `send` writes the whole buffer; `userdata` carries
// the backing handle (the socket, or the test's buffer state). Both procs return
// ok=false on a transport fault — the loop then ends the connection.
Line_Transport :: struct {
	userdata: rawptr,
	recv:     proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool),
	send:     proc(userdata: rawptr, buf: []byte) -> (ok: bool),
}

// Line_Reader buffers a transport's byte stream into complete NDJSON lines. NDJSON
// framing is newline-delimited, so a recv may split a line or carry several; the
// reader accumulates into `pending` and hands back one line per next_line call,
// refilling from the transport when no full line is buffered. The buffering lives
// here (not in session_request, which is framing-agnostic by contract).
Line_Reader :: struct {
	transport: Line_Transport,
	pending:   [dynamic]byte,
	closed:    bool,
}

// new_line_reader builds a reader over a transport, its `pending` accumulator on
// `allocator`.
new_line_reader :: proc(transport: Line_Transport, allocator := context.allocator) -> Line_Reader {
	return Line_Reader{transport = transport, pending = make([dynamic]byte, allocator)}
}

// reader_next_line returns the next complete NDJSON line (newline stripped), pulling
// from the transport until a newline is buffered. ok=false when the peer closed (or
// faulted) with no further complete line — the connection loop then ends. A trailing
// unterminated fragment at close is dropped (an incomplete line is not a request).
reader_next_line :: proc(r: ^Line_Reader, allocator := context.allocator) -> (line: string, ok: bool) {
	for {
		if idx := bytes.index_byte(r.pending[:], '\n'); idx >= 0 {
			line = strings.clone(string(r.pending[:idx]), allocator)
			remaining := len(r.pending) - (idx + 1)
			if remaining > 0 {
				copy(r.pending[:], r.pending[idx + 1:])
			}
			resize(&r.pending, remaining)
			return line, true
		}
		if r.closed {
			return "", false
		}
		chunk: [4096]byte
		n, recv_ok := r.transport.recv(r.transport.userdata, chunk[:])
		if !recv_ok || n == 0 {
			r.closed = true
			continue
		}
		append(&r.pending, ..chunk[:n])
	}
}

// --- Serve one connection: the auth gate, then the request loop -------------

// serve_attach_connection serves ONE attached connection over a Line_Transport: it
// (1) reads the FIRST line as the auth handshake, refuses the connection on a
// missing/malformed/mismatched credential (writing the refusal envelope, then
// returning so the caller closes the socket), and (2) on a valid credential, runs
// the IDENTICAL request loop the local stream would — each subsequent NDJSON line
// folded through session_request, the response written back with its newline frame.
// The session fold is unchanged: remote attach is a transport+auth wrapper, so an
// authed connection serves byte-identically to the local contract.
//
// THE FOLD RUNS ON `allocator`, NOT A PER-LINE SCRATCH: a control command
// (set/spawn/emit/inject_input/reload) commits its forked branch head THROUGH the
// allocator session_request is handed, and that COW chain must SURVIVE across later
// requests on the same connection — so the loop cannot free_all between lines
// without corrupting the branch. This matches the local-stream contract exactly
// (the harness folds session_request on context.allocator and never frees);
// retention is correct because a session is dev-only and holds its chain for its
// lifetime (the same retained-allocation discipline open_debug_session documents).
serve_attach_connection :: proc(s: ^Debug_Session, auth: Attach_Auth, transport: Line_Transport, allocator := context.allocator) {
	reader := new_line_reader(transport, allocator)
	defer delete(reader.pending)

	// (1) The auth handshake — the auth-required gate. The first line MUST be a
	// valid auth envelope presenting the expected credential; anything else refuses
	// the connection (a missing first line, a malformed envelope, or a mismatch all
	// fail closed) before a single command is dispatched.
	if !attach_connection_authed(&reader, auth, allocator) {
		transport_send_line(transport, attach_handshake_response(false, allocator), allocator)
		return
	}
	transport_send_line(transport, attach_handshake_response(true, allocator), allocator)

	// (2) The request loop — the SAME contract the local stream serves. One line in
	// through session_request, one line out; the loop ends when the peer closes.
	for {
		line, have_request := reader_next_line(&reader, allocator)
		if !have_request {
			return
		}
		response := session_request(s, line, allocator)
		if !transport_send_line(transport, response, allocator) {
			return
		}
	}
}

// attach_connection_authed reads the FIRST line off the reader and runs the
// auth-required gate: true only when a complete first line arrives, parses as a
// valid auth envelope, AND presents the expected credential. A missing first line
// (peer closed before authing), a malformed envelope, or a credential mismatch all
// fail closed. Pure over (reader, auth) — the gate decision factored out of the
// connection loop so the no-auth/wrong-auth/right-auth cases test on their own.
attach_connection_authed :: proc(r: ^Line_Reader, auth: Attach_Auth, allocator := context.allocator) -> bool {
	line, have_line := reader_next_line(r, allocator)
	if !have_line {
		return false
	}
	presented, parsed := parse_attach_auth_line(line, allocator)
	if !parsed {
		return false
	}
	return attach_auth_decide(auth, presented)
}

// transport_send_line writes one envelope plus its NDJSON newline frame to the
// transport (the framing session_request omits by contract). The line and the
// newline are sent as one buffer so a response is never split across the frame
// boundary. Returns the transport's send ok.
transport_send_line :: proc(transport: Line_Transport, line: string, allocator := context.allocator) -> bool {
	framed := strings.concatenate({line, "\n"}, allocator)
	return transport.send(transport.userdata, transmute([]byte)framed)
}

// --- The `attach` CLI arg parse (pure; the operator-facing verb surface) ----

// ATTACH_FRESH_TICKS is the recorded-input window an `attach` session WITHOUT a
// replay log pre-folds: a small fixed budget of empty-input ticks so the operator's
// time group (`run{until:N}` / `step`) has a navigable timeline the instant they
// attach, rather than a zero-length recording every `run` would refuse as "tick out
// of range". A dev-only convenience budget (the session is the observe/control
// surface over THIS recording); a replay-log attach overrides it with the log's real
// recorded snapshots. Fixed, not a flag — the operator drives depth over the wire.
ATTACH_FRESH_TICKS :: 64

// ATTACH_EPHEMERAL_PORT is the sentinel `--port 0` request: bind an EPHEMERAL
// loopback port the kernel assigns, rather than a fixed one. It exists to close the
// host-side TOCTOU the MCP supervisor otherwise hits — instead of the supervisor
// probing for a "probably free" port and racing another process to bind it, the
// server lets the kernel pick a guaranteed-free port at bind time and reports it back
// through `--port-file`. 0 is the POSIX wildcard the kernel reads as "any free port".
ATTACH_EPHEMERAL_PORT :: 0

// Attach_Args is the parsed `attach` verb surface: the artifact to open, an OPTIONAL
// recorded replay log to source the session's snapshots+seed from, the loopback port,
// and the two out-of-band FILE handshake paths the MCP supervisor controls.
// `has_replay` distinguishes "attach over the recorded run" (real inputs, the log's
// pinned seed — §28 §3 "sessions are themselves replayable") from a fresh attach over
// an empty-input window (the ATTACH_FRESH_TICKS default).
//
// THE FILE HANDSHAKE (the §28 wire stays on the socket; these two files are the
// out-of-band control channel, NO new structured wire schema):
//   - port == ATTACH_EPHEMERAL_PORT (0) requests a kernel-assigned ephemeral port;
//     `port_file` (when set) is where the server writes the ACTUAL bound port so the
//     supervisor can dial it, closing the host-side ephemeral-port TOCTOU.
//   - `token_file` (when set) is the out-of-band 0600 file the per-session auth token
//     is read from, taking precedence over ATTACH_AUTH_ENV — moving the secret off
//     the inherited environment onto a file the supervisor owns.
Attach_Args :: struct {
	artifact:        string,
	replay_log:      string,
	has_replay:      bool,
	port:            int,
	port_file:       string,
	has_port_file:   bool,
	token_file:      string,
	has_token_file:  bool,
	// The OPTIONAL root-seed override for a BARE open (§25 §60): mirrors `funpack
	// live --seed`. When set it overrides the entrypoint config seed and the engine
	// default for the bare-attach seed resolution; it is IGNORED over a replay log
	// (the log carries its own pinned seed). `has_seed` distinguishes an unset flag
	// (resolve the default) from a passed `--seed 0`.
	seed:            i64,
	has_seed:        bool,
}

// parse_attach_args parses the `attach` verb tail into Attach_Args. The grammar is
//
//   attach <artifact> [recorded.replay] [--port N] [--port-file P] [--token-file T] [--seed N]
//
// `args` is the WHOLE process argv (args[0] = program, args[1] = "attach"); the
// parse walks args[2:]. The first non-flag positional is the artifact (required); a
// second non-flag positional is the optional replay log. `--port N` (or `--port=N`)
// overrides ATTACH_DEFAULT_PORT; `--port 0` requests an EPHEMERAL kernel-assigned
// port (the valid range here is [0, 65535], 0 being the wildcard — a NEGATIVE or
// over-range port is ok=false). `--port-file P` / `--token-file T` (and their `=`
// forms) carry the out-of-band FILE handshake paths; each requires a NON-EMPTY value.
// `--seed N` (or `--seed=N`) overrides the BARE-open root seed (§25 §60), mirroring
// `funpack live --seed`; any base-10 i64 is valid (negatives included). ok=false on
// no artifact, an unknown flag, a malformed `--seed`, or a third positional — the
// caller then prints usage and exits non-zero rather than guessing. Pure (no IO), so
// the verb surface is headless-tested even though the server it feeds is
// FUNPACK_LIVE-gated.
parse_attach_args :: proc(args: []string) -> (parsed: Attach_Args, ok: bool) {
	result := Attach_Args{port = ATTACH_DEFAULT_PORT}
	positionals := 0
	i := 2 // args[0]=program, args[1]="attach"
	for i < len(args) {
		arg := args[i]
		switch {
		case arg == "--port":
			if i + 1 >= len(args) {
				return {}, false
			}
			port, port_ok := strconv.parse_int(args[i + 1])
			if !port_ok || port < 0 || port > 65535 {
				return {}, false
			}
			result.port = port
			i += 2
		case strings.has_prefix(arg, "--port="):
			port, port_ok := strconv.parse_int(arg[len("--port="):])
			if !port_ok || port < 0 || port > 65535 {
				return {}, false
			}
			result.port = port
			i += 1
		case arg == "--port-file":
			if i + 1 >= len(args) || args[i + 1] == "" {
				return {}, false
			}
			result.port_file = args[i + 1]
			result.has_port_file = true
			i += 2
		case strings.has_prefix(arg, "--port-file="):
			value := arg[len("--port-file="):]
			if value == "" {
				return {}, false
			}
			result.port_file = value
			result.has_port_file = true
			i += 1
		case arg == "--token-file":
			if i + 1 >= len(args) || args[i + 1] == "" {
				return {}, false
			}
			result.token_file = args[i + 1]
			result.has_token_file = true
			i += 2
		case strings.has_prefix(arg, "--token-file="):
			value := arg[len("--token-file="):]
			if value == "" {
				return {}, false
			}
			result.token_file = value
			result.has_token_file = true
			i += 1
		case arg == "--seed":
			if i + 1 >= len(args) {
				return {}, false
			}
			seed, seed_ok := strconv.parse_i64(args[i + 1])
			if !seed_ok {
				return {}, false
			}
			result.seed = seed
			result.has_seed = true
			i += 2
		case strings.has_prefix(arg, "--seed="):
			seed, seed_ok := strconv.parse_i64(arg[len("--seed="):])
			if !seed_ok {
				return {}, false
			}
			result.seed = seed
			result.has_seed = true
			i += 1
		case strings.has_prefix(arg, "--"):
			return {}, false // an unknown flag is a usage error, never silently ignored
		case positionals == 0:
			result.artifact = arg
			positionals += 1
			i += 1
		case positionals == 1:
			result.replay_log = arg
			result.has_replay = true
			positionals += 1
			i += 1
		case:
			return {}, false // a third positional is a usage error
		}
	}
	if positionals == 0 {
		return {}, false // the artifact is required
	}
	return result, true
}

// attach_port_file_contents renders the bare port value the server writes to the
// `--port-file` path: the bound port as a DECIMAL ASCII integer with a single
// trailing newline (e.g. "54231\n"). It is the EXACT byte form the MCP supervisor's
// reader parses — kept pure here so the format is pinned by a headless test and the
// supervisor spec matches it byte-for-byte. The newline lets a line-oriented reader
// (or a `read`/`cat`) terminate cleanly; a parser trimming whitespace reads the same
// integer with or without it.
attach_port_file_contents :: proc(port: int, allocator := context.allocator) -> string {
	return fmt.aprintf("%d\n", port, allocator = allocator)
}

// Open_Session_Result discriminates how open_session_for_artifact resolved a
// session-open request. It is the seam's whole point: the helper is the SHARED,
// stdout-clean opener for BOTH attach (the FUNPACK_LIVE TCP arm below) and the
// `funpack mcp` verb, and the two callers report failures differently — the
// attach arm prints its own stderr messages (it owns the artifact-path/port-file
// context), the MCP verb maps each variant to a JSON-RPC error object on a transport
// where stdout belongs to the protocol. Returning a discriminated result instead of
// printing inside the helper keeps it transport-agnostic and stdout-clean (mandatory
// for the MCP caller), and the six open-resolution variants map 1:1 to the §28.2 attach
// stderr messages. Session_Alloc_Failed is the seventh — an internal alloc fault the MCP
// session registry raises when its per-session arena cannot be minted (the attach arm
// holds no per-session arena, so it never produces it). Closed enum (§04 closed-taxonomy
// discipline): every open-failure mode is one named variant, never a bare bool.
Open_Session_Result :: enum {
	Ok, // the session opened — `session` is live, `program` is the heap artifact it borrows
	Artifact_Read_Failed, // the artifact path could not be read off disk
	Artifact_Malformed, // the artifact bytes did not parse (load_program refused)
	Replay_Read_Failed, // a replay log was requested but could not be read off disk
	Replay_Malformed, // the replay log read but did not parse (read_replay refused)
	Replay_Identity_Mismatch, // the §09 §5 identity gate refused: log built/seeded for another artifact
	Session_Alloc_Failed, // the MCP per-session arena could not be allocated — an internal alloc fault, not an on-disk read failure
}

// open_session_for_artifact is the SHARED, stdout-clean session opener — the pure
// (default-build, UN-gated) orchestration both the FUNPACK_LIVE attach arm and the
// `funpack mcp` verb fold over. Every leaf proc it sequences (load_program,
// read_replay_file, identity_from_program*, open_debug_session) lives in the
// SDL-free default build, so the orchestration lives here too (not inside the
// when-gated attach arm) where it compiles and is unit-tested in the `odin test`
// floor. It returns a DISCRIMINATED Open_Session_Result rather than printing, so the
// MCP caller (where stdout is owned by JSON-RPC) maps failures to error objects and
// the attach caller prints its own stderr context — neither writes through the helper.
//
// THE RECORDING the session folds (the §28 §3 time-travel substrate) is sourced two
// ways, mirroring replay.odin's identity-gated path:
//   - WITH a replay log (attach over a recorded run): read_replay_file parses the
//     real per-tick inputs + the pinned seed; the SAME §09 §5 identity check replay
//     gates with (an every-field Replay_Identity compare) refuses a log recorded
//     against a different build or seed BEFORE opening — never fold mismatched
//     inputs. The seed rides through to open_debug_session, so a seeded run (snake)
//     reproduces its RNG-driven setup.
//   - WITHOUT one (a fresh open): a `fresh_ticks`-wide window of empty inputs
//     (default ATTACH_FRESH_TICKS; the render-check passes its own N). A
//     `uses_rng` program resolves a tick-0 ROOT SEED by the SAME §25 §60 precedence
//     `funpack run`/`live` use (resolve_root_seed: the `seed_override`, then the
//     entrypoint config seed, then the fixed engine default), so a BARE attach
//     reproduces the EXACT default-seeded run the SDL window shows — its RNG-driven
//     setup and per-tick draws populate, the session reports seeded=true, and the
//     draw-list/state are the real run's, not frozen-at-defaults. A program that
//     draws no RNG carries no seed (NO_SEED) and is unchanged. The override is the
//     agent-supplyable seed (the MCP session_start `seed` arg / `funpack attach
//     --seed`) for pinning a specific run.
//
// DETERMINISM WARRANTY UNTOUCHED (§28 §2): open_debug_session folds the recording
// through the same production seam every driver uses, and the served session is
// non-perturbing on the canonical chain.
//
// OWNERSHIP: on `Ok` the helper returns the live session and the heap `program` it
// allocated with `new(Program, allocator)` (the session BORROWS program, so the
// caller owns its lifetime); the snapshots/fresh-window are also on `allocator`, so a
// per-session arena allocator frees the whole session in one shot. On any non-`Ok`
// result the helper returns a zero Debug_Session and a `nil` program; any partial
// allocation made before the failure (the new'd program, read bytes) is reclaimed by
// the caller's session-scoped arena — both real callers own one. A future
// context.allocator caller must wrap this in an arena to reclaim a failure-path leak.
open_session_for_artifact :: proc(
	artifact_path: string,
	replay_log: string,
	has_replay: bool,
	allocator := context.allocator,
	seed_override: Maybe(i64) = nil,
	fresh_ticks: int = ATTACH_FRESH_TICKS,
) -> (
	session: Debug_Session,
	program: ^Program,
	result: Open_Session_Result,
) {
	artifact_bytes, read_err := os.read_entire_file_from_path(artifact_path, allocator)
	if read_err != nil {
		return {}, nil, .Artifact_Read_Failed
	}
	program = new(Program, allocator)
	loaded, load_err := load_program(string(artifact_bytes), allocator)
	if load_err != .None {
		return {}, nil, .Artifact_Malformed
	}
	program^ = loaded

	// The recording the session pre-folds. A replay log supplies the real recorded
	// inputs + seed (identity-gated against the loaded build, exactly as replay does);
	// absent one, an empty-input window seedless.
	snapshots: []Input
	run_seed := NO_SEED
	if has_replay {
		log, log_ok, io_ok := read_replay_file(replay_log, allocator)
		if !io_ok {
			return {}, nil, .Replay_Read_Failed
		}
		if !log_ok {
			return {}, nil, .Replay_Malformed
		}
		// The §09 §5 identity gate: refuse a log recorded against a different build or
		// seed BEFORE opening, so the session never folds inputs shaped for another
		// artifact. The seed rides from the log so a seeded run reproduces its setup.
		// The recorded identity is rebuilt from the loaded artifact under the log's
		// OWN seed (identity_from_program_seeded folds the seed into the fingerprint),
		// so a build-or-seed mismatch is a plain Replay_Identity inequality — the same
		// every-field check replay.odin gates with, over the struct's public fields.
		if log.identity.has_seed {
			run_seed = seeded_run(log.identity.seed)
		}
		loaded_identity :=
			log.identity.has_seed ? identity_from_program_seeded(program^, string(artifact_bytes), log.identity.seed) : identity_from_program(program^, string(artifact_bytes))
		if log.identity != loaded_identity {
			return {}, nil, .Replay_Identity_Mismatch
		}
		snapshots = log.snapshots
	} else {
		fresh := make([]Input, fresh_ticks, allocator)
		for i in 0 ..< fresh_ticks {
			fresh[i] = empty()
		}
		snapshots = fresh
		// SEED THE BARE OPEN (§25 §60): a `uses_rng` program resolves a tick-0 root
		// seed by the same precedence `funpack run`/`live` use, so a bare attach
		// reproduces the EXACT default-seeded run the SDL window shows instead of a
		// frozen-at-defaults seedless session. resolve_root_seed picks the agent
		// override first, then the entrypoint config seed, then the fixed engine
		// default. A no-RNG program stays NO_SEED (the seed is meaningless for it).
		if program_uses_rng(program) {
			run_seed = seeded_run(resolve_root_seed(seed_override, program.entrypoint))
		}
	}

	session = open_debug_session(program, snapshots, run_seed, allocator)
	return session, program, .Ok
}

// --- The core:net socket loop (when-gated: the ONLY blocking-IO code here) ---

when #config(FUNPACK_LIVE, false) {

	// run_attach_server is the §28.2 remote-attach listener: handed a pre-resolved auth
	// seam (the caller resolved the token SOURCE — file over env — via
	// attach_auth_resolve, the auth-required floor already enforced there), it binds the
	// LOOPBACK endpoint (attach_listen_endpoint), then accepts connections serially,
	// serving each through serve_attach_connection over a core:net-backed Line_Transport.
	// It is the thin adapter: the auth gate, the framing, and the request loop all live
	// in the pure half above; this loop only wires core:net's recv_tcp/send_tcp/close
	// onto the Line_Transport seam. Serial accept is the right shape for a single-operator
	// dev debug channel — one agent attaches at a time, and the session fold is
	// single-threaded (a control branch is per-session state).
	//
	// THE EPHEMERAL-PORT + PORT-FILE HANDSHAKE (closing the supervisor's host-side
	// TOCTOU): when `port` is ATTACH_EPHEMERAL_PORT the kernel assigns a guaranteed-free
	// port at bind time, and net.bound_endpoint reads the ACTUAL assigned port back off
	// the listening socket — no host-side probe-then-race. When `port_file` is set the
	// resolved port is written there (a bare decimal + newline) BEFORE the accept loop,
	// so a supervisor waiting on the file sees the port the instant the socket is
	// listenable and never races the bind. A fixed `port` still writes the file
	// (harmless — the supervisor reads one code path). Returns a process exit code
	// (non-zero on a listen, port-readback, or port-file-write failure).
	run_attach_server :: proc(
		s: ^Debug_Session,
		auth: Attach_Auth,
		port: int = ATTACH_DEFAULT_PORT,
		port_file: string = "",
		has_port_file: bool = false,
	) -> int {
		endpoint := attach_listen_endpoint(port)
		listener, listen_err := net.listen_tcp(endpoint)
		if listen_err != nil {
			fmt.eprintfln("error: remote attach failed to bind 127.0.0.1:%d (%v)", port, listen_err)
			return 1
		}
		defer net.close(listener)

		// Read the ACTUAL bound port back: for an ephemeral (port 0) bind this is the
		// kernel-assigned port; for a fixed bind it is the same port (a no-op readback
		// that keeps one code path). bound_endpoint is core:net's getsockname wrapper —
		// Odin-first, no custom syscall.
		bound, bound_err := net.bound_endpoint(listener)
		if bound_err != nil {
			fmt.eprintfln("error: remote attach could not read the bound port (%v)", bound_err)
			return 1
		}
		actual_port := bound.port

		// Publish the bound port to the supervisor BEFORE accepting, so a waiter dials
		// the right port the moment the listener is up. The write is the whole file in
		// one call (write_entire_file truncates) — a reader either sees the absent file
		// or the complete contents, never a torn partial.
		if has_port_file {
			contents := attach_port_file_contents(actual_port, context.temp_allocator)
			if write_err := os.write_entire_file_from_string(port_file, contents); write_err != nil {
				fmt.eprintfln("error: remote attach could not write port file %s (%v)", port_file, write_err)
				return 1
			}
		}
		fmt.printfln("remote attach listening on 127.0.0.1:%d (auth required)", actual_port)

		for {
			client, _, accept_err := net.accept_tcp(listener)
			if accept_err != nil {
				// A transient accept failure skips that connection; the listener stays
				// up for the next attach (a dev channel should not die on one bad accept).
				continue
			}
			transport := attach_socket_transport(client)
			serve_attach_connection(s, auth, transport)
			// attach_socket_transport heap-boxes the socket into userdata; free it per
			// connection so the infinite accept loop does not leak one box per client.
			free(transport.userdata)
			net.close(client)
		}
	}

	// run_attach_session is the §28.2 operator-facing `attach` CLI entry — the thin
	// FUNPACK_LIVE arm session_driver.odin foretold ("a thin FUNPACK_LIVE CLI arm can
	// call ... the run_attach_server when-gated thin-adapter shape"). It (1) resolves the
	// auth token SOURCE (a --token-file over the FUNPACK_ATTACH_TOKEN env, via
	// attach_auth_resolve) and refuses up front if no secret is present (the
	// auth-required floor — NO secret ⇒ NO server, enforced BEFORE loading the
	// artifact), (2) opens a Debug_Session over a recording through the SHARED pure
	// open_session_for_artifact helper, mapping its discriminated result to the §28.2
	// stderr messages, and (3) serves the §28 introspection contract on the auth-gated
	// loopback port via run_attach_server, forwarding the ephemeral-port + --port-file
	// handshake. It is when-gated because run_attach_server's core:net loop is.
	//
	// AUTH STAYS CALLER-SIDE: the auth-required floor is resolved + enforced HERE, NOT
	// inside open_session_for_artifact — attach owns a listening TCP port so it must
	// have a secret, while the stdio `funpack mcp` verb (the other helper caller) deletes
	// auth entirely (the host owns the inherited fds). The shared opener is therefore
	// auth-free; auth is the attach arm's own floor, bound to the TCP server it gates.
	// Returns a process exit code (non-zero on a usage, load, replay-identity, or listen
	// failure).
	run_attach_session :: proc(args: []string) -> int {
		parsed, args_ok := parse_attach_args(args)
		if !args_ok {
			fmt.eprintln(
				"usage: funpack attach <artifact-path> [recorded.replay] [--port N] [--port-file P] [--token-file T]",
			)
			return 2
		}

		// Resolve the auth token SOURCE and enforce the auth-required floor BEFORE
		// touching the artifact: a --token-file takes precedence over FUNPACK_ATTACH_TOKEN,
		// and an empty/absent secret from either source refuses to listen (NO secret ⇒ NO
		// server). Fail closed here so the operator sees the auth error without first
		// paying the artifact load.
		auth, auth_ok := attach_auth_resolve(parsed.token_file, parsed.has_token_file)
		if !auth_ok {
			if parsed.has_token_file {
				fmt.eprintfln(
					"error: remote attach requires a non-empty token in %s (the auth-required floor)",
					parsed.token_file,
				)
			} else {
				fmt.eprintfln(
					"error: remote attach requires %s (the auth-required floor) — set a shared token or pass --token-file",
					ATTACH_AUTH_ENV,
				)
			}
			return 1
		}

		// Open the session over the SHARED pure helper, then map its discriminated
		// result to attach's own stderr context (the helper never prints — it returns a
		// transport-agnostic Open_Session_Result the stdio MCP verb reuses unchanged).
		// A passed `--seed` rides through as the bare-open root-seed override (§25 §60);
		// an unset flag leaves it nil so the helper resolves the config/default seed.
		seed_override: Maybe(i64)
		if parsed.has_seed {
			seed_override = parsed.seed
		}
		session, _, result := open_session_for_artifact(
			parsed.artifact,
			parsed.replay_log,
			parsed.has_replay,
			seed_override = seed_override,
		)
		switch result {
		case .Ok:
		// fall through to serve below
		case .Artifact_Read_Failed:
			fmt.eprintfln("error: cannot read artifact %s", parsed.artifact)
			return 1
		case .Artifact_Malformed:
			fmt.eprintfln("error: malformed artifact %s", parsed.artifact)
			return 1
		case .Replay_Read_Failed:
			fmt.eprintfln("error: cannot read replay log %s", parsed.replay_log)
			return 1
		case .Replay_Malformed:
			fmt.eprintfln("error: malformed replay log %s", parsed.replay_log)
			return 1
		case .Replay_Identity_Mismatch:
			fmt.eprintfln(
				"error: replay log %s does not match artifact %s (different build or seed)",
				parsed.replay_log,
				parsed.artifact,
			)
			return 1
		case .Session_Alloc_Failed:
			// open_session_for_artifact never mints a per-session arena, so it never
			// returns this; the arm exists only to keep the closed switch exhaustive.
			fmt.eprintfln("error: could not allocate the session for artifact %s", parsed.artifact)
			return 1
		}

		return run_attach_server(&session, auth, parsed.port, parsed.port_file, parsed.has_port_file)
	}

	// attach_socket_transport builds the Line_Transport over a connected core:net
	// TCP_Socket — the adapter pairing recv_tcp/send_tcp onto the seam the pure
	// connection loop drives. The socket handle rides `userdata` as a heap-boxed
	// TCP_Socket so the proc fields recover it; recv returns 0 on a graceful close
	// (recv_tcp's contract) which the line reader reads as EOF. send_tcp already
	// retries internally until the whole buffer is written, so send only has to
	// surface a short write (written < len) as the real fault it is.
	attach_socket_transport :: proc(socket: net.TCP_Socket) -> Line_Transport {
		boxed := new(net.TCP_Socket)
		boxed^ = socket
		return Line_Transport {
			userdata = boxed,
			recv = proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool) {
				socket := (^net.TCP_Socket)(userdata)^
				read, recv_err := net.recv_tcp(socket, buf)
				if recv_err != nil {
					return 0, false
				}
				return read, true
			},
			send = proc(userdata: rawptr, buf: []byte) -> (ok: bool) {
				socket := (^net.TCP_Socket)(userdata)^
				written, send_err := net.send_tcp(socket, buf)
				if send_err != nil {
					return false
				}
				return written == len(buf)
			},
		}
	}
} else {
	// Headless/default build: no SDL, no introspection server. run_attach_session
	// is still an ALWAYS-PRESENT symbol so the single-binary entry package
	// (cmd/funpack) links its `attach` verb against it in BOTH build modes — the
	// real §28 remote-attach server above when built with -define:FUNPACK_LIVE=true,
	// this refuse-stub otherwise.
	run_attach_session :: proc(args: []string) -> int {
		_ = args
		fmt.eprintln(
			"funpack: this build has no attach runtime (compiled without FUNPACK_LIVE); rebuild with -define:FUNPACK_LIVE=true",
		)
		return 2
	}
}
