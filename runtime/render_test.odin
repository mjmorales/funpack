package funpack_runtime

import "core:testing"

@(private = "file")
render_dt :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

@(private = "file")
render_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = render_dt()
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
render_startup :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	return run_startup(program, base, allocator)
}

@(private = "file")
white_rect :: proc(at, size: Vec2) -> Draw_Cmd {
	return Draw_Rect{at = at, size = size, color = named_color(.White)}
}

@(private = "file")
white_text :: proc(at: Vec2, text: string) -> Draw_Cmd {
	return Draw_Text{at = at, text = text, color = named_color(.White)}
}

@(test)
test_render_committed_tick_draw_list :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := render_startup(&program, context.temp_allocator)
	dt := render_dt()

	committed := step_tick(&program, base, empty(), render_time(context.temp_allocator), context.temp_allocator)

	draw := render_version(&program, committed, empty(), render_time(context.temp_allocator), context.temp_allocator)

	ball_at := Vec2 {
		fixed_add(to_fixed(80), fixed_mul(to_fixed(70), dt)),
		fixed_add(to_fixed(60), fixed_mul(to_fixed(40), dt)),
	}
	paddle_size := Vec2{to_fixed(4), to_fixed(16)}
	ball_size := Vec2{to_fixed(3), to_fixed(3)}

	want := []Draw_Cmd {
		white_rect(Vec2{to_fixed(8), to_fixed(60)}, paddle_size),
		white_rect(Vec2{to_fixed(152), to_fixed(60)}, paddle_size),
		white_rect(ball_at, ball_size),
		white_text(Vec2{to_fixed(80), to_fixed(8)}, "0   0"),
	}

	expect_draw_list_equal(t, draw, want)
}

@(test)
test_render_paddle_move_from_input_and_dt :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := render_startup(&program, context.temp_allocator)
	dt := render_dt()

	context.allocator = context.temp_allocator
	input := with_value(empty(), .P1, ActionId(0), to_fixed(1))
	committed := step_tick(&program, base, input, render_time(context.temp_allocator), context.temp_allocator)

	draw := render_version(&program, committed, input, render_time(context.temp_allocator), context.temp_allocator)

	moved_y := fixed_clamp(
		fixed_add(to_fixed(60), fixed_mul(fixed_mul(to_fixed(1), to_fixed(90)), dt)),
		to_fixed(0),
		to_fixed(120),
	)
	testing.expect(t, moved_y != to_fixed(60))

	first, first_ok := draw_at(draw, 0)
	testing.expect(t, first_ok)
	rect, is_rect := first.(Draw_Rect)
	testing.expect(t, is_rect)
	testing.expect_value(t, rect.at, Vec2{to_fixed(8), moved_y})
	testing.expect_value(t, rect.size, Vec2{to_fixed(4), to_fixed(16)})
	testing.expect_value(t, rect.color, named_color(.White))
}

@(test)
test_render_score_text_interpolates_committed_columns :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := render_startup(&program, context.temp_allocator)
	scored := place_ball_for_render(
		&program,
		base,
		Vec2{to_fixed(200), to_fixed(60)},
		Vec2{to_fixed(70), to_fixed(40)},
	)
	committed := step_tick(&program, scored, empty(), render_time(context.temp_allocator), context.temp_allocator)

	draw := render_version(&program, committed, empty(), render_time(context.temp_allocator), context.temp_allocator)

	last, last_ok := draw_at(draw, len(draw.cmds) - 1)
	testing.expect(t, last_ok)
	text, is_text := last.(Draw_Text)
	testing.expect(t, is_text)
	testing.expect_value(t, text.text, "1   0")
	testing.expect_value(t, text.at, Vec2{to_fixed(80), to_fixed(8)})
}

@(test)
test_render_is_deterministic :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := render_startup(&program, context.temp_allocator)
	committed := step_tick(&program, base, empty(), render_time(context.temp_allocator), context.temp_allocator)

	first := render_version(&program, committed, empty(), render_time(context.temp_allocator), context.temp_allocator)
	second := render_version(&program, committed, empty(), render_time(context.temp_allocator), context.temp_allocator)
	testing.expect(t, draw_lists_equal(first, second))
}

@(test)
test_camera_record_lowers_to_draw_camera :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cam := camera_draw_record(Vec2{to_fixed(82), to_fixed(60)}, to_fixed(1), to_fixed(0))

	cmd, ok := draw_command_from_record(cam)
	testing.expect(t, ok)
	camera, is_camera := cmd.(Draw_Camera)
	testing.expect(t, is_camera)
	testing.expect_value(t, camera.at, Vec2{to_fixed(82), to_fixed(60)})
	testing.expect_value(t, camera.zoom, to_fixed(1))
	testing.expect_value(t, camera.rotation, to_fixed(0))
}

