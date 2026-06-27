package funpack

import "core:strings"

FMT_INDENT :: "  "

render_canonical :: proc(ast: Ast, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	wrote_header := false
	if ast.module_doc != "" {
		fmt_doc_line(&b, ast.module_doc)
		wrote_header = true
	}
	for imp in ast.imports {
		fmt_import(&b, imp)
		wrote_header = true
	}
	wrote_decl := wrote_header
	for ref in ast.decls {
		fmt_decl_separator(&b, &wrote_decl)
		switch ref.kind {
		case .Let:
			fmt_let_decl(&b, ast.lets[ref.index])
		case .Data:
			fmt_data(&b, ast.datas[ref.index])
		case .Enum:
			fmt_enum(&b, ast.enums[ref.index])
		case .Thing:
			fmt_thing(&b, ast.things[ref.index])
		case .Signal:
			fmt_signal(&b, ast.signals[ref.index])
		case .Fn:
			fmt_fn_decl(&b, ast.fns[ref.index])
		case .Query:
			fmt_query(&b, ast.queries[ref.index])
		case .Behavior:
			fmt_behavior(&b, ast.behaviors[ref.index])
		case .Pipeline:
			fmt_pipeline(&b, ast.pipelines[ref.index])
		case .Test:
			fmt_test(&b, ast.tests[ref.index])
		case .Extern_Type:
			fmt_extern_type(&b, ast.extern_types[ref.index])
		}
	}
	return strings.to_string(b)
}

fmt_decl_separator :: proc(b: ^strings.Builder, wrote_prior: ^bool) {
	if wrote_prior^ {
		strings.write_string(b, "\n")
	}
	wrote_prior^ = true
}

fmt_doc_line :: proc(b: ^strings.Builder, doc: string) {
	strings.write_string(b, "@doc(\"")
	strings.write_string(b, doc)
	strings.write_string(b, "\")\n")
}

fmt_import :: proc(b: ^strings.Builder, imp: Import_Node) {
	strings.write_string(b, "import ")
	for segment, i in imp.segments {
		if i > 0 {
			strings.write_string(b, ".")
		}
		strings.write_string(b, segment)
	}
	if imp.members != nil {
		strings.write_string(b, ".{")
		for member, i in imp.members {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, member)
		}
		strings.write_string(b, "}")
	}
	strings.write_string(b, "\n")
}

fmt_directives :: proc(b: ^strings.Builder, doc: string, exposed: bool, gtags: []string, todos: []Todo_Node, probes: []Debug_Probe) {
	if doc != "" {
		fmt_doc_line(b, doc)
	}
	if exposed {
		strings.write_string(b, "@expose\n")
	}
	if len(gtags) > 0 {
		strings.write_string(b, "@gtag(")
		for tag, i in gtags {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, "\"")
			strings.write_string(b, tag)
			strings.write_string(b, "\"")
		}
		strings.write_string(b, ")\n")
	}
	for todo in todos {
		strings.write_string(b, "@todo(\"")
		strings.write_string(b, todo.message)
		strings.write_string(b, "\", ")
		fmt_todo_window(b, todo.window)
		strings.write_string(b, ")\n")
	}
	for probe in probes {
		fmt_probe(b, probe)
	}
}

fmt_todo_window :: proc(b: ^strings.Builder, window: Todo_Window) {
	switch window.form {
	case .Duration:
		strings.write_i64(b, window.amount)
		strings.write_string(b, window.unit)
	case .Date:
		fmt_zero_padded(b, window.year, 4)
		strings.write_string(b, "-")
		fmt_zero_padded(b, window.month, 2)
		strings.write_string(b, "-")
		fmt_zero_padded(b, window.day, 2)
	case .Build_Count:
		strings.write_i64(b, window.amount)
		strings.write_string(b, "builds")
	case .Task_Ref:
		strings.write_string(b, "T-")
		strings.write_string(b, window.task)
	}
}

