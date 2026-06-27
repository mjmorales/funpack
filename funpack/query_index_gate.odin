package funpack

import "core:slice"

check_query_index_gate :: proc(ast: Ast) -> Gate_Verdict {
	for query in ast.queries {
		trace := query_body_trace(query.body)
		for thing in trace.spatial_needs {
			if !query_declares_index(query.indexes, .Spatial, thing) {
				return Gate_Verdict{err = .Query_Missing_Index, declaration = query.name, line = query.line}
			}
		}
		for directive in query.indexes {
			if !query_directive_used(directive, trace) {
				return Gate_Verdict{err = .Query_Unused_Index, declaration = query.name, line = query.line}
			}
		}
	}
	return Gate_Verdict{err = .None}
}

Query_Body_Trace :: struct {
	spatial_needs:  [dynamic]string,
	world_reads:    [dynamic]string,
	untraced_spatial: bool,
}

Trace_Lets :: map[string][]string

query_declares_index :: proc(indexes: []Index_Directive, kind: Index_Directive_Kind, thing: string) -> bool {
	for directive in indexes {
		if directive.kind == kind && directive.thing == thing {
			return true
		}
	}
	return false
}

query_directive_used :: proc(directive: Index_Directive, trace: Query_Body_Trace) -> bool {
	switch directive.kind {
	case .Spatial:
		return slice.contains(trace.spatial_needs[:], directive.thing) || trace.untraced_spatial
	case .Index:
		return slice.contains(trace.world_reads[:], directive.thing)
	}
	return false
}

query_body_trace :: proc(body: []Statement) -> Query_Body_Trace {
	trace := Query_Body_Trace {
		spatial_needs = make([dynamic]string, 0, 2, context.temp_allocator),
		world_reads   = make([dynamic]string, 0, 2, context.temp_allocator),
	}
	lets := make(Trace_Lets, context.temp_allocator)
	trace_statements(body, &trace, &lets)
	return trace
}

trace_statements :: proc(body: []Statement, trace: ^Query_Body_Trace, lets: ^Trace_Lets) {
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			trace_expr(node.value, trace, lets)
			lets[node.name] = expr_world_things(node.value, lets)
		case Return_Node:
			trace_expr(node.value, trace, lets)
		case If_Node:
			trace_expr(node.cond, trace, lets)
			trace_statements(node.body, trace, lets)
		case Assert_Node:
			trace_expr(node.expr, trace, lets)
		}
	}
}

trace_expr :: proc(expr: Expr, trace: ^Query_Body_Trace, lets: ^Trace_Lets) {
	if all, is_all := expr.(^All_Expr); is_all {
		append_unique(&trace.world_reads, all.thing)
		return
	}
	if call, is_call := expr.(^Call_Expr); is_call {
		if name, is_name := call.callee.(^Name_Expr); is_name && len(call.args) >= 1 {
			if name.name == "within" || name.name == "nearest_first" {
				traced := expr_world_things(call.args[0], lets)
				if len(traced) == 0 {
					trace.untraced_spatial = true
				}
				for thing in traced {
					append_unique(&trace.spatial_needs, thing)
				}
			}
		}
	}
	for child in expr_children(expr) {
		trace_expr(child, trace, lets)
	}
}

expr_world_things :: proc(expr: Expr, lets: ^Trace_Lets) -> []string {
	things := make([dynamic]string, 0, 2, context.temp_allocator)
	collect_world_things(expr, lets, &things)
	return things[:]
}

collect_world_things :: proc(expr: Expr, lets: ^Trace_Lets, things: ^[dynamic]string) {
	if all, is_all := expr.(^All_Expr); is_all {
		append_unique(things, all.thing)
		return
	}
	if name, is_name := expr.(^Name_Expr); is_name {
		if carried, bound := lets[name.name]; bound {
			for thing in carried {
				append_unique(things, thing)
			}
		}
		return
	}
	for child in expr_children(expr) {
		collect_world_things(child, lets, things)
	}
}

expr_children :: proc(expr: Expr) -> []Expr {
	children := make([dynamic]Expr, 0, 4, context.temp_allocator)
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
	case ^Call_Expr:
		append(&children, e.callee)
		for arg in e.args {
			append(&children, arg)
		}
	case ^Member_Expr:
		append(&children, e.receiver)
	case ^Variant_Expr:
		for arg in e.payload {
			append(&children, arg)
		}
		for field in e.fields {
			append(&children, field.value)
		}
	case ^Record_Expr:
		for field in e.fields {
			append(&children, field.value)
		}
	case ^List_Expr:
		for element in e.elements {
			append(&children, element)
		}
	case ^Lambda_Expr:
		append(&children, e.body)
	case ^Unary_Expr:
		append(&children, e.operand)
	case ^Binary_Expr:
		append(&children, e.lhs)
		append(&children, e.rhs)
	case ^With_Expr:
		append(&children, e.base)
		for field in e.fields {
			append(&children, field.value)
		}
	case ^Match_Expr:
		append(&children, e.scrutinee)
		for arm in e.arms {
			append(&children, arm.body)
		}
	case ^Tuple_Expr:
		for element in e.elements {
			append(&children, element)
		}
	case ^If_Expr:
		append(&children, e.cond)
		append(&children, e.then_branch)
		append(&children, e.else_branch)
	case ^Stub_Expr:
		if e.has_fallback {
			append(&children, e.fallback)
		}
	}
	return children[:]
}
