// The §08 §3 index-requirement gate — pure AST, a structural gate like its
// gates.odin siblings (spec §01 P5: no per-site waiver): "a query needing an
// index must declare it; an `@index` no query uses is dead code."
//
// Both halves are mechanical functions of one query declaration:
//
//   - NEED (missing declaration): a spatial combinator (within/nearest_first)
//     whose collection argument traces to the world read `all[T]` — directly,
//     through nested combinator calls, or through a `let` binding — needs a
//     @spatial(T.*) declared ON THAT QUERY. A missing declaration is the
//     named Query_Missing_Index.
//   - USE (dead declaration): a declared @spatial(T.f) is used when a spatial
//     combinator over all[T] appears in the body (or when a combinator's
//     collection is untraceable to any all[] — a non-world collection the
//     pure-AST trace cannot type, where erring dead would be a false
//     positive, so the gate stays permissive there); a declared @index(T.f)
//     is used when the body reads all[T] at all — the §08 §3 access-pattern
//     pairing of a query with "the collections it reads". An unused
//     declaration is dead code (P5): the named Query_Unused_Index.
//
// The field half of a declaration (does T.f exist, is it measurable) is the
// typecheck stage's concern (check_index_paths, spatial_combinator_check);
// this gate owns only the requirement ↔ body pairing, so it reads names off
// the pure AST and never consults a schema.
package funpack

import "core:slice"

// check_query_index_gate walks every query declaration in source order and
// returns the first §08 §3 requirement violation, naming the offending query
// (the gates.odin first-offender discipline).
check_query_index_gate :: proc(ast: Ast) -> Gate_Verdict {
	for query in ast.queries {
		trace := query_body_trace(query.body)
		for thing in trace.spatial_needs {
			if !query_declares_index(query.indexes, .Spatial, thing) {
				return Gate_Verdict{err = .Query_Missing_Index, declaration = query.name}
			}
		}
		for directive in query.indexes {
			if !query_directive_used(directive, trace) {
				return Gate_Verdict{err = .Query_Unused_Index, declaration = query.name}
			}
		}
	}
	return Gate_Verdict{err = .None}
}

// Query_Body_Trace is one query body's derived access pattern: the things its
// spatial combinators measure (traced to all[T]), the things it reads at all
// (every all[T] occurrence), and whether some spatial combinator's collection
// could not be traced to a world read (the permissive arm above).
Query_Body_Trace :: struct {
	spatial_needs:  [dynamic]string,
	world_reads:    [dynamic]string,
	untraced_spatial: bool,
}

// Trace_Lets maps a body's `let` names to the world-read things their
// initializers (transitively) carry, so a collection bound through a local —
// `let es = all[Enemy]` then `within(es, …)` — still traces. Lookup-only
// below the binding walk; never iterated (the determinism tripwire).
Trace_Lets :: map[string][]string

// query_declares_index reports whether a query's declared requirement set
// carries a directive of the given kind over the given thing.
query_declares_index :: proc(indexes: []Index_Directive, kind: Index_Directive_Kind, thing: string) -> bool {
	for directive in indexes {
		if directive.kind == kind && directive.thing == thing {
			return true
		}
	}
	return false
}

// query_directive_used applies the USE half: a @spatial is used by a traced
// spatial combinator over its thing (or kept alive by an untraceable
// collection); an @index is used by any world read of its thing.
query_directive_used :: proc(directive: Index_Directive, trace: Query_Body_Trace) -> bool {
	switch directive.kind {
	case .Spatial:
		return slice.contains(trace.spatial_needs[:], directive.thing) || trace.untraced_spatial
	case .Index:
		return slice.contains(trace.world_reads[:], directive.thing)
	}
	return false
}

// query_body_trace derives one body's access pattern: a statement walk that
// records `let` world-read carries in order, collects every all[T] read, and
// traces each spatial combinator's collection argument.
query_body_trace :: proc(body: []Statement) -> Query_Body_Trace {
	trace := Query_Body_Trace {
		spatial_needs = make([dynamic]string, 0, 2, context.temp_allocator),
		world_reads   = make([dynamic]string, 0, 2, context.temp_allocator),
	}
	lets := make(Trace_Lets, context.temp_allocator)
	trace_statements(body, &trace, &lets)
	return trace
}

// trace_statements walks a statement sequence in source order: a `let` binds
// its initializer's traced things before later statements read it, and every
// expression position is traced for reads and spatial combinators.
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

// trace_expr records every all[T] read and every spatial combinator's traced
// collection in one expression tree, descending all children (a combinator
// buried in a lambda body or a match arm still counts).
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

// expr_world_things collects the world-read things one expression carries —
// every all[T] in its tree, plus the carries of any `let`-bound name it
// references (the binding walk recorded those in source order).
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

// expr_children flattens one expression node's immediate sub-expressions —
// the single child walk both traces above share. It mirrors the Expr union
// arm-for-arm so a new expression form is a visible compile gap here, not a
// silently-unwalked branch (the gates.odin totality discipline).
expr_children :: proc(expr: Expr) -> []Expr {
	children := make([dynamic]Expr, 0, 4, context.temp_allocator)
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
		// Leaf atoms host no sub-expression.
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

