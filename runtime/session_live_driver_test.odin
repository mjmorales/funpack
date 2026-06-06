// Proof for the live session DRIVER's pure helpers — the device-pure transforms
// the when-gated SDL driver leans on that compile in every build (the SDL window
// loop itself is when-gated live code, excluded from this deterministic suite).
// The driver's only deterministically-testable surfaces are the replay out-path
// derivation and the score-readout glyph layout; both are pure string/geometry
// transforms with no SDL and no clock, so this headless suite pins their exact
// rails the same way session_live_test.odin pins the projection helpers. The loop,
// pacing, present, and exit are operator-gated (a window must open) and proven by
// the existing replay_acceptance_test's live-vs-replay digest identity.
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

// test_score_digit_rects_empty_is_no_rects pins the empty-string case: a score with
// no characters draws nothing, so the present pass paints no spurious glyph.
@(test)
test_score_digit_rects_empty_is_no_rects :: proc(t: ^testing.T) {
	rects := score_digit_rects("", context.temp_allocator)
	testing.expect_value(t, len(rects), 0)
}

// test_score_digit_rects_single_digit_starts_at_origin pins the layout anchor: the
// first digit's glyph begins at SCORE_ORIGIN and every cell is SCORE_CELL-sized, so
// the readout is positioned by the named constants, not magic offsets. '1' lights 8
// cells (0b010, 0b110, 0b010, 0b010, 0b111), the same count digit_rects pins.
@(test)
test_score_digit_rects_single_digit_starts_at_origin :: proc(t: ^testing.T) {
	rects := score_digit_rects("1", context.temp_allocator)
	testing.expect_value(t, len(rects), 8)
	first := rects[0]
	testing.expect_value(t, first.color, Draw_Color.White)
	testing.expect_value(t, first.size, SCORE_CELL)
	// '1' row 0 mask 0b010 lights column 1: at = SCORE_ORIGIN + (1*cell.x, 0).
	testing.expect_value(t, first.at.x, fixed_add(SCORE_ORIGIN.x, SCORE_CELL.x))
	testing.expect_value(t, first.at.y, SCORE_ORIGIN.y)
}

// test_score_digit_rects_advances_per_character pins the cursor step: a space
// between two digits advances the cursor SCORE_GLYPH_ADVANCE per character but draws
// no rect for the gap, so "0 0" emits only the two digits' glyphs and the second
// digit sits two advances right of the first.
@(test)
test_score_digit_rects_advances_per_character :: proc(t: ^testing.T) {
	// '0' is a 12-cell hollow box; "0 0" is two '0' glyphs with a blank gap.
	rects := score_digit_rects("0 0", context.temp_allocator)
	testing.expect_value(t, len(rects), 24)
	// The second '0' starts two SCORE_GLYPH_ADVANCE steps right of SCORE_ORIGIN (one
	// for the first digit, one for the space). Its first lit cell (row 0, col 0) sits
	// at that advanced origin.
	second_origin_x := fixed_add(SCORE_ORIGIN.x, fixed_add(SCORE_GLYPH_ADVANCE, SCORE_GLYPH_ADVANCE))
	testing.expect_value(t, rects[12].at.x, second_origin_x)
	testing.expect_value(t, rects[12].at.y, SCORE_ORIGIN.y)
}
