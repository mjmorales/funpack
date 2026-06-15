// The tilemaps-tiles capstone goldens over the LIVE dungeon/warren corpus
// (examples/dungeon, examples/warren): the §18 §3 tile layer in
// BOTH build products, end-to-end.
//
//   DUNGEON — compiles end-to-end through parse → typecheck → bake → emit:
//     1. SEAM BYTE MATCH — a fresh bake of levels/dungeon.flvl reproduces the
//        committed gen/dungeon.gen.fun byte-for-byte (the terrain TilemapHandle
//        constant, the hero/loot Refs, the spawn-list + accessor externs), and
//        the manifest reproduces gen/assets.gen.fun (the atlas + tileset
//        handles). FUNPACK_REGEN_GOLDEN=1 rewrites the committed copies from
//        the live emitters (the statequery regen mold); a normal run compares.
//     2. PROJECT COMPILES + INLINE TESTS — read_project merges src/ + the
//        committed gen/ seams, every module clears the compile pipeline, and
//        the funpack-evaluable inline asserts pass at their EXACT pinned count
//        (the golden-count discipline — never a range).
//     3. BOTH PRODUCTS — stage_build over the live tree emits the v12 artifact
//        whose [tilemaps] section carries the terrain layer WITH its anchor
//        lead line, plus the index NDJSON; double-build is byte-identical.
//
//   WARREN — compiles end-to-end through the same pipeline INCLUDING the §12
//   engine.nav QUERY surface (the navigation milestone admitted it):
//     4. SEAM BYTE MATCH — gen/warren.gen.fun and gen/assets.gen.fun, same
//        contract as the dungeon's.
//     5. NAV ADMITTED + GREEN — warren_world, the warren seam, AND warren_game
//        all typecheck clean: the §12 graph queries (`nav.los/reachable/`
//        `nearest/path` and `Path.advance`) are admitted in surface.odin and
//        funpack-evaluated through Nav.of, so the chase AI's inline asserts run
//        GREEN at their EXACT pinned count (the golden-count discipline — never
//        a range), and stage_build emits both products. This is the warren
//        pin FLIPPED — the navigation milestone's acceptance.
//
// All tests resolve the in-repo examples tree and SKIP LOUDLY when it
// is absent — a skipped golden is a warning, never a pass.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// ── Authored seam docs (bake metadata, verbatim in the committed files) ──────

DUNGEON_SEAM_FILE_DOC :: "Generated seam for levels/dungeon.flvl: the terrain layer's typed TilemapHandle, typed references to the level's named instances, and the deterministic spawn list, baked from the flat-text level. Imports the schema module only. Edit the level, not this file."
DUNGEON_SEAM_TILEMAP_DOC :: "The terrain layer's typed handle: movement, the dig's SetTile, and the chest's cell test all query the baked layer through it. Generated from the tilemap in dungeon.flvl."
DUNGEON_SEAM_SYMBOLS_DOC :: "Typed references to the Dungeon level's named instances. Ids are derived from the level-qualified names, so these are stable across loads, saves, and replays. Generated from dungeon.flvl — edit the level, not this file."
DUNGEON_SEAM_SPAWNS_DOC :: "The deterministic spawn list for Dungeon: the grid's markers row-major, then the placed chest, in declaration order. Backed by dungeon.flvl."
DUNGEON_SEAM_ACCESSOR_DOC :: "The Dungeon symbol table, valid once the level is loaded."

WARREN_SEAM_FILE_DOC :: "Generated seam for levels/warren.flvl: the maze layer's typed TilemapHandle, typed references to the level's four named animals and burrows, and the deterministic spawn list, baked from the flat-text level. Imports the schema module only. Edit the level, not this file."
WARREN_SEAM_TILEMAP_DOC :: "The maze layer's typed handle. The nav graph derives from exactly this layer's solids, so the picture is the topology. Generated from the tilemap in warren.flvl."
WARREN_SEAM_SYMBOLS_DOC :: "Typed references to the Warren level's named instances, in row-major marker order. Ids are derived from the level-qualified names, so these are stable across loads, saves, and replays. Generated from warren.flvl — edit the level, not this file."
WARREN_SEAM_SPAWNS_DOC :: "The deterministic spawn list for Warren: the maze's named markers, row-major. Backed by warren.flvl."
WARREN_SEAM_ACCESSOR_DOC :: "The Warren symbol table, valid once the level is loaded."

DUNGEON_ASSETS_ATLAS_DOC :: "The dungeon sprite atlas: the hero, slime, and chest cells the draw behaviors name, plus the terrain tiles' art."
DUNGEON_ASSETS_TILESET_DOC :: "The dungeon tileset: floor, wall, water, and the diggable rubble — each tile's collision verdict is baked into the terrain layer."

WARREN_ASSETS_ATLAS_DOC :: "The warren sprite atlas the maze tiles draw from."
WARREN_ASSETS_TILESET_DOC :: "The warren tileset: the maze's floor and solid wall — the two tiles the nav graph derives from."

