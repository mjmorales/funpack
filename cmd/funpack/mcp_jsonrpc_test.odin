package main

import "core:strings"
import "core:testing"

@(test)
test_mcp_parse_request_fields :: proc(t: ^testing.T) {
	line := `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"build"}}`
	request, ok, _ := mcp_parse_request(line, context.temp_allocator)

	testing.expect(t, ok, "a well-formed request must parse")
	testing.expect_value(t, request.method, "tools/call")
	testing.expect_value(t, request.id.kind, Mcp_Id_Kind.Integer)
	testing.expect_value(t, request.id.integer, i64(7))
	testing.expect(t, !request.is_notification, "a request with an id is not a notification")

	name, has_name := request.params["name"]
	name_string, is_string := name.(string)
	testing.expect(t, has_name && is_string, "params.name must be a readable string")
	testing.expect_value(t, name_string, "build")
}

@(test)
test_mcp_parse_id_forms :: proc(t: ^testing.T) {
	int_req, _, _ := mcp_parse_request(`{"jsonrpc":"2.0","id":42,"method":"a"}`, context.temp_allocator)
	testing.expect_value(t, int_req.id.kind, Mcp_Id_Kind.Integer)
	testing.expect_value(t, int_req.id.integer, i64(42))

	str_req, _, _ := mcp_parse_request(`{"jsonrpc":"2.0","id":"abc","method":"a"}`, context.temp_allocator)
	testing.expect_value(t, str_req.id.kind, Mcp_Id_Kind.String)
	testing.expect_value(t, str_req.id.text, "abc")

	notif, ok, _ := mcp_parse_request(`{"jsonrpc":"2.0","method":"notifications/initialized"}`, context.temp_allocator)
	testing.expect(t, ok, "a notification (no id) is still a valid request envelope")
	testing.expect_value(t, notif.id.kind, Mcp_Id_Kind.Absent)
	testing.expect(t, notif.is_notification, "an id-less request is a notification")
}

@(test)
test_mcp_parse_request_malformed :: proc(t: ^testing.T) {
	_, bad_json, json_ok := mcp_parse_request(`{not json`, context.temp_allocator)
	testing.expect(t, !bad_json, "malformed JSON must not parse")
	testing.expect(t, !json_ok, "unparseable JSON sets json_ok=false (→ PARSE_ERROR)")

	_, not_object, obj_json_ok := mcp_parse_request(`["array","not","object"]`, context.temp_allocator)
	testing.expect(t, !not_object, "a non-object JSON value is not a request")
	testing.expect(t, obj_json_ok, "valid JSON that is not an object keeps json_ok=true (→ INVALID_REQUEST)")

	missing, no_method, miss_json_ok := mcp_parse_request(`{"jsonrpc":"2.0","id":9}`, context.temp_allocator)
	testing.expect(t, !no_method, "a request missing its method must not parse ok")
	testing.expect(t, miss_json_ok, "well-formed JSON missing its method keeps json_ok=true (→ INVALID_REQUEST)")
	testing.expect_value(t, missing.id.kind, Mcp_Id_Kind.Integer)
	testing.expect_value(t, missing.id.integer, i64(9))
}

@(test)
test_mcp_render_result :: proc(t: ^testing.T) {
	int_line := mcp_render_result(Mcp_Id{kind = .Integer, integer = 3}, `{"x":1}`, context.temp_allocator)
	testing.expect_value(t, int_line, `{"jsonrpc":"2.0","id":3,"result":{"x":1}}`)

	str_line := mcp_render_result(Mcp_Id{kind = .String, text = "tok"}, `{}`, context.temp_allocator)
	testing.expect_value(t, str_line, `{"jsonrpc":"2.0","id":"tok","result":{}}`)
}

@(test)
test_mcp_render_error :: proc(t: ^testing.T) {
	line := mcp_render_error(Mcp_Id{kind = .Integer, integer = 5}, MCP_JSONRPC_METHOD_NOT_FOUND, "method not found", context.temp_allocator)
	testing.expect_value(t, line, `{"jsonrpc":"2.0","id":5,"error":{"code":-32601,"message":"method not found"}}`)

	escaped := mcp_render_error(Mcp_Id{kind = .Null}, MCP_JSONRPC_PARSE_ERROR, `bad "quote"`, context.temp_allocator)
	testing.expect(t, strings.contains(escaped, `\"quote\"`), "the error message must be JSON-escaped")
	testing.expect(t, strings.contains(escaped, `"id":null`), "a null id renders as JSON null")
}
