// Deliberate spec for the observe + time-travel tool dispatch family
// (mcp_tools_observe_time.odin) — the living junction test for a session-scoped MCP
// tool arm. It pins the three contracts the arm sits on: (1) the §28 request line it
// builds from MCP arguments (session_id dropped, every other arg threaded by JSON type,
// empty args elided), (2) the end-to-end dispatch through a LIVE registry + session for
// a representative tool from each shape (no-arg pipeline, position-only time_load /
// time_status, required-arg inspect_trace / inspect_diff, the always-headless
// inspect_draw_list, the optional-`until` time_run), and (3) the §28→MCP lift (ok:true
// lifts the result object verbatim, ok:false maps the runtime refusal to a
// Session-category IsError, an unknown session id is the Session refusal).
//
// DEFINE-FREE FLOOR: these run in the default `odin test .` build (no FUNPACK_LIVE, no
// SDL). Everything the arm folds — open_session_for_artifact, session_request, the
// observe/time re-fold — is SDL-free, so the family's contract is pinned in the same
// deterministic floor the rest of the compiler tests run in.
//
// NAMESPACE DISCIPLINE: every package-level symbol here is prefixed `obs_` (the family's
// prefix) so package main has NO duplicate test/helper symbols when all six dispatch
// families merge. The inlined fixture is self-contained per the self-contained-test
// standard (the runtime + session fixtures are file-private elsewhere).
package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import funpack_runtime "../../runtime"

// OBS_FIXTURE is a minimal one-behavior artifact (a Hero whose Fixed `pos` advances
// 1.0/tick) — the same shape the registry's F13 test uses, inlined here so this file
// stands alone. It gives a session a canonical recorded chain to observe (pipeline /
// trace / draw_list / diff) and a cursor to walk (time_load / status / run), without a
// live runtime — the whole observe+time surface re-folds this recording in-process.
OBS_FIXTURE :: "funpack-artifact 18\n" +
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

// obs_stage_fixture writes OBS_FIXTURE to a uniquely-named temp file and returns its
// path. ok=false (the caller skips, never false-fails) when the temp root cannot be
// staged. The caller defers os.remove on the returned path.
@(private = "file")
obs_stage_fixture :: proc(t: ^testing.T, name: string) -> (path: string, ok: bool) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	path, _ = filepath.join({base, name}, context.temp_allocator)
	if write_err := os.write_entire_file(path, OBS_FIXTURE); write_err != nil {
		return "", false
	}
	return path, true
}

// obs_dispatch_tool is the test harness for one tools/call through the family arm: it
// looks the tool's generated Tool_Spec up by name (the real lookup mcp_handle_tools_call
// uses), builds the Mcp_Dispatch the chain passes, and invokes the arm — returning the
// rendered JSON-RPC result line and whether the arm CLAIMED the tool. It drives the arm
// through exactly the seam the chain does, so the test exercises the production path, not
// a private shortcut.
@(private = "file")
obs_dispatch_tool :: proc(
	registry: ^Mcp_Session_Registry,
	name: string,
	arguments: json.Object,
	allocator := context.allocator,
) -> (
	result: string,
	handled: bool,
) {
	spec, found := mcp_lookup_tool(name)
	if !found {
		return "", false
	}
	dispatch := Mcp_Dispatch {
		spec      = spec,
		name      = name,
		arguments = arguments,
		id        = Mcp_Id{kind = .Integer, integer = 7},
		registry  = registry,
	}
	return mcp_observe_time_dispatch(dispatch, allocator)
}

// obs_args parses a JSON object literal into the json.Object the dispatch arm reads —
// the test authors arguments as wire JSON (the shape the MCP boundary delivers) so the
// integer/string types match exactly what mcp_parse_request produces (parse_integers
// true, mcp_jsonrpc.odin). A parse failure is a test-author bug, surfaced loudly.
@(private = "file")
obs_args :: proc(t: ^testing.T, literal: string) -> json.Object {
	parsed, err := json.parse(transmute([]u8)literal, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None, "fixture args must parse: %v", err)
	object, is_object := parsed.(json.Object)
	testing.expect(t, is_object, "fixture args must be a JSON object")
	return object
}

