// The `funpack warden graph` projection tests: the closed four-kind edge
// taxonomy each emits its {from, kind, to} line with use_enum_names, the
// pinned emission order (decl-stream order, then field order calls → emits →
// consumes → mut_data, each list in recorded order), the incident-edge filter
// (exact qualified_name match as from OR to — never a prefix), verbatim
// targets (a calls target with no decl record in the stream still emits), the
// empty edge set's success tier, and double-emission byte identity. The index
// inputs are hand-built Warden_Index values — the projection is a pure
// function of the decoded index, so no disk fixture is needed here (the
// planted-root exit tests in warden_test.odin cover acquisition).
package funpack

import "core:log"
import "core:strings"
import "core:testing"

// graph_decl_fixture builds a decl record carrying just what the graph
// projection reads: the qualified name and the four relation lists. The
// non-relation fields stay zero-valued — the projection must not read them,
// so a zero there can never change an edge.
graph_decl_fixture :: proc(name: string, calls: []string, emits: []string, consumes: []string, mut_data: []string) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = name,
		kind           = .Fn,
		span           = 1,
		calls          = calls,
		emits          = emits,
		consumes       = consumes,
		mut_data       = mut_data,
	}
}

// test_warden_graph_all_kinds_pinned_order pins the whole per-record byte
// shape at once: all four edge kinds emit, in field order calls → emits →
// consumes → mut_data, each list in recorded order (calls carries two entries
// to pin the within-list order), every line the compact
// {"from":…,"kind":…,"to":…} object with the kind as its enum NAME
// (use_enum_names) and a single trailing LF. The calls targets are bare
// names with no decl record in the stream — emitted verbatim, never
// resolved.
@(test)
test_warden_graph_all_kinds_pinned_order :: proc(t: ^testing.T) {
	decls := []Decl_Record{
		graph_decl_fixture("drift.damped", {"add", "clamp"}, {"Goal"}, {"Tick"}, {"Board"}),
	}
	index := Warden_Index{decls = decls}

	want := strings.concatenate({
		`{"from":"drift.damped","kind":"Calls","to":"add"}`, "\n",
		`{"from":"drift.damped","kind":"Calls","to":"clamp"}`, "\n",
		`{"from":"drift.damped","kind":"Emits","to":"Goal"}`, "\n",
		`{"from":"drift.damped","kind":"Consumes","to":"Tick"}`, "\n",
		`{"from":"drift.damped","kind":"Mutates","to":"Board"}`, "\n",
	}, context.temp_allocator)
	got := warden_graph_output(index, "", context.temp_allocator)
	testing.expect_value(t, got, want)
	log.infof("warden graph: all four edge kinds emit in the pinned field order with enum names")
}

// test_warden_graph_decl_stream_order pins the outer order: edges emit per
// decl in the STREAM's order — every first-decl edge precedes every
// second-decl edge — with no re-sort across records.
@(test)
test_warden_graph_decl_stream_order :: proc(t: ^testing.T) {
	decls := []Decl_Record{
		graph_decl_fixture("drift.launch_speed", {"drift.damped"}, {"Goal"}, {}, {}),
		graph_decl_fixture("drift.damped", {"clamp"}, {}, {}, {"Board"}),
	}
	index := Warden_Index{decls = decls}

	want := strings.concatenate({
		`{"from":"drift.launch_speed","kind":"Calls","to":"drift.damped"}`, "\n",
		`{"from":"drift.launch_speed","kind":"Emits","to":"Goal"}`, "\n",
		`{"from":"drift.damped","kind":"Calls","to":"clamp"}`, "\n",
		`{"from":"drift.damped","kind":"Mutates","to":"Board"}`, "\n",
	}, context.temp_allocator)
	got := warden_graph_output(index, "", context.temp_allocator)
	testing.expect_value(t, got, want)
}

