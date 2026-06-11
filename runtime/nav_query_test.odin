// The §12 advance/los/reachable/nearest + Nav.of/Nav.fail acceptance fixtures —
// the remaining query surface over the path() decode story. Two machines, ONE
// §12 contract:
//   - the FIXTURE machine (Nav.of/Nav.fail → Nav_Value): path() replays the
//     supplied route, los/reachable read !failed, nearest is the identity snap;
//     Nav.fail is the coherent total failure. The behavior oracle is funpack's
//     warren_game.fun:212-250 (Nav.of dash / Nav.fail fails-every-query).
//   - the ENGINE machine (NavHandle → loaded Nav_Graph): reachable is BFS
//     reachability, nearest is the closest-center scan (ascending-index tie),
//     los FAILS CLOSED (needs occupancy the [nav] format omits, ADR
//     2026-06-11-engine-los-needs-occupancy-not-in-nav-format).
//   - advance(path, pos, arrive) is a Path-RECORD method fold (Option[Vec2], Path).
//
// Raw-bits equality throughout (the arrival radius pinned through the kernel
// vec2_length, never a float tolerance — Lore #13); the engine-los fail-closed
// test documents the deferred seam loudly. The emitted-warren end-to-end golden
// is the SEPARATE deferred leaf (runtime-nav-golden-end-to-end / engine-los leaf).
package funpack_runtime

import "core:testing"

// --- hand-built fixture builders --------------------------------------------

// nav_path_value hand-builds a `Path{ steps: [centers...], cost }` record value —
// the route a Nav.of fixture replays and the receiver Path.advance folds. The
// slices are made on the temp arena (a compound slice literal cannot escape its
// stack frame, Lore #11).
nav_path_value :: proc(steps: []Vec2, cost: Fixed) -> Record_Value {
	elements := make([]Value, len(steps), context.temp_allocator)
	for wp, i in steps {
		elements[i] = wp
	}
	fields := make(map[string]Value, context.temp_allocator)
	fields["steps"] = List_Value{elements = elements}
	fields["cost"] = cost
	return Record_Value{type_name = "Path", fields = fields}
}

// nav_vec2_slice heap-allocates a Vec2 slice on the temp arena (Lore #11).
nav_vec2_slice :: proc(vs: ..Vec2) -> []Vec2 {
	out := make([]Vec2, len(vs), context.temp_allocator)
	copy(out, vs)
	return out
}

// nav_error_arg builds a `NavError::CASE` unit-variant Value — the argument a
// Nav.fail(err) constructor consumes.
nav_error_arg :: proc(case_name: string) -> Value {
	return Variant_Value{enum_type = "NavError", case_name = case_name}
}

// nav_query_interp builds a bare Interp (no graphs needed for the fixture queries;
// the navs slice is supplied per engine test) — the nav_test_interp mold.
nav_query_interp :: proc(program: ^Program) -> Interp {
	return new_interp(program, nil, nil, empty(), tilemap_time_resource(), context.temp_allocator)
}

// nav_eval_method hand-builds a `r.method(args...)` call forest and drives it
// through the REAL eval_method_call dispatch (so the fixture-vs-engine arm
// selection by Value arm is exercised, never a helper in isolation). The receiver
// binds to `r`, each arg to `a0`, `a1`, … in a fresh scope.
nav_eval_method :: proc(
	interp: ^Interp,
	receiver: Value,
	method: string,
	args: ..Value,
) -> (
	result: Value,
	ok: bool,
) {
	recv := Node{kind = .Name, fields = tilemap_node_fields("r")}
	field := Node {
		kind     = .Field,
		fields   = tilemap_node_fields(method),
		children = tilemap_node_children(recv),
	}
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = field
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["r"] = receiver
	for arg, i in args {
		name := nav_arg_name(i)
		children[i + 1] = Node{kind = .Name, fields = tilemap_node_fields(name)}
		env.names[name] = arg
	}
	call := Node{kind = .Call, children = children}
	return eval(interp, &call, &env)
}

// nav_arg_name maps an arg index to its scope binding name (a0, a1, …) — a tiny
// fixed table so the call forest needs no string formatting in the test path.
nav_arg_name :: proc(i: int) -> string {
	switch i {
	case 0:
		return "a0"
	case 1:
		return "a1"
	}
	return "a2"
}