fmt_probe :: proc(b: ^strings.Builder, probe: Debug_Probe) {
	switch probe.kind {
	case .Break:
		strings.write_string(b, "@break(")
	case .Log:
		strings.write_string(b, "@log(")
	case .Watch:
		strings.write_string(b, "@watch(")
	case .Trace:
		strings.write_string(b, "@trace\n")
		return
	}
	fmt_expr(b, probe.arg, 0)
	strings.write_string(b, ")\n")
}

fmt_migrate :: proc(b: ^strings.Builder, node: Migrate_Node) {
	strings.write_string(b, "@migrate(")
	if node.has_from {
		strings.write_string(b, "from: \"")
		strings.write_string(b, node.from)
		strings.write_string(b, "\"")
	}
	if node.has_with {
		if node.has_from {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, "with: ")
		strings.write_string(b, node.with)
	}
	strings.write_string(b, ")")
}

fmt_zero_padded :: proc(b: ^strings.Builder, value: i64, width: int) {
	digits: [20]byte
	n := 0
	v := value
	for {
		digits[n] = byte('0' + v % 10)
		v /= 10
		n += 1
		if v == 0 {
			break
		}
	}
	for _ in n ..< width {
		strings.write_string(b, "0")
	}
	for i := n - 1; i >= 0; i -= 1 {
		strings.write_byte(b, digits[i])
	}
}

fmt_let_decl :: proc(b: ^strings.Builder, decl: Let_Decl_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "let ")
	strings.write_string(b, decl.name)
	strings.write_string(b, ": ")
	fmt_type_ref(b, decl.type)
	strings.write_string(b, " = ")
	fmt_expr(b, decl.value, 0)
	strings.write_string(b, "\n")
}

fmt_data :: proc(b: ^strings.Builder, decl: Data_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	if decl.has_migrate {
		fmt_migrate(b, decl.migrate)
		strings.write_string(b, "\n")
	}
	strings.write_string(b, "data ")
	strings.write_string(b, decl.name)
	fmt_type_params(b, decl.type_params)
	if decl.kind != "" {
		strings.write_string(b, ": ")
		strings.write_string(b, decl.kind)
	}
	fmt_field_list_inline(b, decl.fields)
	strings.write_string(b, "\n")
}

fmt_enum :: proc(b: ^strings.Builder, decl: Enum_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "enum ")
	strings.write_string(b, decl.name)
	fmt_type_params(b, decl.type_params)
	if decl.kind != "" {
		strings.write_string(b, ": ")
		strings.write_string(b, decl.kind)
	}
	if len(decl.variants) == 0 {
		strings.write_string(b, " {}\n")
		return
	}
	any_variant_doc := false
	for variant in decl.variants {
		if variant.doc != "" {
			any_variant_doc = true
			break
		}
	}
	if any_variant_doc {
		strings.write_string(b, " {\n")
		for variant, i in decl.variants {
			if variant.doc != "" {
				strings.write_string(b, FMT_INDENT)
				fmt_doc_line(b, variant.doc)
			}
			strings.write_string(b, FMT_INDENT)
			fmt_variant_decl(b, variant)
			if i < len(decl.variants) - 1 {
				strings.write_string(b, ",")
			}
			strings.write_string(b, "\n")
		}
		strings.write_string(b, "}\n")
		return
	}
	strings.write_string(b, " { ")
	for variant, i in decl.variants {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		fmt_variant_decl(b, variant)
	}
	strings.write_string(b, " }\n")
}

fmt_variant_decl :: proc(b: ^strings.Builder, variant: Variant_Decl) {
	strings.write_string(b, variant.name)
	switch variant.payload {
	case .Plain:
	case .Tuple:
		strings.write_string(b, "(")
		for type, i in variant.tuple {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_type_ref(b, type)
		}
		strings.write_string(b, ")")
	case .Struct:
		strings.write_string(b, "{")
		for field, i in variant.fields {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, field.name)
			strings.write_string(b, ": ")
			fmt_type_ref(b, field.type)
		}
		strings.write_string(b, "}")
	}
}

