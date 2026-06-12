// The §12 baked navigation graph and its single pure query `path(from, to)`:
// the walkable-cell topology a tilemap's solids imply, BAKED on the funpack side
// (the picture IS the topology, §12 §1) and carried in the artifact's [nav]
// section (docs/artifact-format.md §12, schema v13). The runtime CONSUMES this
// graph and path-finds over it; it never authors the graph (runtime CONSUMES the
// format, funpack DEFINES it — Lore #9). The query is reached through a level
// seam's `NavHandle{name}` record receiver (`nav.path(from, to)`), the
// apply_impulse / TilemapHandle method-dispatch mold (interp_call.odin →
// eval_nav_method here).
//
// The GRAPH queries (path/reachable/nearest) are VERSION-STATE-COUPLED like los,
// not bake-static: when the nav's 1:1 layer is committed they answer over the
// LIVE tile state of that layer, re-deriving the walkable topology per query from
// the committed cells (derive_nav_graph_from_layer), so a path() issued the tick
// after a SetTile wall falls routes through the new gap (§12 §1; ADR
// 2026-06-12-engine-path-reads-live-tilemap-no-materialized-nav). The baked
// program.navs graph is consulted ONLY as the layerless fallback (no committed
// 1:1 layer — layerless fixtures, nav-only artifacts), so there is no
// materialized per-version nav table and no save/restore nav carry: the live
// layer the §24 save stream already persists IS the nav state. los is the same
// shape (an OCCUPANCY query over the live layer, ADR
// 2026-06-11-engine-los-reads-live-tilemap-occupancy); the derivation rule is
// the funpack bake's rule read live, so a derive over UNCHANGED terrain is
// bit-identical to the baked decode (the static-golden consistency guarantee).
//
// Determinism (§10.5, the tilemap.odin invariant): path() is a pure function of
// (graph, from, to). The search is a uniform-cost BFS over the flat 4-neighbor
// graph — edges are unweighted and uniform, so Dijkstra/A* collapse to BFS with
// f=g and NO heuristic (a heuristic would be a §12 §4-forbidden runtime knob).
// The frontier is a FIFO array, neighbors are enqueued in ascending node-index
// order (adj[i] is sorted ascending at load), and first-visit-wins — no PRNG, no
// map iteration, arrays and indexed scans only, so the route is bit-identical on
// every machine (§12 §2 "fixed tie-break: lowest f, then stable cell order").
package funpack_runtime

import "core:strconv"
import "core:strings"

// NAV_NO_NODE marks "no node" in the BFS predecessor/visited arrays and the
// endpoint→node resolution — an endpoint Vec2 that matches no walkable center.
NAV_NO_NODE :: -1

// Nav_Graph is one decoded [nav] record (§12): the graph name (the NavHandle
// constant name, 1:1 with its tilemap), the walkable-cell CENTERS in node-index
// order (line position IS the node index, §12 §5 — centers, never the raw Cell
// index), and the per-node adjacency lists built from the undirected `navedge`
// pairs. `centers[i]` is node i's world-space cell center as raw Q32.32 Vec2
// bits; `adj[i]` is node i's neighbor node indices, SORTED ASCENDING so the BFS
// tie-break is bit-stable regardless of the edge emission order.
Nav_Graph :: struct {
	name:    string,
	centers: []Vec2, // node-index-ordered walkable cell centers (raw Q32.32)
	adj:     [][]int, // per-node neighbor indices, ascending (the 4-neighbor graph)
}

// program_nav finds a decoded nav graph by its NavHandle name, or nil — the
// bare-name lookup the handle-method dispatch resolves a `NavHandle{name}`
// receiver through (mirroring program_tilemap / program_function). The graph is
// bake-static, so there is no version_nav twin: path() reads the Program's
// pristine decode directly.
program_nav :: proc(program: ^Program, name: string) -> ^Nav_Graph {
	for &graph in program.navs {
		if graph.name == name {
			return &graph
		}
	}
	return nil
}

// nav_graphs_equal compares two decoded graphs structurally — the loader
// determinism assertion (same artifact ⇒ same graph). Centers compare by raw
// Vec2 bits; adjacency compares element-wise (order included, so the ascending
// sort is part of the equality).
nav_graphs_equal :: proc(a, b: Nav_Graph) -> bool {
	if a.name != b.name || len(a.centers) != len(b.centers) || len(a.adj) != len(b.adj) {
		return false
	}
	for center, i in a.centers {
		if center != b.centers[i] {
			return false
		}
	}
	for neighbors, i in a.adj {
		if len(neighbors) != len(b.adj[i]) {
			return false
		}
		for n, j in neighbors {
			if n != b.adj[i][j] {
				return false
			}
		}
	}
	return true
}

// --- the live-layer derivation (the bake's rule read per query) ------------

