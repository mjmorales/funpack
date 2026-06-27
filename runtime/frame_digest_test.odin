package funpack_runtime

import "core:encoding/endian"
import "core:testing"

FD_STEER :: ActionId(0)

@(private = "file")
fd_dt :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

@(private = "file")
fd_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fd_dt()
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
fd_startup :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	return run_startup(program, base, allocator)
}

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
	context.allocator = context.temp_allocator

	live_program, ok := load_golden(t)
	if !ok {
		return
	}
	inputs := session_inputs()
	live := drive_capture(&live_program, inputs)

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
	context.allocator = context.temp_allocator

	program_a, ok_a := load_golden(t)
	if !ok_a {
		return
	}
	program_b, ok_b := load_golden(t)
	if !ok_b {
		return
	}
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
	context.allocator = context.temp_allocator

	forward := one_row_version(row_forward())
	reverse := one_row_version(row_reverse())

	forward_bytes := frame_bytes(forward, nil)
	reverse_bytes := frame_bytes(reverse, nil)
	testing.expect(t, slices_equal(forward_bytes, reverse_bytes))

	a := frame_digest(forward, nil)
	b := frame_digest(reverse, nil)
	testing.expect_value(t, a.digest, b.digest)
}

@(test)
test_frame_bytes_encode_fixed_as_raw_bits_no_float :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	value := fixed_from_decimal(1, "5")
	fields := make(map[string]Field_Value)
	fields["v"] = value
	row := Row{id = Id{raw = Thing_Id(0)}, fields = fields}
	version := one_row_version(row)

	bytes := frame_bytes(version, nil)

	fixed_le: [8]u8
	_ = endian.put_u64(fixed_le[:], .Little, u64(i64(value)))
	testing.expect(t, contains_subsequence(bytes, fixed_le[:]))

	float_le: [8]u8
	_ = endian.put_u64(float_le[:], .Little, transmute(u64)f64(1.5))
	testing.expect(t, !contains_subsequence(bytes, float_le[:]))
}

@(test)
test_draw_list_serializes_in_emitted_order :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	empty_version := World_Version{tick = 0, tables = nil}
	r1 := Draw_Rect{at = Vec2{to_fixed(8), to_fixed(60)}, size = Vec2{to_fixed(4), to_fixed(16)}, color = named_color(.White)}
	r2 := Draw_Rect{at = Vec2{to_fixed(152), to_fixed(60)}, size = Vec2{to_fixed(4), to_fixed(16)}, color = named_color(.White)}

	forward := Draw_List{cmds = []Draw_Cmd{r1, r2}}
	reverse := Draw_List{cmds = []Draw_Cmd{r2, r1}}

	forward_bytes := frame_bytes(empty_version, forward)
	reverse_bytes := frame_bytes(empty_version, reverse)
	testing.expect(t, !slices_equal(forward_bytes, reverse_bytes))

	again := frame_bytes(empty_version, forward)
	testing.expect(t, slices_equal(forward_bytes, again))
}

@(test)
test_draw_color_ordinals_are_append_stable :: proc(t: ^testing.T) {
	testing.expect_value(t, u8(Draw_Palette.White), 0)
	testing.expect_value(t, u8(Draw_Palette.Black), 1)
	testing.expect_value(t, u8(Draw_Palette.Red), 2)
	testing.expect_value(t, u8(Draw_Palette.Green), 3)
	testing.expect_value(t, u8(Draw_Palette.Blue), 4)
	testing.expect_value(t, u8(Draw_Palette.Yellow), 5)
	testing.expect_value(t, u8(Draw_Palette.Cyan), 6)
	testing.expect_value(t, u8(Draw_Palette.Magenta), 7)
	testing.expect_value(t, u8(Draw_Palette.Gray), 8)
	testing.expect(t, u64(RGB_COLOR_TAG) > u64(Draw_Palette.Gray))
}

@(test)
test_digest_distinguishes_palette_members :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	empty_version := World_Version{tick = 0, tables = nil}
	at := Vec2{to_fixed(8), to_fixed(60)}
	size := Vec2{to_fixed(4), to_fixed(16)}

	members := []Draw_Palette {
		.White, .Black, .Red, .Green, .Blue, .Yellow, .Cyan, .Magenta, .Gray,
	}
	seen := make(map[u64]bool, context.temp_allocator)
	for palette in members {
		list := Draw_List{cmds = []Draw_Cmd{Draw_Rect{at = at, size = size, color = named_color(palette)}}}
		d := frame_digest(empty_version, list).digest
		testing.expectf(t, !seen[d], "palette member %v digest collided", palette)
		seen[d] = true
	}
	testing.expect_value(t, len(seen), len(members))
}

@(test)
test_digest_folds_rgb_color_stably_and_distinctly :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	empty_version := World_Version{tick = 0, tables = nil}
	at := Vec2{to_fixed(8), to_fixed(60)}
	size := Vec2{to_fixed(4), to_fixed(16)}

	r := fixed_div(FIXED_ONE, to_fixed(4))
	g := fixed_div(FIXED_ONE, to_fixed(2))
	b := fixed_div(to_fixed(3), to_fixed(4))

	rect_digest :: proc(version: World_Version, at, size: Vec2, color: Draw_Color) -> u64 {
		cmds := make([]Draw_Cmd, 1, context.temp_allocator)
		cmds[0] = Draw_Rect{at = at, size = size, color = color}
		return frame_digest(version, Draw_List{cmds = cmds}).digest
	}

	base := rect_digest(empty_version, at, size, rgb_color(r, g, b))
	again := rect_digest(empty_version, at, size, rgb_color(r, g, b))
	testing.expect_value(t, again, base)

	moved := rect_digest(empty_version, at, size, rgb_color(r, g, g))
	testing.expect(t, moved != base)

	gray := rect_digest(empty_version, at, size, named_color(.Gray))
	testing.expect(t, base != gray)
	white := rect_digest(empty_version, at, size, named_color(.White))
	testing.expect(t, base != white)
}

@(private = "file")
fd_payload_world :: proc(status_text: string, note_text: string) -> World_Version {
	payload := new(Value, context.temp_allocator)
	payload^ = String_Value{text = status_text}

	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["status"] = Variant_Value{enum_type = "Option", case_name = "Some", payload = payload}
	fields["note"] = String_Value{text = note_text}

	rows := make([]Row, 1, context.temp_allocator)
	rows[0] = Row{id = Id{raw = 1}, fields = fields}
	tables := make([]Version_Table, 1, context.temp_allocator)
	tables[0] = Version_Table{thing = "Menu", singleton = true, rows = rows, next_id = 2}
	return World_Version{tick = 1, tables = tables}
}

@(test)
test_digest_distinguishes_variant_payloads :: proc(t: ^testing.T) {
	saved := frame_digest(fd_payload_world("saved", "x"), nil)
	restored := frame_digest(fd_payload_world("restored", "x"), nil)
	saved_again := frame_digest(fd_payload_world("saved", "x"), nil)

	testing.expect(t, saved.digest != restored.digest)
	testing.expect_value(t, saved_again.digest, saved.digest)
}

@(test)
test_digest_distinguishes_string_columns :: proc(t: ^testing.T) {
	a := frame_digest(fd_payload_world("saved", "alpha"), nil)
	b := frame_digest(fd_payload_world("saved", "beta"), nil)
	testing.expect(t, a.digest != b.digest)
}

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
