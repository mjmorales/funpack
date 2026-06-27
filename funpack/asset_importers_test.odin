package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

golden_asset_source :: proc(filename: string) -> (content: string, ok: bool) {
	dir := resolve_assets_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP asset importer: %s not found — set FUNPACK_ASSETS_DIR or ensure the in-repo fixture exists", dir)
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
	src, ok := golden_asset_source("coin.fpm")
	if !ok {
		return
	}
	asset, err := import_model(src)
	testing.expect_value(t, err, Importer_Error.None)
	testing.expect_value(t, asset.name, "Coin")

	testing.expect_value(t, len(asset.params), 2)
	testing.expect_value(t, asset.params[0].name, "radius")
	testing.expect_value(t, asset.params[0].type, "Length")
	testing.expect_value(t, asset.params[0].default, to_fixed(4))
	testing.expect_value(t, asset.params[1].name, "thickness")
	testing.expect_value(t, asset.params[1].type, "Length")
	testing.expect_value(t, asset.params[1].default, to_fixed(1))

	testing.expect_value(t, asset.emit_prim, "cyl")
	testing.expect_value(t, len(asset.emit_args), 2)
	testing.expect_value(t, asset.emit_args[0], "radius")
	testing.expect_value(t, asset.emit_args[1], "thickness")

	testing.expect_value(t, asset.material, "body")

	testing.expect(t, len(asset.hash) == len(HASH_PREFIX) + 64, "model hash is sha256: + 64 hex chars")
}

@(test)
test_import_model_deterministic :: proc(t: ^testing.T) {
	src := "model Coin { param radius: Length = 4\n emit cyl(radius)\n material body = pbr(color: gold) }"
	a, ea := import_model(src)
	b, eb := import_model(src)
	testing.expect_value(t, ea, Importer_Error.None)
	testing.expect_value(t, eb, Importer_Error.None)
	testing.expect(t, a.hash == b.hash, "identical model source must yield an identical hash")
}

@(test)
test_import_model_rejects_malformed :: proc(t: ^testing.T) {
	_, err := import_model("Coin { param radius: Length = 4 }")
	testing.expect_value(t, err, Importer_Error.Malformed_Source)
}

@(test)
test_import_atlas_pickups_cells_and_clip :: proc(t: ^testing.T) {
	src, ok := golden_asset_source("pickups.atlas")
	if !ok {
		return
	}
	image_hash := "pickups.png@sha256:b7e2d4f0"
	asset, err := import_atlas(src, []string{image_hash})
	testing.expect_value(t, err, Importer_Error.None)
	testing.expect_value(t, asset.name, "Pickups")
	testing.expect_value(t, asset.image, "pickups.png")
	testing.expect_value(t, asset.grid_w, 8)
	testing.expect_value(t, asset.grid_h, 8)

	testing.expect_value(t, len(asset.cells), 3)
	testing.expect_value(t, asset.cells[0].name, "coin")
	testing.expect_value(t, asset.cells[1].name, "gem")
	testing.expect_value(t, asset.cells[2].name, "key")

	testing.expect_value(t, len(asset.clips), 1)
	spin := asset.clips[0]
	testing.expect_value(t, spin.name, "spin")
	testing.expect_value(t, spin.fps, 8)
	testing.expect_value(t, len(spin.frames), 4)
	testing.expect_value(t, spin.frames[0], "coin")
	testing.expect_value(t, spin.frames[1], "gem")
	testing.expect_value(t, spin.frames[2], "key")
	testing.expect_value(t, spin.frames[3], "gem")

	testing.expect_value(t, asset.image_dep, image_hash)
	testing.expect(t, len(asset.hash) == len(HASH_PREFIX) + 64, "atlas hash is sha256: + 64 hex chars")
}

@(test)
test_import_atlas_image_dep_changes_hash :: proc(t: ^testing.T) {
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
	src := "atlas P { image \"p.png\"\n grid 8 8\n cell c at (0, 0)\n clip s cells [\"missing\"] fps 4 }"
	_, err := import_atlas(src, []string{"p.png@sha256:aaaa"})
	testing.expect_value(t, err, Importer_Error.Malformed_Source)
}

@(test)
test_import_audio_deterministic :: proc(t: ^testing.T) {
	bytes := []byte{0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03}
	a, ea := import_audio(bytes)
	b, eb := import_audio(bytes)
	testing.expect_value(t, ea, Importer_Error.None)
	testing.expect_value(t, eb, Importer_Error.None)
	testing.expect(t, a.hash == b.hash, "identical audio bytes must yield an identical hash")
	testing.expect(t, len(a.hash) == len(HASH_PREFIX) + 64, "audio hash is sha256: + 64 hex chars")

	other, _ := import_audio([]byte{0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x04})
	testing.expect(t, a.hash != other.hash, "distinct audio bytes must hash distinctly")
}

IMAGE_FIXTURE_PNG :: []byte {
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
	0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
	0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00,
	0x16, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
	0x1f, 0x08, 0x1b, 0x18, 0x80, 0x34, 0x10, 0x30, 0x30, 0x00, 0x00, 0x41,
	0xd5, 0x07, 0x7a, 0x73, 0xf4, 0x8b, 0x83, 0x00, 0x00, 0x00, 0x00, 0x49,
	0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
}

IMAGE_FIXTURE_RGBA :: []byte {
	255, 0, 0, 255,
	0, 255, 0, 128,
	0, 0, 255, 255,
	255, 255, 0, 0,
}

@(test)
test_import_image_png_decodes_to_rgba :: proc(t: ^testing.T) {
	asset, err := import_image(IMAGE_FIXTURE_PNG)
	testing.expect_value(t, err, Importer_Error.None)
	testing.expect_value(t, asset.width, 2)
	testing.expect_value(t, asset.height, 2)

	testing.expect_value(t, len(asset.pixels), 16)
	for want, i in IMAGE_FIXTURE_RGBA {
		testing.expect_value(t, asset.pixels[i], want)
	}

	testing.expect(t, len(asset.hash) == len(HASH_PREFIX) + 64, "image hash is sha256: + 64 hex chars")
}

@(test)
test_import_image_deterministic :: proc(t: ^testing.T) {
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
	_, garbage_err := import_image([]byte{0x00, 0x01, 0x02, 0x03, 0x04, 0x05})
	testing.expect_value(t, garbage_err, Importer_Error.Malformed_Image)

	full := IMAGE_FIXTURE_PNG
	truncated := full[:len(full) - 20]
	_, truncated_err := import_image(truncated)
	testing.expect_value(t, truncated_err, Importer_Error.Malformed_Image)
}

@(test)
test_import_asset_dispatch_keyed_on_kind :: proc(t: ^testing.T) {
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
