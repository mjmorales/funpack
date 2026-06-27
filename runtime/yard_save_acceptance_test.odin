package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

YARD_SAVE_GOLDEN_REPLAY_LOG := #load("testdata/yard_save_golden.replay", string)

YARD_SAVE_GOLDEN_EXPECTED_DIGEST := #load("testdata/yard_save_golden.digest", string)

@(private = "file")
YARD_SAVE_BTN :: ActionId(1)
@(private = "file")
YARD_RESTORE_BTN :: ActionId(2)

@(private = "file")
YARD_SAVE_MOVE :: ActionId(0)

@(private = "file")
YARD_SAVE_SESSION_TICKS :: 270

@(private = "file")
YARD_SAVE_TICK :: 140

@(private = "file")
YARD_RESTORE_TICK :: 248

yard_save_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, YARD_SAVE_SESSION_TICKS, allocator)
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
		{right, 12}, {left, 12}, {brake, 8},
		{down, 20}, {brake, 30},
		{up, 16}, {down, 16}, {brake, 4},
		{down, 24}, {brake, 60},
	}

	tick := 0
	for leg in legs {
		for _ in 0 ..< leg.ticks {
			if tick >= YARD_SAVE_SESSION_TICKS {
				return inputs
			}
			inputs[tick] = with_axis(empty(), .P1, YARD_SAVE_MOVE, leg.axis)
			tick += 1
		}
	}
	for tick < YARD_SAVE_SESSION_TICKS {
		inputs[tick] = with_axis(empty(), .P1, YARD_SAVE_MOVE, brake)
		tick += 1
	}

	inputs[YARD_SAVE_TICK] = with_pressed(inputs[YARD_SAVE_TICK], .P1, YARD_SAVE_BTN)
	inputs[YARD_RESTORE_TICK] = with_pressed(inputs[YARD_RESTORE_TICK], .P1, YARD_RESTORE_BTN)
	return inputs
}

@(private = "file")
yard_save_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	store := new_in_memory_store(allocator)
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	carrier := new_persist_carrier(&store)
	time := yard_time(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version, carrier = step_tick_persist(program, version, input, time, carrier, allocator)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

@(private = "file")
yard_save_refold_capture :: proc(
	program: ^Program,
	artifact_bytes: string,
	log: Replay_Log,
	allocator := context.allocator,
) -> (
	capture: Frame_Capture,
	refusal: Replay_Refusal,
) {
	loaded_identity := identity_from_program(program^, artifact_bytes)
	if !yard_save_identity_matches(log.identity, loaded_identity) {
		return {}, .Identity_Mismatch
	}
	return yard_save_capture(program, log.snapshots, allocator), .None
}

@(private = "file")
yard_save_identity_matches :: proc(recorded, loaded: Replay_Identity) -> bool {
	return(
		recorded.artifact_schema_version == loaded.artifact_schema_version &&
		recorded.project_name == loaded.project_name &&
		recorded.project_version == loaded.project_version &&
		recorded.tick_hz == loaded.tick_hz &&
		recorded.content_hash == loaded.content_hash &&
		!recorded.has_seed &&
		!loaded.has_seed \
	)
}

@(private = "file")
record_yard_save_session :: proc(
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
test_yard_save_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	live_program, ok := load_yard(t)
	if !ok {
		return
	}
	inputs := yard_save_session_inputs()
	live := yard_save_capture(&live_program, inputs)

	log_bytes := record_yard_save_session(&live_program, inputs)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	testing.expect(t, pressed(log.snapshots[YARD_SAVE_TICK], .P1, YARD_SAVE_BTN))
	testing.expect(t, pressed(log.snapshots[YARD_RESTORE_TICK], .P1, YARD_RESTORE_BTN))

	refold_program, refold_ok := load_yard(t)
	if !refold_ok {
		return
	}
	refold, refusal := yard_save_refold_capture(&refold_program, YARD_ARTIFACT, log)
	if !testing.expect_value(t, refusal, Replay_Refusal.None) {
		return
	}

	if !testing.expect_value(t, len(refold.per_tick), len(live.per_tick)) {
		return
	}
	for frame, i in live.per_tick {
		testing.expect_value(t, refold.per_tick[i].tick, frame.tick)
		testing.expect_value(t, refold.per_tick[i].digest, frame.digest)
	}
	testing.expect_value(t, refold.session, live.session)
}

@(test)
test_committed_yard_save_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(YARD_SAVE_GOLDEN_REPLAY_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	refold, refusal := yard_save_refold_capture(&program, YARD_ARTIFACT, log)
	if !testing.expect_value(t, refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_yard_save_committed_digest(YARD_SAVE_GOLDEN_EXPECTED_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, refold.session, expected)
}

@(test)
test_yard_save_session_round_trips_at_restore_boundary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := yard_time(program.entrypoint.tick_hz)
	inputs := yard_save_session_inputs()

	store := new_in_memory_store()
	carrier := new_persist_carrier(&store)

	saved_crate: Vec2
	saved_delivered: i64
	mutated_crate: Vec2
	reverted_crate: Vec2
	reverted_delivered: i64
	for input, i in inputs {
		version, carrier = step_tick_persist(&program, version, input, time, carrier)
		if i == YARD_SAVE_TICK {
			saved_crate = yard_save_center_crate_pos(&version)
			saved_delivered = yard_save_scoreboard_delivered(&version)
		}
		if i == YARD_RESTORE_TICK {
			mutated_crate = yard_save_center_crate_pos(&version)
		}
		if i == YARD_RESTORE_TICK + 1 {
			reverted_crate = yard_save_center_crate_pos(&version)
			reverted_delivered = yard_save_scoreboard_delivered(&version)
		}
	}

	testing.expect(t, mutated_crate != saved_crate)

	testing.expect_value(t, reverted_crate, saved_crate)
	testing.expect_value(t, reverted_delivered, saved_delivered)
}

@(test)
test_regenerate_yard_save_golden_fixtures :: proc(t: ^testing.T) {
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}
	inputs := yard_save_session_inputs()
	log_bytes := record_yard_save_session(&program, inputs)

	log_path, log_join_err := filepath.join({"testdata", "yard_save_golden.replay"})
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
	refold, refusal := yard_save_refold_capture(&program, YARD_ARTIFACT, log)
	if !testing.expect_value(t, refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], refold.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "yard_save_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}

@(private = "file")
parse_yard_save_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(private = "file")
yard_save_center_crate_pos :: proc(version: ^World_Version) -> Vec2 {
	table := version_find_table(version, "Crate")
	if table == nil || len(table.rows) < 2 {
		return VEC2_ZERO
	}
	pos, ok := table.rows[1].fields["pos"].(Vec2)
	if !ok {
		return VEC2_ZERO
	}
	return pos
}

@(private = "file")
yard_save_scoreboard_delivered :: proc(version: ^World_Version) -> i64 {
	table := version_find_table(version, "Scoreboard")
	if table == nil || len(table.rows) == 0 {
		return -1
	}
	d, ok := table.rows[0].fields["delivered"].(i64)
	if !ok {
		return -1
	}
	return d
}
