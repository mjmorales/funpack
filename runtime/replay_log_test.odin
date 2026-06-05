// Durable replay-log layer proof: the on-disk format and the production reader the
// re-fold driver consumes. The tests prove the four load-bearing properties of the
// layer above the recorder — (1) a finished log persists to a file and reads back
// BYTE-EXACT and snapshot-exact through the same production reader, so disk and
// memory take one path; (2) a synthetic MULTI-TICK stream mixing pressed/released/
// held edges and fixed-point axis readings across P1..P4 serializes then
// deserializes to the BIT-IDENTICAL snapshot sequence; (3) serializing the same
// stream twice yields BYTE-IDENTICAL buffers and the header carries a non-empty
// artifact hash and a positive tick rate (the §09 §5 mismatch-refusal pins); and
// (4) the production reader FAILS CLOSED on a truncated or malformed log rather
// than re-folding a partial stream. Every snapshot is built in the device-free
// producer/table vocabulary — raw device state never appears.
package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:testing"

// log_identity is a fixed artifact identity the durable-log tests pin without
// touching the artifact loader — a non-zero content hash and a positive tick rate
// so the header-pins assertions have observable values.
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

// put_button writes a resolved button state straight into a snapshot's table — the
// way bindings resolution builds a resolved snapshot, carrying a `released` edge or
// a `held`-without-`pressed` level no producer expresses. Taken by pointer because a
// map mutated through a parameter must pass as ^map.
@(private = "file")
put_button :: proc(snapshot: ^Input, player: PlayerId, action: ActionId, state: Button_State) {
	snapshot.buttons[Player_Action{player, action}] = state
}

// put_axis writes a resolved axis reading straight into a snapshot's table. Taken
// by pointer for the same reason as put_button.
@(private = "file")
put_axis :: proc(snapshot: ^Input, player: PlayerId, action: ActionId, vec: Vec2) {
	snapshot.axes[Player_Action{player, action}] = vec
}

// synthetic_stream builds the multi-tick action-snapshot stream the round-trip
// tests serialize: four ticks mixing every digital edge/level kind and fixed-point
// axis readings across all four players (P1..P4). The snapshots own their tables;
// the caller frees each with delete_input. Built directly into the tables so the
// stream can carry a released edge and a held-without-pressed level — the resolved
// shapes a re-fold must reproduce, which the producer surface cannot express.
@(private = "file")
synthetic_stream :: proc(allocator := context.allocator) -> [dynamic]Input {
	REC_STEER :: ActionId(0)
	REC_FIRE :: ActionId(1)
	quarter := fixed_from_decimal(0, "25")
	half := fixed_from_decimal(0, "5")

	stream := make([dynamic]Input, 0, 4, allocator)

	// Tick 0 — P1 presses (press implies held), P2 reads a positive axis.
	t0 := Input {
		buttons = make(map[Player_Action]Button_State, allocator),
		axes    = make(map[Player_Action]Vec2, allocator),
	}
	put_button(&t0, .P1, REC_FIRE, Button_State{pressed = true, held = true})
	put_axis(&t0, .P2, REC_STEER, Vec2{half, Fixed(0)})
	append(&stream, t0)

	// Tick 1 — P1 still held (no press edge), P3 reads a negative axis, P4 presses.
	t1 := Input {
		buttons = make(map[Player_Action]Button_State, allocator),
		axes    = make(map[Player_Action]Vec2, allocator),
	}
	put_button(&t1, .P1, REC_FIRE, Button_State{held = true})
	put_button(&t1, .P4, REC_FIRE, Button_State{pressed = true, held = true})
	put_axis(&t1, .P3, REC_STEER, Vec2{fixed_neg(quarter), Fixed(0)})
	append(&stream, t1)

	// Tick 2 — P1 releases (edge, no level), P2 axis back to zero, P3 reads a full
	// negative rail.
	t2 := Input {
		buttons = make(map[Player_Action]Button_State, allocator),
		axes    = make(map[Player_Action]Vec2, allocator),
	}
	put_button(&t2, .P1, REC_FIRE, Button_State{released = true})
	put_axis(&t2, .P2, REC_STEER, Vec2{Fixed(0), Fixed(0)})
	put_axis(&t2, .P3, REC_STEER, Vec2{fixed_neg(to_fixed(1)), Fixed(0)})
	append(&stream, t2)

	// Tick 3 — the all-empty snapshot: every query reads its zero default.
	t3 := Input {
		buttons = make(map[Player_Action]Button_State, allocator),
		axes    = make(map[Player_Action]Vec2, allocator),
	}
	append(&stream, t3)

	return stream
}

