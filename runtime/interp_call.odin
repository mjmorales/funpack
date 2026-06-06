// The call and match halves of the interpreter (interp.odin): user-function and
// engine-builtin application, and pattern matching over a scrutinee. Kept beside
// the expression core so the value model and the dispatch that consumes it read
// as one engine; the split is by surface (expression forms vs application/match),
// not by layer.
//
// A `call` is one of three things, decided by its callee node: a method-style
// `recv.method(args)` (a `field` callee — input.value, the only resource query
// pong evaluates here), an engine builtin (the §08/§26 leaf combinators —
// `abs`, `clamp`, `first`, `fold`, the §08 list set `prepend`/`init`/`contains`/
// `map`/`filter`/`concat`/`is_empty`, the §26 `engine.grid.grid_cells`, `Spawn`,
// a record constructor), or a user §9 helper (`advance`, `overlaps`, `add_goal`,
// …) evaluated by binding its args to its params and folding its body. No float
// (spec §10); every numeric path is the fixed.odin kernel.
package funpack_runtime

// --- match ----------------------------------------------------------------

// eval_match evaluates `match SCRUTINEE { arm => body, … }`: child[0] is the
// scrutinee, the remaining children alternate arm/body. The FIRST arm whose
// pattern matches the scrutinee wins; its body evaluates with the arm's binders
// bound, in a fresh child scope. A match with no matching arm is ok=false (the
// checked AST makes pong's matches exhaustive — Option has Some+None, Side has
// Left+Right — so an unmatched scrutinee is a malformed body).
eval_match :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	scrutinee, scrut_ok := eval(interp, &node.children[0], env)
	if !scrut_ok {
		return nil, false
	}
	// Children after the scrutinee pair up arm/body in source order.
	i := 1
	for i + 1 < len(node.children) {
		arm := &node.children[i]
		body := &node.children[i + 1]
		if arm.kind != .Arm {
			return nil, false
		}
		bound := Env {
			names  = make(map[string]Value, interp.allocator),
			parent = env,
		}
		if arm_matches(scrutinee, arm, &bound) {
			return eval(interp, body, &bound)
		}
		i += 2
	}
	return nil, false
}

// arm_matches tests one arm's pattern against the scrutinee, binding the arm's
// payload binders into `scope` on a match. The closed pattern kinds (§2.7 arm
// `pat` field): `bare_variant Enum Case` matches a variant by case name with no
// binder; `variant_binds Enum Case BINDER_COUNT binders…` matches the case and
// binds its payload (Option::Some(side) binds `side`, a `_` binder discards);
// `wildcard - -` matches anything; a literal binder is out of pong's surface.
arm_matches :: proc(scrutinee: Value, arm: ^Node, scope: ^Env) -> bool {
	pat := arm.fields[0]
	switch pat {
	case "wildcard":
		return true
	case "bare_variant":
		v, is_variant := scrutinee.(Variant_Value)
		if !is_variant {
			return false
		}
		// fields: pat, enum, case — match by case name (the enum is the same type).
		return v.case_name == arm.fields[2]
	case "variant_binds":
		v, is_variant := scrutinee.(Variant_Value)
		if !is_variant {
			return false
		}
		if v.case_name != arm.fields[2] {
			return false
		}
		// fields: pat, enum, case, binder_count, binders… — bind the first binder
		// to the variant's payload (pong's Some(x) binds one; `_` discards).
		binder_count := 0
		if n, n_ok := decode_int(arm.fields[3]); n_ok {
			binder_count = int(n)
		}
		if binder_count >= 1 && len(arm.fields) >= 5 {
			binder := arm.fields[4]
			if binder != "_" && v.payload != nil {
				scope.names[binder] = v.payload^
			}
		}
		return true
	}
	return false
}

// --- call -----------------------------------------------------------------

// eval_call applies a call node. The callee (child[0]) decides the form: a
// `field` callee is a method-style `recv.method(args)` (the resource queries —
// input.value); a `name` callee is an engine builtin or a user §9 helper. Args
// are children[1:], evaluated left-to-right so evaluation order is deterministic.
eval_call :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	callee := &node.children[0]
	switch callee.kind {
	case .Field:
		return eval_method_call(interp, node, env)
	case .Name:
		return eval_named_call(interp, callee.fields[0], node, env)
	case .Int, .Fixed, .String, .Variant, .Record, .Recfield, .With, .List, .Call, .Lambda, .Unary, .Binary, .Match, .Arm, .Let, .If_Return, .Return:
		return nil, false
	}
	return nil, false
}

