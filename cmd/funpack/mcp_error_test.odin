package main

import "core:encoding/json"
import "core:strings"
import "core:testing"

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

@(test)
test_mcp_tool_error_envelope_no_detail :: proc(t: ^testing.T) {
	err := Mcp_Error{category = .Invalid_Input, message = "missing path"}
	envelope := mcp_render_error_envelope(err, context.temp_allocator)

	testing.expect(t, !strings.contains(envelope, "detail"), "an empty detail is omitted from the envelope")
	testing.expect(t, strings.contains(envelope, `"category":"invalid_input"`), "the category is the wire string")
	testing.expect(t, strings.contains(envelope, `"message":"missing path"`), "the message is carried")
}

@(test)
test_mcp_error_category_wire :: proc(t: ^testing.T) {
	testing.expect_value(t, mcp_error_category_wire(.Invalid_Input), "invalid_input")
	testing.expect_value(t, mcp_error_category_wire(.Resolver), "resolver")
	testing.expect_value(t, mcp_error_category_wire(.Exec), "exec")
	testing.expect_value(t, mcp_error_category_wire(.Refused), "refused")
	testing.expect_value(t, mcp_error_category_wire(.Protocol), "protocol")
	testing.expect_value(t, mcp_error_category_wire(.Session), "session")
	testing.expect_value(t, mcp_error_category_wire(.Internal), "internal")
}

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
