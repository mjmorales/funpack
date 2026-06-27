package funpack_runtime

import "core:testing"

nav_grid_graph :: proc() -> Nav_Graph {
	centers := make([]Vec2, 8, context.temp_allocator)
	centers[0] = Vec2{x = to_fixed(8), y = to_fixed(40)}
	centers[1] = Vec2{x = to_fixed(24), y = to_fixed(40)}
	centers[2] = Vec2{x = to_fixed(40), y = to_fixed(40)}
	centers[3] = Vec2{x = to_fixed(8), y = to_fixed(24)}
	centers[4] = Vec2{x = to_fixed(40), y = to_fixed(24)}
	centers[5] = Vec2{x = to_fixed(8), y = to_fixed(8)}
	centers[6] = Vec2{x = to_fixed(24), y = to_fixed(8)}
	centers[7] = Vec2{x = to_fixed(40), y = to_fixed(8)}
	adj := make([][]int, 8, context.temp_allocator)
	adj[0] = nav_neighbors(1, 3)
	adj[1] = nav_neighbors(0, 2)
	adj[2] = nav_neighbors(1, 4)
	adj[3] = nav_neighbors(0, 5)
	adj[4] = nav_neighbors(2, 7)
	adj[5] = nav_neighbors(3, 6)
	adj[6] = nav_neighbors(5, 7)
	adj[7] = nav_neighbors(4, 6)
	return Nav_Graph{name = "ground", centers = centers, adj = adj}
}

nav_neighbors :: proc(ns: ..int) -> []int {
	out := make([]int, len(ns), context.temp_allocator)
	copy(out, ns)
	return out
}

nav_test_interp :: proc(program: ^Program) -> Interp {
	return new_interp(program, nil, nil, empty(), tilemap_time_resource(), context.temp_allocator)
}

nav_handle_value :: proc(name: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["name"] = String_Value{text = name}
	return Record_Value{type_name = "NavHandle", fields = fields}
}

eval_nav_path :: proc(
	interp: ^Interp,
	handle: Record_Value,
	from, to: Vec2,
) -> (
	result: Value,
	ok: bool,
) {
	recv := Node{kind = .Name, fields = tilemap_node_fields("n")}
	field := Node{kind = .Field, fields = tilemap_node_fields("path"), children = tilemap_node_children(recv)}
	from_node := Node{kind = .Name, fields = tilemap_node_fields("f")}
	to_node := Node{kind = .Name, fields = tilemap_node_fields("t")}
	call := Node {
		kind     = .Call,
		children = tilemap_node_children(field, from_node, to_node),
	}
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["n"] = handle
	env.names["f"] = from
	env.names["t"] = to
	return eval(interp, &call, &env)
}

NAV_FIXTURE_ARTIFACT ::
	"funpack-artifact 19\n" +
	"[nav 1]\n" +
	"nav ground 3 2\n" +
	"navnode 34359738368 171798691840\n" +
	"navnode 103079215104 171798691840\n" +
	"navnode 171798691840 171798691840\n" +
	"navedge 1 2\n" +
	"navedge 0 1\n"

