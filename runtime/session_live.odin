package funpack_runtime

import "core:bytes"
import "core:encoding/base64"
import "core:fmt"
import "core:image"
import qoi "core:image/qoi"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

import sdl "vendor:sdl2"

SESSION_LIVE_SDL_ALIVE :: sdl.Event

SESSION_LIVE_OS_ALIVE :: os.Error
SESSION_LIVE_FMT_ALIVE :: fmt.Info

SESSION_LIVE_VIRTUAL_ALIVE :: virtual.Arena

SESSION_LIVE_BYTES_ALIVE :: bytes.Buffer
SESSION_LIVE_BASE64_ALIVE :: base64.PADDING
SESSION_LIVE_IMAGE_ALIVE :: image.Image
SESSION_LIVE_QOI_ALIVE :: qoi.Error

replay_out_path :: proc(artifact_path: string, override: string, allocator := context.allocator) -> string {
	if override != "" {
		return strings.clone(override, allocator)
	}
	ext := filepath.ext(artifact_path)
	stem := artifact_path[:len(artifact_path) - len(ext)]
	return strings.concatenate({stem, ".replay"}, allocator)
}

save_root_path :: proc(artifact_path: string, allocator := context.allocator) -> string {
	ext := filepath.ext(artifact_path)
	stem := artifact_path[:len(artifact_path) - len(ext)]
	return strings.concatenate({stem, ".saves"}, allocator)
}

Window_Px :: struct {
	w: i32,
	h: i32,
}

LIVE_TARGET_PX :: 640

live_window_for :: proc(logical_w: int, logical_h: int) -> Window_Px {
	scale := min(LIVE_TARGET_PX / logical_w, LIVE_TARGET_PX / logical_h)
	if scale < 1 {
		scale = 1
	}
	return Window_Px{w = i32(logical_w * scale), h = i32(logical_h * scale)}
}

board_extent :: proc(logical_w: int, logical_h: int) -> Vec2 {
	return Vec2{to_fixed(i64(logical_w)), to_fixed(i64(logical_h))}
}

Pixel :: struct {
	x: i32,
	y: i32,
}

world_axis_to_pixel :: proc(world: Fixed, window_px: i32, board: Fixed) -> i32 {
	if board == 0 {
		return 0
	}
	return i32((i128(world) * i128(window_px)) / i128(board))
}

world_to_pixel :: proc(world: Vec2, board: Vec2, window: Window_Px) -> Pixel {
	return Pixel {
		x = world_axis_to_pixel(world.x, window.w, board.x),
		y = world_axis_to_pixel(world.y, window.h, board.y),
	}
}

Camera_View :: struct {
	at:   Vec2,
	zoom: Fixed,
}

identity_camera :: proc(board: Vec2) -> Camera_View {
	return Camera_View{at = Vec2{fixed_div(board.x, to_fixed(2)), fixed_div(board.y, to_fixed(2))}, zoom = to_fixed(1)}
}

camera_from_command :: proc(cmd: Draw_Camera) -> Camera_View {
	zoom := cmd.zoom
	if zoom == 0 {
		zoom = to_fixed(1)
	}
	return Camera_View{at = cmd.at, zoom = zoom}
}

camera_pre_transform :: proc(world: Vec2, camera: Camera_View, board: Vec2) -> Vec2 {
	board_center := Vec2{fixed_div(board.x, to_fixed(2)), fixed_div(board.y, to_fixed(2))}
	offset := vec2_scale(vec2_sub(world, camera.at), camera.zoom)
	return vec2_add(board_center, offset)
}

camera_world_to_pixel :: proc(world: Vec2, camera: Camera_View, board: Vec2, window: Window_Px) -> Pixel {
	return world_to_pixel(camera_pre_transform(world, camera, board), board, window)
}

Rgba8 :: struct {
	r: u8,
	g: u8,
	b: u8,
	a: u8,
}

