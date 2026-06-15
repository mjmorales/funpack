// The .tiles importer fixtures: parser accept/reject over the grammar
// (grammar/tiles.ebnf), the named §18 §2 semantic rejects, the §19 manifest
// path the dungeon/warren corpus bakes through, and the TilesetHandle seam
// emission + §26 engine.tilemap surface admission pins. Golden sources are the
// REAL corpus files in the in-repo examples tree (examples/dungeon and
// examples/warren), resolved with the loud-SKIP discipline the asset battery's
// tests share — a missing checkout warns, never silently passes.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// The dungeon/warren golden asset dirs in the in-repo examples tree —
// each holds the committed .tiles source, its .atlas, and the assets.manifest
// whose tileset entry deps-on the atlas (§19 §5).
DUNGEON_ASSETS_DEFAULT_DIR :: "examples/dungeon/assets"
WARREN_ASSETS_DEFAULT_DIR :: "examples/warren/assets"

resolve_dungeon_assets_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_DUNGEON_ASSETS", DUNGEON_ASSETS_DEFAULT_DIR)
}

resolve_warren_assets_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_WARREN_ASSETS", WARREN_ASSETS_DEFAULT_DIR)
}

// tiles_golden_source reads one committed file from a resolved golden assets
// dir; ok = false (with a SKIP warning) when the sibling checkout is absent,
// matching golden_asset_source's resolve-or-skip discipline.
tiles_golden_source :: proc(dir: string, filename: string) -> (content: string, ok: bool) {
	if !os.is_dir(dir) {
		log.warnf("SKIP tiles importer: %s not found — set FUNPACK_DUNGEON_ASSETS/FUNPACK_WARREN_ASSETS or ensure the in-repo fixture exists", dir)
		return "", false
	}
	path, _ := filepath.join({dir, filename}, context.temp_allocator)
	bytes, file_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if file_err != nil {
		log.warnf("SKIP tiles importer: %s unreadable", path)
		return "", false
	}
	return string(bytes), true
}

// ── Golden corpus accepts ─────────────────────────────────────────────────

@(test)
test_import_tileset_dungeon_golden :: proc(t: ^testing.T) {
	// The tiles importer's defining outcome over the live golden dungeon.tiles:
	// four tile types in source order with their cells, collision verdicts, and
	// tags, drawing from the dungeon_atlas. The counts are pinned to the golden
	// file on purpose — when the tileset grows a tile, this changes in lockstep.
	src, ok := tiles_golden_source(resolve_dungeon_assets_dir(), "dungeon.tiles")
	if !ok {
		return
	}
	atlas_hash := "dungeon_atlas@sha256:5b08d1f3"
	asset, err := import_tileset(src, []string{atlas_hash})
	testing.expect_value(t, err, Importer_Error.None)
	testing.expect_value(t, asset.name, "Dungeon")
	testing.expect_value(t, asset.atlas, "dungeon_atlas")

	testing.expect_value(t, len(asset.tiles), 4)
	floor := asset.tiles[0]
	testing.expect_value(t, floor.name, "floor")
	testing.expect_value(t, floor.cell_x, 0)
	testing.expect_value(t, floor.cell_y, 0)
	testing.expect_value(t, floor.solid, false)
	testing.expect_value(t, len(floor.tags), 0)

	wall := asset.tiles[1]
	testing.expect_value(t, wall.name, "wall")
	testing.expect_value(t, wall.cell_x, 1)
	testing.expect_value(t, wall.solid, true)

	water := asset.tiles[2]
	testing.expect_value(t, water.name, "water")
	testing.expect_value(t, water.cell_x, 2)
	testing.expect_value(t, water.solid, false)
	testing.expect_value(t, len(water.tags), 1)
	testing.expect_value(t, water.tags[0], "liquid")

	rubble := asset.tiles[3]
	testing.expect_value(t, rubble.name, "rubble")
	testing.expect_value(t, rubble.cell_x, 3)
	testing.expect_value(t, rubble.solid, true)
	testing.expect_value(t, len(rubble.tags), 1)
	testing.expect_value(t, rubble.tags[0], "diggable")

	// The atlas is recorded as the §4 dependency and the content hash carries
	// the §2 canonical prefix — the asset's identity through the manifest.
	testing.expect_value(t, asset.atlas_dep, atlas_hash)
	testing.expect(t, len(asset.hash) == len(HASH_PREFIX) + 64, "tileset hash is sha256: + 64 hex chars")
}