dungeon_level_seam_docs :: proc() -> Level_Seam_Docs {
	return Level_Seam_Docs {
		file     = DUNGEON_SEAM_FILE_DOC,
		tilemap  = DUNGEON_SEAM_TILEMAP_DOC,
		symbols  = DUNGEON_SEAM_SYMBOLS_DOC,
		spawns   = DUNGEON_SEAM_SPAWNS_DOC,
		accessor = DUNGEON_SEAM_ACCESSOR_DOC,
	}
}

warren_level_seam_docs :: proc() -> Level_Seam_Docs {
	return Level_Seam_Docs {
		file     = WARREN_SEAM_FILE_DOC,
		tilemap  = WARREN_SEAM_TILEMAP_DOC,
		symbols  = WARREN_SEAM_SYMBOLS_DOC,
		spawns   = WARREN_SEAM_SPAWNS_DOC,
		accessor = WARREN_SEAM_ACCESSOR_DOC,
	}
}

// ── Shared plumbing ──────────────────────────────────────────────────────────

// expect_committed_bytes compares freshly-emitted seam bytes against the
// committed file at dir/gen/<leaf>, byte-for-byte. Under FUNPACK_REGEN_GOLDEN
// it REWRITES the committed copy from the live emission instead (creating
// gen/ when absent) — the operator-gated regen path the statequery golden
// fixed. ok = false only on a SKIP (an unreadable committed file outside
// regen mode).
expect_committed_bytes :: proc(t: ^testing.T, dir: string, leaf: string, emitted: string) {
	gen_dir, _ := filepath.join({dir, "gen"}, context.temp_allocator)
	committed_path, _ := filepath.join({gen_dir, leaf}, context.temp_allocator)
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) != "" {
		if !os.is_dir(gen_dir) {
			testing.expect(t, os.make_directory(gen_dir) == nil)
		}
		testing.expect(t, os.write_entire_file(committed_path, transmute([]u8)emitted) == nil)
		log.infof("REGEN tilemap e2e: wrote %s (%d bytes)", committed_path, len(emitted))
		return
	}
	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP tilemap e2e: committed seam %s unreadable — regenerate with FUNPACK_REGEN_GOLDEN=1", committed_path)
		return
	}
	committed := string(committed_bytes)
	testing.expect_value(t, len(emitted), len(committed))
	testing.expect(t, emitted == committed)
	if emitted != committed {
		report_first_byte_diff(emitted, committed)
		return
	}
	log.infof("golden tilemap e2e: fresh emission reproduces %s byte-for-byte (%d bytes)", committed_path, len(emitted))
}

// emit_example_assets_seam reads an example's committed assets.manifest and
// renders its assets.gen.fun bytes with the authored per-asset docs. ok =
// false (with a loud SKIP) when the checkout or manifest is absent.
emit_example_assets_seam :: proc(t: ^testing.T, dir: string, docs: []string) -> (emitted: string, ok: bool) {
	manifest_src, manifest_ok := tilemap_golden_source(dir, {"assets", "assets.manifest"})
	if !manifest_ok {
		return "", false
	}
	manifest, manifest_err := read_asset_manifest(manifest_src)
	testing.expect_value(t, manifest_err, Asset_Manifest_Error.None)
	if manifest_err != .None {
		return "", false
	}
	return emit_assets_gen_fun(manifest, docs, context.temp_allocator), true
}

// ── Dungeon: the seam product ────────────────────────────────────────────────

@(test)
test_golden_dungeon_seam_byte_matches :: proc(t: ^testing.T) {
	// AC (seam product): the fresh dungeon bake, projected and emitted through
	// the shared emitter, reproduces the committed gen/dungeon.gen.fun — the
	// terrain layer constant leads the declarations (the byte contract the
	// hand-built TILEMAP_SEAM_EXPECTED fixture pinned — here over live bytes).
	baked, schema_ast, ok := bake_example_level(t, resolve_dungeon_example_dir(), "dungeon.flvl", "dungeon_world.fun", "dungeon_world", "dungeon.tiles")
	if !ok {
		return
	}
	seam := level_seam_of_baked(baked, schema_ast, dungeon_level_seam_docs(), context.temp_allocator)
	expect_committed_bytes(t, resolve_dungeon_example_dir(), "dungeon.gen.fun", emit_gen_fun(seam, context.temp_allocator))
}

@(test)
test_golden_dungeon_assets_seam_byte_matches :: proc(t: ^testing.T) {
	// AC (assets seam): the committed manifest (atlas + tileset) reproduces
	// gen/assets.gen.fun — the engine.assets AND engine.tilemap import lines,
	// the AtlasHandle and TilesetHandle constants.
	docs := []string{DUNGEON_ASSETS_ATLAS_DOC, DUNGEON_ASSETS_TILESET_DOC}
	emitted, ok := emit_example_assets_seam(t, resolve_dungeon_example_dir(), docs)
	if !ok {
		return
	}
	expect_committed_bytes(t, resolve_dungeon_example_dir(), "assets.gen.fun", emitted)
}

