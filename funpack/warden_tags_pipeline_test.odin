package funpack

import "core:log"
import "core:testing"

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

@(test)
test_warden_tags_empty_registry :: proc(t: ^testing.T) {
	index := Warden_Index {
		decls = {{qualified_name = "pong.score"}},
	}
	testing.expect_value(t, warden_tags_ndjson(index, context.temp_allocator), "")
}

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

@(test)
test_warden_pipeline_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, warden_pipeline_ndjson(Warden_Index{}, context.temp_allocator), "")
}