fmt_thing :: proc(b: ^strings.Builder, decl: Thing_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "singleton " if decl.is_singleton else "thing ")
	strings.write_string(b, decl.name)
	strings.write_string(b, " {\n")
	fmt_fields_aligned(b, decl.fields)
	strings.write_string(b, "}\n")
}

fmt_signal :: proc(b: ^strings.Builder, decl: Signal_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "signal ")
	strings.write_string(b, decl.name)
	fmt_field_list_inline(b, decl.fields)
	strings.write_string(b, "\n")
}

fmt_field_list_inline :: proc(b: ^strings.Builder, fields: []Field_Decl) {
	if len(fields) == 0 {
		strings.write_string(b, " {}")
		return
	}
	strings.write_string(b, " { ")
	for field, i in fields {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		if field.has_migrate {
			fmt_migrate(b, field.migrate)
			strings.write_string(b, " ")
		}
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		fmt_type_ref(b, field.type)
		if field.has_default {
			strings.write_string(b, " = ")
			fmt_expr(b, field.default, 0)
		}
	}
	strings.write_string(b, " }")
}

fmt_fields_aligned :: proc(b: ^strings.Builder, fields: []Field_Decl) {
	longest := 0
	for field in fields {
		if len(field.name) > longest {
			longest = len(field.name)
		}
	}
	for field in fields {
		strings.write_string(b, FMT_INDENT)
		strings.write_string(b, field.name)
		strings.write_string(b, ":")
		for _ in 0 ..< longest - len(field.name) + 1 {
			strings.write_string(b, " ")
		}
		fmt_type_ref(b, field.type)
		if field.has_default {
			strings.write_string(b, " = ")
			fmt_expr(b, field.default, 0)
		}
		strings.write_string(b, "\n")
	}
}

fmt_fn_decl :: proc(b: ^strings.Builder, decl: Fn_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	if decl.is_extern {
		strings.write_string(b, "extern ")
	}
	strings.write_string(b, "fn ")
	strings.write_string(b, decl.name)
	fmt_signature(b, decl.params, decl.return_type)
	if decl.is_extern {
		strings.write_string(b, "\n")
		return
	}
	if decl.holed {
		strings.write_string(b, " ")
		fmt_stub(b, decl.hole_type, decl.fallback, decl.has_fallback, 0)
		strings.write_string(b, "\n")
		return
	}
	strings.write_string(b, " {\n")
	fmt_statements(b, decl.body, 1)
	strings.write_string(b, "}\n")
}

fmt_extern_type :: proc(b: ^strings.Builder, decl: Extern_Type_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "extern type ")
	strings.write_string(b, decl.name)
	fmt_type_params(b, decl.type_params)
	strings.write_string(b, "\n")
}

fmt_type_params :: proc(b: ^strings.Builder, params: []string) {
	if len(params) == 0 {
		return
	}
	strings.write_string(b, "[")
	for param, i in params {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, param)
	}
	strings.write_string(b, "]")
}

fmt_signature :: proc(b: ^strings.Builder, params: []Param_Decl, return_type: Type_Ref) {
	strings.write_string(b, "(")
	for param, i in params {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, param.name)
		strings.write_string(b, ": ")
		fmt_type_ref(b, param.type)
	}
	strings.write_string(b, ") -> ")
	fmt_type_ref(b, return_type)
}

fmt_query :: proc(b: ^strings.Builder, decl: Query_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	for index in decl.indexes {
		switch index.kind {
		case .Index:
			strings.write_string(b, "@index(")
		case .Spatial:
			strings.write_string(b, "@spatial(")
		}
		strings.write_string(b, index.thing)
		strings.write_string(b, ".")
		strings.write_string(b, index.field)
		strings.write_string(b, ")\n")
	}
	strings.write_string(b, "query ")
	strings.write_string(b, decl.name)
	fmt_signature(b, decl.params, decl.return_type)
	strings.write_string(b, " {\n")
	fmt_statements(b, decl.body, 1)
	strings.write_string(b, "}\n")
}

