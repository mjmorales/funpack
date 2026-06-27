package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import funpack_runtime "../../runtime"

SESS_FIXTURE :: "funpack-artifact 19\n" +
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
SESS_RNG_FIXTURE := #load("../../runtime/testdata/seedfix.artifact", string)

@(private = "file")
sess_stage_contents :: proc(t: ^testing.T, name: string, contents: string) -> (path: string, ok: bool) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	path, _ = filepath.join({base, name}, context.temp_allocator)
	if write_err := os.write_entire_file_from_string(path, contents); write_err != nil {
		return "", false
	}
	return path, true
}

@(private = "file")
sess_stage_fixture :: proc(t: ^testing.T, name: string) -> (path: string, ok: bool) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	path, _ = filepath.join({base, name}, context.temp_allocator)
	if write_err := os.write_entire_file(path, SESS_FIXTURE); write_err != nil {
		return "", false
	}
	return path, true
}

@(private = "file")
sess_dispatch_tool :: proc(
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
	return mcp_session_tool_dispatch(dispatch, allocator)
}

@(private = "file")
sess_args :: proc(t: ^testing.T, literal: string) -> json.Object {
	parsed, err := json.parse(transmute([]u8)literal, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None, "fixture args must parse: %v", err)
	object, is_object := parsed.(json.Object)
	testing.expect(t, is_object, "fixture args must be a JSON object")
	return object
}

@(test)
test_sess_owns_only_session_group :: proc(t: ^testing.T) {
	owned := []string{"session_start", "session_list", "session_end"}
	for name in owned {
		spec, found := mcp_lookup_tool(name)
		testing.expectf(t, found, "owned tool %s is in the generated table", name)
		testing.expectf(t, sess_owns_command(spec), "the family claims %s", name)
	}
	declined := []string{"inspect_pipeline", "control_set", "time_load", "build", "docs_search"}
	for name in declined {
		spec, found := mcp_lookup_tool(name)
		testing.expectf(t, found, "declined tool %s is in the generated table", name)
		testing.expectf(t, !sess_owns_command(spec), "the family declines %s (another family owns it)", name)
	}
}

@(test)
test_sess_declines_unowned_tool :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	_, handled := sess_dispatch_tool(&registry, "inspect_pipeline", sess_args(t, `{"session_id":"sess-1"}`), context.temp_allocator)
	testing.expect(t, !handled, "the session arm declines an observe-group tool (handled=false)")
}

@(test)
test_sess_start_opens_and_registers :: proc(t: ^testing.T) {
	path, staged := sess_stage_fixture(t, "funpack-mcp-sess-start.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	args := sess_args(t, strings.concatenate({`{"artifact":"`, path, `"}`}, context.temp_allocator))
	result, handled := sess_dispatch_tool(&registry, "session_start", args, context.temp_allocator)
	testing.expect(t, handled, "session_start is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a successful open is not a tool error")
	testing.expect(t, strings.contains(result, `\"session_id\"`), "the result carries the minted session id")
	testing.expect(t, strings.contains(result, `\"negotiated_version\"`), "the result carries the negotiated protocol version")
	testing.expect(t, strings.contains(result, `\"negotiated_version\":1`), "the negotiated version is the §28 protocol version (1)")
	testing.expect(t, strings.contains(result, `\"seeded\":false`), "a no-RNG bare open echoes seeded:false")
	testing.expect_value(t, len(registry.entries), 1)
}

@(test)
test_sess_start_uses_rng_echoes_seeded :: proc(t: ^testing.T) {
	path, staged := sess_stage_contents(t, "funpack-mcp-sess-rng.fpk", SESS_RNG_FIXTURE)
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	args := sess_args(t, strings.concatenate({`{"artifact":"`, path, `"}`}, context.temp_allocator))
	result, handled := sess_dispatch_tool(&registry, "session_start", args, context.temp_allocator)
	testing.expect(t, handled, "session_start is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a uses_rng bare open is a clean result")
	testing.expect(t, strings.contains(result, `\"seeded\":true`), "a bare open of a uses_rng game echoes seeded:true (the friction flip)")
	testing.expect(t, !strings.contains(result, `\"seed\":0`), "the echoed seed is the resolved root seed, not a 0 default")
	testing.expect_value(t, len(registry.entries), 1)
}

@(test)
test_sess_start_seed_arg_overrides :: proc(t: ^testing.T) {
	path, staged := sess_stage_contents(t, "funpack-mcp-sess-rng-seed.fpk", SESS_RNG_FIXTURE)
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	args := sess_args(t, strings.concatenate({`{"artifact":"`, path, `","seed":12345}`}, context.temp_allocator))
	result, handled := sess_dispatch_tool(&registry, "session_start", args, context.temp_allocator)
	testing.expect(t, handled, "session_start is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a seeded bare open is a clean result")
	testing.expect(t, strings.contains(result, `\"seeded\":true`), "an overridden bare open echoes seeded:true")
	testing.expect(t, strings.contains(result, `\"seed\":12345`), "the result echoes the agent-supplied seed")
	testing.expect_value(t, len(registry.entries), 1)
}

@(test)
test_sess_start_missing_artifact_is_invalid_input :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := sess_dispatch_tool(&registry, "session_start", sess_args(t, `{}`), context.temp_allocator)
	testing.expect(t, handled, "session_start is claimed")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing artifact is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
	testing.expect_value(t, len(registry.entries), 0)
}

