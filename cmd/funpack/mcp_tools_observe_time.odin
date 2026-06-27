package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

OBS_TOOL_REQUEST_ID :: 1

mcp_observe_time_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if !obs_owns_command(dispatch.spec) {
		return "", false
	}

	session_id, has_session := funpack_runtime.json_string_field(dispatch.arguments, "session_id")
	if !has_session {
		return mcp_tool_error(dispatch.id, mcp_missing_string_field("session_id", dispatch.name, allocator), allocator), true
	}
	if _, found := mcp_session_registry_lookup(dispatch.registry, session_id); !found {
		return mcp_tool_error(dispatch.id, mcp_unknown_session_error(session_id), allocator), true
	}

	line := obs_build_request_line(dispatch.spec.command, dispatch.arguments, allocator)
	response, found := mcp_session_registry_request(dispatch.registry, session_id, line)
	if !found {
		return mcp_tool_error(dispatch.id, mcp_unknown_session_error(session_id), allocator), true
	}

	if obs_enriches_command(dispatch.spec) {
		precondition := obs_read_precondition(dispatch.registry, session_id, allocator)
		return obs_lift_inspect_response(dispatch.id, dispatch.spec.command, response, precondition, allocator), true
	}

	if obs_enriches_status(dispatch.spec) {
		return obs_lift_status_response(dispatch.id, dispatch.spec.command, response, allocator), true
	}

	return obs_lift_response(dispatch.id, dispatch.spec.command, response, allocator), true
}

obs_enriches_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "inspect" && spec.command != "screenshot"
}

obs_enriches_status :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "time" && spec.command == "status"
}

obs_owns_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "inspect" || spec.group == "time"
}

obs_build_request_line :: proc(command: string, arguments: json.Object, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"id\":")
	strings.write_int(&b, OBS_TOOL_REQUEST_ID)
	strings.write_string(&b, ",\"cmd\":")
	funpack_runtime.write_json_string(&b, command)

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
		if bytes, err := json.marshal(value, {}, context.temp_allocator); err == nil {
			strings.write_bytes(b, bytes)
		} else {
			strings.write_string(b, "null")
		}
	}
}

Obs_Envelope_Kind :: enum {
	Ok,
	Refusal,
	Fault,
}

obs_parse_envelope :: proc(
	response: string,
	command: string,
	allocator := context.allocator,
) -> (kind: Obs_Envelope_Kind, result_obj: json.Object, refusal_msg: string, result_json: string) {
	parsed, parse_err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return .Fault, nil, "session response was not valid JSON", ""
	}
	envelope, is_object := parsed.(json.Object)
	if !is_object {
		return .Fault, nil, "session response was not a JSON object", ""
	}
	ok_field, has_ok := envelope["ok"]
	ok_bool, ok_is_bool := ok_field.(json.Boolean)
	if !has_ok || !ok_is_bool {
		return .Fault, nil, "session response missing ok field", ""
	}
	if !bool(ok_bool) {
		message := strings.concatenate({command, ": runtime refused the command"}, allocator)
		if error_field, has_error := envelope["error"]; has_error {
			if error_text, error_is_string := error_field.(json.String); error_is_string {
				message = string(error_text)
			}
		}
		return .Refusal, nil, message, ""
	}
	result_field, has_result := envelope["result"]
	result_object, result_is_object := result_field.(json.Object)
	if !has_result || !result_is_object {
		return .Fault, nil, "session ok response carried no result object", ""
	}
	result_bytes, marshal_err := json.marshal(result_field, {}, allocator)
	if marshal_err != nil {
		return .Fault, nil, "rendering the session result failed", ""
	}
	return .Ok, result_object, "", string(result_bytes)
}

obs_lift_response :: proc(id: Mcp_Id, command: string, response: string, allocator := context.allocator) -> string {
	kind, _, refusal_msg, result_json := obs_parse_envelope(response, command, allocator)
	if kind == .Fault {
		return mcp_tool_error(id, Mcp_Error{category = .Internal, message = refusal_msg, detail = command}, allocator)
	}
	if kind == .Refusal {
		return mcp_tool_error(id, Mcp_Error{category = .Refused, message = refusal_msg}, allocator)
	}
	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(result_json)
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}

Obs_Precondition :: struct {
	known:          bool,
	loaded:         bool,
	seeded:         bool,
	uses_rng:       bool,
	ticks_recorded: i64,
}

obs_read_precondition :: proc(reg: ^Mcp_Session_Registry, session_id: string, allocator := context.allocator) -> Obs_Precondition {
	line := "{\"id\":1,\"cmd\":\"status\"}"
	response, found := mcp_session_registry_request(reg, session_id, line)
	if !found {
		return Obs_Precondition{known = false}
	}
	parsed, parse_err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return Obs_Precondition{known = false}
	}
	envelope, is_object := parsed.(json.Object)
	if !is_object {
		return Obs_Precondition{known = false}
	}
	result_field, has_result := envelope["result"]
	result, result_is_object := result_field.(json.Object)
	if !has_result || !result_is_object {
		return Obs_Precondition{known = false}
	}
	pre := Obs_Precondition {
		known = true,
	}
	if loaded, ok := result["loaded"].(json.Boolean); ok {
		pre.loaded = bool(loaded)
	}
	if seeded, ok := result["seeded"].(json.Boolean); ok {
		pre.seeded = bool(seeded)
	}
	if uses_rng, ok := result["uses_rng"].(json.Boolean); ok {
		pre.uses_rng = bool(uses_rng)
	}
	if ticks, ok := result["ticks_recorded"].(json.Integer); ok {
		pre.ticks_recorded = i64(ticks)
	}
	return pre
}

