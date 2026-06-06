// Proof for the live session DRIVER's pure helpers — the device-pure transforms
// the when-gated SDL driver leans on that compile in every build (the SDL window
// loop itself is when-gated live code, excluded from this deterministic suite).
// The driver's only deterministically-testable surfaces are the replay out-path
// derivation and the Draw_Text glyph-run layout; both are pure string/geometry
// transforms with no SDL and no clock, so this headless suite pins their exact
// rails the same way session_live_test.odin pins the projection helpers. The loop,
// pacing, present, and exit are operator-gated (a window must open) and proven by
// replay_acceptance_test's live-vs-replay digest identity.
package funpack_runtime

import "core:testing"

// test_replay_out_path_swaps_extension pins the default derivation: an artifact
// path with an extension yields `<stem>.replay` in the SAME directory, so the log
// lands beside the artifact it was recorded against. This is the os.args[2]-absent
// default the driver writes to.
@(test)
test_replay_out_path_swaps_extension :: proc(t: ^testing.T) {
	out := replay_out_path("testdata/pong.artifact", "", context.temp_allocator)
	testing.expect_value(t, out, "testdata/pong.replay")
}

// test_replay_out_path_no_extension_appends pins the degenerate case: an artifact
// path with no extension gets `.replay` appended rather than mangling the name, so
// the derivation stays total over any path shape.
@(test)
test_replay_out_path_no_extension_appends :: proc(t: ^testing.T) {
	out := replay_out_path("build/pong", "", context.temp_allocator)
	testing.expect_value(t, out, "build/pong.replay")
}

// test_replay_out_path_override_wins pins the os.args[2] override: when the operator
// passes an explicit out path, it is returned verbatim regardless of the artifact's
// extension — the override is authoritative, the derivation is the fallback only.
@(test)
test_replay_out_path_override_wins :: proc(t: ^testing.T) {
	out := replay_out_path("testdata/pong.artifact", "/tmp/custom.replay", context.temp_allocator)
	testing.expect_value(t, out, "/tmp/custom.replay")
}

// test_replay_out_path_preserves_nested_dir pins that the directory survives the
// extension swap on a deeper path — the log sits next to the artifact, not at the
// cwd.
@(test)
test_replay_out_path_preserves_nested_dir :: proc(t: ^testing.T) {
	out := replay_out_path("a/b/c/game.fpk", "", context.temp_allocator)
	testing.expect_value(t, out, "a/b/c/game.replay")
}

// test_text_rects_empty_is_no_rects pins the empty-string case: a Draw_Text with
// no characters draws nothing, so the present pass paints no spurious glyph.
@(test)
test_text_rects_empty_is_no_rects :: proc(t: ^testing.T) {
	rects := text_rects("", Vec2{to_fixed(80), to_fixed(8)}, TEXT_CELL, .White, context.temp_allocator)
	testing.expect_value(t, len(rects), 0)
}

// test_text_rects_centers_the_run pins the §20 text anchor: `at` is the CENTER
// of the rendered glyph run. A one-character run at TEXT_CELL (2x2 world units,
// advance 8) is 6 wide x 10 tall, so its origin is at − (3,5) — and '1' row 0
// (mask 0b010) lights column 1, whose cell CENTER lands back at exactly at.x.
// The run renders centered without the author knowing the glyph metrics, and
// the command's color (not a hardcoded White) paints every cell.
@(test)
test_text_rects_centers_the_run :: proc(t: ^testing.T) {
	at := Vec2{to_fixed(80), to_fixed(8)}
	rects := text_rects("1", at, TEXT_CELL, .Green, context.temp_allocator)
	testing.expect_value(t, len(rects), 8)
	first := rects[0]
	testing.expect_value(t, first.color, Draw_Color.Green)
	testing.expect_value(t, first.size, TEXT_CELL)
	// origin = at − (run_w/2, run_h/2) = (77, 3); col-1 cell center =
	// origin.x + cell.x + cell.x/2 = 80 — the anchor point itself.
	testing.expect_value(t, first.at.x, to_fixed(80))
	testing.expect_value(t, first.at.y, to_fixed(4))
}

// test_text_rects_advances_per_character pins the cursor step: a space between
// two digits advances the cursor one glyph advance (4 cells) but draws no rect
// for the gap, so "0 0" emits only the two digits' glyphs and the second digit
// is laid out two advances right of the first.
@(test)
test_text_rects_advances_per_character :: proc(t: ^testing.T) {
	at := Vec2{to_fixed(80), to_fixed(8)}
	// '0' is a 12-cell hollow box; "0 0" is two '0' glyphs with a blank gap.
	rects := text_rects("0 0", at, TEXT_CELL, .White, context.temp_allocator)
	testing.expect_value(t, len(rects), 24)
	// Run: 3 chars * advance 8 − gap 2 = 22 wide → origin.x = 80 − 11 = 69. The
	// second '0' starts two advances right (69 + 16 = 85); its first lit cell
	// (row 0, col 0) CENTER sits half a cell further (86).
	half_y := fixed_div(TEXT_CELL.y, to_fixed(2))
	testing.expect_value(t, rects[12].at.x, to_fixed(86))
	testing.expect_value(t, rects[12].at.y, fixed_add(fixed_sub(at.y, to_fixed(5)), half_y))
}
