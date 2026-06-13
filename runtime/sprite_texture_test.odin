// The §19 textured-sprite RESOLUTION proof (docs/artifact-format.md §19, schema
// v17; frame digest v9): a Draw_Sprite's (atlas, cell) handle pair resolves through
// asset_region against the baked [assets] section to its content-addressed image
// hash + pixel rect, and the resolved reference is folded into the §20 draw-list
// digest — the determinism PROOF that the sprite resolved to the correct atlas
// region deterministically, rather than deferring the resolution to the impure
// present boundary.
//
// THE RESOLUTION SEAM (the architecturally-honest headless deliverable). The render
// lowering carries the atlas/cell NAMES; the post-emit resolve_sprite_textures pass
// binds the §19 image hash + pixel rect (render.odin). The pass is a pure function of
// (atlas name, cell name, the program's bake) — assets are bake-static, never the COW
// version chain — so two projections of the same committed sprite resolve to the SAME
// texture bit-identically. A miss (no atlas under the handle name, or no such cell) is
// fail-closed: Sprite_Texture.resolved stays false, the no-texture fallback the
// untextured live stand-in paints, never a crash and never a guessed rect. The
// resolved reference is the impure present's INPUT; the actual pixel upload is the
// live boundary (the SDL-gated present_frame), deliberately NOT modeled here.
//
// THE v17 CROSS-BOUNDARY LINK (why the real dungeon now RESOLVES). The dungeon's
// sprites reference the atlas by its manifest HANDLE name `dungeon_atlas`
// (assets.dungeon_atlas → an AtlasHandle{name: "dungeon_atlas"} carried as a
// whole-module const, lowered to a bare `dungeon_atlas` ref the interpreter resolves
// by normal const lookup), and the v17 [assets] section now keys the atlas record by
// that SAME handle name — `atlas dungeon_atlas …` (was the .atlas-declared
// `DungeonAtlas` in v16). So asset_region("dungeon_atlas", …) resolves on the real
// artifact: every real dungeon sprite binds its (atlas, cell) to the DungeonAtlas
// image + region pixels (test_dungeon_real_sprites_lower_and_resolve). The v16
// name-bridge gap is closed at the funpack source, not worked around here.
package funpack_runtime

import "core:testing"

// DUNGEON_ATLAS_NAME is the atlas's [assets]-record name — the v17 manifest HANDLE
// name `dungeon_atlas`, the SAME name the dungeon's sprites reference (the v16
// .atlas-declared `DungeonAtlas` is retired: the v17 cross-boundary link keys the
// record by the handle name a reference names, so asset_region resolves from the
// artifact alone).
@(private = "file")
DUNGEON_ATLAS_NAME :: "dungeon_atlas"

