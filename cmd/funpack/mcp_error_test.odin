// Deliberate spec for the MCP tool-boundary error convention (mcp_error.odin) —
// the Odin port of mcperr_test.go's TestToolErrorEnvelope / TestToolErrorNonDomainError.
// These pin the convention every downstream tool arm renders failures through: a
// DOMAIN failure is an IsError tools/call result whose first TextContent decodes to
// a {category,message,detail} envelope under a CLOSED category — never a JSON-RPC
// error object. Also pins the content-block result model (text vs image). Pure JSON
// fold — define-free, no SDL.
package main

import "core:encoding/json"
import "core:strings"
import "core:testing"

// test_mcp_tool_error_envelope is the port of TestToolErrorEnvelope (mcperr_test.go:89):
// a domain Mcp_Error maps to an IsError result with exactly one TextContent whose
// text decodes back to its {category,message,detail} fields. This is the in-band
// failure the model reads and self-corrects from, not a protocol error.
@(test)
test_mcp_tool_error_envelope :: proc(t: ^testing.T) {
	domain := Mcp_Error{category = .Resolver, message = "doc not found", detail = "name=foo"}
	result := mcp_tool_error_result(domain, context.temp_allocator)

	testing.expect(t, result.is_error, "a domain failure sets IsError=true")
	testing.expect_value(t, len(result.content), 1)
	testing.expect_value(t, result.content[0].kind, Mcp_Content_Kind.Text)

	category, message, detail := decode_envelope(t, result.content[0].text)
	testing.expect_value(t, category, "resolver")
	testing.expect_value(t, message, "doc not found")
	testing.expect_value(t, detail, "name=foo")
}

// test_mcp_tool_error_envelope_no_detail pins the `detail,omitempty` contract: an
// error with no detail renders an envelope WITHOUT the detail key (matching the Go
// json:"detail,omitempty"), so a client sees {category,message} only.
@(test)
test_mcp_tool_error_envelope_no_detail :: proc(t: ^testing.T) {
	err := Mcp_Error{category = .Invalid_Input, message = "missing path"}
	envelope := mcp_render_error_envelope(err, context.temp_allocator)

	testing.expect(t, !strings.contains(envelope, "detail"), "an empty detail is omitted from the envelope")
	testing.expect(t, strings.contains(envelope, `"category":"invalid_input"`), "the category is the wire string")
	testing.expect(t, strings.contains(envelope, `"message":"missing path"`), "the message is carried")
}

// test_mcp_error_category_wire pins the CLOSED category set exhaustively — every
// enum value maps to its documented §28 wire string. A new category without a wire
// string is a compile error in mcp_error_category_wire (no default arm); this test
// pins the actual string values so a rename is caught.
@(test)
test_mcp_error_category_wire :: proc(t: ^testing.T) {
	testing.expect_value(t, mcp_error_category_wire(.Invalid_Input), "invalid_input")
	testing.expect_value(t, mcp_error_category_wire(.Resolver), "resolver")
	testing.expect_value(t, mcp_error_category_wire(.Exec), "exec")
	testing.expect_value(t, mcp_error_category_wire(.Protocol), "protocol")
	testing.expect_value(t, mcp_error_category_wire(.Session), "session")
	testing.expect_value(t, mcp_error_category_wire(.Internal), "internal")
}

// test_mcp_content_blocks pins the content-block result model the downstream tool
// arms return through: a text block renders {type:"text",text:…} and an image block
// renders {type:"image",data:…,mimeType:…} with an ARBITRARY mime type, so the
// screenshot task picks image/qoi vs image/png later without a protocol-layer change.
@(test)
test_mcp_content_blocks :: proc(t: ^testing.T) {
	text := mcp_text_content("hello")
	testing.expect_value(t, text.kind, Mcp_Content_Kind.Text)
	testing.expect_value(t, text.text, "hello")

	image := mcp_image_content("YmFzZTY0", "image/qoi")
	testing.expect_value(t, image.kind, Mcp_Content_Kind.Image)
	testing.expect_value(t, image.data, "YmFzZTY0")
	testing.expect_value(t, image.mime_type, "image/qoi")
}

// decode_envelope parses an error-envelope JSON string and returns its
// category/message/detail (detail empty when absent), so a test asserts the decoded
// fields exactly as the Go test json.Unmarshals the envelope.
decode_envelope :: proc(t: ^testing.T, text: string, loc := #caller_location) -> (category: string, message: string, detail: string) {
	parsed, err := json.parse(transmute([]u8)text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect(t, err == .None, "the envelope must be valid JSON", loc = loc)
	object, is_object := parsed.(json.Object)
	testing.expect(t, is_object, "the envelope must be a JSON object", loc = loc)

	if value, ok := object["category"].(json.String); ok {
		category = string(value)
	}
	if value, ok := object["message"].(json.String); ok {
		message = string(value)
	}
	if value, ok := object["detail"].(json.String); ok {
		detail = string(value)
	}
	return
}
