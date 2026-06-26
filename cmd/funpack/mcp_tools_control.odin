// The CONTROL + SELF-HEAL tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns the §28 control commands (branch,
// checkout, inject_input, set, spawn, despawn, emit, reload) plus the observe-class
// self-heal pair (capture_test, audit) over a NAMED session. A control command
// PERTURBS, so it forks the session's branch head as per-session mutable state —
// committed THROUGH the session arena (mcp_session_registry_request, the F13
// retention rule in mcp_session.odin) so a LATER request reads it back. This file is
// ONE dispatch seam: it owns ONLY this file's dispatch proc, never
// mcp_handle_tools_call — that is how the six families stay independent.
//
// THE FOLD (every tool here is one shape, control and self-heal alike): match the MCP
// tool name → its §28 command, pull the universal session_id selector, re-render the
// REMAINING MCP arguments as the §28 `args` object, and fold the assembled line
// `{"id":1,"cmd":"<command>","args":{…}}` through mcp_session_registry_request on the
// session's arena. control_request (runtime/introspect_control.odin) forks onto a
// Session_Branch and answers branch/active/warranted; spawn/despawn answer the minted
// /removed instance; checkout flips the active lineage. The §28 response is lifted
// VERBATIM into the MCP result — `ok:true` becomes a text content block carrying the
// branch position + warranty + instance the agent self-heals from; `ok:false` becomes
// the IsError envelope (mcp_error.odin) keyed .Exec, never a JSON-RPC error object.
//
// THE INTEGER-PRESERVING RE-RENDER (the subtle correctness crux): the MCP arguments
// object is parsed with parse_integers=true (mcp_jsonrpc.odin), so an integer arg
// (tick, instance, ticks) arrives as json.Integer. session_request RE-PARSES the line
// we hand it, also with parse_integers=true, and json_int_field then demands a
// json.Integer. json.marshal would render an i64 as a float ("3.0000…"), which
// re-parses as json.Float and silently fails every int arg — so we re-render with
// ctrl_write_json_value, the inverse of the parser that keeps a json.Integer a BARE
// integer and round-trips cleanly through session_request.
package main

import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strconv"
import "core:strings"

// CTRL_REQUEST_ID is the §28 correlation id every control/self-heal line stamps. The
// id is opaque to MCP — session_request echoes it back and we never read it (the MCP
// layer correlates by the JSON-RPC envelope id, not this). A fixed value is correct:
// a session serializes its requests (mcp_session.odin), so there is no in-flight id
// to disambiguate.
CTRL_REQUEST_ID :: 1

// mcp_control_dispatch is the control + self-heal family's arm. It CLAIMS its eleven
// tools (the eight §28 control commands plus capture_test / capture_tick / audit), folding each
// through the named session, and returns handled=false for any tool it does not own
// so the call flows on down the chain (the stub contract every family keeps). The map
// from MCP tool name → §28 command is exactly the generated Tool_Spec.command field
// (api_contract.gen.odin), so the dispatch cannot drift from the advertised schema.
mcp_control_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	command: string
	switch dispatch.name {
	case "control_branch":
		command = "branch"
	case "control_checkout":
		command = "checkout"
	case "control_inject_input":
		command = "inject_input"
	case "control_set":
		command = "set"
	case "control_spawn":
		command = "spawn"
	case "control_despawn":
		command = "despawn"
	case "control_emit":
		command = "emit"
	case "control_reload":
		command = "reload"
	case "capture_test":
		command = "capture_test"
	case "capture_tick":
		command = "capture_tick"
	case "audit":
		command = "audit"
	case:
		// Not one of this family's tools — decline so the next arm in the chain tries.
		return "", false
	}
	return ctrl_fold_session_command(dispatch, command, allocator), true
}

