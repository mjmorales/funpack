package funpack

import "core:slice"
import "core:strings"

derive_decl_records :: proc(module: string, typed: Typed_Ast, flat: Flattened_Pipeline) -> []Decl_Record {
	ast := typed.ast
	records := make([dynamic]Decl_Record, 0, len(ast.decls), context.temp_allocator)

	for ref in ast.decls {
		switch ref.kind {
		case .Data:
			decl := ast.datas[ref.index]
			append(&records, body_less_decl(module, decl.name, .Data, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_fields(decl.probes, decl.fields), fields_hold_stub(decl.fields), decl.exposed))
		case .Enum:
			decl := ast.enums[ref.index]
			append(&records, body_less_decl(module, decl.name, .Enum, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_variant_fields(decl.probes, decl.variants), variants_hold_stub(decl.variants), decl.exposed))
		case .Thing:
			decl := ast.things[ref.index]
			append(&records, body_less_decl(module, decl.name, .Thing, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_fields(decl.probes, decl.fields), fields_hold_stub(decl.fields), decl.exposed))
		case .Signal:
			decl := ast.signals[ref.index]
			append(&records, body_less_decl(module, decl.name, .Signal, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_fields(decl.probes, decl.fields), fields_hold_stub(decl.fields), decl.exposed))
		case .Fn:
			append(&records, fn_decl_record(module, ast.fns[ref.index]))
		case .Query:
			append(&records, query_decl_record(module, ast.queries[ref.index]))
		case .Behavior:
			append(&records, behavior_decl_record(module, ast.behaviors[ref.index], typed.env, flat.routes))
		case .Pipeline:
			decl := ast.pipelines[ref.index]
			append(&records, body_less_decl(module, decl.name, .Pipeline, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_stages(decl.probes, decl.stages), false, decl.exposed))
		case .Let:
			decl := ast.lets[ref.index]
			append(&records, body_less_decl(module, decl.name, .Let, decl.line, decl.doc, decl.gtags, decl.todos, decl.probes, expr_holds_stub(decl.value), decl.exposed))
		case .Test:
			append(&records, test_decl_record(module, ast.tests[ref.index]))
		case .Extern_Type:
			decl := ast.extern_types[ref.index]
			append(&records, body_less_decl(module, decl.name, .Extern_Type, decl.line, decl.doc, decl.gtags, decl.todos, decl.probes, false, decl.exposed))
		}
	}

	return records[:]
}

body_less_decl :: proc(
	module: string,
	name: string,
	kind: Index_Decl_Kind,
	span: int,
	doc: string,
	gtags: []string,
	todos: []Todo_Node,
	probes: []Debug_Probe,
	stub: bool,
	exposed: bool,
) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, name),
		kind           = kind,
		file           = "",
		span           = span,
		doc            = doc,
		gtags          = gtags,
		stub           = stub,
		todo           = todo_flag(todos),
		debug          = probe_names(probes),
		exposed        = exposed,
		emits          = empty_strings(),
		consumes       = empty_strings(),
		calls          = empty_strings(),
		dup_class      = 0,
		mut_data       = empty_strings(),
	}
}

fn_decl_record :: proc(module: string, decl: Fn_Node) -> Decl_Record {
	kind := Index_Decl_Kind.Extern_Fn if decl.is_extern else Index_Decl_Kind.Fn
	dup: u64 = 0
	calls := empty_strings()
	if !decl.is_extern {
		dup = dup_class(decl.body)
		calls = body_calls(decl.body)
	}
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, decl.name),
		kind           = kind,
		file           = "",
		span           = decl.line,
		doc            = decl.doc,
		gtags          = decl.gtags,
		stub           = fn_holds_stub(decl),
		todo           = todo_flag(decl.todos),
		debug          = probe_names(decl.probes),
		exposed        = decl.exposed,
		emits          = empty_strings(),
		consumes       = empty_strings(),
		calls          = calls,
		dup_class      = dup,
		mut_data       = empty_strings(),
	}
}

