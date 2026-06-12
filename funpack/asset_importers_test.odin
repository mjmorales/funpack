package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// The golden asset sources live in the funpack-spec sibling checkout's
// examples/assets/assets/ dir (the same tree asset_manifest_test reads); the
// importers parse those committed sources. resolve_assets_dir + the
// resolve-or-skip discipline are shared with asset_manifest_test.odin so a
// missing checkout warns loudly instead of silently testing nothing.
golden_asset_source :: proc(filename: string) -> (content: string, ok: bool) {
	dir := resolve_assets_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP asset importer: %s not found — set FUNPACK_ASSETS_DIR or check out funpack-spec as a sibling of the repo", dir)
		return "", false
	}
	path, _ := filepath.join({dir, "assets", filename}, context.temp_allocator)
	bytes, file_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if file_err != nil {
		log.warnf("SKIP asset importer: %s unreadable", path)
		return "", false
	}
	return string(bytes), true
}

@(test)
test_import_model_coin_fpm :: proc(t: ^testing.T) {
	// The model importer's defining outcome over the live golden coin.fpm: the
	// disc params (radius 4, thickness 1) are recovered numerically, the emit
	// primitive is the cylinder over those params, and the material slot is
	// named. The counts are pinned to the golden file on purpose — when the
	// model grows a param, this changes in lockstep.
	src, ok := golden_asset_source("coin.fpm")
	if !ok {
		return
	}
	asset, err := import_model(src)
	testing.expect_value(t, err, Importer_Error.None)
	testing.expect_value(t, asset.name, "Coin")

	// The two disc params, in source order, recovered as §10 Fixed.
	testing.expect_value(t, len(asset.params), 2)
	testing.expect_value(t, asset.params[0].name, "radius")
	testing.expect_value(t, asset.params[0].type, "Length")
	testing.expect_value(t, asset.params[0].default, to_fixed(4))
	testing.expect_value(t, asset.params[1].name, "thickness")
	testing.expect_value(t, asset.params[1].type, "Length")
	testing.expect_value(t, asset.params[1].default, to_fixed(1))

	// emit cyl(radius, thickness): the geometry primitive over the params.
	testing.expect_value(t, asset.emit_prim, "cyl")
	testing.expect_value(t, len(asset.emit_args), 2)
	testing.expect_value(t, asset.emit_args[0], "radius")
	testing.expect_value(t, asset.emit_args[1], "thickness")

	// material body = pbr(...): the named appearance slot the seam exposes.
	testing.expect_value(t, asset.material, "body")

	// The content hash carries the §2 canonical prefix and is the model
	// importer version's output — its presence is the asset's identity.
	testing.expect(t, len(asset.hash) == len(HASH_PREFIX) + 64, "model hash is sha256: + 64 hex chars")
}

@(test)
test_import_model_deterministic :: proc(t: ^testing.T) {
	// §29 purity: the same source bytes always yield the same content hash —
	// proven on a hand-built source so it needs no checkout.
	src := "model Coin { param radius: Length = 4\n emit cyl(radius)\n material body = pbr(color: gold) }"
	a, ea := import_model(src)
	b, eb := import_model(src)
	testing.expect_value(t, ea, Importer_Error.None)
	testing.expect_value(t, eb, Importer_Error.None)
	testing.expect(t, a.hash == b.hash, "identical model source must yield an identical hash")
}

@(test)
test_import_model_rejects_malformed :: proc(t: ^testing.T) {
	// A source missing the `model` header is malformed — the importer is a
	// total parser, never a best-effort one (the one model error case).
	_, err := import_model("Coin { param radius: Length = 4 }")
	testing.expect_value(t, err, Importer_Error.Malformed_Source)
}

@(test)
test_import_atlas_pickups_cells_and_clip :: proc(t: ^testing.T) {
	// The atlas importer's defining outcome over the live golden pickups.atlas:
	// three named cells (coin/gem/key), the spin clip (4 frames at fps 8), and
	// the raw image recorded as the §4 dependency. The counts are pinned to the
	// golden file on purpose — they change in lockstep when the atlas grows.
	src, ok := golden_asset_source("pickups.atlas")
	if !ok {
		return
	}
	// The caller resolves the raw image's content hash and threads it in as the
	// single dependency (the atlas DAG node deps-on its image, §4).
	image_hash := "pickups.png@sha256:b7e2d4f0"
	asset, err := import_atlas(src, []string{image_hash})
	testing.expect_value(t, err, Importer_Error.None)
	testing.expect_value(t, asset.name, "Pickups")
	testing.expect_value(t, asset.image, "pickups.png")
	testing.expect_value(t, asset.grid_w, 8)
	testing.expect_value(t, asset.grid_h, 8)

	// Three named cells in source order.
	testing.expect_value(t, len(asset.cells), 3)
	testing.expect_value(t, asset.cells[0].name, "coin")
	testing.expect_value(t, asset.cells[1].name, "gem")
	testing.expect_value(t, asset.cells[2].name, "key")

	// The spin clip: 4 frames cycling coin/gem/key/gem at fps 8.
	testing.expect_value(t, len(asset.clips), 1)
	spin := asset.clips[0]
	testing.expect_value(t, spin.name, "spin")
	testing.expect_value(t, spin.fps, 8)
	testing.expect_value(t, len(spin.frames), 4)
	testing.expect_value(t, spin.frames[0], "coin")
	testing.expect_value(t, spin.frames[1], "gem")
	testing.expect_value(t, spin.frames[2], "key")
	testing.expect_value(t, spin.frames[3], "gem")

	// The raw image is recorded as the dependency, and that dependency hash is
	// folded into the atlas's own content hash (so editing the PNG re-bakes it).
	testing.expect_value(t, asset.image_dep, image_hash)
	testing.expect(t, len(asset.hash) == len(HASH_PREFIX) + 64, "atlas hash is sha256: + 64 hex chars")
}

