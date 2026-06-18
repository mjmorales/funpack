// The JSON-RPC 2.0 envelope codec — request parse + response render — as plain,
// dependency-light procs (ADR: NO Framer abstraction, NO package split; a future
// `funpack lsp` lifts these procs as-is when it has a real second consumer). The
// parse/render idiom is exactly the §28 one (runtime/introspect.odin: json.parse +
// strings.Builder envelope rendering), reused not re-invented.
//
// JSON-RPC 2.0 (https://www.jsonrpc.org/specification): a request is
// {"jsonrpc":"2.0","id":<id>,"method":<string>,"params":<value>}; `id` is a string,
// a number, or absent (a notification, no reply). A response echoes the request's
// id verbatim and carries EITHER "result" or "error" — never both. This file owns
// only the envelope; the method dispatch (initialize/tools/*) lives in mcp_server.odin.
package main

import "core:encoding/json"
import "core:strings"
import funpack_runtime "../../runtime"

// JSON-RPC 2.0 standard error codes (the spec's reserved range). The dispatch
// maps a PROTOCOL fault to one of these; a DOMAIN failure never reaches here (it
// is an IsError tools/call result, mcp_error.odin). Kept as named constants so the
// dispatch reads by intent, not by magic number.
MCP_JSONRPC_PARSE_ERROR :: -32700      // invalid JSON was received
MCP_JSONRPC_INVALID_REQUEST :: -32600  // the payload is not a valid request object
MCP_JSONRPC_METHOD_NOT_FOUND :: -32601 // the method does not exist
MCP_JSONRPC_INVALID_PARAMS :: -32602   // invalid method parameters
MCP_JSONRPC_INTERNAL_ERROR :: -32603   // an internal JSON-RPC error

// JSONRPC_VERSION is the fixed protocol tag every request and response stamps as
// "jsonrpc" — JSON-RPC 2.0 is exact-match, like §28's `v`.
JSONRPC_VERSION :: "2.0"

// Mcp_Id_Kind tags the JSON-RPC id form so a response echoes it back as the SAME
// JSON type the request sent (the spec requires the response id to equal the
// request id). A request with no id is a notification (.Absent ⇒ no reply).
Mcp_Id_Kind :: enum {
	Absent, // a notification — no id, no response
	Integer,
	String,
	Null, // an explicit JSON null id (rare, but distinct from absent)
}

// Mcp_Id holds a parsed JSON-RPC id in whichever form the request used, so the
// response renders it back verbatim (an integer stays an integer, a string stays a
// quoted string) — a client correlates the reply by exact id match.
Mcp_Id :: struct {
	kind:    Mcp_Id_Kind,
	integer: i64,
	text:    string,
}

// Mcp_Request is one parsed JSON-RPC request: the id (whichever form), the method
// name, and the raw params object (empty json.Object when absent or non-object —
// the method handler reads its own args off it, exactly as session_request reads
// its `args`). `is_notification` mirrors id.kind == .Absent for a readable dispatch.
Mcp_Request :: struct {
	id:             Mcp_Id,
	method:         string,
	params:         json.Object,
	is_notification: bool,
}

// mcp_parse_request parses one JSON-RPC line into an Mcp_Request, returning ok=false
// for a line that is not a valid request envelope (malformed JSON, not an object, or
// a missing/non-string method). The caller renders the parse failure as a JSON-RPC
// error response — the fold never panics on wire input (the §28 contract). The id is
// recovered when present even on a method error, so the error response can echo it.
mcp_parse_request :: proc(line: string, allocator := context.allocator) -> (request: Mcp_Request, ok: bool) {
	parsed, parse_err := json.parse(transmute([]u8)line, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return {}, false
	}
	object, is_object := parsed.(json.Object)
	if !is_object {
		return {}, false
	}

	request.id = mcp_parse_id(object)
	request.is_notification = request.id.kind == .Absent

	method, has_method := object["method"]
	method_string, method_is_string := method.(json.String)
	if !has_method || !method_is_string {
		// A recoverable id is still returned so the caller can echo it on the error.
		return request, false
	}
	request.method = string(method_string)

	if nested, has_params := object["params"]; has_params {
		if params_object, params_ok := nested.(json.Object); params_ok {
			request.params = params_object
		}
	}
	return request, true
}

// mcp_parse_id reads the JSON-RPC id off a request object in whichever form it took
// — an integer, a string, an explicit null, or absent. A float id is out of the
// MCP integer-id contract and is read as .Null rather than truncated (a §10-style
// refusal of a non-integer where an integer is expected).
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

// mcp_write_id writes the id back as the SAME JSON type the request used. An
// .Absent id renders as null defensively — the caller must not build a response for
// a notification at all, so this path is only the degenerate fallback.
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

// mcp_render_result renders a JSON-RPC success response: the fixed field order
// (jsonrpc, id, result) keeps the line byte-stable, mirroring the §28 ok envelope
// (introspect.odin). `result_json` is the already-rendered result value (a JSON
// object/array/literal the method handler built); this proc only wraps it in the
// envelope, so the handler owns the result shape.
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

// mcp_render_error renders a JSON-RPC error response: the envelope's "error" object
// {code,message} replacing "result". This is the PROTOCOL-fault response (parse
// error, unknown method, bad params) — a DOMAIN failure never comes here (it is an
// IsError result, mcp_error.odin). Same fixed field order for byte-stability.
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
