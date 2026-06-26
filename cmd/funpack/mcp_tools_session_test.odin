// Deliberate spec for the session-lifecycle tool dispatch family
// (mcp_tools_session.odin) — the living junction test for the server-native tools that
// manage the registry DIRECTLY (no §28 fold): session_start / session_list / session_end.
// It pins the contracts the arm sits on: (1) the family claim boundary (owns the "session"
// group, declines every other group), (2) session_start over a LIVE artifact returning
// {session_id, negotiated_version} and registering the session, (3) session_list
// enumerating the live entries, (4) session_end tearing a session down (arena_destroy) and
// the unknown-id / double-end Session refusal, (5) the open-failure → IsError mapping with
// no orphaned arena, (6) the END-TO-END reachability proof: a tools/call routed through
// mcp_handle_tools_call (the production chain) reaches this arm and is NO LONGER the
// not-implemented / unknown-tool stub — the regression the upstream contract fix
// (register-mcp-server-native) was the prerequisite for, and (7) the optional `replay_log`
// arg (friction-9771c0f4): a session_start with a recorded replay log pre-folds it so the
// session navigates the recorded ticks (proven by the recorded-tick count, distinct from a
// fresh open's ATTACH_FRESH_TICKS window), and an identity-mismatched log is refused
// Invalid_Input naming the replay path.
//
// DEFINE-FREE FLOOR: these run in the default `odin test .` build (no FUNPACK_LIVE, no
// SDL). Everything the arm drives — open_session_for_artifact, the virtual.Arena
// lifecycle, the registry map — is SDL-free, so the family's contract is pinned in the
// same deterministic floor the rest of the compiler tests run in.
//
// NAMESPACE DISCIPLINE: every package-level symbol here is prefixed `sess_` (the family's
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

// SESS_FIXTURE is a minimal one-behavior artifact (a Hero whose Fixed `pos` advances
// 1.0/tick) — the same shape the registry's F13 test uses, inlined here so this file
// stands alone. A session opens cleanly over it, which is all the lifecycle arm needs
// (it never folds an observe command — that is the observe family's junction).
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

// SESS_RNG_FIXTURE is the committed seedfix golden artifact (the runtime's
// seedless-setup, per-tick-RNG shape — the deepseed case friction-7dfc0512 hit),
// #load'd cross-tree so the session-lifecycle arm's SEED echo is proven over a real
// uses_rng game without hand-authoring one. A bare session_start over it resolves the
// §25 §60 default root seed (seeded=true) — the friction's seeded=false flip — and a
// `seed` arg overrides it.
@(private = "file")
SESS_RNG_FIXTURE := #load("../../runtime/testdata/seedfix.artifact", string)

// sess_stage_contents writes arbitrary `contents` to a uniquely-named temp file and
// returns its path — the generalization of sess_stage_fixture used to stage the
// uses_rng artifact alongside the default SESS_FIXTURE.
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

// sess_stage_fixture writes SESS_FIXTURE to a uniquely-named temp file and returns its
// path. ok=false (the caller skips, never false-fails) when the temp root cannot be
// staged. The caller defers os.remove on the returned path.
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

// sess_dispatch_tool is the test harness for one tools/call through the family arm: it
// looks the tool's generated Tool_Spec up by name (the real lookup mcp_handle_tools_call
// uses), builds the Mcp_Dispatch the chain passes, and invokes the arm — returning the
// rendered JSON-RPC result line and whether the arm CLAIMED the tool. It drives the arm
// through exactly the seam the chain does, so the test exercises the production path, not
// a private shortcut.
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

// sess_args parses a JSON object literal into the json.Object the dispatch arm reads —
// the test authors arguments as wire JSON (the shape the MCP boundary delivers). A parse
// failure is a test-author bug, surfaced loudly.
@(private = "file")
sess_args :: proc(t: ^testing.T, literal: string) -> json.Object {
	parsed, err := json.parse(transmute([]u8)literal, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None, "fixture args must parse: %v", err)
	object, is_object := parsed.(json.Object)
	testing.expect(t, is_object, "fixture args must be a JSON object")
	return object
}