fmt_behavior :: proc(b: ^strings.Builder, decl: Behavior_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "behavior ")
	strings.write_string(b, decl.name)
	strings.write_string(b, " on ")
	strings.write_string(b, decl.target)
	strings.write_string(b, " {\n")
	strings.write_string(b, FMT_INDENT)
	strings.write_string(b, "fn step")
	fmt_signature(b, decl.step.params, decl.step.return_type)
	if decl.step.holed {
		strings.write_string(b, " ")
		fmt_stub(b, decl.step.hole_type, decl.step.fallback, decl.step.has_fallback, 1)
		strings.write_string(b, "\n")
	} else {
		strings.write_string(b, " {\n")
		fmt_statements(b, decl.step.body, 2)
		strings.write_string(b, FMT_INDENT)
		strings.write_string(b, "}\n")
	}
	strings.write_string(b, "}\n")
}

fmt_pipeline :: proc(b: ^strings.Builder, decl: Pipeline_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "pipeline ")
	strings.write_string(b, decl.name)
	strings.write_string(b, " {\n")
	longest := 0
	for stage in decl.stages {
		if len(stage.name) > longest {
			longest = len(stage.name)
		}
	}
	for stage in decl.stages {
		strings.write_string(b, FMT_INDENT)
		strings.write_string(b, stage.name)
		strings.write_string(b, ":")
		for _ in 0 ..< longest - len(stage.name) + 1 {
			strings.write_string(b, " ")
		}
		if stage.is_battery {
			strings.write_string(b, stage.battery)
		} else {
			strings.write_string(b, "[")
			for name, i in stage.behaviors {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				strings.write_string(b, name)
			}
			strings.write_string(b, "]")
		}
		strings.write_string(b, "\n")
	}
	strings.write_string(b, "}\n")
}

fmt_test :: proc(b: ^strings.Builder, decl: Test_Node) {
	if decl.doc != "" {
		fmt_doc_line(b, decl.doc)
	}
	strings.write_string(b, "test \"")
	strings.write_string(b, decl.name)
	strings.write_string(b, "\" {\n")
	fmt_statements(b, decl.body, 1)
	strings.write_string(b, "}\n")
}

fmt_statements :: proc(b: ^strings.Builder, stmts: []Statement, indent: int) {
	for stmt in stmts {
		fmt_statement(b, stmt, indent)
	}
}

fmt_statement :: proc(b: ^strings.Builder, stmt: Statement, indent: int) {
	switch node in stmt {
	case Let_Node:
		fmt_write_indent(b, indent)
		strings.write_string(b, "let ")
		if node.is_tuple {
			strings.write_string(b, "(")
			for name, i in node.names {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				strings.write_string(b, name)
			}
			strings.write_string(b, ")")
		} else {
			strings.write_string(b, node.name)
		}
		strings.write_string(b, " = ")
		fmt_expr(b, node.value, indent)
		strings.write_string(b, "\n")
	case Assert_Node:
		fmt_write_indent(b, indent)
		strings.write_string(b, "assert ")
		fmt_expr(b, node.expr, indent)
		strings.write_string(b, "\n")
	case Return_Node:
		fmt_write_indent(b, indent)
		strings.write_string(b, "return ")
		fmt_expr(b, node.value, indent)
		strings.write_string(b, "\n")
	case If_Node:
		fmt_if_stmt(b, node, indent)
	}
}

fmt_if_stmt :: proc(b: ^strings.Builder, node: If_Node, indent: int) {
	if len(node.body) == 1 {
		inner := strings.builder_make(context.temp_allocator)
		fmt_statement(&inner, node.body[0], 0)
		rendered := strings.to_string(inner)
		if strings.count(rendered, "\n") == 1 {
			fmt_write_indent(b, indent)
			strings.write_string(b, "if ")
			fmt_guarded_expr(b, node.cond, indent)
			strings.write_string(b, " { ")
			strings.write_string(b, strings.trim_suffix(rendered, "\n"))
			strings.write_string(b, " }\n")
			return
		}
	}
	fmt_write_indent(b, indent)
	strings.write_string(b, "if ")
	fmt_guarded_expr(b, node.cond, indent)
	strings.write_string(b, " {\n")
	fmt_statements(b, node.body, indent + 1)
	fmt_write_indent(b, indent)
	strings.write_string(b, "}\n")
}