query_decl_record :: proc(module: string, decl: Query_Node) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, decl.name),
		kind           = .Query,
		file           = "",
		span           = decl.line,
		doc            = decl.doc,
		gtags          = decl.gtags,
		stub           = body_holds_stub(decl.body),
		todo           = todo_flag(decl.todos),
		debug          = probe_names(decl.probes),
		exposed        = decl.exposed,
		emits          = empty_strings(),
		consumes       = empty_strings(),
		calls          = body_calls(decl.body),
		dup_class      = dup_class(decl.body),
		mut_data       = empty_strings(),
	}
}

behavior_decl_record :: proc(
	module: string,
	decl: Behavior_Node,
	env: Type_Env,
	routes: []Signal_Route,
) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, decl.name),
		kind           = .Behavior,
		file           = "",
		span           = decl.line,
		doc            = decl.doc,
		gtags          = decl.gtags,
		stub           = fn_holds_stub(decl.step),
		todo           = todo_flag(decl.todos),
		debug          = probe_names(decl.probes),
		exposed        = decl.exposed,
		emits          = decl_behavior_emits(decl.name, routes),
		consumes       = decl_behavior_consumes(decl.name, routes),
		calls          = body_calls(decl.step.body),
		dup_class      = dup_class(decl.step.body),
		mut_data       = behavior_mut_data(decl.name, env),
	}
}

test_decl_record :: proc(module: string, decl: Test_Node) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, decl.name),
		kind           = .Test,
		file           = "",
		span           = decl.line,
		doc            = decl.doc,
		gtags          = empty_strings(),
		stub           = body_holds_stub(decl.body),
		todo           = false,
		debug          = empty_strings(),
		exposed        = false,
		emits          = empty_strings(),
		consumes       = empty_strings(),
		calls          = body_calls(decl.body),
		dup_class      = dup_class(decl.body),
		mut_data       = empty_strings(),
	}
}

decl_behavior_emits :: proc(name: string, routes: []Signal_Route) -> []string {
	emits := make([dynamic]string, 0, 2, context.temp_allocator)
	for route in routes {
		if endpoints_hold(route.producers, name) {
			append_unique(&emits, route.signal)
		}
	}
	return emits[:]
}

decl_behavior_consumes :: proc(name: string, routes: []Signal_Route) -> []string {
	consumes := make([dynamic]string, 0, 2, context.temp_allocator)
	for route in routes {
		if endpoints_hold(route.consumers, name) {
			append_unique(&consumes, route.signal)
		}
	}
	return consumes[:]
}

endpoints_hold :: proc(endpoints: []Signal_Endpoint, name: string) -> bool {
	for endpoint in endpoints {
		if endpoint.behavior == name {
			return true
		}
	}
	return false
}

behavior_mut_data :: proc(name: string, env: Type_Env) -> []string {
	term, found := env_term_name(env, name)
	if !found || term.signature == nil {
		return empty_strings()
	}
	if !writes_own_blackboard(write_of_return(term.signature.result), term.target) {
		return empty_strings()
	}
	if term.target == "" {
		return empty_strings()
	}
	mut := make([]string, 1, context.temp_allocator)
	mut[0] = term.target
	return mut
}

body_calls :: proc(body: []Statement) -> []string {
	calls := make([dynamic]string, 0, 8, context.temp_allocator)
	calls_walk_body(body, &calls)
	return calls[:]
}

calls_walk_body :: proc(body: []Statement, calls: ^[dynamic]string) {
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			calls_walk_expr(s.value, calls)
		case Assert_Node:
			calls_walk_expr(s.expr, calls)
		case Return_Node:
			calls_walk_expr(s.value, calls)
		case If_Node:
			calls_walk_expr(s.cond, calls)
			calls_walk_body(s.body, calls)
		}
	}
}

