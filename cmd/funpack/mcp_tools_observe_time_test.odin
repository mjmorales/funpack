package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import funpack_runtime "../../runtime"

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

@(private = "file")
obs_args :: proc(t: ^testing.T, literal: string) -> json.Object {
	parsed, err := json.parse(transmute([]u8)literal, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None, "fixture args must parse: %v", err)
	object, is_object := parsed.(json.Object)
	testing.expect(t, is_object, "fixture args must be a JSON object")
	return object
}

@(test)
test_obs_build_request_line_drops_session_threads_args :: proc(t: ^testing.T) {
	pipeline_args := obs_args(t, `{"session_id":"sess-1"}`)
	pipeline_line := obs_build_request_line("pipeline", pipeline_args, context.temp_allocator)
	testing.expect_value(t, pipeline_line, `{"id":1,"cmd":"pipeline"}`)

	trace_args := obs_args(t, `{"session_id":"sess-1","tick":3,"behavior":"advance"}`)
	trace_line := obs_build_request_line("trace", trace_args, context.temp_allocator)
	testing.expect(t, strings.contains(trace_line, `"cmd":"trace"`), "the cmd is trace")
	testing.expect(t, strings.contains(trace_line, `"tick":3`), "tick threads as an integer, never a float")
	testing.expect(t, strings.contains(trace_line, `"behavior":"advance"`), "behavior threads as a string")
	testing.expect(t, !strings.contains(trace_line, "session_id"), "session_id is dropped — it keys the session, not a §28 arg")

	branch_args := obs_args(t, `{"session_id":"sess-1","branch":"fork-a"}`)
	branch_line := obs_build_request_line("pipeline", branch_args, context.temp_allocator)
	testing.expect(t, strings.contains(branch_line, `"branch":"fork-a"`), "the optional branch selector threads through")
}

@(test)
test_obs_owns_only_inspect_and_time :: proc(t: ^testing.T) {
	owned := []string{"inspect_pipeline", "inspect_trace", "inspect_diff", "inspect_draw_list", "time_load", "time_run", "time_status"}
	for name in owned {
		spec, found := mcp_lookup_tool(name)
		testing.expectf(t, found, "owned tool %s is in the generated table", name)
		testing.expectf(t, obs_owns_command(spec), "the family claims %s", name)
	}
	declined := []string{"inspect_screenshot", "control_set", "control_spawn", "break", "watch", "capture_test", "audit"}
	for name in declined {
		spec, found := mcp_lookup_tool(name)
		testing.expectf(t, found, "declined tool %s is in the generated table", name)
		testing.expectf(t, !obs_owns_command(spec), "the family declines %s (its OWN family owns it)", name)
	}
}

@(test)
test_obs_declines_unowned_tool :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	_, handled := obs_dispatch_tool(&registry, "control_set", obs_args(t, `{"session_id":"sess-1"}`), context.temp_allocator)
	testing.expect(t, !handled, "the observe+time arm declines a control-group tool (handled=false)")
}

@(test)
test_obs_unknown_session_is_session_error :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := obs_dispatch_tool(&registry, "inspect_pipeline", obs_args(t, `{"session_id":"sess-999"}`), context.temp_allocator)
	testing.expect(t, handled, "the arm claims its tool even for an unknown session")
	testing.expect(t, strings.contains(result, `"isError":true`), "an unknown session is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"session\"`), "the category is session")
	testing.expect(t, strings.contains(result, "sess-999"), "the offending id rides in the detail")
}

@(test)
test_obs_missing_session_id_is_invalid_input :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := obs_dispatch_tool(&registry, "inspect_pipeline", obs_args(t, `{}`), context.temp_allocator)
	testing.expect(t, handled, "the arm claims its tool")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing session_id is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
}

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
	testing.expect(t, !strings.contains(status_result, `\"next_action\":`), "a loaded status carries no next_action — the timeline is already armed")
}

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

	session_args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `"}`}, context.temp_allocator))
	result, handled := obs_dispatch_tool(&registry, "time_status", session_args, context.temp_allocator)
	testing.expect(t, handled, "time_status is claimed on a fresh session")
	testing.expect(t, strings.contains(result, `"isError":false`), "the orientation read is a clean read, never an error")
	testing.expect(t, strings.contains(result, `\"loaded\":false`), "the unloaded session reports loaded:false")
	testing.expect(t, strings.contains(result, `\"ticks_recorded\"`), "the recording extent is preserved verbatim")
	testing.expect(t, strings.contains(result, `\"tick\":null`), "the unarmed cursor's tick stays null")
	testing.expect(t, strings.contains(result, `\"next_action\":`), "the unloaded orientation read carries a next_action hint")
	testing.expect(t, strings.contains(result, `time_load`), "the next_action names time_load as the required step before time_step / inspect_*")
}

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

	load_args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `"}`}, context.temp_allocator))
	_, _ = obs_dispatch_tool(&registry, "time_load", load_args, context.temp_allocator)

	run_args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `","until":5}`}, context.temp_allocator))
	run_result, run_handled := obs_dispatch_tool(&registry, "time_run", run_args, context.temp_allocator)
	testing.expect(t, run_handled, "time_run is claimed")
	testing.expect(t, strings.contains(run_result, `"isError":false`), "run to an in-range tick is clean")
	testing.expect(t, strings.contains(run_result, `\"tick\":5`), "run folds forward to the requested until tick")
}