@(test)
test_camera_record_without_at_does_not_lower :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fields := make(map[string]Value, context.temp_allocator)
	fields["zoom"] = to_fixed(1)
	fields["rotation"] = to_fixed(0)
	cam := Record_Value{type_name = "Draw::Camera", fields = fields}

	_, ok := draw_command_from_record(cam)
	testing.expect(t, !ok)
}

@(private = "file")
camera_draw_record :: proc(at: Vec2, zoom, rotation: Fixed) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["at"] = at
	fields["zoom"] = zoom
	fields["rotation"] = rotation
	return Record_Value{type_name = "Draw::Camera", fields = fields}
}

@(private = "file")
color_record :: proc(case_name: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["color"] = Variant_Value{enum_type = "Color", case_name = case_name}
	return Record_Value{type_name = "Draw::Rect", fields = fields}
}

@(test)
test_record_color_lowers_new_palette_members :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cases := []struct {
		name: string,
		want: Draw_Color,
	} {
		{"Yellow", named_color(.Yellow)},
		{"Cyan", named_color(.Cyan)},
		{"Magenta", named_color(.Magenta)},
		{"Gray", named_color(.Gray)},
	}
	for c in cases {
		got, ok := record_color(color_record(c.name), "color")
		testing.expectf(t, ok, "%s must lower with ok=true", c.name)
		testing.expect_value(t, got, c.want)
	}
}

@(test)
test_record_color_absent_field_defaults_white_ok :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	rec := Record_Value{type_name = "Draw::Rect", fields = make(map[string]Value, context.temp_allocator)}
	got, ok := record_color(rec, "color")
	testing.expect(t, ok)
	testing.expect_value(t, got, named_color(.White))
}

@(test)
test_record_color_unknown_name_refuses :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	_, ok_typo := record_color(color_record("Whtie"), "color")
	testing.expect(t, !ok_typo)
	_, ok_bare_rgb := record_color(color_record("Rgb"), "color")
	testing.expect(t, !ok_bare_rgb)
	_, ok_future := record_color(color_record("Chartreuse"), "color")
	testing.expect(t, !ok_future)
}

@(test)
test_record_color_lowers_rgb_struct_variant :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	r := fixed_div(FIXED_ONE, to_fixed(4))
	g := fixed_div(FIXED_ONE, to_fixed(2))
	b := FIXED_ONE
	got, ok := record_color(rgb_color_record(r, g, b), "color")
	testing.expect(t, ok)
	testing.expect_value(t, got, rgb_color(r, g, b))

	bad := make(map[string]Value, context.temp_allocator)
	bad["r"] = r
	bad["g"] = g
	bad_rec := Record_Value{type_name = "Draw::Rect", fields = make(map[string]Value, context.temp_allocator)}
	bad_rec.fields["color"] = Record_Value{type_name = "Color::Rgb", fields = bad}
	_, bad_ok := record_color(bad_rec, "color")
	testing.expect(t, !bad_ok)
}

rgb_color_record :: proc(r, g, b: Fixed) -> Record_Value {
	rgb := make(map[string]Value, context.temp_allocator)
	rgb["r"] = r
	rgb["g"] = g
	rgb["b"] = b
	fields := make(map[string]Value, context.temp_allocator)
	fields["color"] = Record_Value{type_name = "Color::Rgb", fields = rgb}
	return Record_Value{type_name = "Draw::Rect", fields = fields}
}

@(test)
test_draw_command_unknown_color_does_not_lower :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fields := make(map[string]Value, context.temp_allocator)
	fields["at"] = Vec2{to_fixed(1), to_fixed(2)}
	fields["size"] = Vec2{to_fixed(3), to_fixed(4)}
	fields["color"] = Variant_Value{enum_type = "Color", case_name = "Rgb"}
	rec := Record_Value{type_name = "Draw::Rect", fields = fields}

	_, ok := draw_command_from_record(rec)
	testing.expect(t, !ok)

	fields["color"] = Variant_Value{enum_type = "Color", case_name = "Gray"}
	cmd, gray_ok := draw_command_from_record(rec)
	testing.expect(t, gray_ok)
	rect, is_rect := cmd.(Draw_Rect)
	testing.expect(t, is_rect)
	testing.expect_value(t, rect.color, named_color(.Gray))
}