// eval_method_call evaluates `recv.method(args)` — the resource-query form. The
// receiver is the `field` callee's child; the method name is its field token.
// Input.value(player, action) is the resource query the executed
// control/collision/scoring stages reach (the render [Draw] projection is not
// produced here), so the receiver is the Input snapshot and the method resolves
// an action reading; an unknown receiver/method is ok=false.
eval_method_call :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	field_node := &node.children[0]
	method := field_node.fields[0]
	recv, recv_ok := eval(interp, &field_node.children[0], env)
	if !recv_ok {
		return nil, false
	}
	// Pong's only method receiver in the executed (non-render) pipeline is the
	// Input snapshot; the receiver value carries no Input arm, so resolve the
	// query against interp.input directly, keyed by the evaluated args.
	_ = recv
	switch method {
	case "value":
		return eval_input_value(interp, node, env)
	}
	return nil, false
}

// eval_input_value evaluates `input.value(self.player, Steer::Move)`: resolve the
// PlayerId arg and the action variant arg, map the action to its stable ActionId
// through the program's action registry, and read the snapshot's 1D analog value
// (§23 §2). An unresolved player or action reads zero (the snapshot default), so
// a behavior never faults on input.
eval_input_value :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (result: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	player_val, player_ok := eval(interp, &node.children[1], env)
	action_val, action_ok := eval(interp, &node.children[2], env)
	if !player_ok || !action_ok {
		return nil, false
	}
	player_variant, is_player := player_val.(Variant_Value)
	action_variant, is_action := action_val.(Variant_Value)
	if !is_player || !is_action {
		return nil, false
	}
	player, player_resolved := player_from_string(player_variant.case_name)
	if !player_resolved {
		return Fixed(0), true
	}
	// The registry is minted once per program (new_interp), so this read is an
	// index lookup, not a per-instance rebuild.
	action_name := variant_to_token(action_variant, interp.allocator)
	def, action_found := interp.registry.by_name[action_name]
	if !action_found {
		return Fixed(0), true
	}
	return value(interp.input, player, def.id), true
}

// eval_named_call dispatches a `name(args)` call: an engine builtin first (the
// closed set §07/§08 expose to a body), then a user §9 helper. An unresolved
// name is ok=false.
eval_named_call :: proc(
	interp: ^Interp,
	name: string,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	ok: bool,
) {
	switch name {
	case "abs":
		return builtin_abs(interp, node, env)
	case "clamp":
		return builtin_clamp(interp, node, env)
	case "first":
		return builtin_first(interp, node, env)
	case "fold":
		return builtin_fold(interp, node, env)
	case "prepend":
		return builtin_prepend(interp, node, env)
	case "init":
		return builtin_init(interp, node, env)
	case "contains":
		return builtin_contains(interp, node, env)
	case "map":
		return builtin_map(interp, node, env)
	case "filter":
		return builtin_filter(interp, node, env)
	case "concat":
		return builtin_concat(interp, node, env)
	case "is_empty":
		return builtin_is_empty(interp, node, env)
	case "grid_cells":
		return builtin_grid_cells(interp, node, env)
	}
	// A user §9 helper: bind its args to its params and fold its body.
	if fn := program_function(interp.program, name); fn != nil {
		return eval_user_call(interp, fn, node, env)
	}
	return nil, false
}

// eval_user_call applies a user §9 helper: evaluate each arg, bind it to the
// matching param name in a fresh scope (the helper closes over no caller locals
// — it sees only its params plus module consts), then fold the helper's body.
// The arg count must match the param count (the checked AST guarantees it).
eval_user_call :: proc(
	interp: ^Interp,
	fn: ^Function_Decl,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	ok: bool,
) {
	arg_count := len(node.children) - 1
	if arg_count != len(fn.params) {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	for param, i in fn.params {
		arg, arg_ok := eval(interp, &node.children[i + 1], env)
		if !arg_ok {
			return nil, false
		}
		scope.names[param.name] = arg
	}
	return eval_body(interp, fn.body, &scope)
}

// --- engine builtins ------------------------------------------------------

// builtin_abs is the §10 absolute value over the kernel: |Fixed| / |Int|,
// computed by saturating-negating a negative operand so it stays total at the
// rails. Pong's overlaps() calls abs on a Fixed difference.
builtin_abs :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false
	}
	switch v in arg {
	case Fixed:
		return (v < 0 ? fixed_neg(v) : v), true
	case i64:
		return (v < 0 ? int_neg(v) : v), true
	case bool, Vec2, Ref, Record_Value, List_Value, Variant_Value, Lambda_Value, String_Value:
		return nil, false
	}
	return nil, false
}

