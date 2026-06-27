package funpack_runtime

import "core:testing"

@(test)
test_assets_decode_round_trips :: proc(t: ^testing.T) {
	loaded, err := load_program(DUNGEON_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden dungeon artifact must load, got %v", err) {
		return
	}
	program := loaded

	testing.expect_value(t, len(program.assets.images), 1)
	image := program.assets.images[0]
	testing.expect_value(t, image.width, 64)
	testing.expect_value(t, image.height, 32)
	testing.expect_value(t, len(image.pixels), 64 * 32 * 4)

	testing.expect_value(t, len(program.assets.atlases), 1)
	atlas := program.assets.atlases[0]
	testing.expect_value(t, atlas.name, "dungeon_atlas")
	testing.expect_value(t, atlas.image_hash, image.hash)
	testing.expect_value(t, len(atlas.regions), 8)

	floor := atlas.regions[0]
	testing.expect_value(t, floor.name, "floor")
	testing.expect_value(t, floor.px_x, 0)
	testing.expect_value(t, floor.px_y, 0)
	testing.expect_value(t, floor.px_w, 16)
	testing.expect_value(t, floor.px_h, 16)

	resolved_image, resolved_region, ok := asset_region(&program, "dungeon_atlas", "floor")
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, resolved_image.width, 64)
	testing.expect_value(t, len(resolved_image.pixels), 8192)
	testing.expect_value(t, resolved_region.px_w, 16)

	_, _, hero_ok := asset_region(&program, "dungeon_atlas", "hero")
	testing.expect(t, hero_ok)
	_, _, unknown_atlas := asset_region(&program, "NoSuchAtlas", "floor")
	testing.expect(t, !unknown_atlas)
	_, _, unknown_cell := asset_region(&program, "dungeon_atlas", "no_such_cell")
	testing.expect(t, !unknown_cell)

	reloaded, reload_err := load_program(DUNGEON_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, reload_err, Artifact_Error.None)
	testing.expect(t, asset_sets_equal(program.assets, reloaded.assets))
}
