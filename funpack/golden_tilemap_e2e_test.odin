package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

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

@(test)
test_golden_dungeon_seam_byte_matches :: proc(t: ^testing.T) {
	baked, schema_ast, ok := bake_example_level(t, resolve_dungeon_example_dir(), "dungeon.flvl", "dungeon_world.fun", "dungeon_world", "dungeon.tiles")
	if !ok {
		return
	}
	seam := level_seam_of_baked(baked, schema_ast, dungeon_level_seam_docs(), context.temp_allocator)
	expect_committed_bytes(t, resolve_dungeon_example_dir(), "dungeon.gen.fun", emit_gen_fun(seam, context.temp_allocator))
}

@(test)
test_golden_dungeon_assets_seam_byte_matches :: proc(t: ^testing.T) {
	docs := []string{DUNGEON_ASSETS_ATLAS_DOC, DUNGEON_ASSETS_TILESET_DOC}
	emitted, ok := emit_example_assets_seam(t, resolve_dungeon_example_dir(), docs)
	if !ok {
		return
	}
	expect_committed_bytes(t, resolve_dungeon_example_dir(), "assets.gen.fun", emitted)
}

@(test)
test_golden_dungeon_project_compiles_and_inline_tests_pass :: proc(t: ^testing.T) {
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

@(test)
test_golden_dungeon_build_carries_tile_layer_in_both_products :: proc(t: ^testing.T) {
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
	testing.expect(t, artifact_has_line(product.artifact, "tile wall true 1 0"))
	testing.expect(t, artifact_has_line(product.artifact, "tile rubble true 3 0"))

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

@(test)
test_golden_dungeon_build_carries_populated_assets_section :: proc(t: ^testing.T) {
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

	assets_section, assets_found := artifact_find_section(doc, "assets")
	testing.expect(t, assets_found)
	testing.expect_value(t, assets_section.count, 2)
	testing.expect_value(t, assets_section.name, "assets")

	DUNGEON_IMAGE_HASH :: "sha256:9091f089c41ac7720fe139b9adfd1b488e7d141a5fc56b9f44b69d50320216d9"
	testing.expect(t, artifact_has_line_prefix(product.artifact, strings.concatenate({"image ", DUNGEON_IMAGE_HASH, " 64 32 b64:"}, context.temp_allocator)))

	testing.expect(t, artifact_has_line(product.artifact, strings.concatenate({"atlas dungeon_atlas ", DUNGEON_IMAGE_HASH, " 8"}, context.temp_allocator)))

	testing.expect(t, artifact_has_line(product.artifact, "region floor 0 0 16 16"))
	testing.expect(t, artifact_has_line(product.artifact, "region wall 16 0 16 16"))
	testing.expect(t, artifact_has_line(product.artifact, "region rubble 48 0 16 16"))
	testing.expect(t, artifact_has_line(product.artifact, "region hero 0 16 16 16"))
	testing.expect(t, artifact_has_line(product.artifact, "region chest_open 48 16 16 16"))

	second, second_verdict := stage_build(dir, .Dev, context.temp_allocator)
	testing.expect_value(t, second_verdict.err, Build_Error.None)
	testing.expect(t, product.artifact == second.artifact)
	log.infof("golden dungeon assets: the [assets] section carries 1 deduped image (64×32 RGBA8, base64) + the DungeonAtlas with 8 cell rects, round-trips through parse_artifact, double-build byte-identical")
}

@(test)
test_golden_dungeon_artifact_carries_imported_schema :: proc(t: ^testing.T) {
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
	dungeon_atlas_const :=
		"function dungeon_atlas const 0 return:AtlasHandle 1 span:assets:8\n" +
		"node return 1\n" +
		"node record AtlasHandle 1 1\n" +
		"node recfield name 1\n" +
		"node string L13:dungeon_atlas 0\n"
	testing.expect(t, strings.contains(product.artifact, dungeon_atlas_const))
	log.infof("golden dungeon setup fold: the 4-row level batch, the carried terrain const, and the v17 dungeon_atlas handle carry ride the artifact")
}

@(test)
test_golden_warren_seam_byte_matches :: proc(t: ^testing.T) {
	baked, schema_ast, ok := bake_example_level(t, resolve_warren_example_dir(), "warren.flvl", "warren_world.fun", "warren_world", "warren.tiles")
	if !ok {
		return
	}
	seam := level_seam_of_baked(baked, schema_ast, warren_level_seam_docs(), context.temp_allocator)
	expect_committed_bytes(t, resolve_warren_example_dir(), "warren.gen.fun", emit_gen_fun(seam, context.temp_allocator))
}

@(test)
test_golden_warren_assets_seam_byte_matches :: proc(t: ^testing.T) {
	docs := []string{WARREN_ASSETS_ATLAS_DOC, WARREN_ASSETS_TILESET_DOC}
	emitted, ok := emit_example_assets_seam(t, resolve_warren_example_dir(), docs)
	if !ok {
		return
	}
	expect_committed_bytes(t, resolve_warren_example_dir(), "assets.gen.fun", emitted)
}

@(test)
test_golden_warren_compiles_minus_nav_surface :: proc(t: ^testing.T) {
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

	report := run_project_pipeline(sources)
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden warren nav pin: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}
	testing.expect_value(t, report.passed, 25)
	testing.expect_value(t, report.failed, 0)

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

	nav_section, nav_found := artifact_find_section(doc, "nav")
	testing.expect(t, nav_found)
	testing.expect_value(t, nav_section.count, 1)
	testing.expect(t, artifact_has_line(product.artifact, "nav maze 80 80"))

	things_section, things_found := artifact_find_section(doc, "things")
	testing.expect(t, things_found)
	testing.expect_value(t, things_section.count, 3)
	testing.expect(t, artifact_has_line(product.artifact, "thing Rabbit false 1 3"))
	testing.expect(t, artifact_has_line(product.artifact, "field path Path =Path(steps=[],cost=0)"))
	testing.expect(t, artifact_has_line(product.artifact, "thing Ferret false 1 3"))
	testing.expect(t, artifact_has_line(product.artifact, "thing Burrow false 1 1"))

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
