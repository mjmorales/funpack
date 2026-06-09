// The tags/pipeline projection tests: warden_tags_ndjson's registry-ordered
// join (used tag, unused registered tag, multi-decl tag — the registry's
// AUTHORED order is the output order, never a re-sort, and decls lists ride
// decl-stream order) and warden_pipeline_ndjson's positional re-projection of
// the recorded Flat_Step_Record order. Indexes are built as struct literals —
// the projections are pure functions of an already-decoded Warden_Index, so
// no fixture compile or scratch root is needed — and every assertion pins
// exact output BYTES, the determinism the §29 §1 contract promises.
package funpack

import "core:log"
import "core:testing"

// test_warden_tags_registry_ordered_join pins the whole join shape on one
// index: a multi-decl tag collects every carrier in decl-stream order, a
// single-decl tag collects exactly its carrier, and a registered-but-unused
// tag emits an EMPTY decls list — present, never an omitted key. The
// registry is deliberately authored in non-alphabetical order ("render" >
// "game" > "audio" reversed-sorts) so the output order proves authored-order
// fidelity, not an accidental sort.
@(test)
test_warden_tags_registry_ordered_join :: proc(t: ^testing.T) {
	index := Warden_Index {
		project = Project_Record{tag_registry = {"render", "game", "audio"}},
		decls = {
			{qualified_name = "pong.draw_court", gtags = {"render"}},
			{qualified_name = "pong.move_ball", gtags = {"game", "render"}},
			{qualified_name = "pong.score", gtags = {"game"}},
		},
	}
	want :=
		`{"tag":"render","decls":["pong.draw_court","pong.move_ball"]}` + "\n" +
		`{"tag":"game","decls":["pong.move_ball","pong.score"]}` + "\n" +
		`{"tag":"audio","decls":[]}` + "\n"
	testing.expect_value(t, warden_tags_ndjson(index, context.temp_allocator), want)
	log.infof("warden tags: registry-ordered join — multi-decl, single-decl, and dead tags all project")
}

// test_warden_tags_decl_stream_order pins the decls axis: carriers list in
// the index's decl-stream order even when that order reverse-sorts their
// qualified names — the join walks index.decls forward, it never re-orders.
@(test)
test_warden_tags_decl_stream_order :: proc(t: ^testing.T) {
	index := Warden_Index {
		project = Project_Record{tag_registry = {"game"}},
		decls = {
			{qualified_name = "z.last_authored", gtags = {"game"}},
			{qualified_name = "a.first_sorted", gtags = {"game"}},
		},
	}
	want := `{"tag":"game","decls":["z.last_authored","a.first_sorted"]}` + "\n"
	testing.expect_value(t, warden_tags_ndjson(index, context.temp_allocator), want)
}

// test_warden_tags_empty_registry pins the empty success: a project with no
// registered tags projects zero lines — the empty string, not an error and
// not a placeholder line.
@(test)
test_warden_tags_empty_registry :: proc(t: ^testing.T) {
	index := Warden_Index {
		decls = {{qualified_name = "pong.score"}},
	}
	testing.expect_value(t, warden_tags_ndjson(index, context.temp_allocator), "")
}

// test_warden_pipeline_recorded_order pins the re-projection: one line per
// Flat_Step_Record exactly as pipeline_flattened recorded them — the
// positional order is the output order (no flatten re-run, no re-sort), and
// each line carries the ordinal/stage/behavior field shape.
@(test)
test_warden_pipeline_recorded_order :: proc(t: ^testing.T) {
	index := Warden_Index {
		project = Project_Record {
			pipeline_flattened = {
				{ordinal = 0, stage = "update", behavior = "move_ball"},
				{ordinal = 1, stage = "update", behavior = "score"},
				{ordinal = 2, stage = "render", behavior = "draw_court"},
			},
		},
	}
	want :=
		`{"ordinal":0,"stage":"update","behavior":"move_ball"}` + "\n" +
		`{"ordinal":1,"stage":"update","behavior":"score"}` + "\n" +
		`{"ordinal":2,"stage":"render","behavior":"draw_court"}` + "\n"
	testing.expect_value(t, warden_pipeline_ndjson(index, context.temp_allocator), want)
	log.infof("warden pipeline: the recorded ordinal order re-projects positionally, one NDJSON line per step")
}

// test_warden_pipeline_empty pins the package case: no pipeline_flattened
// steps project zero lines — emptiness is success, never a refusal (§29 §3:
// the warden's exit image is {0, 2} and this is the 0 side).
@(test)
test_warden_pipeline_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, warden_pipeline_ndjson(Warden_Index{}, context.temp_allocator), "")
}
