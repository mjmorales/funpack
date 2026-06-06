// The LIVE session presentation helpers: the pure, device-pure projection from
// the §20 fixed-point draw-list onto a concrete window's integer pixel grid and
// RGBA8 palette. Like device_live.odin's SDL→§23 maps, every helper here sits
// OUTSIDE any `when` block and references no SDL symbol, so it compiles in every
// build and the headless suite (session_live_test.odin) pins its rails — the
// `stick_sample_to_fixed` / `key_code_from_scancode` discipline mirrored for the
// present side. The window loop, the SDL renderer, and the CLI entry that consume
// these live in the when-gated session driver and device layer, never in this file.
//
// The projection extent comes from the ARTIFACT: the §15 entrypoint's declared
// `logical:WxH` draw space (§20 §3) sizes both the window (the largest integer
// scale of the logical extent that fits LIVE_TARGET_PX) and the world→pixel
// board denominator — no per-game board constant lives here.
//
// NO FLOAT (§10, §10.5): world→pixel is exact-integer over i128 — the Q32.32
// scale on the world coordinate and the same scale on the board extent cancel in
// the ratio, so `pixel = world_bits * window_px / board_bits` is a pure integer
// projection with no 2^32 reconstruction and no float anywhere. Pixel conversion
// is a render-PRESENT-boundary concern only: it reads the committed draw-list and
// never feeds back into resolve_tick / step_tick (the determinism core sees no
// pixel).
//
// vendor:sdl2/ttf is DELIBERATELY NOT USED: §20 Draw_Text is drawn with a
// block-glyph table (digits + uppercase letters over a 3x5 cell grid) emitting
// filled §20-style rects, so the live presentation carries no font dependency
// and the glyph geometry is itself pure and headless-testable.
//
// The SDL session driver itself (the window loop, pacing, present, exit) lives in
// the `when #config(FUNPACK_LIVE, false)` block at the foot of this file; only it
// references an SDL call, so a default build compiles none of it and links no SDL
// symbol. run_live_session is the entry main() dispatches to under the define.
package funpack_runtime

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// import sdl is held by the SESSION_LIVE_SDL_ALIVE alias below so -vet accepts it
// in a default (headless) build, where the whole when-gated driver compiles out —
// the same dead-stripped-alias discipline device_live.odin uses for its own SDL
// import (an import cannot itself sit inside a `when`, so an outside-the-block
// reference keeps it from reading as unused).
import sdl "vendor:sdl2"

// SESSION_LIVE_SDL_ALIVE keeps the vendor:sdl2 import referenced OUTSIDE the
// when-gated block so a headless build's -vet does not flag the import as unused,
// while emitting no SDL symbol (a type alias is dead-stripped, so the default
// binary links nothing). The live driver below uses the same import for its real
// SDL calls; this alias exists only to satisfy the headless vet gate.
SESSION_LIVE_SDL_ALIVE :: sdl.Event

// SESSION_LIVE_OS_ALIVE / SESSION_LIVE_FMT_ALIVE keep core:os and core:fmt
// referenced outside the when-gated driver for the same reason: the driver's IO
// (os.read_entire_file_from_path) and diagnostics (fmt.eprintfln) compile out
// headless, so without an outside reference -vet reads both imports as unused. Both
// aliases are dead-stripped, so the default binary carries nothing extra.
SESSION_LIVE_OS_ALIVE :: os.Error
SESSION_LIVE_FMT_ALIVE :: fmt.Info

// --- replay out-path derivation (pure, compiled in every build) -----------

// replay_out_path derives where a live session writes its .replay log: the
// explicit `override` when the operator passed one (os.args[2]), otherwise
// `<artifact-stem>.replay` sitting next to the artifact — the artifact path with
// its extension swapped for `.replay`, preserving the directory so the log lands
// beside the artifact it was recorded against. An artifact path with no extension
// gets `.replay` appended. This is a render-boundary-free string transform with no
// SDL and no IO, so it compiles in every build and a headless test pins it.
replay_out_path :: proc(artifact_path: string, override: string, allocator := context.allocator) -> string {
	if override != "" {
		return strings.clone(override, allocator)
	}
	ext := filepath.ext(artifact_path)
	stem := artifact_path[:len(artifact_path) - len(ext)]
	return strings.concatenate({stem, ".replay"}, allocator)
}