draw_color_to_rgba :: proc(color: Draw_Color) -> Rgba8 {
	switch color.kind {
	case .Named:
		switch color.palette {
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
	case .Rgb:
		return Rgba8 {
			r = channel_to_u8(color.r),
			g = channel_to_u8(color.g),
			b = channel_to_u8(color.b),
			a = 255,
		}
	}
	return Rgba8{255, 255, 255, 255}
}

channel_to_u8 :: proc(channel: Fixed) -> u8 {
	clamped := fixed_clamp(channel, Fixed(0), FIXED_ONE)
	scaled := fixed_round(fixed_mul(clamped, to_fixed(255)))
	return u8(scaled)
}

GLYPH_COLS :: 3
GLYPH_ROWS :: 5

DIGIT_GLYPHS :: [10][GLYPH_ROWS]u8 {
	{0b111, 0b101, 0b101, 0b101, 0b111},
	{0b010, 0b110, 0b010, 0b010, 0b111},
	{0b111, 0b001, 0b111, 0b100, 0b111},
	{0b111, 0b001, 0b111, 0b001, 0b111},
	{0b101, 0b101, 0b111, 0b001, 0b001},
	{0b111, 0b100, 0b111, 0b001, 0b111},
	{0b111, 0b100, 0b111, 0b101, 0b111},
	{0b111, 0b001, 0b001, 0b001, 0b001},
	{0b111, 0b101, 0b111, 0b101, 0b111},
	{0b111, 0b101, 0b111, 0b001, 0b111},
}

LETTER_GLYPHS :: [26][GLYPH_ROWS]u8 {
	{0b010, 0b101, 0b111, 0b101, 0b101},
	{0b110, 0b101, 0b110, 0b101, 0b110},
	{0b011, 0b100, 0b100, 0b100, 0b011},
	{0b110, 0b101, 0b101, 0b101, 0b110},
	{0b111, 0b100, 0b110, 0b100, 0b111},
	{0b111, 0b100, 0b110, 0b100, 0b100},
	{0b011, 0b100, 0b101, 0b101, 0b011},
	{0b101, 0b101, 0b111, 0b101, 0b101},
	{0b111, 0b010, 0b010, 0b010, 0b111},
	{0b001, 0b001, 0b001, 0b101, 0b010},
	{0b101, 0b101, 0b110, 0b101, 0b101},
	{0b100, 0b100, 0b100, 0b100, 0b111},
	{0b101, 0b111, 0b111, 0b101, 0b101},
	{0b110, 0b101, 0b101, 0b101, 0b101},
	{0b010, 0b101, 0b101, 0b101, 0b010},
	{0b110, 0b101, 0b110, 0b100, 0b100},
	{0b010, 0b101, 0b101, 0b010, 0b001},
	{0b110, 0b101, 0b110, 0b101, 0b101},
	{0b011, 0b100, 0b010, 0b001, 0b110},
	{0b111, 0b010, 0b010, 0b010, 0b010},
	{0b101, 0b101, 0b101, 0b101, 0b111},
	{0b101, 0b101, 0b101, 0b101, 0b010},
	{0b101, 0b101, 0b111, 0b111, 0b101},
	{0b101, 0b101, 0b010, 0b101, 0b101},
	{0b101, 0b101, 0b010, 0b010, 0b010},
	{0b111, 0b001, 0b010, 0b100, 0b111},
}

TOFU_GLYPH :: [GLYPH_ROWS]u8{0b111, 0b111, 0b111, 0b111, 0b111}

glyph_lookup :: proc(ch: rune) -> (glyph: [GLYPH_ROWS]u8, draws: bool) {
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
			bit := (mask >> u8(GLYPH_COLS - 1 - col)) & 1
			if bit == 0 {
				continue
			}
			at := Vec2 {
				fixed_add(fixed_add(origin.x, fixed_mul(cell.x, to_fixed(i64(col)))), half.x),
				fixed_add(fixed_add(origin.y, fixed_mul(cell.y, to_fixed(i64(row)))), half.y),
			}
			append(&rects, Draw_Rect{at = at, size = cell, color = color})
		}
	}
	return rects[:]
}