// builtin_clamp is the §10 clamp over the kernel: clamp(x, lo, hi) on Fixed.
// Pong's paddle_move clamps the paddle's y into the board, so x/lo/hi are all
// Fixed; the kernel's fixed_clamp keeps the rule in one place.
builtin_clamp :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 4 {
		return nil, false
	}
	x_val, x_ok := eval(interp, &node.children[1], env)
	lo_val, lo_ok := eval(interp, &node.children[2], env)
	hi_val, hi_ok := eval(interp, &node.children[3], env)
	if !x_ok || !lo_ok || !hi_ok {
		return nil, false
	}
	x, xf := as_fixed(x_val)
	lo, lof := as_fixed(lo_val)
	hi, hif := as_fixed(hi_val)
	if !xf || !lof || !hif {
		return nil, false
	}
	return fixed_clamp(x, lo, hi), true
}

// builtin_first is the §08 list combinator `first(list) -> Option[T]`: the head
// of a list as Option::Some, or Option::None for the empty list. Pong's
// paddle_bounce/serve match on first(...). When a lambda predicate is supplied
// (`first(list, pred)`), the first element satisfying the predicate is returned
// — paddle_bounce's `first(paddles, pad => overlaps(...))`.
builtin_first :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	if !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	// With a predicate lambda, return the first element it accepts; without one,
	// return the head.
	if len(node.children) >= 3 {
		pred_val, pred_ok := eval(interp, &node.children[2], env)
		if !pred_ok {
			return nil, false
		}
		pred, is_lambda := pred_val.(Lambda_Value)
		if !is_lambda {
			return nil, false
		}
		for elem in elements {
			result, result_ok := apply_lambda(interp, pred, elem)
			if !result_ok {
				return nil, false
			}
			if as_bool(result) {
				return some_value(interp, elem), true
			}
		}
		return none_value(), true
	}
	if len(elements) == 0 {
		return none_value(), true
	}
	return some_value(interp, elements[0]), true
}

// builtin_fold is the §08 list aggregate `fold(list, seed, f)`: fold f over the
// list left-to-right from the seed, threading the accumulator. Pong's tally folds
// add_goal over the inbound goals list onto the seed Scoreboard. `f` is a §9
// helper name resolved here, applied per element as f(acc, element).
builtin_fold :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 4 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	seed_val, seed_ok := eval(interp, &node.children[2], env)
	if !list_ok || !seed_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	// The folding function is named directly (a §9 helper) — pong folds add_goal.
	combiner := &node.children[3]
	if combiner.kind != .Name {
		return nil, false
	}
	fn := program_function(interp.program, combiner.fields[0])
	if fn == nil || len(fn.params) != 2 {
		return nil, false
	}
	acc := seed_val
	for elem in elements {
		next, next_ok := apply_two_arg(interp, fn, acc, elem)
		if !next_ok {
			return nil, false
		}
		acc = next
	}
	return acc, true
}

// builtin_prepend is the §08 list combinator `prepend(elem, list) -> [T]`: a new
// list with `elem` at the front, then every element of `list` in order. Snake's
// cells() prepends the head onto the body; the list is rebuilt fresh in the
// evaluation arena (immutable data — the input list is never mutated, §08).
builtin_prepend :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	elem_val, elem_ok := eval(interp, &node.children[1], env)
	list_val, list_ok := eval(interp, &node.children[2], env)
	if !elem_ok || !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	out := make([]Value, len(elements) + 1, interp.allocator)
	out[0] = elem_val
	for elem, i in elements {
		out[i + 1] = elem
	}
	return List_Value{elements = out}, true
}

// builtin_init is the §08 list combinator `init(list) -> [T]`: a new list with
// every element except the last. Snake's body_after drops the tail this way when
// the snake is not growing. The empty list yields the empty list (total — never
// a fault on a missing last element, §26 totality).
builtin_init :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	if !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	if len(elements) == 0 {
		return List_Value{elements = make([]Value, 0, interp.allocator)}, true
	}
	out := make([]Value, len(elements) - 1, interp.allocator)
	for i in 0 ..< len(elements) - 1 {
		out[i] = elements[i]
	}
	return List_Value{elements = out}, true
}

