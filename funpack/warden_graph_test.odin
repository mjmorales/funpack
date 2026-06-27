package funpack

import "core:log"
import "core:strings"
import "core:testing"

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

	board := warden_graph_output(index, "Board", context.temp_allocator)
	testing.expect_value(t, board, `{"from":"drift.damped","kind":"Mutates","to":"Board"}` + "\n")
	log.infof("warden graph: the incident filter keeps from- and to-matches in pinned order")
}

@(test)
test_warden_graph_filter_exact_match :: proc(t: ^testing.T) {
	decls := []Decl_Record{
		graph_decl_fixture("drift.damped", {"clamp"}, {}, {}, {}),
	}
	index := Warden_Index{decls = decls}

	got := warden_graph_output(index, "drift.damp", context.temp_allocator)
	testing.expect_value(t, got, "")
}

@(test)
test_warden_graph_empty_projection :: proc(t: ^testing.T) {
	no_decls := Warden_Index{}
	testing.expect_value(t, warden_graph_output(no_decls, "", context.temp_allocator), "")

	decls := []Decl_Record{
		graph_decl_fixture("Board", {}, {}, {}, {}),
	}
	bare := Warden_Index{decls = decls}
	testing.expect_value(t, warden_graph_output(bare, "", context.temp_allocator), "")
}

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
