package funpack_runtime

import "core:testing"

@(private = "file")
steer_move_id :: proc(t: ^testing.T, registry: Action_Registry) -> (id: ActionId, ok: bool) {
	def, found := registry_find_token(registry, "Steer::Move")
	if !testing.expect(t, found) {
		return {}, false
	}
	if !testing.expect_value(t, def.kind, Action_Kind.Axis) {
		return {}, false
	}
	return def.id, true
}

@(private = "file")
button_program :: proc(allocator := context.allocator) -> Program {
	variants := make([]Enum_Variant, 1, allocator)
	variants[0] = Enum_Variant{name = "Fire", payload = "unit"}
	enums := make([]Enum_Decl, 1, allocator)
	enums[0] = Enum_Decl{name = "Trigger", kind = .Button, variants = variants}
	bindings := make([]Binding, 1, allocator)
	bindings[0] = Binding {
		kind   = "button",
		player = "P1",
		action = "Trigger::Fire",
		source = "key(Key::Space)",
	}
	return Program{enums = enums, bindings = bindings}
}

@(test)
test_keys_axis_w_resolves_negative :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	enqueue_key_down(&queue, "Key::W")
	snap_w, held_w, levels_w := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_w)
	testing.expect_value(t, value(snap_w, .P1, steer), fixed_neg(to_fixed(1)))

	enqueue_key_up(&queue, "Key::W")
	enqueue_key_down(&queue, "Key::S")
	snap_s, _, _ := resolve_tick(table, &queue, held_w, levels_w, context.temp_allocator)
	defer delete_input(snap_s)
	testing.expect_value(t, value(snap_s, .P1, steer), to_fixed(1))
}

@(test)
test_pong_steer_move_in_unit_range :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	enqueue_key_down(&queue, "Key::Up")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, fixed_neg(to_fixed(5)))
	snap, _, _ := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap)

	v := value(snap, .P2, steer)
	testing.expect(t, v >= fixed_neg(to_fixed(1)))
	testing.expect(t, v <= to_fixed(1))
	testing.expect_value(t, v, fixed_neg(to_fixed(1)))
}

@(test)
test_stacked_keyboard_and_stick_both_contribute :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	half := fixed_from_decimal(0, "5")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, half)
	snap, _, _ := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap)
	testing.expect_value(t, value(snap, .P1, steer), half)
}

@(test)
test_deadzone_clamps_tiny_and_out_of_range :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	tiny := fixed_from_decimal(0, "05")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, tiny)
	snap_tiny, held_tiny, levels_tiny := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_tiny)
	testing.expect_value(t, value(snap_tiny, .P1, steer), Fixed(0))

	enqueue_stick_sample(&queue, "Stick::Left", .Y, to_fixed(3))
	snap_hi, _, _ := resolve_tick(table, &queue, held_tiny, levels_tiny, context.temp_allocator)
	defer delete_input(snap_hi)
	testing.expect_value(t, value(snap_hi, .P1, steer), to_fixed(1))
}

@(test)
test_button_tap_within_window_registers_pressed :: proc(t: ^testing.T) {
	program := button_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	fire, found := registry_find_token(table.registry, "Trigger::Fire")
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	enqueue_key_down(&queue, "Key::Space")
	enqueue_key_up(&queue, "Key::Space")
	snap, _, _ := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap)
	testing.expect(t, pressed(snap, .P1, fire.id))
	testing.expect(t, !held(snap, .P1, fire.id))
}

@(test)
test_button_release_edge_after_hold :: proc(t: ^testing.T) {
	program := button_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	fire, found := registry_find_token(table.registry, "Trigger::Fire")
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	enqueue_key_down(&queue, "Key::Space")
	snap1, held1, levels1 := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap1)
	testing.expect(t, pressed(snap1, .P1, fire.id))
	testing.expect(t, held(snap1, .P1, fire.id))
	testing.expect(t, !released(snap1, .P1, fire.id))

	enqueue_key_up(&queue, "Key::Space")
	snap2, _, _ := resolve_tick(table, &queue, held1, levels1, context.temp_allocator)
	defer delete_input(snap2)
	testing.expect(t, released(snap2, .P1, fire.id))
	testing.expect(t, !pressed(snap2, .P1, fire.id))
	testing.expect(t, !held(snap2, .P1, fire.id))
}

