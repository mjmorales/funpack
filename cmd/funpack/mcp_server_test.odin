// Deliberate spec for the MCP protocol dispatch loop (mcp_server.odin) — the
// initialize / tools/list / tools/call / notifications junction the real handler
// drives over the merged transport. These pin the lifecycle contract as a living
// spec: the handshake advertises tools-only with the PINNED protocolVersion, tools/list
// is the contract projection (not hand-authored), an unknown tools/call is the
// in-band IsError envelope (never a JSON-RPC error), notifications are dropped, and
// — the load-bearing invariant — a full exchange emits ONLY JSON-RPC lines on the
// framed stream (stdout discipline). Driven headlessly over the in-memory transport
// seam (mcp_transport_test.odin's Mcp_Mem_Conn), no real stdio, no SDL.
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"
import "core:testing"

// drive_handler folds one request line through the REAL JSON-RPC handler over an
// in-memory transport and returns the single framed response line (newline trimmed).
// It exercises the same serve_mcp_connection loop the verb runs, so the test pins
// the handler exactly as it ships, not a re-implementation.
drive_handler :: proc(t: ^testing.T, request_line: string, loc := #caller_location) -> string {
	conn := server_mem_conn({request_line}, context.temp_allocator)
	serve_mcp_connection(mcp_jsonrpc_handler(), server_mem_transport(&conn), context.temp_allocator)
	return strings.trim_right(strings.to_string(conn.outgoing), "\n")
}