// test_warden_graph_incident_filter pins the optional positional's
// semantics: a filter keeps exactly the edges incident to the name — as from
// (drift.damped's own calls/mut_data edges) OR as to (the caller's edge INTO
// drift.damped) — and drops everything else (the caller's Emits edge). The
// kept edges stay in the pinned whole-set order.
@(test)
test_warden_graph_incident_filter :: proc(t: ^testing.T) {
	decls := []Decl_Record{
		graph_decl_fixture("drift.damped", {"clamp"}, {}, {}, {"Board"}),
		graph_decl_fixture("drift.launch_speed", {"drift.damped"}, {"Goal"}, {}, {}),
	}
	index := Warden_Index{decls = decls}

	want := strings.concatenate({
		`{"from":"drift.damped","kind":"Calls","to":"clamp"}`, "\n",
		`{"from":"drift.damped","kind":"Mutates","to":"Board"}`, "\n",
		`{"from":"drift.launch_speed","kind":"Calls","to":"drift.damped"}`, "\n",
	}, context.temp_allocator)
	got := warden_graph_output(index, "drift.damped", context.temp_allocator)
	testing.expect_value(t, got, want)

	// to-only incidence: a bare target name keeps just the edge into it.
	board := warden_graph_output(index, "Board", context.temp_allocator)
	testing.expect_value(t, board, `{"from":"drift.damped","kind":"Mutates","to":"Board"}` + "\n")
	log.infof("warden graph: the incident filter keeps from- and to-matches in pinned order")
}

// test_warden_graph_filter_exact_match pins exactness: the filter is a whole
// qualified_name equality, so a strict prefix of a recorded name ("drift.damp"
// against "drift.damped") matches nothing — an empty projection, which is
// still the success tier, never an error.
@(test)
test_warden_graph_filter_exact_match :: proc(t: ^testing.T) {
	decls := []Decl_Record{
		graph_decl_fixture("drift.damped", {"clamp"}, {}, {}, {}),
	}
	index := Warden_Index{decls = decls}

	got := warden_graph_output(index, "drift.damp", context.temp_allocator)
	testing.expect_value(t, got, "")
	testing.expect_value(t, warden_graph_exit(index, "drift.damp"), 0)
}

// test_warden_graph_empty_exit_zero pins the empty-graph success tier both
// ways an edge set can be empty: a stream with no decl records at all, and a
// decl whose every relation list is empty-but-present. Each projects zero
// lines and exits 0 — an empty graph is an answer (§29 §1), not a refusal.
@(test)
test_warden_graph_empty_exit_zero :: proc(t: ^testing.T) {
	no_decls := Warden_Index{}
	testing.expect_value(t, warden_graph_output(no_decls, "", context.temp_allocator), "")
	testing.expect_value(t, warden_graph_exit(no_decls, ""), 0)

	decls := []Decl_Record{
		graph_decl_fixture("Board", {}, {}, {}, {}),
	}
	bare := Warden_Index{decls = decls}
	testing.expect_value(t, warden_graph_output(bare, "", context.temp_allocator), "")
	testing.expect_value(t, warden_graph_exit(bare, ""), 0)
}

// test_warden_graph_double_emit_byte_identical pins the §29 §1 determinism
// floor at the unit level: two projections of the same index — whole-set and
// filtered — are byte-identical, the no-clock/no-map/no-re-sort purity the
// contract emitters established.
@(test)
test_warden_graph_double_emit_byte_identical :: proc(t: ^testing.T) {
	decls := []Decl_Record{
		graph_decl_fixture("drift.damped", {"add", "clamp"}, {"Goal"}, {"Tick"}, {"Board"}),
		graph_decl_fixture("drift.launch_speed", {"drift.damped"}, {}, {"Goal"}, {}),
	}
	index := Warden_Index{decls = decls}

	first := warden_graph_output(index, "", context.temp_allocator)
	second := warden_graph_output(index, "", context.temp_allocator)
	testing.expect_value(t, second, first)

	filtered_first := warden_graph_output(index, "Goal", context.temp_allocator)
	filtered_second := warden_graph_output(index, "Goal", context.temp_allocator)
	testing.expect_value(t, filtered_second, filtered_first)
}
