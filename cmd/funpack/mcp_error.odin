// The MCP tool-boundary error convention and content-block result model. Every
// tool arm (the session-registry, one-shot, docs/health) that grafts onto the
// tools/call dispatch renders a domain failure through THIS file, so the server
// speaks one fixed error vocabulary.
//
// THE CONVENTION: a DOMAIN failure — bad input, a failed resolve/exec, a stale
// session — is NOT a JSON-RPC error object.
// It is a successful tools/call whose CallToolResult carries IsError=true and a
// first TextContent holding the {category,message,detail} envelope as JSON. The
// model reads the category in the tool result and self-corrects; a JSON-RPC error
// object (which the model cannot see inside the result) is reserved for a true
// PROTOCOL fault (malformed request, unknown method) the caller cannot act on.
package main

import "core:strings"
import funpack_runtime "../../runtime"

// Mcp_Error_Category is the closed domain-error vocabulary. The set is
// intentionally tight: adding a value is a deliberate change, not an ad-hoc
// addition, so the model and the server share one fixed error taxonomy. The string
// values ARE the wire `category` strings the envelope carries.
Mcp_Error_Category :: enum {
	Invalid_Input, // a malformed or out-of-contract tool argument
	Resolver,      // a failure resolving a funpack path/document/index entry
	Exec,          // a failure executing an underlying funpack command
	Protocol,      // an MCP-protocol-level fault (transport/request-contract)
	Session,       // a session-lifecycle failure (attach/detach/stale session)
	Internal,      // an unexpected internal fault — the catch-all for bugs
}

// mcp_error_category_wire maps a category to its wire string — the value the
// {category,...} envelope carries and a client matches on. Kept exhaustive (no
// default) so adding an enum value without a wire string is a compile error, the
// closed-enum discipline §28's error vocabulary depends on.
mcp_error_category_wire :: proc(category: Mcp_Error_Category) -> string {
	switch category {
	case .Invalid_Input:
		return "invalid_input"
	case .Resolver:
		return "resolver"
	case .Exec:
		return "exec"
	case .Protocol:
		return "protocol"
	case .Session:
		return "session"
	case .Internal:
		return "internal"
	}
	return "internal"
}

// Mcp_Error is the canonical funpack MCP domain error: a category plus a message,
// with no error-chain wrapping — a domain failure here is always constructed at the
// boundary that names its category. message is the human-and-model summary; detail
// is optional extra context (an offending value, an underlying message). It maps to
// an IsError result via mcp_tool_error_result.
Mcp_Error :: struct {
	category: Mcp_Error_Category,
	message:  string,
	detail:   string,
}

// Mcp_Content_Kind tags a result content block. MCP carries several content types;
// the protocol layer models the two funpack tools return — text (every structured
// result and every error envelope) and image (the screenshot arm). The enum is the
// closed set this server emits; audio/resource blocks are not produced.
Mcp_Content_Kind :: enum {
	Text,
	Image,
}

// Mcp_Content is one result content block. For .Text, `text` is the payload and
// mime_type is unused. For .Image, `data` is the base64-encoded image bytes and
// mime_type is the image media type (e.g. "image/qoi" or "image/png") — modeled as
// an arbitrary string so the screenshot arm picks the encoding without a
// protocol-layer change (the format choice is owned in that arm, not here). The
// wire shapes match the MCP TextContent/ImageContent blocks.
Mcp_Content :: struct {
	kind:      Mcp_Content_Kind,
	text:      string,
	data:      string,
	mime_type: string,
}

// mcp_text_content builds a .Text block — the common case for a structured result
// and for every error envelope.
mcp_text_content :: proc(text: string) -> Mcp_Content {
	return Mcp_Content{kind = .Text, text = text}
}

// mcp_image_content builds an .Image block carrying base64 data under an arbitrary
// mime type, so the screenshot arm chooses image/qoi vs image/png.
mcp_image_content :: proc(data: string, mime_type: string) -> Mcp_Content {
	return Mcp_Content{kind = .Image, data = data, mime_type = mime_type}
}

// Mcp_Tool_Result is the value a tools/call arm returns: a content-block list and
// the IsError flag. A clean result sets is_error=false and carries the structured
// content; a domain failure sets is_error=true with the envelope text block. This
// is the shape mcp_render_tool_result renders into the JSON-RPC result.
Mcp_Tool_Result :: struct {
	content:  []Mcp_Content,
	is_error: bool,
}

// mcp_tool_error_result is the single tool-boundary mapping every tool arm reports
// a domain failure through: it renders the {category,message,detail} envelope as a
// JSON string into one TextContent and sets IsError=true. `detail` is omitted from
// the JSON when empty (the JSON-Schema omitempty convention). The result is a
// SUCCESSFUL tools/call carrying the failure in-band — never a JSON-RPC error
// object — so the model sees the category and self-corrects.
mcp_tool_error_result :: proc(err: Mcp_Error, allocator := context.allocator) -> Mcp_Tool_Result {
	envelope := mcp_render_error_envelope(err, allocator)
	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(envelope)
	return Mcp_Tool_Result{content = content, is_error = true}
}

// mcp_render_error_envelope renders the {category,message,detail} envelope as a
// JSON object string. `detail` is omitted when empty (the omitempty convention).
// Built with the same strings.Builder + write_json_string idiom the §28 envelope
// renderers use (runtime/introspect.odin), so the envelope is byte-stable.
mcp_render_error_envelope :: proc(err: Mcp_Error, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"category\":")
	funpack_runtime.write_json_string(&b, mcp_error_category_wire(err.category))
	strings.write_string(&b, ",\"message\":")
	funpack_runtime.write_json_string(&b, err.message)
	if err.detail != "" {
		strings.write_string(&b, ",\"detail\":")
		funpack_runtime.write_json_string(&b, err.detail)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}
