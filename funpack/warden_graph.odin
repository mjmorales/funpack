// The `funpack warden graph` projection (spec §29 §1): the call/dependency
// graph projected from the decoded index's Decl_Record relation fields —
// calls (callee names), emits/consumes (§04 signal routes), mut_data (§08
// blackboard writes). graph does NOT re-emit decl records; its output is
// warden's OWN per-command shape — one NDJSON EDGE line per relation,
// {from, kind, to} — so this is not an Index Contract reshape and
// INDEX_SCHEMA_VERSION is untouched.
//
// Determinism (§29 §1): edges emit in the decl stream's pinned order, and
// within one record in field order — calls, then emits, then consumes, then
// mut_data — preserving each list's recorded order. The projection is a pure
// function of the decoded index (no clock, no write, no map iteration, no
// re-sort), so two runs over the same index are byte-identical.
//
// Edge targets are names as recorded: a calls target may be a stdlib or
// cross-module name with no decl record in the stream — it is emitted
// verbatim, never resolved (warden answers over the contract, never the AST,
// §29 §2).
package funpack

import "core:encoding/json"
import "core:strings"

// Warden_Edge_Kind is the CLOSED relation taxonomy of the graph projection —
// exactly one member per Decl_Record relation field: Calls ← calls, Emits ←
// emits, Consumes ← consumes, Mutates ← mut_data. Closed-enum discipline: a
// new edge kind is a deliberate surface change (a new member here plus the
// relation field backing it), never a silently-added string.
Warden_Edge_Kind :: enum {
	Calls,    // a function-call edge (Decl_Record.calls)
	Emits,    // a §04 signal-emission route (Decl_Record.emits)
	Consumes, // a §04 signal-consumption route (Decl_Record.consumes)
	Mutates,  // a §08 blackboard data write (Decl_Record.mut_data)
}

// Warden_Edge is one graph edge: the owning declaration's qualified_name, the
// closed relation kind, and the target name VERBATIM as the index recorded it
// (never symbol-resolved). Field declaration order IS the emitted JSON key
// order (the contract emitters' pure-struct-marshal pattern), so a line reads
// {"from":…,"kind":…,"to":…}.
Warden_Edge :: struct {
	from: string,
	kind: Warden_Edge_Kind,
	to:   string,
}

// project_graph_edges projects the decoded index onto its edge set in the
// pinned emission order: decls in stream order, and per decl the relation
// fields in declaration order (calls, emits, consumes, mut_data), each list
// in recorded order. filter is the optional incident-edge filter: "" keeps
// the whole-project edge set; a name keeps only edges INCIDENT to it — an
// EXACT qualified_name match as from OR to, never a prefix or substring
// match. A filter naming nothing in the graph yields a zero-length edge set,
// which is a valid (empty) projection, never an error.
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

// append_relation_edges appends one relation list's edges in recorded order,
// applying the incident filter per edge (from OR to, exact match). It is the
// single fan-out point of all four relation fields, so the per-edge shape and
// filter semantics cannot drift between kinds.
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

// emit_warden_edge encodes one edge as one NDJSON line: the compact JSON
// object followed by a single LF, marshaled in field-declaration order with
// the kind enum as its name (use_enum_names) — the emit_decl_record
// determinism pattern, so a double emission of the same edge is
// byte-identical.
emit_warden_edge :: proc(edge: Warden_Edge, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(edge, {use_enum_names = true}, context.temp_allocator)
	line := strings.concatenate({string(bytes), "\n"}, allocator)
	return line
}

// warden_graph_output renders the whole graph query as its NDJSON byte
// stream: the projected edges in pinned order, one line each, joined in
// emission order. An empty edge set renders as the empty string — no lines,
// no placeholder — so the output is exactly the edge set and nothing else.
// This is graph's arm of the single renderer (warden_command_output): every
// reachable outcome — an empty edge set, a filter matching nothing — is the
// success tier (§29 §1: an empty projection is an answer, not a refusal).
warden_graph_output :: proc(index: Warden_Index, filter: string, allocator := context.allocator) -> string {
	edges := project_graph_edges(index, filter, context.temp_allocator)
	lines := make([dynamic]string, 0, len(edges), context.temp_allocator)
	for edge in edges {
		append(&lines, emit_warden_edge(edge, context.temp_allocator))
	}
	return strings.concatenate(lines[:], allocator)
}
