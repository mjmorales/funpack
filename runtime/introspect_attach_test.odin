// §28.2 remote-attach acceptance: the introspection contract served on an
// auth-gated transport. Remote attach is a TRANSPORT + AUTH wrapper around the
// unchanged session_request fold, so this suite drives serve_attach_connection over
// an IN-MEMORY Line_Transport (the same seam the when-gated core:net socket loop
// fills) and proves the four contract floors WITHOUT a real socket:
//
//   - auth is REQUIRED (§28.2): a connection with NO auth line and a connection with
//     a WRONG token are both refused — the handshake answers ok:false and NO command
//     response follows (the gate fires before any dispatch).
//   - an AUTHED connection serves the IDENTICAL contract: an observe round-trip over
//     the transport returns the SAME response bytes the local session_request fold
//     returns (the wrapper changes transport, not the contract).
//   - the bind is LOOPBACK-only (attach_listen_endpoint pins 127.0.0.1).
//   - the auth-required floor is enforced BY CONSTRUCTION: an empty token cannot
//     build an auth seam (so a server cannot be gated by no secret).
package funpack_runtime

import "core:net"
import "core:strings"
import "core:testing"

// ATTACH_FIXTURE is the same minimal one-behavior artifact the observe suite folds
// (a Hero with a Fixed pos advancing 1.0/tick) — the round-trip asserts the attach
// transport returns byte-identical observe responses, so it needs the identical
// session the local-fold envelope tests pin against.
@(private = "file")
ATTACH_FIXTURE :: "funpack-artifact 18\n" +
	"[meta 2]\n" +
	"project introspect\n" +
	"version L5:0.1.0\n" +
	"[data 2]\n" +
	"data Stats 2 false\n" +
	"field hp Int -\n" +
	"field mana Int -\n" +
	"data Coord 1 false\n" +
	"field v Int -\n" +
	"[things 1]\n" +
	"thing Hero false 0 4\n" +
	"field pos Fixed =0\n" +
	"field stats Stats =Stats(hp=10,mana=4)\n" +
	"field home Coord =Coord(v=5)\n" +
	"field score Int =0\n" +
	"[behaviors 1]\n" +
	"behavior advance on:Hero stage:control contract:Update 0 1 1 1\n" +
	"param self Hero\n" +
	"emit Hero\n" +
	"node return 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield pos 1\n" +
	"node binary add 2\n" +
	"node field pos 1\n" +
	"node name self 0\n" +
	"node fixed 4294967296 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:advance\n" +
	"[setup 1]\n" +
	"spawn Hero 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Intro tick_hz:60 logical:160x120 bindings:bindings\n"

// attach_fixture_session loads the fixture and opens a session over `ticks` empty
// input snapshots — the shared opener the attach round-trip folds from (the twin of
// introspect_test.odin's fixture_session).
@(private = "file")
attach_fixture_session :: proc(t: ^testing.T, ticks: int, allocator := context.allocator) -> (program: ^Program, session: Debug_Session) {
	program = new(Program, allocator)
	loaded, err := load_program(ATTACH_FIXTURE, allocator)
	testing.expect(t, err == .None, "fixture artifact must load")
	program^ = loaded
	inputs := make([]Input, ticks, allocator)
	for i in 0 ..< ticks {
		inputs[i] = empty()
	}
	session = open_debug_session(program, inputs, NO_SEED, allocator)
	return program, session
}

// Mem_Conn is an in-memory Line_Transport backing for the headless attach tests: the
// client's bytes (`incoming`, the NDJSON lines the client "sends") are drained by
// recv, and the server's bytes (`outgoing`) are accumulated by send. It stands in
// for a connected socket so serve_attach_connection runs end-to-end with no network,
// exactly as the when-gated core:net adapter fills the same seam at runtime.
@(private = "file")
Mem_Conn :: struct {
	incoming: []byte,
	read_pos: int,
	outgoing: strings.Builder,
}

// mem_transport builds a Line_Transport over a Mem_Conn: recv hands out the client
// bytes in chunks (0 once drained — the graceful-close signal the line reader reads
// as EOF), send appends to the outgoing builder.
@(private = "file")
mem_transport :: proc(conn: ^Mem_Conn) -> Line_Transport {
	return Line_Transport {
		userdata = conn,
		recv = proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool) {
			conn := (^Mem_Conn)(userdata)
			if conn.read_pos >= len(conn.incoming) {
				return 0, true // drained → graceful close (recv_tcp returns 0,nil too)
			}
			n = copy(buf, conn.incoming[conn.read_pos:])
			conn.read_pos += n
			return n, true
		},
		send = proc(userdata: rawptr, buf: []byte) -> (ok: bool) {
			conn := (^Mem_Conn)(userdata)
			strings.write_bytes(&conn.outgoing, buf)
			return true
		},
	}
}

