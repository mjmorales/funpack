package funpack

import "core:strings"

Screen_Seam_Docs :: struct {
	file:    string,
	row:     string,
	view:    string,
	msg:     string,
	builder: string,
}

emit_screen_seam :: proc(seam: Inferred_Seam, docs: Screen_Seam_Docs, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	emit_seam_doc(&b, docs.file)
	strings.write_string(&b, "\n")
	emit_screen_imports(&b, seam)

	for record in seam.row_types {
		strings.write_string(&b, "\n")
		emit_seam_doc(&b, docs.row)
		emit_screen_row_data(&b, record)
	}
	strings.write_string(&b, "\n")
	emit_seam_doc(&b, docs.view)
	emit_screen_view_data(&b, seam)
	strings.write_string(&b, "\n")
	emit_seam_doc(&b, docs.msg)
	emit_screen_msg_enum(&b, seam)
	strings.write_string(&b, "\n")
	emit_seam_doc(&b, docs.builder)
	emit_screen_builder_fn(&b, seam)
	return strings.to_string(b)
}

emit_screen_imports :: proc(b: ^strings.Builder, seam: Inferred_Seam) {
	prims := screen_prelude_prims(seam)
	if len(prims) > 0 {
		strings.write_string(b, "import engine.prelude.{")
		for prim, i in prims {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, prim)
		}
		strings.write_string(b, "}\n")
	}
	strings.write_string(b, "import engine.ui.View\n")
}

screen_prelude_prims :: proc(seam: Inferred_Seam) -> []string {
	out := make([dynamic]string, 0, 3, context.temp_allocator)
	for record in seam.row_types {
		for field in record.fields {
			add_prelude_prim(&out, field.type)
		}
	}
	for field in seam.view_fields {
		add_prelude_prim(&out, field.type)
	}
	return out[:]
}

add_prelude_prim :: proc(out: ^[dynamic]string, type: Fui_Type) {
	prim, is_prim := type.(Fui_Prim)
	if !is_prim {
		return
	}
	token := fui_prim_token(prim)
	for seen in out {
		if seen == token {
			return
		}
	}
	append(out, token)
}

emit_screen_row_data :: proc(b: ^strings.Builder, record: Fui_Record) {
	emit_screen_data_inline(b, record.name, record.fields)
}

emit_screen_view_data :: proc(b: ^strings.Builder, seam: Inferred_Seam) {
	emit_screen_data_inline(b, seam.view_name, seam.view_fields)
}

emit_screen_data_inline :: proc(b: ^strings.Builder, name: string, fields: []Fui_Field) {
	strings.write_string(b, "data ")
	strings.write_string(b, name)
	if len(fields) == 0 {
		strings.write_string(b, " {}\n")
		return
	}
	strings.write_string(b, " { ")
	for field, i in fields {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		strings.write_string(b, screen_field_type_token(field.type))
	}
	strings.write_string(b, " }\n")
}

emit_screen_msg_enum :: proc(b: ^strings.Builder, seam: Inferred_Seam) {
	strings.write_string(b, "enum ")
	strings.write_string(b, seam.msg_name)
	strings.write_string(b, " { ")
	for variant, i in seam.msg_variants {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, variant.name)
		if variant.has_payload {
			strings.write_string(b, "(")
			strings.write_string(b, screen_field_type_token(variant.payload))
			strings.write_string(b, ")")
		}
	}
	strings.write_string(b, " }\n")
}

emit_screen_builder_fn :: proc(b: ^strings.Builder, seam: Inferred_Seam) {
	strings.write_string(b, "extern fn ")
	strings.write_string(b, screen_builder_fn_name(seam.screen_name))
	strings.write_string(b, "(model: ")
	strings.write_string(b, seam.view_name)
	strings.write_string(b, ") -> View[")
	strings.write_string(b, seam.msg_name)
	strings.write_string(b, "]\n")
}

screen_field_type_token :: proc(type: Fui_Type) -> string {
	switch t in type {
	case Fui_Prim:
		return fui_prim_token(t)
	case Fui_List:
		return fui_concat("[", t.row, "]")
	case Fui_Named:
		return t.token
	}
	return ""
}

fui_prim_token :: proc(prim: Fui_Prim) -> string {
	switch prim {
	case .Int:
		return "Int"
	case .Bool:
		return "Bool"
	case .String:
		return "String"
	}
	return ""
}

screen_builder_fn_name :: proc(screen_name: string, allocator := context.temp_allocator) -> string {
	return strings.to_lower(screen_name, allocator)
}
