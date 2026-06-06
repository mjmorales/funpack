// The §14 v3 binding source-form lowering proof (docs/artifact-format.md §14,
// ADR 2026-06-06-binding-source-lowering-2d-quad-and-stick): the emitter lowers
// every §23 §3 builder helper into the closed v3 source set — a key-LIST button
// source spreads into one key(…) bind per listed key (stacking, §23 §3),
// wasd() lowers to the 2D keys_quad form with the ratified
// (neg_x,pos_x,neg_y,pos_y) order, stick(Stick) records verbatim as a
// first-class 2D source, and the already-canonical 1D forms (keys_axis,
// stick_y) pass through unchanged. These are the records the runtime's
// parse_source folds — an unlowered helper or an empty source token is exactly
// the silent-input-loss bug this set closes, so never loosen the expected
// strings.
package funpack

import "core:testing"

// test_binding_calls_spreads_key_list_buttons proves the snake shape: a
// .button(P1, Move::Up, [Key::W, Key::Up]) key-list source emits one stacked
// bind per listed key, each carrying the single-code key(…) form — never one
// record with an empty source token.
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
	// Source-call order, each list element its own stacked bind (§23 §3).
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

// test_binding_calls_lowers_wasd_and_keeps_stick_2d proves the hunt shape:
// wasd() lowers to keys_quad(Key::A,Key::D,Key::W,Key::S) — the ratified
// (neg_x,pos_x,neg_y,pos_y) order, up = neg_y in the y-down draw space — and
// stick(Stick::Left) records verbatim as the first-class 2D source, never
// spread into 1D stick_x/stick_y halves.
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

// test_binding_calls_passes_canonical_1d_sources_verbatim pins the pong
// regression: the already-canonical 1D forms (keys_axis, stick_y) render
// verbatim through the lowering — the v3 set grew AROUND them, so their
// emitted spelling must not move (the pong byte-golden depends on it).
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
