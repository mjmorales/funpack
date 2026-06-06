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

// --- score-readout layout (pure, compiled in every build) -----------------

// SCORE_CELL is the world-unit size of one block-digit grid cell in the live
// score readout: 2x2 world units, so a 3x5 glyph is 6x10 world units (24x40 px at
// the 4x window scale) — large enough to read against the 160x120 board. The cell
// is the unit digit_rects scales each lit cell by; SCORE_GLYPH_ADVANCE steps the
// cursor one glyph-width-plus-gap to the right between digits.
SCORE_CELL :: Vec2{Fixed(2 << 32), Fixed(2 << 32)}

// SCORE_GLYPH_ADVANCE is the horizontal cursor step between two score digits: the
// glyph's 3 cells wide plus one blank cell of gap, in world units (4 * cell.x), so
// adjacent digits never touch.
SCORE_GLYPH_ADVANCE :: Fixed((DIGIT_GLYPH_COLS + 1) * 2) << 32

// SCORE_ORIGIN is the top-left world position the score readout starts at — near
// the top of the 160x120 board, inset from the left edge. Both the live present
// and a headless layout test read it, so the position is one named constant.
SCORE_ORIGIN :: Vec2{Fixed(8 << 32), Fixed(8 << 32)}

// score_digit_rects emits the §20 rects that draw a score string (the digits of
// "{left}   {right}") at SCORE_ORIGIN, advancing the cursor SCORE_GLYPH_ADVANCE per
// character through digit_rects. It is pure all-fixed-point geometry off the kernel
// (no SDL, no float), so it compiles in every build and the live present pass paints
// its result the same way it paints the artifact's own Draw_Rects.
score_digit_rects :: proc(score_text: string, allocator := context.allocator) -> []Draw_Rect {
	rects := make([dynamic]Draw_Rect, allocator)
	cursor := SCORE_ORIGIN
	for ch in score_text {
		glyph := digit_rects(ch, cursor, SCORE_CELL, allocator)
		for rect in glyph {
			append(&rects, rect)
		}
		delete(glyph, allocator)
		cursor.x = fixed_add(cursor.x, SCORE_GLYPH_ADVANCE)
	}
	return rects[:]
}

// --- the live session driver (when-gated: the ONLY SDL-calling code here) ---

when #config(FUNPACK_LIVE, false) {

	// LIVE_WINDOW is the fixed window extent the live session opens: 640x480, an
	// exact 4x integer scale of pong's 160x120 board, so world_to_pixel lands every
	// world unit on a 4-pixel cell with no rounding. The driver opens the live device
	// at this extent and projects the draw-list against it every frame.
	LIVE_WINDOW :: Window_Px{640, 480}

	// PONG_BOARD_LIVE is the §28 pong board extent in raw Q32.32 bits (160x120 world
	// units) the present pass projects against — the same geometry the headless pixel
	// rails are pinned to. world_to_pixel cancels the Q32.32 scale in the
	// world/board ratio, so the projection is exact-integer with no float.
	PONG_BOARD_LIVE :: Vec2{Fixed(687194767360), Fixed(515396075520)}

	// run_live_session is the live session entry main() dispatches to under
	// FUNPACK_LIVE. It parses the CLI (os.args[1] = artifact path, os.args[2] =
	// optional replay out path), loads the artifact retaining its raw bytes for the
	// content-hashed replay identity, then drives the proven live seam —
	// run_startup, then per frame { drain SDL events once into the injected queue
	// and the exit flag → resolve_tick → step_tick → render_version → present →
	// record_tick → thread prev_held → pace to the next tick deadline }. On exit it
	// flushes the replay (finish_replay + write_replay_file) BEFORE closing the live
	// device. Returns a process exit code (0 on a clean session, non-zero on a usage
	// or load failure). tick_hz comes SOLELY from program.entrypoint.tick_hz — never
	// a flag — and no float ever reaches sim state: pixel conversion happens only at
	// the present boundary and never feeds back into resolve_tick/step_tick.
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

		device, dev_ok := live_device_open(LIVE_WINDOW.w, LIVE_WINDOW.h)
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
		identity := identity_from_program(program, string(artifact_bytes))
		writer := open_replay_writer(identity)

		world := new_world(program)
		version := run_startup(&program, initial_version(world))
		time := live_time(program.entrypoint.tick_hz)

		// prev_held threads each resolve_tick's held_after into the next so released
		// edges fire correctly; tick 0 seeds it empty (no button was down before it).
		prev_held := make(map[Player_Action]bool)

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

			snapshot, held_after := resolve_tick(table, &queue, prev_held)
			version = step_tick(&program, version, snapshot, time)
			draw := render_version(&program, version, snapshot, time)
			present_frame(device.renderer, draw)
			record_tick(&writer, snapshot)

			delete(prev_held)
			prev_held = held_after

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
	// to black, then per Draw_Rect project at/size through world_to_pixel (the same
	// exact-integer projection the headless rails pin) + draw_color_to_rgba and
	// RenderFillRect, then per Draw_Text emit the block-digit score glyphs through
	// score_digit_rects, then RenderPresent. Pixel conversion happens ONLY here at
	// the present boundary; nothing it computes ever re-enters the sim fold (§10.5).
	present_frame :: proc(renderer: ^sdl.Renderer, draw: Draw_List) {
		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		sdl.RenderClear(renderer)

		for cmd in draw.cmds {
			switch c in cmd {
			case Draw_Rect:
				fill_world_rect(renderer, c.at, c.size, c.color)
			case Draw_Text:
				// The score text lowers to block-digit rects at the fixed score layout;
				// the interpolated columns ("{left}   {right}") render as White glyphs.
				glyphs := score_digit_rects(c.text, context.temp_allocator)
				for rect in glyphs {
					fill_world_rect(renderer, rect.at, rect.size, rect.color)
				}
			}
		}
		sdl.RenderPresent(renderer)
	}

	// fill_world_rect projects one world-space rect (top-left + size, both fixed
	// point) into integer window pixels through world_to_pixel — the position and the
	// size go through the SAME ratio, so the rect's pixel extent is the size projected
	// against the board exactly like the position — sets the draw color from the §20
	// palette, and fills it. The whole conversion is render-boundary-only integer
	// arithmetic; no result feeds back into the sim.
	fill_world_rect :: proc(renderer: ^sdl.Renderer, at: Vec2, size: Vec2, color: Draw_Color) {
		top_left := world_to_pixel(at, PONG_BOARD_LIVE, LIVE_WINDOW)
		extent := world_to_pixel(size, PONG_BOARD_LIVE, LIVE_WINDOW)
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
