package funpack

import "core:slice"
import "core:strings"

whole_module_user_imports :: proc(entry_ast: Ast, module_asts: map[string]Ast) -> []string {
	names := make([dynamic]string, 0, 2, context.temp_allocator)
	for import_node in entry_ast.imports {
		if len(import_node.segments) != 1 || len(import_node.members) != 0 {
			continue
		}
		candidate := import_node.segments[0]
		if _, present := module_asts[candidate]; !present {
			continue
		}
		append(&names, candidate)
	}
	return names[:]
}

collect_whole_module_const_records :: proc(entry_ast: Ast, module_asts: map[string]Ast) -> []Function_Record {
	if len(module_asts) == 0 {
		return nil
	}
	imports := whole_module_user_imports(entry_ast, module_asts)
	if len(imports) == 0 {
		return nil
	}
	records := make([dynamic]Function_Record, 0, 2, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for ref in collect_whole_module_refs(entry_ast, imports) {
		key := whole_module_ref_key(ref.module, ref.member)
		if seen[key] {
			continue
		}
		seen[key] = true
		seam_ast := module_asts[ref.module]
		decl, found := find_let(seam_ast, ref.member)
		if !found {
			continue
		}
		append(&records, Function_Record {
			name        = decl.name,
			kind        = "const",
			params      = nil,
			return_type = decl.type,
			body        = const_body(decl),
			line        = decl.line,
			module      = ref.module,
		})
	}
	return records[:]
}

Whole_Module_Ref :: struct {
	module: string,
	member: string,
}

whole_module_ref_key :: proc(module: string, member: string) -> string {
	return strings.concatenate({module, "\x00", member}, context.temp_allocator)
}

collect_whole_module_refs :: proc(entry_ast: Ast, imports: []string) -> []Whole_Module_Ref {
	refs := make([dynamic]Whole_Module_Ref, 0, 4, context.temp_allocator)
	for behavior in entry_ast.behaviors {
		collect_refs_in_statements(&refs, behavior.step.body, imports)
	}
	for fn in entry_ast.fns {
		collect_refs_in_statements(&refs, fn.body, imports)
	}
	for decl in entry_ast.lets {
		collect_refs_in_expr(&refs, decl.value, imports)
	}
	return refs[:]
}

collect_refs_in_statements :: proc(refs: ^[dynamic]Whole_Module_Ref, body: []Statement, imports: []string) {
	for stmt in body {
		switch s in stmt {
		case Assert_Node:
			collect_refs_in_expr(refs, s.expr, imports)
		case Let_Node:
			collect_refs_in_expr(refs, s.value, imports)
		case Return_Node:
			collect_refs_in_expr(refs, s.value, imports)
		case If_Node:
			collect_refs_in_expr(refs, s.cond, imports)
			collect_refs_in_statements(refs, s.body, imports)
		}
	}
}

collect_refs_in_expr :: proc(refs: ^[dynamic]Whole_Module_Ref, expr: Expr, imports: []string) {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
	case ^Member_Expr:
		if name, is_name := e.receiver.(^Name_Expr); is_name && slice.contains(imports, name.name) {
			append(refs, Whole_Module_Ref{module = name.name, member = e.member})
			return
		}
		collect_refs_in_expr(refs, e.receiver, imports)
	case ^Call_Expr:
		collect_refs_in_expr(refs, e.callee, imports)
		for arg in e.args {
			collect_refs_in_expr(refs, arg, imports)
		}
	case ^Variant_Expr:
		for arg in e.payload {
			collect_refs_in_expr(refs, arg, imports)
		}
		for field in e.fields {
			collect_refs_in_expr(refs, field.value, imports)
		}
	case ^Record_Expr:
		for field in e.fields {
			collect_refs_in_expr(refs, field.value, imports)
		}
	case ^List_Expr:
		for element in e.elements {
			collect_refs_in_expr(refs, element, imports)
		}
	case ^Lambda_Expr:
		collect_refs_in_expr(refs, e.body, imports)
	case ^Unary_Expr:
		collect_refs_in_expr(refs, e.operand, imports)
	case ^Binary_Expr:
		collect_refs_in_expr(refs, e.lhs, imports)
		collect_refs_in_expr(refs, e.rhs, imports)
	case ^With_Expr:
		collect_refs_in_expr(refs, e.base, imports)
		for field in e.fields {
			collect_refs_in_expr(refs, field.value, imports)
		}
	case ^Match_Expr:
		collect_refs_in_expr(refs, e.scrutinee, imports)
		for arm in e.arms {
			collect_refs_in_expr(refs, arm.body, imports)
		}
	case ^Tuple_Expr:
		for element in e.elements {
			collect_refs_in_expr(refs, element, imports)
		}
	case ^If_Expr:
		collect_refs_in_expr(refs, e.cond, imports)
		collect_refs_in_expr(refs, e.then_branch, imports)
		collect_refs_in_expr(refs, e.else_branch, imports)
	case ^Stub_Expr:
		if e.has_fallback {
			collect_refs_in_expr(refs, e.fallback, imports)
		}
	}
}

