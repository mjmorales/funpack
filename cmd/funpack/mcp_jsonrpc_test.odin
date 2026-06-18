// Deliberate spec for the JSON-RPC 2.0 envelope codec (mcp_jsonrpc.odin) — the
// parse-request / render-response junction the protocol loop folds every line
// through. These pin the FOUNDATIONAL contract: a well-formed request parses to its
// fields, a malformed line is a recoverable parse failure (never a panic), the id
// echoes back as the SAME JSON type it arrived as, and the result/error envelopes
// render to the spec'd shape. Pure JSON fold — no transport, no SDL, define-free.
package main

import "core:strings"
import "core:testing"

// test_mcp_parse_request_fields pins the happy path: a complete
// {jsonrpc,id,method,params} request parses ok with every field recovered, and the
// params object is readable for the method handler (the seam tools/call dispatches on).
@(test)
test_mcp_parse_request_fields :: proc(t: ^testing.T) {
	line := `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"build"}}`
	request, ok := mcp_parse_request(line, context.temp_allocator)

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

// test_mcp_parse_id_forms pins that the id is recovered in whichever JSON form the
// request used — integer, string, and absent (a notification) — so the response can
// echo it back as the SAME type. JSON-RPC 2.0 requires the response id to match.
@(test)
test_mcp_parse_id_forms :: proc(t: ^testing.T) {
	int_req, _ := mcp_parse_request(`{"jsonrpc":"2.0","id":42,"method":"a"}`, context.temp_allocator)
	testing.expect_value(t, int_req.id.kind, Mcp_Id_Kind.Integer)
	testing.expect_value(t, int_req.id.integer, i64(42))

	str_req, _ := mcp_parse_request(`{"jsonrpc":"2.0","id":"abc","method":"a"}`, context.temp_allocator)
	testing.expect_value(t, str_req.id.kind, Mcp_Id_Kind.String)
	testing.expect_value(t, str_req.id.text, "abc")

	notif, ok := mcp_parse_request(`{"jsonrpc":"2.0","method":"notifications/initialized"}`, context.temp_allocator)
	testing.expect(t, ok, "a notification (no id) is still a valid request envelope")
	testing.expect_value(t, notif.id.kind, Mcp_Id_Kind.Absent)
	testing.expect(t, notif.is_notification, "an id-less request is a notification")
}

// test_mcp_parse_request_malformed pins the refusal contract: a line that is not
// valid JSON, a JSON value that is not an object, and a request missing its method
// all parse ok=false — a JSON-RPC error response, never a panic (the §28 fold
// discipline, introspect.odin:413). A missing-method request still recovers its id
// so the error response can echo it.
@(test)
test_mcp_parse_request_malformed :: proc(t: ^testing.T) {
	_, bad_json := mcp_parse_request(`{not json`, context.temp_allocator)
	testing.expect(t, !bad_json, "malformed JSON must not parse")

	_, not_object := mcp_parse_request(`["array","not","object"]`, context.temp_allocator)
	testing.expect(t, !not_object, "a non-object JSON value is not a request")

	missing, no_method := mcp_parse_request(`{"jsonrpc":"2.0","id":9}`, context.temp_allocator)
	testing.expect(t, !no_method, "a request missing its method must not parse ok")
	testing.expect_value(t, missing.id.kind, Mcp_Id_Kind.Integer)
	testing.expect_value(t, missing.id.integer, i64(9))
}

// test_mcp_render_result pins the success-response shape: the fixed field order
// (jsonrpc, id, result) with the result value wrapped verbatim, and the id echoed
// as its original type — an integer id stays bare, a string id stays quoted.
@(test)
test_mcp_render_result :: proc(t: ^testing.T) {
	int_line := mcp_render_result(Mcp_Id{kind = .Integer, integer = 3}, `{"x":1}`, context.temp_allocator)
	testing.expect_value(t, int_line, `{"jsonrpc":"2.0","id":3,"result":{"x":1}}`)

	str_line := mcp_render_result(Mcp_Id{kind = .String, text = "tok"}, `{}`, context.temp_allocator)
	testing.expect_value(t, str_line, `{"jsonrpc":"2.0","id":"tok","result":{}}`)
}

// test_mcp_render_error pins the protocol-error response shape: the error object
// {code,message} replacing result, the code rendered as a bare integer, and the
// message JSON-escaped. This is the PROTOCOL fault path (parse error, unknown
// method) — a domain failure never renders here (it is an IsError result).
@(test)
test_mcp_render_error :: proc(t: ^testing.T) {
	line := mcp_render_error(Mcp_Id{kind = .Integer, integer = 5}, MCP_JSONRPC_METHOD_NOT_FOUND, "method not found", context.temp_allocator)
	testing.expect_value(t, line, `{"jsonrpc":"2.0","id":5,"error":{"code":-32601,"message":"method not found"}}`)

	// A message needing JSON escaping is escaped, not raw — the envelope stays valid JSON.
	escaped := mcp_render_error(Mcp_Id{kind = .Null}, MCP_JSONRPC_PARSE_ERROR, `bad "quote"`, context.temp_allocator)
	testing.expect(t, strings.contains(escaped, `\"quote\"`), "the error message must be JSON-escaped")
	testing.expect(t, strings.contains(escaped, `"id":null`), "a null id renders as JSON null")
}
