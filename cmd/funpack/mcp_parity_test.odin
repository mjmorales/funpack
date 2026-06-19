// SERVER-LEVEL PARITY GATE — the two cross-cutting contracts that no single
// per-family test covers, expressed as living spec over the REAL framed transport
// (serve_mcp_connection + the production mcp_jsonrpc_handler), not an arm shortcut:
//
//   1. tools/list advertises the WHOLE 46-tool surface — the §28 session tools AND
//      the server-native (oneshot / docs-health / session-lifecycle) tools — each as
//      a named entry carrying a well-formed object inputSchema. Each family pins its
//      own list membership in its own test; this pins the UNION in ONE place over the
//      wire so a dropped or unadvertised family fails loudly. (mcp_server_test.odin's
//      projection test asserts the COUNT and one tool; this asserts the full NAMED set.)
//   2. A full protocol ROUND-TRIP — initialize → tools/list → a tools/call for at
//      least one representative tool of EACH of the six dispatch families — driven as
//      a single framed exchange through one registry-backed handler, so the session a
//      session_start mints persists across the later session-scoped calls (the exact
//      lifecycle the host drives over stdio). Each tools/call returns a JSON-RPC
//      result (never a protocol error object), proving every family is REACHABLE end
//      to end through the chain, not just at its own arm seam.
//
// These compose with — never duplicate — the existing pins: the handshake/capabilities/
// notification/stdout-discipline contracts live in mcp_server_test.odin; each family's
// arg/result shapes and refusal envelopes live in its mcp_tools_<fam>_test.odin; the
// TOOL_SPECS↔contract staleness gate lives in funpack/api_contract_tool_spec_test.odin.
// This file pins ONLY the two server-level invariants that span all six families.
//
// DEFINE-FREE FLOOR: driven over the in-memory transport in the default `odin test .`
// build (no FUNPACK_LIVE, no SDL). A live session opens over an inlined SDL-free
// fixture, so the round-trip's session-scoped leg runs in the same deterministic floor.
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// PARITY_FIXTURE is a minimal one-behavior artifact (a Hero whose Fixed `pos` advances
// 1.0/tick) — the same shape the family tests use, inlined per the self-contained-test
// standard so this file stands alone. A session opens cleanly over it, giving the
// round-trip's observe / control / screenshot legs a real session id to address.
PARITY_FIXTURE :: "funpack-artifact 18\n" +
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

// parity_stage_fixture writes PARITY_FIXTURE to a uniquely-named temp file and returns
// its path. ok=false (the caller skips, never false-fails) when the temp root cannot be
// staged. The caller defers os.remove on the returned path.
@(private = "file")
parity_stage_fixture :: proc(t: ^testing.T, name: string) -> (path: string, ok: bool) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	path, _ = filepath.join({base, name}, context.temp_allocator)
	if write_err := os.write_entire_file(path, PARITY_FIXTURE); write_err != nil {
		return "", false
	}
	return path, true
}

// test_parity_tools_list_advertises_full_surface pins the cross-cutting advertisement
// contract no per-family test covers: tools/list, driven over the REAL framed
// transport, advertises EVERY tool name across all six families — the §28 session
// group AND the server-native group — and each is a named
// entry carrying a well-formed object inputSchema. A family unwired from the projection
// (or a tool dropped from the contract) makes its name absent here. The expected set is
// the closed 46-tool union; a contract that grows the surface without extending this
// list trips the count assertion, forcing the list to track the real surface.
@(test)
test_parity_tools_list_advertises_full_surface :: proc(t: ^testing.T) {
	// The full 46-tool surface, grouped by family for legibility. This is the union of
	// every family's own list membership, pinned here in one place.
	expected := []string {
		// §28 time-travel
		"time_load", "time_run", "time_pause", "time_step", "time_rewind", "time_reset", "time_status",
		// §28 inspect / observe
		"inspect_signals", "inspect_pipeline", "inspect_trace", "inspect_diff",
		"inspect_replay_behavior", "inspect_draw_list", "inspect_state", "inspect_screenshot",
		// §28 control
		"control_inject_input", "control_set", "control_spawn", "control_despawn",
		"control_emit", "control_reload", "control_branch", "control_checkout",
		// §28 breakpoints
		"break", "watch", "clear",
		// §28 self-heal
		"capture_test", "audit",
		// server-native one-shot compute
		"build", "export", "check", "test", "fmt",
		"warden_find", "warden_graph", "warden_holes", "warden_probes",
		"warden_debt", "warden_tags", "warden_pipeline",
		// server-native docs + health
		"docs_get", "docs_search", "health",
		// server-native session lifecycle
		"session_start", "session_list", "session_end",
	}

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	line := parity_drive_one(&registry, `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}`)

	tools := parity_result_tools(t, line, 1)

	// The advertised set IS the expected union — same cardinality, and every expected
	// name present with an object inputSchema. The count guard catches a surface that
	// grew or shrank without this list tracking it.
	testing.expect_value(t, len(tools), len(expected))

	advertised := make(map[string]bool, context.temp_allocator)
	for entry in tools {
		tool, is_object := entry.(json.Object)
		testing.expect(t, is_object, "each advertised tool is a JSON object")
		name, has_name := tool["name"].(json.String)
		testing.expect(t, has_name, "each advertised tool carries a name")
		schema, has_schema := tool["inputSchema"].(json.Object)
		testing.expect(t, has_schema, "each advertised tool carries an object inputSchema")
		schema_type, _ := schema["type"].(json.String)
		testing.expectf(t, string(schema_type) == "object", "tool %q inputSchema must be a JSON-Schema object", string(name))
		advertised[string(name)] = true
	}
	for name in expected {
		testing.expectf(t, advertised[name], "tool %q is not advertised in tools/list — its family is unwired from the projection", name)
	}
	// Cross-check the projection against the generated table: the advertised count is the
	// table length, so the wire surface and TOOL_SPECS can never disagree.
	testing.expect_value(t, len(tools), len(funpack.TOOL_SPECS))
}