@(test)
test_import_tileset_warren_golden :: proc(t: ^testing.T) {
	// The second corpus source: the warren maze's two tile types over the
	// `warren` atlas — the minimal real tileset, pinned in lockstep too.
	src, ok := tiles_golden_source(resolve_warren_assets_dir(), "warren.tiles")
	if !ok {
		return
	}
	asset, err := import_tileset(src, []string{"warren@sha256:a4517c9b"})
	testing.expect_value(t, err, Importer_Error.None)
	testing.expect_value(t, asset.name, "Warren")
	testing.expect_value(t, asset.atlas, "warren")
	testing.expect_value(t, len(asset.tiles), 2)
	testing.expect_value(t, asset.tiles[0].name, "floor")
	testing.expect_value(t, asset.tiles[0].solid, false)
	testing.expect_value(t, asset.tiles[1].name, "wall")
	testing.expect_value(t, asset.tiles[1].cell_x, 1)
	testing.expect_value(t, asset.tiles[1].solid, true)
}

// ── The §19 manifest path ─────────────────────────────────────────────────

@(test)
test_dungeon_manifest_registers_tileset :: proc(t: ^testing.T) {
	// The committed (GENERATED) dungeon assets.manifest registers the §19-literal
	// DAG: the discovered image node (kind=image, named by the PNG filename), then
	// its atlas, then the tileset — three entries in bottom-up order. The tileset
	// (the LAST entry) deps-on its atlas (the §19 §5 edge). The dep prefix is the
	// atlas name `dungeon_atlas@sha256:`; the digest is now a REAL full hash (the
	// §19-literal bake reads the real PNG, no phantom). Pinned to the golden
	// manifest in lockstep — the image node moved the tileset from index 1 to 2.
	content, ok := tiles_golden_source(resolve_dungeon_assets_dir(), "assets.manifest")
	if !ok {
		return
	}
	manifest, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(manifest.entries), 3)

	// The first entry is the discovered image node — a first-class manifest asset
	// (kind=image), the atlas's raw-image dependency read off disk and hashed.
	image := manifest.entries[0]
	testing.expect_value(t, image.kind, Asset_Kind.Image)
	testing.expect_value(t, image.name, "dungeon.png")
	testing.expect_value(t, len(image.deps), 0)

	tileset := manifest.entries[2]
	testing.expect_value(t, tileset.name, "dungeon")
	testing.expect_value(t, tileset.kind, Asset_Kind.Tileset)
	testing.expect_value(t, tileset.source, "dungeon.tiles")
	testing.expect_value(t, tileset.importer_version, TILES_IMPORTER_VERSION)
	testing.expect_value(t, len(tileset.deps), 1)
	testing.expect(t, has_prefix_string(tileset.deps[0], "dungeon_atlas@sha256:"), "the tileset deps-on its atlas")
}

@(test)
test_warren_manifest_registers_tileset :: proc(t: ^testing.T) {
	// Same pin over the warren manifest — the §19-literal three-node DAG (image,
	// atlas, tileset). The tileset entry's NAME differs from its tileset block's
	// name (warren_tiles vs Warren): the manifest name is the handle the seam
	// emits, the block name is the DSL's. The image node moved the tileset to
	// index 2.
	content, ok := tiles_golden_source(resolve_warren_assets_dir(), "assets.manifest")
	if !ok {
		return
	}
	manifest, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(manifest.entries), 3)

	image := manifest.entries[0]
	testing.expect_value(t, image.kind, Asset_Kind.Image)
	testing.expect_value(t, image.name, "warren.png")
	testing.expect_value(t, len(image.deps), 0)

	tileset := manifest.entries[2]
	testing.expect_value(t, tileset.name, "warren_tiles")
	testing.expect_value(t, tileset.kind, Asset_Kind.Tileset)
	testing.expect_value(t, tileset.source, "warren.tiles")
	testing.expect_value(t, tileset.importer_version, TILES_IMPORTER_VERSION)
	testing.expect_value(t, len(tileset.deps), 1)
	testing.expect(t, has_prefix_string(tileset.deps[0], "warren@sha256:"), "the tileset deps-on its atlas")
}