// --- the Nav.of fixture queries (warren_game.fun:212-250 oracle) -------------

@(test)
test_nav_of_path_replays_route :: proc(t: ^testing.T) {
	// AC (Nav.of path): a non-failed fixture's path() returns Result::Ok(route),
	// replaying the SUPPLIED route verbatim — the endpoints are ignored (the
	// deterministic stand-in a baked graph stands in for).
	program := Program{}
	interp := nav_query_interp(&program)
	wp := Vec2{x = to_fixed(10), y = Fixed(0)}
	route := nav_path_value(nav_vec2_slice(wp), to_fixed(10))
	nav := Nav_Value{route = route}
	result, ok := nav_eval_method(&interp, nav, "path", Vec2{}, Vec2{x = to_fixed(8), y = to_fixed(8)})
	testing.expect(t, ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.enum_type, "Result")
	testing.expect_value(t, variant.case_name, "Ok")
	replayed := variant.payload^.(Record_Value)
	testing.expect_value(t, replayed.type_name, "Path")
	steps := replayed.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), 1)
	testing.expect_value(t, steps.elements[0].(Vec2), wp) // bit-exact echo
	testing.expect_value(t, replayed.fields["cost"].(Fixed), to_fixed(10))
}

@(test)
test_nav_of_los_and_reachable_read_true :: proc(t: ^testing.T) {
	// AC (Nav.of los/reachable): the cheap yes/no checks read true on the fixture —
	// the segment is unobstructed and the endpoints reachable (the stand-in's
	// pinned answer).
	program := Program{}
	interp := nav_query_interp(&program)
	route := nav_path_value(nav_vec2_slice(Vec2{x = to_fixed(10), y = Fixed(0)}), to_fixed(10))
	nav := Nav_Value{route = route}
	los, los_ok := nav_eval_method(&interp, nav, "los", Vec2{}, Vec2{x = to_fixed(10)})
	testing.expect(t, los_ok)
	testing.expect_value(t, los.(bool), true)
	reach, reach_ok := nav_eval_method(&interp, nav, "reachable", Vec2{}, Vec2{x = to_fixed(10)})
	testing.expect(t, reach_ok)
	testing.expect_value(t, reach.(bool), true)
}

@(test)
test_nav_of_nearest_is_identity :: proc(t: ^testing.T) {
	// AC (Nav.of nearest): the fixture snap is the IDENTITY — an arbitrary point
	// maps to itself as Option::Some(point), echoing the point back bit-exactly
	// (NOT a closest-center scan; that is the engine's nearest).
	program := Program{}
	interp := nav_query_interp(&program)
	route := nav_path_value(nav_vec2_slice(Vec2{x = to_fixed(10), y = Fixed(0)}), to_fixed(10))
	nav := Nav_Value{route = route}
	p := Vec2{x = to_fixed(4), y = to_fixed(4)}
	result, ok := nav_eval_method(&interp, nav, "nearest", p)
	testing.expect(t, ok)
	opt := result.(Variant_Value)
	testing.expect_value(t, opt.enum_type, "Option")
	testing.expect_value(t, opt.case_name, "Some")
	testing.expect_value(t, opt.payload^.(Vec2), p) // identity echo, bit-exact
}

@(test)
test_nav_of_advance_empty_route_is_none :: proc(t: ^testing.T) {
	// AC (Nav.of advance-empty): advance on an EMPTY Path yields (None, remaining) —
	// no waypoint ahead, the arrival signal. advance is a Path-record method, so the
	// receiver is the empty Path, not the Nav.
	program := Program{}
	interp := nav_query_interp(&program)
	empty_route := nav_path_value(nav_vec2_slice(), Fixed(0))
	result, ok := nav_eval_method(
		&interp,
		empty_route,
		"advance",
		Vec2{x = to_fixed(4), y = to_fixed(4)},
		to_fixed(1),
	)
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)
	testing.expect_value(t, len(tuple.elements), 2)
	next := tuple.elements[0].(Variant_Value)
	testing.expect_value(t, next.enum_type, "Option")
	testing.expect_value(t, next.case_name, "None")
	remaining := tuple.elements[1].(Record_Value)
	testing.expect_value(t, remaining.type_name, "Path")
	testing.expect_value(t, len(remaining.fields["steps"].(List_Value).elements), 0)
}