// builtin_contains is the §08 list combinator `contains(list, elem) -> Bool`:
// true when any element of `list` structurally equals `elem` (§03 universal Eq).
// Snake tests `contains(occ, c)` over Cell records and `contains(self.body,
// self.head)`, so the membership is the deep record equality values_equal folds.
builtin_contains :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	elem_val, elem_ok := eval(interp, &node.children[2], env)
	if !list_ok || !elem_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	for elem in elements {
		if values_equal(elem, elem_val) {
			return true, true
		}
	}
	return false, true
}

// builtin_map is the §08 list combinator `map(list, fn) -> [U]`: a new list
// applying the unary lambda `fn` to each element in order. Snake projects food
// rows to their cells and cells to draw rects this way. The lambda is applied
// per element through apply_lambda; the result keeps the input's deterministic
// order (§08 stable order — order is the source order, never an iteration order).
builtin_map :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	fn_val, fn_ok := eval(interp, &node.children[2], env)
	if !list_ok || !fn_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	lambda, is_lambda := fn_val.(Lambda_Value)
	if !is_lambda {
		return nil, false
	}
	out := make([]Value, len(elements), interp.allocator)
	for elem, i in elements {
		projected, projected_ok := apply_lambda(interp, lambda, elem)
		if !projected_ok {
			return nil, false
		}
		out[i] = projected
	}
	return List_Value{elements = out}, true
}

// builtin_filter is the §08 list combinator `filter(list, pred) -> [T]`: a new
// list of the elements the unary predicate lambda accepts, in order. Snake's
// free-cell selection filters all_cells() by un-occupied, and detect_eat filters
// foods by the head cell. The kept elements preserve the input's deterministic
// order (§08 stable order).
builtin_filter :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	pred_val, pred_ok := eval(interp, &node.children[2], env)
	if !list_ok || !pred_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	pred, is_lambda := pred_val.(Lambda_Value)
	if !is_lambda {
		return nil, false
	}
	kept := make([dynamic]Value, 0, len(elements), interp.allocator)
	for elem in elements {
		verdict, verdict_ok := apply_lambda(interp, pred, elem)
		if !verdict_ok {
			return nil, false
		}
		if as_bool(verdict) {
			append(&kept, elem)
		}
	}
	return List_Value{elements = kept[:]}, true
}

// builtin_concat is the §08 list combinator `concat(a, b) -> [T]`: a new list of
// every element of `a` followed by every element of `b`, both in order. Snake's
// occupied() concatenates the snake's cells with the food cells. The two inputs
// are read, never mutated; the join is fresh in the evaluation arena (§08).
builtin_concat :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 3 {
		return nil, false
	}
	a_val, a_ok := eval(interp, &node.children[1], env)
	b_val, b_ok := eval(interp, &node.children[2], env)
	if !a_ok || !b_ok {
		return nil, false
	}
	a_elements, a_elems_ok := as_elements(interp, a_val)
	b_elements, b_elems_ok := as_elements(interp, b_val)
	if !a_elems_ok || !b_elems_ok {
		return nil, false
	}
	out := make([]Value, len(a_elements) + len(b_elements), interp.allocator)
	for elem, i in a_elements {
		out[i] = elem
	}
	for elem, i in b_elements {
		out[len(a_elements) + i] = elem
	}
	return List_Value{elements = out}, true
}

// builtin_is_empty is the §08 list combinator `is_empty(list) -> Bool`: true
// when the list has no elements. Snake gates grow/replenish/apply_death on an
// empty signal list this way.
builtin_is_empty :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 2 {
		return nil, false
	}
	list_val, list_ok := eval(interp, &node.children[1], env)
	if !list_ok {
		return nil, false
	}
	elements, elems_ok := as_elements(interp, list_val)
	if !elems_ok {
		return nil, false
	}
	return len(elements) == 0, true
}

