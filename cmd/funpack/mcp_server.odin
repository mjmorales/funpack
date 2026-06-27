package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

MCP_PROTOCOL_VERSION :: "2025-06-18"

MCP_SERVER_NAME :: "funpack-mcp"

run_mcp_verb :: proc(allocator := context.allocator) -> int {
	mcp_materialize_docs_projection(allocator)

	registry := mcp_session_registry_make(allocator)
	defer mcp_session_registry_destroy(&registry, allocator)
	serve_mcp_stdio(mcp_jsonrpc_handler(&registry), allocator)
	return 0
}

mcp_jsonrpc_handler :: proc(registry: ^Mcp_Session_Registry) -> Mcp_Line_Handler {
	return Mcp_Line_Handler {
		userdata = registry,
		handle = proc(userdata: rawptr, line: string, allocator := context.allocator) -> (response: string, keep_open: bool) {
			registry := cast(^Mcp_Session_Registry)userdata
			return mcp_dispatch_line(registry, line, allocator)
		},
	}
}

mcp_dispatch_line :: proc(registry: ^Mcp_Session_Registry, line: string, allocator := context.allocator) -> (response: string, keep_open: bool) {
	request, ok, json_ok := mcp_parse_request(line, allocator)
	if !ok {
		if request.is_notification {
			return "", true
		}
		if !json_ok {
			return mcp_render_error(request.id, MCP_JSONRPC_PARSE_ERROR, "parse error: line is not valid JSON", allocator), true
		}
		return mcp_render_error(request.id, MCP_JSONRPC_INVALID_REQUEST, "invalid JSON-RPC request: not a request object or missing method", allocator), true
	}

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

mcp_handle_initialize :: proc(request: Mcp_Request, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"protocolVersion\":\"")
	strings.write_string(&b, MCP_PROTOCOL_VERSION)
	strings.write_string(&b, "\",\"capabilities\":{\"tools\":{\"listChanged\":false}}")
	strings.write_string(&b, ",\"serverInfo\":{\"name\":\"")
	strings.write_string(&b, MCP_SERVER_NAME)
	strings.write_string(&b, "\",\"version\":")
	funpack_runtime.write_json_string(&b, funpack.funpack_version())
	strings.write_string(&b, "}")
	if instructions, ok := core_prefix_build(allocator); ok {
		strings.write_string(&b, ",\"instructions\":")
		funpack_runtime.write_json_string(&b, instructions)
	}
	strings.write_string(&b, "}")
	return mcp_render_result(request.id, strings.to_string(b), allocator)
}

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

Mcp_Dispatch :: struct {
	spec:      funpack.Tool_Spec,
	name:      string,
	arguments: json.Object,
	id:        Mcp_Id,
	registry:  ^Mcp_Session_Registry,
}

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

Mcp_Tool_Dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool)

MCP_DISPATCH_CHAIN := [?]Mcp_Tool_Dispatch {
	mcp_oneshot_dispatch,
	mcp_docs_tool_dispatch,
	mcp_session_tool_dispatch,
	mcp_record_dispatch,
	mcp_observe_time_dispatch,
	mcp_control_dispatch,
	mcp_screenshot_dispatch,
}

mcp_lookup_tool :: proc(name: string) -> (spec: funpack.Tool_Spec, found: bool) {
	for candidate in funpack.TOOL_SPECS {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

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