// record_stream writes a whole snapshot stream against log_identity and returns the
// finished log bytes — the common shape the round-trip and determinism tests share.
@(private = "file")
record_stream :: proc(stream: []Input, allocator := context.allocator) -> string {
	writer := open_replay_writer(log_identity(), allocator)
	defer delete_replay_writer(&writer)
	for snapshot in stream {
		record_tick(&writer, snapshot, allocator)
	}
	return finish_replay(&writer, allocator)
}

// expect_snapshots_equal asserts two snapshots read identically through the query
// API across all four players — the bit-identity the round-trip must preserve. It
// checks the recorded actions on each player; the stream uses REC_STEER/REC_FIRE.
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
	// A synthetic multi-tick stream mixing pressed/released/held edges and
	// fixed-point axis values across P1..P4 must serialize then deserialize to the
	// BIT-IDENTICAL snapshot sequence — the property the re-fold depends on
	// (§23 §4). The reader rebuilds each snapshot's tables from the recorded bits,
	// so the query API reads the re-fed stream identically tick-for-tick.
	stream := synthetic_stream(context.temp_allocator)
	defer for snapshot in stream {
		delete_input(snapshot)
	}

	log_bytes := record_stream(stream[:], context.temp_allocator)
	// The parsed log is temp-allocated; the temp arena reclaims it wholesale at the
	// test boundary, so it is not explicitly freed (a per-snapshot delete here would
	// be a cross-allocator free). test_explicit_free_releases_log exercises
	// delete_replay_log against context.allocator.
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
	// Serializing the same snapshot stream twice produces byte-identical buffers,
	// and the on-disk header carries the artifact/build content hash and tick rate
	// — the determinism record plus the §09 §5 mismatch-refusal pins. A non-zero
	// content hash is the non-empty-hash analogue for the u64-encoded fingerprint.
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

	// The recorded header round-trips back to exactly those pins (temp-allocated;
	// reclaimed at the test boundary).
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
	// A finished log written to a file reads back BYTE-EXACT and parses to the
	// identical snapshot sequence through the SAME production reader — disk and
	// memory take one path. The file is written under the OS temp dir and removed
	// after, so the test leaves no artifact behind.
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

	// The raw bytes on disk equal the in-memory log verbatim (passthrough, not a
	// re-encode), so the on-disk format is byte-exact.
	raw, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if !testing.expect(t, read_err == nil) {
		return
	}
	testing.expect_value(t, string(raw), log_bytes)

	// ...and the production on-disk reader parses it to the identical snapshots.
	log, ok, io_ok := read_replay_file(path, context.temp_allocator)
	if !testing.expect(t, io_ok) {
		return
	}
	if !testing.expect(t, ok) {
		return
	}
	// Temp-allocated; reclaimed at the test boundary.
	if !testing.expect_value(t, len(log.snapshots), len(stream)) {
		return
	}
	for i in 0 ..< len(stream) {
		expect_snapshots_equal(t, log.snapshots[i], stream[i])
	}
}

@(test)
test_read_replay_file_reports_missing_file :: proc(t: ^testing.T) {
	// The on-disk reader fails closed when the file cannot be read: `io_ok` is false
	// and no partial log is returned, so the re-fold driver never re-folds bytes it
	// could not read off disk.
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
	// The production reader fails closed on a TRUNCATED log — a header that declares
	// more ticks than the bytes carry runs the cursor past the last line, which the
	// bound check refuses rather than re-folding a partial stream (§1 exact-match
	// discipline applied to the replay log). The full log re-parses cleanly; a
	// prefix cut after the ticks header does not.
	stream := synthetic_stream(context.temp_allocator)
	defer for snapshot in stream {
		delete_input(snapshot)
	}
	full := record_stream(stream[:], context.temp_allocator)

	// The full log re-parses cleanly (temp-allocated; reclaimed at the test
	// boundary).
	_, ok := read_replay(full, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}

	// A truncated log: keep the header and `[ticks N]` line but drop every tick
	// record. The parser reads the count, then fails on the first missing record.
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
	// Cut at the newline ending the `[ticks N]` line, keeping that line.
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
	// The production reader fails closed on a MALFORMED record: a button line whose
	// player ordinal is out of the P1..P4 range does not parse, so the whole log is
	// refused rather than re-folding a record with a bad key.
	malformed := "funpack-replay 1\nartifact 1 L4:pong L5:0.1.0 60 17361641481138401621\n[ticks 1]\ntick 1 0\nbutton 9 1 true false true\n"
	_, ok := read_replay(malformed, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_explicit_free_releases_log :: proc(t: ^testing.T) {
	// delete_replay_log frees exactly what read_replay allocated — every parsed
	// snapshot's tables and the snapshot slice — so a re-fold driver that owns a
	// parsed log on the default allocator can release it cleanly. The leak-checked
	// test allocator flags any table or slice the free path misses.
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