// test_parity_protocol_round_trip_reaches_every_family is the end-to-end reachability
// gate: a single framed exchange — initialize → tools/list → one tools/call per family
// — driven through ONE registry-backed handler (so the session_start session persists
// for the session-scoped legs). Each tools/call returns a JSON-RPC result with the
// echoed id, never a protocol error object, proving every family arm is reachable
// through the production chain over the wire. The session-scoped legs (inspect / control
// / screenshot / time) address the real session minted by the session_start leg.
@(test)
test_parity_protocol_round_trip_reaches_every_family :: proc(t: ^testing.T) {
	path, staged := parity_stage_fixture(t, "funpack-mcp-parity-roundtrip.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	// 1) Handshake.
	init_line := parity_drive_one(&registry, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	testing.expect(t, strings.contains(init_line, `"result":`), "initialize returns a JSON-RPC result")

	// 2) Discovery.
	list_line := parity_drive_one(&registry, `{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`)
	testing.expect(t, strings.contains(list_line, `"result":`), "tools/list returns a JSON-RPC result")

	// 3a) docs-health family — health takes no args, always a clean probe.
	parity_expect_result_call(
		t,
		&registry,
		3,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}`,
		"health",
	)

	// 3b) session-lifecycle family — session_start opens over the fixture and mints the id
	// the later session-scoped legs address. Read the id back off the registry's only entry.
	start_args := strings.concatenate({`{"artifact":"`, path, `"}`}, context.temp_allocator)
	start_line := parity_drive_one(
		&registry,
		strings.concatenate(
			{`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"session_start","arguments":`, start_args, `}}`},
			context.temp_allocator,
		),
	)
	parity_expect_jsonrpc_result(t, start_line, 4)
	testing.expect(t, strings.contains(start_line, `"isError":false`), "session_start through the chain is a clean result")
	session_id: string
	for id in registry.entries {
		session_id = id
	}
	testing.expect(t, session_id != "", "session_start minted a real session id for the round-trip")

	// 3c) one-shot family — build over the fixture's directory (the staged file's parent is
	// not a §14 tree, so this is a refused build: a NORMAL ok:false result, still a JSON-RPC
	// result, which is the reachability contract this leg pins).
	dir := filepath.dir(path)
	build_args := strings.concatenate({`{"dir":"`, dir, `"}`}, context.temp_allocator)
	parity_expect_result_call(
		t,
		&registry,
		5,
		strings.concatenate(
			{`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"build","arguments":`, build_args, `}}`},
			context.temp_allocator,
		),
		"build",
	)

	// 3d) observe/time family — inspect_pipeline over the live session (a pure program read).
	parity_expect_session_call(t, &registry, 6, "inspect_pipeline", session_id, "")

	// 3e) control family — control_branch forks the live session's canonical chain.
	parity_expect_session_call(t, &registry, 7, "control_branch", session_id, "")

	// 3f) screenshot family — inspect_screenshot over the live session (headless refuses
	// with the draw_list-naming envelope, FUNPACK_LIVE serves an image; either is a result).
	parity_expect_session_call(t, &registry, 8, "inspect_screenshot", session_id, `,"tick":0`)
}

// parity_expect_session_call drives a tools/call for a session-scoped tool naming
// session_id (plus an optional pre-rendered `,extra` arg run) and asserts the framed
// response is a JSON-RPC result echoing the id — the reachability contract for the
// observe / control / screenshot legs (the per-family tests own the result-shape
// detail; this only pins that the call reaches the arm and returns a result).
@(private = "file")
parity_expect_session_call :: proc(
	t: ^testing.T,
	registry: ^Mcp_Session_Registry,
	id: i64,
	tool: string,
	session_id: string,
	extra: string,
	loc := #caller_location,
) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	strings.write_int(&b, int(id))
	strings.write_string(&b, `,"method":"tools/call","params":{"name":"`)
	strings.write_string(&b, tool)
	strings.write_string(&b, `","arguments":{"session_id":"`)
	strings.write_string(&b, session_id)
	strings.write_byte(&b, '"')
	strings.write_string(&b, extra)
	strings.write_string(&b, `}}}`)
	line := parity_drive_one(registry, strings.to_string(b))
	parity_expect_result_call(t, registry, id, "", tool, line, loc)
}

