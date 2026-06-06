// The LIVE session presentation helpers: the pure, device-pure projection from
// the §20 fixed-point draw-list onto a concrete window's integer pixel grid and
// RGBA8 palette. Like device_live.odin's SDL→§23 maps, every helper here sits
// OUTSIDE any `when` block and references no SDL symbol, so it compiles in every
// build and the headless suite (session_live_test.odin) pins its rails — the
// `stick_sample_to_fixed` / `key_code_from_scancode` discipline mirrored for the
// present side. The window loop, the SDL renderer, and the CLI entry that consume
// these live in the when-gated session driver and device layer, never in this file.
//
// NO FLOAT (§10, §10.5): world→pixel is exact-integer over i128 — the Q32.32
// scale on the world coordinate and the same scale on the board extent cancel in
// the ratio, so `pixel = world_bits * window_px / board_bits` is a pure integer
// projection with no 2^32 reconstruction and no float anywhere. Pixel conversion
// is a render-PRESENT-boundary concern only: it reads the committed draw-list and
// never feeds back into resolve_tick / step_tick (the determinism core sees no
// pixel).
//
// vendor:sdl2/ttf is DELIBERATELY NOT USED: the pong score is drawn
// with a block-digit glyph table emitting filled §20-style rects, so the live
// presentation carries no font dependency and the digit geometry is itself
// pure and headless-testable.
package funpack_runtime

// --- world → pixel projection --------------------------------------------

// Window_Px is a concrete window's integer pixel extent (width, height). It is
// the only non-fixed-point coordinate this layer introduces, and it lives on the
// present side of the boundary — the sim never sees it.
Window_Px :: struct {
	w: i32,
	h: i32,
}

// Pixel is an integer pixel coordinate on the window grid (top-left origin). It is
// the projection's output type — a Vec2 of Fixed world bits maps to one Pixel.
Pixel :: struct {
	x: i32,
	y: i32,
}

// world_axis_to_pixel projects one raw Q32.32 world coordinate onto its integer
// pixel along one axis: `pixel = world_bits * window_px / board_bits`. The 2^32
// scale rides BOTH world_bits and board_bits, so it cancels in the ratio — there
// is no float and no scale reconstruction, only i128 integer arithmetic (the i128
// intermediate keeps `world_bits * window_px` from overflowing i64 near the board
// rail). A zero board extent maps to pixel 0 rather than dividing by zero, keeping
// the projection total. Truncation toward zero matches the kernel's one rounding
// rule (§10).
world_axis_to_pixel :: proc(world: Fixed, window_px: i32, board: Fixed) -> i32 {
	if board == 0 {
		return 0
	}
	return i32((i128(world) * i128(window_px)) / i128(board))
}

// world_to_pixel projects a Q32.32 world position into integer window pixels
// against the board extent. With the board at 160x120 world units and the window
// fixed at 640x480 (exact 4x integer scale), the origin maps to (0,0), the board
// extent to (640,480), and any interior point to its exact-integer pixel — no
// float at any step (§10.5). This runs ONLY at the render-present boundary; its
// result never re-enters the sim fold.
world_to_pixel :: proc(world: Vec2, board: Vec2, window: Window_Px) -> Pixel {
	return Pixel {
		x = world_axis_to_pixel(world.x, window.w, board.x),
		y = world_axis_to_pixel(world.y, window.h, board.y),
	}
}

// --- §20 palette → RGBA8 --------------------------------------------------

// Rgba8 is a concrete 8-bit-per-channel color the renderer hands to the window
// backend. It is the present-side lowering of the §20 Draw_Color palette — a
// total map, one variant to one fully-opaque tuple.
Rgba8 :: struct {
	r: u8,
	g: u8,
	b: u8,
	a: u8,
}