// ── Dungeon: end-to-end compile + inline tests ──────────────────────────────

@(test)
test_golden_dungeon_project_compiles_and_inline_tests_pass :: proc(t: ^testing.T) {
	// AC (end-to-end compile): the live dungeon tree — dungeon_world (schema),
	// the dungeon + assets seams (committed gen/), dungeon_game (behaviors) —
	// reads, merges, and clears the whole compile pipeline, and the
	// funpack-evaluable inline asserts pass at their EXACT count. The count is
	// pinned deliberately (the golden-count discipline): the 24 asserts of the
	// ten dungeon_game test blocks — step_cell 2, enterable 3, the fixture
	// enter gate 3, diggable 3, the fixture dig gate 3, dir_from_input 2,
	// toward 2, hero_pos 2, collect 2, chest_cell 2 — all of which evaluate in
	// the funpack interpreter (the imported structural Cell, the
	// TilemapHandle.of fixture, Input.empty/View.of, and behavior-step
	// invocation are all evaluator surface). A regression that drops one, or a
	// source edit that adds one, moves this number in lockstep — never loosen
	// it to a range.
	dir := resolve_dungeon_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden dungeon e2e: %s not found — set FUNPACK_DUNGEON_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	project, read_err, read_detail := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		log.errorf("golden dungeon e2e: read_project refused (%v %s)", read_err, read_detail)
		return
	}
	_, has_world := find_source_module(project.sources, "dungeon_world")
	_, has_seam := find_source_module(project.sources, "dungeon")
	_, has_assets := find_source_module(project.sources, "assets")
	_, has_game := find_source_module(project.sources, "dungeon_game")
	testing.expect(t, has_world)
	testing.expect(t, has_seam)
	testing.expect(t, has_assets)
	testing.expect(t, has_game)

	report := run_project_pipeline(project.sources)
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden dungeon e2e: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}
	testing.expect_value(t, report.passed, 24)
	testing.expect_value(t, report.failed, 0)
	log.infof("golden dungeon e2e: the full dungeon project compiles end-to-end; %d funpack-evaluable inline asserts pass", report.passed)
}

// ── Dungeon: both products through the build verb ───────────────────────────

@(test)
test_golden_dungeon_build_carries_tile_layer_in_both_products :: proc(t: ^testing.T) {
	// AC (both products): stage_build over the live dungeon tree emits BOTH
	// products — the v17 artifact whose [tilemaps] section carries the terrain
	// layer with its anchor + atlas lead line (`tilemap terrain 16 16 9 0
	// 618475290624 dungeon_atlas 4`: cell 16, 16×9, anchored at the level bounds'
	// top-left (0, 144·2^32), the §19 textured-render layer atlas handle name
	// `dungeon_atlas`, four palette entries) whose palette `tile` lines carry the
	// v17 atlas-cell coordinate (`tile rubble true 3 0`) and whose [nav] section
	// carries the §12 §1 nav graph derived from that same layer, and the Index
	// Contract NDJSON. Emission is deterministic: two builds of the same tree are
	// byte-identical (§29).
	dir := resolve_dungeon_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden dungeon build: %s not found — set FUNPACK_DUNGEON_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	product, verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		log.errorf("golden dungeon build: refused (%s)", build_refusal_message(verdict, context.temp_allocator))
		return
	}
	testing.expect(t, len(product.index) > 0)

	doc, parse_err := parse_artifact(product.artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
	section, found := artifact_find_section(doc, "tilemaps")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 1)
	testing.expect(t, artifact_has_line(product.artifact, "tilemap terrain 16 16 9 0 618475290624 dungeon_atlas 4"))
	// The palette `tile` lines now carry the v17 atlas-cell coordinate (the §18 §2
	// tileset cell): floor (0,0), wall (1,0), water (2,0), rubble (3,0) — the same
	// grid coords the [assets] DungeonAtlas regions lower from, so a tile resolves
	// to the same pixels through asset_region("dungeon_atlas", cell) as a sprite.
	testing.expect(t, artifact_has_line(product.artifact, "tile wall true 1 0"))
	testing.expect(t, artifact_has_line(product.artifact, "tile rubble true 3 0"))

	// The v13 [nav] section carries the §12 §1 nav graph derived from the same
	// terrain layer: one flat graph (count == 1), keyed 1:1 to the tilemap. The
	// 16×9 terrain has 91 walkable cells (NOT '#' wall and NOT '%' rubble — both
	// baked solid; water/floor/marker/void cells are walkable) and 155 4-neighbor
	// orthogonal adjacencies (right+down deduped) — computed from dungeon.flvl, not
	// guessed. The lead line carries NO grid metadata (§12 §5 hides the Cell index).
	nav_section, nav_found := artifact_find_section(doc, "nav")
	testing.expect(t, nav_found)
	testing.expect_value(t, nav_section.count, 1)
	testing.expect(t, artifact_has_line(product.artifact, "nav terrain 91 155"))

	second, second_verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, second_verdict.err, Build_Error.None)
	testing.expect(t, product.artifact == second.artifact)
	testing.expect(t, product.index == second.index)
	log.infof("golden dungeon build: both products emit, the artifact carries the anchored terrain layer (%d bytes), double-build byte-identical", len(product.artifact))
}