// derive_nav_graph_from_layer rebuilds the §12 §1 nav graph from one committed
// tile layer's LIVE cells — the funpack bake's derivation rule
// (build.odin:bake_layer_nav_graph + nav_cell_walkable) reproduced in the
// runtime so a path/reachable/nearest query answers over the tick's terrain
// (ADR 2026-06-12-engine-path-reads-live-tilemap-no-materialized-nav). It is a
// pure function of the layer: the walkable set, the centers, and the edges all
// derive from cells + palette + anchor alone, so deriving twice over the same
// layer yields a bit-identical graph (the replay/refold determinism guarantee).
//
// Walkability is the bake's `!solid` verdict read through tilemap_solid_at: an
// empty/marker cell (TILE_CELL_EMPTY) and a non-solid tile are walkable, a solid
// tile is not — bit-equivalent to nav_cell_walkable because tilemap_solid_at
// returns false for an empty cell (the void carries no solidity, §18 §2). Nodes
// are the walkable cells in ROW-MAJOR rank order (line position IS the node
// index, §12 §5), centers come from tilemap_center_of (the same kernel math the
// bake uses), and edges are the 4-neighbor orthogonal adjacencies — the bake's
// undirected dedupe (emit only right c+1 and down r+1) so each edge appears once,
// then every adj[i] SORTED ASCENDING (nav_sort_ascending) so the BFS tie-break is
// bit-stable. The ascending-cell-index scan visits cells in ascending node-index
// order, so a derive over UNCHANGED terrain is structurally equal to the baked
// decode (nav_graphs_equal == true) — the static-golden consistency guarantee.
//
// Ephemeral per query: the graph is built on the supplied (temp/per-tick)
// allocator and never enters the committed World_Version chain — there is no
// materialized per-version nav state to reclaim (Lore #17 O(delta) spirit; the
// "incremental flow field" §12 §2 gestures at is a deferred perf task, not this).
derive_nav_graph_from_layer :: proc(
	layer: ^Tile_Layer,
	allocator := context.allocator,
) -> Nav_Graph {
	// First pass: assign each walkable cell its row-major node index (the bake's
	// cell→node map), so an edge can name node indices, not cell indices.
	cell_count := layer.cols * layer.rows
	cell_to_node := make([]int, cell_count, context.temp_allocator)
	node_count := 0
	for row in 0 ..< layer.rows {
		for col in 0 ..< layer.cols {
			cell := row * layer.cols + col
			if !tilemap_solid_at(layer, col, row) {
				cell_to_node[cell] = node_count
				node_count += 1
			} else {
				cell_to_node[cell] = NAV_NO_NODE
			}
		}
	}
	centers := make([]Vec2, node_count, allocator)
	// Mutable per-node neighbor lists, frozen into owned ascending slices after.
	lists := make([][dynamic]int, node_count, context.temp_allocator)
	for &list in lists {
		list = make([dynamic]int, context.temp_allocator)
	}
	for row in 0 ..< layer.rows {
		for col in 0 ..< layer.cols {
			cell := row * layer.cols + col
			node := cell_to_node[cell]
			if node == NAV_NO_NODE {
				continue
			}
			centers[node] = tilemap_center_of(layer, i64(col), i64(row))
			// Undirected dedupe: open only the right (c+1) and down (r+1) edges so
			// each adjacency appears once; append to BOTH endpoints' lists.
			if col + 1 < layer.cols {
				if right := cell_to_node[cell + 1]; right != NAV_NO_NODE {
					append(&lists[node], right)
					append(&lists[right], node)
				}
			}
			if row + 1 < layer.rows {
				if down := cell_to_node[cell + layer.cols]; down != NAV_NO_NODE {
					append(&lists[node], down)
					append(&lists[down], node)
				}
			}
		}
	}
	adj := make([][]int, node_count, allocator)
	for &list, i in lists {
		nav_sort_ascending(list[:])
		neighbors := make([]int, len(list), allocator)
		copy(neighbors, list[:])
		adj[i] = neighbors
	}
	return Nav_Graph{name = layer.name, centers = centers, adj = adj}
}

// --- the §12 §2 path() search (pure, fixed-point, total) -------------------

// nav_node_of resolves an endpoint Vec2 to its walkable node index by EXACT
// center match — raw Q32.32 Vec2-bits equality against the graph's centers (the
// tilemap.odin anchor-compare discipline), scanned in ascending node order so
// the first match is the stable one. This is the RESOLUTION PRIMITIVE, not the
// §12 §2 endpoint contract: endpoints resolve to the CONTAINING walkable cell
// (nav_resolve_node) — this scan is its exact-center fast path and the whole
// contract for a layerless graph. NAV_NO_NODE for an empty graph.
nav_node_of :: proc(graph: ^Nav_Graph, point: Vec2) -> int {
	for center, i in graph.centers {
		if center == point {
			return i
		}
	}
	return NAV_NO_NODE
}

