// The §08 §3 query evaluation surface: a call to a declared `query` evaluates
// its carried body as a PURE, EVOLVING READ — the body sees only its bound
// parameters plus module consts (exactly a §9 helper's scope) and reads the
// world through the `all[T]` node (interp.odin) and the spatial combinators
// below, over the tick's WORKING table. So a query observes the same evolving
// columns a direct `View[T]`/`all[T]` read does (§08 read-consistency): it is
// re-evaluated on every call and NEVER cached, so a re-call after intervening
// same-tick writes reflects them, and two callers at different tick points may
// see different rows. The result stays a pure, deterministic function of its
// arguments and the world at the call point (a query can never mutate, §08 CQRS
// read side; off a fold it reads the committed version). One uniform read rule
// across `View[T]`, `all[T]`, and `query` (ADR same-tick-query-reads-are-evolving).
package funpack_runtime

import "core:slice"

// eval_query_call applies a declared query at a `name(args)` call site: the
// argument expressions evaluate in the CALLER's scope (left to right, the §9
// helper discipline), then the bound evaluation defers to eval_query_values —
// the single memo + body path the runtime and the test/golden drivers share.
eval_query_call :: proc(
	interp: ^Interp,
	query: ^Query_Decl,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	ok: bool,
) {
	arg_count := len(node.children) - 1
	if arg_count != len(query.params) {
		return nil, false
	}
	args := make([]Value, arg_count, interp.allocator)
	for i in 0 ..< arg_count {
		arg, arg_ok := eval(interp, &node.children[i + 1], env)
		if !arg_ok {
			return nil, false
		}
		args[i] = arg
	}
	return eval_query_values(interp, query, args)
}

// eval_query_values evaluates a query over already-evaluated argument values —
// the §08 §3 evolving read. The body folds in a fresh scope binding only the
// declared params (a query closes over no caller locals), reading the world via
// `all[T]` and the spatial combinators over the tick's WORKING table — so a
// query observes the same evolving columns a direct `View[T]`/`all[T]` read
// does and is re-evaluated on every call, never cached. Its result is a pure,
// deterministic function of its arguments and the world at the call point.
eval_query_values :: proc(
	interp: ^Interp,
	query: ^Query_Decl,
	args: []Value,
) -> (
	value: Value,
	ok: bool,
) {
	if len(args) != len(query.params) {
		return nil, false
	}
	scope := Env {
		names = make(map[string]Value, interp.allocator),
	}
	for param, i in query.params {
		scope.names[param.name] = args[i]
	}
	// The query's declared requirement set scopes its body evaluation so the
	// spatial combinators resolve their measured field from the ENCLOSING
	// query alone; saved and restored around the fold so a composed query
	// call (a query body calling another query) rebinds correctly and a
	// non-query frame never inherits it.
	enclosing := interp.query_indexes
	interp.query_indexes = query.indexes
	value, ok = eval_body(interp, query.body, &scope)
	interp.query_indexes = enclosing
	return value, ok
}

// --- The §08 §3 spatial combinators ----------------------------------------

// builtin_within is the §08 §3 radius read `within(source, origin, r) -> [T]`:
// every row whose declared @spatial field lies within the fixed-point radius
// of origin — distance through the SAME kernel composition the maintained
// structure's read pins (index.odin spatial_within: vec2_length/vec3_length
// over the component difference, compared `<= r`, no float ever) — in SOURCE
// order (stable Id order for a world read). A row outside the kernel's
// distance domain (no enclosing declaration, a missing field, an arm
// mismatch) fails closed, never a coerced 0 — the kernel's refusal arm.
builtin_within :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 4 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	if !source_ok {
		return nil, false
	}
	list, is_list := source.(List_Value)
	if !is_list {
		return nil, false
	}
	origin, origin_ok := eval(interp, &node.children[2], env)
	if !origin_ok {
		return nil, false
	}
	radius_value, radius_ok := eval(interp, &node.children[3], env)
	if !radius_ok {
		return nil, false
	}
	radius, is_fixed := radius_value.(Fixed)
	if !is_fixed {
		return nil, false
	}
	out := make([dynamic]Value, 0, len(list.elements), interp.allocator)
	for element in list.elements {
		distance, measurable := query_spatial_distance(interp, element, origin)
		if !measurable {
			return nil, false
		}
		if distance <= radius {
			append(&out, element)
		}
	}
	return List_Value{elements = out[:]}, true
}