// ── Dungeon: the v16 [assets] sprite-pixel carry (the N>0 proof) ─────────────

@(test)
test_golden_dungeon_build_carries_populated_assets_section :: proc(t: ^testing.T) {
	// AC (v16 [assets], N>0): stage_build over the live dungeon tree emits the
	// [assets] section POPULATED — the decoded content-addressed image pixels and
	// the atlas slice rects a textured Draw_Sprite{atlas, cell} resolves against.
	// This is the N>0 path the asset-less pong/empty-tail goldens never exercise.
	// Exact structure (the golden-count discipline — never a range): [assets 2] =
	// one `image` record (dungeon.png, deduped by content hash) + one `atlas`
	// record keyed by the manifest HANDLE name (`dungeon_atlas`, v17 — NOT the
	// .atlas-declared `DungeonAtlas`, so a sprite's `assets.dungeon_atlas` resolves),
	// and the atlas carries 8 `region` cell rects
	// (floor/wall/water/rubble + hero/slime/chest_closed/chest_open). The whole
	// section round-trips through the funpack-side parse_artifact with the section
	// count reconciled against the lead-line discipline (image+atlas are lead
	// lines, region is a sub-record). The image is the dungeon manifest's hash, so
	// content-addressing is consistent between the manifest bake and the assets
	// bake. Emission is deterministic (§29): two builds are byte-identical.
	dir := resolve_dungeon_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden dungeon assets: %s not found — set FUNPACK_DUNGEON_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	product, verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		log.errorf("golden dungeon assets: refused (%s)", build_refusal_message(verdict, context.temp_allocator))
		return
	}

	doc, parse_err := parse_artifact(product.artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)

	// [assets] is the fixed §3 section tail (after [nav]); the section count
	// reconciles against the lead-line discipline through parse_artifact above
	// (a count mismatch would have been Count_Mismatch, not None). N = 2: the
	// deduped image + the atlas.
	assets_section, assets_found := artifact_find_section(doc, "assets")
	testing.expect(t, assets_found)
	testing.expect_value(t, assets_section.count, 2)
	testing.expect_value(t, assets_section.name, "assets")

	// One distinct image, content-addressed by the dungeon manifest's hash (so the
	// blob is keyed by the same content address the [assets] atlas record points
	// at). The 16×16 grid over a 64×32 atlas image yields the 4×2 cell layout. The
	// image lead line carries the hash, decoded dims, then the b64:RGBA token —
	// the prefix is pinned; the base64 body is length-bound but not byte-pinned
	// here (the runtime-side decode test owns the pixel round-trip).
	DUNGEON_IMAGE_HASH :: "sha256:9091f089c41ac7720fe139b9adfd1b488e7d141a5fc56b9f44b69d50320216d9"
	testing.expect(t, artifact_has_line_prefix(product.artifact, strings.concatenate({"image ", DUNGEON_IMAGE_HASH, " 64 32 b64:"}, context.temp_allocator)))

	// The atlas record is keyed by the manifest HANDLE name `dungeon_atlas` (v17 —
	// the name a `Draw_Sprite{atlas: assets.dungeon_atlas, cell}` references), NOT the
	// .atlas-file-declared `DungeonAtlas`, references the image by hash, and declares
	// its 8 cell regions.
	testing.expect(t, artifact_has_line(product.artifact, strings.concatenate({"atlas dungeon_atlas ", DUNGEON_IMAGE_HASH, " 8"}, context.temp_allocator)))

	// The cell rects: the §19 grid-coord×cell-size lowering (px = grid_coord *
	// 16, w/h = 16). Row 0 is terrain (y=0), row 1 the actors/props (y=16).
	testing.expect(t, artifact_has_line(product.artifact, "region floor 0 0 16 16"))
	testing.expect(t, artifact_has_line(product.artifact, "region wall 16 0 16 16"))
	testing.expect(t, artifact_has_line(product.artifact, "region rubble 48 0 16 16"))
	testing.expect(t, artifact_has_line(product.artifact, "region hero 0 16 16 16"))
	testing.expect(t, artifact_has_line(product.artifact, "region chest_open 48 16 16 16"))

	// Determinism (§29): two builds emit byte-identical assets (and the whole
	// artifact), so the base64 pixel token carries no host nondeterminism.
	second, second_verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, second_verdict.err, Build_Error.None)
	testing.expect(t, product.artifact == second.artifact)
	log.infof("golden dungeon assets: the [assets] section carries 1 deduped image (64×32 RGBA8, base64) + the DungeonAtlas with 8 cell rects, round-trips through parse_artifact, double-build byte-identical")
}