@(test)
test_obs_runtime_refusal_is_refused_error :: proc(t: ^testing.T) {
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
	testing.expect(t, strings.contains(result, `\"category\":\"refused\"`), "a §28 ok:false maps to the refused category, not session")
	testing.expect(t, strings.contains(result, "tick"), "the runtime's own refusal text rides through")
}

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

	args := obs_args(t, strings.concatenate({`{"session_id":"`, id, `","tick":0}`}, context.temp_allocator))
	result, handled := obs_dispatch_tool(&registry, "inspect_signals", args, context.temp_allocator)
	testing.expect(t, handled, "inspect_signals is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "an empty-but-clean observe is not a tool error")
	testing.expect(t, strings.contains(result, `\"result\":`), "the §28 result rides under the result key")
	testing.expect(t, strings.contains(result, `\"routes\":[]`), "the empty routes set is preserved verbatim")
	testing.expect(t, strings.contains(result, `\"precondition\":`), "the precondition block is present on every inspect return")
	testing.expect(t, strings.contains(result, `\"uses_rng\":false`), "the no-RNG class is surfaced — read off the §28 status envelope")
	testing.expect(t, strings.contains(result, `\"ticks_recorded\":`), "the recording extent is surfaced")
	testing.expect(t, strings.contains(result, `\"diagnostic\":`), "an empty no-RNG result carries a distinguishing diagnostic")
	testing.expect(t, strings.contains(result, `uses no RNG`), "the diagnostic names the no-RNG-by-design cause")
	testing.expect(t, !strings.contains(result, `seedless`), "the diagnostic NEVER blames a missing seed for a no-RNG game (the friction-116a1681 misdiagnosis)")
	testing.expect(t, strings.contains(result, `\"next_action\":`), "the diagnostic names the next action")
}

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

@(test)
test_obs_inspect_valid_empty_seeded_omits_diagnostic :: proc(t: ^testing.T) {
	seeded := Obs_Precondition {
		known          = true,
		loaded         = true,
		seeded         = true,
		uses_rng       = true,
		ticks_recorded = 30,
	}
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

@(test)
test_obs_inspect_no_rng_diagnostic :: proc(t: ^testing.T) {
	no_rng := Obs_Precondition {
		known          = true,
		loaded         = true,
		seeded         = false,
		uses_rng       = false,
		ticks_recorded = 64,
	}
	response := `{"v":1,"id":1,"ok":true,"cmd":"state","result":{"thing":"Mote","tick":0,"instances":[]}}`
	id := Mcp_Id{kind = .Integer, integer = 7}
	lifted := obs_lift_inspect_response(id, "state", response, no_rng, context.temp_allocator)

	testing.expect(t, strings.contains(lifted, `"isError":false`), "an empty-but-clean no-RNG observe is not a tool error")
	testing.expect(t, strings.contains(lifted, `\"instances\":[]`), "the empty result rides verbatim")
	testing.expect(t, strings.contains(lifted, `\"uses_rng\":false`), "the no-RNG class is surfaced in the precondition")
	testing.expect(t, strings.contains(lifted, `\"diagnostic\":`), "an empty no-RNG result carries a distinguishing diagnostic")
	testing.expect(t, strings.contains(lifted, `uses no RNG`), "the diagnostic names the no-RNG-by-design cause")
	testing.expect(t, !strings.contains(lifted, `seedless`), "the no-RNG diagnostic NEVER blames a missing seed (the friction-116a1681 misdiagnosis)")
	testing.expect(t, !strings.contains(lifted, `RNG seed`), "the no-RNG diagnostic NEVER mentions a missing RNG seed")
}

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
	testing.expect(t, strings.contains(lifted, `\"category\":\"refused\"`), "the refusal maps to the refused category, not session")
	testing.expect(t, strings.contains(lifted, `unknown thing`), "the runtime's own refusal text rides through")
	testing.expect(t, !strings.contains(lifted, `\"precondition\":`), "a refusal carries no precondition wrap — the runtime already named the cause")
}

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

	_ = obs_chain_call(t, &registry, "time_load", strings.concatenate({"{", sid, "}"}, context.temp_allocator), context.temp_allocator)
	_ = obs_chain_call(t, &registry, "time_run", strings.concatenate({"{", sid, "}"}, context.temp_allocator), context.temp_allocator)
	branch_result := obs_chain_call(t, &registry, "control_branch", strings.concatenate({"{", sid, `,"tick":-1}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(branch_result, `"isError":false`), "the branch forks cleanly")
	checkout_result := obs_chain_call(t, &registry, "control_checkout", strings.concatenate({"{", sid, `,"target":"branch"}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(checkout_result, `"isError":false`), "the branch checks out cleanly")

	spawn_result := obs_chain_call(t, &registry, "control_spawn", strings.concatenate({"{", sid, `,"thing":"Hero"}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(spawn_result, `"isError":false`), "the spawn on the writable branch is clean")

	run_result := obs_chain_call(t, &registry, "time_run", strings.concatenate({"{", sid, `,"branch":"branch","until":4}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(run_result, `"isError":false`), "time_run on a writable branch folds forward (no phantom tick-out-of-range)")
	testing.expect(t, strings.contains(run_result, `\"tick\":4`), "the fold advances the branch head to the requested tick")

	inspect_result := obs_chain_call(t, &registry, "inspect_state", strings.concatenate({"{", sid, `,"thing":"Hero","branch":"branch","tick":4}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(inspect_result, `"isError":false`), "the folded tick is a clean read, not out of range")
	testing.expect(t, strings.contains(inspect_result, `\"instances\":[{`), "the folded tick carries populated state — the pipeline ran forward")

	head_result := obs_chain_call(t, &registry, "inspect_state", strings.concatenate({"{", sid, `,"thing":"Hero","branch":"branch"}`}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(head_result, `"isError":false`), "the branch head is a clean read after the fold")
	testing.expect(t, strings.contains(head_result, `\"tick\":4`), "the branch head advanced to the folded tip, not frozen at the spawn tick")
}
