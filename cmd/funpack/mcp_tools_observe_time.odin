// The OBSERVE + TIME-TRAVEL tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns the §28 observe commands (pipeline,
// signals, trace, diff, replay_behavior, draw_list) and the time-travel commands
// (load, run, pause, step, rewind, reset, status) over a NAMED session. Each tool here
// marshals its args into a §28 request line and folds it through
// mcp_session_registry_request (mcp_session.odin) on the session's arena, lifting the
// result back into the MCP result. This file is ONE dispatch seam — it owns ONLY this
// file's dispatch proc, never mcp_handle_tools_call.
//
// THE FAMILY IS PURE RE-FOLD READS: every command here is class "observe" (the
// generated Tool_Spec, api_contract.gen.odin) — observe re-folds a recorded tick and
// time-travel only moves the cursor / forks no canonical state. So this arm threads the
// optional `branch` selector through verbatim and NEVER mutates Debug_Session directly:
// the runtime's session_request owns the fold (the engine boundary — the model reads,
// the engine folds). The control (perturbing) tools live in the SEPARATE control family
// (mcp_tools_control.odin); this arm declines any tool it does not own (handled=false).
//
// NAMESPACE DISCIPLINE: every package-level proc/type/constant this file adds is
// prefixed `obs_` so package main has NO duplicate symbols when all six dispatch
// families merge (each family file owns its own prefix). The one EXCEPTION is the
// dispatch entry point mcp_observe_time_dispatch — its name is fixed by the chain in
// mcp_server.odin (MCP_DISPATCH_CHAIN) and must not change.
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

// OBS_TOOL_REQUEST_ID is the §28 envelope id stamped on every request this family
// folds through a session. The MCP boundary correlates a tool call by its JSON-RPC id
// (the OUTER envelope, mcp_jsonrpc.odin) — the INNER §28 id is single-shot per fold
// (one request, one response, awaited inline by mcp_session_registry_request), so a
// fixed id is sufficient and keeps the request line byte-stable. It is not zero so a
// refusal echoing it is distinguishable from the malformed-line id-0 case.
OBS_TOOL_REQUEST_ID :: 1

// mcp_observe_time_dispatch is the observe+time family's arm. It claims the §28 observe
// commands (signals/pipeline/trace/diff/replay_behavior/draw_list) and the time-travel
// commands (load/run/pause/step/rewind/reset/status) by their generated Tool_Spec
// .command, declining any other tool (handled=false) so the chain tries the next family.
// For a claimed tool it resolves the named session, builds the §28 request line from the
// MCP arguments, folds it through the registry on the session arena, and lifts the §28
// result back into the MCP tool result — an unknown session id is the Session-category
// refusal, a §28 ok:false is the runtime's refusal text, an ok:true lifts the result
// object verbatim. The dispatch hint is the spec's .command (the §28 wire name), so this
// arm cannot drift from the advertised tool set (the generated-projection contract).
mcp_observe_time_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if !obs_owns_command(dispatch.spec) {
		return "", false
	}

	// Resolve the named session up front: an unknown/ended id is the Session-category
	// refusal (never a fabricated session), exactly the registry's found=false contract.
	session_id, has_session := obs_session_id(dispatch.arguments)
	if !has_session {
		return obs_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: session_id"},
			allocator,
		), true
	}
	if _, found := mcp_session_registry_lookup(dispatch.registry, session_id); !found {
		return obs_tool_error(
			dispatch.id,
			Mcp_Error{category = .Session, message = "unknown session id", detail = session_id},
			allocator,
		), true
	}

	// Build the §28 request line from the MCP arguments (session_id dropped — it keys
	// the session, it is not a §28 arg) and fold it on the SESSION arena. The fold's
	// allocator is the session's, owned by mcp_session_registry_request (the F13
	// retention rule); the LINE itself is built on the per-call `allocator` (scratch).
	line := obs_build_request_line(dispatch.spec.command, dispatch.arguments, allocator)
	response, found := mcp_session_registry_request(dispatch.registry, session_id, line)
	if !found {
		// The session vanished between the lookup and the fold (it cannot, single-
		// threaded per session, but the contract is honored, not assumed).
		return obs_tool_error(
			dispatch.id,
			Mcp_Error{category = .Session, message = "unknown session id", detail = session_id},
			allocator,
		), true
	}

	return obs_lift_response(dispatch.id, dispatch.spec.command, response, allocator), true
}

// obs_owns_command is the family's claim test: it owns exactly the §28 observe-class
// commands the inspect/time groups declare. The check is on the generated Tool_Spec's
// .group (inspect / time) — the two §28 groups this family dispatches — NOT on the tool
// name, so a renamed tool that keeps its group still routes here. The break/self_heal
// observe groups (break/watch/clear, capture_test/audit) and the control group are owned
// by OTHER families; this arm declines them so the chain reaches their file.
obs_owns_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "inspect" || spec.group == "time"
}

// obs_session_id reads the required session_id off the MCP arguments object. Absent or
// non-string is has=false — the arm renders the Invalid_Input refusal (the session
// handle is the one universally-required arg, SESSION_ID_ARG in every spec).
obs_session_id :: proc(arguments: json.Object) -> (id: string, has: bool) {
	field, present := arguments["session_id"]
	if !present {
		return "", false
	}
	text, is_string := field.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}

