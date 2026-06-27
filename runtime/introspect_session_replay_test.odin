package funpack_runtime

import "core:strings"
import "core:testing"

@(private = "file")
SESSION_REPLAY_BATTERY := [?]string {
	`{"id":1,"cmd":"status"}`,
	`{"id":2,"cmd":"load"}`,
	`{"id":3,"cmd":"run","args":{"until":40}}`,
	`{"id":4,"cmd":"step"}`,
	`{"id":5,"cmd":"pipeline"}`,
	`{"id":6,"cmd":"signals","args":{"tick":10}}`,
	`{"id":7,"cmd":"rewind","args":{"tick":20}}`,
	`{"id":8,"cmd":"status"}`,
	`{"id":9,"cmd":"branch","args":{"tick":15}}`,
	`{"id":10,"cmd":"diff","args":{"from":0,"to":15}}`,
	`{"id":11,"cmd":"checkout","args":{"target":"branch"}}`,
	`{"id":12,"cmd":"status"}`,
	`{"id":13,"cmd":"draw_list","args":{"tick":15,"branch":"canonical"}}`,
	`{"id":14,"cmd":"checkout","args":{"target":"canonical"}}`,
	`{"id":15,"cmd":"reset"}`,
	`{"id":16,"cmd":"signals","args":{"tick":9999}}`,
	`{"id":17,"cmd":"trace","args":{"tick":3,"behavior":"paddle_move"}}`,
}

@(private = "file")
session_replay_pong_session :: proc(
	t: ^testing.T,
	allocator := context.allocator,
) -> (
	program: ^Program,
	session: Debug_Session,
	identity: Replay_Identity,
) {
	program = new(Program, allocator)
	loaded, err := load_program(GOLDEN_ARTIFACT, allocator)
	testing.expect(t, err == .None, "golden pong artifact must load")
	program^ = loaded
	session = open_debug_session(program, golden_session_inputs(allocator), NO_SEED, allocator)
	identity = identity_from_program(program^, GOLDEN_ARTIFACT)
	return program, session, identity
}

@(private = "file")
record_session_battery :: proc(
	t: ^testing.T,
	allocator := context.allocator,
) -> (
	log_bytes: string,
	requests: int,
) {
	_, session, identity := session_replay_pong_session(t, allocator)
	s := session
	tick_count := len(s.snapshots)
	recorder := open_session_recorder(&s, identity, tick_count, allocator)
	for request in SESSION_REPLAY_BATTERY {
		record_request(&recorder, request, allocator)
	}
	log_bytes = finish_session_record(&recorder, allocator)
	delete_session_recorder(&recorder)
	return log_bytes, len(SESSION_REPLAY_BATTERY)
}

@(test)
test_session_replay_bit_identical_transcript :: proc(t: ^testing.T) {
	log_bytes, request_count := record_session_battery(t)

	parsed, parse_ok := read_session_log(log_bytes)
	if !testing.expect(t, parse_ok, "the recorded command log must parse") {
		return
	}
	defer delete_session_log(parsed)

	_, fresh, fresh_identity := session_replay_pong_session(t)
	replay := fresh
	result := replay_session(&replay, fresh_identity, parsed)

	testing.expect_value(t, result.refusal, Session_Replay_Refusal.None)
	testing.expect_value(t, result.requests_replayed, request_count)
}

@(test)
test_session_replay_log_byte_stable_and_round_trips :: proc(t: ^testing.T) {
	first, _ := record_session_battery(t)
	second, _ := record_session_battery(t)
	testing.expect_value(t, first, second)

	parsed, parse_ok := read_session_log(first)
	if !testing.expect(t, parse_ok, "the recorded log must parse") {
		return
	}
	defer delete_session_log(parsed)

	rebuilt := open_session_log_writer(parsed.identity, parsed.tick_count)
	for entry in parsed.entries {
		log_session_entry(&rebuilt, entry.kind, entry.envelope)
	}
	rebuilt_bytes := finish_session_log(&rebuilt)
	delete_session_log_writer(&rebuilt)
	testing.expect_value(t, rebuilt_bytes, first)
}

@(test)
test_session_replay_recording_mismatch_refused :: proc(t: ^testing.T) {
	log_bytes, _ := record_session_battery(t)
	parsed, parse_ok := read_session_log(log_bytes)
	if !testing.expect(t, parse_ok, "the recorded log must parse") {
		return
	}
	defer delete_session_log(parsed)

	program := new(Program, context.allocator)
	loaded, err := load_program(GOLDEN_ARTIFACT, context.allocator)
	testing.expect(t, err == .None, "golden pong artifact must load")
	program^ = loaded
	correct_identity := identity_from_program(program^, GOLDEN_ARTIFACT)

	short_inputs := make([]Input, len(golden_session_inputs(context.allocator)) - 1, context.allocator)
	for i in 0 ..< len(short_inputs) {
		short_inputs[i] = empty()
	}
	short := open_debug_session(program, short_inputs, NO_SEED, context.allocator)
	sh := short
	extent_result := replay_session(&sh, correct_identity, parsed)
	testing.expect_value(t, extent_result.refusal, Session_Replay_Refusal.Recording_Mismatch)
	testing.expect_value(t, extent_result.requests_replayed, 0)

	matched := open_debug_session(program, golden_session_inputs(context.allocator), NO_SEED, context.allocator)
	mt := matched
	wrong_build := correct_identity
	wrong_build.content_hash = correct_identity.content_hash ~ 0xFFFF_FFFF_FFFF_FFFF
	build_result := replay_session(&mt, wrong_build, parsed)
	testing.expect_value(t, build_result.refusal, Session_Replay_Refusal.Recording_Mismatch)
	testing.expect_value(t, build_result.requests_replayed, 0)
}

@(test)
test_session_replay_divergence_refused :: proc(t: ^testing.T) {
	log_bytes, _ := record_session_battery(t)
	parsed, parse_ok := read_session_log(log_bytes)
	if !testing.expect(t, parse_ok, "the recorded log must parse") {
		return
	}
	defer delete_session_log(parsed)

	tampered := false
	for &entry in parsed.entries {
		if entry.kind == .Response {
			entry.envelope = strings.clone(`{"v":1,"id":1,"ok":true,"cmd":"status","result":{"tampered":true}}`)
			tampered = true
			break
		}
	}
	if !testing.expect(t, tampered, "the recorded log must carry a response to tamper") {
		return
	}

	_, fresh, fresh_identity := session_replay_pong_session(t)
	replay := fresh
	result := replay_session(&replay, fresh_identity, parsed)

	testing.expect_value(t, result.refusal, Session_Replay_Refusal.Diverged)
	testing.expect(t, strings.contains(result.diagnostic, "diverged at stream offset"), "the divergence must name the stream offset")
}
