// Deliberate spec for the headless-record dispatch family (mcp_tools_record.odin) — the
// server-native `record` tool that folds an agent-supplied input-script into a replay log.
// It pins: (1) the claim boundary (owns group "record", declines every other group), (2) a
// record over a LIVE artifact writes a re-readable log and returns {path, ticks, has_seed,
// seed}, (3) the default out path lands the log beside the artifact, and (4) the arg-
// contract refusals (missing artifact, missing/empty script, ticks < 1, an unresolvable
// action) are in-band Invalid_Input IsError results. The whole family is SDL-free (it loads
// an artifact, serializes snapshots, writes a file — no live runtime), so its contract is
// pinned in the default headless test build.
package main

import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// RECTEST_FIXTURE is a minimal one-behavior SEEDLESS artifact (a Hero whose Fixed `pos`
// advances 1.0/tick — no behavior binds an Rng), inlined so this file stands alone. record
// loads it, records a scripted run over it, and writes a log; the seedless shape means the
// recorded log pins has_seed=false, which the summary assertion checks.
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

// rectest_stage_fixture writes RECTEST_FIXTURE to a uniquely-named temp file (with an
// `.artifact` extension so the default-out stem-swap is exercised) and returns its path.
// ok=false when the temp root cannot be staged (the caller skips, never false-fails). The
// caller defers os.remove on the returned path AND on the `<stem>.replay` it produces.
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

// rectest_dispatch drives one tools/call through the family arm the way mcp_handle_tools_call
// does: look the generated Tool_Spec up by name, build the Mcp_Dispatch, invoke the arm. It
// passes a real (empty) registry the record arm never touches — record is registry-free —
// so the harness exercises the production seam, not a shortcut.
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

// rectest_args parses a JSON object literal into the json.Object the arm reads — arguments
// authored as the wire JSON the MCP boundary delivers. A parse failure is a test-author bug.
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
	// The family owns the server-native `record` tool (group "record") and DECLINES every
	// other group so the chain reaches the owning family — the structural guard against one
	// family shadowing another's tool.
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
	// The arm returns handled=false for a tool it does not own — the chain contract that lets
	// the next family try.
	_, handled := rectest_dispatch("session_start", rectest_args(t, `{"artifact":"x"}`), context.temp_allocator)
	testing.expect(t, !handled, "the record arm declines session_start")
}

@(test)
test_rec_writes_log_and_returns_summary :: proc(t: ^testing.T) {
	// A record over a live artifact writes a re-readable log and returns {path, ticks,
	// has_seed} — the happy path the agent drives before session_start. The script's two
	// segments sum to 7 recorded ticks, the seedless fixture pins has_seed=false, and the
	// written file re-reads to exactly 7 snapshots through the production parser.
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
	// With no `out`, the log lands at <artifact-stem>.replay beside the artifact, and the
	// result carries that path — the discoverable default the agent feeds straight to
	// session_start.
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
	// A record with no artifact is an Invalid_Input IsError (the one always-required arg).
	result, _ := rectest_dispatch("record", rectest_args(t, `{"script":[{"ticks":1}]}`), context.temp_allocator)
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing artifact is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
}

@(test)
test_rec_missing_script_is_invalid_input :: proc(t: ^testing.T) {
	// A record with an artifact but no script is Invalid_Input — the script is the recording.
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
	// A segment with ticks < 1 is Invalid_Input naming the offending segment — a footgun the
	// arm catches before recording an empty/degenerate stretch.
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
	// A segment naming an action the artifact does not declare is Invalid_Input (the shared
	// snapshot builder's "unknown action") — the fixture declares no action enum, so any
	// action token is unresolvable, proving the marshaller surfaces the builder's refusal.
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
