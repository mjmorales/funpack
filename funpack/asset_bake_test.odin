package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

MINIMAL_PNG := []u8 {
	137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
	0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 240,
	31, 0, 5, 0, 1, 255, 137, 153, 61, 29, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
}

write_scratch_asset_tree :: proc(t: ^testing.T, manifest: string, atlas: string, image_bytes: []u8, tiles: string) -> string {
	root := scratch_join({scratch_base(), strings.concatenate({"funpack-bake-", int_to_str(scratch_seq())}, context.temp_allocator)})
	assets_dir := scratch_join({root, "assets"})
	if os.make_directory_all(assets_dir) != nil {
		testing.expect(t, false, "could not create scratch assets dir")
		return ""
	}
	ok := os.write_entire_file(scratch_join({assets_dir, "assets.manifest"}), transmute([]u8)manifest) == nil
	ok &= os.write_entire_file(scratch_join({assets_dir, "scratch.atlas"}), transmute([]u8)atlas) == nil
	ok &= os.write_entire_file(scratch_join({assets_dir, "scratch.png"}), image_bytes) == nil
	if tiles != "" {
		ok &= os.write_entire_file(scratch_join({assets_dir, "scratch.tiles"}), transmute([]u8)tiles) == nil
	}
	if !ok {
		testing.expect(t, false, "could not write scratch asset sources")
		return ""
	}
	return root
}

int_to_str :: proc(n: int) -> string {
	if n == 0 {
		return "0"
	}
	buf: [20]byte
	i := len(buf)
	v := n
	for v > 0 {
		i -= 1
		buf[i] = byte('0' + v % 10)
		v /= 10
	}
	return strings.clone_from_bytes(buf[i:], context.temp_allocator)
}

SCRATCH_ATLAS :: "atlas Scratch {\n  image \"scratch.png\"\n  grid 16 16\n  cell coin at (0, 0)\n}\n"

SCRATCH_TILES :: "tileset Scratch {\n  atlas scratch\n  tile floor {\n    cell: (0, 0)\n    solid: false\n  }\n}\n"

scratch_manifest_no_image :: proc() -> string {
	return strings.concatenate(
		{
			"[scratch]\nkind = atlas\nsource = \"scratch.atlas\"\nimporter = \"atlas@2\"\n",
			"deps = [\"scratch.png@sha256:placeholder\"]\nhash = \"sha256:placeholder\"\nout = \".cache/x\"\n",
			"[scratch_tiles]\nkind = tileset\nsource = \"scratch.tiles\"\nimporter = \"tiles@1\"\n",
			"deps = [\"scratch@sha256:placeholder\"]\nhash = \"sha256:placeholder\"\nout = \".cache/y\"\n",
		},
		context.temp_allocator,
	)
}

@(test)
test_bake_resolves_real_image_into_dag :: proc(t: ^testing.T) {
	root := write_scratch_asset_tree(t, scratch_manifest_no_image(), SCRATCH_ATLAS, MINIMAL_PNG, SCRATCH_TILES)
	if root == "" {
		return
	}
	defer remove_scratch_tree(root)

	baked, err, detail := bake_asset_manifest(root, context.temp_allocator)
	testing.expect_value(t, err, Asset_Bake_Error.None)
	if err != .None {
		log.warnf( "bake refused: %s", detail)
		return
	}

	testing.expect_value(t, len(baked.assets), 3)
	image_node := baked.assets[0]
	atlas_node := baked.assets[1]
	tileset_node := baked.assets[2]

	testing.expect_value(t, image_node.kind, Asset_Kind.Image)
	testing.expect_value(t, image_node.name, "scratch.png")
	testing.expect_value(t, image_node.importer_version, "image@1")
	testing.expect_value(t, len(image_node.deps), 0)
	testing.expect(t, strings.has_prefix(image_node.hash, HASH_PREFIX))
	testing.expect_value(t, len(image_node.hash), len(HASH_PREFIX) + 64)

	testing.expect_value(t, atlas_node.kind, Asset_Kind.Atlas)
	testing.expect_value(t, len(atlas_node.deps), 1)
	testing.expect_value(t, atlas_node.deps[0], asset_dep_string("scratch.png", image_node.hash, context.temp_allocator))
	testing.expect(t, atlas_node.hash != "sha256:placeholder")
	testing.expect_value(t, len(atlas_node.hash), len(HASH_PREFIX) + 64)

	testing.expect_value(t, tileset_node.kind, Asset_Kind.Tileset)
	testing.expect_value(t, len(tileset_node.deps), 1)
	testing.expect_value(t, tileset_node.deps[0], asset_dep_string("scratch", atlas_node.hash, context.temp_allocator))
	testing.expect(t, tileset_node.hash != "sha256:placeholder")

	baked2, err2, _ := bake_asset_manifest(root, context.temp_allocator)
	testing.expect_value(t, err2, Asset_Bake_Error.None)
	testing.expect_value(t, baked2.assets[0].hash, image_node.hash)
	testing.expect_value(t, baked2.assets[1].hash, atlas_node.hash)
	testing.expect_value(t, baked2.assets[2].hash, tileset_node.hash)
}