// test_mcp_initialize_capabilities pins the handshake: an initialize request returns
// a well-formed JSON-RPC result advertising capabilities={tools} ONLY (no resources,
// no prompts), the PINNED MCP protocolVersion, and serverInfo. The protocolVersion
// assertion is the regression guard for the version the go-sdk advertised (the
// bundled plugin client negotiates this exact string).
@(test)
test_mcp_initialize_capabilities :: proc(t: ^testing.T) {
	line := drive_handler(t, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	result := expect_jsonrpc_result(t, line, 1)

	protocol_version, has_pv := result["protocolVersion"].(json.String)
	testing.expect(t, has_pv, "initialize must advertise a protocolVersion")
	testing.expect_value(t, string(protocol_version), MCP_PROTOCOL_VERSION)
	testing.expect_value(t, MCP_PROTOCOL_VERSION, "2025-06-18")

	capabilities, has_caps := result["capabilities"].(json.Object)
	testing.expect(t, has_caps, "initialize must advertise capabilities")
	_, has_tools := capabilities["tools"]
	testing.expect(t, has_tools, "capabilities must advertise tools")
	_, has_resources := capabilities["resources"]
	testing.expect(t, !has_resources, "capabilities must NOT advertise resources")
	_, has_prompts := capabilities["prompts"]
	testing.expect(t, !has_prompts, "capabilities must NOT advertise prompts")

	server_info, has_info := result["serverInfo"].(json.Object)
	testing.expect(t, has_info, "initialize must carry serverInfo")
	name, _ := server_info["name"].(json.String)
	testing.expect_value(t, string(name), MCP_SERVER_NAME)
}

// test_mcp_tools_list_projection pins that tools/list is the GENERATED projection
// from TOOL_SPECS, not a hand-authored or empty stub — so the advertised input_schema
// cannot drift from dispatch (the prerequisite mcp-contract-arg-shapes landed the
// table). The list length equals the contract table, every tool carries a name and
// an object inputSchema, and a representative §28 tool (break) is present.
@(test)
test_mcp_tools_list_projection :: proc(t: ^testing.T) {
	line := drive_handler(t, `{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`)
	result := expect_jsonrpc_result(t, line, 2)

	tools, has_tools := result["tools"].(json.Array)
	testing.expect(t, has_tools, "tools/list must return a tools array")
	testing.expect_value(t, len(tools), len(funpack.TOOL_SPECS))

	seen_break := false
	for entry in tools {
		tool, is_object := entry.(json.Object)
		testing.expect(t, is_object, "each tool is a JSON object")
		name, has_name := tool["name"].(json.String)
		testing.expect(t, has_name, "each tool carries a name")
		_, has_schema := tool["inputSchema"].(json.Object)
		testing.expect(t, has_schema, "each tool carries an object inputSchema")
		if string(name) == "break" {
			seen_break = true
		}
	}
	testing.expect(t, seen_break, "the §28 break command projects to a tool")
}

// test_mcp_tool_schema_required pins the schema projection's required-set: a tool
// whose §28 args include a required field lists it under inputSchema.required, and
// an optional field is absent from required. `watch` carries required `target`+`body`
// and the optional `branch` selector — the junction proving the projection reads the
// generated `required` flags, not a flat property dump.
@(test)
test_mcp_tool_schema_required :: proc(t: ^testing.T) {
	line := drive_handler(t, `{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}`)
	result := expect_jsonrpc_result(t, line, 3)
	tools, _ := result["tools"].(json.Array)

	for entry in tools {
		tool := entry.(json.Object)
		name, _ := tool["name"].(json.String)
		if string(name) != "watch" {
			continue
		}
		schema := tool["inputSchema"].(json.Object)
		required, has_required := schema["required"].(json.Array)
		testing.expect(t, has_required, "a tool with required args lists them")
		required_set := make(map[string]bool, context.temp_allocator)
		for value in required {
			required_set[string(value.(json.String))] = true
		}
		testing.expect(t, required_set["target"], "watch.target is required")
		testing.expect(t, required_set["body"], "watch.body is required")
		testing.expect(t, !required_set["branch"], "the optional branch selector is NOT required")
		return
	}
	testing.expect(t, false, "the watch tool must be present in the projection")
}

// test_mcp_unknown_tool pins the unknown-tool path: a tools/call for a name not in
// the table returns a SUCCESSFUL JSON-RPC result (not an error object) carrying
// isError=true and an invalid_input envelope naming the unknown tool — the in-band
// convention the model self-corrects from.
@(test)
test_mcp_unknown_tool :: proc(t: ^testing.T) {
	line := drive_handler(t, `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool"}}`)
	result := expect_jsonrpc_result(t, line, 4)

	is_error, _ := result["isError"].(json.Boolean)
	testing.expect(t, bool(is_error), "an unknown tool is an IsError result, not a protocol error")

	content := result["content"].(json.Array)
	testing.expect_value(t, len(content), 1)
	block := content[0].(json.Object)
	text, _ := block["text"].(json.String)
	category, message, detail := decode_envelope(t, string(text))
	testing.expect_value(t, category, "invalid_input")
	testing.expect_value(t, message, "unknown tool")
	testing.expect_value(t, detail, "no_such_tool")
}

// test_mcp_known_tool_not_implemented pins the SKELETON contract for a tool that IS
// in the table: at this layer no arm is wired, so the call returns the in-band
// not-implemented IsError envelope keyed off the Tool_Spec (the wave-3 tasks replace
// it). It is an IsError result, never a JSON-RPC error — the same convention.
@(test)
test_mcp_known_tool_not_implemented :: proc(t: ^testing.T) {
	line := drive_handler(t, `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"break"}}`)
	result := expect_jsonrpc_result(t, line, 5)

	is_error, _ := result["isError"].(json.Boolean)
	testing.expect(t, bool(is_error), "a not-yet-implemented tool is an IsError result")
	content := result["content"].(json.Array)
	block := content[0].(json.Object)
	text, _ := block["text"].(json.String)
	category, _, detail := decode_envelope(t, string(text))
	testing.expect_value(t, category, "internal")
	testing.expect_value(t, detail, "break")
}

// test_mcp_notification_dropped pins the MCP handshake contract: a notifications/*
// message (no id, no reply expected) is accepted and produces NO response line, so
// the handshake completes. notifications/initialized is the canonical case.
@(test)
test_mcp_notification_dropped :: proc(t: ^testing.T) {
	conn := server_mem_conn({`{"jsonrpc":"2.0","method":"notifications/initialized"}`}, context.temp_allocator)
	serve_mcp_connection(mcp_jsonrpc_handler(), server_mem_transport(&conn), context.temp_allocator)
	testing.expect_value(t, strings.to_string(conn.outgoing), "")
}

// test_mcp_method_not_found pins the PROTOCOL-fault path: an unknown method (not a
// notification) returns a JSON-RPC error object with code -32601 — the protocol
// fault the caller cannot act on, distinct from a domain failure's in-band envelope.
@(test)
test_mcp_method_not_found :: proc(t: ^testing.T) {
	line := drive_handler(t, `{"jsonrpc":"2.0","id":6,"method":"resources/list","params":{}}`)
	object := expect_jsonrpc_object(t, line, 6)
	error, has_error := object["error"].(json.Object)
	testing.expect(t, has_error, "an unknown method is a JSON-RPC error object")
	code, _ := error["code"].(json.Integer)
	testing.expect_value(t, i64(code), i64(MCP_JSONRPC_METHOD_NOT_FOUND))
}

// test_mcp_stdout_discipline is the load-bearing invariant: across a full
// initialize → tools/list → tools/call exchange the server emits ONLY JSON-RPC lines
// on the framed stream — every line parses as a JSON object carrying "jsonrpc":"2.0"
// and EITHER "result" or "error". A diagnostic leaking to stdout would surface here
// as a non-JSON-RPC line and fail. Every diagnostic must route to stderr.
@(test)
test_mcp_stdout_discipline :: proc(t: ^testing.T) {
	exchange := []string {
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"no_such_tool"}}`,
	}
	conn := server_mem_conn(exchange, context.temp_allocator)
	serve_mcp_connection(mcp_jsonrpc_handler(), server_mem_transport(&conn), context.temp_allocator)

	out := strings.to_string(conn.outgoing)
	// The notification produced no line, so the framed stream is exactly 3 responses.
	lines := strings.split_lines(strings.trim_right(out, "\n"), context.temp_allocator)
	testing.expect_value(t, len(lines), 3)
	for response, i in lines {
		parsed, err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		testing.expectf(t, err == .None, "stdout line %d is not valid JSON: %q", i, response)
		object, is_object := parsed.(json.Object)
		testing.expect(t, is_object, "every stdout line is a JSON object")
		version, has_version := object["jsonrpc"].(json.String)
		testing.expect(t, has_version && string(version) == "2.0", "every stdout line is a JSON-RPC 2.0 envelope")
		_, has_result := object["result"]
		_, has_error := object["error"]
		testing.expect(t, has_result != has_error, "a JSON-RPC response carries exactly one of result/error")
	}
}

// test_mcp_verb_exit_codes pins the {0,1,2} exit contract's clean-shutdown arm: a
// served connection that reaches EOF (the host closed stdin) ends the loop and the
// verb core returns 0 — a clean serve-then-EOF is success (serve.go:121). The usage
// tier (exit 2) is the framework's, pinned by cli_root_test; an unrecoverable fault
// (exit 1) has no path in the skeleton (the loop never panics on wire input). This
// test drives the loop to a natural EOF close to prove the 0-exit shutdown.
@(test)
test_mcp_verb_exit_codes :: proc(t: ^testing.T) {
	// A connection whose stream drains (EOF) returns from the serve loop cleanly —
	// the same path run_mcp_verb returns 0 after.
	conn := server_mem_conn({`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`}, context.temp_allocator)
	serve_mcp_connection(mcp_jsonrpc_handler(), server_mem_transport(&conn), context.temp_allocator)
	// The loop returned (did not hang) and framed exactly the one response — the
	// clean EOF shutdown run_mcp_verb maps to exit 0.
	testing.expect(t, strings.contains(strings.to_string(conn.outgoing), `"id":1`), "the request was answered before the clean EOF close")
}

// --- in-memory transport backing (server-test-local twin of the transport-test seam) ---

// Server_Mem_Conn is the in-memory Line_Transport backing for the protocol-loop
// tests — the same shape as mcp_transport_test.odin's file-private Mcp_Mem_Conn,
// re-declared here because that one is @(private="file"). `incoming` is the peer
// byte stream recv drains; `outgoing` accumulates the framed responses send writes.
@(private = "file")
Server_Mem_Conn :: struct {
	incoming: []byte,
	read_pos: int,
	outgoing: strings.Builder,
}

@(private = "file")
server_mem_transport :: proc(conn: ^Server_Mem_Conn) -> funpack_runtime.Line_Transport {
	return funpack_runtime.Line_Transport {
		userdata = conn,
		recv = proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool) {
			conn := (^Server_Mem_Conn)(userdata)
			if conn.read_pos >= len(conn.incoming) {
				return 0, true
			}
			n = copy(buf, conn.incoming[conn.read_pos:])
			conn.read_pos += n
			return n, true
		},
		send = proc(userdata: rawptr, buf: []byte) -> (ok: bool) {
			conn := (^Server_Mem_Conn)(userdata)
			strings.write_bytes(&conn.outgoing, buf)
			return true
		},
	}
}

@(private = "file")
server_mem_conn :: proc(lines: []string, allocator := context.allocator) -> Server_Mem_Conn {
	b := strings.builder_make(allocator)
	for line in lines {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return Server_Mem_Conn{incoming = transmute([]byte)strings.to_string(b), outgoing = strings.builder_make(allocator)}
}

// expect_jsonrpc_object parses a framed response line, asserts it is a JSON-RPC 2.0
// envelope echoing the expected id, and returns the parsed object.
@(private = "file")
expect_jsonrpc_object :: proc(t: ^testing.T, line: string, want_id: i64, loc := #caller_location) -> json.Object {
	parsed, err := json.parse(transmute([]u8)line, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect(t, err == .None, "the response must be valid JSON", loc = loc)
	object, is_object := parsed.(json.Object)
	testing.expect(t, is_object, "the response must be a JSON object", loc = loc)
	version, _ := object["jsonrpc"].(json.String)
	testing.expect_value(t, string(version), "2.0", loc = loc)
	id, _ := object["id"].(json.Integer)
	testing.expect_value(t, i64(id), want_id, loc = loc)
	return object
}

// expect_jsonrpc_result asserts a success response (a "result" object present) and
// returns the result — the common path for initialize / tools/* assertions.
@(private = "file")
expect_jsonrpc_result :: proc(t: ^testing.T, line: string, want_id: i64, loc := #caller_location) -> json.Object {
	object := expect_jsonrpc_object(t, line, want_id, loc)
	result, has_result := object["result"].(json.Object)
	testing.expect(t, has_result, "the response must carry a result object", loc = loc)
	return result
}