// builtin_grid_cells is the §26 `engine.grid.grid_cells(w, h, fn(x, y) -> Cell)
// -> [Cell]`: every cell of a w×h grid in STABLE ROW-MAJOR order, built by the
// supplied two-arg lambda. The order is driven by the loop indices — the outer
// loop walks rows (y from 0), the inner loop walks columns within a row (x from
// 0) — so the enumeration is machine-identical, never dependent on any map/hash
// iteration (§08 stable order, §26 "stable row-major order"). Snake's all_cells()
// folds free-cell selection through this; a non-positive extent yields the empty
// list (total — no fault on a degenerate grid). No float: w/h are Ints (§10).
builtin_grid_cells :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) < 4 {
		return nil, false
	}
	w_val, w_ok := eval(interp, &node.children[1], env)
	h_val, h_ok := eval(interp, &node.children[2], env)
	fn_val, fn_ok := eval(interp, &node.children[3], env)
	if !w_ok || !h_ok || !fn_ok {
		return nil, false
	}
	w, w_is_int := w_val.(i64)
	h, h_is_int := h_val.(i64)
	if !w_is_int || !h_is_int {
		return nil, false
	}
	lambda, is_lambda := fn_val.(Lambda_Value)
	if !is_lambda {
		return nil, false
	}
	count := (w > 0 && h > 0) ? int(w) * int(h) : 0
	out := make([]Value, count, interp.allocator)
	idx := 0
	// Row-major: y is the outer (row) index, x the inner (column) index, so the
	// list reads row 0 left-to-right, then row 1, …  The two indices fully order
	// the output, independent of any map iteration.
	for y in 0 ..< h {
		for x in 0 ..< w {
			cell, cell_ok := apply_two_arg_lambda(interp, lambda, x, y)
			if !cell_ok {
				return nil, false
			}
			out[idx] = cell
			idx += 1
		}
	}
	return List_Value{elements = out}, true
}

// --- builtin support ------------------------------------------------------

// as_elements reads a value as a list's elements: a List_Value yields its slice;
// a View-of-thing value the interpreter never materializes as a list here, so a
// non-list is ok=false. A behavior reads a View through its param binding (the
// tick passes View rows as a List_Value), so first/fold over `paddles` see the
// rows as elements.
as_elements :: proc(interp: ^Interp, v: Value) -> (elements: []Value, ok: bool) {
	list, is_list := v.(List_Value)
	if !is_list {
		return nil, false
	}
	return list.elements, true
}

// apply_lambda applies a unary lambda closure to one argument: bind the arg to
// the lambda's single param in a child of its captured scope, then evaluate the
// body. A lambda whose arity is not one is a malformed application (ok=false) —
// the unary combinators (first/map/filter) only ever hold a one-param closure.
apply_lambda :: proc(interp: ^Interp, lambda: Lambda_Value, arg: Value) -> (value: Value, ok: bool) {
	if len(lambda.params) != 1 {
		return nil, false
	}
	scope := Env {
		names  = make(map[string]Value, interp.allocator),
		parent = lambda.captured,
	}
	scope.names[lambda.params[0]] = arg
	return eval(interp, lambda.body, &scope)
}

// apply_two_arg_lambda applies a binary lambda closure to (a, b): bind both args
// to the lambda's two params in order in a child of its captured scope, then
// evaluate the body. grid_cells applies this with (x, y) per grid cell — the
// only binary-lambda combinator. A lambda whose arity is not two is malformed.
apply_two_arg_lambda :: proc(
	interp: ^Interp,
	lambda: Lambda_Value,
	a, b: Value,
) -> (
	value: Value,
	ok: bool,
) {
	if len(lambda.params) != 2 {
		return nil, false
	}
	scope := Env {
		names  = make(map[string]Value, interp.allocator),
		parent = lambda.captured,
	}
	scope.names[lambda.params[0]] = a
	scope.names[lambda.params[1]] = b
	return eval(interp, lambda.body, &scope)
}

// apply_two_arg applies a two-param §9 helper to (a, b) — the fold combiner shape
// (add_goal(score, goal)). The args bind to the helper's two params in order in a
// fresh scope, then the body folds.
apply_two_arg :: proc(
	interp: ^Interp,
	fn: ^Function_Decl,
	a, b: Value,
) -> (
	value: Value,
	ok: bool,
) {
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = a
	scope.names[fn.params[1].name] = b
	return eval_body(interp, fn.body, &scope)
}

// some_value boxes a value as Option::Some(v) — the head/predicate-hit result of
// first(). The payload is arena-allocated so the variant outlives the call.
some_value :: proc(interp: ^Interp, v: Value) -> Value {
	boxed := new(Value, interp.allocator)
	boxed^ = v
	return Variant_Value{enum_type = "Option", case_name = "Some", payload = boxed}
}

// none_value is the Option::None result of first() over an empty list / no
// predicate hit. The None arm a behavior's match falls through to.
none_value :: proc() -> Value {
	return Variant_Value{enum_type = "Option", case_name = "None"}
}
