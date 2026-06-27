package main

import "core:strings"
import funpack_runtime "../../runtime"

Mcp_Error_Category :: enum {
	Invalid_Input,
	Resolver,
	Exec,
	Refused,
	Protocol,
	Session,
	Internal,
}

mcp_error_category_wire :: proc(category: Mcp_Error_Category) -> string {
	switch category {
	case .Invalid_Input:
		return "invalid_input"
	case .Resolver:
		return "resolver"
	case .Exec:
		return "exec"
	case .Refused:
		return "refused"
	case .Protocol:
		return "protocol"
	case .Session:
		return "session"
	case .Internal:
		return "internal"
	}
	return "internal"
}

Mcp_Error :: struct {
	category: Mcp_Error_Category,
	message:  string,
	detail:   string,
}

mcp_missing_string_field :: proc(field, tool: string, allocator := context.allocator) -> Mcp_Error {
	return Mcp_Error {
		category = .Invalid_Input,
		message  = strings.concatenate({"missing required string field: ", field}, allocator),
		detail   = tool,
	}
}

mcp_unknown_session_error :: proc(session_id: string) -> Mcp_Error {
	return Mcp_Error {
		category = .Session,
		message  = "no live session with that id — start one with session_start, or it was already ended",
		detail   = session_id,
	}
}

Mcp_Content_Kind :: enum {
	Text,
	Image,
}

Mcp_Content :: struct {
	kind:      Mcp_Content_Kind,
	text:      string,
	data:      string,
	mime_type: string,
}

mcp_text_content :: proc(text: string) -> Mcp_Content {
	return Mcp_Content{kind = .Text, text = text}
}

mcp_image_content :: proc(data: string, mime_type: string) -> Mcp_Content {
	return Mcp_Content{kind = .Image, data = data, mime_type = mime_type}
}

Mcp_Tool_Result :: struct {
	content:  []Mcp_Content,
	is_error: bool,
}

mcp_tool_error_result :: proc(err: Mcp_Error, allocator := context.allocator) -> Mcp_Tool_Result {
	envelope := mcp_render_error_envelope(err, allocator)
	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(envelope)
	return Mcp_Tool_Result{content = content, is_error = true}
}

mcp_tool_error :: proc(id: Mcp_Id, err: Mcp_Error, allocator := context.allocator) -> string {
	return mcp_render_tool_result(id, mcp_tool_error_result(err, allocator), allocator)
}

mcp_text_result :: proc(id: Mcp_Id, text: string, allocator := context.allocator) -> string {
	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(text)
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}

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
