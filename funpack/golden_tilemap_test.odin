package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

DUNGEON_EXAMPLE_DEFAULT_DIR :: "examples/dungeon"
WARREN_EXAMPLE_DEFAULT_DIR :: "examples/warren"

resolve_dungeon_example_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_DUNGEON_DIR", DUNGEON_EXAMPLE_DEFAULT_DIR)
}

resolve_warren_example_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_WARREN_DIR", WARREN_EXAMPLE_DEFAULT_DIR)
}

tilemap_golden_source :: proc(dir: string, segments: []string) -> (content: string, ok: bool) {
	if !os.is_dir(dir) {
		log.warnf("SKIP golden tilemap: %s not found — set FUNPACK_DUNGEON_DIR/FUNPACK_WARREN_DIR or ensure the in-repo fixture exists", dir)
		return "", false
	}
	parts := make([]string, len(segments) + 1, context.temp_allocator)
	parts[0] = dir
	copy(parts[1:], segments)
	path, _ := filepath.join(parts, context.temp_allocator)
	bytes, file_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if file_err != nil {
		log.warnf("SKIP golden tilemap: %s unreadable", path)
		return "", false
	}
	return string(bytes), true
}

bake_example_level :: proc(t: ^testing.T, dir: string, level_file, schema_file, schema_module, tiles_file: string) -> (baked: Baked_Level, schema_ast: Ast, ok: bool) {
	level_src, level_ok := tilemap_golden_source(dir, {"levels", level_file})
	schema_src, schema_ok := tilemap_golden_source(dir, {"src", schema_file})
	tiles_src, tiles_ok := tilemap_golden_source(dir, {"assets", tiles_file})
	if !level_ok || !schema_ok || !tiles_ok {
		return Baked_Level{}, Ast{}, false
	}

	level, level_parse := parse_flvl(level_src)
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	parsed_schema, schema_parse := stage_parse(stage_lex(schema_src))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	if level_parse != .None || schema_parse != .None {
		return Baked_Level{}, Ast{}, false
	}

	tileset, import_err := import_tileset(tiles_src, []string{"atlas@sha256:0"})
	testing.expect_value(t, import_err, Importer_Error.None)
	tilesets := make([]Tileset_Asset, 1, context.temp_allocator)
	tilesets[0] = tileset
	table, table_err := flvl_project_tile_table(tilesets, context.temp_allocator)
	testing.expect_value(t, table_err, Bake_Error.None)

	index := build_module_index_from_asts({schema_module}, {parsed_schema})
	baked_level, bake_err := bake_flvl(level, parsed_schema, schema_module, index, table)
	testing.expect_value(t, bake_err, Bake_Error.None)
	if bake_err != .None {
		return Baked_Level{}, Ast{}, false
	}
	return baked_level, parsed_schema, true
}