// ── Dungeon: the v15 cross-module declaration carry ─────────────────────────

@(test)
test_golden_dungeon_artifact_carries_imported_schema :: proc(t: ^testing.T) {
	// AC (v15 declaration carry): the live dungeon artifact carries the
	// IMPORTED dungeon_world schema the entrypoint module references — without
	// the carry [things]/[signals] were 0 and [enums] held only the
	// entrypoint's Act, so the runtime could neither spawn nor default a single
	// dungeon row. Exact counts (the golden-count discipline — never a range):
	// [enums 2] = the entrypoint's Act (Button) + the imported Dir; [signals 1]
	// = Looted; [things 3] = Player/Slime/Chest, each with its COMPLETE
	// defaulted field schema (the §6 lines pinned below — the defaults the
	// level-backed [setup] omission rule resolves against); [data 0] — the
	// seam's `data Dungeon` symbol table is NOT imported (its consumer is the
	// deferred level-accessor extern), so the import-closure rule keeps it out.
	dir := resolve_dungeon_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden dungeon carry: %s not found — set FUNPACK_DUNGEON_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	product, verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	doc, parse_err := parse_artifact(product.artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)

	enums, enums_found := artifact_find_section(doc, "enums")
	testing.expect(t, enums_found)
	testing.expect_value(t, enums.count, 2)
	testing.expect(t, artifact_has_line(product.artifact, "enum Act Button 5"))
	testing.expect(t, artifact_has_line(product.artifact, "enum Dir - 4"))

	signals, signals_found := artifact_find_section(doc, "signals")
	testing.expect(t, signals_found)
	testing.expect_value(t, signals.count, 1)
	testing.expect(t, artifact_has_line(product.artifact, "signal Looted 1"))
	testing.expect(t, artifact_has_line(product.artifact, "field gems Int -"))

	things, things_found := artifact_find_section(doc, "things")
	testing.expect(t, things_found)
	testing.expect_value(t, things.count, 3)
	testing.expect(t, artifact_has_line(product.artifact, "thing Player false 1 3"))
	testing.expect(t, artifact_has_line(product.artifact, "field dir Dir =Dir::Down"))
	testing.expect(t, artifact_has_line(product.artifact, "field gems Int =0"))
	testing.expect(t, artifact_has_line(product.artifact, "thing Slime false 1 2"))
	testing.expect(t, artifact_has_line(product.artifact, "field rest Fixed =0"))
	testing.expect(t, artifact_has_line(product.artifact, "thing Chest false 1 3"))
	testing.expect(t, artifact_has_line(product.artifact, "field gems Int =1"))
	testing.expect(t, artifact_has_line(product.artifact, "field opened Bool =false"))

	data, data_found := artifact_find_section(doc, "data")
	testing.expect(t, data_found)
	testing.expect_value(t, data.count, 0)
	log.infof("golden dungeon carry: the imported dungeon_world schema (3 things, Dir, Looted) rides the v15 artifact")
}

