package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

GOLDEN_SNAKE_ARTIFACT := #load("testdata/snake.artifact", string)

SNAKE_GOLDEN_LOG := #load("testdata/snake_golden.replay", string)

SNAKE_GOLDEN_DIGEST := #load("testdata/snake_golden.digest", string)

@(private = "file")
SNAKE_GOLDEN_SEED :: i64(42)

@(private = "file")
SNAKE_GOLDEN_TICKS :: 16

@(private = "file")
MOVE_DOWN :: ActionId(1)

@(private = "file")
SNAKE_TURN_TICK :: 6

@(private = "file")
snake_golden_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, SNAKE_GOLDEN_TICKS, allocator)
	for i in 0 ..< SNAKE_GOLDEN_TICKS {
		if i == SNAKE_TURN_TICK {
			inputs[i] = with_pressed(empty(), .P1, MOVE_DOWN)
		} else {
			inputs[i] = empty()
		}
	}
	return inputs
}

@(private = "file")
load_snake_golden :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(GOLDEN_SNAKE_ARTIFACT, context.temp_allocator)
	if !testing.expect_value(t, err, Artifact_Error.None) {
		return {}, false
	}
	return loaded, true
}

@(private = "file")
snake_live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	seed: i64,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version, rng := run_startup_seeded(program, initial_version(world, allocator), rand_seed(seed), allocator)
	current := rng
	time := time_resource(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version = step_tick(program, version, input, time, allocator, &current)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

@(private = "file")
record_snake_golden_session :: proc(
	program: ^Program,
	inputs: []Input,
	seed: i64,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program_seeded(program^, GOLDEN_SNAKE_ARTIFACT, seed)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_snake_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	live_program, ok := load_snake_golden(t)
	if !ok {
		return
	}
	inputs := snake_golden_inputs()
	live := snake_live_capture(&live_program, inputs, SNAKE_GOLDEN_SEED)

	log_bytes := record_snake_golden_session(&live_program, inputs, SNAKE_GOLDEN_SEED)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	refold_program, refold_ok := load_snake_golden(t)
	if !refold_ok {
		return
	}
	result := replay_capture(
		&refold_program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED),
	)
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
test_committed_snake_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_snake_golden(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(SNAKE_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay_capture(
		&program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_snake_committed_digest(SNAKE_GOLDEN_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

@(test)
test_snake_golden_seed_is_recorded_not_ambient :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_snake_golden(t)
	if !ok {
		return
	}
	log, parse_ok := read_replay(SNAKE_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	if !testing.expect(t, log.identity.has_seed) {
		return
	}
	testing.expect_value(t, log.identity.seed, SNAKE_GOLDEN_SEED)

	matched := replay_capture(
		&program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED),
	)
	testing.expect_value(t, matched.refusal, Replay_Refusal.None)

	mismatched := replay_capture(
		&program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED + 1),
	)
	testing.expect_value(t, mismatched.refusal, Replay_Refusal.Identity_Mismatch)
}

@(private = "file")
parse_snake_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(test)
test_regenerate_snake_golden_fixtures :: proc(t: ^testing.T) {
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_snake_golden(t)
	if !ok {
		return
	}
	inputs := snake_golden_inputs()
	log_bytes := record_snake_golden_session(&program, inputs, SNAKE_GOLDEN_SEED)

	log_path, log_join_err := filepath.join({"testdata", "snake_golden.replay"})
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
	result := replay_capture(
		&program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "snake_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