// test_sess_owns_only_session_group pins the family claim boundary: it owns the three
// server-native session tools (group "session") and DECLINES every other group so the
// chain reaches the owning family. A family wrongly claiming another's tool would shadow
// it — this is the structural guard against that.
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

// test_sess_declines_unowned_tool pins that the arm returns handled=false for a tool it
// does not own — the chain contract that lets the next family try. An observe tool flows
// PAST this arm untouched (no result rendered, the result string is ignored).
@(test)
test_sess_declines_unowned_tool :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	_, handled := sess_dispatch_tool(&registry, "inspect_pipeline", sess_args(t, `{"session_id":"sess-1"}`), context.temp_allocator)
	testing.expect(t, !handled, "the session arm declines an observe-group tool (handled=false)")
}

// test_sess_start_opens_and_registers is the session_start junction: a tools/call over a
// LIVE artifact returns a clean (not IsError) result carrying {session_id,
// negotiated_version} AND the session is now in the registry — addressable by the minted
// id. The negotiated version is the §28 protocol integer the session speaks.
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
	// SESS_FIXTURE draws no RNG, so the bare open echoes seeded:false — the self-describing
	// pair an agent reads to tell a genuine seedless read from a uses_rng one.
	testing.expect(t, strings.contains(result, `\"seeded\":false`), "a no-RNG bare open echoes seeded:false")
	testing.expect_value(t, len(registry.entries), 1)
}

// test_sess_start_uses_rng_echoes_seeded is the friction-7dfc0512 / friction-9fcfe1cd
// surface flip at the MCP layer: a BARE session_start over a uses_rng game now resolves
// the §25 §60 default root seed and ECHOES seeded:true with the resolved seed — so an
// agent learns up front it is surfacing the real seeded run, not the frozen-at-defaults
// state the friction reported (where this same open came back seeded:false).
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

// test_sess_start_seed_arg_overrides pins the agent-supplyable seed: a session_start with
// a `seed` arg over a uses_rng game pins THAT seed in the resolved session and echoes it
// back, so an agent can reproduce a specific run rather than only the default.
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

// test_sess_start_missing_artifact_is_invalid_input pins the arg-contract refusal: a
// session_start with no artifact is an Invalid_Input IsError (the one required arg), and
// NO session is registered (the open never ran).
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

// test_sess_start_unreadable_artifact_is_error_no_orphan pins the at-cap / failure path:
// a session_start over an unreadable path is an IsError (Resolver category) and leaves NO
// orphaned entry — the registry open destroys the per-attempt arena before returning,
// so a failed open leaks no arena and registers no session.
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

// test_sess_list_enumerates_live_sessions pins session_list: an empty registry lists the
// empty array, and after two opens it lists both ids. It drives the registry directly (no
// §28 fold), so the result is always clean (never IsError).
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

// test_sess_end_tears_down pins session_end: ending a live session is a clean
// {session_id,ended:true} ack AND the session is gone from the registry — arena_destroy
// reaped its whole graph.
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

// test_sess_end_unknown_id_is_session_error pins the stale-session refusal: ending an id
// the registry never minted (or a double-end) is a Session-category IsError carrying the
// id — never a fault, never a JSON-RPC error object. The registry's idempotent found=false
// contract maps to a clean in-band error the model reads and moves past.
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

// test_sess_end_missing_session_id_is_invalid_input pins the arg-contract refusal: a
// session_end with no session_id is an Invalid_Input IsError (distinct from the Session
// refusal of a wrong id).
@(test)
test_sess_end_missing_session_id_is_invalid_input :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := sess_dispatch_tool(&registry, "session_end", sess_args(t, `{}`), context.temp_allocator)
	testing.expect(t, handled, "session_end is claimed")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing session_id is a tool error")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "the category is invalid_input")
}

// test_sess_open_error_category_mapping pins the Open_Session_Result → MCP-category map:
// an on-disk read failure is Resolver, a malformed/identity-mismatched input is
// Invalid_Input, and a per-session arena alloc fault is Internal — NOT Resolver. The
// alloc fault is a host-resource failure the caller's arguments cannot fix, so it must
// not read as "the file could not be resolved"; it gets its own closed-enum variant
// (Session_Alloc_Failed) and the .Internal category.
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

