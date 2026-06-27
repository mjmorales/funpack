package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

ARENA_FILE_DOC :: "Generated seam for levels/arena.flvl: typed references to the level's named instances and the deterministic spawn list, baked from the flat-text level. Imports the schema module only. Edit the level, not this file."
ARENA_PREFAB_DOC :: "A placed Turret prefab instance: typed references to its expanded members. Generated from the prefab in arena.flvl."
ARENA_SYMBOLS_DOC :: "Typed references to the Arena level's named instances. Ids are derived from the level-qualified names, so these are stable across loads, saves, and replays. Generated from arena.flvl — edit the level, not this file."
ARENA_SPAWNS_DOC :: "The deterministic spawn list for Arena, in declaration order (the prefab and the pillar loop expanded in place). Backed by arena.flvl."
ARENA_ACCESSOR_DOC :: "The Arena symbol table, valid once the level is loaded."

arena_seam_docs :: proc() -> Level_Seam_Docs {
	return Level_Seam_Docs {
		file     = ARENA_FILE_DOC,
		prefab   = ARENA_PREFAB_DOC,
		symbols  = ARENA_SYMBOLS_DOC,
		spawns   = ARENA_SPAWNS_DOC,
		accessor = ARENA_ACCESSOR_DOC,
	}
}

arena_fresh_bake :: proc(t: ^testing.T, allocator := context.allocator) -> (seam: Seam, ok: bool) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden arena: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return Seam{}, false
	}
	level_path := filepath.join({dir, "levels", "arena.flvl"}, context.temp_allocator) or_else ""
	schema_path := filepath.join({dir, "src", "arena_world.fun"}, context.temp_allocator) or_else ""
	level_bytes, level_read := os.read_entire_file_from_path(level_path, context.temp_allocator)
	schema_bytes, schema_read := os.read_entire_file_from_path(schema_path, context.temp_allocator)
	if level_read != nil || schema_read != nil {
		log.warnf("SKIP golden arena: cannot read arena.flvl / arena_world.fun under %s", dir)
		return Seam{}, false
	}

	level, level_parse := parse_flvl(string(level_bytes))
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	schema_ast, schema_parse := stage_parse(stage_lex(string(schema_bytes)))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	if level_parse != .None || schema_parse != .None {
		return Seam{}, false
	}

	index := build_module_index_from_asts({"arena_world"}, {schema_ast})
	baked, bake_err := bake_flvl(level, schema_ast, "arena_world", index)
	testing.expect_value(t, bake_err, Bake_Error.None)
	if bake_err != .None {
		return Seam{}, false
	}
	return level_seam_of_baked(baked, schema_ast, arena_seam_docs(), allocator), true
}

@(test)
test_golden_arena_gen_fun_byte_matches :: proc(t: ^testing.T) {
	committed_path, path_ok := arena_committed_seam_path(t)
	if !path_ok {
		return
	}
	seam, bake_ok := arena_fresh_bake(t, context.temp_allocator)
	if !bake_ok {
		return
	}
	emitted := emit_gen_fun(seam, context.temp_allocator)

	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP golden arena: committed seam %s unreadable", committed_path)
		return
	}
	committed := string(committed_bytes)

	testing.expect_value(t, len(emitted), len(committed))
	testing.expect(t, emitted == committed)
	if emitted != committed {
		report_first_byte_diff(emitted, committed)
		return
	}
	log.infof("golden arena: freshly-baked levels/arena.flvl reproduces gen/arena.gen.fun byte-for-byte (%d bytes)", len(emitted))
}

@(test)
test_golden_arena_double_bake_identical :: proc(t: ^testing.T) {
	first, ok1 := arena_fresh_bake(t, context.temp_allocator)
	if !ok1 {
		return
	}
	second, ok2 := arena_fresh_bake(t, context.temp_allocator)
	if !ok2 {
		return
	}
	first_bytes := emit_gen_fun(first, context.temp_allocator)
	second_bytes := emit_gen_fun(second, context.temp_allocator)
	testing.expect(t, first_bytes == second_bytes)
	testing.expect_value(t, len(first_bytes), len(second_bytes))
	if first_bytes == second_bytes {
		log.infof("golden arena: two arena.flvl bakes are byte-identical (deterministic bake+emit, %d bytes)", len(first_bytes))
	}
}

@(test)
test_golden_arena_seam_compare_none :: proc(t: ^testing.T) {
	committed_path, path_ok := arena_committed_seam_path(t)
	if !path_ok {
		return
	}
	seam, bake_ok := arena_fresh_bake(t, context.temp_allocator)
	if !bake_ok {
		return
	}
	emitted := emit_gen_fun(seam, context.temp_allocator)
	result := compare_seam(emitted, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.None)
	if result != .None {
		committed_bytes, cerr := os.read_entire_file_from_path(committed_path, context.temp_allocator)
		if cerr == nil {
			report_first_byte_diff(emitted, string(committed_bytes))
		}
	}
}

@(test)
test_golden_arena_project_typechecks :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden arena: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	_, has_world := find_source_module(project.sources, "arena_world")
	_, has_seam := find_source_module(project.sources, "arena")
	_, has_game := find_source_module(project.sources, "arena_game")
	testing.expect(t, has_world)
	testing.expect(t, has_seam)
	testing.expect(t, has_game)

	report := run_project_pipeline(project.sources)
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden arena: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}
	log.infof("golden arena: the full arena project (arena_world + arena seam + arena_game) types and clears the compile pipeline end-to-end")
}

@(test)
test_golden_arena_inline_tests_pass :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden arena: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	report := run_project_pipeline(project.sources)
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		return
	}

	testing.expect_value(t, report.passed, 8)
	log.infof(
		"golden arena: project compiles end-to-end; all %d inline asserts pass in the funpack evaluator (View.ref/resolve is now funpack-evaluable)",
		report.passed,
	)
}
