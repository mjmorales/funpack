package funpack

import "core:os"
import "core:path/filepath"
import "core:log"
import "core:strings"
import "core:testing"

ARENA_DEFAULT_DIR :: "examples/arena"

resolve_arena_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ARENA_DIR", ARENA_DEFAULT_DIR)
}

arena_seam_standin :: proc() -> Ast {
	source := "data Arena { count: Int }\n" +
		"fn arena_spawns() -> Int { return 0 }\n" +
		"fn arena() -> Arena { return Arena{count: 0} }\n"
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Ast{}
	}
	return ast
}

@(test)
test_multi_module_resolves_arena_imports :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP multi-module arena: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	world_path := filepath.join({dir, "src", "arena_world.fun"}, context.temp_allocator) or_else ""
	game_path := filepath.join({dir, "src", "arena_game.fun"}, context.temp_allocator) or_else ""

	world_bytes, world_err := os.read_entire_file_from_path(world_path, context.temp_allocator)
	game_bytes, game_err := os.read_entire_file_from_path(game_path, context.temp_allocator)
	if world_err != nil || game_err != nil {
		log.warnf("SKIP multi-module arena: cannot read arena sources under %s", dir)
		return
	}

	world_ast, world_parse := stage_parse(stage_lex(string(world_bytes)))
	testing.expect_value(t, world_parse, Parse_Error.None)

	index := build_module_index_from_asts(
		{"arena_world", "arena"},
		{world_ast, arena_seam_standin()},
	)

	world_entry, has_world := module_index_lookup(index, "arena_world")
	testing.expect(t, has_world)
	world_names := []string{"Player", "Hunter", "Switch", "Door"}
	for name in world_names {
		_, exported := module_export_lookup(world_entry, name)
		testing.expectf(t, exported, "arena_world should export %s", name)
	}
	seam_entry, has_seam := module_index_lookup(index, "arena")
	testing.expect(t, has_seam)
	seam_names := []string{"Arena", "arena_spawns", "arena"}
	for name in seam_names {
		_, exported := module_export_lookup(seam_entry, name)
		testing.expectf(t, exported, "arena seam should export %s", name)
	}

	consumer := parse_arena_game_user_imports(t, string(game_bytes))
	bindings, err := resolve_imports_indexed(consumer, index)
	testing.expect_value(t, err, Type_Error.None)

	switch_binding, has_switch := bindings.names["Switch"]
	testing.expect(t, has_switch)
	testing.expect_value(t, switch_binding.module, "arena_world")
	testing.expect_value(t, switch_binding.kind, Decl_Kind.Type_Name)

	spawns_binding, has_spawns := bindings.names["arena_spawns"]
	testing.expect(t, has_spawns)
	testing.expect_value(t, spawns_binding.module, "arena")
	testing.expect_value(t, spawns_binding.kind, Decl_Kind.Func)

	arena_binding, has_arena := bindings.names["Arena"]
	testing.expect(t, has_arena)
	testing.expect_value(t, arena_binding.module, "arena")
	testing.expect_value(t, arena_binding.kind, Decl_Kind.Type_Name)

	game_ast, game_parse := stage_parse(stage_lex(string(game_bytes)))
	testing.expect_value(t, game_parse, Parse_Error.None)
	testing.expect(t, len(game_ast.behaviors) > 0)
	testing.expect(t, len(game_ast.fns) > 0)
}

parse_arena_game_user_imports :: proc(t: ^testing.T, source: string) -> Ast {
	prefix := import_block_prefix(source)
	ast, parse_err := stage_parse(stage_lex(prefix))
	testing.expect_value(t, parse_err, Parse_Error.None)

	user_imports := make([dynamic]Import_Node, 0, 2, context.temp_allocator)
	for imp in ast.imports {
		if !module_under_reserved_root(imp.segments[0]) {
			append(&user_imports, imp)
		}
	}
	out := ast
	out.imports = user_imports[:]
	return out
}

import_block_prefix :: proc(source: string) -> string {
	decl_keywords := []string{
		"let ", "fn ", "behavior ", "thing ", "singleton ",
		"data ", "enum ", "signal ", "pipeline ", "test ",
	}
	lines := strings.split(source, "\n", context.temp_allocator)
	last_import := -1
	for line, i in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "import ") {
			last_import = i
			continue
		}
		for kw in decl_keywords {
			if strings.has_prefix(trimmed, kw) {
				return strings.join(lines[:last_import + 1], "\n", context.temp_allocator)
			}
		}
	}
	return source
}

@(test)
test_multi_module_unknown_user_module_rejected :: proc(t: ^testing.T) {
	consumer := "import arena_world.{Player}\n"
	ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	index := build_module_index_from_asts({"arena"}, {arena_seam_standin()})
	_, err := resolve_imports_indexed(ast, index)
	testing.expect_value(t, err, Type_Error.Unknown_Module)
}