@(test)
test_emit_manifest_round_trips_through_reader :: proc(t: ^testing.T) {
	root := write_scratch_asset_tree(t, scratch_manifest_no_image(), SCRATCH_ATLAS, MINIMAL_PNG, SCRATCH_TILES)
	if root == "" {
		return
	}
	defer remove_scratch_tree(root)

	baked, err, _ := bake_asset_manifest(root, context.temp_allocator)
	testing.expect_value(t, err, Asset_Bake_Error.None)
	if err != .None {
		return
	}
	emitted := emit_asset_manifest(baked, context.temp_allocator)

	testing.expect(t, strings.has_prefix(emitted, ASSET_MANIFEST_HEADER))
	testing.expect(t, strings.has_suffix(emitted, "\n"))
	testing.expect(t, !strings.has_suffix(emitted, "\n\n"))

	reparsed, read_err := read_asset_manifest(emitted)
	testing.expect_value(t, read_err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(reparsed.entries), 3)
	testing.expect_value(t, reparsed.entries[0].name, "scratch.png")
	testing.expect_value(t, reparsed.entries[0].kind, Asset_Kind.Image)
	testing.expect_value(t, reparsed.entries[0].hash, baked.assets[0].hash)
	testing.expect_value(t, reparsed.entries[1].name, "scratch")
	testing.expect_value(t, reparsed.entries[1].deps[0], baked.assets[1].deps[0])
	testing.expect_value(t, reparsed.entries[2].name, "scratch_tiles")

	emitted2 := emit_asset_manifest(baked, context.temp_allocator)
	testing.expect(t, emitted == emitted2)
}

