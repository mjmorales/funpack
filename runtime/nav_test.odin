// The §12 nav acceptance fixtures: the v13 [nav] loader decode (centers/adj
// bit-exact incl. the ascending-adjacency sort, plus the fail-closed refusal
// sweep), and the pure path() query pinned to EXACT route + EXACT fixed-point
// cost over hand-built graphs — a straight route, a detour around a solid cell,
// an Unreachable disconnected node, and an OffNav off-center endpoint. Raw-bits
// equality throughout; no float, no tolerance (§10.5, §12 §2 bit-identical).
//
// The emitted-warren end-to-end golden (live capture vs committed-log re-fold
// over warren.artifact) is a SEPARATE concern — these fixtures prove the
// loader + search arms on hand-built graphs, independent of the emitted artifact.
package funpack_runtime

import "core:testing"

// --- the hand-built 3×3-minus-center grid graph -----------------------------
//
// A 3×3 grid of cell centers, cell size 16, with the CENTER cell solid (omitted)
// — eight walkable nodes in row-major order (the center index is skipped, so the
// node indices renumber around the hole). Centers are the cell centers a
// cell-16 grid anchored at top-left (0, 48) yields (center_of: x = col·16+8,
// y = 48-(row·16+8)), the same mapping tilemap.odin pins, so the route's steps
// are concrete world points:
//
//   node 0 (0,0)=(8,40)   node 1 (1,0)=(24,40)   node 2 (2,0)=(40,40)
//   node 3 (0,1)=(8,24)   [solid center omitted]  node 4 (2,1)=(40,24)
//   node 5 (0,2)=(8,8)    node 6 (1,2)=(24,8)     node 7 (2,2)=(40,8)
//
// 4-neighbor orthogonal edges only (no diagonals), the center cell carrying
// none. Edges authored A<B canonical: 0-1,1-2,0-3,2-4,3-5,4-7,5-6,6-7.
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

// nav_neighbors heap-allocates a small adjacency list from the temp arena (a
// compound slice literal cannot escape its constructing stack frame, Lore #11).
nav_neighbors :: proc(ns: ..int) -> []int {
	out := make([]int, len(ns), context.temp_allocator)
	copy(out, ns)
	return out
}

// nav_test_interp builds an Interp over a Program carrying the supplied graphs —
// the minimal world path()'s method dispatch needs (no things, no pipeline; the
// query reads only the decoded graph), the tilemap_test_interp mold.
nav_test_interp :: proc(program: ^Program) -> Interp {
	return new_interp(program, nil, nil, empty(), tilemap_time_resource(), context.temp_allocator)
}

// nav_handle_value builds the level seam's `NavHandle{name}` record — the named
// receiver shape (the §12 escape hatch).
nav_handle_value :: proc(name: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["name"] = String_Value{text = name}
	return Record_Value{type_name = "NavHandle", fields = fields}
}

// eval_nav_path hand-builds the `n.path(f, t)` call forest (the
// eval_tilemap_query mold) and evaluates it with the handle bound to `n` and the
// two endpoints bound to `f`/`t` — so the eval_method_call dispatch arm is
// exercised, never the kernel in isolation.
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

// --- the v13 [nav] loader decode --------------------------------------------

// NAV_FIXTURE_ARTIFACT is a minimal v13 artifact carrying a 3-node nav graph:
// three centers and two edges (a path 0-1-2). The edges are authored OUT of
// ascending order on node 1 (1-2 then 0-1) so the loader's ascending sort of
// adj[1] is observable — the bit-stable tie-break does not depend on emission
// order.
NAV_FIXTURE_ARTIFACT ::
	"funpack-artifact 19\n" +
	"[nav 1]\n" +
	"nav ground 3 2\n" +
	"navnode 34359738368 171798691840\n" + // (8, 40) raw Q32.32
	"navnode 103079215104 171798691840\n" + // (24, 40)
	"navnode 171798691840 171798691840\n" + // (40, 40)
	"navedge 1 2\n" +
	"navedge 0 1\n"

@(test)
test_load_navs_decodes :: proc(t: ^testing.T) {
	// AC (decode): a populated [nav] section loads — centers land bit-exact in
	// node-index order, each undirected navedge appends both directions, and
	// every adj[i] is SORTED ASCENDING regardless of emission order (node 1's
	// edges were authored 1-2 then 0-1; adj[1] decodes [0, 2]).
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
	// adj[0]=[1], adj[1]=[0,2] (ascending — authored 2 then 0), adj[2]=[1].
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
	// The `[nav 0]` tail every level-less artifact emits keeps loading clean
	// with zero graphs (no special case).
	program, err := load_program("funpack-artifact 19\n[nav 0]\n", context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(program.navs), 0)
}

