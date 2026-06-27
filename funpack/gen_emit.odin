package funpack

import "core:strings"

Seam :: struct {
	doc:          string,
	imports:      []Seam_Import,
	declarations: []Seam_Decl,
}

Seam_Import :: struct {
	path:    string,
	members: []string,
}

Seam_Decl :: struct {
	doc:  string,
	kind: Seam_Decl_Kind,
}

Seam_Decl_Kind :: union {
	Seam_Data,
	Seam_Extern_Fn,
	Seam_Let,
}

Seam_Data :: struct {
	name:      string,
	fields:    []Seam_Field,
	multiline: bool,
}

Seam_Field :: struct {
	name: string,
	type: string,
}

Seam_Extern_Fn :: struct {
	name:        string,
	return_type: string,
}

Seam_Let :: struct {
	name:  string,
	type:  string,
	value: string,
}

emit_gen_fun :: proc(seam: Seam, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	emit_seam_doc(&b, seam.doc)
	for imp in seam.imports {
		emit_seam_import(&b, imp)
	}
	for decl in seam.declarations {
		strings.write_string(&b, "\n")
		emit_seam_decl(&b, decl)
	}
	return strings.to_string(b)
}

emit_seam_doc :: proc(b: ^strings.Builder, doc: string) {
	strings.write_string(b, "@doc(\"")
	strings.write_string(b, doc)
	strings.write_string(b, "\")\n")
}

emit_seam_import :: proc(b: ^strings.Builder, imp: Seam_Import) {
	strings.write_string(b, "import ")
	strings.write_string(b, imp.path)
	strings.write_string(b, ".{")
	for member, i in imp.members {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, member)
	}
	strings.write_string(b, "}\n")
}

emit_seam_decl :: proc(b: ^strings.Builder, decl: Seam_Decl) {
	emit_seam_doc(b, decl.doc)
	switch body in decl.kind {
	case Seam_Data:
		emit_seam_data(b, body)
	case Seam_Extern_Fn:
		emit_seam_extern_fn(b, body)
	case Seam_Let:
		emit_seam_let(b, body)
	}
}

emit_seam_let :: proc(b: ^strings.Builder, decl: Seam_Let) {
	strings.write_string(b, "let ")
	strings.write_string(b, decl.name)
	strings.write_string(b, ": ")
	strings.write_string(b, decl.type)
	strings.write_string(b, " = ")
	strings.write_string(b, decl.value)
	strings.write_string(b, "\n")
}

emit_seam_data :: proc(b: ^strings.Builder, data: Seam_Data) {
	if data.multiline {
		emit_seam_data_multiline(b, data)
	} else {
		emit_seam_data_inline(b, data)
	}
}

emit_seam_data_inline :: proc(b: ^strings.Builder, data: Seam_Data) {
	strings.write_string(b, "data ")
	strings.write_string(b, data.name)
	strings.write_string(b, " { ")
	for field, i in data.fields {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		strings.write_string(b, field.type)
	}
	strings.write_string(b, " }\n")
}

emit_seam_data_multiline :: proc(b: ^strings.Builder, data: Seam_Data) {
	strings.write_string(b, "data ")
	strings.write_string(b, data.name)
	strings.write_string(b, " {\n")
	longest := longest_field_name_len(data.fields)
	for field in data.fields {
		strings.write_string(b, "  ")
		strings.write_string(b, field.name)
		strings.write_string(b, ":")
		pad := longest - len(field.name) + 1
		for _ in 0 ..< pad {
			strings.write_string(b, " ")
		}
		strings.write_string(b, field.type)
		strings.write_string(b, "\n")
	}
	strings.write_string(b, "}\n")
}

longest_field_name_len :: proc(fields: []Seam_Field) -> int {
	longest := 0
	for field in fields {
		if len(field.name) > longest {
			longest = len(field.name)
		}
	}
	return longest
}

emit_seam_extern_fn :: proc(b: ^strings.Builder, fn: Seam_Extern_Fn) {
	strings.write_string(b, "extern fn ")
	strings.write_string(b, fn.name)
	strings.write_string(b, "() -> ")
	strings.write_string(b, fn.return_type)
	strings.write_string(b, "\n")
}

slice_lit :: proc(items: []string, allocator := context.allocator) -> []string {
	out := make([]string, len(items), allocator)
	copy(out, items)
	return out
}