TEXT_CELL :: Vec2{Fixed(2 << 32), Fixed(2 << 32)}

TEXT_GLYPH_ADVANCE :: Fixed((GLYPH_COLS + 1) * 2) << 32

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

when #config(FUNPACK_LIVE, false) {
	session_capture_frame :: proc(
		program: ^Program,
		draw: Draw_List,
		allocator := context.allocator,
	) -> (
		encoded: string,
		width: int,
		height: int,
		ok: bool,
	) {
		if .VIDEO not_in sdl.WasInit(sdl.INIT_VIDEO) {
			if !sdl.SetHint("SDL_VIDEODRIVER", "dummy") {
				_ = os.set_env("SDL_VIDEODRIVER", "dummy")
			}
			if sdl.Init(sdl.INIT_VIDEO) != 0 {
				return "", 0, 0, false
			}
		}

		window := live_window_for(program.entrypoint.logical_w, program.entrypoint.logical_h)
		board := board_extent(program.entrypoint.logical_w, program.entrypoint.logical_h)

		surface := sdl.CreateRGBSurfaceWithFormat(0, window.w, window.h, 32, u32(sdl.PixelFormatEnum.RGBA32))
		if surface == nil {
			return "", 0, 0, false
		}
		defer sdl.FreeSurface(surface)
		renderer := sdl.CreateSoftwareRenderer(surface)
		if renderer == nil {
			return "", 0, 0, false
		}
		defer sdl.DestroyRenderer(renderer)

		cache := new_atlas_texture_cache(renderer, program, allocator)
		defer destroy_atlas_texture_cache(&cache)
		present_frame(renderer, &cache, draw, board, window)

		pitch := int(window.w) * 4
		rgba := make([]u8, pitch * int(window.h), allocator)
		defer delete(rgba, allocator)
		if sdl.RenderReadPixels(renderer, nil, u32(sdl.PixelFormatEnum.RGBA32), raw_data(rgba), i32(pitch)) != 0 {
			return "", 0, 0, false
		}

		img := image.Image {
			width    = int(window.w),
			height   = int(window.h),
			channels = 4,
			depth    = 8,
		}
		bytes.buffer_init(&img.pixels, rgba)
		qoi_buf: bytes.Buffer
		if encode_err := qoi.save_to_buffer(&qoi_buf, &img, qoi.Options{}, allocator); encode_err != nil {
			return "", 0, 0, false
		}
		defer bytes.buffer_destroy(&qoi_buf)
		out := base64.encode(bytes.buffer_to_bytes(&qoi_buf), base64.ENC_TABLE, allocator)
		return out, int(window.w), int(window.h), true
	}
} else {
	session_capture_frame :: proc(
		program: ^Program,
		draw: Draw_List,
		allocator := context.allocator,
	) -> (
		encoded: string,
		width: int,
		height: int,
		ok: bool,
	) {
		_, _, _ = program, draw, allocator
		return "", 0, 0, false
	}
}

