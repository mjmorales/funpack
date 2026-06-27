package funpack

import "core:testing"

@(test)
test_binding_calls_spreads_key_list_buttons :: proc(t: ^testing.T) {
	source := "enum Move: Button { Up, Down }\n" +
		"fn bindings() -> Bindings {\n" +
		"  return Bindings.empty()\n" +
		"    .button(PlayerId::P1, Move::Up,   [Key::W, Key::Up])\n" +
		"    .button(PlayerId::P1, Move::Down, [Key::S, Key::Down])\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	binds := binding_calls(ast)
	testing.expect_value(t, len(binds), 4)
	if len(binds) != 4 {
		return
	}
	testing.expect_value(t, binds[0].source, "key(Key::W)")
	testing.expect_value(t, binds[0].action, "Move::Up")
	testing.expect_value(t, binds[0].player, "P1")
	testing.expect_value(t, binds[0].kind, "button")
	testing.expect_value(t, binds[1].source, "key(Key::Up)")
	testing.expect_value(t, binds[1].action, "Move::Up")
	testing.expect_value(t, binds[2].source, "key(Key::S)")
	testing.expect_value(t, binds[2].action, "Move::Down")
	testing.expect_value(t, binds[3].source, "key(Key::Down)")
	testing.expect_value(t, binds[3].action, "Move::Down")
}

@(test)
test_binding_calls_lowers_wasd_and_keeps_stick_2d :: proc(t: ^testing.T) {
	source := "enum Drive: Axis { Move }\n" +
		"fn bindings() -> Bindings {\n" +
		"  return Bindings.empty()\n" +
		"    .axis(PlayerId::P1, Drive::Move, wasd())\n" +
		"    .axis(PlayerId::P1, Drive::Move, stick(Stick::Left))\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	binds := binding_calls(ast)
	testing.expect_value(t, len(binds), 2)
	if len(binds) != 2 {
		return
	}
	testing.expect_value(t, binds[0].source, "keys_quad(Key::A,Key::D,Key::W,Key::S)")
	testing.expect_value(t, binds[0].kind, "axis")
	testing.expect_value(t, binds[0].action, "Drive::Move")
	testing.expect_value(t, binds[1].source, "stick(Stick::Left)")
	testing.expect_value(t, binds[1].kind, "axis")
}

@(test)
test_binding_calls_passes_canonical_1d_sources_verbatim :: proc(t: ^testing.T) {
	source := "enum Steer: Axis { Move }\n" +
		"fn bindings() -> Bindings {\n" +
		"  return Bindings.empty()\n" +
		"    .axis(PlayerId::P1, Steer::Move, keys_axis(Key::W, Key::S))\n" +
		"    .axis(PlayerId::P1, Steer::Move, stick_y(Stick::Left))\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	binds := binding_calls(ast)
	testing.expect_value(t, len(binds), 2)
	if len(binds) != 2 {
		return
	}
	testing.expect_value(t, binds[0].source, "keys_axis(Key::W,Key::S)")
	testing.expect_value(t, binds[1].source, "stick_y(Stick::Left)")
}

@(test)
test_binding_calls_lowers_pad_and_mouse_button_sources :: proc(t: ^testing.T) {
	source := "enum Fire: Button { Shoot, Jump }\n" +
		"fn bindings() -> Bindings {\n" +
		"  return Bindings.empty()\n" +
		"    .button(PlayerId::P1, Fire::Shoot, pad(PadButton::A))\n" +
		"    .button(PlayerId::P1, Fire::Jump,  mouse(MouseButton::Left))\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	binds := binding_calls(ast)
	testing.expect_value(t, len(binds), 2)
	if len(binds) != 2 {
		return
	}
	testing.expect_value(t, binds[0].source, "pad(PadButton::A)")
	testing.expect_value(t, binds[0].kind, "button")
	testing.expect_value(t, binds[0].action, "Fire::Shoot")
	testing.expect_value(t, binds[1].source, "mouse(MouseButton::Left)")
	testing.expect_value(t, binds[1].kind, "button")
	testing.expect_value(t, binds[1].action, "Fire::Jump")
}

@(test)
test_binding_calls_spreads_mixed_device_key_list :: proc(t: ^testing.T) {
	source := "enum Move: Button { Up }\n" +
		"fn bindings() -> Bindings {\n" +
		"  return Bindings.empty()\n" +
		"    .button(PlayerId::P1, Move::Up, [Key::W, PadButton::DpadUp])\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	binds := binding_calls(ast)
	testing.expect_value(t, len(binds), 2)
	if len(binds) != 2 {
		return
	}
	testing.expect_value(t, binds[0].source, "key(Key::W)")
	testing.expect_value(t, binds[1].source, "pad(PadButton::DpadUp)")
}

@(test)
test_binding_calls_lowers_arrows_to_arrow_keys_quad :: proc(t: ^testing.T) {
	source := "enum Drive: Axis { Move }\n" +
		"fn bindings() -> Bindings {\n" +
		"  return Bindings.empty()\n" +
		"    .axis(PlayerId::P1, Drive::Move, arrows())\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	binds := binding_calls(ast)
	testing.expect_value(t, len(binds), 1)
	if len(binds) != 1 {
		return
	}
	testing.expect_value(t, binds[0].source, "keys_quad(Key::Left,Key::Right,Key::Up,Key::Down)")
	testing.expect_value(t, binds[0].kind, "axis")
}

@(test)
test_binding_calls_lowers_dpad_to_pad_quad :: proc(t: ^testing.T) {
	source := "enum Drive: Axis { Move }\n" +
		"fn bindings() -> Bindings {\n" +
		"  return Bindings.empty()\n" +
		"    .axis(PlayerId::P1, Drive::Move, dpad())\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	binds := binding_calls(ast)
	testing.expect_value(t, len(binds), 1)
	if len(binds) != 1 {
		return
	}
	testing.expect_value(t, binds[0].source, "pad_quad(PadButton::DpadLeft,PadButton::DpadRight,PadButton::DpadUp,PadButton::DpadDown)")
	testing.expect_value(t, binds[0].kind, "axis")
}