@(test)
test_bake_manifest_staleness_flags_mismatch :: proc(t: ^testing.T) {
	root := write_scratch_asset_tree(t, scratch_manifest_no_image(), SCRATCH_ATLAS, MINIMAL_PNG, SCRATCH_TILES)
	if root == "" {
		return
	}
	defer remove_scratch_tree(root)

	baked, err, _ := bake_asset_manifest(root, context.temp_allocator)
	testing.expect_value(t, err, Asset_Bake_Error.None)
	if err != .None {
		return
	}
	emitted := emit_asset_manifest(baked, context.temp_allocator)

	stale_err, _ := bake_manifest_staleness(root, emitted)
	testing.expect_value(t, stale_err, Asset_Bake_Error.Stale_Manifest)

	testing.expect(t, write_asset_manifest(root, emitted))
	fresh_err, _ := bake_manifest_staleness(root, emitted)
	testing.expect_value(t, fresh_err, Asset_Bake_Error.None)

	verdict := stage_asset_bake(root, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
}

@(test)
test_bake_missing_image_is_named_error :: proc(t: ^testing.T) {
	root := write_scratch_asset_tree(t, scratch_manifest_no_image(), SCRATCH_ATLAS, MINIMAL_PNG, SCRATCH_TILES)
	if root == "" {
		return
	}
	defer remove_scratch_tree(root)

	os.remove(scratch_join({root, "assets", "scratch.png"}))

	_, err, detail := bake_asset_manifest(root, context.temp_allocator)
	testing.expect_value(t, err, Asset_Bake_Error.Missing_Image)
	testing.expect(t, strings.contains(detail, "scratch.png"))

	verdict := stage_asset_bake(root, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Asset_Bake_Failed)
	testing.expect(t, strings.contains(verdict.offender, "Missing_Image"))
	testing.expect(t, strings.contains(verdict.offender, "scratch.png"))
}

@(test)
test_bake_corrupt_image_is_named_error :: proc(t: ^testing.T) {
	garbage := transmute([]u8)string("not a png at all")
	root := write_scratch_asset_tree(t, scratch_manifest_no_image(), SCRATCH_ATLAS, garbage, SCRATCH_TILES)
	if root == "" {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := bake_asset_manifest(root, context.temp_allocator)
	testing.expect_value(t, err, Asset_Bake_Error.Malformed_Image)
}

@(test)
test_image_node_does_not_perturb_seam :: proc(t: ^testing.T) {
	without_image := strings.concatenate(
		{
			"[dungeon_atlas]\nkind = atlas\nsource = \"dungeon_atlas.atlas\"\nimporter = \"atlas@2\"\n",
			"deps = [\"dungeon.png@sha256:aa\"]\nhash = \"sha256:bb\"\nout = \".cache/x\"\n",
			"[dungeon]\nkind = tileset\nsource = \"dungeon.tiles\"\nimporter = \"tiles@1\"\n",
			"deps = [\"dungeon_atlas@sha256:bb\"]\nhash = \"sha256:cc\"\nout = \".cache/y\"\n",
		},
		context.temp_allocator,
	)
	with_image := strings.concatenate(
		{
			"[dungeon.png]\nkind = image\nsource = \"dungeon.png\"\nimporter = \"image@1\"\n",
			"deps = []\nhash = \"sha256:aa\"\nout = \".cache/i\"\n",
			without_image,
		},
		context.temp_allocator,
	)

	m_without, e1 := read_asset_manifest(without_image)
	m_with, e2 := read_asset_manifest(with_image)
	testing.expect_value(t, e1, Asset_Manifest_Error.None)
	testing.expect_value(t, e2, Asset_Manifest_Error.None)
	testing.expect_value(t, len(m_without.entries), 2)
	testing.expect_value(t, len(m_with.entries), 3)

	docs := []string{"the atlas doc", "the tileset doc"}
	seam_without := emit_assets_gen_fun(m_without, docs, context.temp_allocator)
	seam_with := emit_assets_gen_fun(m_with, docs, context.temp_allocator)

	testing.expect(t, seam_without == seam_with)
	testing.expect(t, !strings.contains(seam_with, "dungeon.png"))
	testing.expect(t, !strings.contains(seam_with, "TextureHandle"))
}

@(test)
test_bake_dungeon_emits_real_hashed_manifest :: proc(t: ^testing.T) {
	dir := resolve_dungeon_example_dir()
	png_path, _ := filepath.join({dir, "assets", "dungeon.png"}, context.temp_allocator)
	if !os.is_file(png_path) {
		log.warnf( "SKIP bake dungeon: %s not found — the live PNG is a driver-generated fixture", png_path)
		return
	}

	baked, err, detail := bake_asset_manifest(dir, context.temp_allocator)
	testing.expect_value(t, err, Asset_Bake_Error.None)
	if err != .None {
		log.warnf( "bake dungeon refused: %s", detail)
		return
	}

	testing.expect_value(t, len(baked.assets), 3)
	testing.expect_value(t, baked.assets[0].kind, Asset_Kind.Image)
	testing.expect_value(t, baked.assets[0].name, "dungeon.png")
	testing.expect_value(t, baked.assets[1].kind, Asset_Kind.Atlas)
	testing.expect_value(t, baked.assets[1].deps[0], asset_dep_string("dungeon.png", baked.assets[0].hash, context.temp_allocator))
	testing.expect_value(t, baked.assets[2].kind, Asset_Kind.Tileset)
	testing.expect_value(t, baked.assets[2].deps[0], asset_dep_string("dungeon_atlas", baked.assets[1].hash, context.temp_allocator))

	emitted := emit_asset_manifest(baked, context.temp_allocator)
	reparsed, read_err := read_asset_manifest(emitted)
	testing.expect_value(t, read_err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(reparsed.entries), 3)
}
