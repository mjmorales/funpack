// The §12 advance/los/reachable/nearest + Nav.of/Nav.fail acceptance fixtures —
// the remaining query surface over the path() decode story. Two machines, ONE
// §12 contract:
//   - the FIXTURE machine (Nav.of/Nav.fail → Nav_Value): path() replays the
//     supplied route, los/reachable read !failed, nearest is the identity snap;
//     Nav.fail is the coherent total failure. The behavior oracle is funpack's
//     warren_game.fun:212-250 (Nav.of dash / Nav.fail fails-every-query).
//   - the ENGINE machine (NavHandle → loaded Nav_Graph): reachable is BFS
//     reachability, nearest is the closest-center scan (ascending-index tie),
//     los is the §12 §3 OCCUPANCY verdict — the segment supercover over the
//     graph's 1:1 committed tile layer (tilemap_segment_clear; ADR
//     2026-06-11-engine-los-reads-live-tilemap-occupancy), failing closed only
//     when no committed layer resolves.
//   - advance(path, pos, arrive) is a Path-RECORD method fold (Option[Vec2], Path).
//
// Raw-bits equality throughout (the arrival radius pinned through the kernel
// vec2_length, never a float tolerance — Lore #13). The emitted-warren end-to-end
// golden is the SEPARATE deferred leaf (runtime-nav-golden-end-to-end).
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

// --- the ENGINE los over the graph's 1:1 committed tile layer ----------------
//
// The §12 §3 occupancy verdict (ADR 2026-06-11-engine-los-reads-live-tilemap-
// occupancy): los resolves the graph's same-name committed layer and answers
// the conservative closed-box supercover — never the graph, never the bake.
// The layer fixture mirrors nav_grid_graph's geometry exactly: a 3×3 cell-16
// grid anchored at top-left (0, 48) with the CENTER cell solid — the same
// world the eight walkable centers imply.

// los_grid_layer hand-builds the 3×3 tile layer nav_grid_graph's topology
// derives from: palette [wall(solid), floor], all floor except the center cell
// (1,1). Named "ground" so the graph's 1:1 NAME keying resolves it.
los_grid_layer :: proc() -> Tile_Layer {
	palette := make([]Tile_Def, 2, context.temp_allocator)
	palette[0] = Tile_Def{name = "wall", solid = true}
	palette[1] = Tile_Def{name = "floor", solid = false}
	cells := make([]int, 9, context.temp_allocator)
	copy(cells, []int{1, 1, 1, 1, 0, 1, 1, 1, 1})
	return Tile_Layer {
		name      = "ground",
		cell_size = 16,
		cols      = 3,
		rows      = 3,
		top_left  = Vec2{x = to_fixed(0), y = to_fixed(48)},
		palette   = palette,
		cells     = cells,
	}
}

// los_version wraps one layer as a committed World_Version (the slice on the
// temp arena, Lore #11) — the version the los read resolves through.
los_version :: proc(layer: Tile_Layer) -> World_Version {
	tilemaps := make([]Tile_Layer, 1, context.temp_allocator)
	tilemaps[0] = layer
	return World_Version{tilemaps = tilemaps}
}

// los_interp builds the engine-los world: the graph in the Program, the layer
// committed on a World_Version the interp's version points at.
los_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	return new_interp(program, version, nil, empty(), tilemap_time_resource(), context.temp_allocator)
}

// eval_engine_los drives `nav.los(from, to)` through the real dispatch over the
// grid graph + the supplied committed version.
eval_engine_los :: proc(version: ^World_Version, from, to: Vec2) -> (result: Value, ok: bool) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := los_interp(&program, version)
	return nav_eval_method(&interp, nav_handle_value("ground"), "los", from, to)
}

@(test)
test_engine_los_clear_corridor :: proc(t: ^testing.T) {
	// AC (engine los, clear): a horizontal segment along the walkable top row —
	// node 0 (8,40) to node 2 (40,40) — touches cells (0..2, 0) only, all floor →
	// true.
	version := los_version(los_grid_layer())
	result, ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = to_fixed(40)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), true)
}