@(test)
test_sess_start_unreadable_artifact_is_error_no_orphan :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := sess_dispatch_tool(
		&registry,
		"session_start",
		sess_args(t, `{"artifact":"/nonexistent/funpack-mcp-no-such.fpk"}`),
		context.temp_allocator,
	)
	testing.expect(t, handled, "session_start is claimed")
	testing.expect(t, strings.contains(result, `"isError":true`), "an unreadable artifact is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"resolver\"`), "the read failure maps to the resolver category")
	testing.expect_value(t, len(registry.entries), 0)
}

@(test)
test_sess_list_enumerates_live_sessions :: proc(t: ^testing.T) {
	path, staged := sess_stage_fixture(t, "funpack-mcp-sess-list.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	empty_result, empty_handled := sess_dispatch_tool(&registry, "session_list", sess_args(t, `{}`), context.temp_allocator)
	testing.expect(t, empty_handled, "session_list is claimed")
	testing.expect(t, strings.contains(empty_result, `"isError":false`), "listing an empty registry is clean")
	testing.expect(t, strings.contains(empty_result, `\"sessions\":[]`), "an empty registry lists the empty array")

	id_a, result_a := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	id_b, result_b := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, result_a, funpack_runtime.Open_Session_Result.Ok)
	testing.expect_value(t, result_b, funpack_runtime.Open_Session_Result.Ok)

	list_result, list_handled := sess_dispatch_tool(&registry, "session_list", sess_args(t, `{}`), context.temp_allocator)
	testing.expect(t, list_handled, "session_list is claimed")
	testing.expect(t, strings.contains(list_result, `"isError":false`), "listing live sessions is clean")
	testing.expect(t, strings.contains(list_result, id_a), "the first session's id is listed")
	testing.expect(t, strings.contains(list_result, id_b), "the second session's id is listed")
}