@(test)
test_held_key_persists_across_eventless_window :: proc(t: ^testing.T) {
	program := button_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	fire, found := registry_find_token(table.registry, "Trigger::Fire")
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	enqueue_key_down(&queue, "Key::Space")
	snap_n, held_n, levels_n := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_n)
	testing.expect(t, pressed(snap_n, .P1, fire.id))
	testing.expect(t, held(snap_n, .P1, fire.id))
	testing.expect(t, !released(snap_n, .P1, fire.id))

	snap_n1, _, _ := resolve_tick(table, &queue, held_n, levels_n, context.temp_allocator)
	defer delete_input(snap_n1)
	testing.expect(t, held(snap_n1, .P1, fire.id))
	testing.expect(t, !pressed(snap_n1, .P1, fire.id))
	testing.expect(t, !released(snap_n1, .P1, fire.id))
}

@(test)
test_held_keys_axis_value_persists_at_rail :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	enqueue_key_down(&queue, "Key::W")
	snap_n, held_n, levels_n := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_n)
	testing.expect_value(t, value(snap_n, .P1, steer), fixed_neg(to_fixed(1)))

	snap_n1, held_n1, levels_n1 := resolve_tick(table, &queue, held_n, levels_n, context.temp_allocator)
	defer delete_input(snap_n1)
	testing.expect_value(t, value(snap_n1, .P1, steer), fixed_neg(to_fixed(1)))

	enqueue_key_up(&queue, "Key::W")
	snap_n2, _, _ := resolve_tick(table, &queue, held_n1, levels_n1, context.temp_allocator)
	defer delete_input(snap_n2)
	testing.expect_value(t, value(snap_n2, .P1, steer), Fixed(0))
}

@(test)
test_stick_sample_persists_across_eventless_window :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	half := fixed_from_decimal(0, "5")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, half)
	snap_n, held_n, levels_n := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_n)
	testing.expect_value(t, value(snap_n, .P1, steer), half)

	snap_n1, _, _ := resolve_tick(table, &queue, held_n, levels_n, context.temp_allocator)
	defer delete_input(snap_n1)
	testing.expect_value(t, value(snap_n1, .P1, steer), half)
}

@(private = "file")
axis2d_program :: proc(allocator := context.allocator) -> Program {
	variants := make([]Enum_Variant, 1, allocator)
	variants[0] = Enum_Variant{name = "Move", payload = "unit"}
	enums := make([]Enum_Decl, 1, allocator)
	enums[0] = Enum_Decl{name = "Drive", kind = .Axis, variants = variants}
	bindings := make([]Binding, 2, allocator)
	bindings[0] = Binding {
		kind   = "axis",
		player = "P1",
		action = "Drive::Move",
		source = "keys_quad(Key::A,Key::D,Key::W,Key::S)",
	}
	bindings[1] = Binding {
		kind   = "axis",
		player = "P1",
		action = "Drive::Move",
		source = "stick(Stick::Left)",
	}
	return Program{enums = enums, bindings = bindings}
}

@(private = "file")
pad_quad_program :: proc(allocator := context.allocator) -> Program {
	variants := make([]Enum_Variant, 1, allocator)
	variants[0] = Enum_Variant{name = "Move", payload = "unit"}
	enums := make([]Enum_Decl, 1, allocator)
	enums[0] = Enum_Decl{name = "Drive", kind = .Axis, variants = variants}
	bindings := make([]Binding, 1, allocator)
	bindings[0] = Binding {
		kind   = "axis",
		player = "P1",
		action = "Drive::Move",
		source = "pad_quad(PadButton::DpadLeft,PadButton::DpadRight,PadButton::DpadUp,PadButton::DpadDown)",
	}
	return Program{enums = enums, bindings = bindings}
}

