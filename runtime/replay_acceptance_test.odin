package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

GOLDEN_REPLAY_LOG := #load("testdata/pong_golden.replay", string)

GOLDEN_EXPECTED_DIGEST := #load("testdata/pong_golden.digest", string)

@(private = "file")
GOLDEN_SESSION_TICKS :: 600

@(private = "file")
GOLDEN_STEER :: ActionId(0)

@(private = "file")
GOLDEN_STEER_TICKS :: 26

golden_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, GOLDEN_SESSION_TICKS, allocator)
	for i in 0 ..< GOLDEN_SESSION_TICKS {
		if i < GOLDEN_STEER_TICKS {
			inputs[i] = with_value(empty(), .P2, GOLDEN_STEER, to_fixed(1))
		} else {
			inputs[i] = empty()
		}
	}
	return inputs
}

@(private = "file")
live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	time := time_resource(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version = step_tick(program, version, input, time, allocator)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

@(private = "file")
record_golden_session :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, GOLDEN_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	live_program, ok := load_golden(t)
	if !ok {
		return
	}
	inputs := golden_session_inputs()
	live := live_capture(&live_program, inputs)

	log_bytes := record_golden_session(&live_program, inputs)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	refold_program, refold_ok := load_golden(t)
	if !refold_ok {
		return
	}
	result := replay_capture(&refold_program, GOLDEN_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	if !testing.expect_value(t, len(result.capture.per_tick), len(live.per_tick)) {
		return
	}
	for frame, i in live.per_tick {
		testing.expect_value(t, result.capture.per_tick[i].tick, frame.tick)
		testing.expect_value(t, result.capture.per_tick[i].digest, frame.digest)
	}
	testing.expect_value(t, result.capture.session, live.session)
}

@(test)
test_committed_pong_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_golden(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(GOLDEN_REPLAY_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay_capture(&program, GOLDEN_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_committed_digest(GOLDEN_EXPECTED_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

@(private = "file")
parse_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(test)
test_regenerate_golden_fixtures :: proc(t: ^testing.T) {
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_golden(t)
	if !ok {
		return
	}
	inputs := golden_session_inputs()
	log_bytes := record_golden_session(&program, inputs)

	log_path, log_join_err := filepath.join({"testdata", "pong_golden.replay"})
	if !testing.expect(t, log_join_err == nil) {
		return
	}
	if !testing.expect(t, write_replay_file(log_path, log_bytes)) {
		return
	}

	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	result := replay_capture(&program, GOLDEN_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "pong_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
