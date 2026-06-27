package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

KROGNID_GOLDEN_REPLAY_LOG := #load("testdata/krognid_golden.replay", string)

KROGNID_GOLDEN_EXPECTED_DIGEST := #load("testdata/krognid_golden.digest", string)

@(private = "file")
KROGNID_SESSION_TICKS :: 240

@(private = "file")
KROGNID_STRAFE :: ActionId(0)
@(private = "file")
KROGNID_FORWARD :: ActionId(1)

@(private = "file")
krognid_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, KROGNID_SESSION_TICKS, allocator)
	one := to_fixed(1)
	zero := Fixed(0)

	drive :: proc(strafe, forward: Fixed) -> Input {
		return with_value(with_value(empty(), .P1, KROGNID_STRAFE, strafe), .P1, KROGNID_FORWARD, forward)
	}

	Leg :: struct {
		strafe:  Fixed,
		forward: Fixed,
		ticks:   int,
	}
	legs := []Leg {
		{zero, one, 45},
		{one, zero, 45},
		{zero, fixed_neg(one), 45},
		{fixed_neg(one), zero, 45},
	}

	tick := 0
	for leg in legs {
		for _ in 0 ..< leg.ticks {
			if tick >= KROGNID_SESSION_TICKS {
				return inputs
			}
			inputs[tick] = drive(leg.strafe, leg.forward)
			tick += 1
		}
	}
	for tick < KROGNID_SESSION_TICKS {
		inputs[tick] = empty()
		tick += 1
	}
	return inputs
}

load_krognid :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(KROGNID_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden krognid artifact must load, got %v", err) {
		return {}, false
	}
	if !testing.expect_value(t, loaded.schema_version, ARTIFACT_SCHEMA_VERSION) {
		return {}, false
	}
	return loaded, true
}

@(private = "file")
krognid_live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	tick_hz := program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input, i in inputs {
		time := time_resource_at(tick_hz, i, allocator)
		version = step_tick(program, version, input, time, allocator)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

@(private = "file")
record_krognid_session :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, KROGNID_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_krognid_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	live_program, ok := load_krognid(t)
	if !ok {
		return
	}
	inputs := krognid_session_inputs()
	live := krognid_live_capture(&live_program, inputs)

	log_bytes := record_krognid_session(&live_program, inputs)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	refold_program, refold_ok := load_krognid(t)
	if !refold_ok {
		return
	}
	result := replay_capture(&refold_program, KROGNID_ARTIFACT, log)
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
test_committed_krognid_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_krognid(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(KROGNID_GOLDEN_REPLAY_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay_capture(&program, KROGNID_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_krognid_committed_digest(KROGNID_GOLDEN_EXPECTED_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

@(private = "file")
parse_krognid_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(test)
test_regenerate_krognid_golden_fixtures :: proc(t: ^testing.T) {
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_krognid(t)
	if !ok {
		return
	}
	inputs := krognid_session_inputs()
	log_bytes := record_krognid_session(&program, inputs)

	log_path, log_join_err := filepath.join({"testdata", "krognid_golden.replay"})
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
	result := replay_capture(&program, KROGNID_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "krognid_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