// nav_resolve_node is the §12 §2 endpoint resolution (ADR
// 2026-06-11-path-endpoints-resolve-to-containing-cell): an endpoint resolves
// to the walkable node of the cell CONTAINING it — the half-open cell_of
// partition over the graph's 1:1 layer, the containing cell's center
// reconstructed via tilemap_center_of (bit-identical to the bake's navnode
// math by construction), then the exact center scan. Resolution reads only the
// layer's GEOMETRY (cell size, anchor, dims) — fields SetTile never mutates —
// so it is immune to dynamic terrain. The exact-center scan runs first: a
// center is never on a cell boundary, so the fast path cannot disagree with
// containment, and it is the WHOLE contract for a layerless graph (a
// hand-built fixture with no committed 1:1 tilemap) — off-center resolution
// without geometry would be a guess, so it fails closed to NAV_NO_NODE
// (→ OffNav / false at the callers, never a snapped guess; snapping is
// nearest()'s job, §12 §3).
nav_resolve_node :: proc(graph: ^Nav_Graph, layer: ^Tile_Layer, point: Vec2) -> int {
	if node := nav_node_of(graph, point); node != NAV_NO_NODE {
		return node
	}
	if layer == nil {
		return NAV_NO_NODE
	}
	col, row := tilemap_cell_of(layer, point)
	return nav_node_of(graph, tilemap_center_of(layer, col, row))
}

// nav_path searches the flat 4-neighbor graph for a route from node `from` to
// node `to` — the uniform-cost BFS that backs path(). Returns the node-index
// route (inclusive of both endpoints) on success, or ok=false when `to` is
// unreachable from `from` within the graph's connected component.
//
// FIFO frontier as a plain array (a head cursor walks it — no map, no PRNG);
// neighbors are pushed in adj[i] ascending-index order; first-visit-wins (a node
// already discovered is never re-enqueued). The predecessor array reconstructs
// the route by walking back from `to`, then reversing — so the route is a pure
// function of (graph, from, to), bit-identical on replay (§12 §2).
nav_path :: proc(
	graph: ^Nav_Graph,
	from, to: int,
	allocator := context.allocator,
) -> (
	route: []int,
	ok: bool,
) {
	count := len(graph.centers)
	// from == to is the degenerate single-node route (no edges traversed).
	if from == to {
		single := make([]int, 1, allocator)
		single[0] = from
		return single, true
	}
	pred := make([]int, count, context.temp_allocator)
	for i in 0 ..< count {
		pred[i] = NAV_NO_NODE
	}
	visited := make([]bool, count, context.temp_allocator)
	frontier := make([dynamic]int, context.temp_allocator)
	append(&frontier, from)
	visited[from] = true
	reached := false
	for head := 0; head < len(frontier); head += 1 {
		node := frontier[head]
		if node == to {
			reached = true
			break
		}
		for neighbor in graph.adj[node] {
			if visited[neighbor] {
				continue
			}
			visited[neighbor] = true
			pred[neighbor] = node
			append(&frontier, neighbor)
		}
	}
	if !reached && !visited[to] {
		return nil, false
	}
	// Reconstruct from `to` back to `from` via predecessors, then reverse into
	// start→goal order.
	length := 0
	for node := to; node != NAV_NO_NODE; node = pred[node] {
		length += 1
		if node == from {
			break
		}
	}
	out := make([]int, length, allocator)
	node := to
	for i := length - 1; i >= 0; i -= 1 {
		out[i] = node
		node = pred[node]
	}
	return out, true
}

// nav_route_cost is the §12 §2 fixed-point route cost: the Q32.32 sum of the
// per-edge center-to-center distances along the chosen route, accumulated
// through the kernel (fixed_add over vec2_length(center_b - center_a)). The
// [nav] format deliberately omits cell_size (§12 §5), so cost is NEVER
// hop-count × cell_size — it derives from the centers, the only metric the graph
// carries. An empty/single-node route has zero cost.
nav_route_cost :: proc(graph: ^Nav_Graph, route: []int) -> Fixed {
	cost := Fixed(0)
	for i in 1 ..< len(route) {
		segment := vec2_sub(graph.centers[route[i]], graph.centers[route[i - 1]])
		cost = fixed_add(cost, vec2_length(segment))
	}
	return cost
}

// --- the NavHandle method dispatch (the behavior-call surface) -------------

