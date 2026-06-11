// The tilemaps-tiles capstone goldens over the LIVE dungeon/warren corpus
// (funpack-spec/examples/dungeon, examples/warren): the §18 §3 tile layer in
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
//   WARREN — compiles through the same pipeline MINUS the engine.nav QUERY
//   surface (the navigation milestone's — deliberately NOT admitted here):
//     4. SEAM BYTE MATCH — gen/warren.gen.fun and gen/assets.gen.fun, same
//        contract as the dungeon's.
//     5. THE PRECISE NAV PIN — warren_world and the warren seam typecheck
//        clean, and warren_game refuses at EXACTLY the first §12 graph query
//        (`nav.los`, an unadmitted method on the Nav receiver →
//        Unsupported_Expr). The navigation milestone flips exactly this pin to
//        .None; stage_build refuses the whole tree (Compile_Failed, exit-2
//        class, no product) until it does.
//
// All tests resolve the sibling funpack-spec checkout and SKIP LOUDLY when it
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
		log.warnf("SKIP golden dungeon e2e: %s not found — set FUNPACK_DUNGEON_DIR or check out funpack-spec as a sibling of the repo", dir)
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
	// products — the v12 artifact whose [tilemaps] section carries the terrain
	// layer with its anchor lead line (`tilemap terrain 16 16 9 0
	// 618475290624 4`: cell 16, 16×9, anchored at the level bounds' top-left
	// (0, 144·2^32), four palette entries), and the Index Contract NDJSON.
	// Emission is deterministic: two builds of the same tree are
	// byte-identical (§29).
	dir := resolve_dungeon_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden dungeon build: %s not found — set FUNPACK_DUNGEON_DIR or check out funpack-spec as a sibling of the repo", dir)
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
	testing.expect(t, artifact_has_line(product.artifact, "tilemap terrain 16 16 9 0 618475290624 4"))
	testing.expect(t, artifact_has_line(product.artifact, "tile wall true"))
	testing.expect(t, artifact_has_line(product.artifact, "tile rubble true"))

	second, second_verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, second_verdict.err, Build_Error.None)
	testing.expect(t, product.artifact == second.artifact)
	testing.expect(t, product.index == second.index)
	log.infof("golden dungeon build: both products emit, the artifact carries the anchored terrain layer (%d bytes), double-build byte-identical", len(product.artifact))
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
	// AC (the nav pin): everything in the warren tree EXCEPT the §12 graph
	// queries compiles — warren_world (Path-defaulted things) and the warren
	// seam (maze TilemapHandle + the four Refs) both clear typecheck against
	// the project index — and warren_game refuses at EXACTLY the first
	// unadmitted Nav query (`nav.los(self.pos, goal)` in `stalk`): an unknown
	// method on the Nav engine receiver is Unsupported_Expr, the same closed-
	// table verdict the tilemap fixture pins for `map.warp`. The NAVIGATION
	// MILESTONE flips exactly this expectation to Type_Error.None when it
	// admits los/nearest/reachable — nothing else in this tree stands between
	// warren and green.
	dir := resolve_warren_example_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden warren nav pin: %s not found — set FUNPACK_WARREN_DIR or check out funpack-spec as a sibling of the repo", dir)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	// The project index types every module's exports; the two non-behavior
	// modules clear their whole pipeline against it.
	sources := project_pipeline_sources(project)
	index := build_project_module_index(sources)
	for module in ([]string{"warren_world", "warren"}) {
		source, has_module := find_source_module(sources, module)
		testing.expect(t, has_module)
		if !has_module {
			continue
		}
		bytes, file_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		testing.expect(t, file_err == nil)
		if file_err != nil {
			continue
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		testing.expect_value(t, parse_err, Parse_Error.None)
		_, type_err := stage_typecheck_indexed(ast, index)
		testing.expect_value(t, type_err, Type_Error.None)
	}

	// The behavior module refuses at the nav query — THE pin.
	game, has_game := find_source_module(sources, "warren_game")
	testing.expect(t, has_game)
	if !has_game {
		return
	}
	game_bytes, game_err := os.read_entire_file_from_path(game.path, context.temp_allocator)
	testing.expect(t, game_err == nil)
	if game_err != nil {
		return
	}
	game_ast, game_parse := stage_parse(stage_lex(string(game_bytes)))
	testing.expect_value(t, game_parse, Parse_Error.None)
	_, nav_refusal := stage_typecheck_indexed(game_ast, index)
	testing.expect_value(t, nav_refusal, Type_Error.Unsupported_Expr)

	// And the whole-project walk surfaces the same refusal as the §29 §3
	// exit-2 compile-error class on warren_game — never a counted failure.
	report := run_project_pipeline(sources)
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.Typecheck_Failed)
	testing.expect(t, strings.has_suffix(report.failed_path, "warren_game.fun"))

	// The build verb honors it: no product until the navigation milestone
	// admits the surface.
	_, verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Compile_Failed)
	log.infof("golden warren nav pin: warren_world + the warren seam compile; warren_game refuses at the unadmitted nav query (Unsupported_Expr) — the navigation milestone flips exactly this pin")
}
