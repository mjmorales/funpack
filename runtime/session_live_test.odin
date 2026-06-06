// Proof for the live session's pure presentation helpers — the device-pure half
// of the live producer that compiles in every build (the SDL window/renderer is
// when-gated live code, excluded from this deterministic suite). The tests pin the exact
// pixel rails the 4x integer scale guarantees (origin → (0,0), the 160x120 board
// extent → (640,480), the ball start (80,60) → (320,240)), the totality of the
// §20 Draw_Color → RGBA8 lowering over all five variants, and the block-digit
// glyph rect sets for representative digits — mirroring device_live_test.odin's
// pattern (pure maps tested headless, SDL excluded). NO float at any step: the
// world→pixel rails are exact-integer because the Q32.32 scale cancels in the
// world/board ratio (§10.5).
package funpack_runtime

import "core:testing"

// PONG_BOARD is the §28 pong board extent in raw Q32.32 bits — 160x120 world
// units (160<<32, 120<<32), the exact values testdata/pong.artifact's BOARD const
// carries (node fixed 687194767360 / 515396075520). The world→pixel rails are
// asserted against this so the test is grounded in the artifact's real geometry,
// not a re-derived constant.
@(private = "file")
PONG_BOARD :: Vec2{Fixed(687194767360), Fixed(515396075520)}

// PONG_WINDOW is the fixed 640x480 window the live session opens — an exact 4x
// integer scale of the 160x120 board, so every world unit lands on a 4-pixel cell
// with no rounding.
@(private = "file")
PONG_WINDOW :: Window_Px{640, 480}

// test_world_to_pixel_origin_rail pins the origin: world (0,0) maps to pixel (0,0)
// for any board/window — the top-left anchor the projection rests on.
@(test)
test_world_to_pixel_origin_rail :: proc(t: ^testing.T) {
	px := world_to_pixel(VEC2_ZERO, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, px, Pixel{0, 0})
}

// test_world_to_pixel_board_extent_rail pins the far corner: the full board extent
// (160,120) world units maps to the window's bottom-right (640,480) — the 4x scale
// exactly, proving the Q32.32 scale cancels in the ratio with no float.
@(test)
test_world_to_pixel_board_extent_rail :: proc(t: ^testing.T) {
	extent := Vec2{PONG_BOARD.x, PONG_BOARD.y}
	px := world_to_pixel(extent, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, px, Pixel{640, 480})
}

// test_world_to_pixel_ball_start_rail pins an interior point: the ball start
// (80,60) world units — half the board on each axis (343597383680 / 257698037760
// raw, the artifact's spawn) — maps to the window center (320,240).
@(test)
test_world_to_pixel_ball_start_rail :: proc(t: ^testing.T) {
	ball := Vec2{to_fixed(80), to_fixed(60)}
	px := world_to_pixel(ball, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, px, Pixel{320, 240})
}

// test_world_axis_to_pixel_zero_board_is_total pins the degenerate guard: a zero
// board extent maps to pixel 0 instead of dividing by zero, so the projection
// stays total like the kernel.
@(test)
test_world_axis_to_pixel_zero_board_is_total :: proc(t: ^testing.T) {
	testing.expect_value(t, world_axis_to_pixel(to_fixed(80), 640, Fixed(0)), i32(0))
}

// test_draw_color_to_rgba_totality pins the §20 palette lowering over ALL five
// closed-enum variants to their fully-opaque RGBA8 tuples — the totality the
// present boundary depends on (an unmapped variant would not compile).
@(test)
test_draw_color_to_rgba_totality :: proc(t: ^testing.T) {
	testing.expect_value(t, draw_color_to_rgba(.White), Rgba8{255, 255, 255, 255})
	testing.expect_value(t, draw_color_to_rgba(.Black), Rgba8{0, 0, 0, 255})
	testing.expect_value(t, draw_color_to_rgba(.Red), Rgba8{255, 0, 0, 255})
	testing.expect_value(t, draw_color_to_rgba(.Green), Rgba8{0, 255, 0, 255})
	testing.expect_value(t, draw_color_to_rgba(.Blue), Rgba8{0, 0, 255, 255})
}