@(test)
test_engine_los_solid_blocks :: proc(t: ^testing.T) {
	// AC (engine los, blocked): the middle row crosses the solid center — node 3
	// (8,24) to node 4 (40,24) passes through cell (1,1) = wall → false. Graph
	// adjacency would call these nodes disconnected; los answers from occupancy,
	// and the wall stands in the way.
	version := los_version(los_grid_layer())
	result, ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = to_fixed(24)}, Vec2{x = to_fixed(40), y = to_fixed(24)})
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)
}

@(test)
test_engine_los_corner_crossing_is_conservative :: proc(t: ^testing.T) {
	// AC (engine los, lattice corner): the grid diagonal node 5 (8,8) → node 2
	// (40,40) passes EXACTLY through the lattice corners (16,16)/(32,32) in grid
	// space — cell centers sit on grid diagonals, so corner hits are the common
	// case, not the edge case. The closed-box supercover checks all four incident
	// cells at a corner; the solid center (1,1) is incident to both crossings →
	// false (no line-of-fire through a kissing-corner seam, §12 §3).
	version := los_version(los_grid_layer())
	result, ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = to_fixed(8)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)
}

@(test)
test_engine_los_chasm_and_void_clear :: proc(t: ^testing.T) {
	// AC (engine los, sight over the void): tile-less cells and out-of-grid space
	// block nothing — solidity is a property of a tile (§12 §3: you can SEE across
	// a chasm you cannot WALK). The center becomes a chasm (TILE_CELL_EMPTY) and
	// the middle row reads clear; a segment running past the grid's left edge
	// (off-grid u < 0) also reads clear.
	layer := los_grid_layer()
	layer.cells[4] = TILE_CELL_EMPTY // the wall becomes a chasm
	version := los_version(layer)
	over_chasm, ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = to_fixed(24)}, Vec2{x = to_fixed(40), y = to_fixed(24)})
	testing.expect(t, ok)
	testing.expect_value(t, over_chasm.(bool), true)
	off_grid, off_ok := eval_engine_los(&version, Vec2{x = to_fixed(-24), y = to_fixed(40)}, Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect(t, off_ok)
	testing.expect_value(t, off_grid.(bool), true)
}

@(test)
test_engine_los_endpoint_in_solid_blocks :: proc(t: ^testing.T) {
	// AC (engine los, endpoint occupancy): the closed segment includes its
	// endpoints, so standing inside the wall — from the solid center (24,24) to
	// node 0 (8,40) — reads false, and the degenerate from == to point inside the
	// wall reads false while the same point on open floor reads true.
	version := los_version(los_grid_layer())
	from_wall, ok := eval_engine_los(&version, Vec2{x = to_fixed(24), y = to_fixed(24)}, Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect(t, ok)
	testing.expect_value(t, from_wall.(bool), false)
	point_wall, pw_ok := eval_engine_los(&version, Vec2{x = to_fixed(24), y = to_fixed(24)}, Vec2{x = to_fixed(24), y = to_fixed(24)})
	testing.expect(t, pw_ok)
	testing.expect_value(t, point_wall.(bool), false)
	point_floor, pf_ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = to_fixed(40)}, Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect(t, pf_ok)
	testing.expect_value(t, point_floor.(bool), true)
}

@(test)
test_engine_los_grazing_wall_face_blocks_by_one_bit :: proc(t: ^testing.T) {
	// AC (engine los, closed-box graze): a segment running EXACTLY along the
	// wall's top face — y = 32 is the row 0/1 boundary, whose closed boxes both
	// contain it — touches the solid (1,1) → false; the same segment one raw bit
	// higher (y = 32 + 1 bit) lies strictly inside row 0 → true. The conservative
	// boundary rule is bit-exact, not a tolerance.
	version := los_version(los_grid_layer())
	grazing, ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = to_fixed(32)}, Vec2{x = to_fixed(40), y = to_fixed(32)})
	testing.expect(t, ok)
	testing.expect_value(t, grazing.(bool), false)
	one_bit_up := Fixed(i64(to_fixed(32)) + 1)
	above, above_ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = one_bit_up}, Vec2{x = to_fixed(40), y = one_bit_up})
	testing.expect(t, above_ok)
	testing.expect_value(t, above.(bool), true)
}

