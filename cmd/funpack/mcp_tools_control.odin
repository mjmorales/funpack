package main

import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strconv"
import "core:strings"

CTRL_REQUEST_ID :: 1

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
		return "", false
	}
	return ctrl_fold_session_command(dispatch, command, allocator), true
}

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

ctrl_lift_response :: proc(response: string, command: string, allocator := context.allocator) -> Mcp_Tool_Result {
	parsed, ok_field, error_text := ctrl_parse_response(response, allocator)
	if parsed && ok_field {
		content := make([]Mcp_Content, 1, allocator)
		content[0] = mcp_text_content(response)
		return Mcp_Tool_Result{content = content, is_error = false}
	}
	message := error_text
	if message == "" {
		message = "control command refused"
	}
	return mcp_tool_error_result(Mcp_Error{category = .Refused, message = message, detail = command}, allocator)
}

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

ctrl_assert_specs_present :: proc() -> bool {
	for tool in ctrl_family_tools {
		_, found := mcp_lookup_tool(tool)
		if !found {
			return false
		}
	}
	return true
}
