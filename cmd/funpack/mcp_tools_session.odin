// The SESSION-LIFECYCLE tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns session_start / session_list /
// session_end. It is the family that drives the server-scoped session registry
// (mcp_session.odin) reached through dispatch.registry: session_start opens a session
// on a dedicated arena and returns its id, session_list reports the live entries,
// session_end is the arena_destroy teardown. This file is ONE dispatch seam — it owns
// ONLY this file's dispatch proc, never mcp_handle_tools_call. The registry
// INFRASTRUCTURE it drives lives in mcp_session.odin; this arm wires the three tools
// onto it.
//
// UNLIKE the observe/control families, these tools carry NO §28 request marshalling:
// they manage the registry DIRECTLY (open / enumerate / end), so the int-as-float arg
// trap that bites a §28 fold does not apply here — the only argument is a string
// (`artifact` for start, `session_id` for end). They are server-native tools (the
// generated Tool_Spec group is "session", session_scoped=false, command==name), so the
// claim test is on the spec's .group, never a §28 wire command (there is none).
//
// AUTH-FREE (the resolved ADR, operator-gated): the loopback-token apparatus existed
// only because attach opens a listening TCP port; stdio inverts that — the host forks
// the server and owns its inherited fds, so the peer is trusted. There is no token
// check on session_start; absolute stdout discipline is the sole hard transport
// invariant, owned by the JSON-RPC writer, not by this arm.
//
// NAMESPACE DISCIPLINE: every package-level proc/type/constant this file adds is
// prefixed `sess_` so package main has NO duplicate symbols when all six dispatch
// families merge (each family file owns its own prefix). The one EXCEPTION is the
// dispatch entry point mcp_session_tool_dispatch — its name is fixed by the chain in
// mcp_server.odin (MCP_DISPATCH_CHAIN) and must not change.
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

// mcp_session_tool_dispatch is the session family's arm. It claims session_start /
// session_list / session_end by their generated Tool_Spec .group ("session"), declining
// any other tool (handled=false) so the chain tries the next family. Each claimed tool
// drives dispatch.registry directly — open (returning {session_id, negotiated_version}),
// enumerate (returning the live entries), or end (arena_destroy teardown) — and renders
// the outcome as an MCP tool result. ANY open failure (artifact unreadable/malformed,
// replay mismatch, arena-at-cap) is the in-band IsError envelope with NO orphaned
// arena (mcp_session_registry_open destroys the arena before returning non-Ok), never a
// JSON-RPC error object. The dispatch hint is the spec's .group, so this arm cannot
// drift from the advertised tool set (the generated-projection contract).
mcp_session_tool_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if !sess_owns_command(dispatch.spec) {
		return "", false
	}

	switch dispatch.name {
	case "session_start":
		return sess_start(dispatch, allocator), true
	case "session_list":
		return sess_list(dispatch, allocator), true
	case "session_end":
		return sess_end(dispatch, allocator), true
	}

	// A tool in the "session" group this arm does not name is the family's own gap —
	// surfaced as an Internal fault rather than silently declined (a declined claimed
	// group would fall through the chain to the not-implemented stub, masking the gap).
	return sess_tool_error(
		dispatch.id,
		Mcp_Error{category = .Internal, message = "session-family tool has no dispatch arm", detail = dispatch.name},
		allocator,
	), true
}

// sess_owns_command is the family's claim test: it owns exactly the server-native
// session-lifecycle group. The check is on the generated Tool_Spec's .group ("session")
// — the dispatch family this arm declares — NOT on the tool name, so a renamed tool that
// keeps its group still routes here. Every OTHER group (inspect/time/control/oneshot/
// docs/screenshot) is owned by another family; this arm declines them so the chain
// reaches their file.
sess_owns_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "session"
}

// sess_start opens a fresh debug session over the `artifact` path and registers it,
// returning {session_id, negotiated_version} as the clean result. The negotiated version
// is the §28 protocol version the opened session speaks (INTROSPECT_PROTOCOL_VERSION) —
// the handle the model uses to confirm the wire contract every later session-scoped tool
// folds through. NO replay log (the contract carries only `artifact`, so has_replay is
// false — a fresh seedless window). An absent/non-string artifact is Invalid_Input; any
// non-Ok open is the runtime's discriminated failure mapped to its category, with NO
// orphaned arena (the registry open destroys the per-attempt arena before returning).
sess_start :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	artifact, has_artifact := sess_string_arg(dispatch.arguments, "artifact")
	if !has_artifact {
		return sess_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: artifact"},
			allocator,
		)
	}

	// Open ON a dedicated per-session arena (the F13 lifetime fix lives in the registry):
	// the session outlives this tool call. The registry struct + entry use the per-call
	// `allocator`; the session's own state (program, snapshots, COW chain) lives on the
	// arena the registry mints, reaped whole at session_end.
	id, open_result := mcp_session_registry_open(dispatch.registry, artifact, "", false, "", allocator)
	if open_result != .Ok {
		return sess_tool_error(dispatch.id, sess_open_error(open_result, artifact), allocator)
	}

	body := sess_render_start_result(id, funpack_runtime.INTROSPECT_PROTOCOL_VERSION, allocator)
	return sess_text_result(dispatch.id, body, allocator)
}