// --- the Nav.fail coherent-failure twin (warren_game.fun:244-250 oracle) -----

@(test)
test_nav_fail_path_is_err :: proc(t: ^testing.T) {
	// AC (Nav.fail path): a failed fixture's path() yields a genuine
	// Result::Err(NavError::err) — the errors-as-values branch is a real fixture,
	// not a hand-built Result.
	program := Program{}
	interp := nav_query_interp(&program)
	nav := Nav_Value{failed = true, err = "Unreachable"}
	result, ok := nav_eval_method(
		&interp,
		nav,
		"path",
		Vec2{},
		Vec2{x = to_fixed(8), y = to_fixed(8)},
	)
	testing.expect(t, ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.enum_type, "Result")
	testing.expect_value(t, variant.case_name, "Err")
	nav_err := variant.payload^.(Variant_Value)
	testing.expect_value(t, nav_err.enum_type, "NavError")
	testing.expect_value(t, nav_err.case_name, "Unreachable")
}

@(test)
test_nav_fail_los_reachable_false_nearest_none :: proc(t: ^testing.T) {
	// AC (Nav.fail coherent failure): every cheap query fails coherently — los and
	// reachable read FALSE, nearest reads Option::None. The Nav.fail twin's whole
	// point: no query silently succeeds.
	program := Program{}
	interp := nav_query_interp(&program)
	nav := Nav_Value{failed = true, err = "Unreachable"}
	los, los_ok := nav_eval_method(&interp, nav, "los", Vec2{}, Vec2{x = to_fixed(8), y = to_fixed(8)})
	testing.expect(t, los_ok)
	testing.expect_value(t, los.(bool), false)
	reach, reach_ok := nav_eval_method(&interp, nav, "reachable", Vec2{}, Vec2{x = to_fixed(8), y = to_fixed(8)})
	testing.expect(t, reach_ok)
	testing.expect_value(t, reach.(bool), false)
	nearest, near_ok := nav_eval_method(&interp, nav, "nearest", Vec2{x = to_fixed(4), y = to_fixed(4)})
	testing.expect(t, near_ok)
	opt := nearest.(Variant_Value)
	testing.expect_value(t, opt.enum_type, "Option")
	testing.expect_value(t, opt.case_name, "None")
}

// --- the Nav.of / Nav.fail constructors (the value-builder seam) -------------

@(test)
test_nav_of_constructor_builds_non_failed :: proc(t: ^testing.T) {
	// AC (Nav.of ctor): Nav.of(Path{...}) builds a NON-failed Nav_Value carrying the
	// route. Driven through eval_nav_constructor with a hand-built `Nav.of(p)` call
	// forest so the type-name interception is exercised.
	program := Program{}
	interp := nav_query_interp(&program)
	route := nav_path_value(nav_vec2_slice(Vec2{x = to_fixed(8), y = Fixed(0)}), to_fixed(8))
	recv := Node{kind = .Name, fields = tilemap_node_fields("Nav")}
	field := Node {
		kind     = .Field,
		fields   = tilemap_node_fields("of"),
		children = tilemap_node_children(recv),
	}
	arg := Node{kind = .Name, fields = tilemap_node_fields("p")}
	call := Node{kind = .Call, children = tilemap_node_children(field, arg)}
	env := Env{names = make(map[string]Value, context.temp_allocator)}
	env.names["p"] = route
	result, ok := eval(&interp, &call, &env)
	testing.expect(t, ok)
	nav := result.(Nav_Value)
	testing.expect_value(t, nav.failed, false)
	testing.expect_value(t, nav.route.type_name, "Path")
}