// draw_color_to_rgba lowers a §20 Draw_Color onto its concrete RGBA8 tuple. The
// switch is TOTAL over the five-variant closed palette (a new variant is a
// schema-version bump per §04, and would force a compile error here until mapped),
// so the present boundary never faces an unhandled color. Every color is fully
// opaque (alpha 255); pong paints everything White, the rest round out the palette.
draw_color_to_rgba :: proc(color: Draw_Color) -> Rgba8 {
	switch color {
	case .White:
		return Rgba8{255, 255, 255, 255}
	case .Black:
		return Rgba8{0, 0, 0, 255}
	case .Red:
		return Rgba8{255, 0, 0, 255}
	case .Green:
		return Rgba8{0, 255, 0, 255}
	case .Blue:
		return Rgba8{0, 0, 255, 255}
	}
	return Rgba8{255, 255, 255, 255}
}

// --- block-digit glyph table ----------------------------------------------

// DIGIT_GLYPH_COLS / DIGIT_GLYPH_ROWS are the block-digit grid: each '0'..'9'
// glyph is a 3-wide × 5-tall cell bitmap, so a digit_rects call emits at most 15
// filled rects (one per lit cell). The 3x5 layout is the smallest grid that draws
// every decimal digit legibly with straight block segments and no diagonals.
DIGIT_GLYPH_COLS :: 3
DIGIT_GLYPH_ROWS :: 5

// DIGIT_GLYPHS is the block-digit bitmap table: index by (digit, row) to a 3-bit
// row mask whose set bits (high bit = leftmost column) are the lit cells. Read top
// row to bottom row. A bit set means "emit a filled rect for this cell"; the glyphs
// are the canonical seven-segment-style block shapes over a 3x5 grid.
DIGIT_GLYPHS :: [10][DIGIT_GLYPH_ROWS]u8 {
	{0b111, 0b101, 0b101, 0b101, 0b111}, // 0
	{0b010, 0b110, 0b010, 0b010, 0b111}, // 1
	{0b111, 0b001, 0b111, 0b100, 0b111}, // 2
	{0b111, 0b001, 0b111, 0b001, 0b111}, // 3
	{0b101, 0b101, 0b111, 0b001, 0b001}, // 4
	{0b111, 0b100, 0b111, 0b001, 0b111}, // 5
	{0b111, 0b100, 0b111, 0b101, 0b111}, // 6
	{0b111, 0b001, 0b001, 0b001, 0b001}, // 7
	{0b111, 0b101, 0b111, 0b101, 0b111}, // 8
	{0b111, 0b101, 0b111, 0b001, 0b111}, // 9
}

// digit_rects emits the filled §20 rects that draw one character as a block-digit
// glyph at `origin`, each lit cell a `cell`-sized White rect. For '0'..'9' it walks
// the 3x5 DIGIT_GLYPHS bitmap, placing a rect at `origin + (col*cell.x, row*cell.y)`
// for every set bit; ' ' (and any non-digit) emits nothing — the score readout's
// inter-column gaps are blank cells, so a space advancing the cursor draws no rect.
// All-fixed-point geometry off the kernel (no float), so the rects compose directly
// into the draw-list the present pass paints; tested headless against exact glyphs.
digit_rects :: proc(ch: rune, origin: Vec2, cell: Vec2, allocator := context.allocator) -> []Draw_Rect {
	if ch < '0' || ch > '9' {
		return nil
	}
	// DIGIT_GLYPHS is a compile-time constant; bind it to a local so a runtime
	// digit index reads it (a constant cannot be indexed by a variable).
	glyphs := DIGIT_GLYPHS
	glyph := glyphs[ch - '0']
	rects := make([dynamic]Draw_Rect, allocator)
	for row in 0 ..< DIGIT_GLYPH_ROWS {
		mask := glyph[row]
		for col in 0 ..< DIGIT_GLYPH_COLS {
			// High bit is the leftmost column: shift the column's bit down to LSB.
			bit := (mask >> u8(DIGIT_GLYPH_COLS - 1 - col)) & 1
			if bit == 0 {
				continue
			}
			at := Vec2 {
				fixed_add(origin.x, fixed_mul(cell.x, to_fixed(i64(col)))),
				fixed_add(origin.y, fixed_mul(cell.y, to_fixed(i64(row)))),
			}
			append(&rects, Draw_Rect{at = at, size = cell, color = .White})
		}
	}
	return rects[:]
}