// eval_nav_method lowers a §12 ENGINE nav query reached as a value-method on a
// level seam's `NavHandle{name}` record receiver — warren's
// `nav.path(self.pos, goal)` calling convention (the TilemapHandle /
// apply_impulse mold) — over a REAL loaded Nav_Graph. This is the engine side
// of the §12 surface (the fixture side is eval_nav_fixture_method over the
// Nav_Value arm). A member outside these arms falls through
// (is_nav_method=false) to the next receiver arm.
//
//   - path(from, to)      → Result[Path, NavError] over the loaded graph (exact
//                           endpoint match → OffNav / Unreachable / Ok(Path)).
//   - reachable(from, to) → Bool: a route exists at all (the BFS reachability,
//                           no waypoints materialized). An off-nav endpoint is
//                           NOT an error here (reachable returns Bool, not a
//                           Result) → false.
//   - nearest(point)      → Option[Vec2]: the closest walkable center by squared
//                           distance, ascending-index tie-break; empty graph →
//                           None.
//   - los(from, to)       → Bool: the §12 §3 occupancy verdict — the segment's
//                           supercover over the graph's 1:1 tile layer contains
//                           no solid cell (tilemap_segment_clear), read from the
//                           COMMITTED version like every TilemapHandle query
//                           (ADR 2026-06-11-engine-los-reads-live-tilemap-
//                           occupancy). No committed layer → fail closed.
//
// A malformed receiver (unknown graph, non-Vec2 arg) or wrong call arity fails
// closed (ok=false), never a guessed result.
eval_nav_method :: proc(
	interp: ^Interp,
	node: ^Node,
	env: ^Env,
	handle: Record_Value,
	method: string,
) -> (
	value: Value,
	ok: bool,
	is_nav_method: bool,
) {
	switch method {
	case "path", "reachable", "los":
		// The two-Vec2 endpoint queries: the call node is `field(from, to)` —
		// receiver-method field plus two argument children, three children total.
		graph := nav_of_handle(interp, handle)
		if graph == nil || len(node.children) != 3 {
			return nil, false, true
		}
		from_val, from_ok := eval(interp, &node.children[1], env)
		if !from_ok {
			return nil, false, true
		}
		to_val, to_ok := eval(interp, &node.children[2], env)
		if !to_ok {
			return nil, false, true
		}
		from_vec, from_is_vec := from_val.(Vec2)
		to_vec, to_is_vec := to_val.(Vec2)
		if !from_is_vec || !to_is_vec {
			return nil, false, true
		}
		// The graph's 1:1 committed layer: when present, path/reachable answer over
		// the LIVE graph derived from its current tile state (so a SetTile wall-fall
		// routes through the new gap from the next tick — ADR
		// 2026-06-12-engine-path-reads-live-tilemap-no-materialized-nav); the layer
		// also supplies the §12 §2 containing-cell resolution geometry. los reads
		// the layer's OCCUPANCY for the supercover verdict. No committed layer
		// (layerless fixtures, nav-only artifacts) falls back to the baked graph.
		layer := nav_layer_of_graph(interp, graph)
		query_graph := graph
		derived: Nav_Graph
		if layer != nil {
			derived = derive_nav_graph_from_layer(layer, context.temp_allocator)
			query_graph = &derived
		}
		switch method {
		case "path":
			return nav_path_result(interp, query_graph, layer, from_vec, to_vec), true, true
		case "reachable":
			return nav_reachable(query_graph, layer, from_vec, to_vec), true, true
		case "los":
			// The §12 §3 occupancy query: los never reads the graph (centers +
			// adjacency are connectivity, not visibility) — it answers over the
			// live committed tile state of the 1:1 layer (ADR
			// 2026-06-11-engine-los-reads-live-tilemap-occupancy). No committed
			// layer (nil version, or a graph naming no layer) fails closed —
			// never a guessed true into a line-of-fire gate.
			if layer == nil {
				return nil, false, true
			}
			return tilemap_segment_clear(layer, from_vec, to_vec), true, true
		}
	case "nearest":
		// nearest(point): the call node is `field(point)` — receiver-method field
		// plus one argument child, two children total.
		graph := nav_of_handle(interp, handle)
		if graph == nil || len(node.children) != 2 {
			return nil, false, true
		}
		point_val, point_ok := eval(interp, &node.children[1], env)
		if !point_ok {
			return nil, false, true
		}
		point, is_vec := point_val.(Vec2)
		if !is_vec {
			return nil, false, true
		}
		// nearest snaps to the closest LIVE walkable center when the 1:1 layer is
		// committed (a newly-walkable cell's center becomes snappable the next
		// tick); the baked graph is the layerless fallback. Same live-read contract
		// as path/reachable (ADR 2026-06-12).
		layer := nav_layer_of_graph(interp, graph)
		query_graph := graph
		derived: Nav_Graph
		if layer != nil {
			derived = derive_nav_graph_from_layer(layer, context.temp_allocator)
			query_graph = &derived
		}
		return nav_nearest(interp, query_graph, point), true, true
	}
	return nil, false, false
}

// nav_layer_of_graph resolves the committed tile layer a baked graph keys 1:1
// to — the same NAME token and slice position as its [tilemaps] record
// (docs/artifact-format.md §18) — against the interp's version: the tick's
// ENTERING version, the identical read every TilemapHandle query takes
// (tilemap_of_handle), so a SetTile wall is first visible to the NEXT tick's
// los (§18 §4). nil when no version is committed or the layer is absent — the
// caller fails closed.
nav_layer_of_graph :: proc(interp: ^Interp, graph: ^Nav_Graph) -> ^Tile_Layer {
	return version_tilemap(interp.version, graph.name)
}