when #config(FUNPACK_LIVE, false) {

	Atlas_Texture_Cache :: struct {
		textures: map[string]^sdl.Texture,
	}

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
				.RGBA32,
				.STATIC,
				i32(image.width),
				i32(image.height),
			)
			if texture == nil {
				continue
			}
			sdl.SetTextureBlendMode(texture, .BLEND)
			sdl.UpdateTexture(texture, nil, raw_data(image.pixels), i32(image.width * 4))
			cache.textures[image.hash] = texture
		}
		return cache
	}

	atlas_texture_for :: proc(cache: ^Atlas_Texture_Cache, hash: string) -> ^sdl.Texture {
		texture, present := cache.textures[hash]
		if !present {
			return nil
		}
		return texture
	}

	destroy_atlas_texture_cache :: proc(cache: ^Atlas_Texture_Cache) {
		for _, texture in cache.textures {
			sdl.DestroyTexture(texture)
		}
		delete(cache.textures)
	}

	run_live_session :: proc(args: []string) -> int {
		usage := "usage:\n  funpack live <artifact-path> [replay-out-path]   play a built game artifact\n  funpack run                                       build and play in one step\n  funpack attach <artifact-path>                    open an introspection session\n\nThe artifact is produced by `funpack build` (at .funpack/artifact)."
		if len(args) >= 2 && (args[1] == "--help" || args[1] == "-h") {
			fmt.println(usage)
			return 0
		}
		if len(args) < 2 {
			fmt.eprintln(usage)
			return 2
		}
		live_args, args_ok := parse_live_argv(args)
		if !args_ok {
			fmt.eprintln(usage)
			return 2
		}
		artifact_path := live_args.artifact
		override := live_args.out_override

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

		save_root := save_root_path(artifact_path, context.allocator)
		if !os.exists(save_root) {
			_ = os.make_directory(save_root)
		}
		store := new_on_disk_store(save_root)
		carrier := new_persist_carrier(&store)

		window := live_window_for(program.entrypoint.logical_w, program.entrypoint.logical_h)
		board := board_extent(program.entrypoint.logical_w, program.entrypoint.logical_h)

		device, dev_ok := live_device_open(window.w, window.h)
		if !dev_ok {
			fmt.eprintln("error: SDL device open failed (no display/GPU?)")
			return 1
		}

		texture_cache := new_atlas_texture_cache(device.renderer, &program)

		live_audio, _ := audio_live_open()

		table := build_bindings_table(program, IDENTITY_OVERLAY)
		queue := new_device_queue()

		uses_rng := program_uses_rng(&program)
		root_seed := resolve_root_seed(live_args.seed, program.entrypoint)

		identity :=
			uses_rng ? identity_from_program_seeded(program, string(artifact_bytes), root_seed) : identity_from_program(program, string(artifact_bytes))
		writer := open_replay_writer(identity)

		world := new_world(program)
		base := initial_version(world)
		version: World_Version
		rng: Rng
		if uses_rng {
			version, rng = run_startup_rooted(&program, base, root_seed)
		} else {
			version = run_startup(&program, base)
		}

		prev_held := make(map[Player_Action]bool)

		prev_levels := new_device_levels()

		freq := sdl.GetPerformanceFrequency()
		start := sdl.GetPerformanceCounter()
		tick_hz_u64 := u64(program.entrypoint.tick_hz)

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

			time := time_resource_at(program.entrypoint.tick_hz, tick_index)

			snapshot, held_after, levels_after := resolve_tick(table, &queue, prev_held, prev_levels, persistent)
			version, carrier = step_tick_persist(&program, version, snapshot, time, carrier, scratch_alloc, uses_rng ? &rng : nil, persistent, true)
			draw := render_version(&program, version, snapshot, time, scratch_alloc)
			present_frame(device.renderer, &texture_cache, draw, board, window)
			audio_live_apply(&live_audio, audio_version(&program, version, snapshot, time, scratch_alloc))
			record_tick(&writer, snapshot, scratch_alloc)

			delete_input(snapshot)
			delete(prev_held)
			prev_held = held_after
			delete_device_levels(prev_levels)
			prev_levels = levels_after

			// Wholesale-free the tick's transient eval; the committed world survives because step_tick_persist commits onto `persistent`, not scratch.
			free_all(scratch_alloc)

			pace_to_deadline(start, freq, tick_hz_u64, tick_index)
		}

		log_bytes := finish_replay(&writer)
		if !write_replay_file(out_path, log_bytes) {
			fmt.eprintfln("warning: failed to write replay log %s", out_path)
		} else {
			fmt.printfln("wrote replay log %s", out_path)
		}
		destroy_atlas_texture_cache(&texture_cache)
		live_device_close(device)
		audio_live_close(&live_audio)
		return 0
	}

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
			case .MOUSEBUTTONDOWN:
				if code, named := mouse_code_from_button(event.button.button); named {
					enqueue_mouse_down(queue, code)
				}
			case .MOUSEBUTTONUP:
				if code, named := mouse_code_from_button(event.button.button); named {
					enqueue_mouse_up(queue, code)
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
			case Draw3_Camera:
			case Draw3_Light:
			case Draw3_Plane:
				fill_world_rect(renderer, vec3_xz(c.at), c.size, c.color, camera, board, window)
			case Draw3_Rigged:
				fill_world_rect(renderer, vec3_xz(c.at), RIGGED_MARKER_SIZE, named_color(.White), camera, board, window)
			case Draw_Tilemap:
				present_tile_layer(renderer, cache, c.layer, c.palette_textures, camera, board, window)
			case Draw_Sprite:
				if c.texture.resolved {
					blit_sprite(renderer, cache, c, camera, board, window)
				} else {
					fill_world_rect(renderer, c.at, c.size, c.tint, camera, board, window)
				}
			}
		}
		sdl.RenderPresent(renderer)
	}

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
		rgba := draw_color_to_rgba(sprite.tint)
		sdl.SetTextureColorMod(texture, rgba.r, rgba.g, rgba.b)
		sdl.RenderCopyEx(renderer, texture, &src, &dst, 0, nil, flip_token_to_sdl(sprite.flip))
	}

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

	world_rect_to_pixels :: proc(at: Vec2, size: Vec2, camera: Camera_View, board: Vec2, window: Window_Px) -> sdl.Rect {
		half := Vec2{fixed_div(size.x, to_fixed(2)), fixed_div(size.y, to_fixed(2))}
		corner := Vec2{fixed_sub(at.x, half.x), fixed_sub(at.y, half.y)}
		top_left := camera_world_to_pixel(corner, camera, board, window)
		extent := world_to_pixel(vec2_scale(size, camera.zoom), board, window)
		return sdl.Rect{x = top_left.x, y = top_left.y, w = extent.x, h = extent.y}
	}

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
					continue
				}
				at := tilemap_center_of(&walk, i64(col), i64(row))
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
				if layer.palette[index].solid {
					fill_world_rect(renderer, at, cell_extent, named_color(.Gray), camera, board, window)
				}
			}
		}
	}

	vec3_xz :: proc(v: Vec3) -> Vec2 {
		return Vec2{x = v.x, y = v.z}
	}

	RIGGED_MARKER_SIZE :: Vec2{Fixed(2 * i64(FIXED_ONE)), Fixed(2 * i64(FIXED_ONE))}

	active_camera :: proc(draw: Draw_List, board: Vec2) -> Camera_View {
		camera := identity_camera(board)
		for cmd in draw.cmds {
			if cam, is_camera := cmd.(Draw_Camera); is_camera {
				camera = camera_from_command(cam)
			}
		}
		return camera
	}

	fill_world_rect :: proc(renderer: ^sdl.Renderer, at: Vec2, size: Vec2, color: Draw_Color, camera: Camera_View, board: Vec2, window: Window_Px) {
		rect := world_rect_to_pixels(at, size, camera, board, window)
		rgba := draw_color_to_rgba(color)
		sdl.SetRenderDrawColor(renderer, rgba.r, rgba.g, rgba.b, rgba.a)
		sdl.RenderFillRect(renderer, &rect)
	}

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
			ms := remaining * 1000 / freq
			if ms > 1 {
				sdl.Delay(u32(ms - 1))
			}
		}
	}
} else {
	run_live_session :: proc(args: []string) -> int {
		_ = args
		fmt.eprintln(
			"funpack: this build has no live runtime (compiled without FUNPACK_LIVE); rebuild with -define:FUNPACK_LIVE=true",
		)
		return 2
	}
}
