package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

PARITY_FIXTURE :: "funpack-artifact 19\n" +
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

@(test)
test_parity_tools_list_advertises_full_surface :: proc(t: ^testing.T) {
	expected := []string {
		"time_load", "time_run", "time_pause", "time_step", "time_rewind", "time_reset", "time_status",
		"inspect_signals", "inspect_pipeline", "inspect_trace", "inspect_diff",
		"inspect_replay_behavior", "inspect_draw_list", "inspect_state", "inspect_screenshot",
		"control_inject_input", "control_set", "control_spawn", "control_despawn",
		"control_emit", "control_reload", "control_branch", "control_checkout",
		"break", "watch", "clear",
		"capture_test", "capture_tick", "audit",
		"build", "export", "check", "test", "fmt",
		"warden_find", "warden_graph", "warden_holes", "warden_probes",
		"warden_debt", "warden_tags", "warden_pipeline",
		"docs_get", "docs_search", "health",
		"record",
		"session_start", "session_list", "session_end",
	}

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	line := parity_drive_one(&registry, `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}`)

	tools := parity_result_tools(t, line, 1)

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
	testing.expect_value(t, len(tools), len(funpack.TOOL_SPECS))
}

@(test)
test_parity_protocol_round_trip_reaches_every_family :: proc(t: ^testing.T) {
	path, staged := parity_stage_fixture(t, "funpack-mcp-parity-roundtrip.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	init_line := parity_drive_one(&registry, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	testing.expect(t, strings.contains(init_line, `"result":`), "initialize returns a JSON-RPC result")

	list_line := parity_drive_one(&registry, `{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`)
	testing.expect(t, strings.contains(list_line, `"result":`), "tools/list returns a JSON-RPC result")

	parity_expect_result_call(
		t,
		&registry,
		3,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}`,
		"health",
	)

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

	parity_expect_session_call(t, &registry, 6, "inspect_pipeline", session_id, "")

	parity_expect_session_call(t, &registry, 7, "control_branch", session_id, "")

	parity_expect_session_call(t, &registry, 8, "inspect_screenshot", session_id, `,"tick":0`)
}

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

@(private = "file")
parity_drive_one :: proc(registry: ^Mcp_Session_Registry, request_line: string) -> string {
	conn := parity_mem_conn({request_line}, context.temp_allocator)
	serve_mcp_connection(mcp_jsonrpc_handler(registry), parity_mem_transport(&conn), context.temp_allocator)
	return strings.trim_right(strings.to_string(conn.outgoing), "\n")
}

@(private = "file")
parity_result_tools :: proc(t: ^testing.T, line: string, want_id: i64, loc := #caller_location) -> json.Array {
	result := parity_expect_jsonrpc_result(t, line, want_id, loc)
	tools, has_tools := result["tools"].(json.Array)
	testing.expect(t, has_tools, "tools/list result carries a tools array", loc = loc)
	return tools
}

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