// nav_reachable answers §12 reachable(from, to) over a loaded graph: whether a
// route exists at all, without materializing waypoints. Endpoints take the §12
// §2 containing-cell resolution (nav_resolve_node) — an off-nav endpoint is NOT
// an error here (reachable returns a Bool, not a Result), so it reads false.
// With both endpoints valid, the answer reuses nav_path and discards the route:
// the BFS-reachability bool alone. Pure over (graph, layer geometry, from, to)
// — bit-stable.
nav_reachable :: proc(graph: ^Nav_Graph, layer: ^Tile_Layer, from, to: Vec2) -> bool {
	from_node := nav_resolve_node(graph, layer, from)
	to_node := nav_resolve_node(graph, layer, to)
	if from_node == NAV_NO_NODE || to_node == NAV_NO_NODE {
		return false
	}
	_, ok := nav_path(graph, from_node, to_node, context.temp_allocator)
	return ok
}

// nav_nearest answers §12 nearest(point) over a loaded graph: the closest
// walkable cell CENTER to an arbitrary point, or None for an empty graph. The
// scan is ascending node order with a strict `<` on the squared distance
// (vec2_dot of the difference — NO sqrt, so it is exact-integer and deterministic;
// the monotone sqrt preserves the argmin, so the squared metric ranks identically
// to true distance). Strict `<` means the LOWEST node index wins a tie — the §12
// stable tie-break. Empty graph → Option::None.
nav_nearest :: proc(interp: ^Interp, graph: ^Nav_Graph, point: Vec2) -> Value {
	if len(graph.centers) == 0 {
		return none_value()
	}
	best_index := 0
	best_dist := vec2_dot(vec2_sub(graph.centers[0], point), vec2_sub(graph.centers[0], point))
	for i in 1 ..< len(graph.centers) {
		diff := vec2_sub(graph.centers[i], point)
		dist := vec2_dot(diff, diff)
		if dist < best_dist {
			best_dist = dist
			best_index = i
		}
	}
	return some_value(interp, graph.centers[best_index])
}

// --- the §12 FIXTURE nav surface (Nav.of / Nav.fail + the fixture queries) --
//
// The fixture is a SEPARATE machine from the engine path above: Nav.of/Nav.fail
// build a Nav_Value (the value arm), and eval_nav_fixture_method answers the five
// queries over it with the @doc-pinned stand-in semantics — NO graph, NO search.
// The runtime mirrors funpack's evaluate.odin eval_nav_method / eval_path_advance
// BEHAVIOR exactly (a different machine, one §12 contract), never linked code.

// eval_nav_constructor lowers the §12 fixture nav builders reached as type-name
// static methods: `Nav.of(route)` builds a non-failed Nav_Value carrying the
// supplied Path route the five queries replay (path → Ok(route), los/reachable →
// true, nearest → identity Some(p)); `Nav.fail(err)` builds the coherent-failure
// twin from a NavError variant (path → Err(err), los/reachable → false, nearest →
// None). is_ctor is false for any other (type, member) so a non-nav-constructor
// `Type.method()` falls through to the value-receiver dispatch.
//
// Nav.of guards its arg to a `Path` Record_Value and Nav.fail guards its arg to a
// `NavError` Variant_Value — a wrong-arm arg fails closed (is_ctor=false; the
// typecheck admits only the right type, so a passing program never hits it). The
// dispatch is by Value arm at the query site, so the fixture NEVER carries an
// engine-vs-fixture flag — the Nav_Value arm IS the fixture identity.
eval_nav_constructor :: proc(
	interp: ^Interp,
	type_name, member: string,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	is_ctor: bool,
) {
	if type_name != "Nav" {
		return nil, false
	}
	// Nav.of(route) / Nav.fail(err): the call node is `field(arg)` — receiver-method
	// field plus one argument child, two children total.
	if len(node.children) != 2 {
		return nil, false
	}
	switch member {
	case "of":
		arg, arg_ok := eval(interp, &node.children[1], env)
		if !arg_ok {
			return nil, false
		}
		route, is_path := arg.(Record_Value)
		if !is_path || route.type_name != "Path" {
			return nil, false
		}
		return Nav_Value{route = route}, true
	case "fail":
		arg, arg_ok := eval(interp, &node.children[1], env)
		if !arg_ok {
			return nil, false
		}
		err, is_variant := arg.(Variant_Value)
		if !is_variant || err.enum_type != "NavError" {
			return nil, false
		}
		return Nav_Value{failed = true, err = err.case_name}, true
	}
	return nil, false
}