@(test)
test_keys_quad_resolves_components :: proc(t: ^testing.T) {
	program := axis2d_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	drive, found := registry_find_token(table.registry, "Drive::Move")
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	enqueue_key_down(&queue, "Key::W")
	snap_w, held_w, levels_w := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_w)
	testing.expect_value(t, axis(snap_w, .P1, drive.id), Vec2{Fixed(0), fixed_neg(to_fixed(1))})

	enqueue_key_down(&queue, "Key::D")
	snap_wd, held_wd, levels_wd := resolve_tick(table, &queue, held_w, levels_w, context.temp_allocator)
	defer delete_input(snap_wd)
	testing.expect_value(t, axis(snap_wd, .P1, drive.id), Vec2{to_fixed(1), fixed_neg(to_fixed(1))})

	enqueue_key_down(&queue, "Key::S")
	snap_ws, _, _ := resolve_tick(table, &queue, held_wd, levels_wd, context.temp_allocator)
	defer delete_input(snap_ws)
	testing.expect_value(t, axis(snap_ws, .P1, drive.id), Vec2{to_fixed(1), Fixed(0)})
}

@(test)
test_pad_quad_resolves_components :: proc(t: ^testing.T) {
	program := pad_quad_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	drive, found := registry_find_token(table.registry, "Drive::Move")
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	enqueue_pad_down(&queue, "PadButton::DpadUp")
	snap_u, held_u, levels_u := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_u)
	testing.expect_value(t, axis(snap_u, .P1, drive.id), Vec2{Fixed(0), fixed_neg(to_fixed(1))})

	enqueue_pad_down(&queue, "PadButton::DpadRight")
	snap_ur, held_ur, levels_ur := resolve_tick(table, &queue, held_u, levels_u, context.temp_allocator)
	defer delete_input(snap_ur)
	testing.expect_value(t, axis(snap_ur, .P1, drive.id), Vec2{to_fixed(1), fixed_neg(to_fixed(1))})

	enqueue_pad_down(&queue, "PadButton::DpadDown")
	snap_ud, _, _ := resolve_tick(table, &queue, held_ur, levels_ur, context.temp_allocator)
	defer delete_input(snap_ud)
	testing.expect_value(t, axis(snap_ud, .P1, drive.id), Vec2{to_fixed(1), Fixed(0)})
}

@(test)
test_stick_2d_resolves_both_components :: proc(t: ^testing.T) {
	program := axis2d_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	drive, found := registry_find_token(table.registry, "Drive::Move")
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	half := fixed_from_decimal(0, "5")
	enqueue_stick_sample(&queue, "Stick::Left", .X, half)
	enqueue_stick_sample(&queue, "Stick::Left", .Y, fixed_neg(to_fixed(1)))
	snap, held_n, levels_n := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap)
	testing.expect_value(t, axis(snap, .P1, drive.id), Vec2{half, fixed_neg(to_fixed(1))})

	tiny := fixed_from_decimal(0, "05")
	enqueue_stick_sample(&queue, "Stick::Left", .X, tiny)
	snap_dz, _, _ := resolve_tick(table, &queue, held_n, levels_n, context.temp_allocator)
	defer delete_input(snap_dz)
	testing.expect_value(t, axis(snap_dz, .P1, drive.id), Vec2{Fixed(0), fixed_neg(to_fixed(1))})
}

@(test)
test_stacked_quad_and_stick_sum_per_component :: proc(t: ^testing.T) {
	program := axis2d_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	drive, found := registry_find_token(table.registry, "Drive::Move")
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	half := fixed_from_decimal(0, "5")
	enqueue_key_down(&queue, "Key::W")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, fixed_neg(half))
	snap, _, _ := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap)
	testing.expect_value(t, axis(snap, .P1, drive.id), Vec2{Fixed(0), fixed_neg(to_fixed(1))})
}