// --- world → pixel projection --------------------------------------------

// Window_Px is a concrete window's integer pixel extent (width, height). It is
// the only non-fixed-point coordinate this layer introduces, and it lives on the
// present side of the boundary — the sim never sees it.
Window_Px :: struct {
	w: i32,
	h: i32,
}

// LIVE_TARGET_PX is the longest-side pixel target the live window aims for: the
// window opens at the LARGEST integer multiple of the logical extent that fits
// this target on both axes (so every world unit lands on a whole-pixel cell with
// no rounding — pong's 160x120 scales 4x to 640x480, snake's 160x160 to
// 640x640). A logical extent already past the target opens at 1x rather than
// shrinking below integer scale.
LIVE_TARGET_PX :: 640

// live_window_for derives the live window extent from the artifact's declared
// §15 logical draw space: the largest integer scale k >= 1 with both
// logical_w*k and logical_h*k inside LIVE_TARGET_PX. Integer scaling keeps the
// world→pixel projection exact (§10.5) and uniform on both axes, so the whole
// declared space is visible — the per-artifact replacement for a fixed window
// constant. The loader guarantees positive dimensions (§15).
live_window_for :: proc(logical_w: int, logical_h: int) -> Window_Px {
	scale := min(LIVE_TARGET_PX / logical_w, LIVE_TARGET_PX / logical_h)
	if scale < 1 {
		scale = 1
	}
	return Window_Px{w = i32(logical_w * scale), h = i32(logical_h * scale)}
}