@(test)
test_import_tileset_bakes_through_manifest :: proc(t: ^testing.T) {
	// The §19 path end-to-end over the dungeon corpus: the committed manifest's
	// tileset entry names the source and the atlas dependency; the closed
	// import_asset dispatch routes the source bytes through import_tileset with
	// the entry's deps; the result is the content-hashed Tileset_Asset the seam
	// bakes to a TilesetHandle.
	manifest_content, ok := tiles_golden_source(resolve_dungeon_assets_dir(), "assets.manifest")
	if !ok {
		return
	}
	manifest, manifest_err := read_asset_manifest(manifest_content)
	testing.expect_value(t, manifest_err, Asset_Manifest_Error.None)

	// The tileset is the LAST entry of the §19-literal DAG (image, atlas, tileset).
	entry := manifest.entries[2]
	src, src_ok := tiles_golden_source(resolve_dungeon_assets_dir(), entry.source)
	if !src_ok {
		return
	}
	imported, err := import_asset(entry.kind, transmute([]byte)src, entry.deps)
	testing.expect_value(t, err, Importer_Error.None)
	tileset, is_tileset := imported.(Tileset_Asset)
	testing.expect(t, is_tileset, "a .Tileset kind dispatches to import_tileset")
	if !is_tileset {
		return
	}
	testing.expect_value(t, tileset.atlas_dep, entry.deps[0])
	testing.expect(t, len(tileset.hash) == len(HASH_PREFIX) + 64, "the baked tileset carries its §2 content hash")
}

@(test)
test_manifest_reads_tileset_kind_inline :: proc(t: ^testing.T) {
	// The closed-kind admit, checkout-independent: a `kind = tileset` block
	// parses to .Tileset (and the closed set still rejects an unknown word —
	// asset_manifest_test owns that reject).
	content := "[t]\nkind = tileset\nsource = \"t.tiles\"\nimporter = \"tiles@1\"\ndeps = [\"a@sha256:1\"]\nhash = \"sha256:2\"\nout = \".cache/t\"\n"
	manifest, err := read_asset_manifest(content)
	testing.expect_value(t, err, Asset_Manifest_Error.None)
	testing.expect_value(t, len(manifest.entries), 1)
	testing.expect_value(t, manifest.entries[0].kind, Asset_Kind.Tileset)
}

// ── Determinism & invalidation ────────────────────────────────────────────

@(test)
test_import_tileset_deterministic :: proc(t: ^testing.T) {
	// §29 purity: the same source bytes and atlas dep always yield the same
	// content hash — proven on a hand-built source so it needs no checkout.
	src := "tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false }\n}\n"
	a, ea := import_tileset(src, []string{"a@sha256:aaaa"})
	b, eb := import_tileset(src, []string{"a@sha256:aaaa"})
	testing.expect_value(t, ea, Importer_Error.None)
	testing.expect_value(t, eb, Importer_Error.None)
	testing.expect(t, a.hash == b.hash, "identical tileset source must yield an identical hash")
}

@(test)
test_import_tileset_atlas_dep_changes_hash :: proc(t: ^testing.T) {
	// §4 correct invalidation: the tileset hashes OVER its atlas dependency, so
	// a re-baked atlas (different dep hash) yields a different tileset hash.
	src := "tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false }\n}\n"
	h1, e1 := import_tileset(src, []string{"a@sha256:aaaa"})
	h2, e2 := import_tileset(src, []string{"a@sha256:bbbb"})
	testing.expect_value(t, e1, Importer_Error.None)
	testing.expect_value(t, e2, Importer_Error.None)
	testing.expect(t, h1.hash != h2.hash, "a re-baked atlas (different dep hash) must re-bake the tileset")
}

