package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

YARD_ARTIFACT := #load("testdata/yard.artifact", string)

YARD_GOLDEN_REPLAY_LOG := #load("testdata/yard_golden.replay", string)

YARD_GOLDEN_EXPECTED_DIGEST := #load("testdata/yard_golden.digest", string)

@(private = "file")
YARD_SESSION_TICKS :: 760

@(private = "file")
YARD_MOVE :: ActionId(0)

yard_shake_kick :: proc() -> Fixed {return to_fixed(4)}

yard_shake_decay_1 :: proc() -> Fixed {return fixed_neg(to_fixed(2))}

yard_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, YARD_SESSION_TICKS, allocator)
	up := Vec2{Fixed(0), fixed_neg(to_fixed(1))}
	down := Vec2{Fixed(0), to_fixed(1)}
	left := Vec2{fixed_neg(to_fixed(1)), Fixed(0)}
	right := Vec2{to_fixed(1), Fixed(0)}
	brake := VEC2_ZERO

	Leg :: struct {
		axis:  Vec2,
		ticks: int,
	}
	legs := []Leg {
		{left, 12}, {right, 12}, {brake, 4},
		{up, 18}, {down, 18}, {brake, 4},
		{right, 12}, {left, 12}, {brake, 4},
	}

	tick := 0
	for leg in legs {
		for _ in 0 ..< leg.ticks {
			if tick >= YARD_SESSION_TICKS {
				return inputs
			}
			inputs[tick] = with_axis(empty(), .P1, YARD_MOVE, leg.axis)
			tick += 1
		}
	}
	for tick < YARD_SESSION_TICKS {
		inputs[tick] = with_axis(empty(), .P1, YARD_MOVE, down)
		tick += 1
	}
	return inputs
}

yard_time :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	return time_resource(tick_hz, allocator)
}

load_yard :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(YARD_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden yard artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

@(private = "file")
yard_live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	time := yard_time(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version = step_tick(program, version, input, time, allocator)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

@(private = "file")
record_yard_session :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, YARD_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_yard_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	live_program, ok := load_yard(t)
	if !ok {
		return
	}
	inputs := yard_session_inputs()
	live := yard_live_capture(&live_program, inputs)

	log_bytes := record_yard_session(&live_program, inputs)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	refold_program, refold_ok := load_yard(t)
	if !refold_ok {
		return
	}
	result := replay_capture(&refold_program, YARD_ARTIFACT, log)
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
test_committed_yard_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(YARD_GOLDEN_REPLAY_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay_capture(&program, YARD_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_yard_committed_digest(YARD_GOLDEN_EXPECTED_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

@(private = "file")
parse_yard_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(test)
test_regenerate_yard_golden_fixtures :: proc(t: ^testing.T) {
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}
	inputs := yard_session_inputs()
	log_bytes := record_yard_session(&program, inputs)

	log_path, log_join_err := filepath.join({"testdata", "yard_golden.replay"})
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
	result := replay_capture(&program, YARD_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "yard_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