@(test)
test_load_navs_deterministic :: proc(t: ^testing.T) {
	// AC (determinism): same artifact ⇒ same graph — two independent loads
	// decode structurally identical graphs (slice-order walks, no map touches
	// the decode).
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
	// AC (refusals): every malformed [nav] record fails closed with .Bad_Field.
	// Each case bends exactly one §12 shape rule of the well-formed fixture.
	malformed := [?]string {
		// lead line: wrong arity (a trailing token — nav carries NO grid metadata)
		"funpack-artifact 19\n[nav 1]\nnav ground 1 0 16\nnavnode 0 0\n",
		// lead line: non-numeric node count
		"funpack-artifact 19\n[nav 1]\nnav ground x 0\nnavnode 0 0\n",
		// lead line: non-numeric edge count
		"funpack-artifact 19\n[nav 1]\nnav ground 1 x\nnavnode 0 0\n",
		// sub-record run: a missing navnode line (declared NODE_COUNT=2, one present)
		"funpack-artifact 19\n[nav 1]\nnav ground 2 0\nnavnode 0 0\n",
		// sub-record run: a surplus navedge line (declared EDGE_COUNT=0, one present)
		"funpack-artifact 19\n[nav 1]\nnav ground 1 0\nnavnode 0 0\nnavedge 0 0\n",
		// navnode: wrong arity (missing FIXED_Y)
		"funpack-artifact 19\n[nav 1]\nnav ground 1 0\nnavnode 0\n",
		// navnode: a non-numeric coordinate
		"funpack-artifact 19\n[nav 1]\nnav ground 1 0\nnavnode 0 z\n",
		// navedge: an index past the node range (NODE_COUNT=2, index 2 invalid)
		"funpack-artifact 19\n[nav 1]\nnav ground 2 1\nnavnode 0 0\nnavnode 16 0\nnavedge 0 2\n",
		// navedge: a negative index
		"funpack-artifact 19\n[nav 1]\nnav ground 2 1\nnavnode 0 0\nnavnode 16 0\nnavedge 0 -1\n",
		// navedge: wrong arity (missing B)
		"funpack-artifact 19\n[nav 1]\nnav ground 2 1\nnavnode 0 0\nnavnode 16 0\nnavedge 0\n",
	}
	for artifact in malformed {
		_, err := load_program(artifact, context.temp_allocator)
		testing.expect_value(t, err, Artifact_Error.Bad_Field)
	}
}

// --- path() over the hand-built graph ---------------------------------------

// nav_expect_path_steps asserts a Result::Ok(Path) carries EXACTLY the given
// center sequence as `steps` (raw Vec2-bits equality) and EXACTLY the kernel-
// derived per-edge distance sum as `cost` — the cost computed through the SAME
// fixed_add/vec2_length ops the query runs (pin the kernel value, not an
// idealized magnitude — Lore #13), so a bit-exact replay gives no false positive.
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
	// Cost: the kernel-derived sum over the SAME node route — bit-exact.
	expected_cost := nav_route_cost(graph, expected_nodes)
	testing.expect_value(t, path.fields["cost"].(Fixed), expected_cost)
}

@(test)
test_nav_path_straight_route :: proc(t: ^testing.T) {
	// AC (straight route): a route along the top row 0→2 steps through node 1
	// (the only path: 0-1-2). steps = centers[0,1,2]; cost = two cell-16 edges.
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	result, ok := eval_nav_path(&interp, nav_handle_value("ground"), graph.centers[0], graph.centers[2])
	nav_expect_path_steps(t, &graph, result, ok, []int{0, 1, 2})
	// Two axis-aligned cell-16 edges → cost = to_fixed(32), the perfect-square
	// path: each vec2_length(16,0) = to_fixed(16).
	path := result.(Variant_Value).payload^.(Record_Value)
	testing.expect_value(t, path.fields["cost"].(Fixed), to_fixed(32))
}

@(test)
test_nav_path_detour_around_solid :: proc(t: ^testing.T) {
	// AC (detour): the center cell is solid, so a route from the top-left corner
	// (node 0) to the bottom-right corner (node 7) cannot cut the diagonal — it
	// routes around the hole. BFS with ascending-index tie-break takes 0-1-2-4-7
	// (the right-then-down arm: node 0 expands 1 before 3, so the goal is first
	// reached along the lower-index frontier). steps pinned exactly; cost is four
	// cell-16 edges = to_fixed(64).
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
	// AC (Unreachable): a node disconnected from the rest — both endpoints are
	// valid walkable centers, but no edge sequence reaches the goal — yields
	// Result::Err(NavError::Unreachable), never a silently-empty path.
	graph := nav_grid_graph()
	// Append an isolated 9th node (index 8) with no edges.
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
	// AC (OffNav): an endpoint that matches NO walkable cell center (path() does
	// not snap — that is nearest()'s job, §12 §3) yields
	// Result::Err(NavError::OffNav), checked BEFORE the search. The off-center
	// point is one bit off a real center, so it is genuinely not a node.
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	off := Vec2{x = to_fixed(8) + 1, y = to_fixed(40)} // one raw bit off center 0
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
	// AC (§12 default): a `nav: Nav` param binds the UNNAMED NavHandle marker
	// (no `name` field), which resolves to the single baked layer — the §12
	// "default is the one resource, no name". The same 0→2 route answers.
	graph := nav_grid_graph()
	program := Program{}
	program.navs = nav_one_graph(graph)
	interp := nav_test_interp(&program)
	marker := nav_marker(&interp)
	result, ok := eval_nav_path(&interp, marker.(Record_Value), graph.centers[0], graph.centers[2])
	nav_expect_path_steps(t, &graph, result, ok, []int{0, 1, 2})
}

// nav_one_graph wraps a single graph in the program's []Nav_Graph slice (a
// compound slice literal cannot escape its stack frame, Lore #11).
nav_one_graph :: proc(graph: Nav_Graph) -> []Nav_Graph {
	out := make([]Nav_Graph, 1, context.temp_allocator)
	out[0] = graph
	return out
}
