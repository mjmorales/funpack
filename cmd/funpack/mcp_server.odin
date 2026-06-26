// The MCP protocol dispatch loop and the `funpack mcp` verb entry — the JSON-RPC
// 2.0 handler that swaps in over the merged transport's Mcp_Line_Handler seam
// (mcp_transport.odin). This is the protocol CORE: the three lifecycle methods
// (initialize / tools/list / tools/call) plus the notifications/* accept-and-drop,
// over the contract-generated TOOL_SPECS table. It owns the dispatch framework and
// the three contracts the per-tool arms extend: the tool name → arm seam, the
// Mcp_Error envelope convention, and the Mcp_Content result model. The per-family
// arm files (mcp_tools_*.odin) graft real arms onto the tools/call switch; the
// session registry is threaded through here (see THE SESSION REGISTRY below).
//
// ABSOLUTE STDOUT DISCIPLINE: this loop returns a response STRING per request; the
// transport's send is the only stdout writer (mcp_transport.odin). Every diagnostic
// routes to stderr via the gated dbg() / fmt.eprintln, never stdout — a test scans
// the framed stream for any non-JSON-RPC line (mcp_server_test.odin).
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

// MCP_PROTOCOL_VERSION is the Model Context Protocol revision this server advertises
// in the initialize handshake, pinned to the MCP spec revision the bundled plugin
// client negotiates against. A test asserts the handshake carries exactly this
// string (test_mcp_initialize_capabilities).
MCP_PROTOCOL_VERSION :: "2025-06-18"

// MCP_SERVER_NAME identifies this server to a client in the initialize result's
// serverInfo — the stable programmatic id the server reports ("funpack-mcp").
MCP_SERVER_NAME :: "funpack-mcp"

// run_mcp_verb is the `funpack mcp` verb core: it builds the JSON-RPC handler and
// serves it over the auth-free stdio transport, then owns the {0,1,2} exit contract
// (each verb core owns its exit number). A clean serve-then-EOF (the MCP host closed
// stdin) or a handler-signalled shutdown is exit 0 — the normal end of a stdio
// session. A usage error is the framework's exit 2 (this verb takes no args, so
// usage never reaches here). An unrecoverable server fault is exit 1; the protocol
// loop never panics on wire input (every malformed request is a JSON-RPC error
// response), so a fault path arises only from the session/IO arms, not the dispatch
// core.
//
// THE SESSION REGISTRY is server-scoped: minted once here, lives for the whole stdio
// session, torn down on shutdown (the F13 fix — a session OUTLIVES the request that
// opened it). It is threaded into the handler via userdata so the session-family
// dispatch arm reaches it without the transport knowing its shape.
run_mcp_verb :: proc(allocator := context.allocator) -> int {
	// Best-effort, startup-once: materialize the version-keyed on-disk docs projection so an
	// agent can traverse the docs natively (Read/Grep/follow-anchor) alongside the in-process
	// docs tools. Idempotent (a matching sentinel is a no-op) and non-fatal (a missing or
	// read-only ~/.funpack home degrades to no on-disk tree, reported to stderr) — it never
	// aborts the serve loop, and docs_search stays a pure in-process function regardless.
	mcp_materialize_docs_projection(allocator)

	registry := mcp_session_registry_make(allocator)
	defer mcp_session_registry_destroy(&registry, allocator)
	serve_mcp_stdio(mcp_jsonrpc_handler(&registry), allocator)
	return 0
}

// mcp_jsonrpc_handler builds the real request handler — the Mcp_Line_Handler the
// transport folds each line through. It carries the SERVER-SCOPED session registry as
// userdata so the session-family dispatch arm reaches the live session table; the
// registry outlives every request (the F13 lifetime contract). The handler unwraps the
// registry pointer back out of userdata before dispatching.
mcp_jsonrpc_handler :: proc(registry: ^Mcp_Session_Registry) -> Mcp_Line_Handler {
	return Mcp_Line_Handler {
		userdata = registry,
		handle = proc(userdata: rawptr, line: string, allocator := context.allocator) -> (response: string, keep_open: bool) {
			registry := cast(^Mcp_Session_Registry)userdata
			return mcp_dispatch_line(registry, line, allocator)
		},
	}
}