// test_sess_reachable_through_tools_call is THE reachability proof — the regression the
// upstream contract fix (register-mcp-server-native) was the prerequisite for. It drives
// session_start through mcp_handle_tools_call (the PRODUCTION tools/call entry, not a
// direct arm call): the request reaches THIS family arm and returns the clean
// {session_id, negotiated_version} result — NO LONGER the "unknown tool" or "tool not yet
// implemented" IsError stub. session_list and session_end are then driven through the same
// entry to prove the whole lifecycle is reachable end-to-end through the chain.
@(test)
test_sess_reachable_through_tools_call :: proc(t: ^testing.T) {
	path, staged := sess_stage_fixture(t, "funpack-mcp-sess-e2e.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	// session_start through the production chain: it must reach this arm, NOT the stub.
	start_request := sess_tools_call_request(t, "session_start", strings.concatenate({`{"artifact":"`, path, `"}`}, context.temp_allocator))
	start_result := mcp_handle_tools_call(&registry, start_request, context.temp_allocator)
	testing.expect(t, !strings.contains(start_result, "tool not yet implemented"), "session_start is NO LONGER the not-implemented stub")
	testing.expect(t, !strings.contains(start_result, "unknown tool"), "session_start is NOT the unknown-tool stub")
	testing.expect(t, strings.contains(start_result, `"isError":false`), "session_start through the chain is a clean result")
	testing.expect(t, strings.contains(start_result, `\"negotiated_version\":1`), "the chain result carries the negotiated version")
	testing.expect_value(t, len(registry.entries), 1)

	// The minted id is needed to end the session through the chain — read it back off the
	// single registered entry (the only one, just opened).
	session_id: string
	for id in registry.entries {
		session_id = id
	}
	testing.expect(t, session_id != "", "the chain opened a session with a real id")

	// session_list through the chain lists the live session.
	list_request := sess_tools_call_request(t, "session_list", `{}`)
	list_result := mcp_handle_tools_call(&registry, list_request, context.temp_allocator)
	testing.expect(t, strings.contains(list_result, `"isError":false`), "session_list through the chain is clean")
	testing.expect(t, strings.contains(list_result, session_id), "the live session is listed through the chain")

	// session_end through the chain tears it down.
	end_request := sess_tools_call_request(t, "session_end", strings.concatenate({`{"session_id":"`, session_id, `"}`}, context.temp_allocator))
	end_result := mcp_handle_tools_call(&registry, end_request, context.temp_allocator)
	testing.expect(t, strings.contains(end_result, `"isError":false`), "session_end through the chain is clean")
	testing.expect(t, strings.contains(end_result, `\"ended\":true`), "the chain end-ack reports ended:true")
	testing.expect_value(t, len(registry.entries), 0)
}

// sess_tools_call_request builds an Mcp_Request for a tools/call with the given tool name
// and JSON argument literal — the exact shape mcp_parse_request produces from a wire line,
// so the end-to-end test drives mcp_handle_tools_call through its real input contract
// (params.name + params.arguments).
@(private = "file")
sess_tools_call_request :: proc(t: ^testing.T, name: string, arguments_literal: string) -> Mcp_Request {
	params := make(json.Object, context.temp_allocator)
	params["name"] = json.String(name)
	params["arguments"] = sess_args(t, arguments_literal)
	return Mcp_Request{id = Mcp_Id{kind = .Integer, integer = 11}, method = "tools/call", params = params}
}

// --- friction-9771c0f4: session_start with a recorded replay log ----------------------

// SESS_REPLAY_TICKS is the tick count the synthesized replay log records — chosen to
// DIFFER from the fresh-open window (funpack_runtime.ATTACH_FRESH_TICKS, 64) so a
// session_start that pre-folds the replay reports ticks_recorded == this value, NOT the
// fresh-open default. The mismatch IS the proof: the recorded ticks were folded, so the
// time_*/inspect_* surface navigates the recording rather than a synthetic empty window.
SESS_REPLAY_TICKS :: 10

// sess_stage_replay synthesizes an identity-MATCHED replay log against SESS_FIXTURE and
// writes it to a uniquely-named temp file. It mirrors how the runtime records a real
// replay: derive the build identity from the loaded fixture (identity_from_program over the
// SAME bytes session_start loads), open a writer, record SESS_REPLAY_TICKS empty-input ticks
// (the fixture is input-free — empty ticks fold its deterministic `pos` advance), finish,
// and write the bytes. ok=false (the caller skips) on any stage failure. The caller defers
// os.remove on the returned path.
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

// sess_status_ticks_recorded opens a session over (artifact, replay_log) through the
// PRODUCTION registry open, folds a §28 status request through it, and returns the
// ticks_recorded the status reports — the observable that proves whether the replay was
// pre-folded. It drives the same open + fold the session-scoped tools navigate, so a
// recorded-tick count read here is what time_*/inspect_* would address.
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

// test_sess_start_replay_log_prefolds_recorded_ticks is the friction-9771c0f4 junction:
// session_start with a `replay_log` arg pre-folds the recorded run so the session opens ON
// the recorded ticks (time_*/inspect_* navigate real gameplay), not a fresh empty window.
// The proof is the recorded-tick COUNT: a fresh open folds ATTACH_FRESH_TICKS (64) empty
// ticks, but a replay-backed open folds exactly the recorded count (SESS_REPLAY_TICKS, 10).
// The test opens both ways and asserts the replay-backed session reports the recorded count
// while the fresh open reports the larger default — so the replay arg DEMONSTRABLY changed
// what the session navigates, the whole point of the bridge.
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

	// A FRESH open (no replay) folds the ATTACH_FRESH_TICKS window — the baseline.
	fresh_ticks, fresh_opened := sess_status_ticks_recorded(t, artifact, "", false)
	testing.expect(t, fresh_opened, "the fresh session opens")
	testing.expect_value(t, fresh_ticks, i64(funpack_runtime.ATTACH_FRESH_TICKS))

	// The replay-backed open folds exactly the recorded ticks — the friction fix.
	replay_ticks, replay_opened := sess_status_ticks_recorded(t, artifact, replay_path, true)
	testing.expect(t, replay_opened, "the replay-backed session opens")
	testing.expect_value(t, replay_ticks, i64(SESS_REPLAY_TICKS))
	testing.expect(t, replay_ticks != fresh_ticks, "the replay arg pre-folds the recorded ticks, demonstrably distinct from a fresh empty window")

	// The same open through the tools/call dispatch arm is a clean result (the wire path).
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

// test_sess_start_replay_identity_mismatch_is_error pins the §09 §5 identity gate at the MCP
// surface: a replay log recorded against a DIFFERENT build (a perturbed content_hash) is
// refused as an Invalid_Input IsError whose detail names the REPLAY path (not the artifact),
// so a `replay_log` typo or a stale recording self-corrects to the right file. The gate
// refuses BEFORE folding mismatched inputs, and the surface never opens a session — the
// fail-closed contract the runtime owns, surfaced truthfully through the dispatch arm.
@(test)
test_sess_start_replay_identity_mismatch_is_error :: proc(t: ^testing.T) {
	artifact, staged := sess_stage_fixture(t, "funpack-mcp-sess-mismatch.fpk")
	if !staged {
		return
	}
	defer os.remove(artifact)

	// A replay log whose header identity does NOT match the fixture build: derive the true
	// identity, then perturb the content_hash so the every-field compare fails (the same
	// mismatch the runtime's open_session_for_artifact identity test constructs).
	loaded, load_err := funpack_runtime.load_program(SESS_FIXTURE, context.temp_allocator)
	testing.expect(t, load_err == .None, "the fixture must load to derive its identity")
	program := loaded
	identity := funpack_runtime.identity_from_program(program, SESS_FIXTURE)
	identity.content_hash ~= 0xDEAD_BEEF // a build fingerprint that cannot match the artifact

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
