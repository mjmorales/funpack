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
OBS_FIXTURE :: "funpack-artifact 19\n" +
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
	testing.expect(t, strings.contains(status_result, `\"loaded\":true`), "after load the status payload reports loaded:true")
	testing.expect(t, strings.contains(status_result, `\"ticks_recorded\"`), "the status payload reports the recording extent")
	// The next_action hint is ONLY for the unloaded orientation read — a loaded status is
	// already coherent (ring populated, cursor armed), so it carries no hint. Pinning its
	// ABSENCE here keeps the enrichment scoped to the loaded:false case.
	testing.expect(t, !strings.contains(status_result, `\"next_action\":`), "a loaded status carries no next_action — the timeline is already armed")
}

// test_obs_time_status_unloaded_carries_next_action is the unloaded-status junction: the
// FIRST-CONTACT orientation read on a fresh session, BEFORE any time_load. The bare §28
// status payload reports loaded:false alongside ticks_recorded:N (the recording's extent
// exists, but the cursor is not armed), which reads to a first-time agent as "N ticks of
// data are here to inspect" — so it calls time_step / inspect_*, which fail or return
// empty. The enriched lift attaches a next_action naming time_load as the required step,
// mirroring the self-describing precondition/diagnostic/next_action pattern
// so the orientation call carries the same guidance the time_step pre-load error already
// does. The §28 result still rides verbatim under `result` (the additive-superset
// contract — loaded/ticks_recorded/ring stay byte-stable, next_action is a pure addition).
@(test)
test_obs_time_status_unloaded_carries_next_action :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-status-unloaded.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	// A fresh session, NO time_load — exactly the first-contact orientation read.
	session_args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `"}`}, context.temp_allocator))
	result, handled := obs_dispatch_tool(&registry, "time_status", session_args, context.temp_allocator)
	testing.expect(t, handled, "time_status is claimed on a fresh session")
	testing.expect(t, strings.contains(result, `"isError":false`), "the orientation read is a clean read, never an error")
	// The §28 result rides verbatim — the machine-stable payload stays a superset.
	testing.expect(t, strings.contains(result, `\"loaded\":false`), "the unloaded session reports loaded:false")
	testing.expect(t, strings.contains(result, `\"ticks_recorded\"`), "the recording extent is preserved verbatim")
	testing.expect(t, strings.contains(result, `\"tick\":null`), "the unarmed cursor's tick stays null")
	// The additive next_action names time_load as the required next step.
	testing.expect(t, strings.contains(result, `\"next_action\":`), "the unloaded orientation read carries a next_action hint")
	testing.expect(t, strings.contains(result, `time_load`), "the next_action names time_load as the required step before time_step / inspect_*")
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