@(test)
test_multi_module_unknown_member_rejected :: proc(t: ^testing.T) {
	world := "thing Player { pos: Int }\nthing Hunter { pos: Int }\n"
	world_ast, world_parse := stage_parse(stage_lex(world))
	testing.expect_value(t, world_parse, Parse_Error.None)

	consumer := "import arena_world.{Player, Goblin}\n"
	consumer_ast, consumer_parse := stage_parse(stage_lex(consumer))
	testing.expect_value(t, consumer_parse, Parse_Error.None)

	index := build_module_index_from_asts({"arena_world"}, {world_ast})
	_, err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_multi_module_dotted_single_member_resolves :: proc(t: ^testing.T) {
	world := "thing Player { pos: Int }\n"
	world_ast, _ := stage_parse(stage_lex(world))
	consumer := "import arena_world.Player\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	index := build_module_index_from_asts({"arena_world"}, {world_ast})
	bindings, err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, err, Type_Error.None)
	binding, bound := bindings.names["Player"]
	testing.expect(t, bound)
	testing.expect_value(t, binding.module, "arena_world")
	testing.expect_value(t, binding.kind, Decl_Kind.Type_Name)
}

@(test)
test_multi_module_collision_with_import_rejected :: proc(t: ^testing.T) {
	world := "thing Vec2 { x: Int }\n"
	world_ast, _ := stage_parse(stage_lex(world))
	consumer := "import engine.math.{Vec2}\nimport other.{Vec2}\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	index := build_module_index_from_asts({"other"}, {world_ast})
	_, err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, err, Type_Error.Name_Collision)
}

@(test)
test_multi_module_cross_module_type_resolves :: proc(t: ^testing.T) {
	world := "thing Player { pos: Int }\n"
	world_ast, _ := stage_parse(stage_lex(world))
	consumer := "import arena_world.{Player}\nfn id(p: Player) -> Player { return p }\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	index := build_module_index_from_asts({"arena_world"}, {world_ast})
	bindings, bind_err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, bind_err, Type_Error.None)
	env, env_err := resolve_env(consumer_ast, bindings, index)
	testing.expect_value(t, env_err, Type_Error.None)

	term, has_term := env_term_name(env, "id")
	testing.expect(t, has_term)
	testing.expect(t, term.signature != nil)
	testing.expect_value(t, len(term.signature.params), 1)
	param := term.signature.params[0]
	user, is_user := param.(^User_Type)
	testing.expect(t, is_user)
	if is_user {
		testing.expect_value(t, user.name, "Player")
		testing.expect_value(t, user.kind, User_Kind.Thing)
	}
}

hexgrid_layout_ast :: proc(t: ^testing.T) -> Ast {
	source := "@expose\ndata Hex { q: Int, r: Int }\n" +
		"data Cube { x: Int, y: Int, z: Int }\n" +
		"@doc(\"Axial to pixel. The package's public API.\")\n" +
		"@expose\n" +
		"fn axial_to_pixel(q: Int, size: Fixed) -> Fixed {\n" +
		"  return size\n" +
		"}\n" +
		"@doc(\"Internal rounding helper.\")\n" +
		"fn cube_round(x: Fixed) -> Fixed {\n" +
		"  return x\n" +
		"}\n" +
		"@expose\nlet ORIGIN: Int = 0\n" +
		"let SCALE: Int = 2\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	return ast
}

hexgrid_index :: proc(t: ^testing.T) -> Module_Index {
	return build_module_index_typed({"hexgrid.layout"}, {hexgrid_layout_ast(t)}, {"hexgrid"})
}

@(test)
test_package_edge_exposed_member_resolves :: proc(t: ^testing.T) {
	consumer := "import hexgrid.layout.{Hex, axial_to_pixel, ORIGIN}\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	bindings, err := resolve_imports_indexed(consumer_ast, hexgrid_index(t))
	testing.expect_value(t, err, Type_Error.None)
	hex_binding, has_hex := bindings.names["Hex"]
	testing.expect(t, has_hex)
	testing.expect_value(t, hex_binding.module, "hexgrid.layout")
	testing.expect_value(t, hex_binding.kind, Decl_Kind.Type_Name)
	fn_binding, has_fn := bindings.names["axial_to_pixel"]
	testing.expect(t, has_fn)
	testing.expect_value(t, fn_binding.kind, Decl_Kind.Func)
}