fmt_write_indent :: proc(b: ^strings.Builder, indent: int) {
	for _ in 0 ..< indent {
		strings.write_string(b, FMT_INDENT)
	}
}

fmt_type_ref :: proc(b: ^strings.Builder, type: Type_Ref) {
	switch type.name {
	case "[]":
		strings.write_string(b, "[")
		fmt_type_ref(b, type.args[0])
		strings.write_string(b, "]")
	case "fn":
		strings.write_string(b, "fn(")
		for arg, i in type.args[:len(type.args)-1] {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_type_ref(b, arg)
		}
		strings.write_string(b, ") -> ")
		fmt_type_ref(b, type.args[len(type.args)-1])
	case "()":
		strings.write_string(b, "(")
		for arg, i in type.args {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_type_ref(b, arg)
		}
		strings.write_string(b, ")")
	case:
		strings.write_string(b, type.name)
		if len(type.args) > 0 {
			strings.write_string(b, "[")
			for arg, i in type.args {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				fmt_type_ref(b, arg)
			}
			strings.write_string(b, "]")
		}
	}
}

fmt_expr :: proc(b: ^strings.Builder, expr: Expr, indent: int) {
	switch e in expr {
	case ^Int_Lit_Expr:
		strings.write_i64(b, e.value)
	case ^Fixed_Lit_Expr:
		fmt_fixed_literal(b, e.bits)
	case ^String_Lit_Expr:
		strings.write_string(b, "\"")
		strings.write_string(b, e.text)
		strings.write_string(b, "\"")
	case ^Name_Expr:
		strings.write_string(b, e.name)
	case ^Call_Expr:
		fmt_postfix_operand(b, e.callee, indent)
		strings.write_string(b, "(")
		for arg, i in e.args {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_expr(b, arg, indent)
		}
		strings.write_string(b, ")")
	case ^Member_Expr:
		fmt_postfix_operand(b, e.receiver, indent)
		strings.write_string(b, ".")
		strings.write_string(b, e.member)
	case ^Variant_Expr:
		strings.write_string(b, e.type_name)
		strings.write_string(b, "::")
		strings.write_string(b, e.variant)
		if e.has_payload {
			strings.write_string(b, "(")
			for arg, i in e.payload {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				fmt_expr(b, arg, indent)
			}
			strings.write_string(b, ")")
		}
		if e.has_fields {
			fmt_record_fields_tight(b, e.fields, indent)
		}
	case ^Record_Expr:
		strings.write_string(b, e.type_name)
		fmt_record_fields_tight(b, e.fields, indent)
	case ^List_Expr:
		strings.write_string(b, "[")
		for element, i in e.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_expr(b, element, indent)
		}
		strings.write_string(b, "]")
	case ^Tuple_Expr:
		strings.write_string(b, "(")
		for element, i in e.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_expr(b, element, indent)
		}
		strings.write_string(b, ")")
	case ^Lambda_Expr:
		strings.write_string(b, "fn(")
		for param, i in e.params {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, param)
		}
		strings.write_string(b, ") { return ")
		fmt_expr(b, e.body, indent)
		strings.write_string(b, " }")
	case ^Unary_Expr:
		strings.write_string(b, e.op.text)
		if e.op.kind == .Ident {
			strings.write_string(b, " ")
		}
		fmt_unary_operand(b, e.operand, indent)
	case ^Binary_Expr:
		fmt_binary_operand(b, e.lhs, infix_power(e.op), false, indent)
		strings.write_string(b, " ")
		strings.write_string(b, e.op.text)
		strings.write_string(b, " ")
		fmt_binary_operand(b, e.rhs, infix_power(e.op), true, indent)
	case ^With_Expr:
		fmt_with_base(b, e.base, indent)
		strings.write_string(b, " with { ")
		for field, i in e.fields {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, field.name)
			strings.write_string(b, ": ")
			fmt_expr(b, field.value, indent)
		}
		strings.write_string(b, " }")
	case ^Match_Expr:
		fmt_match(b, e, indent)
	case ^If_Expr:
		fmt_if_expr(b, e, indent)
	case ^Stub_Expr:
		fmt_stub(b, e.hole_type, e.fallback, e.has_fallback, indent)
	case ^All_Expr:
		strings.write_string(b, "all[")
		strings.write_string(b, e.thing)
		strings.write_string(b, "]")
	}
}