// ── Named semantic rejects (§18 §2 fail-closed floors) ────────────────────

@(test)
test_import_tileset_rejects_missing_cell :: proc(t: ^testing.T) {
	// A grammar-legal tile with no `cell:` cannot draw — the named reject, not
	// a defaulted coordinate.
	src := "tileset T {\n atlas a\n tile floor { solid: false }\n}\n"
	_, err := import_tileset(src, []string{"a@sha256:1"})
	testing.expect_value(t, err, Importer_Error.Missing_Tile_Cell)
}

@(test)
test_import_tileset_rejects_missing_solid :: proc(t: ^testing.T) {
	// A grammar-legal tile with no `solid:` has no collision verdict — §18 §2
	// bakes collision, never assumes it.
	src := "tileset T {\n atlas a\n tile floor { cell: (0, 0) }\n}\n"
	_, err := import_tileset(src, []string{"a@sha256:1"})
	testing.expect_value(t, err, Importer_Error.Missing_Tile_Solid)
}

@(test)
test_import_tileset_rejects_duplicate_tile_name :: proc(t: ^testing.T) {
	// Two tiles sharing a name within one tileset — the §18 §3 one-name-one-tile
	// discipline applied inside the file.
	src := "tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false }\n tile floor { cell: (1, 0), solid: true }\n}\n"
	_, err := import_tileset(src, []string{"a@sha256:1"})
	testing.expect_value(t, err, Importer_Error.Duplicate_Tile_Name)
}

// ── Grammar rejects (the uniform Malformed_Source) ────────────────────────

@(test)
test_import_tileset_rejects_malformed :: proc(t: ^testing.T) {
	// One sweep over the grammar-reject space, each a distinct malformed form;
	// all collapse to the battery's uniform Malformed_Source.
	cases := []string{
		// missing atlas member — a tileset whose tiles can name no cells
		"tileset T {\n tile floor { cell: (0, 0), solid: false }\n}\n",
		// duplicate single-slot atlas member
		"tileset T {\n atlas a\n atlas b\n tile floor { cell: (0, 0), solid: false }\n}\n",
		// duplicate field within a tile
		"tileset T {\n atlas a\n tile floor { cell: (0, 0), cell: (1, 0), solid: false }\n}\n",
		// wrong-case tileset name (UPPER_IDENT position)
		"tileset t {\n atlas a\n tile floor { cell: (0, 0), solid: false }\n}\n",
		// wrong-case tile name (LOWER_IDENT position)
		"tileset T {\n atlas a\n tile Floor { cell: (0, 0), solid: false }\n}\n",
		// wrong-case atlas reference (LOWER_IDENT position)
		"tileset T {\n atlas A\n tile floor { cell: (0, 0), solid: false }\n}\n",
		// empty tile block (the grammar's TileField+ floor)
		"tileset T {\n atlas a\n tile floor { }\n}\n",
		// two members butted together with no Sep between them
		"tileset T {\n atlas a tile floor { cell: (0, 0), solid: false }\n}\n",
		// trailing junk after the one TilesUnit block
		"tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false }\n}\nextra\n",
		// trailing comma in the tags list (the grammar admits none)
		"tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false, tags: [\"x\",] }\n}\n",
		// non-string tags element
		"tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false, tags: [liquid] }\n}\n",
		// solid with a non-BOOL value
		"tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: 1 }\n}\n",
		// cell missing its tuple comma
		"tileset T {\n atlas a\n tile floor { cell: (0 0), solid: false }\n}\n",
		// unterminated string
		"tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false, tags: [\"liquid] }\n}\n",
		// stray glyph
		"tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false };\n}\n",
		// unterminated block
		"tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false }\n",
		// a directive outside the closed lexical-core §5 metadata set
		"@shader(\"x\")\ntileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false }\n}\n",
		// empty input
		"",
	}
	for src in cases {
		_, err := import_tileset(src, []string{"a@sha256:1"})
		testing.expectf(t, err == .Malformed_Source, "expected Malformed_Source, got %v for: %s", err, src)
	}
}

