package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

ASSETS_DEFAULT_DIR :: "examples/assets"

resolve_assets_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ASSETS_DIR", ASSETS_DEFAULT_DIR)
}

golden_manifest :: proc() -> (content: string, ok: bool) {
	dir := resolve_assets_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP assets manifest: %s not found — set FUNPACK_ASSETS_DIR or ensure the in-repo fixture exists", dir)
		return "", false
	}
	manifest_path, _ := filepath.join({dir, "assets", "assets.manifest"}, context.temp_allocator)
	bytes, file_err := os.read_entire_file_from_path(manifest_path, context.temp_allocator)
	if file_err != nil {
		log.warnf("SKIP assets manifest: %s unreadable", manifest_path)
		return "", false
	}
	return string(bytes), true
}

@(test)
test_asset_manifest_reads_four_entries :: proc(t: ^testing.T) {
	content, ok := golden_manifest()
	if !ok {
		return
	}
	manifest, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(manifest.entries), 4)

	coin := manifest.entries[0]
	testing.expect_value(t, coin.name, "coin")
	testing.expect_value(t, coin.kind, Asset_Kind.Model)
	testing.expect_value(t, coin.source, "coin.fpm")
	testing.expect_value(t, coin.importer_version, "model@3")
	testing.expect_value(t, len(coin.deps), 0)

	image := manifest.entries[1]
	testing.expect_value(t, image.name, "pickups.png")
	testing.expect_value(t, image.kind, Asset_Kind.Image)
	testing.expect_value(t, image.source, "pickups.png")
	testing.expect_value(t, image.importer_version, "image@1")
	testing.expect_value(t, len(image.deps), 0)

	pickups := manifest.entries[2]
	testing.expect_value(t, pickups.name, "pickups")
	testing.expect_value(t, pickups.kind, Asset_Kind.Atlas)
	testing.expect_value(t, pickups.source, "pickups.atlas")
	testing.expect_value(t, len(pickups.deps), 1)
	testing.expect(t, strings.has_prefix(pickups.deps[0], "pickups.png@sha256:"), "pickups deps-on the real pickups.png image hash")

	coin_sfx := manifest.entries[3]
	testing.expect_value(t, coin_sfx.name, "coin_sfx")
	testing.expect_value(t, coin_sfx.kind, Asset_Kind.Audio)
	testing.expect_value(t, coin_sfx.source, "audio/coin.wav")
	testing.expect_value(t, len(coin_sfx.deps), 0)
}

@(test)
test_asset_content_hash_deterministic_and_order_sensitive :: proc(t: ^testing.T) {
	source := transmute([]byte)string("the coin mesh source bytes")
	importer := "model@3"
	deps := []string{"sha256:aaaa", "sha256:bbbb"}

	h1 := asset_content_hash(source, importer, deps)
	h2 := asset_content_hash(source, importer, deps)
	testing.expect(t, h1 == h2, "identical inputs must yield an identical hash")

	testing.expect(t, len(h1) == len(HASH_PREFIX) + 64, "hash is sha256: + 64 hex chars")
	testing.expectf(t, h1[:len(HASH_PREFIX)] == HASH_PREFIX, "hash carries the %q prefix", HASH_PREFIX)

	reordered := []string{"sha256:bbbb", "sha256:aaaa"}
	h_reordered := asset_content_hash(source, importer, reordered)
	testing.expect(t, h1 != h_reordered, "reordering deps must change the hash")
}

@(test)
test_asset_content_hash_field_inputs_distinguish :: proc(t: ^testing.T) {
	a := asset_content_hash(transmute([]byte)string("ab"), "c", nil)
	b := asset_content_hash(transmute([]byte)string("a"), "bc", nil)
	testing.expect(t, a != b, "field framing must distinguish shifted boundaries")

	none := asset_content_hash(transmute([]byte)string("x"), "v", nil)
	one_empty := asset_content_hash(transmute([]byte)string("x"), "v", []string{""})
	testing.expect(t, none != one_empty, "dep count must distinguish empty list from one empty dep")
}

@(test)
test_asset_manifest_rejects_unknown_kind :: proc(t: ^testing.T) {
	content := "[shader]\nkind = shader\nsource = \"x.glsl\"\nimporter = \"shader@1\"\ndeps = []\nhash = \"sha256:00\"\nout = \".cache/x\"\n"
	_, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.Unknown_Kind)
}

@(test)
test_asset_manifest_rejects_missing_key :: proc(t: ^testing.T) {
	content := "[coin]\nkind = model\nsource = \"coin.fpm\"\nimporter = \"model@3\"\ndeps = []\nhash = \"sha256:00\"\n"
	_, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.Missing_Key)
}

@(test)
test_asset_manifest_rejects_duplicate_name :: proc(t: ^testing.T) {
	block := "[coin]\nkind = model\nsource = \"coin.fpm\"\nimporter = \"model@3\"\ndeps = []\nhash = \"sha256:00\"\nout = \".cache/coin\"\n"
	content := strings.concatenate({block, block}, context.temp_allocator)
	_, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.Duplicate_Name)
}

@(test)
test_asset_manifest_parses_inline_grammar :: proc(t: ^testing.T) {
	content := "# a generated index\n[pickups]\nsource = \"pickups.atlas\"  # trailing comment\nkind = atlas\nimporter = \"atlas@2\"\ndeps = [\"a.png@sha256:1\", \"b.pal@sha256:2\",]\nout = \".cache/p\"\nhash = \"sha256:cc\"\n"
	manifest, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(manifest.entries), 1)
	entry := manifest.entries[0]
	testing.expect_value(t, entry.name, "pickups")
	testing.expect_value(t, entry.kind, Asset_Kind.Atlas)
	testing.expect_value(t, len(entry.deps), 2)
	testing.expect_value(t, entry.deps[0], "a.png@sha256:1")
	testing.expect_value(t, entry.deps[1], "b.pal@sha256:2")
}