fmt_record_fields_tight :: proc(b: ^strings.Builder, fields: []Record_Field, indent: int) {
	strings.write_string(b, "{")
	for field, i in fields {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		fmt_expr(b, field.value, indent)
	}
	strings.write_string(b, "}")
}

fmt_stub :: proc(b: ^strings.Builder, hole_type: Type_Ref, fallback: Expr, has_fallback: bool, indent: int) {
	strings.write_string(b, "@stub(")
	fmt_type_ref(b, hole_type)
	if has_fallback {
		strings.write_string(b, ", ")
		fmt_expr(b, fallback, indent)
	}
	strings.write_string(b, ")")
}

fmt_match :: proc(b: ^strings.Builder, e: ^Match_Expr, indent: int) {
	strings.write_string(b, "match ")
	fmt_guarded_expr(b, e.scrutinee, indent)
	strings.write_string(b, " {\n")
	for arm in e.arms {
		fmt_write_indent(b, indent + 1)
		fmt_pattern(b, arm.pattern)
		strings.write_string(b, " => ")
		fmt_expr(b, arm.body, indent + 1)
		strings.write_string(b, "\n")
	}
	fmt_write_indent(b, indent)
	strings.write_string(b, "}")
}

fmt_if_expr :: proc(b: ^strings.Builder, e: ^If_Expr, indent: int) {
	strings.write_string(b, "if ")
	fmt_guarded_expr(b, e.cond, indent)
	strings.write_string(b, " { ")
	fmt_expr(b, e.then_branch, indent)
	strings.write_string(b, " } else ")
	if chained, is_if := e.else_branch.(^If_Expr); is_if {
		fmt_if_expr(b, chained, indent)
		return
	}
	strings.write_string(b, "{ ")
	fmt_expr(b, e.else_branch, indent)
	strings.write_string(b, " }")
}

fmt_guarded_expr :: proc(b: ^strings.Builder, expr: Expr, indent: int) {
	if fmt_spine_exposes_brace(expr) {
		strings.write_string(b, "(")
		fmt_expr(b, expr, indent)
		strings.write_string(b, ")")
		return
	}
	fmt_expr(b, expr, indent)
}

fmt_spine_exposes_brace :: proc(expr: Expr) -> bool {
	switch e in expr {
	case ^Record_Expr:
		return true
	case ^Variant_Expr:
		return e.has_fields
	case ^Match_Expr:
		return true
	case ^If_Expr:
		return fmt_spine_exposes_brace(e.then_branch) || fmt_spine_exposes_brace(e.else_branch)
	case ^Lambda_Expr:
		return fmt_spine_exposes_brace(e.body)
	case ^With_Expr:
		return fmt_spine_exposes_brace(e.base)
	case ^Unary_Expr:
		return fmt_spine_exposes_brace(e.operand)
	case ^Binary_Expr:
		return fmt_spine_exposes_brace(e.lhs) || fmt_spine_exposes_brace(e.rhs)
	case ^Member_Expr:
		return fmt_spine_exposes_brace(e.receiver)
	case ^Call_Expr:
		return fmt_spine_exposes_brace(e.callee)
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^List_Expr, ^Tuple_Expr, ^Stub_Expr, ^All_Expr:
		return false
	}
	return false
}