// dungeon_program loads the committed producer-real dungeon artifact (the v17 fixture
// carrying the real [assets 2] section, the atlas keyed by handle `dungeon_atlas`) —
// the same #load-embedded artifact dungeon_acceptance_test.odin drives.
@(private = "file")
dungeon_program :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(DUNGEON_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "dungeon artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

// sprite_cmd builds a Draw_Sprite carrying only the lowered NAMES (the pre-resolution
// shape resolve_sprite_textures consumes) — the texture starts zero (resolved=false),
// exactly as draw_command_from_record leaves it.
@(private = "file")
sprite_cmd :: proc(atlas, cell: string) -> Draw_Sprite {
	return Draw_Sprite {
		atlas = atlas,
		cell = cell,
		at = Vec2{to_fixed(40), to_fixed(24)},
		size = Vec2{to_fixed(16), to_fixed(16)},
		tint = .White,
		flip = "None",
		layer = 5,
	}
}

// test_sprite_resolves_to_dungeon_atlas_region is the core resolution proof: a sprite
// addressing the DungeonAtlas by its [assets]-record name resolves through
// resolve_sprite_textures to the atlas's real image hash and the named cell's pixel
// rect — the §19 grid-coord×cell-size lowering. The rects are the dungeon atlas's
// committed regions (hero at (0,16,16,16), slime at (16,16,16,16)), so this pins the
// sprite to the CORRECT atlas pixels deterministically.
@(test)
test_sprite_resolves_to_dungeon_atlas_region :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := dungeon_program(t)
	if !ok {
		return
	}

	// The atlas's content hash and the hero cell's rect, read once from the bake so
	// the assertion is grounded in the decoded section (asset_region is the same chain
	// the resolution pass folds through).
	image, hero_region, region_ok := asset_region(&program, DUNGEON_ATLAS_NAME, "hero")
	if !testing.expect(t, region_ok) {
		return
	}

	// The resolution pass binds the hero sprite to that image + rect.
	cmds := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "hero")}
	resolve_sprite_textures(&program, cmds)
	hero := cmds[0].(Draw_Sprite)
	testing.expect(t, hero.texture.resolved)
	testing.expect_value(t, hero.texture.image_hash, image.hash)
	testing.expect_value(t, hero.texture.px_x, hero_region.px_x) // 0
	testing.expect_value(t, hero.texture.px_y, hero_region.px_y) // 16
	testing.expect_value(t, hero.texture.px_w, 16)
	testing.expect_value(t, hero.texture.px_h, 16)

	// A different cell resolves to a DIFFERENT rect off the SAME image (the §19 dedup:
	// one image, many regions) — slime at the second column of row 1.
	slime_cmds := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "slime")}
	resolve_sprite_textures(&program, slime_cmds)
	slime := slime_cmds[0].(Draw_Sprite)
	testing.expect(t, slime.texture.resolved)
	testing.expect_value(t, slime.texture.image_hash, image.hash) // same image, dedup
	testing.expect_value(t, slime.texture.px_x, 16) // shifted one cell right
	testing.expect_value(t, slime.texture.px_y, 16)

	// Determinism: re-resolving the same sprite yields the same texture (assets are
	// bake-static, the resolution is a pure function of the names + the decode).
	again := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "hero")}
	resolve_sprite_textures(&program, again)
	testing.expect(t, draw_cmd_equal(cmds[0], again[0]))
}

// test_sprite_resolution_is_in_the_digest proves the resolved texture is INSIDE the
// frame-digest comparison surface (v9): two folds of the same resolved sprite digest
// identically, a sprite resolving to a DIFFERENT region digests differently, and an
// unresolved sprite digests differently from its resolved twin — so the digest is the
// determinism proof that the sprite resolved to the right region.
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

	// Two folds of the SAME resolved sprite digest identically (a pure content hash).
	digest_a := frame_digest(empty_version, hero_list).digest
	digest_b := frame_digest(empty_version, hero_list).digest
	testing.expect_value(t, digest_b, digest_a)

	// A sprite resolving to a DIFFERENT region (slime's rect ≠ hero's) digests
	// differently — the resolved rect is folded, so the region is in the surface.
	slime := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "slime")}
	resolve_sprite_textures(&program, slime)
	slime_digest := frame_digest(empty_version, Draw_List{cmds = slime}).digest
	testing.expect(t, slime_digest != digest_a)

	// The SAME sprite NAMES but UNRESOLVED (no resolution pass run) digests
	// differently from its resolved twin — the resolved flag + hash + rect are folded,
	// so resolution moves the digest. This is the proof that resolution enters the
	// comparison surface, not just the present.
	unresolved := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "hero")} // texture left zero
	unresolved_digest := frame_digest(empty_version, Draw_List{cmds = unresolved}).digest
	testing.expect(t, unresolved_digest != digest_a)
}