// test_obs_build_request_line_drops_session_threads_args pins the request-line builder:
// session_id is dropped (it keys the session, not a §28 arg), every other arg is
// threaded by its JSON type (integer tick, string behavior), and a no-arg command emits
// just {id,cmd} with the args object elided. This is the projection contract — the §28
// arg names ARE the MCP arg names, no translation table.
@(test)
test_obs_build_request_line_drops_session_threads_args :: proc(t: ^testing.T) {
	// A no-arg command (pipeline): session_id dropped, no args object at all.
	pipeline_args := obs_args(t, `{"session_id":"sess-1"}`)
	pipeline_line := obs_build_request_line("pipeline", pipeline_args, context.temp_allocator)
	testing.expect_value(t, pipeline_line, `{"id":1,"cmd":"pipeline"}`)

	// A required-arg command (trace): tick threaded as an integer, behavior as a string,
	// session_id dropped. The args object carries exactly the §28 arg names.
	trace_args := obs_args(t, `{"session_id":"sess-1","tick":3,"behavior":"advance"}`)
	trace_line := obs_build_request_line("trace", trace_args, context.temp_allocator)
	testing.expect(t, strings.contains(trace_line, `"cmd":"trace"`), "the cmd is trace")
	testing.expect(t, strings.contains(trace_line, `"tick":3`), "tick threads as an integer, never a float")
	testing.expect(t, strings.contains(trace_line, `"behavior":"advance"`), "behavior threads as a string")
	testing.expect(t, !strings.contains(trace_line, "session_id"), "session_id is dropped — it keys the session, not a §28 arg")

	// The optional branch selector threads verbatim when present (§28 observe addressing).
	branch_args := obs_args(t, `{"session_id":"sess-1","branch":"fork-a"}`)
	branch_line := obs_build_request_line("pipeline", branch_args, context.temp_allocator)
	testing.expect(t, strings.contains(branch_line, `"branch":"fork-a"`), "the optional branch selector threads through")
}

// test_obs_owns_only_inspect_and_time pins the family claim boundary: it owns the
// inspect and time groups, and DECLINES every other group (break/self_heal observe,
// control) so the chain reaches the owning family. A family wrongly claiming another's
// tool would shadow it — this is the structural guard against that.
@(test)
test_obs_owns_only_inspect_and_time :: proc(t: ^testing.T) {
	owned := []string{"inspect_pipeline", "inspect_trace", "inspect_diff", "inspect_draw_list", "time_load", "time_run", "time_status"}
	for name in owned {
		spec, found := mcp_lookup_tool(name)
		testing.expectf(t, found, "owned tool %s is in the generated table", name)
		testing.expectf(t, obs_owns_command(spec), "the family claims %s", name)
	}
	declined := []string{"control_set", "control_spawn", "break", "watch", "capture_test", "audit"}
	for name in declined {
		spec, found := mcp_lookup_tool(name)
		testing.expectf(t, found, "declined tool %s is in the generated table", name)
		testing.expectf(t, !obs_owns_command(spec), "the family declines %s (its OWN family owns it)", name)
	}
}

// test_obs_declines_unowned_tool pins that the arm returns handled=false for a tool it
// does not own — the chain contract that lets the next family try. A control tool flows
// PAST this arm untouched (no result rendered, the result string is ignored).
@(test)
test_obs_declines_unowned_tool :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	_, handled := obs_dispatch_tool(&registry, "control_set", obs_args(t, `{"session_id":"sess-1"}`), context.temp_allocator)
	testing.expect(t, !handled, "the observe+time arm declines a control-group tool (handled=false)")
}

// test_obs_unknown_session_is_session_error pins the stale-session refusal: a claimed
// tool naming an id the registry never minted is a Session-category IsError carrying the
// id — never a fabricated session, never a JSON-RPC error object.
@(test)
test_obs_unknown_session_is_session_error :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := obs_dispatch_tool(&registry, "inspect_pipeline", obs_args(t, `{"session_id":"sess-999"}`), context.temp_allocator)
	testing.expect(t, handled, "the arm claims its tool even for an unknown session")
	testing.expect(t, strings.contains(result, `"isError":true`), "an unknown session is a tool error")
	// The {category,...} envelope is a JSON string INSIDE the text content block, so its
	// quotes are escaped on the MCP wire (\"category\":\"session\").
	testing.expect(t, strings.contains(result, `\"category\":\"session\"`), "the category is session")
	testing.expect(t, strings.contains(result, "sess-999"), "the offending id rides in the detail")
}

