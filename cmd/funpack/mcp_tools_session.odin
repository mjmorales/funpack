package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

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

	return mcp_tool_error(
		dispatch.id,
		Mcp_Error{category = .Internal, message = "session-family tool has no dispatch arm", detail = dispatch.name},
		allocator,
	), true
}

sess_owns_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "session"
}

sess_start :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	artifact, has_artifact := funpack_runtime.json_string_field(dispatch.arguments, "artifact")
	if !has_artifact {
		return mcp_tool_error(dispatch.id, mcp_missing_string_field("artifact", dispatch.name, allocator), allocator)
	}

	replay_log, has_replay := funpack_runtime.json_string_field(dispatch.arguments, "replay_log")

	seed_override: Maybe(i64)
	if seed, has_seed := sess_int_arg(dispatch.arguments, "seed"); has_seed {
		seed_override = seed
	}

	id, open_result := mcp_session_registry_open(dispatch.registry, artifact, replay_log, has_replay, "", allocator, seed_override)
	if open_result != .Ok {
		return mcp_tool_error(dispatch.id, sess_open_error(open_result, artifact, replay_log), allocator)
	}

	seed := funpack_runtime.NO_SEED
	if entry, found := mcp_session_registry_lookup(dispatch.registry, id); found {
		seed = entry.session.seed
	}

	body := sess_render_start_result(id, funpack_runtime.INTROSPECT_PROTOCOL_VERSION, seed, allocator)
	return mcp_text_result(dispatch.id, body, allocator)
}

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
	return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
}

sess_end :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	session_id, has_session := funpack_runtime.json_string_field(dispatch.arguments, "session_id")
	if !has_session {
		return mcp_tool_error(dispatch.id, mcp_missing_string_field("session_id", dispatch.name, allocator), allocator)
	}

	if !mcp_session_registry_end(dispatch.registry, session_id, allocator) {
		return mcp_tool_error(dispatch.id, mcp_unknown_session_error(session_id), allocator)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"session_id\":")
	funpack_runtime.write_json_string(&b, session_id)
	strings.write_string(&b, ",\"ended\":true}")
	return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
}

sess_render_start_result :: proc(
	id: string,
	negotiated_version: int,
	seed: funpack_runtime.Run_Seed,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"session_id\":")
	funpack_runtime.write_json_string(&b, id)
	strings.write_string(&b, ",\"negotiated_version\":")
	strings.write_int(&b, negotiated_version)
	strings.write_string(&b, ",\"seeded\":")
	strings.write_string(&b, seed.has_seed ? "true" : "false")
	strings.write_string(&b, ",\"seed\":")
	strings.write_i64(&b, seed.seed)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

sess_open_error :: proc(result: funpack_runtime.Open_Session_Result, artifact: string, replay_log: string) -> Mcp_Error {
	switch result {
	case .Ok:
		return Mcp_Error{category = .Internal, message = "open reported Ok on the failure path", detail = artifact}
	case .Artifact_Read_Failed:
		return Mcp_Error{category = .Resolver, message = "the artifact could not be read", detail = artifact}
	case .Session_Alloc_Failed:
		return Mcp_Error{category = .Internal, message = "the per-session arena could not be allocated", detail = artifact}
	case .Artifact_Malformed:
		return Mcp_Error{category = .Invalid_Input, message = "the artifact bytes did not parse as a funpack build", detail = artifact}
	case .Replay_Read_Failed:
		return Mcp_Error{category = .Resolver, message = "the replay log could not be read", detail = replay_log}
	case .Replay_Malformed:
		return Mcp_Error{category = .Invalid_Input, message = "the replay log did not parse", detail = replay_log}
	case .Replay_Identity_Mismatch:
		return Mcp_Error{category = .Invalid_Input, message = "the replay log was recorded against a different build or seed", detail = replay_log}
	}
	return Mcp_Error{category = .Internal, message = "unmapped open failure", detail = artifact}
}

sess_int_arg :: proc(arguments: json.Object, name: string) -> (value: i64, has: bool) {
	return funpack_runtime.json_int_field(arguments, name)
}