fmt_binary_operand :: proc(b: ^strings.Builder, operand: Expr, parent_power: Binding_Power, is_right: bool, indent: int) {
	if child, is_binary := operand.(^Binary_Expr); is_binary {
		child_power := infix_power(child.op)
		if child_power < parent_power || (is_right && child_power == parent_power) {
			strings.write_string(b, "(")
			fmt_expr(b, operand, indent)
			strings.write_string(b, ")")
			return
		}
	}
	fmt_expr(b, operand, indent)
}

fmt_unary_operand :: proc(b: ^strings.Builder, operand: Expr, indent: int) {
	if _, is_binary := operand.(^Binary_Expr); is_binary {
		strings.write_string(b, "(")
		fmt_expr(b, operand, indent)
		strings.write_string(b, ")")
		return
	}
	fmt_expr(b, operand, indent)
}

fmt_with_base :: proc(b: ^strings.Builder, base: Expr, indent: int) {
	needs_parens := false
	#partial switch _ in base {
	case ^Binary_Expr, ^Unary_Expr:
		needs_parens = true
	}
	if needs_parens {
		strings.write_string(b, "(")
		fmt_expr(b, base, indent)
		strings.write_string(b, ")")
		return
	}
	fmt_expr(b, base, indent)
}

fmt_postfix_operand :: proc(b: ^strings.Builder, operand: Expr, indent: int) {
	needs_parens := false
	#partial switch _ in operand {
	case ^Binary_Expr, ^Unary_Expr, ^With_Expr:
		needs_parens = true
	}
	if needs_parens {
		strings.write_string(b, "(")
		fmt_expr(b, operand, indent)
		strings.write_string(b, ")")
		return
	}
	fmt_expr(b, operand, indent)
}

fmt_pattern :: proc(b: ^strings.Builder, pattern: Pattern) {
	switch pattern.kind {
	case .Wildcard:
		strings.write_string(b, "_")
	case .Bare_Binder:
		strings.write_string(b, pattern.binders[0])
	case .Bare_Variant:
		strings.write_string(b, pattern.type_name)
		strings.write_string(b, "::")
		strings.write_string(b, pattern.variant)
	case .Variant_Binds:
		strings.write_string(b, pattern.type_name)
		strings.write_string(b, "::")
		strings.write_string(b, pattern.variant)
		strings.write_string(b, "(")
		for element, i in pattern.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_pattern(b, element)
		}
		strings.write_string(b, ")")
	case .Struct_Binds:
		strings.write_string(b, pattern.type_name)
		strings.write_string(b, "::")
		strings.write_string(b, pattern.variant)
		strings.write_string(b, "{")
		for binder, i in pattern.binders {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, binder)
		}
		strings.write_string(b, "}")
	case .Tuple:
		strings.write_string(b, "(")
		for element, i in pattern.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_pattern(b, element)
		}
		strings.write_string(b, ")")
	}
}

fmt_fixed_literal :: proc(b: ^strings.Builder, bits: Fixed) {
	value := bits
	if value < 0 {
		strings.write_string(b, "-")
		value = fixed_neg(value)
	}
	int_part := i64(value) >> FIXED_FRACTION_BITS
	frac := u128(i64(value) & ((1 << FIXED_FRACTION_BITS) - 1))
	strings.write_i64(b, int_part)
	strings.write_string(b, ".")
	if frac == 0 {
		strings.write_string(b, "0")
		return
	}
	pow: u128 = 1
	for width in 1 ..= 10 {
		pow *= 10
		digits := (frac * pow + (1 << (FIXED_FRACTION_BITS - 1))) >> FIXED_FRACTION_BITS
		if (digits << FIXED_FRACTION_BITS + pow / 2) / pow == frac {
			fmt_zero_padded(b, i64(digits), width)
			return
		}
	}
}