@(test)
test_golden_dungeon_setup_folds_level_batch :: proc(t: ^testing.T) {
	// AC (v15 level-backed [setup] fold): dungeon's `setup() { return
	// dungeon_spawns() }` folds the §17 bake's deterministic spawn list into
	// concrete §13 rows — the prior emitter left `[setup 0]`, violating §13's
	// "the runtime spawns the initial population without interpreting an
	// initializer". The 4 rows in BAKE order (markers row-major, then the
	// placed chest): the named P marker at cell (2,2) → center (40, 104), the
	// anonymous g markers at (11,2) → (184, 104) and (3,6) → (56, 40), then
	// `place Chest … { gems: 5 } at cell(13, 4)` → (216, 72) — every center
	// computed from dungeon.flvl (bounds (0,0)(256,144), cell 16, y-down rows
	// from the top edge), never read back from the emitter. gems encodes by
	// its DECLARED Int type (`=5`, not raw Q32.32 bits). The imported `terrain`
	// const reaches [functions] as a v15 carried const record with the SEAM
	// module's span (dungeon.gen.fun line 7), so the behaviors' bare-name
	// terrain reads resolve. The v17 textured-render whole-module carry adds the
	// `dungeon_atlas` AtlasHandle const the draw behaviors reach through `import
	// assets` then `assets.dungeon_atlas` — carried from the assets seam (line 8)
	// with the §26 AtlasHandle KIND read from its declared type, and the body refs
	// lowered to bare `dungeon_atlas` — so [functions 18] = the 16 own records + the
	// terrain carry + the dungeon_atlas carry.
	dir := resolve_dungeon_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden dungeon setup fold: %s not found — set FUNPACK_DUNGEON_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	product, verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	doc, parse_err := parse_artifact(product.artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)

	setup, setup_found := artifact_find_section(doc, "setup")
	testing.expect(t, setup_found)
	testing.expect_value(t, setup.count, 4)
	expected_setup :=
		"[setup 4]\n" +
		"spawn Player 1\n" +
		"set pos =vec2 171798691840 446676598784\n" +
		"spawn Slime 1\n" +
		"set pos =vec2 790273982464 446676598784\n" +
		"spawn Slime 1\n" +
		"set pos =vec2 240518168576 171798691840\n" +
		"spawn Chest 2\n" +
		"set pos =vec2 927712935936 309237645312\n" +
		"set gems =5\n"
	testing.expect(t, strings.contains(product.artifact, expected_setup))

	functions, functions_found := artifact_find_section(doc, "functions")
	testing.expect(t, functions_found)
	testing.expect_value(t, functions.count, 18)
	terrain_const :=
		"function terrain const 0 return:TilemapHandle 1 span:dungeon:7\n" +
		"node return 1\n" +
		"node record TilemapHandle 1 1\n" +
		"node recfield name 1\n" +
		"node string L7:terrain 0\n"
	testing.expect(t, strings.contains(product.artifact, terrain_const))
	// The v17 whole-module carry: the `dungeon_atlas` AtlasHandle const the draw
	// behaviors reach through `import assets`, carried with the §26 AtlasHandle KIND
	// (read from the seam's declared type, NOT hardcoded) and the assets seam's span
	// (line 8). The body refs are lowered to bare `dungeon_atlas`, so this carried
	// record is what the runtime's bare-name lookup resolves them against.
	dungeon_atlas_const :=
		"function dungeon_atlas const 0 return:AtlasHandle 1 span:assets:8\n" +
		"node return 1\n" +
		"node record AtlasHandle 1 1\n" +
		"node recfield name 1\n" +
		"node string L13:dungeon_atlas 0\n"
	testing.expect(t, strings.contains(product.artifact, dungeon_atlas_const))
	log.infof("golden dungeon setup fold: the 4-row level batch, the carried terrain const, and the v17 dungeon_atlas handle carry ride the artifact")
}

// ── Warren: the seam product ─────────────────────────────────────────────────

@(test)
test_golden_warren_seam_byte_matches :: proc(t: ^testing.T) {
	// AC (seam product): the fresh warren bake reproduces the committed
	// gen/warren.gen.fun — the maze layer constant plus the four row-major
	// named-marker Refs (doe, den, sealed, hob).
	baked, schema_ast, ok := bake_example_level(t, resolve_warren_example_dir(), "warren.flvl", "warren_world.fun", "warren_world", "warren.tiles")
	if !ok {
		return
	}
	seam := level_seam_of_baked(baked, schema_ast, warren_level_seam_docs(), context.temp_allocator)
	expect_committed_bytes(t, resolve_warren_example_dir(), "warren.gen.fun", emit_gen_fun(seam, context.temp_allocator))
}

@(test)
test_golden_warren_assets_seam_byte_matches :: proc(t: ^testing.T) {
	// AC (assets seam): the warren manifest (atlas + tileset) reproduces
	// gen/assets.gen.fun.
	docs := []string{WARREN_ASSETS_ATLAS_DOC, WARREN_ASSETS_TILESET_DOC}
	emitted, ok := emit_example_assets_seam(t, resolve_warren_example_dir(), docs)
	if !ok {
		return
	}
	expect_committed_bytes(t, resolve_warren_example_dir(), "assets.gen.fun", emitted)
}

// ── Warren: compiles minus the engine.nav surface — the precise pin ─────────