// board_extent lifts the artifact's declared integer logical extent (§15
// logical:WxH) into the Q32.32 world-unit Vec2 the world→pixel projection
// divides by — the per-artifact replacement for a hardcoded board constant.
board_extent :: proc(logical_w: int, logical_h: int) -> Vec2 {
	return Vec2{to_fixed(i64(logical_w)), to_fixed(i64(logical_h))}
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

// --- camera world↔screen pre-transform (§3: camera is state, view is a command) ---

// Camera_View is the active §20 Draw::Camera transform the present pass composes
// onto the board geometry: the world point the camera is centered on and the zoom
// factor (1.0 = unscaled). It is the render-boundary projection of the committed
// Draw_Camera command — the sim never sees it (§3: only the engine reads
// world↔screen). rotation is not carried here because it is unprojected (yard emits
// rotation:0.0); when a story projects rotation it joins this struct.
Camera_View :: struct {
	at:   Vec2,
	zoom: Fixed,
}

// identity_camera is the no-transform view: centered on the board center at zoom
// 1.0, so camera_pre_transform is the identity (every world point maps exactly as
// world_to_pixel alone would). A draw-list carrying no Draw::Camera (pong, snake,
// hunt) presents through this, so the existing exact-pixel rails are unchanged.
identity_camera :: proc(board: Vec2) -> Camera_View {
	return Camera_View{at = Vec2{fixed_div(board.x, to_fixed(2)), fixed_div(board.y, to_fixed(2))}, zoom = to_fixed(1)}
}

// camera_from_command lifts a committed Draw_Camera draw command into the present
// pass's Camera_View — the at/zoom the world↔screen pre-transform composes. A zoom
// of 0 (an absent/malformed scalar lowered to 0) reads as 1.0, so a degenerate
// command never collapses the whole world to the camera center; the present pass
// stays total like the kernel.
camera_from_command :: proc(cmd: Draw_Camera) -> Camera_View {
	zoom := cmd.zoom
	if zoom == 0 {
		zoom = to_fixed(1)
	}
	return Camera_View{at = cmd.at, zoom = zoom}
}

// camera_pre_transform composes the §3 camera transform onto one world coordinate
// BEFORE world_to_pixel: it recenters the world on the camera (`world - cam.at`),
// scales the offset by `zoom`, then re-anchors to the board center so the camera's
// `at` lands at screen center. screen_world = board/2 + (world - cam.at) * zoom.
// With cam.at = board/2 and zoom = 1.0 this is the identity. The whole composition
// is exact-integer over the Q32.32 kernel (fixed_sub / vec2_scale / fixed_add) —
// NO float (§10.5) — and runs ONLY at the render-present boundary: its result feeds
// world_to_pixel and never re-enters step_tick / the sim fold.
camera_pre_transform :: proc(world: Vec2, camera: Camera_View, board: Vec2) -> Vec2 {
	board_center := Vec2{fixed_div(board.x, to_fixed(2)), fixed_div(board.y, to_fixed(2))}
	offset := vec2_scale(vec2_sub(world, camera.at), camera.zoom)
	return vec2_add(board_center, offset)
}

// camera_world_to_pixel is the full present-boundary projection: compose the §3
// camera pre-transform onto the world coordinate, then project the camera-space
// world point onto integer window pixels. It is the one entry the live present pass
// projects every rect/text corner through, so the active Draw::Camera transform
// folds in uniformly. Exact-integer throughout (the pre-transform over the kernel,
// world_to_pixel over i128) — no float, render-boundary-only (§10.5).
camera_world_to_pixel :: proc(world: Vec2, camera: Camera_View, board: Vec2, window: Window_Px) -> Pixel {
	return world_to_pixel(camera_pre_transform(world, camera, board), board, window)
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

// --- block-glyph table ------------------------------------------------------

// GLYPH_COLS / GLYPH_ROWS are the block-glyph grid: each glyph is a 3-wide ×
// 5-tall cell bitmap, so a glyph_rects call emits at most 15 filled rects (one
// per lit cell). The 3x5 layout is the smallest grid that draws every decimal
// digit and uppercase letter legibly with straight block segments.
GLYPH_COLS :: 3
GLYPH_ROWS :: 5

// DIGIT_GLYPHS is the block-digit bitmap table: index by (digit, row) to a 3-bit
// row mask whose set bits (high bit = leftmost column) are the lit cells. Read top
// row to bottom row. A bit set means "emit a filled rect for this cell"; the glyphs
// are the canonical seven-segment-style block shapes over a 3x5 grid.
DIGIT_GLYPHS :: [10][GLYPH_ROWS]u8 {
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

// LETTER_GLYPHS is the uppercase A..Z bitmap table over the same 3x5 grid and
// row-mask encoding as DIGIT_GLYPHS. Letter 'O' (rounded corners) deliberately
// differs from digit '0' (square box) so a score never reads as prose. M/N are
// the 3-wide compromise every 3x5 face makes — distinct from each other and
// from H by their filled rows.
LETTER_GLYPHS :: [26][GLYPH_ROWS]u8 {
	{0b010, 0b101, 0b111, 0b101, 0b101}, // A
	{0b110, 0b101, 0b110, 0b101, 0b110}, // B
	{0b011, 0b100, 0b100, 0b100, 0b011}, // C
	{0b110, 0b101, 0b101, 0b101, 0b110}, // D
	{0b111, 0b100, 0b110, 0b100, 0b111}, // E
	{0b111, 0b100, 0b110, 0b100, 0b100}, // F
	{0b011, 0b100, 0b101, 0b101, 0b011}, // G
	{0b101, 0b101, 0b111, 0b101, 0b101}, // H
	{0b111, 0b010, 0b010, 0b010, 0b111}, // I
	{0b001, 0b001, 0b001, 0b101, 0b010}, // J
	{0b101, 0b101, 0b110, 0b101, 0b101}, // K
	{0b100, 0b100, 0b100, 0b100, 0b111}, // L
	{0b101, 0b111, 0b111, 0b101, 0b101}, // M
	{0b110, 0b101, 0b101, 0b101, 0b101}, // N
	{0b010, 0b101, 0b101, 0b101, 0b010}, // O
	{0b110, 0b101, 0b110, 0b100, 0b100}, // P
	{0b010, 0b101, 0b101, 0b010, 0b001}, // Q
	{0b110, 0b101, 0b110, 0b101, 0b101}, // R
	{0b011, 0b100, 0b010, 0b001, 0b110}, // S
	{0b111, 0b010, 0b010, 0b010, 0b010}, // T
	{0b101, 0b101, 0b101, 0b101, 0b111}, // U
	{0b101, 0b101, 0b101, 0b101, 0b010}, // V
	{0b101, 0b101, 0b111, 0b111, 0b101}, // W
	{0b101, 0b101, 0b010, 0b101, 0b101}, // X
	{0b101, 0b101, 0b010, 0b010, 0b010}, // Y
	{0b111, 0b001, 0b010, 0b100, 0b111}, // Z
}

// TOFU_GLYPH is the full 15-cell block an UNMAPPED character renders as: a
// missing glyph must be LOUD on screen (the visible tofu convention), never a
// silent blank — a blank render is exactly how missing text hides invisibly.
TOFU_GLYPH :: [GLYPH_ROWS]u8{0b111, 0b111, 0b111, 0b111, 0b111}

// glyph_lookup maps one character onto its 3x5 row bitmap and whether it draws
// at all: digits and uppercase letters from their tables, lowercase folded to
// uppercase, ' ' as the one draws-nothing character (a layout gap advances the
// cursor without painting), and every other character as the loud TOFU block.
glyph_lookup :: proc(ch: rune) -> (glyph: [GLYPH_ROWS]u8, draws: bool) {
	// The tables are compile-time constants; bind to locals so a runtime index
	// reads them (a constant cannot be indexed by a variable).
	digits := DIGIT_GLYPHS
	letters := LETTER_GLYPHS
	switch {
	case ch == ' ':
		return {}, false
	case ch >= '0' && ch <= '9':
		return digits[ch - '0'], true
	case ch >= 'A' && ch <= 'Z':
		return letters[ch - 'A'], true
	case ch >= 'a' && ch <= 'z':
		return letters[ch - 'a'], true
	}
	return TOFU_GLYPH, true
}

// glyph_rects emits the filled §20 rects that draw one character as a block
// glyph in `color`, `origin` the glyph's top-left corner reference for layout.
// Per §20's normative anchor, each emitted Draw_Rect.at is the CELL CENTER —
// origin + ((col + 1/2)*cell.x, (row + 1/2)*cell.y) — so the glyph cell renders
// unshifted under the center anchor the present pass derives a corner from
// (at − size/2). It walks the character's 3x5 bitmap (glyph_lookup), emitting a
// `cell`-sized rect per set bit; ' ' emits nothing — a layout gap advances the
// cursor without drawing. The half-cell offset is taken in fixed-point off the
// kernel (fixed_div by 2), so the geometry stays float-free and composes
// directly into the rects the present pass paints; tested headless against
// exact glyphs.
glyph_rects :: proc(ch: rune, origin: Vec2, cell: Vec2, color: Draw_Color, allocator := context.allocator) -> []Draw_Rect {
	glyph, draws := glyph_lookup(ch)
	if !draws {
		return nil
	}
	half := Vec2{fixed_div(cell.x, to_fixed(2)), fixed_div(cell.y, to_fixed(2))}
	rects := make([dynamic]Draw_Rect, allocator)
	for row in 0 ..< GLYPH_ROWS {
		mask := glyph[row]
		for col in 0 ..< GLYPH_COLS {
			// High bit is the leftmost column: shift the column's bit down to LSB.
			bit := (mask >> u8(GLYPH_COLS - 1 - col)) & 1
			if bit == 0 {
				continue
			}
			// Center the cell: corner (origin + col/row * cell) plus half a cell.
			at := Vec2 {
				fixed_add(fixed_add(origin.x, fixed_mul(cell.x, to_fixed(i64(col)))), half.x),
				fixed_add(fixed_add(origin.y, fixed_mul(cell.y, to_fixed(i64(row)))), half.y),
			}
			append(&rects, Draw_Rect{at = at, size = cell, color = color})
		}
	}
	return rects[:]
}

// --- text layout (pure, compiled in every build) ---------------------------

// TEXT_CELL is the world-unit size of one block-glyph grid cell in the live
// text lowering: 2x2 world units, so a 3x5 glyph is 6x10 world units (24x40 px
// at a 4x window scale) — large enough to read against a 160-unit board. One
// fixed engine metric for every Draw_Text; a game sizes text by its logical
// space, not a font API.
TEXT_CELL :: Vec2{Fixed(2 << 32), Fixed(2 << 32)}

// TEXT_GLYPH_ADVANCE is the horizontal cursor step between two characters: the
// glyph's 3 cells wide plus one blank cell of gap, in world units (4 * cell.x),
// so adjacent glyphs never touch.
TEXT_GLYPH_ADVANCE :: Fixed((GLYPH_COLS + 1) * 2) << 32

// text_rects lowers one §20 Draw_Text onto its filled block-glyph rects: `at`
// is the CENTER of the rendered glyph run — the §20 anchor rule extended to
// text, so `Draw::Text{at: board-center}` reads centered without the author
// knowing the engine's glyph metrics. The run's extent is derived from the
// fixed engine metrics (chars * TEXT_GLYPH_ADVANCE minus the trailing gap, 5
// cells tall), the top-left origin is at − extent/2, then the cursor walks one
// glyph_rects call per character in `color`. Pure all-fixed-point geometry off
// the kernel (no SDL, no float), so it compiles in every build and the live
// present pass paints its result the same way it paints the artifact's own
// Draw_Rects.
text_rects :: proc(text: string, at: Vec2, cell: Vec2, color: Draw_Color, allocator := context.allocator) -> []Draw_Rect {
	advance := fixed_mul(cell.x, to_fixed(GLYPH_COLS + 1))
	gap := cell.x
	count := 0
	for _ in text {
		count += 1
	}
	if count == 0 {
		return nil
	}
	// Run extent: count advances minus the trailing inter-glyph gap, 5 rows tall.
	run_w := fixed_sub(fixed_mul(advance, to_fixed(i64(count))), gap)
	run_h := fixed_mul(cell.y, to_fixed(GLYPH_ROWS))
	origin := Vec2 {
		fixed_sub(at.x, fixed_div(run_w, to_fixed(2))),
		fixed_sub(at.y, fixed_div(run_h, to_fixed(2))),
	}

	rects := make([dynamic]Draw_Rect, allocator)
	cursor := origin
	for ch in text {
		glyph := glyph_rects(ch, cursor, cell, color, allocator)
		for rect in glyph {
			append(&rects, rect)
		}
		delete(glyph, allocator)
		cursor.x = fixed_add(cursor.x, advance)
	}
	return rects[:]
}

// --- the live session driver (when-gated: the ONLY SDL-calling code here) ---

when #config(FUNPACK_LIVE, false) {

	// run_live_session is the live session entry main() dispatches to under
	// FUNPACK_LIVE. It parses the CLI (os.args[1] = artifact path, os.args[2] =
	// optional replay out path), loads the artifact retaining its raw bytes for the
	// content-hashed replay identity, then drives the proven live seam —
	// run_startup, then per frame { drain SDL events once into the injected queue
	// and the exit flag → resolve_tick → step_tick → render_version → present →
	// record_tick → thread prev_held → pace to the next tick deadline }. On exit it
	// flushes the replay (finish_replay + write_replay_file) BEFORE closing the live
	// device. Returns a process exit code (0 on a clean session, non-zero on a usage
	// or load failure). tick_hz comes SOLELY from program.entrypoint.tick_hz and the
	// window/board geometry SOLELY from its declared logical extent (§15
	// logical:WxH via live_window_for / board_extent) — never a flag — and no float
	// ever reaches sim state: pixel conversion happens only at the present boundary
	// and never feeds back into resolve_tick/step_tick.
	run_live_session :: proc(args: []string) -> int {
		if len(args) < 2 {
			fmt.eprintln("usage: funpack-live <artifact-path> [replay-out-path]")
			return 2
		}
		artifact_path := args[1]
		override := len(args) >= 3 ? args[2] : ""

		// Read the raw bytes ourselves so the replay identity's content hash is over
		// the exact bytes loaded (load_artifact_file does not surface them); load the
		// program from those same bytes so the hash pins the build that ran.
		artifact_bytes, read_err := os.read_entire_file_from_path(artifact_path, context.allocator)
		if read_err != nil {
			fmt.eprintfln("error: cannot read artifact %s", artifact_path)
			return 1
		}
		program, load_err := load_program(string(artifact_bytes), context.allocator)
		if load_err != .None {
			fmt.eprintfln("error: malformed artifact %s (%v)", artifact_path, load_err)
			return 1
		}

		out_path := replay_out_path(artifact_path, override, context.allocator)

		// The window and the world→pixel board come from the artifact's declared
		// §15 logical extent — the present geometry is per-artifact, never a
		// hardcoded board constant (§20 §3).
		window := live_window_for(program.entrypoint.logical_w, program.entrypoint.logical_h)
		board := board_extent(program.entrypoint.logical_w, program.entrypoint.logical_h)

		device, dev_ok := live_device_open(window.w, window.h)
		if !dev_ok {
			fmt.eprintln("error: SDL device open failed (no display/GPU?)")
			return 1
		}

		// Build the determinism seam exactly as live_capture does: the bindings table
		// over the identity overlay, the injected queue the live poll feeds, the
		// replay writer pinned to the content-hashed identity, the empty world stepped
		// from setup, and the Time resource at the artifact's fixed tick rate.
		table := build_bindings_table(program, IDENTITY_OVERLAY)
		queue := new_device_queue()

		// SEED PICK (§25 §60): a program whose setup BINDS AN RNG PARAM is SEEDED — its
		// tick-0 population is drawn from an RNG (snake's first food cell). The seed is
		// a RUN-TIME determinism input the artifact does not carry, so the live session
		// picks it ONCE here from the wall clock and RECORDS it in the header — that
		// turns the only live nondeterminism (the seed pick) into a recorded determinism
		// input, so a re-fold re-feeds the exact seed and reproduces the run. A seedless
		// program (pong, hunt, yard) pins the bare build identity (has_seed = false) and
		// runs the pre-evaluated [Spawn] batch unchanged. A Startup function alone is
		// NOT seeded: a seedless `setup() -> [Spawn]` body is already folded into
		// program.setup, so the check keys on the Rng param, never mere presence.
		seeded := program_is_seeded(&program)
		seed := i64(sdl.GetPerformanceCounter())

		identity :=
			seeded ? identity_from_program_seeded(program, string(artifact_bytes), seed) : identity_from_program(program, string(artifact_bytes))
		writer := open_replay_writer(identity)

		world := new_world(program)
		// rng is the run's persistent tick-0 Rng for a seeded program; nil-threaded
		// (left zero, passed only when seeded) for a seedless one.
		base := initial_version(world)
		version: World_Version
		rng: Rng
		if seeded {
			version, rng = run_startup_seeded(&program, base, rand_seed(seed))
		} else {
			version = run_startup(&program, base)
		}
		time := live_time(program.entrypoint.tick_hz)

		// prev_held threads each resolve_tick's held_after into the next so released
		// edges fire correctly; tick 0 seeds it empty (no button was down before it).
		prev_held := make(map[Player_Action]bool)

		// prev_levels threads the persistent RAW device state (codes down, last stick
		// samples) across ticks so a held key emitting one KEYDOWN edge keeps reading
		// held on every later event-less frame, and a held stick keeps its sample
		// without a fresh CONTROLLERAXISMOTION (§23 §4 level semantics). SDL delivers a
		// single edge for a held key, so without this carrier a held W would die after
		// one tick. Tick 0 seeds it empty (no device was down before the session).
		prev_levels := new_device_levels()

		// The integer pacing clock: deadline N is recomputed from the ABSOLUTE start
		// (start + (tick_index+1)*frequency/tick_hz), so no accumulator drift creeps
		// in over a long session. The clock throttles the loop; it never drives the
		// sim — on an overrun the loop runs exactly one sim tick and lets the deadline
		// slip.
		freq := sdl.GetPerformanceFrequency()
		start := sdl.GetPerformanceCounter()
		tick_hz_u64 := u64(program.entrypoint.tick_hz)

		for tick_index := 0; ; tick_index += 1 {
			if poll_session_events(&queue) {
				break
			}

			snapshot, held_after, levels_after := resolve_tick(table, &queue, prev_held, prev_levels)
			// Thread the persistent Rng through a seeded run so each tick observes the
			// prior tick's draws (§04 §1); a seedless run threads nothing (rng stays nil).
			version = step_tick(&program, version, snapshot, time, context.allocator, seeded ? &rng : nil)
			draw := render_version(&program, version, snapshot, time)
			present_frame(device.renderer, draw, board, window)
			record_tick(&writer, snapshot)

			delete(prev_held)
			prev_held = held_after
			delete_device_levels(prev_levels)
			prev_levels = levels_after

			pace_to_deadline(start, freq, tick_hz_u64, tick_index)
		}

		// Flush the replay log to disk BEFORE releasing the device: the recorded
		// snapshots are the sole durable nondeterminism record, so they must persist
		// even though the window is about to close.
		log_bytes := finish_replay(&writer)
		if !write_replay_file(out_path, log_bytes) {
			fmt.eprintfln("warning: failed to write replay log %s", out_path)
		} else {
			fmt.printfln("wrote replay log %s", out_path)
		}
		live_device_close(device)
		return 0
	}

	// live_time builds the Time resource the live loop steps at — the one `dt` field
	// at the artifact's fixed tick rate, dt = 1/tick_hz in Q32.32 through the kernel.
	// This is bit-identical to the golden_time / replay_time_resource pattern (no
	// float, no wall-clock in dt), so a live run and a re-fold step at the same dt and
	// any digest divergence would be the input source, never the clock.
	live_time :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
		fields := make(map[string]Value, allocator)
		if tick_hz > 0 {
			fields["dt"] = fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
		} else {
			fields["dt"] = Fixed(0)
		}
		return Record_Value{type_name = "Time", fields = fields}
	}

	// poll_session_events is the driver-owned SINGLE PollEvent drain per frame: it
	// dispatches .QUIT and an Escape KEYDOWN to the exit flag (Escape has no §23 Key
	// variant, so the exit check claims it without touching the binding queue), and
	// routes every other bindable event through the existing
	// key_code_from_scancode / pad_code_from_button / stick_from_axis maps and the
	// enqueue_* helpers onto the injected queue. It is the live producer's drain —
	// the driver calls THIS, never poll_live_window AND its own loop, so the window is
	// drained exactly once per tick (no double-drain). Returns true when an exit was
	// requested. SDL repeats a held key; only the first down is the §23 edge, so a
	// repeat KEYDOWN is ignored for the binding queue (the level is already set).
	poll_session_events :: proc(queue: ^Device_Queue) -> (exit: bool) {
		event: Sdl_Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				exit = true
			case .KEYDOWN:
				if event.key.keysym.scancode == .ESCAPE {
					exit = true
					continue
				}
				if event.key.repeat == 0 {
					if code, named := key_code_from_scancode(event.key.keysym.scancode); named {
						enqueue_key_down(queue, code)
					}
				}
			case .KEYUP:
				if code, named := key_code_from_scancode(event.key.keysym.scancode); named {
					enqueue_key_up(queue, code)
				}
			case .CONTROLLERBUTTONDOWN:
				if code, named := pad_code_from_button(sdl.GameControllerButton(event.cbutton.button));
				   named {
					enqueue_pad_down(queue, code)
				}
			case .CONTROLLERBUTTONUP:
				if code, named := pad_code_from_button(sdl.GameControllerButton(event.cbutton.button));
				   named {
					enqueue_pad_up(queue, code)
				}
			case .CONTROLLERAXISMOTION:
				stick, stick_axis, named := stick_from_axis(sdl.GameControllerAxis(event.caxis.axis))
				if named {
					enqueue_stick_sample(queue, stick, stick_axis, stick_sample_to_fixed(event.caxis.value))
				}
			}
		}
		return exit
	}

	// present_frame paints one committed tick's §20 draw-list onto the window: clear
	// to black, resolve the active §3 camera transform from the draw-list (the last
	// Draw_Camera the `view` behavior emitted, else the identity camera so a
	// camera-less artifact presents exactly as before), then per Draw_Rect project
	// at/size through camera_world_to_pixel + draw_color_to_rgba and RenderFillRect,
	// then per Draw_Text emit its center-anchored block-glyph run through the same
	// camera projection in the command's own color, then RenderPresent. The Camera
	// command itself paints nothing — it is the world↔screen state, not a primitive.
	// The board and window come from the artifact's declared logical extent. Pixel
	// conversion happens ONLY here at the present boundary; nothing it computes ever
	// re-enters the sim fold (§10.5).
	present_frame :: proc(renderer: ^sdl.Renderer, draw: Draw_List, board: Vec2, window: Window_Px) {
		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		sdl.RenderClear(renderer)

		camera := active_camera(draw, board)

		for cmd in draw.cmds {
			switch c in cmd {
			case Draw_Rect:
				fill_world_rect(renderer, c.at, c.size, c.color, camera, board, window)
			case Draw_Text:
				glyphs := text_rects(c.text, c.at, TEXT_CELL, c.color, context.temp_allocator)
				for rect in glyphs {
					fill_world_rect(renderer, rect.at, rect.size, rect.color, camera, board, window)
				}
			case Draw_Camera:
			// The camera is the active world↔screen transform (resolved above), not a
			// painted primitive — it contributes no pixels of its own.
			}
		}
		sdl.RenderPresent(renderer)
	}

	// active_camera resolves the §3 camera transform a tick's draw-list presents
	// through: the LAST Draw_Camera command emitted (a later `view` behavior overrides
	// an earlier one in flattened-pipeline order), or the identity camera when the
	// list carries none — so a camera-less artifact (pong, snake, hunt) projects
	// through the unchanged board geometry. Pure over the committed draw-list; no SDL.
	active_camera :: proc(draw: Draw_List, board: Vec2) -> Camera_View {
		camera := identity_camera(board)
		for cmd in draw.cmds {
			if cam, is_camera := cmd.(Draw_Camera); is_camera {
				camera = camera_from_command(cam)
			}
		}
		return camera
	}

	// fill_world_rect projects one §20 center-anchored world rect into integer
	// window pixels against the artifact's board/window geometry, composing the
	// active §3 camera transform. §20's anchor is normative: `at` is the CENTER of
	// the extent, so a corner-origin backend derives the top-left corner at the
	// present boundary — at − size/2 — before projecting. The half is taken in
	// fixed-point through the kernel (fixed_div by 2, truncating toward zero); pong's
	// sizes are even world units at the exact 4x window scale, so the half lands on a
	// whole world unit and the projected pixel stays exact. The corner projects
	// through camera_world_to_pixel (recenter + zoom + letterbox); the size is a
	// RELATIVE extent, so it takes only the camera zoom (vec2_scale) — never the
	// recenter — before the same world_to_pixel ratio, keeping the pixel extent
	// matched to the zoomed position projection. The whole conversion is
	// render-boundary-only integer arithmetic; no result feeds back into the sim.
	fill_world_rect :: proc(renderer: ^sdl.Renderer, at: Vec2, size: Vec2, color: Draw_Color, camera: Camera_View, board: Vec2, window: Window_Px) {
		half := Vec2{fixed_div(size.x, to_fixed(2)), fixed_div(size.y, to_fixed(2))}
		corner := Vec2{fixed_sub(at.x, half.x), fixed_sub(at.y, half.y)}
		top_left := camera_world_to_pixel(corner, camera, board, window)
		extent := world_to_pixel(vec2_scale(size, camera.zoom), board, window)
		rgba := draw_color_to_rgba(color)
		sdl.SetRenderDrawColor(renderer, rgba.r, rgba.g, rgba.b, rgba.a)
		rect := sdl.Rect {
			x = top_left.x,
			y = top_left.y,
			w = extent.x,
			h = extent.y,
		}
		sdl.RenderFillRect(renderer, &rect)
	}

	// pace_to_deadline sleeps the loop until tick `tick_index`'s deadline, computed
	// in INTEGER performance-counter ticks from the ABSOLUTE start:
	// deadline = start + (tick_index+1) * freq / tick_hz. Recomputing from the
	// absolute start (not an accumulator) means no drift builds up over a long
	// session. It sdl.Delay's the whole-millisecond remainder, then busy-spins the
	// sub-millisecond tail to hit the deadline precisely. On an OVERRUN (now already
	// past the deadline) it returns immediately, so the loop runs exactly one sim
	// tick per iteration and the deadline simply slips — the clock throttles, never
	// drives, the sim.
	pace_to_deadline :: proc(start: u64, freq: u64, tick_hz: u64, tick_index: int) {
		if tick_hz == 0 || freq == 0 {
			return
		}
		deadline := start + (u64(tick_index) + 1) * freq / tick_hz
		for {
			now := sdl.GetPerformanceCounter()
			if now >= deadline {
				return
			}
			remaining := deadline - now
			// Whole milliseconds: sleep them off; the sub-ms tail is busy-spun below.
			ms := remaining * 1000 / freq
			if ms > 1 {
				sdl.Delay(u32(ms - 1))
			}
		}
	}
}