// test_obs_missing_session_id_is_invalid_input pins the arg-contract refusal: a claimed
// tool with no session_id is an Invalid_Input IsError (the one universally-required
// arg), distinct from the Session refusal of a wrong id.
@(test)
test_obs_missing_session_id_is_invalid_input :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := obs_dispatch_tool(&registry, "inspect_pipeline", obs_args(t, `{}`), context.temp_allocator)
	testing.expect(t, handled, "the arm claims its tool")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing session_id is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
}

// test_obs_pipeline_round_trip is the end-to-end junction: open a LIVE session, dispatch
// inspect_pipeline, and assert the §28 result rides into the MCP result as a clean (not
// IsError) Text block carrying the flattened pipeline. This is the whole arm — lookup,
// request-line build, session fold, ok:true lift — through the production seam.
@(test)
test_obs_pipeline_round_trip :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-pipeline.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `"}`}, context.temp_allocator))
	result, handled := obs_dispatch_tool(&registry, "inspect_pipeline", args, context.temp_allocator)
	testing.expect(t, handled, "inspect_pipeline is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a clean observe is not a tool error")
	testing.expect(t, strings.contains(result, `\"steps\"`), "the lifted result carries the flattened pipeline steps")
	testing.expect(t, strings.contains(result, `advance`), "the one behavior's step is in the result")
}

// test_obs_time_load_and_status_round_trip pins the position-only and status time
// commands through a live session: load arms the cursor (result {tick}), status reports
// the fixed payload (loaded/ticks_recorded/ring). Both lift ok:true verbatim — the
// time-travel half of the family over the same fold.
@(test)
test_obs_time_load_and_status_round_trip :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-time.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	session_args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `"}`}, context.temp_allocator))

	load_result, load_handled := obs_dispatch_tool(&registry, "time_load", session_args, context.temp_allocator)
	testing.expect(t, load_handled, "time_load is claimed")
	testing.expect(t, strings.contains(load_result, `"isError":false`), "load is a clean position ack")
	testing.expect(t, strings.contains(load_result, `\"tick\"`), "load's result is the cursor tick")

	status_result, status_handled := obs_dispatch_tool(&registry, "time_status", session_args, context.temp_allocator)
	testing.expect(t, status_handled, "time_status is claimed")
	testing.expect(t, strings.contains(status_result, `"isError":false`), "status is a clean read")
	testing.expect(t, strings.contains(status_result, `\"loaded\"`), "the status payload reports the loaded flag")
	testing.expect(t, strings.contains(status_result, `\"ticks_recorded\"`), "the status payload reports the recording extent")
}

// test_obs_run_threads_optional_until pins the optional-arg path: time_run with `until`
// folds forward to that tick and lifts the {tick} result. Omitting `until` is exercised
// by load/status above; this asserts the optional integer threads into the §28 args (the
// generated optional-arg projection — not all args are required).
@(test)
test_obs_run_threads_optional_until :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-run.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	// load first to arm the cursor, then run to an in-range recorded tick.
	load_args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `"}`}, context.temp_allocator))
	_, _ = obs_dispatch_tool(&registry, "time_load", load_args, context.temp_allocator)

	run_args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `","until":5}`}, context.temp_allocator))
	run_result, run_handled := obs_dispatch_tool(&registry, "time_run", run_args, context.temp_allocator)
	testing.expect(t, run_handled, "time_run is claimed")
	testing.expect(t, strings.contains(run_result, `"isError":false`), "run to an in-range tick is clean")
	testing.expect(t, strings.contains(run_result, `\"tick\":5`), "run folds forward to the requested until tick")
}