@(test)
test_golden_warren_compiles_minus_nav_surface :: proc(t: ^testing.T) {
	// AC (the nav pin, FLIPPED): the whole warren tree now compiles end-to-end —
	// warren_world (Path-defaulted things), the warren seam (maze TilemapHandle +
	// the four Refs), AND warren_game all clear typecheck against the project
	// index. The §12 graph queries that USED to refuse at `nav.los` are admitted
	// in surface.odin (los/reachable → Bool, nearest → Option[Vec2], path →
	// Result) and funpack-evaluated through Nav.of (Nav_Value, the nav-method and
	// Path.advance evaluators), so the chase AI's inline asserts run GREEN.
	//
	// The 25 warren_game inline asserts evaluate in the funpack interpreter —
	// three per `routed`/`drifted`/`replan_due`/`follow` test (12), one for
	// `step_to` and one for `open_burrow` and one for the arrived-rabbit hide (3),
	// two each for `nearest_rabbit`/`stalk dashes`/`bolt runs` (6), and four for
	// the `Nav.fail fails every query coherently` test — path==Result::Err,
	// reachable==false, los==false, nearest==Option::None — the Err-arm fixture
	// twin of Nav.of (4) = 25. The non-behavior modules (warren_world, the gen
	// seams) carry no asserts, so the project-wide sum is exactly 25. A regression
	// that drops one, or a source edit that adds one, moves this number in lockstep
	// — never loosen it to a range.
	dir := resolve_warren_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden warren nav pin: %s not found — set FUNPACK_WARREN_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	sources := project_pipeline_sources(project)
	_, has_world := find_source_module(sources, "warren_world")
	_, has_seam := find_source_module(sources, "warren")
	_, has_game := find_source_module(sources, "warren_game")
	testing.expect(t, has_world)
	testing.expect(t, has_seam)
	testing.expect(t, has_game)

	// The whole-project walk now passes: every module compiles (module_err
	// .None), and the warren_game chase asserts run green at their exact count.
	report := run_project_pipeline(sources)
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden warren nav pin: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}
	testing.expect_value(t, report.passed, 25)
	testing.expect_value(t, report.failed, 0)

	// The build verb emits both products now that the nav surface is admitted:
	// warren is a game (entrypoints.fcfg names WarrenGame), so stage_build emits
	// the runtime artifact AND the Index Contract NDJSON, at the v13 schema (the
	// nav-section bake lands here): the artifact carries ARTIFACT_SCHEMA_VERSION,
	// which the bump auto-follows.
	product, verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		log.errorf("golden warren build: refused (%s)", build_refusal_message(verdict, context.temp_allocator))
		return
	}
	testing.expect(t, len(product.artifact) > 0)
	testing.expect(t, len(product.index) > 0)
	doc, art_parse := parse_artifact(product.artifact)
	testing.expect_value(t, art_parse, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)

	// The v13 [nav] section carries the §12 §1 nav graph baked from the maze
	// layer's solids — "the picture IS the topology" (warren.flvl §1). The 16×12
	// maze has 112 solid '#' walls, leaving 80 walkable cells (floor + the four
	// markers R/F/O/S, which sit on the floor), so NODE_COUNT == 80, and the
	// 4-neighbor orthogonal adjacencies between them number 80 (right+down
	// deduped) — computed from warren.flvl, never guessed. One flat graph
	// (count == 1), keyed to the `maze` tilemap, lead line carrying NO grid
	// metadata (§12 §5 hides the Cell index).
	nav_section, nav_found := artifact_find_section(doc, "nav")
	testing.expect(t, nav_found)
	testing.expect_value(t, nav_section.count, 1)
	testing.expect(t, artifact_has_line(product.artifact, "nav maze 80 80"))

	// The v15 carry + fold over warren: [things 3] = the imported
	// Rabbit/Ferret/Burrow schemas (warren_game imports no enum/signal/const
	// from its siblings — `maze` is not in its import closure, so no const
	// record carries), and [setup 4] = the four named markers in row-major bake
	// order: doe Rabbit at cell (1,1) → center (12, 84), den Burrow at (14,1) →
	// (116, 84), sealed Burrow at (3,9) → (28, 20), hob Ferret at (14,9) →
	// (116, 20) — centers computed from warren.flvl (bounds (0,0)(128,96),
	// cell 8), never read back from the emitter.
	things_section, things_found := artifact_find_section(doc, "things")
	testing.expect(t, things_found)
	testing.expect_value(t, things_section.count, 3)
	testing.expect(t, artifact_has_line(product.artifact, "thing Rabbit false 1 3"))
	testing.expect(t, artifact_has_line(product.artifact, "field path Path =Path(steps=[],cost=0)"))
	testing.expect(t, artifact_has_line(product.artifact, "thing Ferret false 1 3"))
	testing.expect(t, artifact_has_line(product.artifact, "thing Burrow false 1 1"))

	// The carried Rabbit/Ferret `path: Path` fields trigger the synthesized §8
	// Path data projection — [data 1] (warren declares no user `data`), the one
	// decl the runtime resolves the `=Path(steps=[],cost=0)` default's
	// steps/cost types against ([Vec2]/Fixed; untyped tokens without it).
	data_section, data_found := artifact_find_section(doc, "data")
	testing.expect(t, data_found)
	testing.expect_value(t, data_section.count, 1)
	testing.expect(t, artifact_has_line(product.artifact, "data Path 2 false"))
	testing.expect(t, artifact_has_line(product.artifact, "field steps [Vec2] -"))
	testing.expect(t, artifact_has_line(product.artifact, "field cost Fixed -"))
	setup_section, setup_found := artifact_find_section(doc, "setup")
	testing.expect(t, setup_found)
	testing.expect_value(t, setup_section.count, 4)
	expected_setup :=
		"[setup 4]\n" +
		"spawn Rabbit 1\n" +
		"set pos =vec2 51539607552 360777252864\n" +
		"spawn Burrow 1\n" +
		"set pos =vec2 498216206336 360777252864\n" +
		"spawn Burrow 1\n" +
		"set pos =vec2 120259084288 85899345920\n" +
		"spawn Ferret 1\n" +
		"set pos =vec2 498216206336 85899345920\n"
	testing.expect(t, strings.contains(product.artifact, expected_setup))
	log.infof("golden warren nav pin FLIPPED: the full warren project compiles end-to-end; %d funpack-evaluable chase asserts pass, both build products emit, and the [nav] section carries the 80-node maze graph", report.passed)
}

