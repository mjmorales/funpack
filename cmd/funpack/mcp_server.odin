// The MCP protocol dispatch loop and the `funpack mcp` verb entry — the JSON-RPC
// 2.0 handler that swaps in over the merged transport's Mcp_Line_Handler seam
// (mcp_transport.odin). This is the protocol SKELETON: the three lifecycle methods
// (initialize / tools/list / tools/call) plus the notifications/* accept-and-drop,
// over the contract-generated TOOL_SPECS table. The per-tool ARMS and the session
// registry are downstream tasks (mcp-session-registry, mcp-tools-*); they graft
// real arms onto the tools/call switch this file stubs, so this task lands the
// dispatch framework + the three contracts they extend: the tool name → arm seam,
// the Mcp_Error envelope convention, and the Mcp_Content result model.
//
// ABSOLUTE STDOUT DISCIPLINE: this loop returns a response STRING per request; the
// transport's send is the only stdout writer (mcp_transport.odin:70). Every
// diagnostic routes to stderr via the gated dbg() / fmt.eprintln, never stdout —
// a test scans the framed stream for any non-JSON-RPC line (mcp_server_test.odin).
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:strings"

// MCP_PROTOCOL_VERSION is the Model Context Protocol revision this server advertises
// in the initialize handshake. It is pinned to the version the go-sdk advertised as
// its latest (go-sdk v1.3.1 shared.go:37-39 latestProtocolVersion = "2025-06-18"),
// the same value the deleted Go server negotiated, so the bundled plugin client sees
// no protocol change across the fold. A test asserts the handshake carries exactly
// this string (test_mcp_initialize_capabilities).
MCP_PROTOCOL_VERSION :: "2025-06-18"

// MCP_SERVER_NAME / MCP_SERVER_TITLE identify this server to a client in the
// initialize result's serverInfo (the go-sdk Implementation, server.go:11). The
// name is the stable programmatic id the deleted Go server reported ("funpack-mcp").
MCP_SERVER_NAME :: "funpack-mcp"

// run_mcp_verb is the `funpack mcp` verb core: it builds the JSON-RPC handler and
// serves it over the auth-free stdio transport, then owns the {0,1,2} exit contract
// (main.odin:23-24, each verb core owns its exit number). A clean serve-then-EOF (the
// MCP host closed stdin) or a handler-signalled shutdown is exit 0 — the normal end
// of a stdio session (mirroring serve.go:121, EOF/signal-as-clean). A usage error is
// the framework's exit 2 (this verb takes no args, so usage never reaches here). An
// unrecoverable server fault would be exit 1; the protocol loop never panics on wire
// input (every malformed request is a JSON-RPC error response), so there is no fault
// path in the skeleton — it is reserved for the downstream session/IO arms.
run_mcp_verb :: proc(allocator := context.allocator) -> int {
	serve_mcp_stdio(mcp_jsonrpc_handler(), allocator)
	return 0
}

// mcp_jsonrpc_handler builds the real request handler that replaces the echo stub —
// the Mcp_Line_Handler the transport folds each line through. It carries no userdata
// at the skeleton layer (no session registry yet); the downstream session-registry
// task threads the registry through userdata without changing this seam.
mcp_jsonrpc_handler :: proc() -> Mcp_Line_Handler {
	return Mcp_Line_Handler {
		userdata = nil,
		handle = proc(userdata: rawptr, line: string, allocator := context.allocator) -> (response: string, keep_open: bool) {
			return mcp_dispatch_line(line, allocator)
		},
	}
}