// test_obs_runtime_refusal_is_session_error pins the §28 ok:false lift: an out-of-range
// tick is a runtime refusal, surfaced as a Session-category IsError carrying the
// runtime's own text (so the model reads "tick out of range" and self-corrects) — NOT an
// Internal fault, NOT a JSON-RPC error object. inspect_trace at an impossible tick is the
// representative refusal.
@(test)
test_obs_runtime_refusal_is_session_error :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-refusal.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `","behavior":"advance","tick":99999}`}, context.temp_allocator))
	result, handled := obs_dispatch_tool(&registry, "inspect_trace", args, context.temp_allocator)
	testing.expect(t, handled, "inspect_trace is claimed")
	testing.expect(t, strings.contains(result, `"isError":true`), "a runtime refusal is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"session\"`), "a §28 ok:false maps to the session category")
	testing.expect(t, strings.contains(result, "tick"), "the runtime's own refusal text rides through")
}

// test_obs_inspect_empty_unseeded_carries_diagnostic is the friction-0007 junction: an
// inspect_* probe over a FRESH (seedless) session that returns an empty result set must be
// SELF-DESCRIBING. The OBS_FIXTURE opens seedless (no replay log), so inspect_signals at a
// recorded tick reads an empty `routes` — the bare `[]` an agent could not tell apart from
// a dead swarm or a wrong tick. The enriched lift carries the session precondition
// (seeded:false) AND a diagnostic naming the missing prerequisite plus the next action, so
// the emptiness is explained at its source. This is the whole fix, end-to-end through the
// live registry: the §28 status read-back + the empty-set verdict + the diagnostic attach.
@(test)
test_obs_inspect_empty_unseeded_carries_diagnostic :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-empty-unseeded.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	// inspect_signals at tick 0: the one-behavior fixture routes no signals, so `routes`
	// is empty — the friction-0007 shape over a seedless fresh open.
	args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `","tick":0}`}, context.temp_allocator))
	result, handled := obs_dispatch_tool(&registry, "inspect_signals", args, context.temp_allocator)
	testing.expect(t, handled, "inspect_signals is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "an empty-but-clean observe is not a tool error")
	// The §28 result still rides verbatim under the `result` key — an existing reader
	// reaches the data (the additive-superset contract).
	testing.expect(t, strings.contains(result, `\"result\":`), "the §28 result rides under the result key")
	testing.expect(t, strings.contains(result, `\"routes\":[]`), "the empty routes set is preserved verbatim")
	// The precondition block surfaces the seedless session shape.
	testing.expect(t, strings.contains(result, `\"precondition\":`), "the precondition block is present on every inspect return")
	testing.expect(t, strings.contains(result, `\"seeded\":false`), "the seedless precondition is surfaced")
	testing.expect(t, strings.contains(result, `\"ticks_recorded\":`), "the recording extent is surfaced")
	// The diagnostic names the missing prerequisite (seedless) AND the next action.
	testing.expect(t, strings.contains(result, `\"diagnostic\":`), "an empty result with an unmet precondition carries a diagnostic")
	testing.expect(t, strings.contains(result, `seedless`), "the diagnostic names the seedless prerequisite — the friction-0007 root cause")
	testing.expect(t, strings.contains(result, `\"next_action\":`), "the diagnostic names the next action")
}

// test_obs_inspect_populated_omits_diagnostic pins distinguishability the OTHER way: a
// POPULATED inspect result carries the precondition block (so the agent always sees the
// timeline shape) but NO diagnostic — a non-empty result is never a precondition failure,
// so attaching one would be false-alarm noise. inspect_state of the spawned Hero at tick 0
// has one instance, the populated case over the same seedless session.
@(test)
test_obs_inspect_populated_omits_diagnostic :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-populated.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `","thing":"Hero","tick":0}`}, context.temp_allocator))
	result, handled := obs_dispatch_tool(&registry, "inspect_state", args, context.temp_allocator)
	testing.expect(t, handled, "inspect_state is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a populated observe is clean")
	testing.expect(t, strings.contains(result, `\"instances\":[{`), "the spawned Hero instance is in the result")
	testing.expect(t, strings.contains(result, `\"precondition\":`), "the precondition block is present even on a populated result")
	testing.expect(t, !strings.contains(result, `\"diagnostic\":`), "a populated result carries NO diagnostic — only empties with an unmet precondition do")
}

