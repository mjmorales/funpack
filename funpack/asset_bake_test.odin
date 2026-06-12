// Unit suite for the §19-literal manifest-generating bake (asset_bake.odin): the
// real-image-resolution, emitted-manifest format, staleness-mismatch, and
// missing-image-error obligations, proven on hermetic scratch trees (a minimal
// valid PNG written to disk) plus the live dungeon corpus (resolve-or-SKIP). The
// load-bearing properties:
//
//   - real-image resolution: the bake reads the actual PNG off disk, hashes it
//     through import_image, and the atlas deps-on that REAL hash (never a declared
//     phantom). The image is a first-class `[name] kind=image` node ahead of its
//     atlas; the tileset deps-on the atlas's real hash, so the (image→atlas→tileset)
//     chain's hashes are all computed.
//   - emitted-manifest format: the emitter round-trips through the reader (emit →
//     read → identical node set) and matches the committed manifest's text shape.
//   - staleness: a committed manifest that does not byte-match the freshly-baked one
//     is a Stale_Manifest build error (§19 §5); a matching one passes.
//   - missing-image: an atlas naming an image file not on disk is the named
//     Missing_Image error (fail-closed), never a silent skip or a panic.
//   - seam invariance: registering an image node does NOT perturb the assets.gen.fun
//     seam bytes — an image carries no handle (sliced through its atlas, §19 §1).
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// MINIMAL_PNG is a valid 1×1 RGBA PNG (sig + IHDR + IDAT + IEND), the smallest
// input core:image/png.load_from_bytes decodes — the hermetic image-source bytes
// the scratch-tree bakes hash over. Its exact bytes are immaterial (the bake
// hashes whatever they are); what matters is that it DECODES, so import_image
// succeeds and the bake resolves a real image hash.
MINIMAL_PNG := []u8 {
	137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
	0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 240,
	31, 0, 5, 0, 1, 255, 137, 153, 61, 29, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
}

// write_scratch_asset_tree builds a hermetic §14 asset tree under a unique scratch
// root: assets/<manifest>, assets/<atlas>, assets/<image>, assets/<tiles>. The
// committed manifest content the caller supplies registers the atlas + tileset (the
// image is DISCOVERED from the atlas's `image` clause, not pre-declared). Returns
// the root; the caller defers remove_scratch_tree. A construction failure expects
// false and returns "".
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

// int_to_str renders an int as decimal — the scratch-root suffix; core:strconv via
// a small builder to avoid importing strconv only for this.
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

// SCRATCH_ATLAS is a minimal .atlas naming scratch.png as its image — the source
// the bake parses to DISCOVER the image dependency.
SCRATCH_ATLAS :: "atlas Scratch {\n  image \"scratch.png\"\n  grid 16 16\n  cell coin at (0, 0)\n}\n"

// SCRATCH_TILES is a minimal .tiles naming scratch as its atlas — the source whose
// tileset deps-on the atlas's real hash.
SCRATCH_TILES :: "tileset Scratch {\n  atlas scratch\n  tile floor {\n    cell: (0, 0)\n    solid: false\n  }\n}\n"

// scratch_manifest_no_image registers the atlas + tileset only (the bake discovers
// the image). The hashes are placeholders — the bake recomputes them, so a committed
// manifest with these is STALE against the fresh bake (the staleness test relies on
// this).
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

// ── real-image resolution ────────────────────────────────────────────────────