@(test)
test_engine_los_reads_the_committed_version :: proc(t: ^testing.T) {
	// AC (engine los, dynamic terrain): los answers over the version the interp
	// reads — the §12 §3 SetTile promise. The same top-row segment is clear on the
	// pre-wall version and blocked on a version whose (1,0) cell became wall (the
	// committed state a SetTile fold would produce), while the bake-static graph
	// never changed.
	version_pre := los_version(los_grid_layer())
	clear_pre, ok := eval_engine_los(&version_pre, Vec2{x = to_fixed(8), y = to_fixed(40)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	testing.expect_value(t, clear_pre.(bool), true)
	walled := los_grid_layer()
	walled.cells[1] = 0 // (1,0) becomes wall — the post-SetTile committed state
	version_post := los_version(walled)
	blocked_post, post_ok := eval_engine_los(&version_post, Vec2{x = to_fixed(8), y = to_fixed(40)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, post_ok)
	testing.expect_value(t, blocked_post.(bool), false)
}

// --- the §12 §2 containing-cell endpoint resolution (path/reachable) ---------
//
// ADR 2026-06-11-path-endpoints-resolve-to-containing-cell: with the 1:1 layer
// committed, a path()/reachable() endpoint resolves to the walkable node of the
// cell CONTAINING it (half-open cell_of partition) — a thing paths from where
// it stands. OffNav still fires from a solid cell; the layerless exact-center
// contract is pinned by the nav_test.odin units (no version → fail closed).

// eval_engine_nav drives `nav.<method>(from, to)` through the real dispatch
// over the grid graph + the supplied committed version (the eval_engine_los
// mold for the two-Vec2 graph queries).
eval_engine_nav :: proc(version: ^World_Version, method: string, from, to: Vec2) -> (result: Value, ok: bool) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := los_interp(&program, version)
	return nav_eval_method(&interp, nav_handle_value("ground"), method, from, to)
}

@(test)
test_engine_path_resolves_off_center_endpoint_to_containing_cell :: proc(t: ^testing.T) {
	// AC (§12 §2 resolution): path() from (10, 38) — inside cell (0,0) but off
	// node 0's center (8,40) — to node 2's exact center succeeds: the endpoint
	// resolves to its containing cell's node, and the route's steps are the cell
	// CENTERS [c0, c1, c2] with cost 32 (two 16-unit edges), bit-exact.
	version := los_version(los_grid_layer())
	result, ok := eval_engine_nav(&version, "path", Vec2{x = to_fixed(10), y = to_fixed(38)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Ok")
	route := variant.payload^.(Record_Value)
	steps := route.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), 3)
	testing.expect_value(t, steps.elements[0].(Vec2), Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect_value(t, steps.elements[1].(Vec2), Vec2{x = to_fixed(24), y = to_fixed(40)})
	testing.expect_value(t, steps.elements[2].(Vec2), Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect_value(t, route.fields["cost"].(Fixed), to_fixed(32))
}

@(test)
test_engine_path_solid_cell_endpoint_is_offnav :: proc(t: ^testing.T) {
	// AC (§12 §2 OffNav): an endpoint inside the SOLID center cell (24,24)
	// resolves to no walkable node — containing-cell resolution keeps OffNav
	// honest (snapping out of a wall is nearest()'s job, never path()'s).
	version := los_version(los_grid_layer())
	result, ok := eval_engine_nav(&version, "path", Vec2{x = to_fixed(24), y = to_fixed(24)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Err")
	testing.expect_value(t, variant.payload^.(Variant_Value).case_name, "OffNav")
}

@(test)
test_engine_reachable_off_center_with_layer_is_true :: proc(t: ^testing.T) {
	// AC (§12 §2 reachable): the same one-raw-bit-off endpoint that reads false
	// LAYERLESS (test_engine_reachable_off_nav_is_false — no geometry, fail
	// closed) resolves through its containing cell once the 1:1 layer is
	// committed → true.
	version := los_version(los_grid_layer())
	off := Vec2{x = to_fixed(8) + 1, y = to_fixed(40)}
	result, ok := eval_engine_nav(&version, "reachable", off, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), true)
}

@(test)
test_engine_path_boundary_point_resolves_half_open :: proc(t: ^testing.T) {
	// AC (§12 §2 boundary): a point EXACTLY on the col 0/1 boundary (x=16)
	// belongs to col 1 under the half-open cell_of partition — the route from
	// (16,40) starts at node 1's center (24,40), one 16-unit edge to node 0.
	// Resolution is a partition, never the closed-box supercover los uses.
	version := los_version(los_grid_layer())
	result, ok := eval_engine_nav(&version, "path", Vec2{x = to_fixed(16), y = to_fixed(40)}, Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect(t, ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Ok")
	route := variant.payload^.(Record_Value)
	steps := route.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), 2)
	testing.expect_value(t, steps.elements[0].(Vec2), Vec2{x = to_fixed(24), y = to_fixed(40)})
	testing.expect_value(t, steps.elements[1].(Vec2), Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect_value(t, route.fields["cost"].(Fixed), to_fixed(16))
}

@(test)
test_engine_los_no_committed_layer_fails_closed :: proc(t: ^testing.T) {
	// AC (engine los fails closed): with NO committed version (nil — no layer to
	// answer from) los returns ok=false, never a guessed true into a line-of-fire
	// gate. The only remaining fail-closed arm of the engine-los surface.
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

// --- the §12 §1 SetTile-driven LIVE nav (path/reachable/nearest) -------------
//
// ADR 2026-06-12-engine-path-reads-live-tilemap-no-materialized-nav: path /
// reachable / nearest answer over the LIVE committed tile state of the nav's 1:1
// layer (exactly as los does), re-deriving the walkable topology per query via
// derive_nav_graph_from_layer — so a wall that falls (or rises) routes the NEXT
// tick. The baked program.navs graph is the layerless fallback ONLY. The
// derivation reproduces the funpack bake's rule (build.odin:bake_layer_nav_graph
// + nav_cell_walkable), so a derive over UNCHANGED terrain is bit-identical to
// the baked decode — no static golden can move (the inverse-golden discipline).

// nav_layer_with_cells clones los_grid_layer's 3×3 cell-16 geometry (anchored at
// top-left (0,48), palette [wall(solid), floor]) with a supplied cell-index
// pattern — the world a derived live nav graph reads. cells are row-major palette
// indices (0=wall, 1=floor); the geometry SetTile never mutates stays fixed.
nav_layer_with_cells :: proc(pattern: []int) -> Tile_Layer {
	layer := los_grid_layer()
	cells := make([]int, len(pattern), context.temp_allocator)
	copy(cells, pattern)
	layer.cells = cells
	return layer
}

// nav_path_steps decodes a path() Result::Ok(Path) Value into its (steps, cost)
// for a bit-exact route comparison; ok=false on an Err arm (OffNav/Unreachable).
nav_path_steps :: proc(result: Value) -> (steps: []Vec2, cost: Fixed, ok: bool) {
	variant, is_variant := result.(Variant_Value)
	if !is_variant || variant.enum_type != "Result" || variant.case_name != "Ok" {
		return nil, Fixed(0), false
	}
	path := variant.payload^.(Record_Value)
	list := path.fields["steps"].(List_Value)
	out := make([]Vec2, len(list.elements), context.temp_allocator)
	for el, i in list.elements {
		out[i] = el.(Vec2)
	}
	return out, path.fields["cost"].(Fixed), true
}

// nav_paths_equal compares two decoded routes by raw Vec2 bits + raw cost bits —
// the bit-identical replay/refold assertion (no float, no tolerance, §10.5).
nav_paths_equal :: proc(a_steps: []Vec2, a_cost: Fixed, b_steps: []Vec2, b_cost: Fixed) -> bool {
	if a_cost != b_cost || len(a_steps) != len(b_steps) {
		return false
	}
	for s, i in a_steps {
		if s != b_steps[i] {
			return false
		}
	}
	return true
}

@(test)
test_settile_live_nav :: proc(t: ^testing.T) {
	// AC1: path/reachable/nearest answer over the LIVE committed tile layer, not the
	// bake-static program.navs — SetTile-then-query routes the new terrain, while
	// UNCHANGED terrain stays bit-identical to the bake (no static golden moves).
	c0 := Vec2{x = to_fixed(8), y = to_fixed(40)} // node (0,0)
	c2 := Vec2{x = to_fixed(40), y = to_fixed(40)} // node (2,0)
	left_mid := Vec2{x = to_fixed(8), y = to_fixed(24)} // cell (0,1) center
	right_mid := Vec2{x = to_fixed(40), y = to_fixed(24)} // cell (2,1) center
	center := Vec2{x = to_fixed(24), y = to_fixed(24)} // the solid center cell's center

	base := []int{1, 1, 1, 1, 0, 1, 1, 1, 1} // center (1,1) solid — los_grid_layer
	gap := []int{1, 1, 1, 1, 1, 1, 1, 1, 1} // center filled to floor — wall FELL
	// node 2's only neighbors (cell 1 left, cell 5 down) walled — wall BUILT,
	// isolating the top-right cell so a route to it is Unreachable.
	walled := []int{1, 0, 1, 1, 0, 0, 1, 1, 1}

	// (a) UNCHANGED terrain — derive == bake, and the live route matches the bake's.
	{
		baked := nav_grid_graph()
		base_layer := nav_layer_with_cells(base)
		derived := derive_nav_graph_from_layer(&base_layer, context.temp_allocator)
		testing.expect(t, nav_graphs_equal(derived, baked)) // derive(unchanged) == bake

		version := los_version(nav_layer_with_cells(base))
		// path left_mid → right_mid must DETOUR the solid center (cost 64, 5 steps):
		// down-around the bottom row, the only route around the wall.
		live_res, ok := eval_engine_nav(&version, "path", left_mid, right_mid)
		testing.expect(t, ok)
		steps, cost, decoded := nav_path_steps(live_res)
		testing.expect(t, decoded)
		testing.expect_value(t, len(steps), 5) // detour: (8,24)(8,40)(24,40)(40,40)(40,24)
		testing.expect_value(t, steps[0], left_mid)
		testing.expect_value(t, steps[len(steps) - 1], right_mid)
		testing.expect_value(t, cost, to_fixed(64)) // 4 edges × 16

		// reachable over the live layer agrees; nearest to the solid center snaps to
		// a surrounding walkable center (NOT the center — it is not a node yet).
		reach, rok := eval_engine_nav(&version, "reachable", left_mid, right_mid)
		testing.expect(t, rok)
		testing.expect_value(t, reach.(bool), true)
		near_res, nok := eval_engine_nearest(&version, center)
		testing.expect(t, nok)
		near := near_res.(Variant_Value)
		testing.expect_value(t, near.case_name, "Some")
		testing.expect(t, near.payload^.(Vec2) != center) // the solid center is no node
	}

	// (b) wall FALLS (solid → walkable): the gap version routes STRAIGHT through the
	// new center node (cost 32, 3 steps) where the base detoured, and nearest snaps
	// to the now-walkable center.
	gap_version := los_version(nav_layer_with_cells(gap))
	gap_steps: []Vec2
	gap_cost: Fixed
	{
		res, ok := eval_engine_nav(&gap_version, "path", left_mid, right_mid)
		testing.expect(t, ok)
		steps, cost, decoded := nav_path_steps(res)
		testing.expect(t, decoded)
		testing.expect_value(t, len(steps), 3) // (8,24)(24,24)(40,24) — through the gap
		testing.expect_value(t, steps[0], left_mid)
		testing.expect_value(t, steps[1], center) // the cell that was solid is now a waypoint
		testing.expect_value(t, steps[2], right_mid)
		testing.expect_value(t, cost, to_fixed(32)) // 2 edges × 16
		gap_steps, gap_cost = steps, cost

		near_res, nok := eval_engine_nearest(&gap_version, center)
		testing.expect(t, nok)
		near := near_res.(Variant_Value)
		testing.expect_value(t, near.case_name, "Some")
		testing.expect_value(t, near.payload^.(Vec2), center) // snaps to the freed cell
	}

	// (c) wall BUILT (walkable → solid): the top-right cell is isolated, so a path
	// to it is Unreachable and reachable reads false over the new version.
	{
		version := los_version(nav_layer_with_cells(walled))
		res, ok := eval_engine_nav(&version, "path", c0, c2)
		testing.expect(t, ok)
		variant := res.(Variant_Value)
		testing.expect_value(t, variant.case_name, "Err")
		testing.expect_value(t, variant.payload^.(Variant_Value).case_name, "Unreachable")
		reach, rok := eval_engine_nav(&version, "reachable", c0, c2)
		testing.expect(t, rok)
		testing.expect_value(t, reach.(bool), false)
	}

	// (d) SAME-tick / old-version visibility: a query against the OLD (base) version
	// still sees the OLD topology even after the gap version is committed — the
	// committed = entering-version §18 §4 next-tick invariant los already obeys.
	{
		base_version := los_version(nav_layer_with_cells(base))
		old_res, ok := eval_engine_nav(&base_version, "path", left_mid, right_mid)
		testing.expect(t, ok)
		_, old_cost, decoded := nav_path_steps(old_res)
		testing.expect(t, decoded)
		testing.expect_value(t, old_cost, to_fixed(64)) // still the detour — the gap is not visible here
	}

	// (e) replay / refold determinism: build the gap version a SECOND way — by
	// FOLDING a SetTile(center → floor) over the base version (the §18 §4 tick-end
	// application) — and assert the derived route is BIT-IDENTICAL to the
	// hand-committed gap route. Same inputs ⇒ same committed cells ⇒ same derived
	// graph ⇒ same Path.
	{
		prior := los_version(nav_layer_with_cells(base))
		state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
		// SetTile(ground, cell (1,1), "floor") — the center wall falls.
		append(&state.terrain_commands, Terrain_Command{kind = .Set_Tile, record = nav_settile_record("ground", 1, 1, "floor")})
		folded := fold_tile_layers(prior, &state)
		testing.expect_value(t, len(state.tile_refusals), 0)
		refolded := World_Version{tilemaps = folded}

		res, ok := eval_engine_nav(&refolded, "path", left_mid, right_mid)
		testing.expect(t, ok)
		refold_steps, refold_cost, decoded := nav_path_steps(res)
		testing.expect(t, decoded)
		testing.expect(t, nav_paths_equal(refold_steps, refold_cost, gap_steps, gap_cost))
	}

	// (f) layerless fallback unchanged: with NO committed layer (nav_test_interp,
	// version nil) path/reachable/nearest resolve over the baked program.navs graph
	// exactly as before — derive is never reached, the bake answers.
	{
		baked := nav_grid_graph()
		program := Program{}
		program.navs = nav_one_graph(baked)
		interp := nav_test_interp(&program)
		// reachable over the connected top row (the existing layerless contract).
		reach, rok := nav_eval_method(&interp, nav_handle_value("ground"), "reachable", baked.centers[0], baked.centers[2])
		testing.expect(t, rok)
		testing.expect_value(t, reach.(bool), true)
		// nearest snaps to a real baked center (the closest-center scan, not identity).
		near, nok := nav_eval_method(&interp, nav_handle_value("ground"), "nearest", baked.centers[0])
		testing.expect(t, nok)
		opt := near.(Variant_Value)
		testing.expect_value(t, opt.case_name, "Some")
		testing.expect_value(t, opt.payload^.(Vec2), baked.centers[0]) // exact baked center
	}
}

// nav_settile_record hand-builds one collected SetTile command Record_Value over a
// NavHandle-shaped `map` handle (the same name-keyed handle the level seam emits)
// — the settile_record mold, used here to fold a wall-fall into the gap version.
nav_settile_record :: proc(layer: string, x, y: i64, tile: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["map"] = nav_handle_value(layer)
	fields["cell"] = tilemap_cell_record(x, y)
	fields["tile"] = String_Value{text = tile}
	return Record_Value{type_name = "SetTile", fields = fields}
}

// eval_engine_nearest drives `nav.nearest(point)` through the real dispatch over
// the grid graph + the supplied committed version (the eval_engine_nav mold for
// the one-Vec2 nearest query).
eval_engine_nearest :: proc(version: ^World_Version, point: Vec2) -> (result: Value, ok: bool) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := los_interp(&program, version)
	return nav_eval_method(&interp, nav_handle_value("ground"), "nearest", point)
}