// test_digit_rects_space_is_empty pins the score-readout gap: a space (and any
// non-digit) emits no rect, so the inter-column blanks in "0   0" advance the
// cursor without drawing.
@(test)
test_digit_rects_space_is_empty :: proc(t: ^testing.T) {
	rects := digit_rects(' ', VEC2_ZERO, Vec2{to_fixed(1), to_fixed(1)}, context.temp_allocator)
	testing.expect_value(t, len(rects), 0)

	non_digit := digit_rects('A', VEC2_ZERO, Vec2{to_fixed(1), to_fixed(1)}, context.temp_allocator)
	testing.expect_value(t, len(non_digit), 0)
}

// test_digit_rects_one_glyph pins the simplest non-trivial glyph: '1' over the 3x5
// grid lights 1+2+1+1+3 = 8 cells (0b010, 0b110, 0b010, 0b010, 0b111), so it emits
// exactly 8 White rects, and the first lit cell's CENTER (§20 anchor) sits at the
// col-1/row-0 corner plus half a cell — the column/row placement asserted at one
// exact point under the center anchor.
@(test)
test_digit_rects_one_glyph :: proc(t: ^testing.T) {
	cell := Vec2{to_fixed(2), to_fixed(3)}
	origin := Vec2{to_fixed(10), to_fixed(20)}
	rects := digit_rects('1', origin, cell, context.temp_allocator)
	// 0b010, 0b110, 0b010, 0b010, 0b111 -> 1 + 2 + 1 + 1 + 3 lit cells.
	testing.expect_value(t, len(rects), 8)
	// First lit cell of row 0 (mask 0b010) is column 1: center = origin +
	// (1*cell.x + cell.x/2, 0 + cell.y/2).
	first := rects[0]
	testing.expect_value(t, first.color, Draw_Color.White)
	testing.expect_value(t, first.size, cell)
	testing.expect_value(t, first.at.x, fixed_add(fixed_add(origin.x, cell.x), fixed_div(cell.x, to_fixed(2))))
	testing.expect_value(t, first.at.y, fixed_add(origin.y, fixed_div(cell.y, to_fixed(2))))
}

// test_digit_rects_eight_is_full_block pins the densest glyph: '8' lights every
// row's outer columns plus the three horizontal bars (0b111, 0b101, 0b111, 0b101,
// 0b111) = 3 + 2 + 3 + 2 + 3 = 13 cells, the most any digit emits — the upper
// bound the renderer budgets against.
@(test)
test_digit_rects_eight_is_full_block :: proc(t: ^testing.T) {
	cell := Vec2{to_fixed(4), to_fixed(4)}
	rects := digit_rects('8', VEC2_ZERO, cell, context.temp_allocator)
	testing.expect_value(t, len(rects), 13)
}

// test_digit_rects_zero_corner_placement pins '0' (a hollow 3x5 box: 0b111, 0b101,
// 0b101, 0b101, 0b111 = 12 cells) and checks the bottom-right lit cell's CENTER
// (§20 anchor) lands at the row-4/col-2 corner plus half a cell — the far corner of
// the glyph grid, so the row/col scaling is exact at both extremes.
@(test)
test_digit_rects_zero_corner_placement :: proc(t: ^testing.T) {
	cell := Vec2{to_fixed(5), to_fixed(7)}
	origin := Vec2{to_fixed(100), to_fixed(200)}
	rects := digit_rects('0', origin, cell, context.temp_allocator)
	// 0b111, 0b101, 0b101, 0b101, 0b111 -> 3 + 2 + 2 + 2 + 3 = 12 lit cells.
	testing.expect_value(t, len(rects), 12)
	// The last appended cell is the bottom row's rightmost column (row 4, col 2); its
	// center is that corner plus half a cell on each axis.
	last := rects[len(rects) - 1]
	last_corner_x := fixed_add(origin.x, fixed_mul(cell.x, to_fixed(2)))
	last_corner_y := fixed_add(origin.y, fixed_mul(cell.y, to_fixed(4)))
	testing.expect_value(t, last.at.x, fixed_add(last_corner_x, fixed_div(cell.x, to_fixed(2))))
	testing.expect_value(t, last.at.y, fixed_add(last_corner_y, fixed_div(cell.y, to_fixed(2))))
}