@(test)
test_golden_dungeon_tilemap_bakes :: proc(t: ^testing.T) {
	baked, _, ok := bake_example_level(t, resolve_dungeon_example_dir(), "dungeon.flvl", "dungeon_world.fun", "dungeon_world", "dungeon.tiles")
	if !ok {
		return
	}
	testing.expect_value(t, baked.level_name, "Dungeon")

	testing.expect_value(t, len(baked.tile_layers), 1)
	layer := baked.tile_layers[0]
	testing.expect_value(t, layer.name, "terrain")
	testing.expect_value(t, layer.cell_size, 16)
	testing.expect_value(t, layer.cols, 16)
	testing.expect_value(t, layer.rows, 9)
	testing.expect_value(t, len(layer.palette), 4)
	testing.expect_value(t, layer.palette[0].name, "wall")
	testing.expect_value(t, layer.palette[0].solid, true)
	testing.expect_value(t, layer.palette[1].name, "floor")
	testing.expect_value(t, layer.palette[1].solid, false)
	testing.expect_value(t, layer.palette[2].name, "water")
	testing.expect_value(t, layer.palette[2].solid, false)
	testing.expect_value(t, layer.palette[3].name, "rubble")
	testing.expect_value(t, layer.palette[3].solid, true)

	testing.expect_value(t, len(layer.cells), 144)
	testing.expect_value(t, layer.cells[0], 0)
	testing.expect_value(t, layer.cells[1*16+1], 1)
	testing.expect_value(t, layer.cells[3*16+3], 2)
	testing.expect_value(t, layer.cells[3*16+7], 3)
	testing.expect_value(t, layer.cells[4*16+10], TILE_LAYER_EMPTY_CELL)
	testing.expect_value(t, layer.cells[2*16+2], TILE_LAYER_EMPTY_CELL)

	testing.expect_value(t, len(baked.spawns), 4)
	testing.expect_value(t, baked.spawns[0].thing_type, "Player")
	testing.expect_value(t, baked.spawns[1].thing_type, "Slime")
	testing.expect_value(t, baked.spawns[2].thing_type, "Slime")
	testing.expect_value(t, baked.spawns[3].thing_type, "Chest")

	testing.expect_value(t, baked.spawns[0].pos.x, to_fixed(40))
	testing.expect_value(t, baked.spawns[0].pos.y, to_fixed(104))
	testing.expect_value(t, baked.spawns[3].pos.x, to_fixed(216))
	testing.expect_value(t, baked.spawns[3].pos.y, to_fixed(72))

	gems, has_gems := find_baked_param(baked.spawns[3].params, "gems")
	testing.expect(t, has_gems)
	testing.expect_value(t, gems.value, to_fixed(5))
	testing.expect_value(t, len(baked.refs), 2)
	testing.expect_value(t, baked.refs[0].name, "Dungeon.hero")
	testing.expect_value(t, baked.refs[1].name, "Dungeon.loot")
	testing.expect_value(t, len(baked.symbols), 2)
}

@(test)
test_golden_warren_tilemap_bakes :: proc(t: ^testing.T) {
	baked, _, ok := bake_example_level(t, resolve_warren_example_dir(), "warren.flvl", "warren_world.fun", "warren_world", "warren.tiles")
	if !ok {
		return
	}
	testing.expect_value(t, baked.level_name, "Warren")

	testing.expect_value(t, len(baked.tile_layers), 1)
	layer := baked.tile_layers[0]
	testing.expect_value(t, layer.name, "maze")
	testing.expect_value(t, layer.cell_size, 8)
	testing.expect_value(t, layer.cols, 16)
	testing.expect_value(t, layer.rows, 12)
	testing.expect_value(t, len(layer.palette), 2)
	testing.expect_value(t, layer.palette[0].name, "wall")
	testing.expect_value(t, layer.palette[1].name, "floor")

	testing.expect_value(t, len(baked.spawns), 4)
	testing.expect_value(t, baked.spawns[0].thing_type, "Rabbit")
	testing.expect_value(t, baked.spawns[1].thing_type, "Burrow")
	testing.expect_value(t, baked.spawns[2].thing_type, "Burrow")
	testing.expect_value(t, baked.spawns[3].thing_type, "Ferret")
	testing.expect_value(t, len(baked.refs), 4)
	testing.expect_value(t, baked.refs[0].name, "Warren.doe")
	testing.expect_value(t, baked.refs[1].name, "Warren.den")
	testing.expect_value(t, baked.refs[2].name, "Warren.sealed")
	testing.expect_value(t, baked.refs[3].name, "Warren.hob")
	testing.expect_value(t, len(baked.symbols), 4)

	testing.expect_value(t, baked.spawns[0].pos.x, to_fixed(12))
	testing.expect_value(t, baked.spawns[0].pos.y, to_fixed(84))
}