// mcp_dispatch_line parses one JSON-RPC line and routes it to its method handler,
// returning the response line to frame back (empty ⇒ no reply, the notification
// case) and keep_open (always true at the skeleton layer — the host closing stdin
// ends the session, not a protocol message). A line that is not a valid request
// envelope is a PROTOCOL fault: a JSON-RPC error response (never a panic). A
// notification (no id) is accepted and dropped silently per the MCP contract.
mcp_dispatch_line :: proc(line: string, allocator := context.allocator) -> (response: string, keep_open: bool) {
	request, ok := mcp_parse_request(line, allocator)
	if !ok {
		// A notification that failed to parse a method still gets no reply (the
		// client expects none); a request envelope that is malformed or missing its
		// method is a protocol error the caller can read on its id.
		if request.is_notification {
			return "", true
		}
		return mcp_render_error(request.id, MCP_JSONRPC_INVALID_REQUEST, "invalid JSON-RPC request: malformed envelope or missing method", allocator), true
	}

	// notifications/* carry no id and expect no response (notifications/initialized,
	// notifications/cancelled, …) — accept and drop, matching the go-sdk, so the
	// handshake completes (server.go registers no notification handlers beyond this).
	if strings.has_prefix(request.method, "notifications/") {
		return "", true
	}

	switch request.method {
	case "initialize":
		return mcp_handle_initialize(request, allocator), true
	case "tools/list":
		return mcp_handle_tools_list(request, allocator), true
	case "tools/call":
		return mcp_handle_tools_call(request, allocator), true
	}
	return mcp_render_error(request.id, MCP_JSONRPC_METHOD_NOT_FOUND, "method not found", allocator), true
}

// mcp_handle_initialize answers the MCP handshake: it advertises THIS server's
// protocolVersion, capabilities, and serverInfo. capabilities advertises tools ONLY
// (no resources, no prompts, no logging) — the deleted Go server registered only
// tools (server.go:37-49), and the screenshot/session surface is all tools. The
// result shape matches the go-sdk InitializeResult (protocol.go:486-503).
mcp_handle_initialize :: proc(request: Mcp_Request, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"protocolVersion\":\"")
	strings.write_string(&b, MCP_PROTOCOL_VERSION)
	// capabilities advertises tools only; listChanged=false (the tool list is the
	// fixed contract projection — it never changes within a session).
	strings.write_string(&b, "\",\"capabilities\":{\"tools\":{\"listChanged\":false}}")
	strings.write_string(&b, ",\"serverInfo\":{\"name\":\"")
	strings.write_string(&b, MCP_SERVER_NAME)
	strings.write_string(&b, "\",\"version\":")
	funpack_runtime.write_json_string(&b, funpack.funpack_version())
	strings.write_string(&b, "}}")
	return mcp_render_result(request.id, strings.to_string(b), allocator)
}

// mcp_handle_tools_list emits the tools/list result from the generated TOOL_SPECS
// table (funpack/api_contract.gen.odin), so the advertised input_schema CANNOT drift
// from dispatch (the §28 wire arg names ARE the dispatch hints). At the SKELETON
// layer this projection is the full contract table; the downstream tool tasks fill
// the matching tools/call arms. The result is {tools:[…]}, each tool a {name,
// description, inputSchema} per the go-sdk Tool shape (protocol.go:1045).
mcp_handle_tools_list :: proc(request: Mcp_Request, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"tools\":[")
	for spec, i in funpack.TOOL_SPECS {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		mcp_write_tool_spec(&b, spec)
	}
	strings.write_string(&b, "]}")
	return mcp_render_result(request.id, strings.to_string(b), allocator)
}

// mcp_write_tool_spec renders one Tool_Spec as an MCP tool object: name plus a
// JSON-Schema inputSchema projected from the spec's args (type:object, properties,
// required). The schema is the generated arg shape — this proc only formats it, it
// authors nothing (no hand-written schema literal, the drift the projection cures).
mcp_write_tool_spec :: proc(b: ^strings.Builder, spec: funpack.Tool_Spec) {
	strings.write_string(b, "{\"name\":")
	funpack_runtime.write_json_string(b, spec.name)
	strings.write_string(b, ",\"inputSchema\":{\"type\":\"object\",\"properties\":{")
	for arg, i in spec.args {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		funpack_runtime.write_json_string(b, arg.name)
		strings.write_string(b, ":{\"type\":")
		funpack_runtime.write_json_string(b, arg.json_type)
		strings.write_string(b, ",\"description\":")
		funpack_runtime.write_json_string(b, arg.doc)
		strings.write_byte(b, '}')
	}
	strings.write_string(b, "},\"required\":[")
	first_required := true
	for arg in spec.args {
		if !arg.required {
			continue
		}
		if !first_required {
			strings.write_byte(b, ',')
		}
		first_required = false
		funpack_runtime.write_json_string(b, arg.name)
	}
	strings.write_string(b, "]}}")
}