// test_emit_warren_matches_runtime_testdata is the warren cross-package byte
// seam: the live stage_build artifact equals the committed
// runtime/testdata/warren.artifact the runtime nav golden #loads, byte-for-byte
// (the krognid/statequery seam mold). FUNPACK_REGEN_GOLDEN=1 REWRITES the
// committed copy from the live build — checked BEFORE the staged-bump skip, so
// a regen run can bootstrap the copy across a schema bump. Without regen, a
// committed copy stamped behind
// ARTIFACT_SCHEMA_VERSION SKIPs loudly (a staged schema bump — the runtime-side
// reconcile restores the seam); a SAME-version divergence is the hard failure
// this seam exists to catch.
@(test)
test_emit_warren_matches_runtime_testdata :: proc(t: ^testing.T) {
	dir := resolve_warren_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP warren testdata match: %s not found — ensure the in-repo fixture exists", dir)
		return
	}
	product, verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	committed_path, _ := filepath.join({#directory, "..", "runtime", "testdata", "warren.artifact"}, context.temp_allocator)
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) != "" {
		testing.expect(t, os.write_entire_file(committed_path, transmute([]u8)product.artifact) == nil)
		log.infof("REGEN warren: wrote %s (%d bytes)", committed_path, len(product.artifact))
		return
	}
	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP warren testdata match: committed %s unreadable — regenerate with FUNPACK_REGEN_GOLDEN=1", committed_path)
		return
	}
	committed := string(committed_bytes)
	if _, committed_version, stamp_ok := parse_version_stamp(line_around(committed, 0)); stamp_ok && committed_version < ARTIFACT_SCHEMA_VERSION {
		log.warnf(
			"SKIP warren testdata match: committed runtime copy is stamped v%d while the emitter is at v%d — a staged schema bump; regenerate with FUNPACK_REGEN_GOLDEN=1 or land the runtime-side reconcile",
			committed_version,
			ARTIFACT_SCHEMA_VERSION,
		)
		return
	}
	testing.expect_value(t, len(product.artifact), len(committed))
	testing.expect(t, product.artifact == committed)
	if product.artifact != committed {
		report_first_byte_diff(product.artifact, committed)
		return
	}
	log.infof("emit warren: the live build reproduces the committed runtime/testdata/warren.artifact byte-for-byte (%d bytes)", len(product.artifact))
}

// test_emit_dungeon_matches_runtime_testdata is the dungeon cross-package byte
// seam, the warren seam's twin: the live stage_build artifact equals the
// committed runtime/testdata/dungeon.artifact the runtime's live dungeon
// execution loads, byte-for-byte. FUNPACK_REGEN_GOLDEN=1 REWRITES the committed
// copy from the live build — checked BEFORE the staged-bump skip, so a regen
// run can bootstrap the copy across a schema bump (this seam is BORN staged:
// the v15 emitter lands before the runtime-side reconcile commits the first
// copy, so the unreadable-committed-copy SKIP fires until then — loud, never a
// pass). Without regen, a committed copy stamped behind ARTIFACT_SCHEMA_VERSION
// SKIPs loudly (a staged schema bump); a SAME-version divergence is the hard
// failure this seam exists to catch.
@(test)
test_emit_dungeon_matches_runtime_testdata :: proc(t: ^testing.T) {
	dir := resolve_dungeon_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP dungeon testdata match: %s not found — ensure the in-repo fixture exists", dir)
		return
	}
	product, verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	committed_path, _ := filepath.join({#directory, "..", "runtime", "testdata", "dungeon.artifact"}, context.temp_allocator)
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) != "" {
		testing.expect(t, os.write_entire_file(committed_path, transmute([]u8)product.artifact) == nil)
		log.infof("REGEN dungeon: wrote %s (%d bytes)", committed_path, len(product.artifact))
		return
	}
	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP dungeon testdata match: committed %s unreadable — regenerate with FUNPACK_REGEN_GOLDEN=1", committed_path)
		return
	}
	committed := string(committed_bytes)
	if _, committed_version, stamp_ok := parse_version_stamp(line_around(committed, 0)); stamp_ok && committed_version < ARTIFACT_SCHEMA_VERSION {
		log.warnf(
			"SKIP dungeon testdata match: committed runtime copy is stamped v%d while the emitter is at v%d — a staged schema bump; regenerate with FUNPACK_REGEN_GOLDEN=1 or land the runtime-side reconcile",
			committed_version,
			ARTIFACT_SCHEMA_VERSION,
		)
		return
	}
	testing.expect_value(t, len(product.artifact), len(committed))
	testing.expect(t, product.artifact == committed)
	if product.artifact != committed {
		report_first_byte_diff(product.artifact, committed)
		return
	}
	log.infof("emit dungeon: the live build reproduces the committed runtime/testdata/dungeon.artifact byte-for-byte (%d bytes)", len(product.artifact))
}