TILEMAP_SEAM_EXPECTED :: "@doc(\"FILE\")\n" +
	"import engine.world.{Spawn, Ref}\n" +
	"import engine.tilemap.{TilemapHandle}\n" +
	"import arena_world.{Player, Switch, Pillar}\n" +
	"\n" +
	"@doc(\"LAYER\")\n" +
	"let terrain: TilemapHandle = TilemapHandle{name: \"terrain\"}\n" +
	"\n" +
	"@doc(\"SYMBOLS\")\n" +
	"data Arena {\n" +
	"  hero:  Ref[Player]\n" +
	"  plate: Ref[Switch]\n" +
	"}\n" +
	"\n" +
	"@doc(\"SPAWNS\")\n" +
	"extern fn arena_spawns() -> [Spawn]\n" +
	"\n" +
	"@doc(\"ACCESSOR\")\n" +
	"extern fn arena() -> Arena\n"

tilemap_seam_fixture :: proc(t: ^testing.T) -> (seam: Seam, schema_ast: Ast, ok: bool) {
	parsed_schema, schema_parse := stage_parse(stage_lex(SCHEMA_SOURCE))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	level, level_parse := parse_flvl(TILEMAP_LEVEL)
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	index := build_module_index_from_asts({"arena_world"}, {parsed_schema})
	baked, bake_err := bake_flvl(level, parsed_schema, "arena_world", index, tile_table_fixture(t))
	testing.expect_value(t, bake_err, Bake_Error.None)
	if schema_parse != .None || level_parse != .None || bake_err != .None {
		return Seam{}, Ast{}, false
	}
	docs := Level_Seam_Docs {
		file     = "FILE",
		symbols  = "SYMBOLS",
		spawns   = "SPAWNS",
		accessor = "ACCESSOR",
		tilemap  = "LAYER",
	}
	return level_seam_of_baked(baked, parsed_schema, docs, context.temp_allocator), parsed_schema, true
}

@(test)
test_tilemap_seam_byte_contract :: proc(t: ^testing.T) {
	seam, _, ok := tilemap_seam_fixture(t)
	if !ok {
		return
	}
	emitted := emit_gen_fun(seam, context.temp_allocator)
	testing.expect_value(t, len(emitted), len(TILEMAP_SEAM_EXPECTED))
	testing.expect(t, emitted == TILEMAP_SEAM_EXPECTED)
	if emitted != TILEMAP_SEAM_EXPECTED {
		report_first_byte_diff(emitted, TILEMAP_SEAM_EXPECTED)
	}
}

@(test)
test_tilemap_seam_reingests_and_typechecks :: proc(t: ^testing.T) {
	seam, schema_ast, ok := tilemap_seam_fixture(t)
	if !ok {
		return
	}
	emitted := emit_gen_fun(seam, context.temp_allocator)
	seam_ast, parse_err := stage_parse(stage_lex(emitted))
	testing.expect_value(t, parse_err, Parse_Error.None)
	index := build_module_index_from_asts({"arena_world"}, {schema_ast})
	_, type_err := stage_typecheck_indexed(seam_ast, index)
	testing.expect_value(t, type_err, Type_Error.None)
}

@(test)
test_tilemap_seam_double_projection_identical :: proc(t: ^testing.T) {
	first, _, ok1 := tilemap_seam_fixture(t)
	if !ok1 {
		return
	}
	second, _, ok2 := tilemap_seam_fixture(t)
	if !ok2 {
		return
	}
	testing.expect(t, emit_gen_fun(first, context.temp_allocator) == emit_gen_fun(second, context.temp_allocator))
}

@(test)
test_layerless_seam_imports_unchanged :: proc(t: ^testing.T) {
	parsed_schema, schema_parse := stage_parse(stage_lex(SCHEMA_SOURCE))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	level, level_parse := parse_flvl(CLEAN_LEVEL)
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	index := build_module_index_from_asts({"arena_world"}, {parsed_schema})
	baked, bake_err := bake_flvl(level, parsed_schema, "arena_world", index)
	testing.expect_value(t, bake_err, Bake_Error.None)
	seam := level_seam_of_baked(baked, parsed_schema, Level_Seam_Docs{}, context.temp_allocator)
	testing.expect_value(t, len(seam.imports), 2)
	testing.expect_value(t, seam.imports[0].path, "engine.world")
	testing.expect_value(t, seam.imports[1].path, "arena_world")
}