// mcp_dispatch_line parses one JSON-RPC line and routes it to its method handler,
// returning the response line to frame back (empty ⇒ no reply, the notification
// case) and keep_open (always true — the host closing stdin ends the session, never
// a protocol message). A line that is not a valid request envelope is a PROTOCOL
// fault: a JSON-RPC error response (never a panic). A notification (no id) is
// accepted and dropped silently per the MCP contract.
mcp_dispatch_line :: proc(registry: ^Mcp_Session_Registry, line: string, allocator := context.allocator) -> (response: string, keep_open: bool) {
	request, ok, json_ok := mcp_parse_request(line, allocator)
	if !ok {
		// A notification that failed to parse a method still gets no reply (the
		// client expects none); otherwise the two JSON-RPC fault classes map to their
		// distinct reserved codes: unparseable JSON is -32700 PARSE_ERROR, well-formed
		// JSON that is not a valid Request is -32600 INVALID_REQUEST.
		if request.is_notification {
			return "", true
		}
		if !json_ok {
			return mcp_render_error(request.id, MCP_JSONRPC_PARSE_ERROR, "parse error: line is not valid JSON", allocator), true
		}
		return mcp_render_error(request.id, MCP_JSONRPC_INVALID_REQUEST, "invalid JSON-RPC request: not a request object or missing method", allocator), true
	}

	// notifications/* carry no id and expect no response (notifications/initialized,
	// notifications/cancelled, …) — accept and drop per JSON-RPC notification
	// semantics, so the handshake completes regardless of which notifications a client
	// sends.
	if strings.has_prefix(request.method, "notifications/") {
		return "", true
	}

	switch request.method {
	case "initialize":
		return mcp_handle_initialize(request, allocator), true
	case "tools/list":
		return mcp_handle_tools_list(request, allocator), true
	case "tools/call":
		return mcp_handle_tools_call(registry, request, allocator), true
	}
	return mcp_render_error(request.id, MCP_JSONRPC_METHOD_NOT_FOUND, "method not found", allocator), true
}

// mcp_handle_initialize answers the MCP handshake: it advertises THIS server's
// protocolVersion, capabilities, serverInfo, AND the invariant-core `instructions`.
// capabilities advertises tools ONLY (no resources, no prompts, no logging) — the
// entire funpack surface is tools. `instructions` carries the always-present invariant
// core (mcp_core_prefix.odin) — the spec-sanctioned channel a client folds into its
// system prompt, so the prompt cache holds the funpack core ONCE rather than the model
// re-retrieving it per docs query. The core is assembled from the embedded corpus and
// is emitted only when it builds; a build failure (a curated anchor that no longer
// resolves) drops the field rather than shipping a truncated prefix — a fail-loudly the
// corpus tests guard so the committed binary always carries it. The result shape
// matches the MCP InitializeResult.
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
	strings.write_string(&b, "}")
	// The invariant-core prefix rides in `instructions` — the always-present, cacheable
	// channel. Emitted only on a clean build (a missing curated anchor fails loudly to no
	// instructions, never a partial prefix); the corpus tests keep the build clean so a
	// shipped binary always carries it.
	if instructions, ok := core_prefix_build(allocator); ok {
		strings.write_string(&b, ",\"instructions\":")
		funpack_runtime.write_json_string(&b, instructions)
	}
	strings.write_string(&b, "}")
	return mcp_render_result(request.id, strings.to_string(b), allocator)
}

// mcp_handle_tools_list emits the tools/list result from the generated TOOL_SPECS
// table (funpack/api_contract.gen.odin), so the advertised input_schema CANNOT drift
// from dispatch (the §28 wire arg names ARE the dispatch hints). This projection is
// the full contract table; the per-family arm files fill the matching tools/call
// arms. The result is {tools:[…]}, each tool a {name, description, inputSchema} per
// the MCP Tool shape.
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

// Mcp_Dispatch is the per-call context every family dispatch arm reads: the resolved
// Tool_Spec (name + arg schema — the dispatch hints), the tool name, the parsed
// `arguments` object the call carried, the request id (so an arm can render its own
// JSON-RPC result line), and the server-scoped session registry (the session family's
// reach into live sessions — the F13 lifetime owner). It is passed BY VALUE: a family
// arm reads it; only the session arm mutates state, and that state lives behind the
// `registry` pointer, not in this struct. Bundling the call context in one struct is
// what lets each family file fill ONLY its own arm — the dispatch seam never changes
// shape as arms land.
Mcp_Dispatch :: struct {
	spec:      funpack.Tool_Spec,
	name:      string,
	arguments: json.Object,
	id:        Mcp_Id,
	registry:  ^Mcp_Session_Registry,
}