@(test)
test_bake_resolves_real_image_into_dag :: proc(t: ^testing.T) {
	// AC (real-image resolution): the bake reads scratch.png off disk, hashes it,
	// discovers it as a first-class image node ahead of the atlas, and the atlas
	// deps-on the REAL image hash — the tileset on the REAL atlas hash. The chain's
	// hashes are computed, never the manifest's placeholders.
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

	// Three nodes: the discovered image, then the atlas, then the tileset — the
	// bottom-up DAG order (image ahead of its atlas).
	testing.expect_value(t, len(baked.assets), 3)
	image_node := baked.assets[0]
	atlas_node := baked.assets[1]
	tileset_node := baked.assets[2]

	testing.expect_value(t, image_node.kind, Asset_Kind.Image)
	testing.expect_value(t, image_node.name, "scratch.png")
	testing.expect_value(t, image_node.importer_version, "image@1")
	testing.expect_value(t, len(image_node.deps), 0)
	// The image hash is REAL — the §2 fold over the actual PNG bytes + image@1, so
	// it carries the sha256: prefix and the full 64-hex digest (never a placeholder).
	testing.expect(t, strings.has_prefix(image_node.hash, HASH_PREFIX))
	testing.expect_value(t, len(image_node.hash), len(HASH_PREFIX) + 64)

	// The atlas deps-on the image's REAL hash — its single dep string is
	// `scratch.png@<real-image-hash>`, NOT the manifest's placeholder.
	testing.expect_value(t, atlas_node.kind, Asset_Kind.Atlas)
	testing.expect_value(t, len(atlas_node.deps), 1)
	testing.expect_value(t, atlas_node.deps[0], asset_dep_string("scratch.png", image_node.hash, context.temp_allocator))
	testing.expect(t, atlas_node.hash != "sha256:placeholder")
	testing.expect_value(t, len(atlas_node.hash), len(HASH_PREFIX) + 64)

	// The tileset deps-on the atlas's REAL hash.
	testing.expect_value(t, tileset_node.kind, Asset_Kind.Tileset)
	testing.expect_value(t, len(tileset_node.deps), 1)
	testing.expect_value(t, tileset_node.deps[0], asset_dep_string("scratch", atlas_node.hash, context.temp_allocator))
	testing.expect(t, tileset_node.hash != "sha256:placeholder")

	// The bake is deterministic: a second bake of the same tree yields identical
	// hashes (the §2 same-inputs-same-hash invariant).
	baked2, err2, _ := bake_asset_manifest(root, context.temp_allocator)
	testing.expect_value(t, err2, Asset_Bake_Error.None)
	testing.expect_value(t, baked2.assets[0].hash, image_node.hash)
	testing.expect_value(t, baked2.assets[1].hash, atlas_node.hash)
	testing.expect_value(t, baked2.assets[2].hash, tileset_node.hash)
}

// ── emitted-manifest format ──────────────────────────────────────────────────

@(test)
test_emit_manifest_round_trips_through_reader :: proc(t: ^testing.T) {
	// AC (emitted-manifest format): the emitter's text reads back through
	// read_asset_manifest to the SAME node set — the emit/read pair is a lossless
	// round-trip, so the generated manifest is a valid manifest the registry,
	// staleness gate, and seam emitter all consume.
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

	// The emitted text leads with the fixed GENERATED-by-the-bake header and ends
	// in exactly one newline.
	testing.expect(t, strings.has_prefix(emitted, ASSET_MANIFEST_HEADER))
	testing.expect(t, strings.has_suffix(emitted, "\n"))
	testing.expect(t, !strings.has_suffix(emitted, "\n\n"))

	// Read it back: the registry reader parses the emitted bytes to the identical
	// three-node set in the identical order.
	reparsed, read_err := read_asset_manifest(emitted)
	testing.expect_value(t, read_err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(reparsed.entries), 3)
	testing.expect_value(t, reparsed.entries[0].name, "scratch.png")
	testing.expect_value(t, reparsed.entries[0].kind, Asset_Kind.Image)
	testing.expect_value(t, reparsed.entries[0].hash, baked.assets[0].hash)
	testing.expect_value(t, reparsed.entries[1].name, "scratch")
	testing.expect_value(t, reparsed.entries[1].deps[0], baked.assets[1].deps[0])
	testing.expect_value(t, reparsed.entries[2].name, "scratch_tiles")

	// Emit is double-deterministic: two emissions of the same baked nodes are
	// byte-identical (§29).
	emitted2 := emit_asset_manifest(baked, context.temp_allocator)
	testing.expect(t, emitted == emitted2)
}

// ── staleness ────────────────────────────────────────────────────────────────

