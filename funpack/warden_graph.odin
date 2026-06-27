package funpack

import "core:encoding/json"
import "core:strings"

Warden_Edge_Kind :: enum {
	Calls,
	Emits,
	Consumes,
	Mutates,
}

Warden_Edge :: struct {
	from: string,
	kind: Warden_Edge_Kind,
	to:   string,
}

project_graph_edges :: proc(index: Warden_Index, filter: string, allocator := context.allocator) -> []Warden_Edge {
	edges := make([dynamic]Warden_Edge, allocator)
	for decl in index.decls {
		append_relation_edges(&edges, decl.qualified_name, .Calls, decl.calls, filter)
		append_relation_edges(&edges, decl.qualified_name, .Emits, decl.emits, filter)
		append_relation_edges(&edges, decl.qualified_name, .Consumes, decl.consumes, filter)
		append_relation_edges(&edges, decl.qualified_name, .Mutates, decl.mut_data, filter)
	}
	return edges[:]
}

append_relation_edges :: proc(
	edges: ^[dynamic]Warden_Edge,
	from: string,
	kind: Warden_Edge_Kind,
	targets: []string,
	filter: string,
) {
	for to in targets {
		if filter != "" && from != filter && to != filter {
			continue
		}
		append(edges, Warden_Edge{from = from, kind = kind, to = to})
	}
}

emit_warden_edge :: proc(edge: Warden_Edge, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(edge, {use_enum_names = true}, context.temp_allocator)
	line := strings.concatenate({string(bytes), "\n"}, allocator)
	return line
}

warden_graph_output :: proc(index: Warden_Index, filter: string, allocator := context.allocator) -> string {
	edges := project_graph_edges(index, filter, context.temp_allocator)
	lines := make([dynamic]string, 0, len(edges), context.temp_allocator)
	for edge in edges {
		append(&lines, emit_warden_edge(edge, context.temp_allocator))
	}
	return strings.concatenate(lines[:], allocator)
}