@(test)
test_import_atlas_image_dep_changes_hash :: proc(t: ^testing.T) {
	// §4 correct invalidation: the atlas hashes OVER its image dependency, so a
	// different image hash (an edited PNG) yields a different atlas hash, while
	// the same image hash is deterministic — proven on a hand-built source.
	src := "atlas P { image \"p.png\"\n grid 8 8\n cell c at (0, 0)\n clip s cells [\"c\"] fps 4 }"
	h1, e1 := import_atlas(src, []string{"p.png@sha256:aaaa"})
	h1b, _ := import_atlas(src, []string{"p.png@sha256:aaaa"})
	h2, e2 := import_atlas(src, []string{"p.png@sha256:bbbb"})
	testing.expect_value(t, e1, Importer_Error.None)
	testing.expect_value(t, e2, Importer_Error.None)
	testing.expect(t, h1.hash == h1b.hash, "same image dep hash must yield the same atlas hash")
	testing.expect(t, h1.hash != h2.hash, "an edited image (different dep hash) must re-bake the atlas")
}

@(test)
test_import_atlas_rejects_clip_undeclared_cell :: proc(t: ^testing.T) {
	// A clip naming a cell the atlas never declared is malformed — the
	// closed-name discipline at the asset level (the one atlas error case).
	src := "atlas P { image \"p.png\"\n grid 8 8\n cell c at (0, 0)\n clip s cells [\"missing\"] fps 4 }"
	_, err := import_atlas(src, []string{"p.png@sha256:aaaa"})
	testing.expect_value(t, err, Importer_Error.Malformed_Source)
}

@(test)
test_import_audio_deterministic :: proc(t: ^testing.T) {
	// The audio importer content-hashes the raw binary directly: the same
	// bytes are deterministic, distinct bytes differ, and the hash carries the
	// §2 canonical prefix — proven on a byte fixture, no parse, no checkout.
	bytes := []byte{0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03}
	a, ea := import_audio(bytes)
	b, eb := import_audio(bytes)
	testing.expect_value(t, ea, Importer_Error.None)
	testing.expect_value(t, eb, Importer_Error.None)
	testing.expect(t, a.hash == b.hash, "identical audio bytes must yield an identical hash")
	testing.expect(t, len(a.hash) == len(HASH_PREFIX) + 64, "audio hash is sha256: + 64 hex chars")

	// Distinct bytes hash distinctly (the importer hashes the content, not a
	// constant).
	other, _ := import_audio([]byte{0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x04})
	testing.expect(t, a.hash != other.hash, "distinct audio bytes must hash distinctly")
}

// A deterministic 2×2 RGBA8 PNG, hand-built (Python: struct + zlib over a
// known IHDR/IDAT/IEND framing) and embedded as the byte literal below, so the
// image importer test needs no checkout and no PNG encoder (core:image/png
// decodes, but does not encode). The four pixels, row-major top-to-bottom,
// left-to-right, are: (0,0) red opaque, (1,0) green half-alpha, (0,1) blue
// opaque, (1,1) yellow fully transparent — the known-pixel ground truth the
// decode is asserted against. The bytes were verified to decode through
// core:image/png to exactly the IMAGE_FIXTURE_RGBA buffer below.
IMAGE_FIXTURE_PNG :: []byte {
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
	0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
	0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00,
	0x16, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
	0x1f, 0x08, 0x1b, 0x18, 0x80, 0x34, 0x10, 0x30, 0x30, 0x00, 0x00, 0x41,
	0xd5, 0x07, 0x7a, 0x73, 0xf4, 0x8b, 0x83, 0x00, 0x00, 0x00, 0x00, 0x49,
	0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
}

// IMAGE_FIXTURE_RGBA is the canonical RGBA8 decode of IMAGE_FIXTURE_PNG: 16
// bytes (2×2×4), row-major. Pinned to the known source pixels so the importer's
// decode is proven exact, not just non-empty.
IMAGE_FIXTURE_RGBA :: []byte {
	255, 0, 0, 255, // (0,0) red opaque
	0, 255, 0, 128, // (1,0) green half-alpha
	0, 0, 255, 255, // (0,1) blue opaque
	255, 255, 0, 0, // (1,1) yellow fully transparent
}