// test_obs_inspect_valid_empty_seeded_omits_diagnostic pins the third leg of
// distinguishability: an empty result whose preconditions are ALL met is a genuinely-empty
// -but-VALID tick, NOT a precondition failure — so it carries the precondition block but no
// diagnostic. A seeded MCP session needs a replay-log fixture, so this exercises the lift
// proc directly with a synthesized seeded/recorded precondition and an empty §28 response
// line — the same junction obs_lift_inspect_response runs end-to-end, isolating the
// "valid-empty" verdict from the seedless-fixture path the other two tests use.
@(test)
test_obs_inspect_valid_empty_seeded_omits_diagnostic :: proc(t: ^testing.T) {
	seeded := Obs_Precondition {
		known          = true,
		loaded         = true,
		seeded         = true,
		ticks_recorded = 30,
	}
	// A clean §28 draw_list ok response with an empty commands set — the valid-empty shape.
	response := `{"v":1,"id":1,"ok":true,"cmd":"draw_list","result":{"tick":7,"commands":[]}}`
	id := Mcp_Id{kind = .Integer, integer = 7}
	lifted := obs_lift_inspect_response(id, "draw_list", response, seeded, context.temp_allocator)

	testing.expect(t, strings.contains(lifted, `"isError":false`), "a valid-empty result is clean")
	testing.expect(t, strings.contains(lifted, `\"commands\":[]`), "the empty result rides verbatim")
	testing.expect(t, strings.contains(lifted, `\"seeded\":true`), "the met precondition is surfaced")
	testing.expect(t, strings.contains(lifted, `\"ticks_recorded\":30`), "the recording extent is surfaced")
	testing.expect(t, !strings.contains(lifted, `\"diagnostic\":`), "an empty result with EVERY precondition met carries no diagnostic — it is valid-empty, distinguishable from a precondition failure")
}

// test_obs_inspect_refusal_stays_verbatim pins that the enriched lift does NOT touch a §28
// refusal: an ok:false (a runtime-named cause like an out-of-range tick) stays the
// verbatim Session IsError obs_lift_response renders, with no precondition wrap — the
// precondition enrichment is for the EMPTY-but-ok case, never the already-named refusal.
@(test)
test_obs_inspect_refusal_stays_verbatim :: proc(t: ^testing.T) {
	pre := Obs_Precondition {
		known          = true,
		seeded         = false,
		ticks_recorded = 64,
	}
	response := `{"v":1,"id":1,"ok":false,"cmd":"state","error":"unknown thing"}`
	id := Mcp_Id{kind = .Integer, integer = 7}
	lifted := obs_lift_inspect_response(id, "state", response, pre, context.temp_allocator)

	testing.expect(t, strings.contains(lifted, `"isError":true`), "a §28 refusal stays a tool error")
	testing.expect(t, strings.contains(lifted, `\"category\":\"session\"`), "the refusal maps to the session category")
	testing.expect(t, strings.contains(lifted, `unknown thing`), "the runtime's own refusal text rides through")
	testing.expect(t, !strings.contains(lifted, `\"precondition\":`), "a refusal carries no precondition wrap — the runtime already named the cause")
}

// test_obs_draw_list_round_trip pins the always-headless render projection: inspect_draw
// _list at a committed tick lifts the §20 draw-list result clean. This is the
// deterministic screenshot substitute (the ADR's headless-always-serves path) — it runs
// in the SDL-free floor precisely because the draw-list is sim-pure, no present boundary.
@(test)
test_obs_draw_list_round_trip :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-drawlist.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `","tick":0}`}, context.temp_allocator))
	result, handled := obs_dispatch_tool(&registry, "inspect_draw_list", args, context.temp_allocator)
	testing.expect(t, handled, "inspect_draw_list is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "the always-headless draw_list serves clean")
	testing.expect(t, strings.contains(result, `\"tick\":0`), "the draw_list result echoes the requested tick")
}
