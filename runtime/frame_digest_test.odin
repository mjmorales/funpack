// Frame-digest acceptance (spec §20, §28, §10.5): the deterministic per-tick
// frame digest is the comparison surface two runs are checked equal against.
// These tests prove the four load-bearing properties the acceptance harness rests
// on:
//
//   - RE-FOLD IDENTITY: a live golden pong session and a re-fold of its RECORDED
//     input log produce bit-identical per-tick AND session digests — the digest
//     depends on the committed state, not on how the tick loop was driven;
//   - STABILITY: digesting the same captured frame sequence twice yields
//     byte-identical per-tick and session digests (the digest is a pure content
//     hash, no wall-clock, no run-to-run state);
//   - ORDER-STABILITY: re-emitting a frame whose row blackboard columns were
//     inserted in a DIFFERENT map order produces the IDENTICAL canonical bytes —
//     the serializer sorts field names, never leaking Odin's unspecified map
//     iteration order; and a draw-list serializes in its emitted order;
//   - NO FLOAT: the canonical frame bytes are raw fixed-width little-endian
//     fixed-point — a known Fixed column encodes to exactly its Q32.32 i64 bits,
//     never a float byte pattern (§10: no float in the determinism path).
package funpack_runtime

import "core:encoding/endian"
import "core:testing"

// FD_STEER is pong's Steer::Move axis action id (the sole Axis variant, ActionId
// 0 — the same stand-in the render tests drive a paddle with). The digest tests
// drive an input-shaped session through it so the committed state actually evolves
// tick to tick, making the per-tick digests distinct.
FD_STEER :: ActionId(0)

// fd_dt is the fixed 60hz step the Time resource carries each tick: 1/60 in
// Q32.32 through the kernel — the same dt the fold and the render projection
// advance by, no float.
@(private = "file")
fd_dt :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

// fd_time is the Time resource the fold and the render pass read: the one `dt`
// field at the fixed 60hz step.
@(private = "file")
fd_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fd_dt()
	return Record_Value{type_name = "Time", fields = fields}
}

// fd_startup runs setup's [Spawn] batch against the empty initial version,
// returning the populated base tick 0 reads.
@(private = "file")
fd_startup :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	return run_startup(program, base, allocator)
}

// drive_capture drives a golden pong session over an ordered input sequence and
// returns the finished Frame_Capture: it steps the tick loop once per supplied
// snapshot, capturing each committed tick's digest over the world state AND its
// §20 draw-list, then folds the session digest. This is the headless capture
// shape a live run and a re-fold both drive — the only difference between two
// captures is the committed state each step produced, never how it was captured.
@(private = "file")
drive_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	version := fd_startup(program, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version = step_tick(program, version, input, fd_time(allocator), allocator)
		draw := render_version(program, version, input, fd_time(allocator), allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

// session_inputs builds a fixed multi-tick input sequence for the golden pong
// program: a few ticks holding P1's steer axis at +1 then a few at -1, so the
// paddle (and the free-running ball) move every tick and the per-tick digests
// differ. The same sequence drives both the live run and, after recording, the
// re-fold — so the two captures must agree.
@(private = "file")
session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, 6, allocator)
	for i in 0 ..< 6 {
		dir := i < 3 ? to_fixed(1) : fixed_neg(to_fixed(1))
		inputs[i] = with_value(empty(), .P1, FD_STEER, dir)
	}
	return inputs
}