@(test)
test_draw_sprite_lowering_and_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	hero := sprite_record("dungeon_atlas", "hero", Vec2{to_fixed(40), to_fixed(24)}, Vec2{to_fixed(16), to_fixed(16)}, "White", "None", 5)
	cmd, ok := draw_command_from_record(hero)
	testing.expect(t, ok)
	sprite, is_sprite := cmd.(Draw_Sprite)
	testing.expect(t, is_sprite)
	testing.expect_value(t, sprite.atlas, "dungeon_atlas")
	testing.expect_value(t, sprite.cell, "hero")
	testing.expect_value(t, sprite.at, Vec2{to_fixed(40), to_fixed(24)})
	testing.expect_value(t, sprite.size, Vec2{to_fixed(16), to_fixed(16)})
	testing.expect_value(t, sprite.tint, named_color(.White))
	testing.expect_value(t, sprite.flip, "None")
	testing.expect_value(t, sprite.layer, i64(5))

	handle_fields := make(map[string]Value, context.temp_allocator)
	handle_fields["name"] = String_Value{text = "dungeon_atlas"}
	hero_handle := hero
	hero_handle.fields["atlas"] = Record_Value{type_name = "AtlasHandle", fields = handle_fields}
	cmd_h, ok_h := draw_command_from_record(hero_handle)
	testing.expect(t, ok_h)
	sprite_h, is_sprite_h := cmd_h.(Draw_Sprite)
	testing.expect(t, is_sprite_h)
	testing.expect_value(t, sprite_h.atlas, "dungeon_atlas")

	bad_tint := sprite_record("dungeon_atlas", "hero", Vec2{to_fixed(40), to_fixed(24)}, Vec2{to_fixed(16), to_fixed(16)}, "Chartreuse", "None", 5)
	_, ok_tint := draw_command_from_record(bad_tint)
	testing.expect(t, !ok_tint)

	no_cell := sprite_record("dungeon_atlas", "hero", Vec2{to_fixed(40), to_fixed(24)}, Vec2{to_fixed(16), to_fixed(16)}, "White", "None", 5)
	delete_key(&no_cell.fields, "cell")
	_, ok_cell := draw_command_from_record(no_cell)
	testing.expect(t, !ok_cell)

	no_layer := sprite_record("dungeon_atlas", "hero", Vec2{to_fixed(40), to_fixed(24)}, Vec2{to_fixed(16), to_fixed(16)}, "White", "None", 5)
	delete_key(&no_layer.fields, "layer")
	_, ok_layer := draw_command_from_record(no_layer)
	testing.expect(t, !ok_layer)

	slime := sprite_record("dungeon_atlas", "slime", Vec2{to_fixed(40), to_fixed(24)}, Vec2{to_fixed(16), to_fixed(16)}, "White", "None", 4)
	hero_again, _ := draw_command_from_record(hero)
	slime_cmd, _ := draw_command_from_record(slime)
	testing.expect(t, draw_cmd_equal(cmd, hero_again))
	testing.expect(t, !draw_cmd_equal(cmd, slime_cmd))

	hero_cmd := cmd.(Draw_Sprite)
	moved := hero_cmd; moved.at = Vec2{to_fixed(41), to_fixed(24)}
	retinted := hero_cmd; retinted.tint = named_color(.Red)
	reflipped := hero_cmd; reflipped.flip = "Horizontal"
	relayered := hero_cmd; relayered.layer = 6
	reatlased := hero_cmd; reatlased.atlas = "other_atlas"
	resized := hero_cmd; resized.size = Vec2{to_fixed(32), to_fixed(16)}
	testing.expect(t, !draw_cmd_equal(cmd, moved))
	testing.expect(t, !draw_cmd_equal(cmd, retinted))
	testing.expect(t, !draw_cmd_equal(cmd, reflipped))
	testing.expect(t, !draw_cmd_equal(cmd, relayered))
	testing.expect(t, !draw_cmd_equal(cmd, reatlased))
	testing.expect(t, !draw_cmd_equal(cmd, resized))

	other_arm: Draw_Cmd = Draw_Rect{at = Vec2{to_fixed(40), to_fixed(24)}, size = Vec2{to_fixed(16), to_fixed(16)}, color = named_color(.White)}
	testing.expect(t, !draw_cmd_equal(cmd, other_arm))

	testing.expect_value(t, u8(Cmd_Tag.Sprite), 8)
	empty_version := World_Version{tick = 0, tables = nil}
	sprite_list := Draw_List{cmds = []Draw_Cmd{cmd}}
	empty_list := Draw_List{cmds = []Draw_Cmd{}}

	digest_a := frame_digest(empty_version, sprite_list).digest
	digest_b := frame_digest(empty_version, sprite_list).digest
	testing.expect_value(t, digest_b, digest_a)

	moved_list := Draw_List{cmds = []Draw_Cmd{moved}}
	testing.expect(t, frame_digest(empty_version, moved_list).digest != digest_a)

	retint_list := Draw_List{cmds = []Draw_Cmd{retinted}}
	relayer_list := Draw_List{cmds = []Draw_Cmd{relayered}}
	testing.expect(t, frame_digest(empty_version, retint_list).digest != digest_a)
	testing.expect(t, frame_digest(empty_version, relayer_list).digest != digest_a)

	testing.expect(t, digest_a != frame_digest(empty_version, empty_list).digest)

	sprite_bytes := frame_bytes(empty_version, sprite_list)
	tag_offset := 16 + 8
	testing.expect(t, len(sprite_bytes) > tag_offset)
	testing.expect_value(t, sprite_bytes[tag_offset], u8(Cmd_Tag.Sprite))

	testing.expect_value(t, FRAME_DIGEST_SCHEMA_VERSION, 11)
}