@(test)
test_nav_fail_constructor_builds_failed :: proc(t: ^testing.T) {
	// AC (Nav.fail ctor): Nav.fail(NavError::Unreachable) builds a FAILED Nav_Value
	// carrying the error case name.
	program := Program{}
	interp := nav_query_interp(&program)
	recv := Node{kind = .Name, fields = tilemap_node_fields("Nav")}
	field := Node {
		kind     = .Field,
		fields   = tilemap_node_fields("fail"),
		children = tilemap_node_children(recv),
	}
	arg := Node{kind = .Name, fields = tilemap_node_fields("e")}
	call := Node{kind = .Call, children = tilemap_node_children(field, arg)}
	env := Env{names = make(map[string]Value, context.temp_allocator)}
	env.names["e"] = nav_error_arg("Unreachable")
	result, ok := eval(&interp, &call, &env)
	testing.expect(t, ok)
	nav := result.(Nav_Value)
	testing.expect_value(t, nav.failed, true)
	testing.expect_value(t, nav.err, "Unreachable")
}

// --- the advance(path, pos, arrive) fold (Path-record method) ----------------

@(test)
test_advance_next_waypoint_when_outside_arrive :: proc(t: ^testing.T) {
	// AC (advance ahead): pos OUTSIDE the arrival radius of the only waypoint →
	// (Some(wp), remaining = the same one-step route). The waypoint is still ahead,
	// so it is the next steer target and is NOT consumed. Arrival radius pinned
	// through the kernel vec2_length, raw bits (Lore #13).
	program := Program{}
	interp := nav_query_interp(&program)
	wp := Vec2{x = to_fixed(10), y = Fixed(0)}
	route := nav_path_value(nav_vec2_slice(wp), to_fixed(10))
	// pos at origin: |wp - pos| = 10 > arrive(1), so the waypoint is ahead.
	pos := Vec2{}
	result, ok := nav_eval_method(&interp, route, "advance", pos, to_fixed(1))
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)
	next := tuple.elements[0].(Variant_Value)
	testing.expect_value(t, next.enum_type, "Option")
	testing.expect_value(t, next.case_name, "Some")
	testing.expect_value(t, next.payload^.(Vec2), wp) // bit-exact next waypoint
	remaining := tuple.elements[1].(Record_Value)
	rem_steps := remaining.fields["steps"].(List_Value)
	testing.expect_value(t, len(rem_steps.elements), 1)
	testing.expect_value(t, rem_steps.elements[0].(Vec2), wp)
	testing.expect_value(t, remaining.fields["cost"].(Fixed), to_fixed(10)) // cost verbatim
}

@(test)
test_advance_exhausted_when_within_arrive :: proc(t: ^testing.T) {
	// AC (advance exhausted): pos WITHIN the arrival radius of the last waypoint →
	// the waypoint is consumed and the route exhausts → (None, empty remaining).
	// |wp - pos| pinned through the kernel: pos == wp gives length 0 <= arrive.
	program := Program{}
	interp := nav_query_interp(&program)
	wp := Vec2{x = to_fixed(10), y = Fixed(0)}
	route := nav_path_value(nav_vec2_slice(wp), to_fixed(10))
	// pos AT the waypoint: |wp - pos| = 0 <= arrive(1), so it is reached/consumed.
	result, ok := nav_eval_method(&interp, route, "advance", wp, to_fixed(1))
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)
	next := tuple.elements[0].(Variant_Value)
	testing.expect_value(t, next.enum_type, "Option")
	testing.expect_value(t, next.case_name, "None")
	remaining := tuple.elements[1].(Record_Value)
	testing.expect_value(t, len(remaining.fields["steps"].(List_Value).elements), 0)
}

// --- the ENGINE reachable / nearest over a loaded graph ----------------------

@(test)
test_engine_reachable_connected :: proc(t: ^testing.T) {
	// AC (engine reachable, connected): reachable(0, 2) over the grid graph is true
	// (the top-row 0-1-2 route exists). reachable returns the BFS-reachability bool,
	// no waypoints materialized.
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	result, ok := nav_eval_method(
		&interp,
		nav_handle_value("ground"),
		"reachable",
		graph.centers[0],
		graph.centers[2],
	)
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), true)
}

@(test)
test_engine_reachable_isolated_is_false :: proc(t: ^testing.T) {
	// AC (engine reachable, disconnected): both endpoints valid walkable centers but
	// no edge sequence connects them → false (NOT an error; reachable returns Bool).
	graph := nav_grid_graph()
	centers := make([]Vec2, 9, context.temp_allocator)
	copy(centers, graph.centers)
	centers[8] = Vec2{x = to_fixed(99), y = to_fixed(99)}
	adj := make([][]int, 9, context.temp_allocator)
	copy(adj, graph.adj)
	adj[8] = make([]int, 0, context.temp_allocator)
	graph.centers = centers
	graph.adj = adj
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	result, ok := nav_eval_method(
		&interp,
		nav_handle_value("ground"),
		"reachable",
		graph.centers[0],
		graph.centers[8],
	)
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)
}