@(test)
test_bake_manifest_staleness_flags_mismatch :: proc(t: ^testing.T) {
	// AC (staleness): the committed manifest (placeholder hashes, no image node)
	// does NOT byte-match the freshly-baked one, so the staleness gate is
	// Stale_Manifest (§19 §5). After regenerating in place (write_asset_manifest),
	// the gate passes — the regen/check pair closes the loop.
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

	// The committed placeholder manifest is stale against the fresh bake.
	stale_err, _ := bake_manifest_staleness(root, emitted)
	testing.expect_value(t, stale_err, Asset_Bake_Error.Stale_Manifest)

	// Regenerate the committed manifest in place, then the gate passes.
	testing.expect(t, write_asset_manifest(root, emitted))
	fresh_err, _ := bake_manifest_staleness(root, emitted)
	testing.expect_value(t, fresh_err, Asset_Bake_Error.None)

	// And a normal build over the regenerated tree no longer refuses on the asset
	// bake gate (the §19-literal end-to-end: regen → staleness passes).
	verdict := stage_asset_bake(root, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
}

// ── missing-image error ──────────────────────────────────────────────────────

@(test)
test_bake_missing_image_is_named_error :: proc(t: ^testing.T) {
	// AC (missing-image): an atlas naming an image file NOT on disk is the named
	// Missing_Image error (fail-closed) with the missing path in detail — never a
	// silent skip or a panic. Built by writing the tree, then deleting the PNG so
	// the atlas's `image "scratch.png"` clause dangles.
	root := write_scratch_asset_tree(t, scratch_manifest_no_image(), SCRATCH_ATLAS, MINIMAL_PNG, SCRATCH_TILES)
	if root == "" {
		return
	}
	defer remove_scratch_tree(root)

	// Remove the image so the atlas's declared image is absent.
	os.remove(scratch_join({root, "assets", "scratch.png"}))

	_, err, detail := bake_asset_manifest(root, context.temp_allocator)
	testing.expect_value(t, err, Asset_Bake_Error.Missing_Image)
	testing.expect(t, strings.contains(detail, "scratch.png"))

	// The build refusal NAMES the missing image — the refusal line is actionable.
	verdict := stage_asset_bake(root, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Asset_Bake_Failed)
	testing.expect(t, strings.contains(verdict.offender, "Missing_Image"))
	testing.expect(t, strings.contains(verdict.offender, "scratch.png"))
}

// ── corrupt-image error ──────────────────────────────────────────────────────

@(test)
test_bake_corrupt_image_is_named_error :: proc(t: ^testing.T) {
	// AC (malformed-image): an image file present but NOT a decodable PNG is the
	// named Malformed_Image error — the binary importer fails closed on the
	// decoder's reject, never panics (§4 deterministic binary importer).
	garbage := transmute([]u8)string("not a png at all")
	root := write_scratch_asset_tree(t, scratch_manifest_no_image(), SCRATCH_ATLAS, garbage, SCRATCH_TILES)
	if root == "" {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := bake_asset_manifest(root, context.temp_allocator)
	testing.expect_value(t, err, Asset_Bake_Error.Malformed_Image)
}

// ── seam invariance under image nodes ────────────────────────────────────────

@(test)
test_image_node_does_not_perturb_seam :: proc(t: ^testing.T) {
	// AC (seam invariance): registering an image node in the manifest does NOT
	// change the assets.gen.fun seam bytes — an image carries no typed handle
	// (sliced through its atlas, §19 §1), so the seam over a manifest WITH the
	// image equals the seam over the same manifest WITHOUT it. This is why the
	// committed gen/assets.gen.fun stays byte-identical after the manifest gains
	// its image nodes.
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

	// The image node is skipped: same seam bytes either way. The image never emits
	// a `let dungeon.png:` handle (its `.`-bearing name is not a valid identifier).
	testing.expect(t, seam_without == seam_with)
	testing.expect(t, !strings.contains(seam_with, "dungeon.png"))
	testing.expect(t, !strings.contains(seam_with, "TextureHandle"))
}

// ── live dungeon corpus (resolve-or-SKIP) ────────────────────────────────────

@(test)
test_bake_dungeon_emits_real_hashed_manifest :: proc(t: ^testing.T) {
	// AC (live real-image resolution): the bake over the live dungeon tree reads
	// the real dungeon.png, discovers it as an image node, and resolves the
	// atlas/tileset hashes from the real (image→atlas→tileset) chain. The emitted
	// manifest reads back lossless and carries the image node ahead of the atlas.
	// SKIPs loudly when the sibling checkout (or the placeholder PNG) is absent.
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

	// The discovered image node leads, named by the PNG filename, with no deps and
	// a real hash; the atlas deps-on it; the tileset deps-on the atlas.
	testing.expect_value(t, len(baked.assets), 3)
	testing.expect_value(t, baked.assets[0].kind, Asset_Kind.Image)
	testing.expect_value(t, baked.assets[0].name, "dungeon.png")
	testing.expect_value(t, baked.assets[1].kind, Asset_Kind.Atlas)
	testing.expect_value(t, baked.assets[1].deps[0], asset_dep_string("dungeon.png", baked.assets[0].hash, context.temp_allocator))
	testing.expect_value(t, baked.assets[2].kind, Asset_Kind.Tileset)
	testing.expect_value(t, baked.assets[2].deps[0], asset_dep_string("dungeon_atlas", baked.assets[1].hash, context.temp_allocator))

	// The emitted manifest round-trips and double-bakes identically.
	emitted := emit_asset_manifest(baked, context.temp_allocator)
	reparsed, read_err := read_asset_manifest(emitted)
	testing.expect_value(t, read_err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(reparsed.entries), 3)
}
