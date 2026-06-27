package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_derive_seam_module_name_flat :: proc(t: ^testing.T) {
	module := derive_seam_module_name("/proj/gen", "/proj/gen/arena.gen.fun")
	testing.expect_value(t, module, "arena")
}

@(test)
test_derive_seam_module_name_nested :: proc(t: ^testing.T) {
	module := derive_seam_module_name("/proj/gen", "/proj/gen/town/market.gen.fun")
	testing.expect_value(t, module, "town.market")
}

@(test)
test_merge_sources_combines_and_sorts :: proc(t: ^testing.T) {
	src := []Source{{path = "/p/src/arena_world.fun", module = "arena_world"}}
	seam := []Source{{path = "/p/gen/arena.gen.fun", module = "arena"}}
	merged, err, _ := merge_sources(src, seam)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(merged), 2)
	if len(merged) == 2 {
		testing.expect_value(t, merged[0].module, "arena")
		testing.expect_value(t, merged[1].module, "arena_world")
	}
}

@(test)
test_merge_sources_cross_set_duplicate_module_rejected :: proc(t: ^testing.T) {
	src := []Source{{path = "/p/src/arena.fun", module = "arena"}}
	seam := []Source{{path = "/p/gen/arena.gen.fun", module = "arena"}}
	_, err, _ := merge_sources(src, seam)
	testing.expect_value(t, err, Project_Error.Duplicate_Module)
}

@(test)
test_capabilities_any_on :: proc(t: ^testing.T) {
	testing.expect(t, !capabilities_any_on(Capabilities{}))
	testing.expect(t, capabilities_any_on(Capabilities{levels = true}))
	testing.expect(t, capabilities_any_on(Capabilities{assets = true}))
}

@(test)
test_parse_extern_fn_seam_accessors :: proc(t: ^testing.T) {
	source := "extern fn arena_spawns() -> [Spawn]\nextern fn arena() -> Arena\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 2)
	if len(ast.fns) == 2 {
		testing.expect_value(t, ast.fns[0].name, "arena_spawns")
		testing.expect(t, ast.fns[0].is_extern)
		testing.expect_value(t, len(ast.fns[0].body), 0)
		testing.expect_value(t, ast.fns[1].name, "arena")
		testing.expect(t, ast.fns[1].is_extern)
	}
}

@(test)
test_parse_extern_fn_exports_name_through_index :: proc(t: ^testing.T) {
	seam := "data Arena { count: Int }\nextern fn arena_spawns() -> [Spawn]\nextern fn arena() -> Arena\n"
	seam_ast, parse_err := stage_parse(stage_lex(seam))
	testing.expect_value(t, parse_err, Parse_Error.None)
	exports := collect_module_exports(seam_ast)
	has_spawns := false
	for e in exports {
		if e.name == "arena_spawns" {
			has_spawns = true
			testing.expect_value(t, e.kind, Module_Export_Kind.Term)
		}
	}
	testing.expect(t, has_spawns)
}

@(test)
test_source_is_behavior_module_classifies :: proc(t: ^testing.T) {
	root, ok := write_seam_scratch_tree(
		t,
		{
			{rel = "src/world.fun", content = "thing Player { pos: Int }\n"},
			{rel = "src/game.fun", content = "thing Foo { x: Int }\nbehavior b on Foo { fn step(f: Foo) -> Foo { return f } }\n"},
		},
	)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	src, src_err, _ := collect_sources(root)
	testing.expect_value(t, src_err, Project_Error.None)
	testing.expect(t, source_is_behavior_module(src, "game"))
	testing.expect(t, !source_is_behavior_module(src, "world"))
	testing.expect(t, !source_is_behavior_module(src, "absent"))
}

@(test)
test_seam_import_arena :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP seam-import arena: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}

	project, err, _ := read_project(dir)
	testing.expect_value(t, err, Project_Error.None)
	if err != .None {
		return
	}

	seam_source, has_seam := find_source_module(project.sources, "arena")
	testing.expect(t, has_seam)
	if !has_seam {
		return
	}
	testing.expect(t, strings.has_suffix(seam_source.path, "arena.gen.fun"))
	_, has_world := find_source_module(project.sources, "arena_world")
	testing.expect(t, has_world)

	seam_bytes, read_err := os.read_entire_file_from_path(seam_source.path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	seam_ast, parse_err := stage_parse(stage_lex(string(seam_bytes)))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, stage_gates(seam_ast), Gate_Error.None)

	index := build_seam_test_index(project.sources)
	bindings, bind_err := resolve_imports_indexed(seam_ast, index)
	testing.expect_value(t, bind_err, Type_Error.None)
	_, env_err := resolve_env(seam_ast, bindings, index)
	testing.expect_value(t, env_err, Type_Error.None)

	player_binding, has_player := bindings.names["Player"]
	testing.expect(t, has_player)
	testing.expect_value(t, player_binding.module, "arena_world")
	spawn_binding, has_spawn := bindings.names["Spawn"]
	testing.expect(t, has_spawn)
	testing.expect_value(t, spawn_binding.module, "engine.world")

	log.infof("seam-import arena: gen/arena.gen.fun joined the set as `arena`; parses+typechecks importing schema+engine only")
}