// test_obs_inspect_empty_no_rng_diagnostic_live is the friction-116a1681 junction END-TO-END:
// an inspect_* probe over a live FRESH session of a NO-RNG game that returns an empty result
// set must be SELF-DESCRIBING WITHOUT blaming a missing RNG seed. The OBS_FIXTURE is a no-RNG
// game (its one behavior binds no Rng — the runtime status reports uses_rng:false), so
// inspect_signals at a recorded tick reads an empty `routes` — the bare `[]` an agent could
// not tell apart from a dead swarm or a wrong tick. The enriched lift reads uses_rng off the
// §28 status read-back and carries the precondition (uses_rng:false) plus a diagnostic naming
// the no-RNG-by-design cause and the next action, NEVER the false missing-seed premise. This
// is the whole fix, end-to-end through the live registry: the §28 status read-back (which
// carries uses_rng) + the empty-set verdict + the corrected diagnostic attach.
@(test)
test_obs_inspect_empty_no_rng_diagnostic_live :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-empty-no-rng.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	// inspect_signals at tick 0: the one-behavior fixture routes no signals, so `routes`
	// is empty — the friction shape over a live no-RNG fresh open.
	args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `","tick":0}`}, context.temp_allocator))
	result, handled := obs_dispatch_tool(&registry, "inspect_signals", args, context.temp_allocator)
	testing.expect(t, handled, "inspect_signals is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "an empty-but-clean observe is not a tool error")
	// The §28 result still rides verbatim under the `result` key — an existing reader
	// reaches the data (the additive-superset contract).
	testing.expect(t, strings.contains(result, `\"result\":`), "the §28 result rides under the result key")
	testing.expect(t, strings.contains(result, `\"routes\":[]`), "the empty routes set is preserved verbatim")
	// The precondition block surfaces the no-RNG session shape (the new uses_rng fact).
	testing.expect(t, strings.contains(result, `\"precondition\":`), "the precondition block is present on every inspect return")
	testing.expect(t, strings.contains(result, `\"uses_rng\":false`), "the no-RNG class is surfaced — read off the §28 status envelope")
	testing.expect(t, strings.contains(result, `\"ticks_recorded\":`), "the recording extent is surfaced")
	// The diagnostic names the no-RNG cause AND the next action — and NEVER blames a seed.
	testing.expect(t, strings.contains(result, `\"diagnostic\":`), "an empty no-RNG result carries a distinguishing diagnostic")
	testing.expect(t, strings.contains(result, `uses no RNG`), "the diagnostic names the no-RNG-by-design cause")
	testing.expect(t, !strings.contains(result, `seedless`), "the diagnostic NEVER blames a missing seed for a no-RNG game (the friction-116a1681 misdiagnosis)")
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

// test_obs_inspect_valid_empty_seeded_omits_diagnostic pins the valid-empty leg of
// distinguishability for an RNG game: an empty result on a session that DRAWS RNG and folds
// a recorded seed over a non-empty recording is a genuinely-empty-but-VALID tick, NOT a
// precondition failure — so it carries the precondition block but no diagnostic. A seeded
// MCP session needs a replay-log fixture, so this exercises the lift proc directly with a
// synthesized seeded/uses_rng/recorded precondition and an empty §28 response line — the
// same junction obs_lift_inspect_response runs end-to-end, isolating the "valid-empty"
// verdict from the fixture paths the other tests use. The uses_rng:true + seeded:true pair
// is the REALISTIC valid-empty for an RNG game (a no-RNG game's empty result is its own
// distinguishable case, pinned by test_obs_inspect_no_rng_diagnostic).
@(test)
test_obs_inspect_valid_empty_seeded_omits_diagnostic :: proc(t: ^testing.T) {
	seeded := Obs_Precondition {
		known          = true,
		loaded         = true,
		seeded         = true,
		uses_rng       = true,
		ticks_recorded = 30,
	}
	// A clean §28 draw_list ok response with an empty commands set — the valid-empty shape.
	response := `{"v":1,"id":1,"ok":true,"cmd":"draw_list","result":{"tick":7,"commands":[]}}`
	id := Mcp_Id{kind = .Integer, integer = 7}
	lifted := obs_lift_inspect_response(id, "draw_list", response, seeded, context.temp_allocator)

	testing.expect(t, strings.contains(lifted, `"isError":false`), "a valid-empty result is clean")
	testing.expect(t, strings.contains(lifted, `\"commands\":[]`), "the empty result rides verbatim")
	testing.expect(t, strings.contains(lifted, `\"seeded\":true`), "the met precondition is surfaced")
	testing.expect(t, strings.contains(lifted, `\"uses_rng\":true`), "the RNG class is surfaced")
	testing.expect(t, strings.contains(lifted, `\"ticks_recorded\":30`), "the recording extent is surfaced")
	testing.expect(t, !strings.contains(lifted, `\"diagnostic\":`), "an empty result with EVERY precondition met (seeded RNG game, recorded) carries no diagnostic — it is valid-empty, distinguishable from a precondition failure")
}

// test_obs_inspect_no_rng_diagnostic is the friction-116a1681 junction: an inspect_* probe
// over a NO-RNG game whose empty result must NOT blame a missing RNG seed. The §28 status
// envelope reports uses_rng, and the enricher reads it: when the program draws no RNG, an
// empty result is a genuine state read of a deterministic game, and the diagnostic names the
// no-RNG-by-design cause rather than the false missing-seed premise. Exercises the lift proc
// directly with a no-RNG precondition (uses_rng:false, recorded) and an empty §28 response —
// the misdiagnosis the report reproduced over colony-sim, folded into the living spec at its
// source. The invariant this pins: seeded:false alone NEVER fires the seedless diagnostic —
// it fires only when uses_rng is also true, so a no-RNG game (which has no seed) is never
// misdiagnosed as seedless-broken.
@(test)
test_obs_inspect_no_rng_diagnostic :: proc(t: ^testing.T) {
	no_rng := Obs_Precondition {
		known          = true,
		loaded         = true,
		seeded         = false,
		uses_rng       = false,
		ticks_recorded = 64,
	}
	// A clean §28 state ok response with an empty instances set over a no-RNG game.
	response := `{"v":1,"id":1,"ok":true,"cmd":"state","result":{"thing":"Mote","tick":0,"instances":[]}}`
	id := Mcp_Id{kind = .Integer, integer = 7}
	lifted := obs_lift_inspect_response(id, "state", response, no_rng, context.temp_allocator)

	testing.expect(t, strings.contains(lifted, `"isError":false`), "an empty-but-clean no-RNG observe is not a tool error")
	testing.expect(t, strings.contains(lifted, `\"instances\":[]`), "the empty result rides verbatim")
	testing.expect(t, strings.contains(lifted, `\"uses_rng\":false`), "the no-RNG class is surfaced in the precondition")
	// The diagnostic fires (the empty result is explained) but names the no-RNG cause, NOT a
	// missing seed — the misdiagnosis fix.
	testing.expect(t, strings.contains(lifted, `\"diagnostic\":`), "an empty no-RNG result carries a distinguishing diagnostic")
	testing.expect(t, strings.contains(lifted, `uses no RNG`), "the diagnostic names the no-RNG-by-design cause")
	testing.expect(t, !strings.contains(lifted, `seedless`), "the no-RNG diagnostic NEVER blames a missing seed (the friction-116a1681 misdiagnosis)")
	testing.expect(t, !strings.contains(lifted, `RNG seed`), "the no-RNG diagnostic NEVER mentions a missing RNG seed")
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

// --- friction-6e7bb2c4: forward-fold on a writable branch ---------------------------

// obs_chain_call drives one tools/call through the PRODUCTION dispatch chain
// (mcp_handle_tools_call), so a test can cross dispatch families in one session — a
// control_* fold (control family) and a time_*/inspect_* fold (observe family) over the SAME
// registry. It builds the Mcp_Request exactly as mcp_parse_request does (params.name +
// params.arguments) and returns the rendered result line. This is the only way to exercise a
// branch-then-run sequence, which spans two families.
@(private = "file")
obs_chain_call :: proc(
	t: ^testing.T,
	registry: ^Mcp_Session_Registry,
	name: string,
	arguments_literal: string,
	allocator := context.allocator,
) -> string {
	params := make(json.Object, allocator)
	params["name"] = json.String(name)
	params["arguments"] = obs_args(t, arguments_literal)
	request := Mcp_Request{id = Mcp_Id{kind = .Integer, integer = 11}, method = "tools/call", params = params}
	return mcp_handle_tools_call(registry, request, allocator)
}

// test_obs_time_run_folds_writable_branch_forward is the friction-6e7bb2c4 junction: on a
// writable branch, time_run folds the pipeline FORWARD — it computes and records real new
// ticks, advancing the branch head — rather than advancing a phantom cursor over ticks that
// were never computed. The sequence mirrors the report's repro end-to-end through the
// production chain: open + load + run the canonical timeline, fork a writable branch at the
// post-startup boundary, checkout, spawn a fresh Hero on the branch, then time_run the branch
// forward. The proof the fold ran:
//
//   - time_run on the branch is a CLEAN position ack to the requested tick (no "tick out of
//     range" phantom),
//   - inspect_state at that real folded tick is a clean read whose instances are populated —
//     the spawned Hero's deterministic `pos` advance VISIBLY changed (the pipeline ran),
//   - the branch head reads back at the advanced tick, not pinned at the spawn tick.
//
// This is the surface VERIFICATION that R2's runtime forward-fold is threaded truthfully
// through the time_run dispatch — the dispatch lifts the runtime's real folded result, never
// a swallowed phantom.
@(test)
test_obs_time_run_folds_writable_branch_forward :: proc(t: ^testing.T) {
	path, staged := obs_stage_fixture(t, "funpack-mcp-obs-fwd-fold.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	sid := strings.concatenate({`"session_id":"`, id, `"`}, context.temp_allocator)

	// Load + run the canonical timeline, then fork a writable branch at the post-startup
	// boundary and check it out — the writable lineage a forward fold advances.
	_ = obs_chain_call(t, &registry, "time_load", strings.concatenate({"{", sid, "}"}, context.temp_allocator), context.temp_allocator)
	_ = obs_chain_call(t, &registry, "time_run", strings.concatenate({"{", sid, "}"}, context.temp_allocator), context.temp_allocator)
	branch_result := obs_chain_call(t, &registry, "control_branch", strings.concatenate({"{", sid, `,"tick":-1}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(branch_result, `"isError":false`), "the branch forks cleanly")
	checkout_result := obs_chain_call(t, &registry, "control_checkout", strings.concatenate({"{", sid, `,"target":"branch"}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(checkout_result, `"isError":false`), "the branch checks out cleanly")

	// Spawn a fresh Hero on the branch — the staged state a forward fold advances.
	spawn_result := obs_chain_call(t, &registry, "control_spawn", strings.concatenate({"{", sid, `,"thing":"Hero"}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(spawn_result, `"isError":false`), "the spawn on the writable branch is clean")

	// THE FORWARD FOLD: run the branch forward. The runtime folds the pipeline, producing
	// real new ticks — a CLEAN position ack to the requested tick, not a phantom "tick out of
	// range".
	run_result := obs_chain_call(t, &registry, "time_run", strings.concatenate({"{", sid, `,"branch":"branch","until":4}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(run_result, `"isError":false`), "time_run on a writable branch folds forward (no phantom tick-out-of-range)")
	testing.expect(t, strings.contains(run_result, `\"tick\":4`), "the fold advances the branch head to the requested tick")

	// The real folded tick is inspectable — the pipeline RAN, so the instances are populated.
	inspect_result := obs_chain_call(t, &registry, "inspect_state", strings.concatenate({"{", sid, `,"thing":"Hero","branch":"branch","tick":4}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(inspect_result, `"isError":false`), "the folded tick is a clean read, not out of range")
	testing.expect(t, strings.contains(inspect_result, `\"instances\":[{`), "the folded tick carries populated state — the pipeline ran forward")

	// The branch head reads back at the advanced tick (not pinned at the spawn tick) — the
	// fold COMMITTED the new ticks, the regression the report pinned.
	head_result := obs_chain_call(t, &registry, "inspect_state", strings.concatenate({"{", sid, `,"thing":"Hero","branch":"branch"}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(head_result, `"isError":false`), "the branch head is a clean read after the fold")
	testing.expect(t, strings.contains(head_result, `\"tick\":4`), "the branch head advanced to the folded tip, not frozen at the spawn tick")
}