@(private = "file")
sprite_record :: proc(atlas, cell: string, at, size: Vec2, tint, flip: string, layer: i64) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["atlas"] = String_Value{text = atlas}
	fields["cell"] = String_Value{text = cell}
	fields["at"] = at
	fields["size"] = size
	fields["tint"] = Variant_Value{enum_type = "Color", case_name = tint}
	fields["flip"] = Variant_Value{enum_type = "Flip", case_name = flip}
	fields["layer"] = layer
	return Record_Value{type_name = "Draw::Sprite", fields = fields}
}

@(private = "file")
draw_at :: proc(draw: Draw_List, i: int) -> (cmd: Draw_Cmd, ok: bool) {
	if i < 0 || i >= len(draw.cmds) {
		return nil, false
	}
	return draw.cmds[i], true
}

@(private = "file")
expect_draw_list_equal :: proc(t: ^testing.T, got: Draw_List, want: []Draw_Cmd) {
	if !testing.expectf(
		t,
		len(got.cmds) == len(want),
		"draw-list length: got %d, want %d",
		len(got.cmds),
		len(want),
	) {
		return
	}
	for cmd, i in want {
		testing.expect(t, draw_cmd_equal(got.cmds[i], cmd))
	}
}

@(private = "file")
draw_lists_equal :: proc(a, b: Draw_List) -> bool {
	if len(a.cmds) != len(b.cmds) {
		return false
	}
	for cmd, i in a.cmds {
		if !draw_cmd_equal(cmd, b.cmds[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
place_ball_for_render :: proc(
	program: ^Program,
	prior: World_Version,
	pos, vel: Vec2,
	allocator := context.temp_allocator,
) -> World_Version {
	prior_version := prior
	ball, _ := view_at(view_of_type(&prior_version, "Ball"), 0)
	fields := make(map[string]Field_Value, allocator)
	fields["pos"] = pos
	fields["vel"] = vel
	rows := make([]Row, 1, allocator)
	rows[0] = Row{id = ball.id, fields = fields}
	changed := make(map[string]Version_Table, allocator)
	changed["Ball"] = Version_Table {
		thing   = "Ball",
		rows    = rows,
		next_id = Thing_Id(1),
	}
	return commit_version(prior, changed, allocator)
}

@(test)
test_render_overlay_center_anchored_extent :: proc(t: ^testing.T) {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = Vec2{to_fixed(96), to_fixed(90)}
	fields["size"] = Vec2{to_fixed(40), to_fixed(20)}
	rows := []Row{Row{id = Id{raw = 0}, fields = fields}}
	tables := []Version_Table{Version_Table{thing = "Box", rows = rows, next_id = Thing_Id(1)}}
	version := World_Version{tables = tables}

	cmds := render_overlay_commands(version, context.temp_allocator)
	testing.expect_value(t, len(cmds), 5)

	want := [][2]Vec2 {
		{Vec2{to_fixed(96), to_fixed(90)}, Vec2{to_fixed(2), to_fixed(2)}},
		{Vec2{to_fixed(96), to_fixed(80)}, Vec2{to_fixed(40), to_fixed(1)}},
		{Vec2{to_fixed(96), to_fixed(100)}, Vec2{to_fixed(40), to_fixed(1)}},
		{Vec2{to_fixed(76), to_fixed(90)}, Vec2{to_fixed(1), to_fixed(20)}},
		{Vec2{to_fixed(116), to_fixed(90)}, Vec2{to_fixed(1), to_fixed(20)}},
	}
	for w in want {
		found := false
		for cmd in cmds {
			rect, is_rect := cmd.(Draw_Rect)
			if is_rect && rect.at == w[0] && rect.size == w[1] && rect.color.palette == .Magenta {
				found = true
				break
			}
		}
		testing.expectf(t, found, "overlay must carry a magenta rect at=%v size=%v", w[0], w[1])
	}
}