@(test)
test_import_tileset_rejects_dep_count_mismatch :: proc(t: ^testing.T) {
	// A tileset declares exactly one atlas, so it carries exactly one resolved
	// dependency hash — zero or two is a malformed bake graph (the atlas
	// importer's discipline).
	src := "tileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false }\n}\n"
	_, err_none := import_tileset(src, nil)
	testing.expect_value(t, err_none, Importer_Error.Malformed_Source)
	_, err_two := import_tileset(src, []string{"a@sha256:1", "b@sha256:2"})
	testing.expect_value(t, err_two, Importer_Error.Malformed_Source)
}

@(test)
test_import_tileset_accepts_leading_directives :: proc(t: ^testing.T) {
	// TilesUnit ::= Directive* TilesetBlock — the closed lexical-core §5
	// metadata directives are admitted ahead of the block and consumed as
	// metadata this importer does not lift.
	src := "@doc(\"the test tileset\")\n@gtag(\"tiles\", \"test\")\ntileset T {\n atlas a\n tile floor { cell: (0, 0), solid: false }\n}\n"
	asset, err := import_tileset(src, []string{"a@sha256:1"})
	testing.expect_value(t, err, Importer_Error.None)
	testing.expect_value(t, asset.name, "T")
	testing.expect_value(t, len(asset.tiles), 1)
}

// ── TilesetHandle seam emission ───────────────────────────────────────────

@(test)
test_emit_tileset_handle_constant :: proc(t: ^testing.T) {
	// The §19 §3 seam over a tileset-bearing manifest: the handle types group
	// into one import line per §26 owning module — engine.assets first-use
	// first, then engine.tilemap — and the tileset's typed constant binds a
	// TilesetHandle keyed on its registered name.
	entries := make([]Asset_Entry, 2, context.temp_allocator)
	entries[0] = Asset_Entry{name = "dungeon_atlas", kind = .Atlas}
	entries[1] = Asset_Entry{name = "dungeon", kind = .Tileset}
	manifest := Asset_Manifest{entries = entries}
	docs := []string{"The dungeon sprite atlas.", "The dungeon tileset."}

	emitted := emit_assets_gen_fun(manifest, docs, context.temp_allocator)
	testing.expect(t, contains_substring(emitted, "import engine.assets.{AtlasHandle}\nimport engine.tilemap.{TilesetHandle}\n"))
	testing.expect(t, contains_substring(emitted, "let dungeon: TilesetHandle = TilesetHandle{name: \"dungeon\"}\n"))
}

@(test)
test_emit_tileset_only_manifest_imports_tilemap_alone :: proc(t: ^testing.T) {
	// A manifest registering only tilesets imports engine.tilemap alone — no
	// empty engine.assets line is ever emitted.
	entries := make([]Asset_Entry, 1, context.temp_allocator)
	entries[0] = Asset_Entry{name = "warren_tiles", kind = .Tileset}
	manifest := Asset_Manifest{entries = entries}
	docs := []string{"The warren tileset."}

	emitted := emit_assets_gen_fun(manifest, docs, context.temp_allocator)
	testing.expect(t, contains_substring(emitted, "import engine.tilemap.{TilesetHandle}\n"))
	testing.expect(t, !contains_substring(emitted, "engine.assets"))
}

// ── §26 engine.tilemap surface admission ──────────────────────────────────