@(test)
test_package_edge_private_member_rejected :: proc(t: ^testing.T) {
	index := hexgrid_index(t)
	private_imports := []string {
		"import hexgrid.layout.{cube_round}\n",
		"import hexgrid.layout.{Cube}\n",
		"import hexgrid.layout.{SCALE}\n",
	}
	for source in private_imports {
		consumer_ast, parse_err := stage_parse(stage_lex(source))
		testing.expect_value(t, parse_err, Parse_Error.None)
		_, err := resolve_imports_indexed(consumer_ast, index)
		testing.expect_value(t, err, Type_Error.Package_Private)
	}

	unknown_ast, unknown_parse := stage_parse(stage_lex("import hexgrid.layout.{Goblin}\n"))
	testing.expect_value(t, unknown_parse, Parse_Error.None)
	_, unknown_err := resolve_imports_indexed(unknown_ast, index)
	testing.expect_value(t, unknown_err, Type_Error.Unknown_Member)
}

@(test)
test_package_edge_dotted_member_gated :: proc(t: ^testing.T) {
	index := hexgrid_index(t)
	ok_ast, ok_parse := stage_parse(stage_lex("import hexgrid.layout.axial_to_pixel\n"))
	testing.expect_value(t, ok_parse, Parse_Error.None)
	_, ok_err := resolve_imports_indexed(ok_ast, index)
	testing.expect_value(t, ok_err, Type_Error.None)

	private_ast, private_parse := stage_parse(stage_lex("import hexgrid.layout.cube_round\n"))
	testing.expect_value(t, private_parse, Parse_Error.None)
	_, private_err := resolve_imports_indexed(private_ast, index)
	testing.expect_value(t, private_err, Type_Error.Package_Private)
}

@(test)
test_package_edge_module_handle_member_gated :: proc(t: ^testing.T) {
	index := hexgrid_index(t)
	ok_consumer := "import hexgrid.layout\n" +
		"test \"exposed const reachable\" {\n" +
		"  assert layout.ORIGIN == layout.ORIGIN\n" +
		"}\n"
	ok_ast, ok_parse := stage_parse(stage_lex(ok_consumer))
	testing.expect_value(t, ok_parse, Parse_Error.None)
	_, ok_err := stage_typecheck_indexed(ok_ast, index)
	testing.expect_value(t, ok_err, Type_Error.None)

	private_consumer := "import hexgrid.layout\n" +
		"test \"private const refused\" {\n" +
		"  assert layout.SCALE == layout.SCALE\n" +
		"}\n"
	private_ast, private_parse := stage_parse(stage_lex(private_consumer))
	testing.expect_value(t, private_parse, Parse_Error.None)
	_, private_err := stage_typecheck_indexed(private_ast, index)
	testing.expect_value(t, private_err, Type_Error.Package_Private)
}

@(test)
test_within_project_unexposed_member_still_public :: proc(t: ^testing.T) {
	index := build_module_index_typed({"layout"}, {hexgrid_layout_ast(t)})
	consumer := "import layout.{cube_round, Cube, SCALE}\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_module_exports_module_level_let_as_const :: proc(t: ^testing.T) {
	seam := "import engine.assets.{SoundHandle, MeshHandle}\n" +
		"let coin: MeshHandle = MeshHandle{name: \"coin\"}\n" +
		"let coin_sfx: SoundHandle = SoundHandle{name: \"coin_sfx\"}\n"
	seam_ast, parse_err := stage_parse(stage_lex(seam))
	testing.expect_value(t, parse_err, Parse_Error.None)

	name_index := build_module_index_from_asts({"assets"}, {seam_ast})
	entry, has_entry := module_index_lookup(name_index, "assets")
	testing.expect(t, has_entry)
	coin_sfx_export, exported := module_export_lookup(entry, "coin_sfx")
	testing.expect(t, exported)
	testing.expect_value(t, coin_sfx_export.kind, Module_Export_Kind.Const)
	testing.expect(t, coin_sfx_export.let_type == nil)

	typed_index := build_module_index_typed({"assets"}, {seam_ast})
	typed_entry, _ := module_index_lookup(typed_index, "assets")
	coin_sfx_typed, _ := module_export_lookup(typed_entry, "coin_sfx")
	testing.expect_value(t, coin_sfx_typed.kind, Module_Export_Kind.Const)
	engine_type, is_engine := coin_sfx_typed.let_type.(^Engine_Type)
	testing.expect(t, is_engine)
	if is_engine {
		testing.expect_value(t, engine_type.kind, Engine_Kind.SoundHandle)
	}
	binding := module_export_binding("assets", coin_sfx_typed)
	testing.expect_value(t, binding.kind, Decl_Kind.Value)
	testing.expect_value(t, binding.module, "assets")
}

