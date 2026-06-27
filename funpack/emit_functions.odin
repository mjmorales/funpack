package funpack

import "core:strings"

emit_functions :: proc(b: ^strings.Builder, ast: Ast, module: string, imported_fns: []Function_Record) {
	records := function_records(ast, module)
	emit_header(b, "functions", len(records) + len(imported_fns))
	for record in records {
		emit_function_record(b, record)
	}
	for record in imported_fns {
		emit_function_record(b, record)
	}
}

Function_Record :: struct {
	name:         string,
	kind:         string,
	params:       []Param_Decl,
	return_type:  Type_Ref,
	body:         []Statement,
	line:         int,
	module:       string,
	holed:        bool,
	has_fallback: bool,
	fallback:     Expr,
}

function_records :: proc(ast: Ast, module: string) -> []Function_Record {
	records := make([dynamic]Function_Record, 0, len(ast.fns) + len(ast.lets), context.temp_allocator)
	append_fn_records(&records, ast, "fn", module)
	for decl in ast.lets {
		append(&records, Function_Record{
			name        = decl.name,
			kind        = "const",
			params      = nil,
			return_type = decl.type,
			body        = const_body(decl),
			line        = decl.line,
			module      = module,
		})
	}
	append_fn_records(&records, ast, "bindings", module)
	append_fn_records(&records, ast, "startup", module)
	return records[:]
}

append_fn_records :: proc(records: ^[dynamic]Function_Record, ast: Ast, kind: string, module: string) {
	for fn in ast.fns {
		if fn.is_extern {
			continue
		}
		if function_kind(fn.name) != kind {
			continue
		}
		append(records, Function_Record{
			name         = fn.name,
			kind         = kind,
			params       = fn.params,
			return_type  = fn.return_type,
			body         = fn.body,
			line         = fn.line,
			module       = module,
			holed        = fn.holed,
			has_fallback = fn.has_fallback,
			fallback     = fn.fallback,
		})
	}
}

function_kind :: proc(name: string) -> string {
	switch name {
	case "bindings":
		return "bindings"
	case "setup":
		return "startup"
	}
	return "fn"
}

const_body :: proc(decl: Let_Decl_Node) -> []Statement {
	body := make([]Statement, 1, context.temp_allocator)
	body[0] = Return_Node{value = decl.value}
	return body
}

emit_function_record :: proc(b: ^strings.Builder, record: Function_Record) {
	strings.write_string(b, "function ")
	strings.write_string(b, record.name)
	strings.write_byte(b, ' ')
	strings.write_string(b, record.kind)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(record.params))
	strings.write_string(b, " return:")
	strings.write_string(b, type_ref_string(record.return_type))
	strings.write_byte(b, ' ')
	strings.write_int(b, executable_body_count(record.holed, record.body))
	strings.write_string(b, " span:")
	strings.write_string(b, record.module)
	strings.write_byte(b, ':')
	strings.write_int(b, record.line)
	emit_line(b, "")
	for param in record.params {
		emit_line(b, "param ", param.name, " ", type_ref_string(param.type))
	}
	emit_executable_body(b, record.holed, record.has_fallback, record.fallback, record.body)
}
