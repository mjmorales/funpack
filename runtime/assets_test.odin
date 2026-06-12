// The §19 [assets] decode round-trip proof (docs/artifact-format.md §19, schema
// v16): loading the committed producer-real dungeon artifact decodes its
// [assets 2] section — one content-addressed 64×32 RGBA8 image (8192 pixel bytes)
// and the DungeonAtlas with its 8 cell rects — through core:encoding/base64,
// proving the runtime's DEC_TABLE decode round-trips funpack's ENC_TABLE encode
// byte-for-byte (the Odin-first §29 seam, both sides on the same core package).
//
// dungeon.artifact is the FIRST committed copy carrying a populated [assets]
// section (an asset-less game writes the constant [assets 0] tail, exercised by
// pong/snake/hunt/yard/krognid/statequery). The asset model is bake-static, so a
// load decodes the pixels once into the Program; the textured renderer resolves a
// `Draw_Sprite{atlas, cell}` through asset_region against this decode.
package funpack_runtime

import "core:testing"

// DUNGEON_ARTIFACT is embedded by dungeon_acceptance_test.odin (same package),
// the committed producer-real dungeon artifact — the v16 fixture that carries the
// real [assets 2] sprite section this test round-trips.

// test_assets_decode_round_trips loads dungeon.artifact and asserts its
// [assets 2] section decodes exactly: the DungeonAtlas image is 64×32 with a
// width·height·4 = 8192-byte RGBA8 buffer (proving base64 round-tripped funpack's
// emission), and the atlas slices it into 8 named cell rects with `floor` at
// (0,0,16,16) — the §19 grid-coord×cell-size lowering. asset_region resolves the
// full `(atlas, cell) → (image, rect)` chain the textured renderer blits from.
@(test)
test_assets_decode_round_trips :: proc(t: ^testing.T) {
	loaded, err := load_program(DUNGEON_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden dungeon artifact must load, got %v", err) {
		return
	}
	program := loaded

	// One distinct decoded image (content-addressed; the dedup holds it once) —
	// 64×32, the canonical RGBA8 buffer of width·height·4 = 8192 bytes. A decode
	// that did not match these dims would have failed the load closed (the W·H·4
	// gate in load_asset_image), so reaching here proves the base64 round-trip.
	testing.expect_value(t, len(program.assets.images), 1)
	image := program.assets.images[0]
	testing.expect_value(t, image.width, 64)
	testing.expect_value(t, image.height, 32)
	testing.expect_value(t, len(image.pixels), 64 * 32 * 4) // 8192 RGBA8 bytes

	// One atlas (DungeonAtlas), referencing the image by its content hash (the
	// dedup key), with 8 cell regions.
	testing.expect_value(t, len(program.assets.atlases), 1)
	atlas := program.assets.atlases[0]
	testing.expect_value(t, atlas.name, "DungeonAtlas")
	testing.expect_value(t, atlas.image_hash, image.hash) // the atlas resolves its pixels by hash
	testing.expect_value(t, len(atlas.regions), 8)

	// The `floor` cell's pixel rect is the §19 grid-coord×cell-size lowering: the
	// top-left 16×16 cell of the 64×32 atlas image.
	floor := atlas.regions[0]
	testing.expect_value(t, floor.name, "floor")
	testing.expect_value(t, floor.px_x, 0)
	testing.expect_value(t, floor.px_y, 0)
	testing.expect_value(t, floor.px_w, 16)
	testing.expect_value(t, floor.px_h, 16)

	// The full resolution chain `(atlas-name, cell-name) → (image pixels, pixel
	// rect)` the textured renderer blits a sprite through.
	resolved_image, resolved_region, ok := asset_region(&program, "DungeonAtlas", "floor")
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, resolved_image.width, 64)
	testing.expect_value(t, len(resolved_image.pixels), 8192)
	testing.expect_value(t, resolved_region.px_w, 16)

	// A miss is fail-closed (an unknown atlas or cell resolves to nothing, never a
	// guessed rect).
	_, _, hero_ok := asset_region(&program, "DungeonAtlas", "hero")
	testing.expect(t, hero_ok) // a real cell resolves
	_, _, unknown_atlas := asset_region(&program, "NoSuchAtlas", "floor")
	testing.expect(t, !unknown_atlas)
	_, _, unknown_cell := asset_region(&program, "DungeonAtlas", "no_such_cell")
	testing.expect(t, !unknown_cell)

	// Determinism: a second load of the same bytes decodes to a bit-identical
	// Asset_Set (base64 is a pure ASCII→byte map, the walk is slice-order — the
	// tilemap/nav loader invariant). asset_sets_equal is the comparison surface.
	reloaded, reload_err := load_program(DUNGEON_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, reload_err, Artifact_Error.None)
	testing.expect(t, asset_sets_equal(program.assets, reloaded.assets))
}
