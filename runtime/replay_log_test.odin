package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
log_identity :: proc() -> Replay_Identity {
	return Replay_Identity {
		artifact_schema_version = 1,
		project_name = "pong",
		project_version = "0.1.0",
		tick_hz = 60,
		content_hash = 0xfeed_face_dead_c0de,
	}
}

@(private = "file")
put_button :: proc(snapshot: ^Input, player: PlayerId, action: ActionId, state: Button_State) {
	snapshot.buttons[Player_Action{player, action}] = state
}

@(private = "file")
put_axis :: proc(snapshot: ^Input, player: PlayerId, action: ActionId, vec: Vec2) {
	snapshot.axes[Player_Action{player, action}] = vec
}

@(private = "file")
synthetic_stream :: proc(allocator := context.allocator) -> [dynamic]Input {
	REC_STEER :: ActionId(0)
	REC_FIRE :: ActionId(1)
	quarter := fixed_from_decimal(0, "25")
	half := fixed_from_decimal(0, "5")

	stream := make([dynamic]Input, 0, 4, allocator)

	t0 := Input {
		buttons = make(map[Player_Action]Button_State, allocator),
		axes    = make(map[Player_Action]Vec2, allocator),
	}
	put_button(&t0, .P1, REC_FIRE, Button_State{pressed = true, held = true})
	put_axis(&t0, .P2, REC_STEER, Vec2{half, Fixed(0)})
	append(&stream, t0)

	t1 := Input {
		buttons = make(map[Player_Action]Button_State, allocator),
		axes    = make(map[Player_Action]Vec2, allocator),
	}
	put_button(&t1, .P1, REC_FIRE, Button_State{held = true})
	put_button(&t1, .P4, REC_FIRE, Button_State{pressed = true, held = true})
	put_axis(&t1, .P3, REC_STEER, Vec2{fixed_neg(quarter), Fixed(0)})
	append(&stream, t1)

	t2 := Input {
		buttons = make(map[Player_Action]Button_State, allocator),
		axes    = make(map[Player_Action]Vec2, allocator),
	}
	put_button(&t2, .P1, REC_FIRE, Button_State{released = true})
	put_axis(&t2, .P2, REC_STEER, Vec2{Fixed(0), Fixed(0)})
	put_axis(&t2, .P3, REC_STEER, Vec2{fixed_neg(to_fixed(1)), Fixed(0)})
	append(&stream, t2)

	t3 := Input {
		buttons = make(map[Player_Action]Button_State, allocator),
		axes    = make(map[Player_Action]Vec2, allocator),
	}
	append(&stream, t3)

	return stream
}