// builtin_nearest_first is the §08 §3 nearest-first order
// `nearest_first(source, origin) -> [T]`: ascending kernel distance with the
// STABLE Id tiebreak — a stable sort over a source in stable Id order keeps
// equidistant rows in Id order, exactly the maintained structure's pinned
// (distance, Id) answer (index.odin spatial_hit_less).
builtin_nearest_first :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	if !source_ok {
		return nil, false
	}
	list, is_list := source.(List_Value)
	if !is_list {
		return nil, false
	}
	origin, origin_ok := eval(interp, &node.children[2], env)
	if !origin_ok {
		return nil, false
	}
	keyed := make([]Query_Keyed_Row, len(list.elements), context.temp_allocator)
	for element, i in list.elements {
		distance, measurable := query_spatial_distance(interp, element, origin)
		if !measurable {
			return nil, false
		}
		keyed[i] = Query_Keyed_Row{row = element, distance = distance}
	}
	slice.stable_sort_by(keyed, query_keyed_row_less)
	out := make([]Value, len(keyed), interp.allocator)
	for entry, i in keyed {
		out[i] = entry.row
	}
	return List_Value{elements = out}, true
}

// Query_Keyed_Row pairs one source row with its kernel distance — the sort key
// builtin_nearest_first orders by.
Query_Keyed_Row :: struct {
	row:      Value,
	distance: Fixed,
}

// query_keyed_row_less is the nearest-first order's comparator: ascending
// distance ONLY — the stable sort preserves source (Id) order between equal
// distances, which IS the §08 §3 Id tiebreak.
query_keyed_row_less :: proc(a, b: Query_Keyed_Row) -> bool {
	return a.distance < b.distance
}

// query_spatial_distance measures one row's declared @spatial field against
// the probe origin through the fixed-point kernel — vec2_length/vec3_length
// over the component difference, the spatial_distance composition exactly
// (index.odin). The field resolves from the enclosing query's requirement set
// by the row's thing tag; ok is false outside the measurable domain (no
// declaration, several for one thing, a missing field, or an origin/field arm
// mismatch) — fail closed, mirroring the kernel.
query_spatial_distance :: proc(interp: ^Interp, element: Value, origin: Value) -> (distance: Fixed, ok: bool) {
	record, is_record := element.(Record_Value)
	if !is_record {
		return 0, false
	}
	field, resolved := query_spatial_field(interp.query_indexes, record.type_name)
	if !resolved {
		return 0, false
	}
	at, has_field := record.fields[field]
	if !has_field {
		return 0, false
	}
	#partial switch from in origin {
	case Vec2:
		at2, is_vec2 := at.(Vec2)
		if !is_vec2 {
			return 0, false
		}
		return vec2_length(vec2_sub(at2, from)), true
	case Vec3:
		at3, is_vec3 := at.(Vec3)
		if !is_vec3 {
			return 0, false
		}
		return vec3_length(vec3_sub(at3, from)), true
	}
	return 0, false
}

// query_spatial_field resolves which field the enclosing query's @spatial
// declarations measure for one thing — exactly one must match (the compiler
// names the missing/ambiguous verdicts upstream; the runtime fails closed).
query_spatial_field :: proc(indexes: []Index_Req, thing: string) -> (field: string, ok: bool) {
	found := false
	for req in indexes {
		if req.kind != .Spatial || req.thing != thing {
			continue
		}
		if found {
			return "", false
		}
		field = req.field
		found = true
	}
	return field, found
}