// test_sprite_resolution_fail_closed proves the miss path: an unknown atlas and an
// unknown cell both fail-close — Sprite_Texture.resolved stays false with a zero
// hash/rect, never a crash and never a guessed rect (the asset_region fail-closed mold
// threaded into the resolution pass).
@(test)
test_sprite_resolution_fail_closed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := dungeon_program(t)
	if !ok {
		return
	}

	// An unknown atlas: no atlas registered under the name → unresolved.
	bad_atlas := []Draw_Cmd{sprite_cmd("NoSuchAtlas", "hero")}
	resolve_sprite_textures(&program, bad_atlas)
	ba := bad_atlas[0].(Draw_Sprite)
	testing.expect(t, !ba.texture.resolved)
	testing.expect_value(t, ba.texture.image_hash, "")
	testing.expect_value(t, ba.texture.px_w, 0)

	// An unknown cell on a REAL atlas: the atlas resolves, the cell does not → still
	// fail-closed (asset_region needs both).
	bad_cell := []Draw_Cmd{sprite_cmd(DUNGEON_ATLAS_NAME, "no_such_cell")}
	resolve_sprite_textures(&program, bad_cell)
	bc := bad_cell[0].(Draw_Sprite)
	testing.expect(t, !bc.texture.resolved)
	testing.expect_value(t, bc.texture.px_w, 0)
}

// test_dungeon_real_sprites_lower_and_resolve drives render_version over the REAL
// dungeon artifact LIVE and pins the v17 capstone facts:
//
//   (1) the dungeon's draw_hero/draw_slime/draw_chest sprites LOWER into the
//       draw-list. `assets.dungeon_atlas` is a whole-module const carried into
//       [functions] and lowered to a bare `dungeon_atlas` ref the interpreter
//       resolves by normal const lookup to an AtlasHandle{name: "dungeon_atlas"} —
//       no `assets`-receiver interception. The draw-list carries one Draw_Tilemap
//       (terrain) + the entity sprites.
//   (2) every real dungeon sprite now RESOLVES to its DungeonAtlas region — the v17
//       cross-boundary link keys the [assets] atlas record by the SAME handle name
//       `dungeon_atlas` the sprite references, so asset_region resolves the real
//       artifact (resolved=true, the real image hash + the named cell's pixel rect).
@(test)
test_dungeon_real_sprites_lower_and_resolve :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program, ok := dungeon_program(t)
	if !ok {
		return
	}
	// The atlas's image + the hero cell's rect, read once from the bake — the
	// resolved sprites must bind exactly these.
	image, hero_region, region_ok := asset_region(&program, DUNGEON_ATLAS_NAME, "hero")
	if !testing.expect(t, region_ok) {
		return
	}

	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := time_resource_at(program.entrypoint.tick_hz, 0, context.temp_allocator)
	version = step_tick(&program, version, empty(), time, context.temp_allocator)
	draw := render_version(&program, version, empty(), time, context.temp_allocator)

	// (1) the sprites lower (no longer dropped). tick-0 spawns 1 hero + 2 slimes + 1
	// chest, each emitting one Draw::Sprite — 4 entity sprites — plus the 1 batched
	// terrain Draw_Tilemap.
	sprite_count := 0
	tilemap_count := 0
	for cmd in draw.cmds {
		#partial switch c in cmd {
		case Draw_Sprite:
			sprite_count += 1
			// (2) every real dungeon sprite carries the handle name AND resolves — the
			// v17 link closed the bridge, so resolved=true against the real DungeonAtlas.
			testing.expect_value(t, c.atlas, "dungeon_atlas")
			testing.expect(t, c.texture.resolved)
			testing.expect_value(t, c.texture.image_hash, image.hash)
		case Draw_Tilemap:
			tilemap_count += 1
		}
	}
	testing.expect_value(t, sprite_count, 4) // hero + 2 slimes + chest
	testing.expect_value(t, tilemap_count, 1) // the batched terrain layer

	// The hero sprite addresses the `hero` cell at the hero's spawn center, and now
	// resolves to the hero cell's pixel rect (the v17 link binds the pixels).
	for cmd in draw.cmds {
		if s, is := cmd.(Draw_Sprite); is && s.cell == "hero" {
			testing.expect_value(t, s.layer, i64(5))
			testing.expect(t, s.texture.resolved)
			testing.expect_value(t, s.texture.px_x, hero_region.px_x)
			testing.expect_value(t, s.texture.px_y, hero_region.px_y)
			return
		}
	}
	testing.expect(t, false) // a hero sprite must be present
}