calls_walk_expr :: proc(expr: Expr, calls: ^[dynamic]string) {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
	case ^Call_Expr:
		if name, ok := callee_name(e.callee); ok {
			append_unique(calls, name)
		}
		calls_walk_expr(e.callee, calls)
		for arg in e.args {
			calls_walk_expr(arg, calls)
		}
	case ^Member_Expr:
		calls_walk_expr(e.receiver, calls)
	case ^Variant_Expr:
		for arg in e.payload {
			calls_walk_expr(arg, calls)
		}
		for field in e.fields {
			calls_walk_expr(field.value, calls)
		}
	case ^Record_Expr:
		for field in e.fields {
			calls_walk_expr(field.value, calls)
		}
	case ^List_Expr:
		for element in e.elements {
			calls_walk_expr(element, calls)
		}
	case ^Lambda_Expr:
		calls_walk_expr(e.body, calls)
	case ^Unary_Expr:
		calls_walk_expr(e.operand, calls)
	case ^Binary_Expr:
		calls_walk_expr(e.lhs, calls)
		calls_walk_expr(e.rhs, calls)
	case ^With_Expr:
		calls_walk_expr(e.base, calls)
		for field in e.fields {
			calls_walk_expr(field.value, calls)
		}
	case ^Match_Expr:
		calls_walk_expr(e.scrutinee, calls)
		for arm in e.arms {
			calls_walk_expr(arm.body, calls)
		}
	case ^Tuple_Expr:
		for element in e.elements {
			calls_walk_expr(element, calls)
		}
	case ^If_Expr:
		calls_walk_expr(e.cond, calls)
		calls_walk_expr(e.then_branch, calls)
		calls_walk_expr(e.else_branch, calls)
	case ^Stub_Expr:
		if e.has_fallback {
			calls_walk_expr(e.fallback, calls)
		}
	}
}

callee_name :: proc(callee: Expr) -> (name: string, ok: bool) {
	#partial switch c in callee {
	case ^Name_Expr:
		return c.name, true
	case ^Member_Expr:
		return c.member, true
	}
	return "", false
}

qualify_decl :: proc(module: string, name: string) -> string {
	if module == "" {
		return name
	}
	return strings.concatenate({module, ".", name}, context.temp_allocator)
}

append_unique :: proc(list: ^[dynamic]string, name: string) {
	if slice.contains(list[:], name) {
		return
	}
	append(list, name)
}

todo_flag :: proc(todos: []Todo_Node) -> bool {
	return len(todos) > 0
}

probe_names :: proc(probes: []Debug_Probe) -> []string {
	if len(probes) == 0 {
		return empty_strings()
	}
	names := make([]string, len(probes), context.temp_allocator)
	for probe, i in probes {
		names[i] = probe_directive_name(probe.kind)
	}
	return names
}

decl_probes_with_fields :: proc(decl_probes: []Debug_Probe, fields: []Field_Decl) -> []Debug_Probe {
	combined := make([dynamic]Debug_Probe, 0, len(decl_probes) + len(fields), context.temp_allocator)
	for probe in decl_probes {
		append(&combined, probe)
	}
	for field in fields {
		for probe in field.probes {
			append(&combined, probe)
		}
	}
	return combined[:]
}

decl_probes_with_variant_fields :: proc(decl_probes: []Debug_Probe, variants: []Variant_Decl) -> []Debug_Probe {
	combined := make([dynamic]Debug_Probe, 0, len(decl_probes), context.temp_allocator)
	for probe in decl_probes {
		append(&combined, probe)
	}
	for variant in variants {
		for field in variant.fields {
			for probe in field.probes {
				append(&combined, probe)
			}
		}
	}
	return combined[:]
}

decl_probes_with_stages :: proc(decl_probes: []Debug_Probe, stages: []Pipeline_Stage) -> []Debug_Probe {
	combined := make([dynamic]Debug_Probe, 0, len(decl_probes) + len(stages), context.temp_allocator)
	for probe in decl_probes {
		append(&combined, probe)
	}
	for stage in stages {
		for probe in stage.probes {
			append(&combined, probe)
		}
	}
	return combined[:]
}

probe_directive_name :: proc(kind: Debug_Probe_Kind) -> string {
	switch kind {
	case .Break:
		return "break"
	case .Log:
		return "log"
	case .Watch:
		return "watch"
	case .Trace:
		return "trace"
	}
	return ""
}

empty_strings :: proc() -> []string {
	return nil
}