@(test)
test_recorded_session_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	// A recorded pong session and a re-fold of its RECORDED input log produce
	// bit-identical per-tick and session digests (§23 §4, §20): the digest reads
	// the committed state, so a live run and a re-fold that re-feeds the same
	// recorded snapshots commit the same versions and therefore digest identically.
	context.allocator = context.temp_allocator

	live_program, ok := load_golden(t)
	if !ok {
		return
	}
	inputs := session_inputs()
	live := drive_capture(&live_program, inputs)

	// Record exactly the snapshots the live run was driven by, then read them back
	// through the production parser — the re-fold re-feeds these parsed snapshots.
	identity := identity_from_program(live_program, GOLDEN_ARTIFACT)
	writer := open_replay_writer(identity)
	for input in inputs {
		record_tick(&writer, input)
	}
	log_bytes := finish_replay(&writer)

	log, read_ok := read_replay(log_bytes)
	if !testing.expect(t, read_ok) {
		return
	}

	// Re-fold against a FRESH program load, driven only by the parsed log — no
	// reference to the live run's state.
	refold_program, refold_ok := load_golden(t)
	if !refold_ok {
		return
	}
	refold := drive_capture(&refold_program, log.snapshots)

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
test_digesting_same_session_twice_is_byte_identical :: proc(t: ^testing.T) {
	// Digesting the same driven session twice yields byte-identical per-tick and
	// session digests — the digest is a pure content hash with no run-to-run state
	// and no wall-clock (the stability invariant §10.5). Two captures of the same
	// program from the same inputs must match digest-for-digest.
	context.allocator = context.temp_allocator

	program_a, ok_a := load_golden(t)
	if !ok_a {
		return
	}
	program_b, ok_b := load_golden(t)
	if !ok_b {
		return
	}
	first := drive_capture(&program_a, session_inputs())
	second := drive_capture(&program_b, session_inputs())

	if !testing.expect_value(t, len(first.per_tick), len(second.per_tick)) {
		return
	}
	for frame, i in first.per_tick {
		testing.expect_value(t, second.per_tick[i].digest, frame.digest)
	}
	testing.expect_value(t, second.session, first.session)
}

@(test)
test_session_digest_distinguishes_different_runs :: proc(t: ^testing.T) {
	// The session digest is a faithful summary: two runs whose committed state
	// diverges (different driving input) produce different session digests, so the
	// digest cannot silently report two divergent runs as equal. A digest that
	// ignored the state would collide here.
	context.allocator = context.temp_allocator

	program_a, ok_a := load_golden(t)
	if !ok_a {
		return
	}
	program_b, ok_b := load_golden(t)
	if !ok_b {
		return
	}
	// One run holds the paddle, the other runs over empty input — the paddle's
	// committed position diverges, so the captures must not collide.
	held := make([]Input, 4, context.temp_allocator)
	for i in 0 ..< 4 {
		held[i] = with_value(empty(), .P1, FD_STEER, to_fixed(1))
	}
	idle := make([]Input, 4, context.temp_allocator)
	for i in 0 ..< 4 {
		idle[i] = empty()
	}

	moving := drive_capture(&program_a, held)
	still := drive_capture(&program_b, idle)
	testing.expect(t, moving.session != still.session)
}

// --- canonical-encoding tests (no float, order-stable) ----------------------

// row_forward / row_reverse build the SAME logical thing instance — one Fixed
// column and one Int column with identical values — but insert the two columns
// into the blackboard map in OPPOSITE orders. Odin leaves map iteration order
// unspecified, so a serializer that walked the map directly could emit different
// bytes for these two; the sorted-field-name discipline must collapse them.
@(private = "file")
row_forward :: proc(allocator := context.allocator) -> Row {
	fields := make(map[string]Field_Value, allocator)
	fields["pos"] = Vec2{to_fixed(8), to_fixed(60)}
	fields["score"] = i64(3)
	return Row{id = Id{raw = Thing_Id(0)}, fields = fields}
}

@(private = "file")
row_reverse :: proc(allocator := context.allocator) -> Row {
	fields := make(map[string]Field_Value, allocator)
	fields["score"] = i64(3)
	fields["pos"] = Vec2{to_fixed(8), to_fixed(60)}
	return Row{id = Id{raw = Thing_Id(0)}, fields = fields}
}

// one_row_version wraps a single row in a one-table committed version — the
// minimal frame the canonical-encoding tests serialize, with no draw-list, so the
// assertion isolates the world-state field-order behavior.
@(private = "file")
one_row_version :: proc(row: Row, allocator := context.allocator) -> World_Version {
	rows := make([]Row, 1, allocator)
	rows[0] = row
	tables := make([]Version_Table, 1, allocator)
	tables[0] = Version_Table{thing = "Paddle", rows = rows, next_id = Thing_Id(1)}
	return World_Version{tick = 0, tables = tables}
}