@(test)
test_module_qualified_const_typechecks :: proc(t: ^testing.T) {
	seam := "import engine.assets.{SoundHandle}\n" +
		"let coin_sfx: SoundHandle = SoundHandle{name: \"coin_sfx\"}\n"
	seam_ast, _ := stage_parse(stage_lex(seam))

	consumer := "import engine.assets.{SoundHandle, sound}\n" +
		"import assets\n" +
		"test \"cross-module const types\" {\n" +
		"  assert assets.coin_sfx == sound(\"coin_sfx\")\n" +
		"}\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	index := build_module_index_typed({"assets", "consumer"}, {seam_ast, consumer_ast})

	bindings, bind_err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, bind_err, Type_Error.None)
	handle, bound := bindings.names["assets"]
	testing.expect(t, bound)
	testing.expect_value(t, handle.kind, Decl_Kind.Module)
	testing.expect_value(t, handle.module, "assets")

	const_type, found := module_const_type(index, bindings, "assets", "coin_sfx")
	testing.expect(t, found)
	engine_type, is_engine := const_type.(^Engine_Type)
	testing.expect(t, is_engine)
	if is_engine {
		testing.expect_value(t, engine_type.kind, Engine_Kind.SoundHandle)
	}

	_, type_err := stage_typecheck_indexed(consumer_ast, index)
	testing.expect_value(t, type_err, Type_Error.None)
}

@(test)
test_module_qualified_unknown_member_rejected :: proc(t: ^testing.T) {
	seam := "import engine.assets.{SoundHandle}\n" +
		"let coin_sfx: SoundHandle = SoundHandle{name: \"coin_sfx\"}\n"
	seam_ast, _ := stage_parse(stage_lex(seam))

	consumer := "import assets\n" +
		"test \"unknown member rejects\" {\n" +
		"  assert assets.not_a_const == assets.not_a_const\n" +
		"}\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	index := build_module_index_typed({"assets", "consumer"}, {seam_ast, consumer_ast})
	_, type_err := stage_typecheck_indexed(consumer_ast, index)
	testing.expect_value(t, type_err, Type_Error.Unknown_Member)
}

@(test)
test_module_qualified_type_member_unsupported :: proc(t: ^testing.T) {
	seam := "data Item { id: Int }\n" + "fn count() -> Int { return 0 }\n"
	seam_ast, seam_parse := stage_parse(stage_lex(seam))
	testing.expect_value(t, seam_parse, Parse_Error.None)

	type_consumer := "import store\n" +
		"test \"a module-qualified type is not a value\" {\n" +
		"  assert store.Item == store.Item\n" +
		"}\n"
	type_ast, type_parse := stage_parse(stage_lex(type_consumer))
	testing.expect_value(t, type_parse, Parse_Error.None)
	type_index := build_module_index_typed({"store", "consumer"}, {seam_ast, type_ast})
	_, type_err := stage_typecheck_indexed(type_ast, type_index)
	testing.expect_value(t, type_err, Type_Error.Unsupported_Expr)

	fn_consumer := "import store\n" +
		"test \"a module-qualified fn name is not a value\" {\n" +
		"  assert store.count == store.count\n" +
		"}\n"
	fn_ast, fn_parse := stage_parse(stage_lex(fn_consumer))
	testing.expect_value(t, fn_parse, Parse_Error.None)
	fn_index := build_module_index_typed({"store", "consumer"}, {seam_ast, fn_ast})
	_, fn_err := stage_typecheck_indexed(fn_ast, fn_index)
	testing.expect_value(t, fn_err, Type_Error.Unsupported_Expr)
}

@(test)
test_module_handle_shadowed_by_local_binding :: proc(t: ^testing.T) {
	seam := "import engine.assets.{SoundHandle}\n" +
		"let coin_sfx: SoundHandle = SoundHandle{name: \"coin_sfx\"}\n"
	seam_ast, _ := stage_parse(stage_lex(seam))

	consumer := "import assets\n" +
		"test \"a local binding shadows the module handle\" {\n" +
		"  let assets = 5\n" +
		"  assert assets.coin_sfx == assets.coin_sfx\n" +
		"}\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	index := build_module_index_typed({"assets", "consumer"}, {seam_ast, consumer_ast})
	_, type_err := stage_typecheck_indexed(consumer_ast, index)
	testing.expect_value(t, type_err, Type_Error.Type_Mismatch)
}

@(test)
test_module_handle_name_collision_with_user_decl :: proc(t: ^testing.T) {
	seam := "import engine.assets.{SoundHandle}\n" +
		"let coin_sfx: SoundHandle = SoundHandle{name: \"coin_sfx\"}\n"
	seam_ast, _ := stage_parse(stage_lex(seam))

	consumer := "import assets\n" + "let assets: Int = 5\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	index := build_module_index_typed({"assets", "consumer"}, {seam_ast, consumer_ast})

	bindings, bind_err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, bind_err, Type_Error.None)
	_, env_err := resolve_env(consumer_ast, bindings, index)
	testing.expect_value(t, env_err, Type_Error.Name_Collision)
}