@(test)
test_sess_end_tears_down :: proc(t: ^testing.T) {
	path, staged := sess_stage_fixture(t, "funpack-mcp-sess-end.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	args := sess_args(t, strings.concatenate({`{"session_id":"`, id, `"}`}, context.temp_allocator))
	result, handled := sess_dispatch_tool(&registry, "session_end", args, context.temp_allocator)
	testing.expect(t, handled, "session_end is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "ending a live session is clean")
	testing.expect(t, strings.contains(result, `\"ended\":true`), "the ack reports ended:true")
	testing.expect_value(t, len(registry.entries), 0)
}

@(test)
test_sess_end_unknown_id_is_session_error :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := sess_dispatch_tool(&registry, "session_end", sess_args(t, `{"session_id":"sess-999"}`), context.temp_allocator)
	testing.expect(t, handled, "session_end is claimed even for an unknown session")
	testing.expect(t, strings.contains(result, `"isError":true`), "ending an unknown id is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"session\"`), "the category is session")
	testing.expect(t, strings.contains(result, "sess-999"), "the offending id rides in the detail")
}

@(test)
test_sess_end_missing_session_id_is_invalid_input :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := sess_dispatch_tool(&registry, "session_end", sess_args(t, `{}`), context.temp_allocator)
	testing.expect(t, handled, "session_end is claimed")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing session_id is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
}

@(test)
test_sess_open_error_category_mapping :: proc(t: ^testing.T) {
	read := sess_open_error(.Artifact_Read_Failed, "game.fpk", "")
	testing.expect_value(t, read.category, Mcp_Error_Category.Resolver)

	malformed := sess_open_error(.Artifact_Malformed, "game.fpk", "")
	testing.expect_value(t, malformed.category, Mcp_Error_Category.Invalid_Input)

	mismatch := sess_open_error(.Replay_Identity_Mismatch, "game.fpk", "run.replay")
	testing.expect_value(t, mismatch.category, Mcp_Error_Category.Invalid_Input)

	alloc := sess_open_error(.Session_Alloc_Failed, "game.fpk", "")
	testing.expect_value(t, alloc.category, Mcp_Error_Category.Internal)
}

@(test)
test_sess_reachable_through_tools_call :: proc(t: ^testing.T) {
	path, staged := sess_stage_fixture(t, "funpack-mcp-sess-e2e.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	start_request := sess_tools_call_request(t, "session_start", strings.concatenate({`{"artifact":"`, path, `"}`}, context.temp_allocator))
	start_result := mcp_handle_tools_call(&registry, start_request, context.temp_allocator)
	testing.expect(t, !strings.contains(start_result, "tool not yet implemented"), "session_start is NO LONGER the not-implemented stub")
	testing.expect(t, !strings.contains(start_result, "unknown tool"), "session_start is NOT the unknown-tool stub")
	testing.expect(t, strings.contains(start_result, `"isError":false`), "session_start through the chain is a clean result")
	testing.expect(t, strings.contains(start_result, `\"negotiated_version\":1`), "the chain result carries the negotiated version")
	testing.expect_value(t, len(registry.entries), 1)

	session_id: string
	for id in registry.entries {
		session_id = id
	}
	testing.expect(t, session_id != "", "the chain opened a session with a real id")

	list_request := sess_tools_call_request(t, "session_list", `{}`)
	list_result := mcp_handle_tools_call(&registry, list_request, context.temp_allocator)
	testing.expect(t, strings.contains(list_result, `"isError":false`), "session_list through the chain is clean")
	testing.expect(t, strings.contains(list_result, session_id), "the live session is listed through the chain")

	end_request := sess_tools_call_request(t, "session_end", strings.concatenate({`{"session_id":"`, session_id, `"}`}, context.temp_allocator))
	end_result := mcp_handle_tools_call(&registry, end_request, context.temp_allocator)
	testing.expect(t, strings.contains(end_result, `"isError":false`), "session_end through the chain is clean")
	testing.expect(t, strings.contains(end_result, `\"ended\":true`), "the chain end-ack reports ended:true")
	testing.expect_value(t, len(registry.entries), 0)
}

@(private = "file")
sess_tools_call_request :: proc(t: ^testing.T, name: string, arguments_literal: string) -> Mcp_Request {
	params := make(json.Object, context.temp_allocator)
	params["name"] = json.String(name)
	params["arguments"] = sess_args(t, arguments_literal)
	return Mcp_Request{id = Mcp_Id{kind = .Integer, integer = 11}, method = "tools/call", params = params}
}

SESS_REPLAY_TICKS :: 10

@(private = "file")
sess_stage_replay :: proc(t: ^testing.T, name: string) -> (path: string, ok: bool) {
	program: funpack_runtime.Program
	loaded, load_err := funpack_runtime.load_program(SESS_FIXTURE, context.temp_allocator)
	if load_err != .None {
		testing.expectf(t, false, "the session fixture must load to derive its replay identity: %v", load_err)
		return "", false
	}
	program = loaded
	identity := funpack_runtime.identity_from_program(program, SESS_FIXTURE)

	writer := funpack_runtime.open_replay_writer(identity, context.temp_allocator)
	defer funpack_runtime.delete_replay_writer(&writer)
	for _ in 0 ..< SESS_REPLAY_TICKS {
		funpack_runtime.record_tick(&writer, funpack_runtime.empty(), context.temp_allocator)
	}
	log_bytes := funpack_runtime.finish_replay(&writer, context.temp_allocator)

	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	path, _ = filepath.join({base, name}, context.temp_allocator)
	if !funpack_runtime.write_replay_file(path, log_bytes) {
		return "", false
	}
	return path, true
}

@(private = "file")
sess_status_ticks_recorded :: proc(
	t: ^testing.T,
	artifact: string,
	replay_log: string,
	has_replay: bool,
) -> (
	ticks_recorded: i64,
	opened: bool,
) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, artifact, replay_log, has_replay, "", context.temp_allocator)
	if open_result != funpack_runtime.Open_Session_Result.Ok {
		return 0, false
	}
	response, found := mcp_session_registry_request(&registry, id, `{"id":1,"cmd":"status"}`)
	if !found {
		return 0, false
	}
	parsed, parse_err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if parse_err != .None {
		testing.expectf(t, false, "the status response must parse: %v", parse_err)
		return 0, false
	}
	envelope, is_object := parsed.(json.Object)
	if !is_object {
		return 0, false
	}
	result, has_result := envelope["result"].(json.Object)
	if !has_result {
		return 0, false
	}
	ticks, has_ticks := result["ticks_recorded"].(json.Integer)
	if !has_ticks {
		return 0, false
	}
	return i64(ticks), true
}