// eval_nav_fixture_method answers a §12 query on a Nav.of/Nav.fail FIXTURE value
// (the Nav_Value arm), mirroring funpack's eval_nav_method behavior:
//   - path(from, to)      → Result::Ok(route) replaying the supplied route — or,
//                           on the Nav.fail twin, Result::Err(NavError::err).
//                           The endpoints are IGNORED (the fixture replays its
//                           pinned route, a deterministic stand-in).
//   - los/reachable(f, t) → !failed (true on Nav.of, false on Nav.fail).
//   - nearest(point)      → IDENTITY Some(point) on Nav.of (the fixture snap is
//                           the identity — an off-nav point maps to itself), None
//                           on Nav.fail.
// advance is NOT a Nav method here — it is a Path-record method (eval_path_advance,
// dispatched on the Path receiver in eval_method_call). A wrong arity fails closed
// (ok=false), so a typecheck-rejected form never reaches a passing program.
eval_nav_fixture_method :: proc(
	interp: ^Interp,
	nav: Nav_Value,
	method: string,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	ok: bool,
) {
	switch method {
	case "path":
		// path(from, to): three children (field + two args). Endpoints ignored.
		if len(node.children) != 3 {
			return nil, false
		}
		if nav.failed {
			return nav_err_value(interp, nav.err), true
		}
		return nav_ok_value(interp, nav.route), true
	case "los", "reachable":
		// The cheap yes/no checks: three children. true on Nav.of, false on Nav.fail.
		if len(node.children) != 3 {
			return nil, false
		}
		return !nav.failed, true
	case "nearest":
		// nearest(point): two children (field + one arg). Identity Some(point) on
		// Nav.of, None on Nav.fail.
		if len(node.children) != 2 {
			return nil, false
		}
		if nav.failed {
			return none_value(), true
		}
		point, point_ok := eval(interp, &node.children[1], env)
		if !point_ok {
			return nil, false
		}
		return some_value(interp, point), true
	}
	return nil, false
}

// eval_path_advance lowers §12 Path.advance(pos, arrive) on a Path RECORD value —
// the path-follower fold (spec engine.nav `fn advance(self: Path, …)`), mirroring
// funpack's eval_path_advance. It reads the route's `steps: [Vec2]` and consumes
// the LEADING waypoints already within `arrive` of `pos` (the follower has reached
// them), then the first remaining step is the next waypoint (Option::Some) and the
// rest is the remaining Path; an exhausted route yields (Option::None, the empty
// route) — the arrival signal a chase folds to a hide. Returns the
// (Option[Vec2], Path) pair as a Tuple_Value, destructured by a follow/run_for
// match. ok is false on a wrong arity or a malformed Path/arg.
//
// The arrival comparison is the kernel `vec2_length(vec2_sub(wp, pos)) <= arrive`
// — raw Q32.32 bits through the same kernel ops a baked-graph follow runs, NEVER a
// float tolerance (the determinism floor: same bits on every replay).
eval_path_advance :: proc(
	interp: ^Interp,
	node: ^Node,
	env: ^Env,
	route: Record_Value,
) -> (
	value: Value,
	ok: bool,
) {
	// advance(self, pos, arrive): the call node is `field(pos, arrive)` —
	// receiver-method field plus two argument children, three children total.
	if len(node.children) != 3 {
		return nil, false
	}
	pos_val, pos_ok := eval(interp, &node.children[1], env)
	if !pos_ok {
		return nil, false
	}
	pos, pos_is_vec := pos_val.(Vec2)
	if !pos_is_vec {
		return nil, false
	}
	arrive_val, arrive_ok := eval(interp, &node.children[2], env)
	if !arrive_ok {
		return nil, false
	}
	arrive, arrive_is_fixed := arrive_val.(Fixed)
	if !arrive_is_fixed {
		return nil, false
	}
	steps_field, has_steps := route.fields["steps"]
	if !has_steps {
		return nil, false
	}
	steps, steps_is_list := steps_field.(List_Value)
	if !steps_is_list {
		return nil, false
	}
	// Drop the leading waypoints the follower has already reached (within the
	// arrival radius of pos), so the next waypoint is the first one still ahead.
	next := 0
	for next < len(steps.elements) {
		wp, wp_is_vec := steps.elements[next].(Vec2)
		if !wp_is_vec {
			return nil, false
		}
		if vec2_length(vec2_sub(wp, pos)) <= arrive {
			next += 1
			continue
		}
		break
	}
	remaining := nav_path_record(interp, steps.elements[next:], route)
	if next >= len(steps.elements) {
		// The route is exhausted — every waypoint reached. None signals arrival.
		return nav_tuple2(interp, none_value(), remaining), true
	}
	return nav_tuple2(interp, some_value(interp, steps.elements[next]), remaining), true
}

// nav_path_record rebuilds a Path record value carrying the given remaining steps
// and the source route's cost verbatim — the trimmed route advance threads
// forward (the cost is the whole route's cost; a follower reads waypoints, never
// the residual). The steps slice is made on interp.allocator (NOT a stack
// compound literal — annotation #11) so the rebuilt record outlives the call.
nav_path_record :: proc(interp: ^Interp, steps: []Value, source: Record_Value) -> Record_Value {
	fields := make(map[string]Value, interp.allocator)
	owned := make([]Value, len(steps), interp.allocator)
	copy(owned, steps)
	fields["steps"] = List_Value{elements = owned}
	if cost, has_cost := source.fields["cost"]; has_cost {
		fields["cost"] = cost
	}
	return Record_Value{type_name = "Path", fields = fields}
}

// nav_tuple2 boxes a two-value pair as a Tuple_Value — the (Option[Vec2], Path)
// pair Path.advance returns, destructured by a follow/run_for tuple match. The
// elements slice is made on interp.allocator (NOT a stack compound literal —
// annotation #11) so the tuple outlives the call.
nav_tuple2 :: proc(interp: ^Interp, a, b: Value) -> Value {
	elements := make([]Value, 2, interp.allocator)
	elements[0] = a
	elements[1] = b
	return Tuple_Value{elements = elements}
}