@(private = "file")
record_stream :: proc(stream: []Input, allocator := context.allocator) -> string {
	writer := open_replay_writer(log_identity(), allocator)
	defer delete_replay_writer(&writer)
	for snapshot in stream {
		record_tick(&writer, snapshot, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(private = "file")
expect_snapshots_equal :: proc(t: ^testing.T, got, want: Input) {
	REC_STEER :: ActionId(0)
	REC_FIRE :: ActionId(1)
	for player in PlayerId {
		testing.expect_value(t, pressed(got, player, REC_FIRE), pressed(want, player, REC_FIRE))
		testing.expect_value(t, released(got, player, REC_FIRE), released(want, player, REC_FIRE))
		testing.expect_value(t, held(got, player, REC_FIRE), held(want, player, REC_FIRE))
		testing.expect_value(t, value(got, player, REC_STEER), value(want, player, REC_STEER))
		testing.expect_value(t, axis(got, player, REC_STEER), axis(want, player, REC_STEER))
	}
}

@(test)
test_round_trip_multi_tick_stream :: proc(t: ^testing.T) {
	stream := synthetic_stream(context.temp_allocator)
	defer for snapshot in stream {
		delete_input(snapshot)
	}

	log_bytes := record_stream(stream[:], context.temp_allocator)
	log, ok := read_replay(log_bytes, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}

	if !testing.expect_value(t, len(log.snapshots), len(stream)) {
		return
	}
	for i in 0 ..< len(stream) {
		expect_snapshots_equal(t, log.snapshots[i], stream[i])
	}
}

@(test)
test_serialize_twice_is_byte_identical :: proc(t: ^testing.T) {
	stream := synthetic_stream(context.temp_allocator)
	defer for snapshot in stream {
		delete_input(snapshot)
	}

	first := record_stream(stream[:], context.temp_allocator)
	second := record_stream(stream[:], context.temp_allocator)
	testing.expect_value(t, first, second)

	identity := log_identity()
	testing.expect(t, identity.content_hash != 0)
	testing.expect(t, identity.tick_hz > 0)

	log, ok := read_replay(first, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect(t, log.identity.content_hash != 0)
	testing.expect(t, log.identity.tick_hz > 0)
	testing.expect_value(t, log.identity.content_hash, identity.content_hash)
	testing.expect_value(t, log.identity.tick_hz, identity.tick_hz)
}

@(test)
test_on_disk_round_trip_is_byte_exact :: proc(t: ^testing.T) {
	stream := synthetic_stream(context.temp_allocator)
	defer for snapshot in stream {
		delete_input(snapshot)
	}
	log_bytes := record_stream(stream[:], context.temp_allocator)

	dir, dir_err := os.temp_dir(context.temp_allocator)
	if !testing.expect(t, dir_err == nil) {
		return
	}
	path, join_err := filepath.join({dir, "funpack-replay-roundtrip.replay"}, context.temp_allocator)
	if !testing.expect(t, join_err == nil) {
		return
	}
	defer os.remove(path)

	if !testing.expect(t, write_replay_file(path, log_bytes)) {
		return
	}

	raw, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if !testing.expect(t, read_err == nil) {
		return
	}
	testing.expect_value(t, string(raw), log_bytes)

	log, ok, io_ok := read_replay_file(path, context.temp_allocator)
	if !testing.expect(t, io_ok) {
		return
	}
	if !testing.expect(t, ok) {
		return
	}
	if !testing.expect_value(t, len(log.snapshots), len(stream)) {
		return
	}
	for i in 0 ..< len(stream) {
		expect_snapshots_equal(t, log.snapshots[i], stream[i])
	}
}

@(test)
test_read_replay_file_reports_missing_file :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_dir(context.temp_allocator)
	if !testing.expect(t, dir_err == nil) {
		return
	}
	missing, join_err := filepath.join({dir, "funpack-replay-does-not-exist.replay"}, context.temp_allocator)
	if !testing.expect(t, join_err == nil) {
		return
	}
	_, ok, io_ok := read_replay_file(missing, context.temp_allocator)
	testing.expect(t, !io_ok)
	testing.expect(t, !ok)
}

@(test)
test_production_reader_fails_closed_on_truncation :: proc(t: ^testing.T) {
	stream := synthetic_stream(context.temp_allocator)
	defer for snapshot in stream {
		delete_input(snapshot)
	}
	full := record_stream(stream[:], context.temp_allocator)

	_, ok := read_replay(full, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}

	ticks_marker := "[ticks "
	marker_at := -1
	for i in 0 ..< len(full) {
		if i + len(ticks_marker) <= len(full) && full[i:i + len(ticks_marker)] == ticks_marker {
			marker_at = i
			break
		}
	}
	if !testing.expect(t, marker_at >= 0) {
		return
	}
	cut := marker_at
	for cut < len(full) && full[cut] != '\n' {
		cut += 1
	}
	truncated := full[:cut + 1]
	_, truncated_ok := read_replay(truncated, context.temp_allocator)
	testing.expect(t, !truncated_ok)
}

@(test)
test_production_reader_fails_closed_on_malformed_record :: proc(t: ^testing.T) {
	malformed := "funpack-replay 2\nartifact 1 L4:pong L5:0.1.0 60 17361641481138401621 false 0\n[ticks 1]\ntick 1 0\nbutton 9 1 true false true\n"
	_, ok := read_replay(malformed, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_explicit_free_releases_log :: proc(t: ^testing.T) {
	stream := synthetic_stream(context.temp_allocator)
	defer for snapshot in stream {
		delete_input(snapshot)
	}
	log_bytes := record_stream(stream[:], context.temp_allocator)

	log, ok := read_replay(log_bytes, context.allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, len(log.snapshots), len(stream))
	delete_replay_log(log)
}