@(test)
test_seam_imports_behavior_rejects :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP seam-imports-behavior: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}

	seam_path := filepath.join({dir, "gen", "arena.gen.fun"}, context.temp_allocator) or_else ""
	world_path := filepath.join({dir, "src", "arena_world.fun"}, context.temp_allocator) or_else ""
	seam_bytes, seam_read := os.read_entire_file_from_path(seam_path, context.temp_allocator)
	world_bytes, world_read := os.read_entire_file_from_path(world_path, context.temp_allocator)
	if seam_read != nil || world_read != nil {
		log.warnf("SKIP seam-imports-behavior: cannot read arena sources under %s", dir)
		return
	}

	anchor := "import arena_world.{Player, Hunter, Pillar, Switch, Door, Base, Cannon}"
	variant, found := golden_variant(string(seam_bytes), anchor, "import arena_game.{gate_open}")
	testing.expect(t, found)
	if !found {
		return
	}

	game_standin := "@doc(\"arena_game behavior-module stand-in: a behavior + the gate_open export, spelled with the current grammar.\")\n" +
		"import arena_world.{Switch, Door}\n" +
		"fn gate_open(sw: Switch) -> Bool { return sw.on }\n" +
		"behavior gate_logic on Door { fn step(self: Door) -> Door { return self } }\n"
	root, ok := write_seam_scratch_tree(
		t,
		{
			{rel = "src/arena_world.fun", content = string(world_bytes)},
			{rel = "src/arena_game.fun", content = game_standin},
			{rel = "gen/arena.gen.fun", content = variant},
			{rel = "levels/arena.flvl", content = "level Arena 2d {\n}\n"},
		},
	)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Seam_Imports_Behavior)
	log.infof("seam-imports-behavior: a gen/ seam importing arena_game (behavior module) rejects with Seam_Imports_Behavior")
}

find_source_module :: proc(sources: []Source, module: string) -> (source: Source, found: bool) {
	for candidate in sources {
		if candidate.module == module {
			return candidate, true
		}
	}
	return Source{}, false
}

build_seam_test_index :: proc(sources: []Source) -> Module_Index {
	parseable := make([dynamic]Source, 0, len(sources), context.temp_allocator)
	for source in sources {
		source_bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			continue
		}
		if _, parse_err := stage_parse(stage_lex(string(source_bytes))); parse_err != .None {
			continue
		}
		append(&parseable, source)
	}
	index, err := build_module_index(parseable[:])
	if err != .None {
		return Module_Index{}
	}
	return index
}

Seam_Scratch_File :: struct {
	rel:     string,
	content: string,
}

write_seam_scratch_tree :: proc(t: ^testing.T, files: []Seam_Scratch_File) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), fmt.tprintf("funpack-seam-scratch-%d", scratch_seq())})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	if os.make_directory_all(configs) != nil {
		log.warnf("SKIP seam scratch tree: cannot create dirs under %s", root)
		return "", false
	}
	fcfg_path := scratch_join({configs, "project.fcfg"})
	if os.write_entire_file(fcfg_path, "project arena {\n  version = \"0.1.0\"\n}\n") != nil {
		remove_scratch_tree(root)
		log.warnf("SKIP seam scratch tree: cannot write project.fcfg under %s", root)
		return "", false
	}
	for file in files {
		path := scratch_join({root, file.rel})
		dir := filepath.dir(path)
		if !os.is_dir(dir) && os.make_directory_all(dir) != nil {
			remove_scratch_tree(root)
			log.warnf("SKIP seam scratch tree: cannot create dir for %s under %s", file.rel, root)
			return "", false
		}
		if os.write_entire_file(path, file.content) != nil {
			remove_scratch_tree(root)
			log.warnf("SKIP seam scratch tree: cannot write %s under %s", file.rel, root)
			return "", false
		}
	}
	return root, true
}