@(test)
test_load_navs_decodes :: proc(t: ^testing.T) {
	program, err := load_program(NAV_FIXTURE_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(program.navs), 1)
	graph := program.navs[0]
	testing.expect_value(t, graph.name, "ground")
	testing.expect_value(t, len(graph.centers), 3)
	testing.expect_value(t, graph.centers[0], Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect_value(t, graph.centers[1], Vec2{x = to_fixed(24), y = to_fixed(40)})
	testing.expect_value(t, graph.centers[2], Vec2{x = to_fixed(40), y = to_fixed(40)})
	testing.expect_value(t, len(graph.adj), 3)
	testing.expect_value(t, len(graph.adj[0]), 1)
	testing.expect_value(t, graph.adj[0][0], 1)
	testing.expect_value(t, len(graph.adj[1]), 2)
	testing.expect_value(t, graph.adj[1][0], 0)
	testing.expect_value(t, graph.adj[1][1], 2)
	testing.expect_value(t, len(graph.adj[2]), 1)
	testing.expect_value(t, graph.adj[2][0], 1)
}

@(test)
test_load_navs_empty_section_still_loads :: proc(t: ^testing.T) {
	program, err := load_program("funpack-artifact 19\n[nav 0]\n", context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(program.navs), 0)
}

@(test)
test_load_navs_deterministic :: proc(t: ^testing.T) {
	first, err1 := load_program(NAV_FIXTURE_ARTIFACT, context.temp_allocator)
	second, err2 := load_program(NAV_FIXTURE_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, err1, Artifact_Error.None)
	testing.expect_value(t, err2, Artifact_Error.None)
	testing.expect_value(t, len(first.navs), len(second.navs))
	for graph, i in first.navs {
		testing.expect(t, nav_graphs_equal(graph, second.navs[i]))
	}
}

@(test)
test_load_navs_malformed_refused :: proc(t: ^testing.T) {
	malformed := [?]string {
		"funpack-artifact 19\n[nav 1]\nnav ground 1 0 16\nnavnode 0 0\n",
		"funpack-artifact 19\n[nav 1]\nnav ground x 0\nnavnode 0 0\n",
		"funpack-artifact 19\n[nav 1]\nnav ground 1 x\nnavnode 0 0\n",
		"funpack-artifact 19\n[nav 1]\nnav ground 2 0\nnavnode 0 0\n",
		"funpack-artifact 19\n[nav 1]\nnav ground 1 0\nnavnode 0 0\nnavedge 0 0\n",
		"funpack-artifact 19\n[nav 1]\nnav ground 1 0\nnavnode 0\n",
		"funpack-artifact 19\n[nav 1]\nnav ground 1 0\nnavnode 0 z\n",
		"funpack-artifact 19\n[nav 1]\nnav ground 2 1\nnavnode 0 0\nnavnode 16 0\nnavedge 0 2\n",
		"funpack-artifact 19\n[nav 1]\nnav ground 2 1\nnavnode 0 0\nnavnode 16 0\nnavedge 0 -1\n",
		"funpack-artifact 19\n[nav 1]\nnav ground 2 1\nnavnode 0 0\nnavnode 16 0\nnavedge 0\n",
	}
	for artifact in malformed {
		_, err := load_program(artifact, context.temp_allocator)
		testing.expect_value(t, err, Artifact_Error.Bad_Field)
	}
}

nav_expect_path_steps :: proc(
	t: ^testing.T,
	graph: ^Nav_Graph,
	result: Value,
	ok: bool,
	expected_nodes: []int,
) {
	testing.expect(t, ok)
	variant, is_variant := result.(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, variant.enum_type, "Result")
	testing.expect_value(t, variant.case_name, "Ok")
	path := variant.payload^.(Record_Value)
	testing.expect_value(t, path.type_name, "Path")
	steps := path.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), len(expected_nodes))
	for n, i in expected_nodes {
		testing.expect_value(t, steps.elements[i].(Vec2), graph.centers[n])
	}
	expected_cost := nav_route_cost(graph, expected_nodes)
	testing.expect_value(t, path.fields["cost"].(Fixed), expected_cost)
}

@(test)
test_nav_path_straight_route :: proc(t: ^testing.T) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	result, ok := eval_nav_path(&interp, nav_handle_value("ground"), graph.centers[0], graph.centers[2])
	nav_expect_path_steps(t, &graph, result, ok, []int{0, 1, 2})
	path := result.(Variant_Value).payload^.(Record_Value)
	testing.expect_value(t, path.fields["cost"].(Fixed), to_fixed(32))
}

@(test)
test_nav_path_detour_around_solid :: proc(t: ^testing.T) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	result, ok := eval_nav_path(&interp, nav_handle_value("ground"), graph.centers[0], graph.centers[7])
	nav_expect_path_steps(t, &graph, result, ok, []int{0, 1, 2, 4, 7})
	path := result.(Variant_Value).payload^.(Record_Value)
	testing.expect_value(t, path.fields["cost"].(Fixed), to_fixed(64))
}

@(test)
test_nav_path_unreachable :: proc(t: ^testing.T) {
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
	result, ok := eval_nav_path(&interp, nav_handle_value("ground"), graph.centers[0], graph.centers[8])
	testing.expect(t, ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.enum_type, "Result")
	testing.expect_value(t, variant.case_name, "Err")
	nav_err := variant.payload^.(Variant_Value)
	testing.expect_value(t, nav_err.enum_type, "NavError")
	testing.expect_value(t, nav_err.case_name, "Unreachable")
}

@(test)
test_nav_path_off_nav_endpoint :: proc(t: ^testing.T) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	off := Vec2{x = to_fixed(8) + 1, y = to_fixed(40)}
	result, ok := eval_nav_path(&interp, nav_handle_value("ground"), off, graph.centers[7])
	testing.expect(t, ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Err")
	nav_err := variant.payload^.(Variant_Value)
	testing.expect_value(t, nav_err.enum_type, "NavError")
	testing.expect_value(t, nav_err.case_name, "OffNav")
}

@(test)
test_nav_path_default_unnamed_handle :: proc(t: ^testing.T) {
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	marker := nav_marker(&interp)
	result, ok := eval_nav_path(&interp, marker.(Record_Value), graph.centers[0], graph.centers[2])
	nav_expect_path_steps(t, &graph, result, ok, []int{0, 1, 2})
}

nav_one_graph :: proc(graph: Nav_Graph) -> []Nav_Graph {
	out := make([]Nav_Graph, 1, context.temp_allocator)
	out[0] = graph
	return out
}