obs_inspect_collection_key :: proc(command: string) -> (key: string, has: bool) {
	switch command {
	case "state", "replay_behavior":
		return "instances", true
	case "signals":
		return "routes", true
	case "trace", "pipeline":
		return "steps", true
	case "draw_list":
		return "commands", true
	case "diff":
		return "tables", true
	}
	return "", false
}

obs_result_collection_empty :: proc(command: string, result: json.Object) -> bool {
	key, has_key := obs_inspect_collection_key(command)
	if !has_key {
		return false
	}
	field, present := result[key]
	if !present {
		return false
	}
	array, is_array := field.(json.Array)
	if !is_array {
		return false
	}
	return len(array) == 0
}

obs_precondition_diagnostic :: proc(pre: Obs_Precondition) -> (diagnostic: string, next_action: string, has: bool) {
	if !pre.known {
		return "", "", false
	}
	if pre.ticks_recorded <= 0 {
		return "the session has no recorded ticks, so there is no simulated timeline to inspect",
			"run the timeline forward (time_load then time_run) or attach over a recording before inspecting",
			true
	}
	if pre.uses_rng && !pre.seeded {
		return "the session is seedless: this game draws RNG, but a fresh session_start opens without a recorded RNG seed, so an RNG-driven setup (e.g. a spawn-on-start swarm) never populates and every inspect_* reads empty — this is distinct from a genuinely-empty tick",
			"re-open the session over a recorded replay log (session_start with a recording that pins the seed) to reproduce the seeded run, or use control_spawn / control_set to populate the state you want to inspect",
			true
	}
	if !pre.uses_rng {
		return "this game uses no RNG (no behavior or function draws from an Rng), so a missing seed cannot explain the empty result — the inspected tick genuinely produced no instances for this thing",
			"verify the thing name and tick, or use control_spawn / control_set to populate the state you want to inspect",
			true
	}
	return "", "", false
}

obs_lift_inspect_response :: proc(
	id: Mcp_Id,
	command: string,
	response: string,
	precondition: Obs_Precondition,
	allocator := context.allocator,
) -> string {
	kind, result_object, refusal_msg, result_json := obs_parse_envelope(response, command, allocator)
	if kind == .Fault {
		return mcp_tool_error(id, Mcp_Error{category = .Internal, message = refusal_msg, detail = command}, allocator)
	}
	if kind == .Refusal {
		return mcp_tool_error(id, Mcp_Error{category = .Refused, message = refusal_msg}, allocator)
	}

	empty := obs_result_collection_empty(command, result_object)
	diagnostic, next_action, has_diagnostic := obs_precondition_diagnostic(precondition)
	attach_diagnostic := empty && has_diagnostic

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"result\":")
	strings.write_string(&b, result_json)
	if precondition.known {
		strings.write_string(&b, ",\"precondition\":{\"seeded\":")
		strings.write_string(&b, precondition.seeded ? "true" : "false")
		strings.write_string(&b, ",\"uses_rng\":")
		strings.write_string(&b, precondition.uses_rng ? "true" : "false")
		strings.write_string(&b, ",\"loaded\":")
		strings.write_string(&b, precondition.loaded ? "true" : "false")
		strings.write_string(&b, ",\"ticks_recorded\":")
		strings.write_i64(&b, precondition.ticks_recorded)
		strings.write_byte(&b, '}')
	}
	if attach_diagnostic {
		strings.write_string(&b, ",\"diagnostic\":")
		funpack_runtime.write_json_string(&b, diagnostic)
		strings.write_string(&b, ",\"next_action\":")
		funpack_runtime.write_json_string(&b, next_action)
	}
	strings.write_byte(&b, '}')

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(strings.to_string(b))
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}

OBS_STATUS_LOAD_NEXT_ACTION :: "time_load — arm the timeline before time_step / inspect_*"

obs_lift_status_response :: proc(id: Mcp_Id, command: string, response: string, allocator := context.allocator) -> string {
	kind, result_object, refusal_msg, result_json := obs_parse_envelope(response, command, allocator)
	if kind == .Fault {
		return mcp_tool_error(id, Mcp_Error{category = .Internal, message = refusal_msg, detail = command}, allocator)
	}
	if kind == .Refusal {
		return mcp_tool_error(id, Mcp_Error{category = .Refused, message = refusal_msg}, allocator)
	}

	loaded := true
	if loaded_field, ok := result_object["loaded"].(json.Boolean); ok {
		loaded = bool(loaded_field)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"result\":")
	strings.write_string(&b, result_json)
	if !loaded {
		strings.write_string(&b, ",\"next_action\":")
		funpack_runtime.write_json_string(&b, OBS_STATUS_LOAD_NEXT_ACTION)
	}
	strings.write_byte(&b, '}')

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(strings.to_string(b))
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}