// nav_path_result runs path() over a resolved graph and boxes the
// Result[Path, NavError]: OffNav for an endpoint resolving to no walkable node
// (§12 §2 containing-cell resolution — checked first), Unreachable when both
// endpoints are valid but BFS exhausts the reachable component without reaching
// `to`, else Ok(Path) with the route's cell centers as `steps` and the per-edge
// distance sum as `cost`. A route from an off-center endpoint starts at its
// containing cell's center — steps are always centers (§12 §5).
nav_path_result :: proc(interp: ^Interp, graph: ^Nav_Graph, layer: ^Tile_Layer, from, to: Vec2) -> Value {
	from_node := nav_resolve_node(graph, layer, from)
	to_node := nav_resolve_node(graph, layer, to)
	if from_node == NAV_NO_NODE || to_node == NAV_NO_NODE {
		return nav_err_value(interp, "OffNav")
	}
	route, found := nav_path(graph, from_node, to_node, interp.allocator)
	if !found {
		return nav_err_value(interp, "Unreachable")
	}
	steps := make([]Value, len(route), interp.allocator)
	for n, i in route {
		steps[i] = graph.centers[n]
	}
	cost := nav_route_cost(graph, route)
	fields := make(map[string]Value, interp.allocator)
	fields["steps"] = List_Value{elements = steps}
	fields["cost"] = cost
	path := Record_Value{type_name = "Path", fields = fields}
	return nav_ok_value(interp, path)
}

// nav_ok_value boxes a Path as Result::Ok(path) — the success arm of path()
// (the some_value mold: payload arena-allocated so the variant outlives the call).
nav_ok_value :: proc(interp: ^Interp, path: Record_Value) -> Value {
	boxed := new(Value, interp.allocator)
	boxed^ = path
	return Variant_Value{enum_type = "Result", case_name = "Ok", payload = boxed}
}

// nav_err_value boxes a NavError as Result::Err(NavError::CASE) — the failure
// arm of path(). `case_name` is "Unreachable" or "OffNav" (the §12 enum
// NavError); the NavError is itself a unit Variant (no payload), boxed under the
// Result Err.
nav_err_value :: proc(interp: ^Interp, case_name: string) -> Value {
	err := new(Value, interp.allocator)
	err^ = Variant_Value{enum_type = "NavError", case_name = case_name}
	return Variant_Value{enum_type = "Result", case_name = "Err", payload = err}
}

// nav_marker returns the value a behavior's `nav: Nav` param binds to — the
// receiver `nav.path(...)` dispatches on. A `NavHandle` record with NO `name`
// field is the §12 DEFAULT (the one resource, no name): nav_of_handle resolves
// it to the single baked layer. A named layer (the §12 escape hatch) would carry
// a `name` String, but the default param binds the unnamed marker (the
// input_marker mold — the value only marks the receiver, the graph is read at
// the call). The marker widens no Value arm: it is a Record_Value.
nav_marker :: proc(interp: ^Interp) -> Value {
	fields := make(map[string]Value, interp.allocator)
	return Record_Value{type_name = "NavHandle", fields = fields}
}

// nav_of_handle resolves a NavHandle record receiver to its decoded graph
// (program_nav — the bake-static decode, no version table). A handle carrying a
// `name` String keys that layer by name (the §12 escape hatch); a handle with NO
// name field is the §12 DEFAULT and resolves to the single baked layer (the lone
// nav graph, no name to address). nil when a named layer is unknown, when the
// default is taken but the program carries no nav graph, or when more than one
// graph exists with no name to disambiguate — the caller fails closed.
nav_of_handle :: proc(interp: ^Interp, handle: Record_Value) -> ^Nav_Graph {
	name, has_name := nav_handle_name(handle)
	if has_name {
		return program_nav(interp.program, name)
	}
	// The default: the one baked layer (§12 — the default is the one resource,
	// no name). Exactly one graph resolves; zero or many fails closed.
	if len(interp.program.navs) != 1 {
		return nil
	}
	return &interp.program.navs[0]
}

// nav_handle_name reads the `name` String field off a `NavHandle{name}` record
// value (the tilemap_handle_name mold). ok=false on a missing or non-String
// field — a malformed handle fails closed, never a guessed graph.
nav_handle_name :: proc(handle: Record_Value) -> (name: string, ok: bool) {
	field, present := handle.fields["name"]
	if !present {
		return "", false
	}
	text, is_string := field.(String_Value)
	if !is_string {
		return "", false
	}
	return text.text, true
}

// --- the §12 [nav] loader (schema v13) -------------------------------------