@(test)
test_engine_reachable_off_nav_is_false :: proc(t: ^testing.T) {
	// AC (engine reachable, off-nav): an endpoint matching no walkable center is NOT
	// an error here (reachable is Bool, not a Result) → false. One raw bit off a
	// real center is genuinely not a node.
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	off := Vec2{x = to_fixed(8) + 1, y = to_fixed(40)}
	result, ok := nav_eval_method(&interp, nav_handle_value("ground"), "reachable", off, graph.centers[2])
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)
}

@(test)
test_engine_nearest_snaps_to_center :: proc(t: ^testing.T) {
	// AC (engine nearest): nearest(point one raw bit off center 0) snaps to
	// Some(centers[0]) — the closest walkable center by squared distance. The
	// off-by-one-bit point is nearer center 0 than any other.
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	near := Vec2{x = graph.centers[0].x + 1, y = graph.centers[0].y}
	result, ok := nav_eval_method(&interp, nav_handle_value("ground"), "nearest", near)
	testing.expect(t, ok)
	opt := result.(Variant_Value)
	testing.expect_value(t, opt.enum_type, "Option")
	testing.expect_value(t, opt.case_name, "Some")
	testing.expect_value(t, opt.payload^.(Vec2), graph.centers[0]) // genuine closest center
}

@(test)
test_engine_nearest_tie_lowest_index_wins :: proc(t: ^testing.T) {
	// AC (engine nearest tie-break): a point EQUIDISTANT between two centers snaps
	// to the LOWER node index — the strict `<` on squared distance means the first
	// (ascending) center holds against a later equal one. The midpoint of centers
	// [0]=(8,40) and [1]=(24,40) is (16,40), squared-equidistant from both; node 0
	// wins.
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	mid := Vec2{x = to_fixed(16), y = to_fixed(40)} // exactly between centers 0 and 1
	result, ok := nav_eval_method(&interp, nav_handle_value("ground"), "nearest", mid)
	testing.expect(t, ok)
	opt := result.(Variant_Value)
	testing.expect_value(t, opt.case_name, "Some")
	testing.expect_value(t, opt.payload^.(Vec2), graph.centers[0]) // lower index wins the tie
}

@(test)
test_engine_nearest_empty_graph_is_none :: proc(t: ^testing.T) {
	// AC (engine nearest, empty): an empty graph (no centers to match) → None — the
	// §12 "or None if the nav is empty".
	graph := Nav_Graph {
		name    = "ground",
		centers = make([]Vec2, 0, context.temp_allocator),
		adj     = make([][]int, 0, context.temp_allocator),
	}
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	result, ok := nav_eval_method(&interp, nav_handle_value("ground"), "nearest", Vec2{x = to_fixed(4)})
	testing.expect(t, ok)
	opt := result.(Variant_Value)
	testing.expect_value(t, opt.enum_type, "Option")
	testing.expect_value(t, opt.case_name, "None")
}

// --- the ENGINE los FAILS CLOSED (the deferred seam, documented loudly) ------

@(test)
test_engine_los_fails_closed :: proc(t: ^testing.T) {
	// AC (engine los fails closed): los over a REAL loaded graph returns ok=false —
	// NEVER a guessed true. Line-of-sight needs the per-cell occupancy the [nav]
	// format (centers + adjacency, §12 §5) does not carry, so there is no honest
	// answer; refused, deferred to the engine-los leaf
	// (engine-los-over-a-baked-nav-gr) pending a §12 / [nav]-format decision (ADR
	// 2026-06-11-engine-los-needs-occupancy-not-in-nav-format). This test documents
	// the deferred seam loudly — a future implementation flips it to a real verdict.
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	_, ok := nav_eval_method(
		&interp,
		nav_handle_value("ground"),
		"los",
		graph.centers[0],
		graph.centers[2],
	)
	testing.expect(t, !ok) // fails closed: no guessed true
}