// ctrl_fold_session_command is the one shape every tool in this family takes: pull the
// universal session_id selector off the MCP arguments, build the §28 request line from
// the remaining arguments, fold it through the named session's arena, and lift the §28
// response into the MCP result. A missing/non-string session_id is an Invalid_Input
// refusal (the schema's required field); an unknown/ended session id is a Session
// refusal (the stale-session path mcp_session_registry_request signals with
// found=false). Both ride the IsError envelope, never a JSON-RPC error object.
ctrl_fold_session_command :: proc(dispatch: Mcp_Dispatch, command: string, allocator := context.allocator) -> string {
	session_id, has_session := funpack_runtime.json_string_field(dispatch.arguments, "session_id")
	if !has_session {
		return mcp_render_tool_result(
			dispatch.id,
			mcp_tool_error_result(mcp_missing_string_field("session_id", dispatch.name, allocator), allocator),
			allocator,
		)
	}

	line := ctrl_build_request_line(command, dispatch.arguments, allocator)
	response, found := mcp_session_registry_request(dispatch.registry, session_id, line)
	if !found {
		return mcp_render_tool_result(
			dispatch.id,
			mcp_tool_error_result(mcp_unknown_session_error(session_id), allocator),
			allocator,
		)
	}
	return mcp_render_tool_result(dispatch.id, ctrl_lift_response(response, command, allocator), allocator)
}

// ctrl_build_request_line assembles the §28 request line a control/self-heal command
// folds through session_request: `{"id":1,"cmd":"<command>","args":{<args>}}`. The
// args object is the MCP arguments object MINUS the universal session_id selector
// (session_id is the MCP handle, not a §28 arg) — every OTHER field passes through
// verbatim as the §28 wire arg (the schema arg names ARE the §28 arg names, the
// generated-projection invariant). Re-rendered with ctrl_write_json_value so a
// json.Integer stays a bare integer and round-trips through the re-parse.
ctrl_build_request_line :: proc(command: string, arguments: json.Object, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"id\":")
	strings.write_int(&b, CTRL_REQUEST_ID)
	strings.write_string(&b, ",\"cmd\":")
	funpack_runtime.write_json_string(&b, command)
	strings.write_string(&b, ",\"args\":{")
	first := true
	for key, value in arguments {
		if key == "session_id" {
			continue
		}
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		funpack_runtime.write_json_string(&b, key)
		strings.write_byte(&b, ':')
		ctrl_write_json_value(&b, value)
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// ctrl_write_json_value renders one parsed json.Value back to its wire form — the
// inverse of json.parse, written here because json.marshal renders a json.Integer as
// a float ("3.0000…") which would re-parse as json.Float and break every §28 int arg
// (the integer-preserving crux this family's header documents). The switch is
// exhaustive over the json.Value union so a new variant is a compile error. Numbers:
// an Integer is bare i64 text, a Float renders through strconv (the rare analog-free
// case — §28 ints arrive as json.Integer, so a Float here is a genuine fractional arg).
ctrl_write_json_value :: proc(b: ^strings.Builder, value: json.Value) {
	switch v in value {
	case json.Null:
		strings.write_string(b, "null")
	case json.Integer:
		strings.write_i64(b, i64(v))
	case json.Float:
		buf: [32]u8
		strings.write_string(b, strconv.write_float(buf[:], f64(v), 'g', -1, 64))
	case json.Boolean:
		strings.write_string(b, v ? "true" : "false")
	case json.String:
		funpack_runtime.write_json_string(b, string(v))
	case json.Array:
		strings.write_byte(b, '[')
		for element, i in v {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			ctrl_write_json_value(b, element)
		}
		strings.write_byte(b, ']')
	case json.Object:
		strings.write_byte(b, '{')
		first := true
		for key, nested in v {
			if !first {
				strings.write_byte(b, ',')
			}
			first = false
			funpack_runtime.write_json_string(b, key)
			strings.write_byte(b, ':')
			ctrl_write_json_value(b, nested)
		}
		strings.write_byte(b, '}')
	}
}

// ctrl_lift_response lifts a §28 response line into the MCP tool result. The §28
// envelope already carries everything the agent self-heals from — for a control
// command the branch position + `"warranted":false`, for checkout the active lineage +
// its warranty, for spawn/despawn the minted/removed instance, for capture_test the
// generated test source, for audit the divergence-first-tick — so a clean `ok:true`
// response rides VERBATIM as one text content block (the agent reads the §28 result
// object directly). An `ok:false` refusal is re-cast as the IsError envelope keyed
// .Refused (a control command that resolved but refused: tick out of range, unknown
// thing, a reload migration refusal) carrying the §28 `error` message, so the model
// sees the session is healthy and the command was declined — fix the command, not the
// session — and self-corrects rather than reading a raw §28 line.
ctrl_lift_response :: proc(response: string, command: string, allocator := context.allocator) -> Mcp_Tool_Result {
	parsed, ok_field, error_text := ctrl_parse_response(response, allocator)
	if parsed && ok_field {
		content := make([]Mcp_Content, 1, allocator)
		content[0] = mcp_text_content(response)
		return Mcp_Tool_Result{content = content, is_error = false}
	}
	// A refusal (ok:false) or an unparseable line: surface the engine's own `error` text
	// when present, else a generic refusal. An unparseable line falls here too (the prior
	// two-parse pair also treated it as a refusal), so a malformed engine line never crashes.
	message := error_text
	if message == "" {
		message = "control command refused"
	}
	return mcp_tool_error_result(Mcp_Error{category = .Refused, message = message, detail = command}, allocator)
}

// ctrl_parse_response parses one §28 control response line ONCE into its (ok, error)
// parts — the single parse the lift's success/refusal split AND the refusal message both
// read, replacing the former two-parse pair (ctrl_response_ok then ctrl_response_error
// over the SAME line, which parsed every refusal twice with disagreeing allocator
// discipline). parsed=false for a line that is not a JSON object; on ok:true the caller
// lifts the line verbatim; on ok:false `error_text` is the runtime's refusal string (or
// "" when absent/non-string — the caller substitutes a default). error_text points into
// the parsed tree on `allocator` (the per-request arena), valid for the request's
// lifetime — no clone, no destroy. Mirrors shot_parse_response (mcp_tools_screenshot.odin).
ctrl_parse_response :: proc(response: string, allocator := context.allocator) -> (parsed: bool, ok_field: bool, error_text: string) {
	value, parse_err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return false, false, ""
	}
	object, is_object := value.(json.Object)
	if !is_object {
		return false, false, ""
	}
	if flag, has_ok := object["ok"]; has_ok {
		if boolean, is_bool := flag.(json.Boolean); is_bool {
			ok_field = bool(boolean)
		}
	}
	if !ok_field {
		error_text, _ = funpack_runtime.json_string_field(object, "error")
	}
	return true, ok_field, error_text
}

