package funpack_runtime

import "core:strconv"
import "core:strings"

NAV_NO_NODE :: -1

Nav_Graph :: struct {
	name:    string,
	centers: []Vec2,
	adj:     [][]int,
}

program_nav :: proc(program: ^Program, name: string) -> ^Nav_Graph {
	for &graph in program.navs {
		if graph.name == name {
			return &graph
		}
	}
	return nil
}

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

derive_nav_graph_from_layer :: proc(
	layer: ^Tile_Layer,
	allocator := context.allocator,
) -> Nav_Graph {
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
	adj := freeze_adjacency(lists, allocator)
	return Nav_Graph{name = layer.name, centers = centers, adj = adj}
}

nav_node_of :: proc(graph: ^Nav_Graph, point: Vec2) -> int {
	for center, i in graph.centers {
		if center == point {
			return i
		}
	}
	return NAV_NO_NODE
}

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

nav_path :: proc(
	graph: ^Nav_Graph,
	from, to: int,
	allocator := context.allocator,
) -> (
	route: []int,
	ok: bool,
) {
	count := len(graph.centers)
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

nav_route_cost :: proc(graph: ^Nav_Graph, route: []int) -> Fixed {
	cost := Fixed(0)
	for i in 1 ..< len(route) {
		segment := vec2_sub(graph.centers[route[i]], graph.centers[route[i - 1]])
		cost = fixed_add(cost, vec2_length(segment))
	}
	return cost
}

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
			if layer == nil {
				return nil, false, true
			}
			return tilemap_segment_clear(layer, from_vec, to_vec), true, true
		}
	case "nearest":
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

nav_layer_of_graph :: proc(interp: ^Interp, graph: ^Nav_Graph) -> ^Tile_Layer {
	return version_tilemap(interp.version, graph.name)
}

nav_reachable :: proc(graph: ^Nav_Graph, layer: ^Tile_Layer, from, to: Vec2) -> bool {
	from_node := nav_resolve_node(graph, layer, from)
	to_node := nav_resolve_node(graph, layer, to)
	if from_node == NAV_NO_NODE || to_node == NAV_NO_NODE {
		return false
	}
	_, ok := nav_path(graph, from_node, to_node, context.temp_allocator)
	return ok
}

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
		if len(node.children) != 3 {
			return nil, false
		}
		if nav.failed {
			return nav_err_value(interp, nav.err), true
		}
		return nav_ok_value(interp, nav.route), true
	case "los", "reachable":
		if len(node.children) != 3 {
			return nil, false
		}
		return !nav.failed, true
	case "nearest":
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

eval_path_advance :: proc(
	interp: ^Interp,
	node: ^Node,
	env: ^Env,
	route: Record_Value,
) -> (
	value: Value,
	ok: bool,
) {
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
		return nav_tuple2(interp, none_value(), remaining), true
	}
	return nav_tuple2(interp, some_value(interp, steps.elements[next]), remaining), true
}

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

nav_tuple2 :: proc(interp: ^Interp, a, b: Value) -> Value {
	elements := make([]Value, 2, interp.allocator)
	elements[0] = a
	elements[1] = b
	return Tuple_Value{elements = elements}
}

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

nav_ok_value :: proc(interp: ^Interp, path: Record_Value) -> Value {
	boxed := new(Value, interp.allocator)
	boxed^ = path
	return Variant_Value{enum_type = "Result", case_name = "Ok", payload = boxed}
}

nav_err_value :: proc(interp: ^Interp, case_name: string) -> Value {
	err := new(Value, interp.allocator)
	err^ = Variant_Value{enum_type = "NavError", case_name = case_name}
	return Variant_Value{enum_type = "Result", case_name = "Err", payload = err}
}

nav_marker :: proc(interp: ^Interp) -> Value {
	fields := make(map[string]Value, interp.allocator)
	return Record_Value{type_name = "NavHandle", fields = fields}
}

nav_of_handle :: proc(interp: ^Interp, handle: Record_Value) -> ^Nav_Graph {
	name, has_name := nav_handle_name(handle)
	if has_name {
		return program_nav(interp.program, name)
	}
	if len(interp.program.navs) != 1 {
		return nil
	}
	return &interp.program.navs[0]
}

nav_handle_name :: proc(handle: Record_Value) -> (name: string, ok: bool) {
	return record_name_field(handle, "name")
}

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
		if len(f) != 4 || f[0] != "nav" {
			return nil, .Bad_Field
		}
		node_count, n_ok := strconv.parse_int(f[2])
		edge_count, e_ok := strconv.parse_int(f[3])
		if !n_ok || !e_ok || node_count < 0 || edge_count < 0 {
			return nil, .Bad_Field
		}
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

load_nav_edges :: proc(
	subs: []string,
	node_count: int,
	allocator := context.allocator,
) -> (
	adj: [][]int,
	err: Artifact_Error,
) {
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
	return freeze_adjacency(lists, allocator), .None
}

freeze_adjacency :: proc(lists: [][dynamic]int, allocator := context.allocator) -> [][]int {
	adj := make([][]int, len(lists), allocator)
	for &list, i in lists {
		nav_sort_ascending(list[:])
		neighbors := make([]int, len(list), allocator)
		copy(neighbors, list[:])
		adj[i] = neighbors
	}
	return adj
}

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
