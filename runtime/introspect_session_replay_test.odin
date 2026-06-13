// §28 §3 SESSION RECORD/REPLAY acceptance: a debug session is itself replayable.
// The recorder logs the full request/response stream of a live session to a
// byte-stable NDJSON command log; the replayer re-drives that log through a FRESH
// session over the SAME recording and reproduces the session's transcript
// bit-for-bit — the shareable-repro property (§28 §3: "a session re-runs
// bit-identically and is shareable"). Four paths are pinned:
//
//   - BIT-IDENTICAL TRANSCRIPT: a recorded session that mixes observe, time, and
//     control (state-mutating) commands re-runs to a byte-identical response
//     transcript — the core property, proven over a stream that drives the session
//     through cursor and branch state, so a stateful divergence would surface;
//   - DETERMINISM GOLDEN: recording the SAME request stream over the SAME recording
//     twice writes byte-identical command logs (the log bytes are stable, like the
//     replay log) AND round-trips through the on-disk reader unchanged;
//   - RECORDING-MISMATCH GATE: re-driving a command log against a session over a
//     DIFFERENT recording (a different snapshot count / seed) is refused before a
//     single request is re-fed — the pairing gate fails closed;
//   - DIVERGENCE REFUSAL: a tampered transcript (a recorded response edited) makes
//     the replay surface the §28 §3 `diverged` condition with the stream offset,
//     never a silent pass.
package funpack_runtime

import "core:strings"
import "core:testing"

// SESSION_REPLAY_BATTERY is the recorded session script: a stream that mixes the
// three command classes so the re-drive exercises a session whose STATE evolves —
// the time cursor advances (load/run/step/rewind), a control branch forks and is
// perturbed (branch/set), checkout flips the active lineage, and observe commands
// read across it. A pure-observe stream would replay trivially; this stream proves
// the property holds when the session carries mutated cursor + branch state, which
// is the load-bearing case (a wrong re-threaded cursor/branch would diverge).
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
	// A refusal in the middle: the error envelope is part of the transcript too, so
	// a replay must reproduce a recorded refusal byte-for-byte (the stream stays
	// loggable and replayable on every line, §28 §3).
	`{"id":16,"cmd":"signals","args":{"tick":9999}}`,
	`{"id":17,"cmd":"trace","args":{"tick":3,"behavior":"paddle_move"}}`,
}

// session_replay_pong_session opens an observe/control/time session over the golden
// pong run — the seedless fixture both the recorder and the replayer fold over. The
// pong identity is derived from the real golden artifact bytes, so the recorded
// command log pins the exact build the session ran against.
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

// record_session_battery drives the recorded script through a live session via the
// recorder, returning the finished command-log bytes and the count of recorded
// requests — the shared helper the transcript and determinism tests fold from.
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

// THE STORY ACCEPTANCE — a recorded session re-runs to a bit-identical transcript.
// The recorder logs a stream that mutates the session's cursor and branch state;
// the replayer re-drives that command log through a FRESH session over the SAME
// recording and reproduces every response byte-for-byte. Because session_request is
// a pure deterministic fold over (session_state, request), the re-driven session
// reproduces the recorded transcript exactly — the shareable-repro property.
@(test)
test_session_replay_bit_identical_transcript :: proc(t: ^testing.T) {
	log_bytes, request_count := record_session_battery(t)

	parsed, parse_ok := read_session_log(log_bytes)
	if !testing.expect(t, parse_ok, "the recorded command log must parse") {
		return
	}
	defer delete_session_log(parsed)

	// A fresh session over the SAME recording (same program + snapshots + seed), as a
	// shared session pairs the recording with the command log (§28 §3); the recording
	// identity the session was opened under is the gate's fingerprint.
	_, fresh, fresh_identity := session_replay_pong_session(t)
	replay := fresh
	result := replay_session(&replay, fresh_identity, parsed)

	testing.expect_value(t, result.refusal, Session_Replay_Refusal.None)
	testing.expect_value(t, result.requests_replayed, request_count)
}

// THE DETERMINISM GOLDEN — recording the SAME request stream over the SAME recording
// twice writes BYTE-IDENTICAL command logs (the log bytes are stable, mirroring the
// replay log's byte-stability), and the log round-trips through the on-disk reader
// unchanged. Byte-stability is what makes a recorded session SHAREABLE — two parties
// recording the same session produce the same artifact.
@(test)
test_session_replay_log_byte_stable_and_round_trips :: proc(t: ^testing.T) {
	first, _ := record_session_battery(t)
	second, _ := record_session_battery(t)
	testing.expect_value(t, first, second)

	// The on-disk reader round-trips the in-memory bytes: parse then re-assemble
	// against a fresh writer must reproduce the exact bytes (the format is a
	// passthrough, §28 §3 loggable-and-replayable).
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

// THE RECORDING-MISMATCH GATE — a command log re-driven against a session over a
// DIFFERENT recording is refused before a single request is re-fed (the pairing gate
// fails closed; a faithful re-drive needs the exact recording the log was made
// against — the recording half of the shareable pair). Both halves of the gate are
// exercised: a wrong snapshot extent and a wrong build fingerprint.
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

	// Extent half: a session over a recording SHORTER than the command log pins.
	short_inputs := make([]Input, len(golden_session_inputs(context.allocator)) - 1, context.allocator)
	for i in 0 ..< len(short_inputs) {
		short_inputs[i] = empty()
	}
	short := open_debug_session(program, short_inputs, NO_SEED, context.allocator)
	sh := short
	extent_result := replay_session(&sh, correct_identity, parsed)
	testing.expect_value(t, extent_result.refusal, Session_Replay_Refusal.Recording_Mismatch)
	testing.expect_value(t, extent_result.requests_replayed, 0)

	// Build-fingerprint half: the extent matches, but the recording identity the
	// session was opened under carries a different content hash than the command log
	// pins (a different build) — the §09 §5 fingerprint gate fires.
	matched := open_debug_session(program, golden_session_inputs(context.allocator), NO_SEED, context.allocator)
	mt := matched
	wrong_build := correct_identity
	wrong_build.content_hash = correct_identity.content_hash ~ 0xFFFF_FFFF_FFFF_FFFF
	build_result := replay_session(&mt, wrong_build, parsed)
	testing.expect_value(t, build_result.refusal, Session_Replay_Refusal.Recording_Mismatch)
	testing.expect_value(t, build_result.requests_replayed, 0)
}

// THE DIVERGENCE REFUSAL — a tampered transcript surfaces the §28 §3 `diverged`
// condition. A recorded response is edited to a value the fresh re-drive will not
// reproduce; the replayer catches the mismatch on that entry and refuses with the
// stream offset, never a silent pass. This is the property's contrapositive: replay
// reproduces the transcript bit-for-bit IFF the recording is faithful.
@(test)
test_session_replay_divergence_refused :: proc(t: ^testing.T) {
	log_bytes, _ := record_session_battery(t)
	parsed, parse_ok := read_session_log(log_bytes)
	if !testing.expect(t, parse_ok, "the recorded log must parse") {
		return
	}
	defer delete_session_log(parsed)

	// Tamper the first recorded RESPONSE entry to a value the re-drive cannot
	// reproduce, so the comparison diverges on it.
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
