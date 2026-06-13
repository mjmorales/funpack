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
import "core:mem/virtual"
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

// SESSION_LIVE_VIRTUAL_ALIVE keeps core:mem/virtual referenced outside the
// when-gated driver for the same reason: the live loop's per-tick scratch arena
// (virtual.Arena, the bounded-memory reclamation seam) compiles out headless, so
// without an outside reference -vet reads the import as unused. The alias is
// dead-stripped, so the default binary carries nothing extra.
SESSION_LIVE_VIRTUAL_ALIVE :: virtual.Arena

// --- replay out-path / save-root derivation (pure, compiled in every build) ---

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

// save_root_path derives where a live session roots its §24 on-disk save-slot
// store: `<artifact-stem>.saves` sitting next to the artifact — the same
// stem-swap discipline replay_out_path applies, so a game's save slots land
// beside the artifact and replay log they belong to and two artifacts in one
// directory never share a slot namespace. An artifact path with no extension
// gets `.saves` appended. Pure string transform (no SDL, no IO), compiled in
// every build and pinned headless.
save_root_path :: proc(artifact_path: string, allocator := context.allocator) -> string {
	ext := filepath.ext(artifact_path)
	stem := artifact_path[:len(artifact_path) - len(ext)]
	return strings.concatenate({stem, ".saves"}, allocator)
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
// switch is TOTAL over the nine-member closed palette (a new member is a
// schema-version bump per §04, and would force a compile error here until mapped),
// so the present boundary never faces an unhandled color. Every color is fully
// opaque (alpha 255); pong paints everything White. Of the four added members,
// Yellow/Cyan/Magenta are the canonical full-saturation complements (the spec
// render.fun pins no RGBA for the named members, only the channel range for the
// `Rgb` escape) and Gray is the mid-channel 0.5 → 128/255 (krognid's ground
// plane).
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
	case .Yellow:
		return Rgba8{255, 255, 0, 255}
	case .Cyan:
		return Rgba8{0, 255, 255, 255}
	case .Magenta:
		return Rgba8{255, 0, 255, 255}
	case .Gray:
		return Rgba8{128, 128, 128, 255}
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

	// Atlas_Texture_Cache holds one GPU texture per distinct §19 atlas IMAGE,
	// keyed by the image's content hash (the same dedup key Asset_Image carries),
	// uploaded ONCE at session start and reused for every blit of every tick. The
	// resolved draw commands address their art by image hash + pixel rect
	// (Sprite_Texture / Tile_Texture), so a textured present looks the texture up by
	// hash here and blits the rect — no per-tick upload, no per-sprite texture
	// create. It is a present-boundary resource (impure, render-only); nothing it
	// holds re-enters the sim fold. The textures are destroyed at session teardown
	// (destroy_atlas_texture_cache), paired with creation like the device handles.
	Atlas_Texture_Cache :: struct {
		textures: map[string]^sdl.Texture,
	}

	// new_atlas_texture_cache uploads every decoded §19 image in the program to a
	// GPU texture, ONCE — one CreateTexture + UpdateTexture per distinct image hash.
	//
	// PIXEL FORMAT (the channel-order seam): Asset_Image.pixels is byte-order
	// R,G,B,A row-major (import_image's canonical RGBA8). SDL's PixelFormatEnum names
	// the PACKED 32-bit word order, so its byte order in memory is endianness-
	// dependent. ABGR8888 packs A in the high byte → on a little-endian machine the
	// bytes in memory are R,G,B,A — exactly our buffer (and SDL's own RGBA32 alias
	// resolves to ABGR8888 on little-endian for this same reason, the
	// platform-correct "byte-order R,G,B,A" choice). Using RGBA8888 instead would
	// channel-swap every pixel (its byte order is A,B,G,R on little-endian). The
	// platform alias `.RGBA32` is byte-order R,G,B,A on BOTH endiannesses, so it is
	// the portable choice. STATIC access (the image never changes after upload); the
	// pitch is width*4 bytes (the canonical RGBA8 stride). BLEND mode so a sprite's
	// alpha composites over the background (the dungeon's transparent sprite edges).
	// A failed CreateTexture for one image is skipped (that hash resolves to no
	// texture, so a sprite/tile referencing it falls back to the untextured stand-in
	// the same way an unresolved one does) — never a fault, the present stays total.
	new_atlas_texture_cache :: proc(
		renderer: ^sdl.Renderer,
		program: ^Program,
		allocator := context.allocator,
	) -> Atlas_Texture_Cache {
		cache := Atlas_Texture_Cache{textures = make(map[string]^sdl.Texture, allocator)}
		for &image in program.assets.images {
			if image.width <= 0 || image.height <= 0 || len(image.pixels) == 0 {
				continue
			}
			texture := sdl.CreateTexture(
				renderer,
				.RGBA32, // byte-order R,G,B,A on every endianness (ABGR8888 on little-endian) — matches Asset_Image.pixels
				.STATIC,
				i32(image.width),
				i32(image.height),
			)
			if texture == nil {
				continue
			}
			sdl.SetTextureBlendMode(texture, .BLEND)
			// pitch = width*4: the canonical RGBA8 row stride (4 bytes per pixel).
			sdl.UpdateTexture(texture, nil, raw_data(image.pixels), i32(image.width * 4))
			cache.textures[image.hash] = texture
		}
		return cache
	}

	// atlas_texture_for looks one image's uploaded GPU texture up by content hash, or
	// nil when no texture was uploaded for it (an image that failed CreateTexture, or
	// a hash the program never decoded). A nil return drops the blit to the untextured
	// stand-in — the same fail-closed fallback an unresolved Sprite_Texture takes.
	atlas_texture_for :: proc(cache: ^Atlas_Texture_Cache, hash: string) -> ^sdl.Texture {
		texture, present := cache.textures[hash]
		if !present {
			return nil
		}
		return texture
	}

	// destroy_atlas_texture_cache destroys every uploaded GPU texture and frees the
	// map backing — paired with new_atlas_texture_cache at session teardown, the same
	// open/close discipline live_device_close applies to the window/renderer.
	destroy_atlas_texture_cache :: proc(cache: ^Atlas_Texture_Cache) {
		for _, texture in cache.textures {
			sdl.DestroyTexture(texture)
		}
		delete(cache.textures)
	}

	// run_live_session is the live session entry main() dispatches to under
	// FUNPACK_LIVE. It parses the CLI (os.args[1] = artifact path, os.args[2] =
	// optional replay out path), loads the artifact retaining its raw bytes for the
	// content-hashed replay identity, then drives the proven live seam —
	// run_startup, then per frame { drain SDL events once into the injected queue
	// and the exit flag → resolve_tick → step_tick_persist → render_version →
	// present → record_tick → thread prev_held + the persist carrier → pace to the
	// next tick deadline }. The tick driver is step_tick_persist (NOT plain
	// step_tick, which silently drops §24 persist commands), so a Save/Restore/
	// ApplySettings a behavior emits executes against the on-disk store rooted
	// beside the artifact — live yard quicksaves on F5 and quickloads on F9. The
	// determinism record is unchanged: persist commands never ride the replay log
	// (the F5/F9 PRESSES ride the recorded input stream, so a re-fold re-runs the
	// same commands against a fresh store — save_io.odin's slot-as-refold
	// invariant). A command-less game (pong, snake, hunt) folds
	// bit-identically: both drivers share run_pipeline_fold. On exit it flushes
	// the replay (finish_replay + write_replay_file) BEFORE closing the live
	// device. Returns a process exit code (0 on a clean session, non-zero on a usage
	// or load failure). tick_hz comes SOLELY from program.entrypoint.tick_hz and the
	// window/board geometry SOLELY from its declared logical extent (§15
	// logical:WxH via live_window_for / board_extent) — never a flag — and no float
	// ever reaches sim state: pixel conversion happens only at the present boundary
	// and never feeds back into resolve_tick/step_tick_persist.
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

		// The §24 persist boundary: quicksave/quickload writes through the real
		// on-disk store rooted beside the artifact (`<stem>.saves/`). The driver
		// ensures the root exists once here — new_on_disk_store never creates it. A
		// failed create is NOT fatal: the session runs, and each Save against the
		// missing root fails closed to Result::Err, the §24 error arm the menu fold
		// records ("save failed"), never a crash and never a silent drop.
		save_root := save_root_path(artifact_path, context.allocator)
		if !os.exists(save_root) {
			_ = os.make_directory(save_root)
		}
		store := new_on_disk_store(save_root)
		carrier := new_persist_carrier(&store)

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

		// Upload the §19 atlas images to GPU textures ONCE, keyed by content hash —
		// the present pass blits a resolved sprite/tile from these by its image hash.
		// An asset-less game (pong/snake/hunt/yard) yields the empty cache and presents
		// exactly as before (every draw command falls back to the fill stand-in).
		texture_cache := new_atlas_texture_cache(device.renderer, &program)

		// The §22 live audio boundary: open the scene→device reconciler alongside the
		// render device. FAIL-CLOSED like every other audio open here — a machine with
		// no audio device (audio_live_open's InitSubSystem fails) runs the session
		// SILENT, never faulting (audio is an output, never on the determinism path).
		// The per-frame audio_live_apply below tolerates the empty voice table, so a
		// silent session still folds and presents identically.
		live_audio, _ := audio_live_open()

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
		// Time rebinds per tick inside the loop (time_resource_at) so `time.t` —
		// logical time since startup — advances each frame for a `time.t`-reading
		// render body (krognid's pose_idle bob). The derivation is replay.odin's
		// shared one, bit-identical to what a re-fold of this session binds, so any
		// digest divergence is the input source, never the clock.

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

		// BOUNDED-MEMORY SEAM (the unbounded-session reclamation). The session loops
		// forever, so a per-tick allocation that is never freed grows the heap without
		// bound. Two reclamation mechanisms compose, split by lifetime:
		//
		//   - PERSISTENT (context.allocator, `persistent` below): the committed world
		//     version chain. Each committed version aliases the prior's UNWRITTEN-row
		//     blackboard maps (structural sharing, state.odin / tick.odin), so it cannot
		//     be free_all'd — the live generational reclaimer in step_tick_persist
		//     (reclaim_live=true) retires the now-dead PRIOR version O(delta) once the
		//     next commits, freeing its tables/rows structure + the maps the tick
		//     abandoned while keeping the maps the new version still aliases (reclaim.odin).
		//   - SCRATCH (per-tick arena `scratch` below): every TRANSIENT per-tick value —
		//     the tick fold's intermediate records/lambda-envs/registry, the working
		//     tables, the signal mailbox, the input snapshot, the render draw-list and
		//     audio scene (consumed same-tick at present/audio_live_apply). These never
		//     alias the committed version, so the whole arena is freed wholesale
		//     (arena_free_all) at the END of each tick. This is what bounds the dominant
		//     per-tick allocation, which is interpreter eval garbage, not the version.
		//
		// The committed version's maps/columns clone onto `persistent` (step_tick_persist
		// commit_allocator); only the eval garbage lands on `scratch`. The determinism
		// floor is untouched: reclamation changes no committed value, digest, or replay
		// byte — a live-vs-replay capture stays bit-identical (the AC asserts it).
		persistent := context.allocator
		scratch: virtual.Arena
		if arena_err := virtual.arena_init_growing(&scratch); arena_err != nil {
			fmt.eprintln("error: failed to init the per-tick scratch arena")
			return 1
		}
		defer virtual.arena_destroy(&scratch)
		scratch_alloc := virtual.arena_allocator(&scratch)

		for tick_index := 0; ; tick_index += 1 {
			if poll_session_events(&queue) {
				break
			}

			// Logical time AT this committed tick (t = tick_index * dt); control reads
			// only dt, render's pose_idle reads t.
			time := time_resource_at(program.entrypoint.tick_hz, tick_index)

			// resolve_tick runs on the PERSISTENT allocator: held_after / levels_after are
			// THREADED forward (they become next tick's prev_held / prev_levels), so they
			// must outlive this tick's scratch reset. The snapshot it also returns is
			// consumed THIS tick (the fold reads it, record_tick serializes it) and is
			// freed explicitly below — it does not enter the committed version.
			snapshot, held_after, levels_after := resolve_tick(table, &queue, prev_held, prev_levels, persistent)
			// Thread the persistent Rng through a seeded run so each tick observes the
			// prior tick's draws (§04 §1); a seedless run threads nothing (rng stays nil).
			// The persist carrier threads alongside it: this tick delivers a PRIOR
			// tick's Save/Restore outcomes into the mailbox and hands its own emitted
			// commands to the store for next-tick delivery (§24 §1 one-tick deferral).
			//
			// ALLOCATOR SPLIT: the fold's TRANSIENT eval runs on `scratch_alloc` (freed
			// at tick end); the committed version clones onto `persistent` (commit_allocator)
			// and survives. reclaim_live=true retires the now-dead PRIOR version O(delta)
			// inside the call — render/audio below read only the NEW committed version, so
			// retiring the prior immediately after the commit is safe.
			version, carrier = step_tick_persist(&program, version, snapshot, time, carrier, scratch_alloc, seeded ? &rng : nil, persistent, true)
			// Render and audio project the COMMITTED version onto the per-tick scratch and
			// are consumed SAME-TICK (present_frame / audio_live_apply), so the arena reset
			// at the loop's end reclaims the draw-list + audio scene + their interp garbage
			// (incl. any slice-bearing Draw3_Rigged pose/handle values) — they never alias
			// the committed version.
			draw := render_version(&program, version, snapshot, time, scratch_alloc)
			present_frame(device.renderer, &texture_cache, draw, board, window)
			// Project the COMMITTED tick's §22 keyed audio scene off the same version
			// the render projection reads, and reconcile the live voice table against
			// it (§22 §1 level-triggered start/stop/bend). Like render, this reads the
			// committed version + this tick's input snapshot + the shared time record
			// and never feeds back into the sim fold — audio is a present-boundary
			// output, not a determinism input.
			audio_live_apply(&live_audio, audio_version(&program, version, snapshot, time, scratch_alloc))
			record_tick(&writer, snapshot, scratch_alloc)

			// The snapshot's two tables are on `persistent` (resolve_tick) and fully
			// consumed now — free them so a seedless session does not leak one snapshot
			// per tick on the persistent heap (held_after / levels_after carry forward
			// instead and are retired via the existing prev_* swap below).
			delete_input(snapshot)
			delete(prev_held)
			prev_held = held_after
			delete_device_levels(prev_levels)
			prev_levels = levels_after

			// Reclaim every transient per-tick allocation in one shot — the fold's eval
			// garbage, the working tables, the mailbox, the draw-list, and the audio scene.
			// The committed version chain is NOT here (it is on `persistent`, retired
			// generationally inside step_tick_persist), so this reset is the bound on the
			// dominant transient allocation and leaves the surviving version untouched.
			free_all(scratch_alloc)

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
		// Destroy the uploaded atlas textures BEFORE the renderer they belong to —
		// each texture is a renderer-owned GPU resource, so it is released ahead of
		// live_device_close's DestroyRenderer.
		destroy_atlas_texture_cache(&texture_cache)
		live_device_close(device)
		// Tear down the live audio backend alongside the render device: stop every
		// sounding voice (pause + close each device) and quit SDL's audio subsystem.
		audio_live_close(&live_audio)
		return 0
	}

	// poll_session_events is the driver-owned SINGLE PollEvent drain per frame: it
	// dispatches .QUIT and an Escape KEYDOWN to the exit flag (Escape has no §23 Key
	// variant, so the exit check claims it without touching the binding queue), and
	// routes every other bindable event through the existing
	// key_code_from_scancode / pad_code_from_button / stick_from_axis maps and the
	// enqueue_* helpers onto the injected queue. It is the live producer's ONLY
	// drain — no second PollEvent loop exists anywhere, so the window is drained
	// exactly once per tick (no double-drain) and the SDL→§23 dispatch lives in
	// one switch. Returns true when an exit was requested. SDL repeats a held key;
	// only the first down is the §23 edge, so a repeat KEYDOWN is ignored for the
	// binding queue (the level is already set).
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
	//
	// TEXTURED PRESENT (the §19 atlas blit): a Draw_Sprite with a RESOLVED texture
	// (resolve_sprite_textures bound an image hash + pixel rect) and a Draw_Tilemap's
	// resolved per-palette cells blit their atlas pixels through `cache` — the GPU
	// textures uploaded once by image hash. An UNRESOLVED sprite (resolved=false) keeps
	// the tinted-rect stand-in, and an unresolved/atlas-less tile keeps the Gray solid
	// stand-in, so an asset-less game (empty cache) presents exactly as before. The
	// blit is STRICTLY presentation — it reads the resolved reference the digest
	// already pinned headlessly and never feeds back into the sim (§10.5).
	//
	// The board and window come from the artifact's declared logical extent. Pixel
	// conversion happens ONLY here at the present boundary; nothing it computes ever
	// re-enters the sim fold (§10.5).
	present_frame :: proc(renderer: ^sdl.Renderer, cache: ^Atlas_Texture_Cache, draw: Draw_List, board: Vec2, window: Window_Px) {
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
			case Draw3_Camera:
			// DELIBERATE 2D PROJECTION (the present decision): a §20 §1 3D camera is
			// NOT projected as a true-3D view here — the present flattens the scene to
			// the existing XZ-top-down pixel grid (X→pixel X, Z→pixel Y), so the 3D
			// camera's eye/at/fov contribute no transform of their own (the board
			// geometry already supplies the orthographic frame). It paints nothing.
			case Draw3_Light:
			// A directional light has no painted primitive in a flat 2D top-down
			// projection (no shading pass) — it contributes no pixels. Carried in the
			// determinism digest, dropped at the present boundary.
			case Draw3_Plane:
				// The §20 §1 ground plane projects top-down: its XZ extent fills a
				// center-anchored rect over the XZ plane (the X/Z lanes of the Vec3 at
				// become the 2D world position, the Vec2 size is the XZ extent), the
				// same fill_world_rect the 2D rects use. This is the deliberate 2D
				// flattening — Y (height) is dropped at the boundary.
				fill_world_rect(renderer, vec3_xz(c.at), c.size, c.color, camera, board, window)
			case Draw3_Rigged:
				// The posed creature projects top-down to a small marker rect at its XZ
				// position — a deliberate stand-in for the rigged mesh under the flat 2D
				// projection (a true-3D skinned draw is out of scope; the rig STATE is
				// fully in the determinism digest, the PRESENT shows only its footprint).
				fill_world_rect(renderer, vec3_xz(c.at), RIGGED_MARKER_SIZE, .White, camera, board, window)
			case Draw_Tilemap:
				// The §18 §3 batched layer paints per-CELL only here, at the present
				// boundary (the sim-side draw-LIST carries the one batched command —
				// the §18 §3 batching is about commands, never pixels). Each cell blits
				// its palette tile's RESOLVED atlas pixels (present_tile_layer indexes
				// c.palette_textures by the cell's palette index); a cell whose tile did
				// not resolve (no atlas, a palette-less layer) falls back to the Gray
				// solid stand-in. The layer's full CONTENT is already in the
				// determinism digest — this is the textured present of it.
				present_tile_layer(renderer, cache, c.layer, c.palette_textures, camera, board, window)
			case Draw_Sprite:
				// The §18 §1 entity sprite: a RESOLVED sprite blits its atlas cell
				// pixels (blit_sprite slices c.texture's pixel rect from the GPU texture
				// the cache holds for its image hash, honoring `flip` + `tint`); an
				// UNRESOLVED sprite (resolved=false — no atlas/cell answered the §19
				// resolution) keeps the tinted-rect stand-in. The sprite's FULL state
				// (atlas, cell, flip, tint, layer) AND the resolved texture reference are
				// already in the determinism digest; this is the textured present of it.
				if c.texture.resolved {
					blit_sprite(renderer, cache, c, camera, board, window)
				} else {
					fill_world_rect(renderer, c.at, c.size, c.tint, camera, board, window)
				}
			}
		}
		sdl.RenderPresent(renderer)
	}

	// blit_sprite paints one RESOLVED §18 §1 sprite by copying its atlas cell pixels
	// onto the sprite's destination window rect. The SOURCE rect is the resolved
	// Sprite_Texture's pixel window into the atlas image (px_x/px_y/px_w/px_h); the
	// DEST rect is the sprite's center-anchored `at`/`size` projected through the same
	// camera + letterbox geometry fill_world_rect uses (world_rect_to_pixels), so a
	// textured sprite lands exactly where its untextured stand-in would. `flip` orients
	// the quad (the §20 None|X|Y|XY mirror enum → RendererFlip) and `tint` modulates
	// the source color (SetTextureColorMod — White is the identity, so an untinted
	// sprite blits its art unchanged). A missing GPU texture for the resolved hash (a
	// CreateTexture that failed at upload) drops to the tinted stand-in — fail-closed,
	// never a fault. Render-boundary-only; nothing re-enters the sim (§10.5).
	blit_sprite :: proc(renderer: ^sdl.Renderer, cache: ^Atlas_Texture_Cache, sprite: Draw_Sprite, camera: Camera_View, board: Vec2, window: Window_Px) {
		texture := atlas_texture_for(cache, sprite.texture.image_hash)
		if texture == nil {
			fill_world_rect(renderer, sprite.at, sprite.size, sprite.tint, camera, board, window)
			return
		}
		src := sdl.Rect {
			x = i32(sprite.texture.px_x),
			y = i32(sprite.texture.px_y),
			w = i32(sprite.texture.px_w),
			h = i32(sprite.texture.px_h),
		}
		dst := world_rect_to_pixels(sprite.at, sprite.size, camera, board, window)
		// Tint modulates the source pixels (White = identity, the untinted sprite's
		// art unchanged); the present's named palette lowers to the same RGBA8 a
		// filled rect would paint, so a tinted sprite reads in its §20 tint.
		rgba := draw_color_to_rgba(sprite.tint)
		sdl.SetTextureColorMod(texture, rgba.r, rgba.g, rgba.b)
		sdl.RenderCopyEx(renderer, texture, &src, &dst, 0, nil, flip_token_to_sdl(sprite.flip))
	}

	// flip_token_to_sdl maps the §20 sprite-mirroring Flip token (the case name
	// carried verbatim on Draw_Sprite.flip — None | X | Y | XY) onto SDL's
	// RenderCopyEx flip flag. X mirrors on the X axis (a horizontal flip), Y on the Y
	// axis (vertical), XY both (the OR of the two C flag bits — RendererFlip is a
	// plain c.int enum, so the combined facing is the bitwise union 0x3). An
	// unrecognized token reads as no flip (None) — the closed §20 set is the contract;
	// a malformed flip never faults the present, it blits unflipped.
	flip_token_to_sdl :: proc(flip: string) -> sdl.RendererFlip {
		switch flip {
		case "X":
			return .HORIZONTAL
		case "Y":
			return .VERTICAL
		case "XY":
			return sdl.RendererFlip(i32(sdl.RendererFlip.HORIZONTAL) | i32(sdl.RendererFlip.VERTICAL))
		}
		return .NONE
	}

	// world_rect_to_pixels projects a §20 center-anchored world rect into the integer
	// window destination rect — the SAME camera + letterbox geometry fill_world_rect
	// applies, factored out so the textured blit (RenderCopy dest) and the untextured
	// fill land a sprite/tile at the identical pixels. `at` is the CENTER (§20 anchor),
	// so the top-left corner is at − size/2 projected through camera_world_to_pixel
	// (recenter + zoom + letterbox); the extent takes only the camera zoom (a relative
	// extent, never the recenter) before the world_to_pixel ratio. Exact-integer
	// throughout (no float, §10.5); render-boundary-only.
	world_rect_to_pixels :: proc(at: Vec2, size: Vec2, camera: Camera_View, board: Vec2, window: Window_Px) -> sdl.Rect {
		half := Vec2{fixed_div(size.x, to_fixed(2)), fixed_div(size.y, to_fixed(2))}
		corner := Vec2{fixed_sub(at.x, half.x), fixed_sub(at.y, half.y)}
		top_left := camera_world_to_pixel(corner, camera, board, window)
		extent := world_to_pixel(vec2_scale(size, camera.zoom), board, window)
		return sdl.Rect{x = top_left.x, y = top_left.y, w = extent.x, h = extent.y}
	}

	// present_tile_layer paints one batched §18 §3 layer per-CELL at the present
	// boundary. Each NON-EMPTY cell resolves its palette tile's RESOLVED §19 texture
	// (palette_textures indexed by the cell's palette index) and blits that atlas cell
	// rect onto the cell's world rect — the textured terrain. A cell whose tile did NOT
	// resolve (a palette-less/atlas-less layer, or a missing GPU texture) falls back to
	// the untextured stand-in: a SOLID tile fills Gray (walls read as mass), a passable
	// tile stays unpainted (floor reads as background) — the exact prior behavior, so an
	// asset-less or unresolved layer presents as before. Cell centers come from the same
	// tilemap_center_of kernel the §18 §4 queries answer with, so the painted terrain
	// sits exactly where collision says it is; the extent is the layer's cell size on
	// both axes. Walks rows then columns (row-major, the decoded table's order);
	// present-boundary only, nothing re-enters the sim.
	present_tile_layer :: proc(
		renderer: ^sdl.Renderer,
		cache: ^Atlas_Texture_Cache,
		layer: Tile_Layer,
		palette_textures: []Tile_Texture,
		camera: Camera_View,
		board: Vec2,
		window: Window_Px,
	) {
		cell_extent := Vec2{to_fixed(layer.cell_size), to_fixed(layer.cell_size)}
		walk := layer
		for row in 0 ..< layer.rows {
			for col in 0 ..< layer.cols {
				index := layer.cells[row * layer.cols + col]
				if index == TILE_CELL_EMPTY || index < 0 || index >= len(layer.palette) {
					continue // a tile-less cell paints nothing (the void is background)
				}
				at := tilemap_center_of(&walk, i64(col), i64(row))
				// Resolved texture for this palette tile → blit the atlas cell pixels.
				if index < len(palette_textures) && palette_textures[index].resolved {
					tex := palette_textures[index]
					texture := atlas_texture_for(cache, tex.image_hash)
					if texture != nil {
						src := sdl.Rect {
							x = i32(tex.px_x),
							y = i32(tex.px_y),
							w = i32(tex.px_w),
							h = i32(tex.px_h),
						}
						dst := world_rect_to_pixels(at, cell_extent, camera, board, window)
						sdl.RenderCopy(renderer, texture, &src, &dst)
						continue
					}
				}
				// Unresolved (or no GPU texture): the untextured stand-in — Gray for a
				// solid tile, nothing for a passable one (the prior behavior).
				if layer.palette[index].solid {
					fill_world_rect(renderer, at, cell_extent, .Gray, camera, board, window)
				}
			}
		}
	}

	// vec3_xz flattens a §20 §1 world Vec3 to the 2D XZ-plane position the top-down
	// present projects through: X→world x, Z→world y (the ground plane), dropping Y
	// (height). This is the render-boundary 2D projection of the 3D draw-list; the
	// dropped Y never re-enters the sim (the result feeds fill_world_rect only).
	vec3_xz :: proc(v: Vec3) -> Vec2 {
		return Vec2{x = v.x, y = v.z}
	}

	// RIGGED_MARKER_SIZE is the fixed world-unit footprint the top-down present paints
	// for a Draw3_Rigged creature — a small 2x2 world-unit marker at its XZ position.
	// A present-only constant; the digest folds the full rig, never this marker. The
	// extent is 2.0 world units on each axis in Q32.32 (2 * FIXED_ONE).
	RIGGED_MARKER_SIZE :: Vec2{Fixed(2 * i64(FIXED_ONE)), Fixed(2 * i64(FIXED_ONE))}

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
		rect := world_rect_to_pixels(at, size, camera, board, window)
		rgba := draw_color_to_rgba(color)
		sdl.SetRenderDrawColor(renderer, rgba.r, rgba.g, rgba.b, rgba.a)
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
