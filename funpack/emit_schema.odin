package funpack

import "core:strings"

emit_meta :: proc(b: ^strings.Builder, project: Project_Identity) {
	emit_header(b, "meta", 2)
	emit_line(b, "project ", project.name)
	emit_line(b, "version ", encode_string(project.version, context.temp_allocator))
}

emit_enums :: proc(b: ^strings.Builder, ast: Ast, imported: []Enum_Node) {
	emit_header(b, "enums", len(ast.enums) + len(imported))
	for decl in ast.enums {
		emit_enum_record(b, decl)
	}
	for decl in imported {
		emit_enum_record(b, decl)
	}
}

emit_enum_record :: proc(b: ^strings.Builder, decl: Enum_Node) {
	kind := decl.kind if decl.kind != "" else "-"
	strings.write_string(b, "enum ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_string(b, kind)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.variants))
	emit_line(b, "")
	for variant in decl.variants {
		emit_line(b, "variant ", variant.name, " ", variant_payload_tag(variant))
	}
}

variant_payload_tag :: proc(variant: Variant_Decl) -> string {
	switch variant.payload {
	case .Tuple:
		return strings.concatenate({"tuple ", encode_int(i64(len(variant.tuple)), context.temp_allocator)}, context.temp_allocator)
	case .Struct:
		return strings.concatenate({"struct ", encode_int(i64(len(variant.fields)), context.temp_allocator)}, context.temp_allocator)
	case .Plain:
		return "unit"
	}
	return "unit"
}

emit_data :: proc(b: ^strings.Builder, ast: Ast, imported: Imported_Decls) {
	synthetic := synthetic_data_decls(ast, imported)
	emit_header(b, "data", len(ast.datas) + len(imported.datas) + len(synthetic))
	for decl in ast.datas {
		emit_data_record(b, decl, ast)
	}
	for decl in imported.datas {
		emit_data_record(b, decl, ast)
	}
	for decl in synthetic {
		emit_synthetic_data(b, decl)
	}
}

emit_data_record :: proc(b: ^strings.Builder, decl: Data_Node, ast: Ast) {
	strings.write_string(b, "data ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.fields))
	emit_line(b, " false")
	if decl.has_migrate {
		emit_line(b, "migrate ", decl.migrate.from, " -")
	}
	emit_data_fields(b, decl.fields, ast)
}

Synthetic_Data :: struct {
	name:   string,
	fields: []Synthetic_Field,
}

synthetic_data_decls :: proc(ast: Ast, imported: Imported_Decls) -> []Synthetic_Data {
	out := make([dynamic]Synthetic_Data, 0, 3, context.temp_allocator)
	if uses_engine_type(ast, imported, "Settings") {
		append(&out, Synthetic_Data{name = "Settings", fields = SETTINGS_DATA_FIELDS})
		append(&out, Synthetic_Data{name = "AccessOpts", fields = ACCESS_OPTS_DATA_FIELDS})
	}
	if uses_engine_type(ast, imported, "Path") {
		append(&out, Synthetic_Data{name = "Path", fields = PATH_DATA_FIELDS})
	}
	if references_cell_type(ast, imported) && !declares_data_type(ast, imported, "Cell") {
		append(&out, Synthetic_Data{name = "Cell", fields = CELL_DATA_FIELDS})
	}
	return out[:]
}

@(rodata)
CELL_DATA_FIELDS := []Synthetic_Field{{name = "x", type_name = "Int"}, {name = "y", type_name = "Int"}}

references_cell_type :: proc(ast: Ast, imported: Imported_Decls) -> bool {
	return(
		uses_engine_type(ast, imported, "Cell") ||
		uses_engine_type(ast, imported, "[Cell]") ||
		uses_engine_type(ast, imported, "Option[Cell]") \
	)
}

declares_data_type :: proc(ast: Ast, imported: Imported_Decls, type_name: string) -> bool {
	for decl in ast.datas {
		if decl.name == type_name {
			return true
		}
	}
	for decl in imported.datas {
		if decl.name == type_name {
			return true
		}
	}
	return false
}

uses_engine_type :: proc(ast: Ast, imported: Imported_Decls, type_name: string) -> bool {
	for decl in ast.things {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in ast.datas {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in ast.signals {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in imported.things {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in imported.datas {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in imported.signals {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	return false
}

fields_declare_type :: proc(fields: []Field_Decl, type_name: string) -> bool {
	for field in fields {
		if type_ref_string(field.type) == type_name {
			return true
		}
	}
	return false
}

emit_synthetic_data :: proc(b: ^strings.Builder, decl: Synthetic_Data) {
	strings.write_string(b, "data ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.fields))
	emit_line(b, " false")
	for field in decl.fields {
		emit_line(b, "field ", field.name, " ", field.type_name, " -")
	}
}

emit_signals :: proc(b: ^strings.Builder, ast: Ast, imported: []Signal_Node) {
	emit_header(b, "signals", len(ast.signals) + len(imported))
	for decl in ast.signals {
		emit_signal_record(b, decl, ast)
	}
	for decl in imported {
		emit_signal_record(b, decl, ast)
	}
}

emit_signal_record :: proc(b: ^strings.Builder, decl: Signal_Node, ast: Ast) {
	strings.write_string(b, "signal ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.fields))
	emit_line(b, "")
	emit_fields(b, decl.fields, ast)
}

emit_things :: proc(b: ^strings.Builder, ast: Ast, imported: []Thing_Node) {
	emit_header(b, "things", len(ast.things) + len(imported))
	for decl in ast.things {
		emit_thing_record(b, decl, ast)
	}
	for decl in imported {
		emit_thing_record(b, decl, ast)
	}
}

emit_thing_record :: proc(b: ^strings.Builder, decl: Thing_Node, ast: Ast) {
	strings.write_string(b, "thing ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_string(b, encode_bool(decl.is_singleton))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.gtags))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.fields))
	emit_line(b, "")
	emit_gtags(b, decl.gtags)
	emit_fields(b, decl.fields, ast)
}

emit_fields :: proc(b: ^strings.Builder, fields: []Field_Decl, ast: Ast) {
	for field in fold_field_decls(fields, ast) {
		emit_line(b, "field ", field.name, " ", type_ref_string(field.type), " ", field_default_token(field))
	}
}

emit_data_fields :: proc(b: ^strings.Builder, fields: []Field_Decl, ast: Ast) {
	for field in fold_field_decls(fields, ast) {
		emit_line(b, "field ", field.name, " ", type_ref_string(field.type), " ", field_default_token(field))
		if field.has_migrate {
			from := field.migrate.from if field.migrate.has_from else "-"
			with := field.migrate.with if field.migrate.has_with else "-"
			emit_line(b, "migrate ", from, " ", with)
		}
	}
}

emit_gtags :: proc(b: ^strings.Builder, gtags: []string) {
	for tag in gtags {
		emit_line(b, "gtag ", encode_string(tag, context.temp_allocator))
	}
}

field_default_token :: proc(field: Field_Decl) -> string {
	if !field.has_default {
		return "-"
	}
	return strings.concatenate({"=", encode_field_default(field.default)}, context.temp_allocator)
}

encode_field_default :: proc(expr: Expr) -> string {
	#partial switch e in expr {
	case ^Variant_Expr:
		return strings.concatenate({e.type_name, "::", e.variant}, context.temp_allocator)
	case ^List_Expr:
		return "[]"
	case ^Record_Expr:
		return encode_record_default(e)
	case ^Call_Expr:
		if token, found := engine_builder_default(e); found {
			return token
		}
	}
	return encode_literal(expr)
}

engine_builder_default :: proc(call: ^Call_Expr) -> (token: string, found: bool) {
	member, is_member := call.callee.(^Member_Expr)
	if !is_member || len(call.args) != 0 {
		return "", false
	}
	type_name, is_name := member.receiver.(^Name_Expr)
	if !is_name {
		return "", false
	}
	if type_name.name == "Settings" && member.member == "defaults" {
		return SETTINGS_DEFAULT_TOKEN, true
	}
	return "", false
}

SETTINGS_DEFAULT_TOKEN :: "Settings(volume=128,fullscreen=false,access=AccessOpts(reduce_motion=false))"

@(rodata)
SETTINGS_DATA_FIELDS := []Synthetic_Field{
	{name = "volume", type_name = "Int"},
	{name = "fullscreen", type_name = "Bool"},
	{name = "access", type_name = "AccessOpts"},
}

@(rodata)
ACCESS_OPTS_DATA_FIELDS := []Synthetic_Field{
	{name = "reduce_motion", type_name = "Bool"},
}

@(rodata)
PATH_DATA_FIELDS := []Synthetic_Field{
	{name = "steps", type_name = "[Vec2]"},
	{name = "cost", type_name = "Fixed"},
}

Synthetic_Field :: struct {
	name:      string,
	type_name: string,
}

encode_record_default :: proc(record: ^Record_Expr) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, record.type_name)
	strings.write_byte(&b, '(')
	for field, i in record.fields {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, field.name)
		strings.write_byte(&b, '=')
		strings.write_string(&b, encode_field_default(field.value))
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}