@(test)
test_frame_bytes_are_order_stable_across_field_insertion :: proc(t: ^testing.T) {
	// Re-emitting a frame whose row columns were inserted in a different map order
	// produces the IDENTICAL canonical bytes (the order-stability the determinism
	// assertion rests on): the serializer sorts field names, so the bytes depend on
	// the row's CONTENT, not on how the blackboard map was assembled.
	context.allocator = context.temp_allocator

	forward := one_row_version(row_forward())
	reverse := one_row_version(row_reverse())

	forward_bytes := frame_bytes(forward, nil)
	reverse_bytes := frame_bytes(reverse, nil)
	testing.expect(t, slices_equal(forward_bytes, reverse_bytes))

	// And the digest collapses the two identically — the per-tick digest of two
	// insertion-orderings of the same state is one value.
	a := frame_digest(forward, nil)
	b := frame_digest(reverse, nil)
	testing.expect_value(t, a.digest, b.digest)
}

@(test)
test_frame_bytes_encode_fixed_as_raw_bits_no_float :: proc(t: ^testing.T) {
	// The canonical bytes are raw fixed-width little-endian fixed-point: a Fixed
	// column encodes to exactly its Q32.32 i64 bits — never a float byte pattern
	// (§10: no float in the determinism path). Encode a frame carrying one Fixed
	// column at a value whose float and fixed-point representations differ, and
	// confirm the frame bytes contain the RAW Q32.32 bits and NOT the IEEE-754
	// double bits of the same magnitude.
	context.allocator = context.temp_allocator

	value := fixed_from_decimal(1, "5") // 1.5 in Q32.32 — bits 0x0000_0001_8000_0000
	fields := make(map[string]Field_Value)
	fields["v"] = value
	row := Row{id = Id{raw = Thing_Id(0)}, fields = fields}
	version := one_row_version(row)

	bytes := frame_bytes(version, nil)

	// The raw Q32.32 little-endian bits of 1.5 must appear verbatim in the stream.
	fixed_le: [8]u8
	_ = endian.put_u64(fixed_le[:], .Little, u64(i64(value)))
	testing.expect(t, contains_subsequence(bytes, fixed_le[:]))

	// The IEEE-754 double bits of 1.5 (0x3FF8_0000_0000_0000) must NOT appear — a
	// serializer that wrote a float would leak exactly these bytes.
	float_le: [8]u8
	_ = endian.put_u64(float_le[:], .Little, transmute(u64)f64(1.5))
	testing.expect(t, !contains_subsequence(bytes, float_le[:]))
}

@(test)
test_draw_list_serializes_in_emitted_order :: proc(t: ^testing.T) {
	// The draw-list serializes in the order the render stage emitted it — the
	// canonical order IS the emit order (flattened-pipeline + stable-Id, §20). Two
	// draw-lists with the SAME commands in a DIFFERENT order produce DIFFERENT
	// bytes, so the digest is sensitive to render ordering, never collapsing a
	// reordered draw-list to the same frame.
	context.allocator = context.temp_allocator

	empty_version := World_Version{tick = 0, tables = nil}
	r1 := Draw_Rect{at = Vec2{to_fixed(8), to_fixed(60)}, size = Vec2{to_fixed(4), to_fixed(16)}, color = .White}
	r2 := Draw_Rect{at = Vec2{to_fixed(152), to_fixed(60)}, size = Vec2{to_fixed(4), to_fixed(16)}, color = .White}

	forward := Draw_List{cmds = []Draw_Cmd{r1, r2}}
	reverse := Draw_List{cmds = []Draw_Cmd{r2, r1}}

	forward_bytes := frame_bytes(empty_version, forward)
	reverse_bytes := frame_bytes(empty_version, reverse)
	testing.expect(t, !slices_equal(forward_bytes, reverse_bytes))

	// The same draw-list serialized twice is byte-identical (stability).
	again := frame_bytes(empty_version, forward)
	testing.expect(t, slices_equal(forward_bytes, again))
}

// --- byte helpers -----------------------------------------------------------

// slices_equal reports whether two byte slices are length- and content-equal —
// the exact-equality the canonical-encoding assertions read.
@(private = "file")
slices_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for v, i in a {
		if b[i] != v {
			return false
		}
	}
	return true
}

// contains_subsequence reports whether `needle` appears as a contiguous run in
// `haystack` — the search the no-float test uses to confirm the raw fixed-point
// bits are present and the float bits are absent.
@(private = "file")
contains_subsequence :: proc(haystack, needle: []u8) -> bool {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return false
	}
	for start in 0 ..= len(haystack) - len(needle) {
		match := true
		for k in 0 ..< len(needle) {
			if haystack[start + k] != needle[k] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
