package funpack_runtime

import "core:testing"

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

nav_vec2_slice :: proc(vs: ..Vec2) -> []Vec2 {
	out := make([]Vec2, len(vs), context.temp_allocator)
	copy(out, vs)
	return out
}

nav_error_arg :: proc(case_name: string) -> Value {
	return Variant_Value{enum_type = "NavError", case_name = case_name}
}

nav_query_interp :: proc(program: ^Program) -> Interp {
	return new_interp(program, nil, nil, empty(), tilemap_time_resource(), context.temp_allocator)
}

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

nav_arg_name :: proc(i: int) -> string {
	switch i {
	case 0:
		return "a0"
	case 1:
		return "a1"
	}
	return "a2"
}

@(test)
test_nav_of_path_replays_route :: proc(t: ^testing.T) {
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
	testing.expect_value(t, steps.elements[0].(Vec2), wp)
	testing.expect_value(t, replayed.fields["cost"].(Fixed), to_fixed(10))
}

@(test)
test_nav_of_los_and_reachable_read_true :: proc(t: ^testing.T) {
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
	testing.expect_value(t, opt.payload^.(Vec2), p)
}

@(test)
test_nav_of_advance_empty_route_is_none :: proc(t: ^testing.T) {
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

@(test)
test_nav_fail_path_is_err :: proc(t: ^testing.T) {
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

@(test)
test_nav_of_constructor_builds_non_failed :: proc(t: ^testing.T) {
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

@(test)
test_advance_next_waypoint_when_outside_arrive :: proc(t: ^testing.T) {
	program := Program{}
	interp := nav_query_interp(&program)
	wp := Vec2{x = to_fixed(10), y = Fixed(0)}
	route := nav_path_value(nav_vec2_slice(wp), to_fixed(10))
	pos := Vec2{}
	result, ok := nav_eval_method(&interp, route, "advance", pos, to_fixed(1))
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)
	next := tuple.elements[0].(Variant_Value)
	testing.expect_value(t, next.enum_type, "Option")
	testing.expect_value(t, next.case_name, "Some")
	testing.expect_value(t, next.payload^.(Vec2), wp)
	remaining := tuple.elements[1].(Record_Value)
	rem_steps := remaining.fields["steps"].(List_Value)
	testing.expect_value(t, len(rem_steps.elements), 1)
	testing.expect_value(t, rem_steps.elements[0].(Vec2), wp)
	testing.expect_value(t, remaining.fields["cost"].(Fixed), to_fixed(10))
}

@(test)
test_advance_exhausted_when_within_arrive :: proc(t: ^testing.T) {
	program := Program{}
	interp := nav_query_interp(&program)
	wp := Vec2{x = to_fixed(10), y = Fixed(0)}
	route := nav_path_value(nav_vec2_slice(wp), to_fixed(10))
	result, ok := nav_eval_method(&interp, route, "advance", wp, to_fixed(1))
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)
	next := tuple.elements[0].(Variant_Value)
	testing.expect_value(t, next.enum_type, "Option")
	testing.expect_value(t, next.case_name, "None")
	remaining := tuple.elements[1].(Record_Value)
	testing.expect_value(t, len(remaining.fields["steps"].(List_Value).elements), 0)
}

@(test)
test_engine_reachable_connected :: proc(t: ^testing.T) {
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
	testing.expect_value(t, opt.payload^.(Vec2), graph.centers[0])
}

@(test)
test_engine_nearest_tie_lowest_index_wins :: proc(t: ^testing.T) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	mid := Vec2{x = to_fixed(16), y = to_fixed(40)}
	result, ok := nav_eval_method(&interp, nav_handle_value("ground"), "nearest", mid)
	testing.expect(t, ok)
	opt := result.(Variant_Value)
	testing.expect_value(t, opt.case_name, "Some")
	testing.expect_value(t, opt.payload^.(Vec2), graph.centers[0])
}