@(test)
test_engine_tilemap_surface_resolves_tileset_handle :: proc(t: ^testing.T) {
	// The partition's admitted rows resolve: TilesetHandle, TilemapHandle, AND
	// SetTile — the complete §26 tilemap row — all bind to engine.tilemap as
	// Type_Names. A name outside the row is Unknown_Member, pinning that any
	// further growth stays a deliberate edit (the four §18 §4 query Funcs are
	// pinned in tilemap_fixture_test.odin).
	source := "import engine.tilemap.{TilesetHandle, TilemapHandle, SetTile}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	if err != .None {
		return
	}
	binding, bound := bindings.names["TilesetHandle"]
	testing.expect(t, bound, "TilesetHandle must bind")
	if bound {
		testing.expect_value(t, binding.module, "engine.tilemap")
		testing.expect_value(t, binding.kind, Decl_Kind.Type_Name)
	}
	layer_binding, layer_bound := bindings.names["TilemapHandle"]
	testing.expect(t, layer_bound, "TilemapHandle must bind")
	if layer_bound {
		testing.expect_value(t, layer_binding.module, "engine.tilemap")
		testing.expect_value(t, layer_binding.kind, Decl_Kind.Type_Name)
	}
	settile_binding, settile_bound := bindings.names["SetTile"]
	testing.expect(t, settile_bound, "SetTile must bind")
	if settile_bound {
		testing.expect_value(t, settile_binding.module, "engine.tilemap")
		testing.expect_value(t, settile_binding.kind, Decl_Kind.Type_Name)
	}

	bogus, bogus_err := stage_parse(stage_lex("import engine.tilemap.{WarpTile}\n"))
	testing.expect_value(t, bogus_err, Parse_Error.None)
	_, reject := resolve_imports(bogus)
	testing.expect_value(t, reject, Type_Error.Unknown_Member)
}

@(test)
test_tilemap_handle_typecheck_fixture :: proc(t: ^testing.T) {
	// The admit side of the layer handle's record schema: a TilemapHandle
	// param, return, and `TilemapHandle{name: "…"}` literal all typecheck
	// clean — the level seam's layer-constant shape (`let terrain:
	// TilemapHandle = TilemapHandle{name: "terrain"}`), CI-executing and
	// sibling-independent (the TilesetHandle fixture pattern).
	source := "import engine.tilemap.TilemapHandle\n" +
		"let terrain: TilemapHandle = TilemapHandle{name: \"terrain\"}\n" +
		"fn pick(layer: TilemapHandle) -> TilemapHandle {\n" +
		"  return layer\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_tilemap_handle_unknown_field_is_compile_error :: proc(t: ^testing.T) {
	// The reject side: the layer handle's closed schema is the single String
	// `name` — an extra field fails the record check, the same closed-schema
	// rejection every engine record enforces.
	source := "import engine.tilemap.TilemapHandle\n" +
		"fn bad() -> TilemapHandle {\n" +
		"  return TilemapHandle{name: \"terrain\", cells: 4}\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect(t, err != .None)
}

@(test)
test_tileset_handle_typecheck_fixture :: proc(t: ^testing.T) {
	// The admit side of the record schema: a TilesetHandle param, return, and
	// `TilesetHandle{name: "…"}` literal all typecheck clean — the seam
	// constant's shape, CI-executing and sibling-independent (the AtlasHandle
	// fixture pattern).
	source := "import engine.tilemap.TilesetHandle\n" +
		"fn pick(tiles: TilesetHandle) -> TilesetHandle {\n" +
		"  return tiles\n" +
		"}\n" +
		"fn dungeon_tiles() -> TilesetHandle {\n" +
		"  return TilesetHandle{name: \"dungeon\"}\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_tileset_handle_unknown_field_is_compile_error :: proc(t: ^testing.T) {
	// The reject side: the handle's closed schema is the single String `name` —
	// an extra field fails the record check (the same closed-schema rejection
	// every engine record enforces).
	source := "import engine.tilemap.TilesetHandle\n" +
		"fn bad() -> TilesetHandle {\n" +
		"  return TilesetHandle{name: \"dungeon\", cells: 4}\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect(t, err != .None)
}

// has_prefix_string reports whether `text` begins with `prefix` — the dep-edge
// probe over the manifest's ellipsized golden hashes (the committed hash tails
// are abbreviated, so the pin is the name@sha256: head, not the full digest).
has_prefix_string :: proc(text: string, prefix: string) -> bool {
	return len(text) >= len(prefix) && text[:len(prefix)] == prefix
}