// parity_expect_result_call drives `request_line` (or, when it is empty, uses the
// already-driven `pre_driven` line) and asserts the framed response is a JSON-RPC
// result echoing `id` for the named tool — NEVER a protocol error object. It is the
// shared "this tools/call is reachable and returns a result" assertion every family
// leg of the round-trip funnels through.
@(private = "file")
parity_expect_result_call :: proc(
	t: ^testing.T,
	registry: ^Mcp_Session_Registry,
	id: i64,
	request_line: string,
	tool: string,
	pre_driven: string = "",
	loc := #caller_location,
) {
	line := pre_driven
	if request_line != "" {
		line = parity_drive_one(registry, request_line)
	}
	object := parity_expect_jsonrpc_result(t, line, id, loc)
	_ = object
	testing.expectf(t, !strings.contains(line, `"error":{"code"`), "tools/call for %q must not be a JSON-RPC error object", tool, loc = loc)
}

// parity_drive_one folds ONE request line through the production handler over an
// in-memory transport, returning the single framed response (newline trimmed). It
// reuses the SAME registry across calls so a session minted by an earlier line is
// visible to a later one — the stdio lifecycle the host drives.
@(private = "file")
parity_drive_one :: proc(registry: ^Mcp_Session_Registry, request_line: string) -> string {
	conn := parity_mem_conn({request_line}, context.temp_allocator)
	serve_mcp_connection(mcp_jsonrpc_handler(registry), parity_mem_transport(&conn), context.temp_allocator)
	return strings.trim_right(strings.to_string(conn.outgoing), "\n")
}

// parity_result_tools parses a tools/list framed response, asserts it is a JSON-RPC 2.0
// result echoing want_id, and returns the tools array — the entry point for the
// full-surface advertisement assertion.
@(private = "file")
parity_result_tools :: proc(t: ^testing.T, line: string, want_id: i64, loc := #caller_location) -> json.Array {
	result := parity_expect_jsonrpc_result(t, line, want_id, loc)
	tools, has_tools := result["tools"].(json.Array)
	testing.expect(t, has_tools, "tools/list result carries a tools array", loc = loc)
	return tools
}

// parity_expect_jsonrpc_result parses a framed response, asserts it is a JSON-RPC 2.0
// envelope echoing want_id and carrying a result object, and returns the result.
@(private = "file")
parity_expect_jsonrpc_result :: proc(t: ^testing.T, line: string, want_id: i64, loc := #caller_location) -> json.Object {
	parsed, err := json.parse(transmute([]u8)line, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None, "the response must be valid JSON: %q", line, loc = loc)
	object, is_object := parsed.(json.Object)
	testing.expect(t, is_object, "the response must be a JSON object", loc = loc)
	version, _ := object["jsonrpc"].(json.String)
	testing.expect_value(t, string(version), "2.0", loc = loc)
	resp_id, _ := object["id"].(json.Integer)
	testing.expect_value(t, i64(resp_id), want_id, loc = loc)
	result, has_result := object["result"].(json.Object)
	testing.expect(t, has_result, "the response must carry a result object", loc = loc)
	return result
}

// --- in-memory transport backing (parity-test-local twin of the family-test seam) ---

// Parity_Mem_Conn is the in-memory Line_Transport backing for the round-trip — the same
// shape mcp_server_test.odin and the transport test declare file-private, re-declared
// here because those are @(private="file"). `incoming` is the peer byte stream recv
// drains; `outgoing` accumulates the framed responses send writes.
@(private = "file")
Parity_Mem_Conn :: struct {
	incoming: []byte,
	read_pos: int,
	outgoing: strings.Builder,
}

@(private = "file")
parity_mem_transport :: proc(conn: ^Parity_Mem_Conn) -> funpack_runtime.Line_Transport {
	return funpack_runtime.Line_Transport {
		userdata = conn,
		recv = proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool) {
			conn := (^Parity_Mem_Conn)(userdata)
			if conn.read_pos >= len(conn.incoming) {
				return 0, true
			}
			n = copy(buf, conn.incoming[conn.read_pos:])
			conn.read_pos += n
			return n, true
		},
		send = proc(userdata: rawptr, buf: []byte) -> (ok: bool) {
			conn := (^Parity_Mem_Conn)(userdata)
			strings.write_bytes(&conn.outgoing, buf)
			return true
		},
	}
}

@(private = "file")
parity_mem_conn :: proc(lines: []string, allocator := context.allocator) -> Parity_Mem_Conn {
	b := strings.builder_make(allocator)
	for line in lines {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return Parity_Mem_Conn{incoming = transmute([]byte)strings.to_string(b), outgoing = strings.builder_make(allocator)}
}