// sess_list enumerates every live session in the registry as a clean result —
// {"sessions":[{session_id,label},…]} — the model's reach into what is currently open.
// It takes no arguments (the generated Tool_Spec carries an empty arg set), drives the
// registry map directly (no §28 fold), and is always a clean result (an empty registry
// is the empty array, never an error). The label is the optional caller-supplied name
// carried on each entry; when session_start opens without one it is the empty string.
sess_list :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"sessions\":[")
	first := true
	for id, entry in dispatch.registry.entries {
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		strings.write_string(&b, "{\"session_id\":")
		funpack_runtime.write_json_string(&b, id)
		strings.write_string(&b, ",\"label\":")
		funpack_runtime.write_json_string(&b, entry.label)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return sess_text_result(dispatch.id, strings.to_string(b), allocator)
}

// sess_end tears a named session down — arena_destroy frees its WHOLE graph in one free
// (mcp_session_registry_end), returning {session_id,ended:true} as the clean ack. An
// absent/non-string session_id is Invalid_Input; an id the registry never minted (or a
// double-end) is the Session-category refusal, never a fault — the registry's
// idempotent found=false contract maps to a clean in-band error the model reads and
// moves past (the session is already gone, which is what the caller wanted).
sess_end :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	session_id, has_session := sess_string_arg(dispatch.arguments, "session_id")
	if !has_session {
		return sess_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: session_id"},
			allocator,
		)
	}

	if !mcp_session_registry_end(dispatch.registry, session_id, allocator) {
		return sess_tool_error(
			dispatch.id,
			Mcp_Error{category = .Session, message = "unknown session id", detail = session_id},
			allocator,
		)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"session_id\":")
	funpack_runtime.write_json_string(&b, session_id)
	strings.write_string(&b, ",\"ended\":true}")
	return sess_text_result(dispatch.id, strings.to_string(b), allocator)
}

// sess_render_start_result renders the session_start clean result body —
// {"session_id":…,"negotiated_version":N} — built with the same strings.Builder +
// write_json_string idiom the §28 envelope renderers use (introspect.odin), so the
// body is byte-stable. The id is a string handle; negotiated_version is the §28 protocol
// integer the session speaks (so an integer, never a float — the model reads it raw).
sess_render_start_result :: proc(id: string, negotiated_version: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"session_id\":")
	funpack_runtime.write_json_string(&b, id)
	strings.write_string(&b, ",\"negotiated_version\":")
	strings.write_int(&b, negotiated_version)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// sess_open_error maps a runtime Open_Session_Result failure to the MCP error vocabulary
// (mcp_error.odin). A read/IO/arena-cap failure is Resolver (the artifact or replay log
// could not be resolved off disk, or the per-session arena could not be minted — the
// at-cap path); a malformed/identity-mismatched artifact is Invalid_Input (the bytes the
// caller pointed at are out of contract). The offending path rides in the detail so the
// model self-corrects. The switch is exhaustive (no default) so a new Open_Session_Result
// without a mapping is a compile error — the closed-enum discipline.
sess_open_error :: proc(result: funpack_runtime.Open_Session_Result, artifact: string) -> Mcp_Error {
	switch result {
	case .Ok:
		// Unreachable: sess_start only calls this on a non-Ok result. Mapped defensively.
		return Mcp_Error{category = .Internal, message = "open reported Ok on the failure path", detail = artifact}
	case .Artifact_Read_Failed:
		return Mcp_Error{category = .Resolver, message = "the artifact could not be read (or the session arena could not be allocated)", detail = artifact}
	case .Artifact_Malformed:
		return Mcp_Error{category = .Invalid_Input, message = "the artifact bytes did not parse as a funpack build", detail = artifact}
	case .Replay_Read_Failed:
		return Mcp_Error{category = .Resolver, message = "the replay log could not be read", detail = artifact}
	case .Replay_Malformed:
		return Mcp_Error{category = .Invalid_Input, message = "the replay log did not parse", detail = artifact}
	case .Replay_Identity_Mismatch:
		return Mcp_Error{category = .Invalid_Input, message = "the replay log was recorded against a different build or seed", detail = artifact}
	}
	return Mcp_Error{category = .Internal, message = "unmapped open failure", detail = artifact}
}

// sess_string_arg reads a required string argument off the MCP arguments object. Absent
// or non-string is has=false — the arm renders the Invalid_Input refusal naming the
// argument. The mirror of obs_session_id, generalized to any string arg (artifact for
// start, session_id for end).
sess_string_arg :: proc(arguments: json.Object, name: string) -> (value: string, has: bool) {
	field, present := arguments[name]
	if !present {
		return "", false
	}
	text, is_string := field.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}

// sess_text_result renders a clean (not IsError) tool result carrying one Text content
// block — the structured payload the model reads (the start/list/end result bodies). The
// thin wrapper keeps each arm reading by intent.
sess_text_result :: proc(id: Mcp_Id, text: string, allocator := context.allocator) -> string {
	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(text)
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}

// sess_tool_error renders a domain failure as the in-band IsError tool result (the
// mcp_error.odin convention — a SUCCESSFUL tools/call carrying isError=true, never a
// JSON-RPC error object). The thin wrapper keeps the dispatch arm reading by intent.
sess_tool_error :: proc(id: Mcp_Id, err: Mcp_Error, allocator := context.allocator) -> string {
	return mcp_render_tool_result(id, mcp_tool_error_result(err, allocator), allocator)
}
