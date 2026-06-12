package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The golden assets tree lives in the funpack-spec sibling checkout; the
// committed manifest is examples/assets/assets/assets.manifest (the inner
// `assets/` is the bake's output dir, alongside the .fpm/.atlas sources).
ASSETS_DEFAULT_DIR :: "../funpack-spec/examples/assets"

resolve_assets_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ASSETS_DIR", ASSETS_DEFAULT_DIR)
}

// golden_manifest reads the committed assets.manifest; ok = false (with a
// SKIP warning) when the sibling checkout is absent, matching the golden
// tests' resolve-or-skip discipline so a missing checkout warns loudly
// instead of silently testing nothing.
golden_manifest :: proc() -> (content: string, ok: bool) {
	dir := resolve_assets_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP assets manifest: %s not found — set FUNPACK_ASSETS_DIR or check out funpack-spec as a sibling of the repo", dir)
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
	// The reader's defining outcome over the live §19-literal golden manifest:
	// FOUR entries — the coin model, the first-class `pickups.png` IMAGE node the
	// §19-literal bake discovers ahead of its atlas, the pickups atlas that
	// deps-on that image, and the coin audio. The counts are pinned to the golden
	// file on purpose — when the manifest grows an entry, this count changes in
	// lockstep. The dependency hash is asserted by SHAPE (a `pickups.png@sha256:`
	// edge), not exact value, so the placeholder image's bytes are free to change
	// without churning this structural test.
	content, ok := golden_manifest()
	if !ok {
		return
	}
	manifest, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(manifest.entries), 4)

	// Entries are in committed-file order, walked by index — the bottom-up DAG
	// order puts each discovered image immediately ahead of its atlas.
	coin := manifest.entries[0]
	testing.expect_value(t, coin.name, "coin")
	testing.expect_value(t, coin.kind, Asset_Kind.Model)
	testing.expect_value(t, coin.source, "coin.fpm")
	testing.expect_value(t, coin.importer_version, "model@3")
	testing.expect_value(t, len(coin.deps), 0)

	// The first-class image node: a raw-image DAG root (no deps), named by its
	// filename, discovered from the pickups atlas's `image "pickups.png"` clause.
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
	// pickups deps-on its real image input; that dependency hash is the one the
	// §2 hasher folds into pickups' own hash — asserted by edge shape.
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
	// The §2 hash rule's two load-bearing properties: same inputs always
	// yield the same hash (reproducible anywhere), and dependency order is
	// significant (an atlas hashing [image, palette] differs from [palette,
	// image]) — proven on hand-built inputs, no checkout needed.
	source := transmute([]byte)string("the coin mesh source bytes")
	importer := "model@3"
	deps := []string{"sha256:aaaa", "sha256:bbbb"}

	h1 := asset_content_hash(source, importer, deps)
	h2 := asset_content_hash(source, importer, deps)
	testing.expect(t, h1 == h2, "identical inputs must yield an identical hash")

	// The canonical form carries the algorithm prefix the manifest writes.
	testing.expect(t, len(h1) == len(HASH_PREFIX) + 64, "hash is sha256: + 64 hex chars")
	testing.expectf(t, h1[:len(HASH_PREFIX)] == HASH_PREFIX, "hash carries the %q prefix", HASH_PREFIX)

	// Reordering deps changes the canonical byte stream, so the hash differs.
	reordered := []string{"sha256:bbbb", "sha256:aaaa"}
	h_reordered := asset_content_hash(source, importer, reordered)
	testing.expect(t, h1 != h_reordered, "reordering deps must change the hash")
}

@(test)
test_asset_content_hash_field_inputs_distinguish :: proc(t: ^testing.T) {
	// Length-prefixed framing makes the field boundaries unambiguous: the
	// same total bytes split differently across (source, importer) must not
	// collide. "ab" + "c" and "a" + "bc" share a naive concatenation but
	// differ under framing.
	a := asset_content_hash(transmute([]byte)string("ab"), "c", nil)
	b := asset_content_hash(transmute([]byte)string("a"), "bc", nil)
	testing.expect(t, a != b, "field framing must distinguish shifted boundaries")

	// An empty dep list and a single empty-string dep also differ — the dep
	// count is folded in, not just the dep bytes.
	none := asset_content_hash(transmute([]byte)string("x"), "v", nil)
	one_empty := asset_content_hash(transmute([]byte)string("x"), "v", []string{""})
	testing.expect(t, none != one_empty, "dep count must distinguish empty list from one empty dep")
}

@(test)
test_asset_manifest_rejects_unknown_kind :: proc(t: ^testing.T) {
	// The closed kind set: a fourth kind is not a tolerated extension, it is
	// an Unknown_Kind reject (the one error case the suite proves).
	content := "[shader]\nkind = shader\nsource = \"x.glsl\"\nimporter = \"shader@1\"\ndeps = []\nhash = \"sha256:00\"\nout = \".cache/x\"\n"
	_, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.Unknown_Kind)
}

@(test)
test_asset_manifest_rejects_missing_key :: proc(t: ^testing.T) {
	// A block missing a required key (here `out`) is Missing_Key — the
	// manifest is a complete index, never partially populated.
	content := "[coin]\nkind = model\nsource = \"coin.fpm\"\nimporter = \"model@3\"\ndeps = []\nhash = \"sha256:00\"\n"
	_, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.Missing_Key)
}

@(test)
test_asset_manifest_rejects_duplicate_name :: proc(t: ^testing.T) {
	// Two blocks registering the same name collide — the registry is
	// single-owner, like §15.6 module identity.
	block := "[coin]\nkind = model\nsource = \"coin.fpm\"\nimporter = \"model@3\"\ndeps = []\nhash = \"sha256:00\"\nout = \".cache/coin\"\n"
	content := strings.concatenate({block, block}, context.temp_allocator)
	_, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.Duplicate_Name)
}

@(test)
test_asset_manifest_parses_inline_grammar :: proc(t: ^testing.T) {
	// Parse a hand-built manifest exercising the full grammar surface —
	// `#` comments (full-line and trailing), a multi-element deps list, key
	// order independence — independent of the on-disk golden so the grammar
	// is proven, not just the two golden lines.
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