// mcp_handle_tools_call dispatches a tools/call to its arm. At the SKELETON layer NO
// arm is implemented: the call returns the IsError tools/call result the downstream
// tasks will replace per tool — for a name in the table, a clean not-implemented
// stub keyed off the Tool_Spec (wave-3 fills it); for an unknown name, the
// invalid_input "unknown tool" envelope. EITHER way the failure is the in-band
// IsError result convention (mcp_error.odin), never a JSON-RPC error object — the
// model reads the category and self-corrects. The downstream arms graft onto the
// switch this stub establishes.
mcp_handle_tools_call :: proc(request: Mcp_Request, allocator := context.allocator) -> string {
	name, has_name := request.params["name"]
	name_string, name_is_string := name.(string)
	if !has_name || !name_is_string {
		result := mcp_tool_error_result(
			Mcp_Error{category = .Invalid_Input, message = "tools/call missing required string field: name"},
			allocator,
		)
		return mcp_render_tool_result(request.id, result, allocator)
	}

	if spec, found := mcp_lookup_tool(string(name_string)); found {
		result := mcp_tool_error_result(
			Mcp_Error{
				category = .Internal,
				message  = "tool not yet implemented",
				detail   = spec.name,
			},
			allocator,
		)
		return mcp_render_tool_result(request.id, result, allocator)
	}

	result := mcp_tool_error_result(
		Mcp_Error{
			category = .Invalid_Input,
			message  = "unknown tool",
			detail   = string(name_string),
		},
		allocator,
	)
	return mcp_render_tool_result(request.id, result, allocator)
}

// mcp_lookup_tool finds a Tool_Spec by its advertised MCP name in the generated
// table — the seam the downstream tool tasks dispatch their arms through (name →
// spec → arm). Returned by value (the table is read-only); found=false is the
// unknown-tool path.
mcp_lookup_tool :: proc(name: string) -> (spec: funpack.Tool_Spec, found: bool) {
	for candidate in funpack.TOOL_SPECS {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

// mcp_render_tool_result renders an Mcp_Tool_Result into a JSON-RPC success result:
// {content:[…],isError:<bool>} per the go-sdk CallToolResult (protocol.go:75). A
// domain failure rides here as a SUCCESSFUL JSON-RPC result with isError=true (the
// convention) — never a JSON-RPC error object. Each content block renders to its
// MCP wire shape (text ⇒ {type:"text",text:…}, image ⇒ {type:"image",data:…,
// mimeType:…}, content.go).
mcp_render_tool_result :: proc(id: Mcp_Id, result: Mcp_Tool_Result, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"content\":[")
	for block, i in result.content {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		mcp_write_content_block(&b, block)
	}
	strings.write_string(&b, "],\"isError\":")
	strings.write_string(&b, result.is_error ? "true" : "false")
	strings.write_byte(&b, '}')
	return mcp_render_result(id, strings.to_string(b), allocator)
}

// mcp_write_content_block renders one content block to its MCP wire shape. The
// model is closed to the two kinds this server emits (text/image); the switch is
// exhaustive so a new kind without a renderer is a compile error.
mcp_write_content_block :: proc(b: ^strings.Builder, block: Mcp_Content) {
	switch block.kind {
	case .Text:
		strings.write_string(b, "{\"type\":\"text\",\"text\":")
		funpack_runtime.write_json_string(b, block.text)
		strings.write_byte(b, '}')
	case .Image:
		strings.write_string(b, "{\"type\":\"image\",\"data\":")
		funpack_runtime.write_json_string(b, block.data)
		strings.write_string(b, ",\"mimeType\":")
		funpack_runtime.write_json_string(b, block.mime_type)
		strings.write_byte(b, '}')
	}
}
