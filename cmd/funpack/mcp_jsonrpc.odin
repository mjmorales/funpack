package main

import "core:encoding/json"
import "core:strings"
import funpack_runtime "../../runtime"

MCP_JSONRPC_PARSE_ERROR :: -32700
MCP_JSONRPC_INVALID_REQUEST :: -32600
MCP_JSONRPC_METHOD_NOT_FOUND :: -32601
MCP_JSONRPC_INVALID_PARAMS :: -32602
MCP_JSONRPC_INTERNAL_ERROR :: -32603

JSONRPC_VERSION :: "2.0"

Mcp_Id_Kind :: enum {
	Absent,
	Integer,
	String,
	Null,
}

Mcp_Id :: struct {
	kind:    Mcp_Id_Kind,
	integer: i64,
	text:    string,
}

Mcp_Request :: struct {
	id:             Mcp_Id,
	method:         string,
	params:         json.Object,
	is_notification: bool,
}

mcp_parse_request :: proc(line: string, allocator := context.allocator) -> (request: Mcp_Request, ok: bool, json_ok: bool) {
	parsed, parse_err := json.parse(transmute([]u8)line, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return {}, false, false
	}
	object, is_object := parsed.(json.Object)
	if !is_object {
		return {}, false, true
	}

	request.id = mcp_parse_id(object)
	request.is_notification = request.id.kind == .Absent

	method, has_method := object["method"]
	method_string, method_is_string := method.(json.String)
	if !has_method || !method_is_string {
		return request, false, true
	}
	request.method = string(method_string)

	if nested, has_params := object["params"]; has_params {
		if params_object, params_ok := nested.(json.Object); params_ok {
			request.params = params_object
		}
	}
	return request, true, true
}

mcp_parse_id :: proc(object: json.Object) -> Mcp_Id {
	field, has := object["id"]
	if !has {
		return Mcp_Id{kind = .Absent}
	}
	switch value in field {
	case json.Integer:
		return Mcp_Id{kind = .Integer, integer = i64(value)}
	case json.String:
		return Mcp_Id{kind = .String, text = string(value)}
	case json.Null:
		return Mcp_Id{kind = .Null}
	case json.Float, json.Boolean, json.Array, json.Object:
		return Mcp_Id{kind = .Null}
	}
	return Mcp_Id{kind = .Null}
}

mcp_write_id :: proc(b: ^strings.Builder, id: Mcp_Id) {
	switch id.kind {
	case .Integer:
		strings.write_i64(b, id.integer)
	case .String:
		funpack_runtime.write_json_string(b, id.text)
	case .Null, .Absent:
		strings.write_string(b, "null")
	}
}

mcp_render_result :: proc(id: Mcp_Id, result_json: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"jsonrpc\":\"")
	strings.write_string(&b, JSONRPC_VERSION)
	strings.write_string(&b, "\",\"id\":")
	mcp_write_id(&b, id)
	strings.write_string(&b, ",\"result\":")
	strings.write_string(&b, result_json)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

mcp_render_error :: proc(id: Mcp_Id, code: int, message: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"jsonrpc\":\"")
	strings.write_string(&b, JSONRPC_VERSION)
	strings.write_string(&b, "\",\"id\":")
	mcp_write_id(&b, id)
	strings.write_string(&b, ",\"error\":{\"code\":")
	strings.write_int(&b, code)
	strings.write_string(&b, ",\"message\":")
	funpack_runtime.write_json_string(&b, message)
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}