// ctrl_tool_command maps an MCP tool name in this family to its §28 command, mirroring
// the dispatch switch — exposed as a pure proc so the family's tests assert the
// name→command projection against the generated Tool_Spec.command without re-running a
// session. has=false for a tool outside this family (the decline path).
ctrl_tool_command :: proc(tool_name: string) -> (command: string, has: bool) {
	switch tool_name {
	case "control_branch":
		return "branch", true
	case "control_checkout":
		return "checkout", true
	case "control_inject_input":
		return "inject_input", true
	case "control_set":
		return "set", true
	case "control_spawn":
		return "spawn", true
	case "control_despawn":
		return "despawn", true
	case "control_emit":
		return "emit", true
	case "control_reload":
		return "reload", true
	case "capture_test":
		return "capture_test", true
	case "capture_tick":
		return "capture_tick", true
	case "audit":
		return "audit", true
	}
	return "", false
}

// ctrl_family_tools is this family's tool roster — the eleven tools mcp_control_dispatch
// claims. Kept as a package-level table the family's tests walk (assert each is in
// TOOL_SPECS, assert ctrl_tool_command resolves it, assert no other family's tool is
// in the set), so the roster has one source the dispatch and the tests share.
ctrl_family_tools := [?]string {
	"control_branch",
	"control_checkout",
	"control_inject_input",
	"control_set",
	"control_spawn",
	"control_despawn",
	"control_emit",
	"control_reload",
	"capture_test",
	"capture_tick",
	"audit",
}

// ctrl_assert_specs_present confirms every ctrl_family_tools entry resolves to a real
// generated Tool_Spec (the name→spec projection guard the family test walks): if a
// tool name here is not in TOOL_SPECS, the dispatch claims a tool tools/list never
// advertised. Kept tiny and pure so it is a test helper, not a runtime path.
ctrl_assert_specs_present :: proc() -> bool {
	for tool in ctrl_family_tools {
		_, found := mcp_lookup_tool(tool)
		if !found {
			return false
		}
	}
	return true
}