// obs_build_request_line renders one §28 request line for a command, projecting the MCP
// arguments (minus session_id) into the `args` object. The session_id keys the live
// session — it is NOT a §28 wire arg, so it is dropped here. Every OTHER argument the
// tool carried passes through verbatim by its JSON type (tick/from/to/until as integers,
// behavior/branch as strings, include_drawlist as a boolean) so the §28 arg names ARE
// the MCP arg names (the generated-projection contract — no per-arg translation table).
// An empty args object is elided (a no-arg command like pipeline sends just {id,cmd}),
// matching session_request's optional-args read (introspect.odin).
obs_build_request_line :: proc(command: string, arguments: json.Object, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"id\":")
	strings.write_int(&b, OBS_TOOL_REQUEST_ID)
	strings.write_string(&b, ",\"cmd\":")
	funpack_runtime.write_json_string(&b, command)

	// Project every non-session_id argument into the §28 args object, preserving its
	// JSON type. The order is the map's iteration order — irrelevant to the §28 reader
	// (it reads args by key, introspect.odin json_*_field), and the request line is not
	// part of the byte-stable §28 RESPONSE log (only the response envelope is, :997).
	first := true
	for key, value in arguments {
		if key == "session_id" {
			continue
		}
		if first {
			strings.write_string(&b, ",\"args\":{")
			first = false
		} else {
			strings.write_byte(&b, ',')
		}
		funpack_runtime.write_json_string(&b, key)
		strings.write_byte(&b, ':')
		obs_write_json_value(&b, value)
	}
	if !first {
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// obs_write_json_value renders one parsed JSON value back to its wire form for the §28
// args object. The argument types the observe/time tools carry are the scalar set
// (integer/float/string/boolean/null); objects and arrays pass through via json.marshal
// (no observe/time arg uses them today, but the projection stays total so a future arg
// shape needs no change here). Integers render as integers (the parse used
// parse_integers=true, mcp_jsonrpc.odin), so a §10 tick never becomes a float.
obs_write_json_value :: proc(b: ^strings.Builder, value: json.Value) {
	switch v in value {
	case json.Integer:
		strings.write_i64(b, i64(v))
	case json.Float:
		strings.write_f64(b, f64(v), 'g')
	case json.String:
		funpack_runtime.write_json_string(b, string(v))
	case json.Boolean:
		strings.write_string(b, v ? "true" : "false")
	case json.Null:
		strings.write_string(b, "null")
	case json.Object, json.Array:
		// No observe/time arg is a container today; marshal keeps the projection total.
		if bytes, err := json.marshal(value, {}, context.temp_allocator); err == nil {
			strings.write_bytes(b, bytes)
		} else {
			strings.write_string(b, "null")
		}
	}
}

// obs_lift_response lifts a §28 response line into an MCP tool result. The §28 envelope
// is the dual of the MCP one: ok:true carries a `result` object (lifted VERBATIM into a
// Text content block — the structured payload the model reads), ok:false carries an
// `error` string (mapped to a Session-category IsError envelope — the runtime's refusal
// the model self-corrects from, e.g. "tick out of range", "no timeline loaded"). A
// response the server cannot parse, or an ok:true with no result, is an Internal fault
// (the runtime broke its own §28 contract) — surfaced, never masked. This is the Go
// path's mapResponseError + decodeResult collapsed into one lift, MINUS the per-tool
// typed structs (the ADR lifts the result object verbatim, no re-typing).
obs_lift_response :: proc(id: Mcp_Id, command: string, response: string, allocator := context.allocator) -> string {
	parsed, parse_err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return obs_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response was not valid JSON", detail = command},
			allocator,
		)
	}
	envelope, is_object := parsed.(json.Object)
	if !is_object {
		return obs_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response was not a JSON object", detail = command},
			allocator,
		)
	}

	ok_field, has_ok := envelope["ok"]
	ok_bool, ok_is_bool := ok_field.(json.Boolean)
	if !has_ok || !ok_is_bool {
		return obs_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response missing ok field", detail = command},
			allocator,
		)
	}

	if !bool(ok_bool) {
		// A §28 refusal: the runtime declined the command (bad tick, unknown behavior,
		// unsupported branch refold, no timeline loaded). Surface its text as a Session-
		// category refusal so the model reads the reason and retries with corrected args.
		message := strings.concatenate({command, ": runtime refused the command"}, allocator)
		if error_field, has_error := envelope["error"]; has_error {
			if error_text, error_is_string := error_field.(json.String); error_is_string {
				message = string(error_text)
			}
		}
		return obs_tool_error(id, Mcp_Error{category = .Session, message = message}, allocator)
	}

	// ok:true — lift the `result` object verbatim into a Text content block. A missing
	// result on an ok response is the runtime breaking its own contract (Internal).
	result_field, has_result := envelope["result"]
	if !has_result {
		return obs_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session ok response carried no result", detail = command},
			allocator,
		)
	}
	result_json, marshal_err := json.marshal(result_field, {}, allocator)
	if marshal_err != nil {
		return obs_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "rendering the session result failed", detail = command},
			allocator,
		)
	}

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(string(result_json))
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}

// obs_tool_error renders a domain failure as the in-band IsError tool result (the
// mcp_error.odin convention — a SUCCESSFUL tools/call carrying isError=true, never a
// JSON-RPC error object). The thin wrapper keeps the dispatch arm reading by intent.
obs_tool_error :: proc(id: Mcp_Id, err: Mcp_Error, allocator := context.allocator) -> string {
	return mcp_render_tool_result(id, mcp_tool_error_result(err, allocator), allocator)
}