@(test)
test_import_image_png_decodes_to_rgba :: proc(t: ^testing.T) {
	// The image importer's defining outcome over the hand-built fixture PNG: the
	// raw bytes content-hash to the §2 canonical form, and the PNG decodes
	// through core:image/png to the exact canonical RGBA8 buffer (2×2, four
	// channels, row-major) the known source pixels demand. Decode is exact, not
	// best-effort — a wrong pixel is a semantics bug.
	asset, err := import_image(IMAGE_FIXTURE_PNG)
	testing.expect_value(t, err, Importer_Error.None)
	testing.expect_value(t, asset.width, 2)
	testing.expect_value(t, asset.height, 2)

	// The canonical RGBA8 buffer: width*height*4 bytes, matching the known
	// source pixels exactly.
	testing.expect_value(t, len(asset.pixels), 16)
	for want, i in IMAGE_FIXTURE_RGBA {
		testing.expect_value(t, asset.pixels[i], want)
	}

	// The content hash carries the §2 canonical prefix — the image importer
	// version's output over the raw PNG bytes, the asset's identity.
	testing.expect(t, len(asset.hash) == len(HASH_PREFIX) + 64, "image hash is sha256: + 64 hex chars")
}

@(test)
test_import_image_deterministic :: proc(t: ^testing.T) {
	// §29 purity: the same PNG bytes always yield the same content hash AND the
	// same decoded buffer — both are pure functions of the source bytes (§4
	// determinism), proven on the byte fixture, no checkout.
	a, ea := import_image(IMAGE_FIXTURE_PNG)
	b, eb := import_image(IMAGE_FIXTURE_PNG)
	testing.expect_value(t, ea, Importer_Error.None)
	testing.expect_value(t, eb, Importer_Error.None)
	testing.expect(t, a.hash == b.hash, "identical PNG bytes must yield an identical hash")
	testing.expect_value(t, len(a.pixels), len(b.pixels))
	for i in 0 ..< len(a.pixels) {
		testing.expect_value(t, a.pixels[i], b.pixels[i])
	}
}

@(test)
test_import_image_rejects_garbage :: proc(t: ^testing.T) {
	// A truncated/non-PNG input is Malformed_Image — the importer fails closed on
	// the core:image/png decoder's error, never panics (§4 deterministic binary
	// importer). A bare byte run with no PNG signature is the garbage case; a
	// fixture truncated mid-stream is the truncation case.
	_, garbage_err := import_image([]byte{0x00, 0x01, 0x02, 0x03, 0x04, 0x05})
	testing.expect_value(t, garbage_err, Importer_Error.Malformed_Image)

	// A copy of the fixture truncated mid-stream (the IDAT/IEND tail lopped off):
	// a well-formed signature and IHDR, but no decodable image data.
	full := IMAGE_FIXTURE_PNG
	truncated := full[:len(full) - 20]
	_, truncated_err := import_image(truncated)
	testing.expect_value(t, truncated_err, Importer_Error.Malformed_Image)
}

@(test)
test_import_asset_dispatch_keyed_on_kind :: proc(t: ^testing.T) {
	// The closed Asset_Kind dispatch routes each kind to its importer and folds
	// the result into the tagged Imported_Asset union — the entry point the
	// bake walks the manifest through.
	model_src := transmute([]byte)string("model M { param r: Length = 2\n emit cyl(r)\n material b = pbr(c: gold) }")
	m, em := import_asset(.Model, model_src, nil)
	testing.expect_value(t, em, Importer_Error.None)
	_, is_model := m.(Model_Asset)
	testing.expect(t, is_model, "a .Model kind dispatches to import_model")

	atlas_src := transmute([]byte)string("atlas A { image \"a.png\"\n grid 8 8\n cell c at (0, 0)\n clip s cells [\"c\"] fps 2 }")
	a, ea := import_asset(.Atlas, atlas_src, []string{"a.png@sha256:1"})
	testing.expect_value(t, ea, Importer_Error.None)
	_, is_atlas := a.(Atlas_Asset)
	testing.expect(t, is_atlas, "an .Atlas kind dispatches to import_atlas")

	au, eau := import_asset(.Audio, []byte{0x00, 0x01}, nil)
	testing.expect_value(t, eau, Importer_Error.None)
	_, is_audio := au.(Audio_Asset)
	testing.expect(t, is_audio, "an .Audio kind dispatches to import_audio")

	im, eim := import_asset(.Image, IMAGE_FIXTURE_PNG, nil)
	testing.expect_value(t, eim, Importer_Error.None)
	img_asset, is_image := im.(Image_Asset)
	testing.expect(t, is_image, "an .Image kind dispatches to import_image")
	testing.expect_value(t, img_asset.width, 2)
	testing.expect_value(t, img_asset.height, 2)
}