@(test)
test_sess_start_replay_log_prefolds_recorded_ticks :: proc(t: ^testing.T) {
	artifact, staged := sess_stage_fixture(t, "funpack-mcp-sess-replay.fpk")
	if !staged {
		return
	}
	defer os.remove(artifact)
	replay_path, replayed := sess_stage_replay(t, "funpack-mcp-sess-replay.replay")
	if !replayed {
		return
	}
	defer os.remove(replay_path)

	fresh_ticks, fresh_opened := sess_status_ticks_recorded(t, artifact, "", false)
	testing.expect(t, fresh_opened, "the fresh session opens")
	testing.expect_value(t, fresh_ticks, i64(funpack_runtime.ATTACH_FRESH_TICKS))

	replay_ticks, replay_opened := sess_status_ticks_recorded(t, artifact, replay_path, true)
	testing.expect(t, replay_opened, "the replay-backed session opens")
	testing.expect_value(t, replay_ticks, i64(SESS_REPLAY_TICKS))
	testing.expect(t, replay_ticks != fresh_ticks, "the replay arg pre-folds the recorded ticks, demonstrably distinct from a fresh empty window")

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	args := sess_args(
		t,
		strings.concatenate({`{"artifact":"`, artifact, `","replay_log":"`, replay_path, `"}`}, context.temp_allocator),
	)
	result, handled := sess_dispatch_tool(&registry, "session_start", args, context.temp_allocator)
	testing.expect(t, handled, "session_start is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a replay-backed open is a clean result")
	testing.expect(t, strings.contains(result, `\"session_id\"`), "the result carries the minted session id")
	testing.expect_value(t, len(registry.entries), 1)
}

@(test)
test_sess_start_replay_identity_mismatch_is_error :: proc(t: ^testing.T) {
	artifact, staged := sess_stage_fixture(t, "funpack-mcp-sess-mismatch.fpk")
	if !staged {
		return
	}
	defer os.remove(artifact)

	loaded, load_err := funpack_runtime.load_program(SESS_FIXTURE, context.temp_allocator)
	testing.expect(t, load_err == .None, "the fixture must load to derive its identity")
	program := loaded
	identity := funpack_runtime.identity_from_program(program, SESS_FIXTURE)
	identity.content_hash ~= 0xDEAD_BEEF

	writer := funpack_runtime.open_replay_writer(identity, context.temp_allocator)
	defer funpack_runtime.delete_replay_writer(&writer)
	funpack_runtime.record_tick(&writer, funpack_runtime.empty(), context.temp_allocator)
	log_bytes := funpack_runtime.finish_replay(&writer, context.temp_allocator)

	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	replay_path, _ := filepath.join({base, "funpack-mcp-sess-mismatch.replay"}, context.temp_allocator)
	testing.expect(t, funpack_runtime.write_replay_file(replay_path, log_bytes), "the mismatched replay log writes")
	defer os.remove(replay_path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	args := sess_args(
		t,
		strings.concatenate({`{"artifact":"`, artifact, `","replay_log":"`, replay_path, `"}`}, context.temp_allocator),
	)
	result, handled := sess_dispatch_tool(&registry, "session_start", args, context.temp_allocator)
	testing.expect(t, handled, "session_start is claimed")
	testing.expect(t, strings.contains(result, `"isError":true`), "an identity-mismatched replay log is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the mismatch maps to invalid_input")
	testing.expect(t, strings.contains(result, "funpack-mcp-sess-mismatch.replay"), "the detail names the REPLAY path, not the artifact")
	testing.expect_value(t, len(registry.entries), 0)
}