// mem_conn builds a Mem_Conn whose incoming stream is the given NDJSON lines joined
// with newline frames (the bytes a client would write over the wire).
@(private = "file")
mem_conn :: proc(lines: []string, allocator := context.allocator) -> Mem_Conn {
	b := strings.builder_make(allocator)
	for line in lines {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return Mem_Conn{incoming = transmute([]byte)strings.to_string(b), outgoing = strings.builder_make(allocator)}
}

// test_attach_loopback_bind pins the §28.2 bind decision: remote attach ALWAYS binds
// the loopback interface (127.0.0.1), never a public address. Pure over the endpoint,
// so the loopback-only choice is proven without opening a socket.
@(test)
test_attach_loopback_bind :: proc(t: ^testing.T) {
	ep := attach_listen_endpoint(7341)
	addr, is_ip4 := ep.address.(net.IP4_Address)
	testing.expect(t, is_ip4, "attach must bind an IPv4 loopback address")
	testing.expect(t, addr == net.IP4_Loopback, "attach must bind 127.0.0.1, never a public address")
	testing.expect_value(t, ep.port, 7341)
}

// test_attach_auth_required_floor pins the auth-required floor enforced BY
// CONSTRUCTION: an empty token cannot build an auth seam (a server cannot be gated by
// no secret), while a non-empty token builds one that ACCEPTS the matching credential
// and REJECTS a mismatched one. §28.2: auth is required, never optional.
@(test)
test_attach_auth_required_floor :: proc(t: ^testing.T) {
	_, empty_ok := attach_auth_from_token("", context.temp_allocator)
	testing.expect(t, !empty_ok, "an empty token must NOT build an auth seam — the auth-required floor")

	auth, ok := attach_auth_from_token("s3cret", context.temp_allocator)
	testing.expect(t, ok, "a non-empty token must build an auth seam")
	testing.expect(t, attach_auth_decide(auth, "s3cret"), "the matching credential is accepted")
	testing.expect(t, !attach_auth_decide(auth, "wrong"), "a mismatched credential is rejected")
	testing.expect(t, !attach_auth_decide(auth, ""), "an empty presented credential is rejected")
}

// test_attach_no_auth_refused pins that a connection presenting NO auth line (the
// peer closes before authing) is refused: the handshake answers ok:false and NO
// command response follows. The gate fires before any dispatch.
@(test)
test_attach_no_auth_refused :: proc(t: ^testing.T) {
	_, session := attach_fixture_session(t, 2)
	s := session
	auth, _ := attach_auth_from_token("s3cret", context.allocator)

	conn := mem_conn({}) // no lines at all → no auth presented
	transport := mem_transport(&conn)
	serve_attach_connection(&s, auth, transport)

	out := strings.to_string(conn.outgoing)
	testing.expect(t, strings.contains(out, `"handshake":true`), "the refusal is the handshake envelope")
	testing.expect(t, strings.contains(out, `"ok":false`), "no auth line must be refused")
	testing.expect(t, !strings.contains(out, `"cmd":`), "a refused connection serves NO command response")
}

// test_attach_wrong_auth_refused pins that a connection presenting the WRONG token —
// even followed by a valid observe request — is refused at the gate: ok:false
// handshake, and the trailing request is NEVER dispatched (no command response).
@(test)
test_attach_wrong_auth_refused :: proc(t: ^testing.T) {
	_, session := attach_fixture_session(t, 2)
	s := session
	auth, _ := attach_auth_from_token("s3cret", context.allocator)

	conn := mem_conn({`{"auth":"WRONG"}`, `{"id":1,"cmd":"pipeline"}`})
	transport := mem_transport(&conn)
	serve_attach_connection(&s, auth, transport)

	out := strings.to_string(conn.outgoing)
	testing.expect(t, strings.contains(out, `"handshake":true`), "the refusal is the handshake envelope")
	testing.expect(t, strings.contains(out, `"ok":false`), "a wrong token must be refused")
	testing.expect(t, !strings.contains(out, `"cmd":"pipeline"`), "a refused connection never dispatches the trailing request")
}

// test_attach_authed_serves_identical_contract is the STORY ACCEPTANCE: an AUTHED
// connection serves the IDENTICAL contract. After a valid handshake, an observe
// round-trip (pipeline, then trace) over the in-memory transport returns response
// bytes BYTE-IDENTICAL to the local session_request fold — proving remote attach is a
// transport+auth wrapper that changes the transport, never the contract. The
// handshake success line precedes the command responses, and each response carries
// its NDJSON newline frame.
@(test)
test_attach_authed_serves_identical_contract :: proc(t: ^testing.T) {
	_, session := attach_fixture_session(t, 3)
	s := session
	auth, _ := attach_auth_from_token("s3cret", context.allocator)

	// The reference: the SAME two observe requests folded through the local stream
	// contract (session_request) against a fresh session over the identical fixture.
	_, ref_session := attach_fixture_session(t, 3)
	ref := ref_session
	ref_pipeline := session_request(&ref, `{"id":1,"cmd":"pipeline"}`)
	ref_trace := session_request(&ref, `{"id":2,"cmd":"trace","args":{"tick":1,"behavior":"advance"}}`)

	// The attach transport: auth, then the same two requests.
	conn := mem_conn(
		{
			`{"v":1,"auth":"s3cret"}`,
			`{"id":1,"cmd":"pipeline"}`,
			`{"id":2,"cmd":"trace","args":{"tick":1,"behavior":"advance"}}`,
		},
	)
	transport := mem_transport(&conn)
	serve_attach_connection(&s, auth, transport)

	// The server stream is: handshake-success line, pipeline response, trace response
	// — each newline-framed. Split and compare the command responses byte-for-byte
	// against the local fold.
	lines := strings.split(strings.to_string(conn.outgoing), "\n", context.allocator)
	testing.expect(t, len(lines) >= 3, "the authed stream is handshake + 2 responses")
	testing.expect(t, strings.contains(lines[0], `"handshake":true`), "the first line is the handshake success")
	testing.expect(t, strings.contains(lines[0], `"ok":true`), "the handshake succeeds for the right token")
	testing.expect_value(t, lines[1], ref_pipeline)
	testing.expect_value(t, lines[2], ref_trace)
}

// test_attach_control_state_persists_across_requests pins the allocator-correctness
// floor: a control command's forked branch MUST survive across later requests on the
// SAME attached connection. Over one connection the client sends branch → set (forces
// a branch column) → checkout → diff; the diff reads the branch divergence the set
// committed, proving the branch's COW chain — committed through the allocator
// session_request is handed — is NOT freed between lines. (A per-line free_all would
// corrupt the branch head and this diff would fail closed; this test locks that out.)
// It uses the golden pong session because the divergence forces a Ball column the
// fixture's lone Hero lacks.
@(test)
test_attach_control_state_persists_across_requests :: proc(t: ^testing.T) {
	program := new(Program, context.allocator)
	loaded, err := load_program(GOLDEN_ARTIFACT, context.allocator)
	testing.expect(t, err == .None, "golden pong artifact must load")
	program^ = loaded
	inputs := make([]Input, 3, context.allocator)
	for i in 0 ..< 3 {
		inputs[i] = empty()
	}
	s := open_debug_session(program, inputs, NO_SEED, context.allocator)
	auth, _ := attach_auth_from_token("s3cret", context.allocator)

	conn := mem_conn(
		{
			`{"v":1,"auth":"s3cret"}`,
			`{"id":1,"cmd":"branch"}`,
			`{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=0,y=0)"}}`,
			`{"id":3,"cmd":"checkout"}`,
			`{"id":4,"cmd":"diff","args":{"from":2,"to":3}}`,
		},
	)
	transport := mem_transport(&conn)
	serve_attach_connection(&s, auth, transport)

	out := strings.to_string(conn.outgoing)
	// The diff (the last response) reads the branch tip the set forced — the branch
	// outlived the three requests since it. The branch was checked out, so the no-arg
	// diff resolves the branch lineage and reports the forced Ball/pos column.
	testing.expect(t, strings.contains(out, `"thing":"Ball"`), "the diff over the attach connection reads the branch's forced Ball")
	testing.expect(t, strings.contains(out, `"field":"pos"`), "the forced pos column survives across requests — the branch was not freed")
	testing.expect(t, strings.contains(out, `"warranted":false`), "the forked control lineage is non-warranted")
}

// test_attach_handshake_carries_version pins the handshake envelope is versioned
// exact-match like every §28 envelope (§28 §2) and a foreign-version auth line is
// refused — the §29 index-contract discipline applied to the transport pre-amble.
@(test)
test_attach_handshake_carries_version :: proc(t: ^testing.T) {
	_, parsed_v1 := parse_attach_auth_line(`{"v":1,"auth":"t"}`, context.temp_allocator)
	testing.expect(t, parsed_v1, "a current-version auth line parses")

	_, parsed_v2 := parse_attach_auth_line(`{"v":2,"auth":"t"}`, context.temp_allocator)
	testing.expect(t, !parsed_v2, "a foreign-version auth line is refused (exact-match)")

	_, parsed_no_auth := parse_attach_auth_line(`{"v":1}`, context.temp_allocator)
	testing.expect(t, !parsed_no_auth, "an auth line with no credential is refused")

	ok_line := attach_handshake_response(true, context.temp_allocator)
	testing.expect(t, strings.contains(ok_line, `"v":1`), "the handshake response stamps the protocol version")
}