// load_navs reads each §12 nav record into a Nav_Graph: the lead line `nav NAME
// NODE_COUNT EDGE_COUNT` (NO grid metadata — §12 §5 forbids leaking the raw Cell
// index, so no cols/rows/cell_size), then exactly NODE_COUNT `navnode FIXED_X
// FIXED_Y` sub-records (each a walkable cell's world-space CENTER as two raw
// Q32.32 Fixed, in row-major order so line position IS the node index), then
// exactly EDGE_COUNT `navedge A B` sub-records (two decimal node indices, the
// 4-neighbor orthogonal adjacencies). Each undirected edge appends B to adj[A]
// and A to adj[B]; every adj[i] is then SORTED ASCENDING so the BFS tie-break is
// bit-stable regardless of edge emission order.
//
// Every shape violation is the fail-closed .Bad_Field refusal the section molds
// share: a lead line that is not exactly four tokens, a sub-record run that does
// not split into NODE_COUNT + EDGE_COUNT, a malformed navnode/navedge line, or a
// navedge index outside [0, NODE_COUNT) — never a best-effort partial graph. An
// empty `[nav 0]` (a level-less artifact) yields an empty navs slice with no
// special case.
load_navs :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	navs: []Nav_Graph,
	err: Artifact_Error,
) {
	out := make([]Nav_Graph, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		// nav NAME NODE_COUNT EDGE_COUNT
		if len(f) != 4 || f[0] != "nav" {
			return nil, .Bad_Field
		}
		node_count, n_ok := strconv.parse_int(f[2])
		edge_count, e_ok := strconv.parse_int(f[3])
		if !n_ok || !e_ok || node_count < 0 || edge_count < 0 {
			return nil, .Bad_Field
		}
		// The sub-record run splits exactly: NODE_COUNT navnode lines, then
		// EDGE_COUNT navedge lines — an under- or over-shaped record is refused.
		if len(rec.subs) != node_count + edge_count {
			return nil, .Bad_Field
		}
		centers := load_nav_nodes(rec.subs[:node_count], allocator) or_return
		adj := load_nav_edges(rec.subs[node_count:], node_count, allocator) or_return
		out[i] = Nav_Graph {
			name    = strings.clone(f[1], allocator),
			centers = centers,
			adj     = adj,
		}
	}
	return out, .None
}

// load_nav_nodes reads a run of `navnode FIXED_X FIXED_Y` sub-records (§12) into
// the node-index-ordered center slice: each line is exactly three tokens, the
// two coordinates raw Q32.32 Fixed bits (decode_fixed — no float in the load
// path). Line position IS the node index, so the slice order is the topology.
load_nav_nodes :: proc(
	subs: []string,
	allocator := context.allocator,
) -> (
	centers: []Vec2,
	err: Artifact_Error,
) {
	out := make([]Vec2, len(subs), allocator)
	for sub, i in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) != 3 || sf[0] != "navnode" {
			return nil, .Bad_Field
		}
		x, x_ok := decode_fixed(sf[1])
		y, y_ok := decode_fixed(sf[2])
		if !x_ok || !y_ok {
			return nil, .Bad_Field
		}
		out[i] = Vec2{x = x, y = y}
	}
	return out, .None
}

// load_nav_edges reads a run of `navedge A B` sub-records (§12) into the
// per-node adjacency lists: each line is exactly three tokens, A and B decimal
// node indices in [0, node_count). Each undirected edge appends B to adj[A] and
// A to adj[B]; every adj[i] is then sorted ascending so the BFS frontier walks
// neighbors in stable index order (the determinism tie-break). An index outside
// the node range refuses — the search indexes adj unconditionally, so the gate
// lives here, once.
load_nav_edges :: proc(
	subs: []string,
	node_count: int,
	allocator := context.allocator,
) -> (
	adj: [][]int,
	err: Artifact_Error,
) {
	// Build mutable per-node neighbor lists, then freeze each into an owned slice.
	lists := make([][dynamic]int, node_count, context.temp_allocator)
	for &list in lists {
		list = make([dynamic]int, context.temp_allocator)
	}
	for sub in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) != 3 || sf[0] != "navedge" {
			return nil, .Bad_Field
		}
		a, a_ok := strconv.parse_int(sf[1])
		b, b_ok := strconv.parse_int(sf[2])
		if !a_ok || !b_ok || a < 0 || a >= node_count || b < 0 || b >= node_count {
			return nil, .Bad_Field
		}
		append(&lists[a], b)
		append(&lists[b], a)
	}
	out := make([][]int, node_count, allocator)
	for &list, i in lists {
		nav_sort_ascending(list[:])
		neighbors := make([]int, len(list), allocator)
		copy(neighbors, list[:])
		out[i] = neighbors
	}
	return out, .None
}

// nav_sort_ascending sorts a small adjacency list in place by insertion sort —
// the neighbor lists are tiny (≤4 for a 4-neighbor grid graph) and a determinism
// path wants a fixed, dependency-free comparison order, so the simplest
// in-place sort is the right one (no map, no allocation, bit-stable).
nav_sort_ascending :: proc(xs: []int) {
	for i in 1 ..< len(xs) {
		key := xs[i]
		j := i - 1
		for j >= 0 && xs[j] > key {
			xs[j + 1] = xs[j]
			j -= 1
		}
		xs[j + 1] = key
	}
}