concat_function_records :: proc(first: []Function_Record, second: []Function_Record) -> []Function_Record {
	out := make([dynamic]Function_Record, 0, len(first) + len(second), context.temp_allocator)
	append(&out, ..first)
	append(&out, ..second)
	return out[:]
}

Whole_Module_Lower_Error :: enum {
	None,
	Bare_Name_Collision,
}

Whole_Module_Lower_Verdict :: struct {
	err:  Whole_Module_Lower_Error,
	name: string,
}

lower_whole_module_refs :: proc(entry_ast: ^Ast, module_asts: map[string]Ast) -> Whole_Module_Lower_Verdict {
	if len(module_asts) == 0 {
		return Whole_Module_Lower_Verdict{}
	}
	imports := whole_module_user_imports(entry_ast^, module_asts)
	if len(imports) == 0 {
		return Whole_Module_Lower_Verdict{}
	}
	own_names := entrypoint_own_decl_names(entry_ast^)
	for ref in collect_whole_module_refs(entry_ast^, imports) {
		seam_ast := module_asts[ref.module]
		if _, found := find_let(seam_ast, ref.member); !found {
			continue
		}
		if slice.contains(own_names, ref.member) {
			return Whole_Module_Lower_Verdict{err = .Bare_Name_Collision, name = ref.member}
		}
	}
	for &behavior in entry_ast.behaviors {
		lower_refs_in_statements(behavior.step.body, imports, module_asts)
	}
	for &fn in entry_ast.fns {
		lower_refs_in_statements(fn.body, imports, module_asts)
	}
	for &decl in entry_ast.lets {
		lower_ref_in_expr(&decl.value, imports, module_asts)
	}
	return Whole_Module_Lower_Verdict{}
}

entrypoint_own_decl_names :: proc(ast: Ast) -> []string {
	names := make([dynamic]string, 0, len(ast.fns) + len(ast.lets), context.temp_allocator)
	for fn in ast.fns {
		append(&names, fn.name)
	}
	for decl in ast.lets {
		append(&names, decl.name)
	}
	return names[:]
}

lower_refs_in_statements :: proc(body: []Statement, imports: []string, module_asts: map[string]Ast) {
	for &stmt in body {
		switch &s in stmt {
		case Assert_Node:
			lower_ref_in_expr(&s.expr, imports, module_asts)
		case Let_Node:
			lower_ref_in_expr(&s.value, imports, module_asts)
		case Return_Node:
			lower_ref_in_expr(&s.value, imports, module_asts)
		case If_Node:
			lower_ref_in_expr(&s.cond, imports, module_asts)
			lower_refs_in_statements(s.body, imports, module_asts)
		}
	}
}

lower_ref_in_expr :: proc(slot: ^Expr, imports: []string, module_asts: map[string]Ast) {
	switch e in slot^ {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
	case ^Member_Expr:
		if name, is_name := e.receiver.(^Name_Expr); is_name && slice.contains(imports, name.name) {
			seam_ast := module_asts[name.name]
			if _, found := find_let(seam_ast, e.member); found {
				lowered := new(Name_Expr, context.temp_allocator)
				lowered.name = e.member
				lowered.class = .Snake_Case
				slot^ = lowered
				return
			}
		}
		lower_ref_in_expr(&e.receiver, imports, module_asts)
	case ^Call_Expr:
		lower_ref_in_expr(&e.callee, imports, module_asts)
		for &arg in e.args {
			lower_ref_in_expr(&arg, imports, module_asts)
		}
	case ^Variant_Expr:
		for &arg in e.payload {
			lower_ref_in_expr(&arg, imports, module_asts)
		}
		for &field in e.fields {
			lower_ref_in_expr(&field.value, imports, module_asts)
		}
	case ^Record_Expr:
		for &field in e.fields {
			lower_ref_in_expr(&field.value, imports, module_asts)
		}
	case ^List_Expr:
		for &element in e.elements {
			lower_ref_in_expr(&element, imports, module_asts)
		}
	case ^Lambda_Expr:
		lower_ref_in_expr(&e.body, imports, module_asts)
	case ^Unary_Expr:
		lower_ref_in_expr(&e.operand, imports, module_asts)
	case ^Binary_Expr:
		lower_ref_in_expr(&e.lhs, imports, module_asts)
		lower_ref_in_expr(&e.rhs, imports, module_asts)
	case ^With_Expr:
		lower_ref_in_expr(&e.base, imports, module_asts)
		for &field in e.fields {
			lower_ref_in_expr(&field.value, imports, module_asts)
		}
	case ^Match_Expr:
		lower_ref_in_expr(&e.scrutinee, imports, module_asts)
		for &arm in e.arms {
			lower_ref_in_expr(&arm.body, imports, module_asts)
		}
	case ^Tuple_Expr:
		for &element in e.elements {
			lower_ref_in_expr(&element, imports, module_asts)
		}
	case ^If_Expr:
		lower_ref_in_expr(&e.cond, imports, module_asts)
		lower_ref_in_expr(&e.then_branch, imports, module_asts)
		lower_ref_in_expr(&e.else_branch, imports, module_asts)
	case ^Stub_Expr:
		if e.has_fallback {
			lower_ref_in_expr(&e.fallback, imports, module_asts)
		}
	}
}