@(test)
test_engine_nearest_empty_graph_is_none :: proc(t: ^testing.T) {
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

los_version :: proc(layer: Tile_Layer) -> World_Version {
	tilemaps := make([]Tile_Layer, 1, context.temp_allocator)
	tilemaps[0] = layer
	return World_Version{tilemaps = tilemaps}
}

los_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	return new_interp(program, version, nil, empty(), tilemap_time_resource(), context.temp_allocator)
}

eval_engine_los :: proc(version: ^World_Version, from, to: Vec2) -> (result: Value, ok: bool) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := los_interp(&program, version)
	return nav_eval_method(&interp, nav_handle_value("ground"), "los", from, to)
}

@(test)
test_engine_los_clear_corridor :: proc(t: ^testing.T) {
	version := los_version(los_grid_layer())
	result, ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = to_fixed(40)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), true)
}

@(test)
test_engine_los_solid_blocks :: proc(t: ^testing.T) {
	version := los_version(los_grid_layer())
	result, ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = to_fixed(24)}, Vec2{x = to_fixed(40), y = to_fixed(24)})
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)
}

@(test)
test_engine_los_corner_crossing_is_conservative :: proc(t: ^testing.T) {
	version := los_version(los_grid_layer())
	result, ok := eval_engine_los(&version, Vec2{x = to_fixed(8), y = to_fixed(8)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)
}

@(test)
test_engine_los_chasm_and_void_clear :: proc(t: ^testing.T) {
	layer := los_grid_layer()
	layer.cells[4] = TILE_CELL_EMPTY
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
	version_pre := los_version(los_grid_layer())
	clear_pre, ok := eval_engine_los(&version_pre, Vec2{x = to_fixed(8), y = to_fixed(40)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	testing.expect_value(t, clear_pre.(bool), true)
	walled := los_grid_layer()
	walled.cells[1] = 0
	version_post := los_version(walled)
	blocked_post, post_ok := eval_engine_los(&version_post, Vec2{x = to_fixed(8), y = to_fixed(40)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, post_ok)
	testing.expect_value(t, blocked_post.(bool), false)
}

eval_engine_nav :: proc(version: ^World_Version, method: string, from, to: Vec2) -> (result: Value, ok: bool) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := los_interp(&program, version)
	return nav_eval_method(&interp, nav_handle_value("ground"), method, from, to)
}

@(test)
test_engine_path_resolves_off_center_endpoint_to_containing_cell :: proc(t: ^testing.T) {
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
	version := los_version(los_grid_layer())
	result, ok := eval_engine_nav(&version, "path", Vec2{x = to_fixed(24), y = to_fixed(24)}, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Err")
	testing.expect_value(t, variant.payload^.(Variant_Value).case_name, "OffNav")
}

@(test)
test_engine_reachable_off_center_with_layer_is_true :: proc(t: ^testing.T) {
	version := los_version(los_grid_layer())
	off := Vec2{x = to_fixed(8) + 1, y = to_fixed(40)}
	result, ok := eval_engine_nav(&version, "reachable", off, Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), true)
}

@(test)
test_engine_path_boundary_point_resolves_half_open :: proc(t: ^testing.T) {
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
	testing.expect(t, !ok)
}

nav_layer_with_cells :: proc(pattern: []int) -> Tile_Layer {
	layer := los_grid_layer()
	cells := make([]int, len(pattern), context.temp_allocator)
	copy(cells, pattern)
	layer.cells = cells
	return layer
}

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
	c0 := Vec2{x = to_fixed(8), y = to_fixed(40)}
	c2 := Vec2{x = to_fixed(40), y = to_fixed(40)}
	left_mid := Vec2{x = to_fixed(8), y = to_fixed(24)}
	right_mid := Vec2{x = to_fixed(40), y = to_fixed(24)}
	center := Vec2{x = to_fixed(24), y = to_fixed(24)}

	base := []int{1, 1, 1, 1, 0, 1, 1, 1, 1}
	gap := []int{1, 1, 1, 1, 1, 1, 1, 1, 1}
	walled := []int{1, 0, 1, 1, 0, 0, 1, 1, 1}

	{
		baked := nav_grid_graph()
		base_layer := nav_layer_with_cells(base)
		derived := derive_nav_graph_from_layer(&base_layer, context.temp_allocator)
		testing.expect(t, nav_graphs_equal(derived, baked))

		version := los_version(nav_layer_with_cells(base))
		live_res, ok := eval_engine_nav(&version, "path", left_mid, right_mid)
		testing.expect(t, ok)
		steps, cost, decoded := nav_path_steps(live_res)
		testing.expect(t, decoded)
		testing.expect_value(t, len(steps), 5)
		testing.expect_value(t, steps[0], left_mid)
		testing.expect_value(t, steps[len(steps) - 1], right_mid)
		testing.expect_value(t, cost, to_fixed(64))

		reach, rok := eval_engine_nav(&version, "reachable", left_mid, right_mid)
		testing.expect(t, rok)
		testing.expect_value(t, reach.(bool), true)
		near_res, nok := eval_engine_nearest(&version, center)
		testing.expect(t, nok)
		near := near_res.(Variant_Value)
		testing.expect_value(t, near.case_name, "Some")
		testing.expect(t, near.payload^.(Vec2) != center)
	}

	gap_version := los_version(nav_layer_with_cells(gap))
	gap_steps: []Vec2
	gap_cost: Fixed
	{
		res, ok := eval_engine_nav(&gap_version, "path", left_mid, right_mid)
		testing.expect(t, ok)
		steps, cost, decoded := nav_path_steps(res)
		testing.expect(t, decoded)
		testing.expect_value(t, len(steps), 3)
		testing.expect_value(t, steps[0], left_mid)
		testing.expect_value(t, steps[1], center)
		testing.expect_value(t, steps[2], right_mid)
		testing.expect_value(t, cost, to_fixed(32))
		gap_steps, gap_cost = steps, cost

		near_res, nok := eval_engine_nearest(&gap_version, center)
		testing.expect(t, nok)
		near := near_res.(Variant_Value)
		testing.expect_value(t, near.case_name, "Some")
		testing.expect_value(t, near.payload^.(Vec2), center)
	}

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

	{
		base_version := los_version(nav_layer_with_cells(base))
		old_res, ok := eval_engine_nav(&base_version, "path", left_mid, right_mid)
		testing.expect(t, ok)
		_, old_cost, decoded := nav_path_steps(old_res)
		testing.expect(t, decoded)
		testing.expect_value(t, old_cost, to_fixed(64))
	}

	{
		prior := los_version(nav_layer_with_cells(base))
		state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
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

	{
		baked := nav_grid_graph()
		program := Program{}
		program.navs = nav_one_graph(baked)
		interp := nav_test_interp(&program)
		reach, rok := nav_eval_method(&interp, nav_handle_value("ground"), "reachable", baked.centers[0], baked.centers[2])
		testing.expect(t, rok)
		testing.expect_value(t, reach.(bool), true)
		near, nok := nav_eval_method(&interp, nav_handle_value("ground"), "nearest", baked.centers[0])
		testing.expect(t, nok)
		opt := near.(Variant_Value)
		testing.expect_value(t, opt.case_name, "Some")
		testing.expect_value(t, opt.payload^.(Vec2), baked.centers[0])
	}
}

nav_settile_record :: proc(layer: string, x, y: i64, tile: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["map"] = nav_handle_value(layer)
	fields["cell"] = tilemap_cell_record(x, y)
	fields["tile"] = String_Value{text = tile}
	return Record_Value{type_name = "SetTile", fields = fields}
}

eval_engine_nearest :: proc(version: ^World_Version, point: Vec2) -> (result: Value, ok: bool) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := los_interp(&program, version)
	return nav_eval_method(&interp, nav_handle_value("ground"), "nearest", point)
}
