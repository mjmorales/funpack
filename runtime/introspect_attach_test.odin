package funpack_runtime

import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

@(private = "file")
ATTACH_FIXTURE :: "funpack-artifact 19\n" +
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

@(private = "file")
Mem_Conn :: struct {
	incoming: []byte,
	read_pos: int,
	outgoing: strings.Builder,
}

@(private = "file")
mem_transport :: proc(conn: ^Mem_Conn) -> Line_Transport {
	return Line_Transport {
		userdata = conn,
		recv = proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool) {
			conn := (^Mem_Conn)(userdata)
			if conn.read_pos >= len(conn.incoming) {
				return 0, true
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

@(private = "file")
mem_conn :: proc(lines: []string, allocator := context.allocator) -> Mem_Conn {
	b := strings.builder_make(allocator)
	for line in lines {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return Mem_Conn{incoming = transmute([]byte)strings.to_string(b), outgoing = strings.builder_make(allocator)}
}

@(test)
test_attach_loopback_bind :: proc(t: ^testing.T) {
	ep := attach_listen_endpoint(7341)
	addr, is_ip4 := ep.address.(net.IP4_Address)
	testing.expect(t, is_ip4, "attach must bind an IPv4 loopback address")
	testing.expect(t, addr == net.IP4_Loopback, "attach must bind 127.0.0.1, never a public address")
	testing.expect_value(t, ep.port, 7341)
}

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

@(test)
test_attach_no_auth_refused :: proc(t: ^testing.T) {
	_, session := attach_fixture_session(t, 2)
	s := session
	auth, _ := attach_auth_from_token("s3cret", context.allocator)

	conn := mem_conn({})
	transport := mem_transport(&conn)
	serve_attach_connection(&s, auth, transport)

	out := strings.to_string(conn.outgoing)
	testing.expect(t, strings.contains(out, `"handshake":true`), "the refusal is the handshake envelope")
	testing.expect(t, strings.contains(out, `"ok":false`), "no auth line must be refused")
	testing.expect(t, !strings.contains(out, `"cmd":`), "a refused connection serves NO command response")
}

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

@(test)
test_attach_authed_serves_identical_contract :: proc(t: ^testing.T) {
	_, session := attach_fixture_session(t, 3)
	s := session
	auth, _ := attach_auth_from_token("s3cret", context.allocator)

	_, ref_session := attach_fixture_session(t, 3)
	ref := ref_session
	ref_pipeline := session_request(&ref, `{"id":1,"cmd":"pipeline"}`)
	ref_trace := session_request(&ref, `{"id":2,"cmd":"trace","args":{"tick":1,"behavior":"advance"}}`)

	conn := mem_conn(
		{
			`{"v":1,"auth":"s3cret"}`,
			`{"id":1,"cmd":"pipeline"}`,
			`{"id":2,"cmd":"trace","args":{"tick":1,"behavior":"advance"}}`,
		},
	)
	transport := mem_transport(&conn)
	serve_attach_connection(&s, auth, transport)

	lines := strings.split(strings.to_string(conn.outgoing), "\n", context.allocator)
	testing.expect(t, len(lines) >= 3, "the authed stream is handshake + 2 responses")
	testing.expect(t, strings.contains(lines[0], `"handshake":true`), "the first line is the handshake success")
	testing.expect(t, strings.contains(lines[0], `"ok":true`), "the handshake succeeds for the right token")
	testing.expect_value(t, lines[1], ref_pipeline)
	testing.expect_value(t, lines[2], ref_trace)
}

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
	testing.expect(t, strings.contains(out, `"thing":"Ball"`), "the diff over the attach connection reads the branch's forced Ball")
	testing.expect(t, strings.contains(out, `"field":"pos"`), "the forced pos column survives across requests — the branch was not freed")
	testing.expect(t, strings.contains(out, `"warranted":false`), "the forked control lineage is non-warranted")
}

@(private = "file")
attach_write_fixture :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_dir(context.temp_allocator)
	testing.expect(t, dir_err == nil, "a temp dir is available")
	path, join_err := filepath.join({dir, name}, context.temp_allocator)
	testing.expect(t, join_err == nil, "the fixture path joins")
	testing.expect(t, os.write_entire_file_from_string(path, ATTACH_FIXTURE) == nil, "the fixture artifact writes")
	return path
}

@(test)
test_open_session_for_artifact_fresh :: proc(t: ^testing.T) {
	path := attach_write_fixture(t, "funpack-open-session-fresh.artifact")
	defer os.remove(path)

	session, program, result := open_session_for_artifact(path, "", false, context.allocator)
	testing.expect_value(t, result, Open_Session_Result.Ok)
	testing.expect(t, program != nil, "an Ok open returns the heap program the session borrows")
	s := session
	testing.expect_value(t, len(s.snapshots), ATTACH_FRESH_TICKS)
	testing.expect(t, !s.seed.has_seed, "a fresh open is seedless (NO_SEED)")

	_, ref_session := attach_fixture_session(t, ATTACH_FRESH_TICKS)
	ref := ref_session
	helper_resp := session_request(&s, `{"id":1,"cmd":"pipeline"}`)
	ref_resp := session_request(&ref, `{"id":1,"cmd":"pipeline"}`)
	testing.expect_value(t, helper_resp, ref_resp)
}

@(test)
test_open_session_for_artifact_replay_identity_mismatch :: proc(t: ^testing.T) {
	path := attach_write_fixture(t, "funpack-open-session-mismatch.artifact")
	defer os.remove(path)

	program := new(Program, context.temp_allocator)
	loaded, load_err := load_program(ATTACH_FIXTURE, context.temp_allocator)
	testing.expect(t, load_err == .None, "the fixture must load to derive its identity")
	program^ = loaded
	identity := identity_from_program(program^, ATTACH_FIXTURE)
	identity.content_hash ~= 0xDEAD_BEEF

	writer := open_replay_writer(identity, context.temp_allocator)
	defer delete_replay_writer(&writer)
	record_tick(&writer, empty(), context.temp_allocator)
	log_bytes := finish_replay(&writer, context.temp_allocator)

	replay_path, join_err := filepath.join({os.temp_dir(context.temp_allocator) or_else "", "funpack-open-session-mismatch.replay"}, context.temp_allocator)
	testing.expect(t, join_err == nil, "the replay path joins")
	testing.expect(t, write_replay_file(replay_path, log_bytes), "the mismatched replay log writes")
	defer os.remove(replay_path)

	session, prog, result := open_session_for_artifact(path, replay_path, true, context.allocator)
	_ = session
	testing.expect_value(t, result, Open_Session_Result.Replay_Identity_Mismatch)
	testing.expect(t, prog == nil, "an identity-mismatch open returns a nil program (refused before opening)")
}

@(test)
test_open_session_for_artifact_read_and_malformed :: proc(t: ^testing.T) {
	_, prog_missing, missing := open_session_for_artifact("/nonexistent/funpack/no-such.artifact", "", false, context.allocator)
	testing.expect_value(t, missing, Open_Session_Result.Artifact_Read_Failed)
	testing.expect(t, prog_missing == nil, "a read failure returns a nil program")

	dir, dir_err := os.temp_dir(context.temp_allocator)
	testing.expect(t, dir_err == nil, "a temp dir is available")
	garbage_path, join_err := filepath.join({dir, "funpack-open-session-garbage.artifact"}, context.temp_allocator)
	testing.expect(t, join_err == nil, "the garbage path joins")
	testing.expect(t, os.write_entire_file_from_string(garbage_path, "not a funpack artifact\n") == nil, "the garbage file writes")
	defer os.remove(garbage_path)

	_, prog_bad, malformed := open_session_for_artifact(garbage_path, "", false, context.allocator)
	testing.expect_value(t, malformed, Open_Session_Result.Artifact_Malformed)
	testing.expect(t, prog_bad == nil, "a malformed artifact returns a nil program")
}

@(test)
test_attach_args_artifact_only :: proc(t: ^testing.T) {
	parsed, ok := parse_attach_args({"funpack", "attach", "game.artifact"})
	testing.expect(t, ok, "attach with an artifact must parse")
	testing.expect_value(t, parsed.artifact, "game.artifact")
	testing.expect(t, !parsed.has_replay, "no second positional means no replay log")
	testing.expect_value(t, parsed.port, ATTACH_DEFAULT_PORT)
}

@(test)
test_attach_args_replay_and_port :: proc(t: ^testing.T) {
	parsed, ok := parse_attach_args({"funpack", "attach", "game.artifact", "run.replay", "--port", "9000"})
	testing.expect(t, ok, "attach with a replay log and a port must parse")
	testing.expect_value(t, parsed.artifact, "game.artifact")
	testing.expect(t, parsed.has_replay, "the second positional is the replay log")
	testing.expect_value(t, parsed.replay_log, "run.replay")
	testing.expect_value(t, parsed.port, 9000)

	eq, eq_ok := parse_attach_args({"funpack", "attach", "game.artifact", "--port=9000"})
	testing.expect(t, eq_ok, "the --port=N form must parse")
	testing.expect_value(t, eq.port, 9000)
	testing.expect(t, !eq.has_replay, "a flag is not a positional — no replay log here")
}

@(test)
test_attach_args_seed :: proc(t: ^testing.T) {
	spaced, spaced_ok := parse_attach_args({"funpack", "attach", "game.artifact", "--seed", "1337"})
	testing.expect(t, spaced_ok, "attach with --seed N must parse")
	testing.expect(t, spaced.has_seed, "--seed sets has_seed")
	testing.expect_value(t, spaced.seed, i64(1337))

	eq, eq_ok := parse_attach_args({"funpack", "attach", "game.artifact", "--seed=42"})
	testing.expect(t, eq_ok, "the --seed=N form must parse")
	testing.expect_value(t, eq.seed, i64(42))

	zero, zero_ok := parse_attach_args({"funpack", "attach", "game.artifact", "--seed", "0"})
	testing.expect(t, zero_ok, "--seed 0 is a real value, not a default")
	testing.expect(t, zero.has_seed, "--seed 0 sets has_seed")
	testing.expect_value(t, zero.seed, i64(0))

	neg, neg_ok := parse_attach_args({"funpack", "attach", "game.artifact", "--seed=-5"})
	testing.expect(t, neg_ok, "a negative seed parses (any base-10 i64)")
	testing.expect_value(t, neg.seed, i64(-5))

	unset, unset_ok := parse_attach_args({"funpack", "attach", "game.artifact"})
	testing.expect(t, unset_ok, "no --seed must parse")
	testing.expect(t, !unset.has_seed, "an unset --seed leaves has_seed false (resolve the default)")
}

@(test)
test_attach_args_refusals :: proc(t: ^testing.T) {
	_, no_artifact := parse_attach_args({"funpack", "attach"})
	testing.expect(t, !no_artifact, "attach with no artifact is a usage error")

	_, unknown_flag := parse_attach_args({"funpack", "attach", "game.artifact", "--bogus"})
	testing.expect(t, !unknown_flag, "an unknown flag is a usage error, never silently ignored")

	_, bad_port := parse_attach_args({"funpack", "attach", "game.artifact", "--port", "nope"})
	testing.expect(t, !bad_port, "a non-numeric port is a usage error")

	_, oob_port := parse_attach_args({"funpack", "attach", "game.artifact", "--port", "70000"})
	testing.expect(t, !oob_port, "an out-of-range port is a usage error")

	_, dangling_port := parse_attach_args({"funpack", "attach", "game.artifact", "--port"})
	testing.expect(t, !dangling_port, "--port with no value is a usage error")

	_, bad_seed := parse_attach_args({"funpack", "attach", "game.artifact", "--seed", "nope"})
	testing.expect(t, !bad_seed, "a non-numeric seed is a usage error")

	_, dangling_seed := parse_attach_args({"funpack", "attach", "game.artifact", "--seed"})
	testing.expect(t, !dangling_seed, "--seed with no value is a usage error")

	_, third_positional := parse_attach_args({"funpack", "attach", "a", "b", "c"})
	testing.expect(t, !third_positional, "a third positional is a usage error")
}

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

@(test)
test_attach_ephemeral_endpoint :: proc(t: ^testing.T) {
	ep := attach_listen_endpoint(ATTACH_EPHEMERAL_PORT)
	addr, is_ip4 := ep.address.(net.IP4_Address)
	testing.expect(t, is_ip4, "an ephemeral attach still binds an IPv4 loopback address")
	testing.expect(t, addr == net.IP4_Loopback, "ephemeral attach binds 127.0.0.1, never a public address")
	testing.expect_value(t, ep.port, 0)
	testing.expect_value(t, ATTACH_EPHEMERAL_PORT, 0)
}

@(test)
test_attach_port_file_format :: proc(t: ^testing.T) {
	contents := attach_port_file_contents(54231, context.temp_allocator)
	testing.expect_value(t, contents, "54231\n")

	port, ok := strconv.parse_int(strings.trim_space(contents))
	testing.expect(t, ok, "the port-file contents parse as a decimal integer")
	testing.expect_value(t, port, 54231)
}

@(test)
test_attach_args_file_handshake :: proc(t: ^testing.T) {
	parsed, ok := parse_attach_args(
		{"funpack", "attach", "game.artifact", "--port", "0", "--port-file", "/tmp/p", "--token-file", "/tmp/t"},
	)
	testing.expect(t, ok, "attach with --port 0 and the file flags must parse")
	testing.expect_value(t, parsed.port, ATTACH_EPHEMERAL_PORT)
	testing.expect(t, parsed.has_port_file, "--port-file binds has_port_file")
	testing.expect_value(t, parsed.port_file, "/tmp/p")
	testing.expect(t, parsed.has_token_file, "--token-file binds has_token_file")
	testing.expect_value(t, parsed.token_file, "/tmp/t")

	eq, eq_ok := parse_attach_args(
		{"funpack", "attach", "game.artifact", "--port=0", "--port-file=/tmp/p2", "--token-file=/tmp/t2"},
	)
	testing.expect(t, eq_ok, "the =-joined file flags must parse")
	testing.expect_value(t, eq.port, ATTACH_EPHEMERAL_PORT)
	testing.expect_value(t, eq.port_file, "/tmp/p2")
	testing.expect_value(t, eq.token_file, "/tmp/t2")

	_, blank_port_file := parse_attach_args({"funpack", "attach", "game.artifact", "--port-file", ""})
	testing.expect(t, !blank_port_file, "an empty --port-file value is a usage error")
	_, blank_token_file := parse_attach_args({"funpack", "attach", "game.artifact", "--token-file="})
	testing.expect(t, !blank_token_file, "an empty --token-file= value is a usage error")

	_, neg_port := parse_attach_args({"funpack", "attach", "game.artifact", "--port", "-1"})
	testing.expect(t, !neg_port, "a negative port is a usage error")
}

@(test)
test_attach_token_source_precedence :: proc(t: ^testing.T) {
	saved, had_saved := os.lookup_env(ATTACH_AUTH_ENV, context.temp_allocator)
	defer {
		if had_saved {
			os.set_env(ATTACH_AUTH_ENV, saved)
		} else {
			os.unset_env(ATTACH_AUTH_ENV)
		}
	}

	dir, dir_err := os.temp_dir(context.temp_allocator)
	testing.expect(t, dir_err == nil, "a temp dir is available")
	token_path, join_err := filepath.join({dir, "funpack-attach-token"}, context.temp_allocator)
	testing.expect(t, join_err == nil, "the token-file path joins")
	defer os.remove(token_path)

	testing.expect(t, os.set_env(ATTACH_AUTH_ENV, "env-token") == nil, "the env token sets")
	testing.expect(
		t,
		os.write_entire_file_from_string(token_path, "file-token\n") == nil,
		"the token file writes",
	)
	auth, ok := attach_auth_resolve(token_path, true)
	testing.expect(t, ok, "a non-empty token file resolves an auth seam")
	testing.expect(t, attach_auth_decide(auth, "file-token"), "the FILE token wins over the env token")
	testing.expect(t, !attach_auth_decide(auth, "env-token"), "the env token is NOT the resolved secret when a file is given")

	testing.expect(t, os.write_entire_file_from_string(token_path, "   \n") == nil, "the empty token file writes")
	_, empty_file_ok := attach_auth_resolve(token_path, true)
	testing.expect(t, !empty_file_ok, "an empty token file refuses — the auth floor, no env fallback")

	_, no_file_ok := attach_auth_resolve("", false)
	testing.expect(t, no_file_ok, "with no --token-file the env token resolves")

	os.unset_env(ATTACH_AUTH_ENV)
	_, empty_env_ok := attach_auth_resolve("", false)
	testing.expect(t, !empty_env_ok, "an absent env token with no file refuses — the auth floor")
}
