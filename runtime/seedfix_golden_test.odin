package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

SEEDFIX_GOLDEN_ARTIFACT := #load("testdata/seedfix.artifact", string)

SEEDFIX_GOLDEN_LOG := #load("testdata/seedfix_golden.replay", string)

SEEDFIX_GOLDEN_DIGEST := #load("testdata/seedfix_golden.digest", string)

@(private = "file")
SEEDFIX_GOLDEN_SEED :: RUNTIME_DEFAULT_SEED

@(private = "file")
SEEDFIX_GOLDEN_TICKS :: 8

@(private = "file")
seedfix_golden_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, SEEDFIX_GOLDEN_TICKS, allocator)
	for i in 0 ..< SEEDFIX_GOLDEN_TICKS {
		inputs[i] = empty()
	}
	return inputs
}

@(private = "file")
load_seedfix_golden :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(SEEDFIX_GOLDEN_ARTIFACT, context.temp_allocator)
	if !testing.expect_value(t, err, Artifact_Error.None) {
		return {}, false
	}
	return loaded, true
}

@(private = "file")
seedfix_live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	seed: i64,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version, rng := run_startup_rooted(program, initial_version(world, allocator), seed, allocator)
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
record_seedfix_golden_session :: proc(
	program: ^Program,
	inputs: []Input,
	seed: i64,
	allocator := context.allocator,
) -> string {
	identity :=
		program_uses_rng(program) ? identity_from_program_seeded(program^, SEEDFIX_GOLDEN_ARTIFACT, seed) : identity_from_program(program^, SEEDFIX_GOLDEN_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(private = "file")
parse_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	return strconv.parse_u64(strings.trim_space(text))
}

@(test)
test_seedfix_is_seedless_setup_but_uses_rng :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	testing.expect(t, !program_is_seeded(&program))
	testing.expect(t, program_uses_rng(&program))
	testing.expect_value(t, resolve_root_seed(nil, program.entrypoint), SEEDFIX_GOLDEN_SEED)
}

@(test)
test_seedfix_golden_refold_renders_nonempty_world :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	log, parse_ok := read_replay(SEEDFIX_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay(
		&program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	testing.expect_value(t, view_count(view_of_type(&result.world, "Spawner")), 1)
	motes := view_of_type(&result.world, "Mote")
	testing.expect_value(t, view_count(motes), SEEDFIX_GOLDEN_TICKS)

	hand := rand_seed(SEEDFIX_GOLDEN_SEED)
	for i in 0 ..< view_count(motes) {
		expected_cell, next := rand_range(hand, 0, 10)
		hand = next
		row, _ := view_at(motes, i)
		cell, present := row_field(row, "cell")
		testing.expect(t, present)
		testing.expect_value(t, cell.(i64), expected_cell)
	}
}

@(test)
test_committed_seedfix_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	log, parse_ok := read_replay(SEEDFIX_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}
	result := replay_capture(
		&program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}
	expected, digest_ok := parse_committed_digest(SEEDFIX_GOLDEN_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

@(test)
test_seedfix_golden_seed_is_recorded_not_ambient :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	log, parse_ok := read_replay(SEEDFIX_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}
	if !testing.expect(t, log.identity.has_seed) {
		return
	}
	testing.expect_value(t, log.identity.seed, SEEDFIX_GOLDEN_SEED)

	matched := replay_capture(
		&program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
	)
	testing.expect_value(t, matched.refusal, Replay_Refusal.None)

	mismatched := replay_capture(
		&program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED + 1),
	)
	testing.expect_value(t, mismatched.refusal, Replay_Refusal.Identity_Mismatch)
}

@(test)
test_seedfix_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	live_program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	inputs := seedfix_golden_inputs()
	live := seedfix_live_capture(&live_program, inputs, SEEDFIX_GOLDEN_SEED)

	log_bytes := record_seedfix_golden_session(&live_program, inputs, SEEDFIX_GOLDEN_SEED)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	refold_program, refold_ok := load_seedfix_golden(t)
	if !refold_ok {
		return
	}
	result := replay_capture(
		&refold_program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
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
test_regenerate_seedfix_golden_fixtures :: proc(t: ^testing.T) {
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	inputs := seedfix_golden_inputs()
	log_bytes := record_seedfix_golden_session(&program, inputs, SEEDFIX_GOLDEN_SEED)

	log_path, log_join_err := filepath.join({"testdata", "seedfix_golden.replay"})
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
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "seedfix_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