// mcp_handle_tools_call dispatches a tools/call through the per-family arm CHAIN. For
// a tool found in TOOL_SPECS it tries each family dispatch proc in order; the FIRST
// that returns handled=true wins and owns the rendered JSON-RPC result. If NO family
// handles a KNOWN tool, it falls through to the not-implemented IsError stub keyed off
// the spec (the family file for that tool has not been filled yet). An UNKNOWN name
// keeps the invalid_input "unknown tool" IsError envelope. EITHER failure is the
// in-band IsError result convention (mcp_error.odin), never a JSON-RPC error object —
// the model reads the category and self-corrects.
//
// THE EXTENSION SEAM (the whole point of the chain): each family file fills ONLY its
// own dispatch proc, with ZERO edits here. A family arm returns ("", false) for any
// tool it does not own (the stub state), so a tool flows down the chain until its
// family claims it. The chain order is the family list, not a
// priority — at most one family owns any given tool name, so order is immaterial to
// correctness (a tool the wrong family wrongly claimed would be a bug in that family,
// not here).
mcp_handle_tools_call :: proc(registry: ^Mcp_Session_Registry, request: Mcp_Request, allocator := context.allocator) -> string {
	name, has_name := request.params["name"]
	name_string, name_is_string := name.(json.String)
	if !has_name || !name_is_string {
		result := mcp_tool_error_result(
			Mcp_Error{category = .Invalid_Input, message = "tools/call missing required string field: name"},
			allocator,
		)
		return mcp_render_tool_result(request.id, result, allocator)
	}

	spec, found := mcp_lookup_tool(string(name_string))
	if !found {
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

	// The `arguments` object the call carried (MCP tools/call params.arguments). Absent
	// or non-object leaves it empty — each arm reads its own args off it, exactly as
	// session_request reads its `args` (introspect.odin).
	arguments: json.Object
	if nested, has_args := request.params["arguments"]; has_args {
		if object, args_ok := nested.(json.Object); args_ok {
			arguments = object
		}
	}

	dispatch := Mcp_Dispatch {
		spec      = spec,
		name      = string(name_string),
		arguments = arguments,
		id        = request.id,
		registry  = registry,
	}

	// The per-family dispatch chain. Each arm lives in its own file (mcp_tools_*.odin);
	// the first arm that returns handled=true owns the result. A KNOWN tool no family
	// claims falls through to the not-implemented stub below.
	for arm in MCP_DISPATCH_CHAIN {
		if result, handled := arm(dispatch, allocator); handled {
			return result
		}
	}

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

// Mcp_Tool_Dispatch is one per-family dispatch arm: handed the call context, it either
// CLAIMS the tool (handled=true, returning the rendered JSON-RPC result line) or
// declines it (handled=false, result ignored) so the next arm in the chain tries.
// Every family file (mcp_tools_*.odin) implements exactly one of these.
Mcp_Tool_Dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool)

// MCP_DISPATCH_CHAIN is the ordered per-family dispatch chain mcp_handle_tools_call
// walks. Each entry is a family's arm proc, each in its OWN file. ADDING a tool
// family means: write its mcp_tools_<family>.odin with its dispatch proc, then append
// the proc here — NEVER edit mcp_handle_tools_call. Order is immaterial to
// correctness (at most one family claims any tool name).
MCP_DISPATCH_CHAIN := [?]Mcp_Tool_Dispatch {
	mcp_oneshot_dispatch,
	mcp_docs_tool_dispatch,
	mcp_session_tool_dispatch,
	mcp_record_dispatch,
	mcp_observe_time_dispatch,
	mcp_control_dispatch,
	mcp_screenshot_dispatch,
}

// mcp_lookup_tool finds a Tool_Spec by its advertised MCP name in the generated
// table — the seam the family arms dispatch through (name → spec → arm). Returned by
// value (the table is read-only); found=false is the unknown-tool path.
mcp_lookup_tool :: proc(name: string) -> (spec: funpack.Tool_Spec, found: bool) {
	for candidate in funpack.TOOL_SPECS {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

// mcp_render_tool_result renders an Mcp_Tool_Result into a JSON-RPC success result:
// {content:[…],isError:<bool>} per the MCP CallToolResult shape. A domain failure
// rides here as a SUCCESSFUL JSON-RPC result with isError=true (the convention) —
// never a JSON-RPC error object. Each content block renders to its MCP wire shape
// (text ⇒ {type:"text",text:…}, image ⇒ {type:"image",data:…,mimeType:…}).
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
