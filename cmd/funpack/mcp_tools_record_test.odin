package main

import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

RECTEST_FIXTURE :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project introspect\n" +
	"version L5:0.1.0\n" +
	"[data 2]\n" +
	"data Stats 2 false\n" +
	"field hp Int -\n" +
	"field mana Int -\n" +
	"data Coord 1 false\n" +
	"field v Int -\n" +
	"[things 1]\n" +
	"thing Hero false 0 4\n" +
	"field pos Fixed =0\n" +
	"field stats Stats =Stats(hp=10,mana=4)\n" +
	"field home Coord =Coord(v=5)\n" +
	"field score Int =0\n" +
	"[behaviors 1]\n" +
	"behavior advance on:Hero stage:control contract:Update 0 1 1 1\n" +
	"param self Hero\n" +
	"emit Hero\n" +
	"node return 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield pos 1\n" +
	"node binary add 2\n" +
	"node field pos 1\n" +
	"node name self 0\n" +
	"node fixed 4294967296 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:advance\n" +
	"[setup 1]\n" +
	"spawn Hero 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Intro tick_hz:60 logical:160x120 bindings:bindings\n"

@(private = "file")
rectest_stage_fixture :: proc(t: ^testing.T, name: string) -> (path: string, ok: bool) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	path, _ = filepath.join({base, name}, context.temp_allocator)
	if write_err := os.write_entire_file(path, RECTEST_FIXTURE); write_err != nil {
		return "", false
	}
	return path, true
}

@(private = "file")
rectest_dispatch :: proc(name: string, arguments: json.Object, allocator := context.allocator) -> (result: string, handled: bool) {
	registry := mcp_session_registry_make(allocator)
	spec, found := mcp_lookup_tool(name)
	if !found {
		return "", false
	}
	dispatch := Mcp_Dispatch {
		spec      = spec,
		name      = name,
		arguments = arguments,
		id        = Mcp_Id{kind = .Integer, integer = 7},
		registry  = &registry,
	}
	return mcp_record_dispatch(dispatch, allocator)
}

@(private = "file")
rectest_args :: proc(t: ^testing.T, literal: string) -> json.Object {
	parsed, err := json.parse(transmute([]u8)literal, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None, "fixture args must parse: %v", err)
	object, is_object := parsed.(json.Object)
	testing.expect(t, is_object, "fixture args must be a JSON object")
	return object
}

@(test)
test_rec_owns_only_record_group :: proc(t: ^testing.T) {
	spec, found := mcp_lookup_tool("record")
	testing.expect(t, found, "record is in the generated table")
	testing.expect(t, rec_owns_command(spec), "the family claims record")

	declined := []string{"session_start", "build", "inspect_pipeline", "control_set", "docs_search"}
	for name in declined {
		other, ok := mcp_lookup_tool(name)
		testing.expectf(t, ok, "declined tool %s is in the generated table", name)
		testing.expectf(t, !rec_owns_command(other), "the family declines %s (another family owns it)", name)
	}
}

@(test)
test_rec_declines_unowned_tool :: proc(t: ^testing.T) {
	_, handled := rectest_dispatch("session_start", rectest_args(t, `{"artifact":"x"}`), context.temp_allocator)
	testing.expect(t, !handled, "the record arm declines session_start")
}

@(test)
test_rec_writes_log_and_returns_summary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	artifact, ok := rectest_stage_fixture(t, "funpack-rec-write.artifact")
	if !ok {
		return
	}
	defer os.remove(artifact)
	out := strings.concatenate({artifact[:len(artifact) - len(".artifact")], ".replay"})
	defer os.remove(out)

	args := rectest_args(t, strings.concatenate({`{"artifact":"`, artifact, `","script":[{"ticks":4},{"ticks":3}]}`}))
	result, handled := rectest_dispatch("record", args)
	testing.expect(t, handled, "the record arm claims record")
	testing.expect(t, strings.contains(result, `"isError":false`), "a successful record is not a tool error")
	testing.expect(t, strings.contains(result, `\"ticks\":7`), "the result reports 7 recorded ticks")
	testing.expect(t, strings.contains(result, `\"has_seed\":false`), "the seedless fixture records has_seed=false")

	log_bytes, read_err := os.read_entire_file_from_path(out, context.allocator)
	testing.expect(t, read_err == nil, "the log was written beside the artifact")
	log, parse_ok := funpack_runtime.read_replay(string(log_bytes), context.allocator)
	testing.expect(t, parse_ok, "the written log re-reads through the production parser")
	testing.expect_value(t, len(log.snapshots), 7)
}

@(test)
test_rec_default_out_path_beside_artifact :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	artifact, ok := rectest_stage_fixture(t, "funpack-rec-default.artifact")
	if !ok {
		return
	}
	defer os.remove(artifact)
	expected := strings.concatenate({artifact[:len(artifact) - len(".artifact")], ".replay"})
	defer os.remove(expected)

	args := rectest_args(t, strings.concatenate({`{"artifact":"`, artifact, `","script":[{"ticks":1}]}`}))
	result, _ := rectest_dispatch("record", args)
	testing.expect(t, os.exists(expected), "the default log lands at <stem>.replay beside the artifact")
	testing.expect(t, strings.contains(result, expected), "the result reports the default out path")
}

@(test)
test_rec_missing_artifact_is_invalid_input :: proc(t: ^testing.T) {
	result, _ := rectest_dispatch("record", rectest_args(t, `{"script":[{"ticks":1}]}`), context.temp_allocator)
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing artifact is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
}

@(test)
test_rec_missing_script_is_invalid_input :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	artifact, ok := rectest_stage_fixture(t, "funpack-rec-noscript.artifact")
	if !ok {
		return
	}
	defer os.remove(artifact)
	args := rectest_args(t, strings.concatenate({`{"artifact":"`, artifact, `"}`}))
	result, _ := rectest_dispatch("record", args)
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing script is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
}

@(test)
test_rec_bad_ticks_is_invalid_input :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	artifact, ok := rectest_stage_fixture(t, "funpack-rec-badticks.artifact")
	if !ok {
		return
	}
	defer os.remove(artifact)
	args := rectest_args(t, strings.concatenate({`{"artifact":"`, artifact, `","script":[{"ticks":0}]}`}))
	result, _ := rectest_dispatch("record", args)
	testing.expect(t, strings.contains(result, `"isError":true`), "ticks < 1 is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
	testing.expect(t, strings.contains(result, `segment 0`), "the error names the offending segment")
}

@(test)
test_rec_unknown_action_is_invalid_input :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	artifact, ok := rectest_stage_fixture(t, "funpack-rec-badaction.artifact")
	if !ok {
		return
	}
	defer os.remove(artifact)
	args := rectest_args(t, strings.concatenate({`{"artifact":"`, artifact, `","script":[{"ticks":1,"pressed":[{"player":"P1","action":"Move::Up"}]}]}`}))
	result, _ := rectest_dispatch("record", args)
	testing.expect(t, strings.contains(result, `"isError":true`), "an unknown action is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
}
