package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

HUNT_ARTIFACT := #load("testdata/hunt.artifact", string)

HUNT_GOLDEN_REPLAY_LOG := #load("testdata/hunt_golden.replay", string)

HUNT_GOLDEN_EXPECTED_DIGEST := #load("testdata/hunt_golden.digest", string)

@(private = "file")
HUNT_SESSION_TICKS :: 240

@(private = "file")
HUNT_MOVE :: ActionId(0)

@(private = "file")
HUNT_TOWARD_TICKS :: 40

@(private = "file")
HUNT_CHASE_TICK :: 23
@(private = "file")
HUNT_SEARCH_TICK :: 75
@(private = "file")
HUNT_PATROL_TICK :: 196

@(private = "file")
hunt_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, HUNT_SESSION_TICKS, allocator)
	toward := Vec2{fixed_neg(to_fixed(1)), fixed_neg(to_fixed(1))}
	away := Vec2{to_fixed(1), to_fixed(1)}
	for i in 0 ..< HUNT_SESSION_TICKS {
		axis := i < HUNT_TOWARD_TICKS ? toward : away
		inputs[i] = with_axis(empty(), .P1, HUNT_MOVE, axis)
	}
	return inputs
}

@(private = "file")
hunt_time :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	return time_resource(tick_hz, allocator)
}

@(private = "file")
load_hunt :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(HUNT_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden hunt artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

@(private = "file")
hunt_live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	time := hunt_time(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version = step_tick(program, version, input, time, allocator)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

@(private = "file")
record_hunt_session :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, HUNT_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(private = "file")
hunter_ai_case :: proc(version: ^World_Version, idx: int) -> string {
	table := version_find_table(version, "Hunter")
	if table == nil || idx < 0 || idx >= len(table.rows) {
		return ""
	}
	token, ok := table.rows[idx].fields["ai"].(string)
	if !ok {
		return ""
	}
	return variant_from_token(token).case_name
}

@(test)
test_scripted_session_cycles_hunter_ai :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_hunt(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := hunt_time(program.entrypoint.tick_hz)
	inputs := hunt_session_inputs()

	testing.expect_value(t, hunter_ai_case(&version, 0), "Patrol")

	states := make([]string, len(inputs), context.temp_allocator)
	for input, i in inputs {
		version = step_tick(&program, version, input, time)
		states[i] = hunter_ai_case(&version, 0)
	}

	testing.expect_value(t, states[HUNT_CHASE_TICK - 1], "Patrol")
	testing.expect_value(t, states[HUNT_CHASE_TICK], "Chase")
	testing.expect_value(t, states[HUNT_SEARCH_TICK - 1], "Chase")
	testing.expect_value(t, states[HUNT_SEARCH_TICK], "Search")
	testing.expect_value(t, states[HUNT_PATROL_TICK - 1], "Search")
	testing.expect_value(t, states[HUNT_PATROL_TICK], "Patrol")
	testing.expect_value(t, states[len(states) - 1], "Patrol")
}

@(test)
test_hunt_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	live_program, ok := load_hunt(t)
	if !ok {
		return
	}
	inputs := hunt_session_inputs()
	live := hunt_live_capture(&live_program, inputs)

	log_bytes := record_hunt_session(&live_program, inputs)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	refold_program, refold_ok := load_hunt(t)
	if !refold_ok {
		return
	}
	result := replay_capture(&refold_program, HUNT_ARTIFACT, log)
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
test_committed_hunt_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_hunt(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(HUNT_GOLDEN_REPLAY_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay_capture(&program, HUNT_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_hunt_committed_digest(HUNT_GOLDEN_EXPECTED_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

@(private = "file")
parse_hunt_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(test)
test_regenerate_hunt_golden_fixtures :: proc(t: ^testing.T) {
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_hunt(t)
	if !ok {
		return
	}
	inputs := hunt_session_inputs()
	log_bytes := record_hunt_session(&program, inputs)

	log_path, log_join_err := filepath.join({"testdata", "hunt_golden.replay"})
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
	result := replay_capture(&program, HUNT_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "hunt_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