@(test)
test_parse_source_v3_forms :: proc(t: ^testing.T) {
	quad, quad_ok := parse_source("keys_quad(Key::A,Key::D,Key::W,Key::S)", context.temp_allocator)
	testing.expect(t, quad_ok)
	testing.expect_value(t, quad.kind, Source_Kind.Keys_Quad)
	testing.expect_value(t, quad.neg_code, "Key::A")
	testing.expect_value(t, quad.pos_code, "Key::D")
	testing.expect_value(t, quad.neg_y_code, "Key::W")
	testing.expect_value(t, quad.pos_y_code, "Key::S")

	stick, stick_ok := parse_source("stick(Stick::Left)", context.temp_allocator)
	testing.expect(t, stick_ok)
	testing.expect_value(t, stick.kind, Source_Kind.Stick)
	testing.expect_value(t, stick.code, "Stick::Left")

	pad_quad, pad_quad_ok := parse_source(
		"pad_quad(PadButton::DpadLeft,PadButton::DpadRight,PadButton::DpadUp,PadButton::DpadDown)",
		context.temp_allocator,
	)
	testing.expect(t, pad_quad_ok)
	testing.expect_value(t, pad_quad.kind, Source_Kind.Pad_Quad)
	testing.expect_value(t, pad_quad.neg_code, "PadButton::DpadLeft")
	testing.expect_value(t, pad_quad.pos_code, "PadButton::DpadRight")
	testing.expect_value(t, pad_quad.neg_y_code, "PadButton::DpadUp")
	testing.expect_value(t, pad_quad.pos_y_code, "PadButton::DpadDown")

	_, bad_arity := parse_source("keys_quad(Key::A,Key::D)", context.temp_allocator)
	testing.expect(t, !bad_arity)
	_, bad_pad_quad_arity := parse_source("pad_quad(PadButton::DpadLeft,PadButton::DpadRight)", context.temp_allocator)
	testing.expect(t, !bad_pad_quad_arity)
	_, unknown := parse_source("wasd()", context.temp_allocator)
	testing.expect(t, !unknown)
}

@(test)
test_parse_source_digital_button_forms :: proc(t: ^testing.T) {
	pad, pad_ok := parse_source("pad(PadButton::A)", context.temp_allocator)
	testing.expect(t, pad_ok)
	testing.expect_value(t, pad.kind, Source_Kind.Pad)
	testing.expect_value(t, pad.code, "PadButton::A")

	mouse, mouse_ok := parse_source("mouse(MouseButton::Left)", context.temp_allocator)
	testing.expect(t, mouse_ok)
	testing.expect_value(t, mouse.kind, Source_Kind.Mouse)
	testing.expect_value(t, mouse.code, "MouseButton::Left")

	_, bad_arity := parse_source("mouse(MouseButton::Left,MouseButton::Right)", context.temp_allocator)
	testing.expect(t, !bad_arity)
}

@(private = "file")
mouse_button_program :: proc(allocator := context.allocator) -> Program {
	variants := make([]Enum_Variant, 1, allocator)
	variants[0] = Enum_Variant{name = "Fire", payload = "unit"}
	enums := make([]Enum_Decl, 1, allocator)
	enums[0] = Enum_Decl{name = "Trigger", kind = .Button, variants = variants}
	bindings := make([]Binding, 1, allocator)
	bindings[0] = Binding {
		kind   = "button",
		player = "P1",
		action = "Trigger::Fire",
		source = "mouse(MouseButton::Left)",
	}
	return Program{enums = enums, bindings = bindings}
}

@(test)
test_mouse_button_resolves_pressed_held_released :: proc(t: ^testing.T) {
	program := mouse_button_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	fire, found := registry_find_token(table.registry, "Trigger::Fire")
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	enqueue_mouse_down(&queue, "MouseButton::Left")
	snap1, held1, levels1 := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap1)
	testing.expect(t, pressed(snap1, .P1, fire.id))
	testing.expect(t, held(snap1, .P1, fire.id))
	testing.expect(t, !released(snap1, .P1, fire.id))

	enqueue_mouse_up(&queue, "MouseButton::Left")
	snap2, _, _ := resolve_tick(table, &queue, held1, levels1, context.temp_allocator)
	defer delete_input(snap2)
	testing.expect(t, released(snap2, .P1, fire.id))
	testing.expect(t, !pressed(snap2, .P1, fire.id))
	testing.expect(t, !held(snap2, .P1, fire.id))
}

@(test)
test_action_registry_skips_non_input_enums :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	registry := build_action_registry(program, context.temp_allocator)
	_, has_steer := registry_find_token(registry, "Steer::Move")
	testing.expect(t, has_steer)
	_, has_side := registry_find_token(registry, "Side::Left")
	testing.expect(t, !has_side)
	testing.expect_value(t, len(registry.defs), 1)
}
