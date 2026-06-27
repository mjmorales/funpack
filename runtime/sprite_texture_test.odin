package funpack_runtime

import "core:testing"

@(private = "file")
DUNGEON_ATLAS_NAME :: "dungeon_atlas"

@(private = "file")
dungeon_program :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(DUNGEON_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "dungeon artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

@(private = "file")
sprite_cmd :: proc(atlas, cell: string) -> Draw_Sprite {
	return Draw_Sprite {
		atlas = atlas,
		cell = cell,
		at = Vec2{to_fixed(40), to_fixed(24)},
		size = Vec2{to_fixed(16), to_fixed(16)},
		tint = named_color(.White),
		flip = "None",
		layer = 5,
	}
}

@(test)
test_sprite_resolves_to_dungeon_atlas_region :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := dungeon_program(t)
	if !ok {
		return
	}

	image, hero_region, region_ok := asset_region(&program, DUNGEON_ATLAS_NAME, "hero")
	if !testing.expect(t, region_ok) {
		return
	}

	cmds := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "hero")}
	resolve_sprite_textures(&program, cmds)
	hero := cmds[0].(Draw_Sprite)
	testing.expect(t, hero.texture.resolved)
	testing.expect_value(t, hero.texture.image_hash, image.hash)
	testing.expect_value(t, hero.texture.px_x, hero_region.px_x)
	testing.expect_value(t, hero.texture.px_y, hero_region.px_y)
	testing.expect_value(t, hero.texture.px_w, 16)
	testing.expect_value(t, hero.texture.px_h, 16)

	slime_cmds := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "slime")}
	resolve_sprite_textures(&program, slime_cmds)
	slime := slime_cmds[0].(Draw_Sprite)
	testing.expect(t, slime.texture.resolved)
	testing.expect_value(t, slime.texture.image_hash, image.hash)
	testing.expect_value(t, slime.texture.px_x, 16)
	testing.expect_value(t, slime.texture.px_y, 16)

	again := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "hero")}
	resolve_sprite_textures(&program, again)
	testing.expect(t, draw_cmd_equal(cmds[0], again[0]))
}

@(test)
test_sprite_resolution_is_in_the_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := dungeon_program(t)
	if !ok {
		return
	}
	empty_version := World_Version{tick = 0, tables = nil}

	hero := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "hero")}
	resolve_sprite_textures(&program, hero)
	hero_list := Draw_List{cmds = hero}

	digest_a := frame_digest(empty_version, hero_list).digest
	digest_b := frame_digest(empty_version, hero_list).digest
	testing.expect_value(t, digest_b, digest_a)

	slime := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "slime")}
	resolve_sprite_textures(&program, slime)
	slime_digest := frame_digest(empty_version, Draw_List{cmds = slime}).digest
	testing.expect(t, slime_digest != digest_a)

	unresolved := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "hero")}
	unresolved_digest := frame_digest(empty_version, Draw_List{cmds = unresolved}).digest
	testing.expect(t, unresolved_digest != digest_a)
}

@(test)
test_sprite_resolution_fail_closed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := dungeon_program(t)
	if !ok {
		return
	}

	bad_atlas := []Draw_Cmd{sprite_cmd("NoSuchAtlas", "hero")}
	resolve_sprite_textures(&program, bad_atlas)
	ba := bad_atlas[0].(Draw_Sprite)
	testing.expect(t, !ba.texture.resolved)
	testing.expect_value(t, ba.texture.image_hash, "")
	testing.expect_value(t, ba.texture.px_w, 0)

	bad_cell := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "no_such_cell")}
	resolve_sprite_textures(&program, bad_cell)
	bc := bad_cell[0].(Draw_Sprite)
	testing.expect(t, !bc.texture.resolved)
	testing.expect_value(t, bc.texture.px_w, 0)
}

@(test)
test_dungeon_real_sprites_lower_and_resolve :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := dungeon_program(t)
	if !ok {
		return
	}
	image, hero_region, region_ok := asset_region(&program, DUNGEON_ATLAS_NAME, "hero")
	if !testing.expect(t, region_ok) {
		return
	}

	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := time_resource_at(program.entrypoint.tick_hz, 0, context.temp_allocator)
	version = step_tick(&program, version, empty(), time, context.temp_allocator)
	draw := render_version(&program, version, empty(), time, context.temp_allocator)

	sprite_count := 0
	tilemap_count := 0
	for cmd in draw.cmds {
		#partial switch c in cmd {
		case Draw_Sprite:
			sprite_count += 1
			testing.expect_value(t, c.atlas, "dungeon_atlas")
			testing.expect(t, c.texture.resolved)
			testing.expect_value(t, c.texture.image_hash, image.hash)
		case Draw_Tilemap:
			tilemap_count += 1
		}
	}
	testing.expect_value(t, sprite_count, 4)
	testing.expect_value(t, tilemap_count, 1)

	for cmd in draw.cmds {
		if s, is := cmd.(Draw_Sprite); is && s.cell == "hero" {
			testing.expect_value(t, s.layer, i64(5))
			testing.expect(t, s.texture.resolved)
			testing.expect_value(t, s.texture.px_x, hero_region.px_x)
			testing.expect_value(t, s.texture.px_y, hero_region.px_y)
			return
		}
	}
	testing.expect(t, false)
}
