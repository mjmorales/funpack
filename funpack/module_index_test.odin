// Multi-module user-module import resolution fixtures (spec §15, §02). The
// frontend was single-source: an `import arena_world.{Player}` naming a SIBLING
// user module returned .Unknown_Module. The module index lifts every source's
// exported names keyed by §15 module, and the user-module import arm resolves a
// member-group or dotted import against a sibling module's exports, binding them
// into the consuming module — an unknown user module, an unknown member, and a
// name colliding with an in-scope import all stay compile errors.
//
// The arena example is the live proof, on its .fun sources ALONE (no .flvl, no
// emitter): arena_game.fun imports both arena_world (the schema module) and arena
// (the generated seam, stood in for here since it is not yet generated), and both
// imports must resolve clean. The hand-built unit fixtures (no spec checkout
// needed) pin the index shape and the three reject arms so coverage is not
// gated entirely on the sibling.
package funpack

import "core:os"
import "core:path/filepath"
import "core:log"
import "core:strings"
import "core:testing"

ARENA_DEFAULT_DIR :: "../funpack-spec/examples/arena"

// resolve_arena_dir resolves the arena example tree: FUNPACK_ARENA_DIR override,
// else the sibling-checkout default anchored at the main checkout (the worktree
// infix is stripped so golden coverage does not silently SKIP out of a worktree
// validation run) — the same resolution every spec golden uses.
resolve_arena_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ARENA_DIR", ARENA_DEFAULT_DIR)
}

// arena_seam_standin builds the not-yet-generated arena seam's parsed module: a
// `data Arena` schema and the two seam entry points (arena_spawns, arena). The
// real seam (gen/arena.gen.fun) is `extern fn` over Ref[T] — a grammar the bake
// story owns, not this seam — so the stand-in spells the seam's exported names
// with the current grammar (plain fns, an Int-field Arena). Only the EXPORTED
// NAMES matter to the index, so the stand-in carries exactly Arena/arena_spawns/
// arena, the three names arena_game imports from `arena`.
arena_seam_standin :: proc() -> Ast {
	source := "data Arena { count: Int }\n" +
		"fn arena_spawns() -> Int { return 0 }\n" +
		"fn arena() -> Arena { return Arena{count: 0} }\n"
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		// The stand-in is a fixed, well-formed source — a parse failure is a
		// test-authoring bug, surfaced as an empty module.
		return Ast{}
	}
	return ast
}

@(test)
test_multi_module_resolves_arena_imports :: proc(t: ^testing.T) {
	// AC: arena_game resolves its imports of BOTH arena_world (the schema
	// module, read off disk and fully parsed) and the arena seam (the hand-built
	// stand-in) to .None. The cross-module surface — Switch/Door/Player/Hunter
	// from arena_world, arena_spawns/Arena/arena from the seam — binds into
	// arena_game's environment.
	//
	// SCOPE NOTE: this seam resolves USER-module imports. arena_game's engine.*
	// imports (engine.nav.{Nav, Path}, engine.prelude.{…, or_else}) name surface
	// the NEXT seam admits (lore #11 seam 2: engine.world.Ref + engine.nav). The
	// if-expression and tuple-match-pattern body grammar arena_game's bodies use
	// (lines 38, 62-65) IS now admitted by the parser (the if-expr/tuple-match
	// grammar seam, expr.odin), so the full file PARSES — the proof asserts that
	// directly below. Typecheck of the full file still depends on the engine.nav /
	// engine.world.Ref surface another seam admits, so the proof reads
	// arena_game's REAL user-module import declarations (parse_arena_game_user_imports)
	// and resolves exactly those against the index — the user-module arms this
	// seam owns — isolated from the engine.* surface another seam owns.
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP multi-module arena: %s not found — set FUNPACK_ARENA_DIR or check out funpack-spec as a sibling", dir)
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

	// arena_world.fun parses fully (schema-only, no behaviors) — its `on` field
	// (Switch.on) now lexes as a value name, the contextual-keyword fix this seam
	// landed.
	world_ast, world_parse := stage_parse(stage_lex(string(world_bytes)))
	testing.expect_value(t, world_parse, Parse_Error.None)

	// Build the project-wide index over arena_world (real, full parse) and the
	// arena seam stand-in (the not-yet-generated seam's exported names).
	index := build_module_index_from_asts(
		{"arena_world", "arena"},
		{world_ast, arena_seam_standin()},
	)

	// arena_world exports its seven things; the seam stand-in exports Arena +
	// arena_spawns + arena — the names arena_game's two user imports name.
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

	// Read arena_game's REAL user-module import declarations and resolve them.
	consumer := parse_arena_game_user_imports(t, string(game_bytes))
	bindings, err := resolve_imports_indexed(consumer, index)
	testing.expect_value(t, err, Type_Error.None)

	// The user-module members bind to their OWNING module with the right kind:
	// a schema thing as a Type_Name owned by arena_world, the spawn-list fn as
	// a Func owned by the seam.
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

	// The if-expr/tuple-match grammar seam landed: arena_game's FULL source now
	// PARSES (its bodies use the value-producing if-expression at arena_game.fun
	// line 38 and the tuple match patterns at lines 62-65 — forms the parser used
	// to deliberately exclude). The body grammar is admitted, so stage_parse over
	// the whole file is .None — strictly further than the import-prefix-only proof
	// this test ran before the seam. Full typecheck still awaits the engine.nav /
	// engine.world.Ref surface another seam admits.
	game_ast, game_parse := stage_parse(stage_lex(string(game_bytes)))
	testing.expect_value(t, game_parse, Parse_Error.None)
	// The parsed file carries arena_game's behaviors and fns whose bodies hold the
	// newly-admitted forms — chase's tuple-match step and nearest_player's
	// if-expr fold — so the parse proof is over real grammar, not an empty file.
	testing.expect(t, len(game_ast.behaviors) > 0)
	testing.expect(t, len(game_ast.fns) > 0)
}

// parse_arena_game_user_imports parses arena_game.fun's leading import block and
// returns an Ast carrying ONLY its USER-module import declarations (the modules
// not under the reserved `engine` root). It keeps the proof faithful — the import
// nodes come from arena_game's genuine source bytes — while isolating the
// user-module arms this seam owns from the engine.* arms seam 2 admits and the
// body grammar seam 3 admits. The import block is the file prefix up to (but not
// including) the first non-import top-level declaration; parsing that prefix
// alone never trips the unsupported body grammar.
parse_arena_game_user_imports :: proc(t: ^testing.T, source: string) -> Ast {
	prefix := import_block_prefix(source)
	ast, parse_err := stage_parse(stage_lex(prefix))
	testing.expect_value(t, parse_err, Parse_Error.None)

	user_imports := make([dynamic]Import_Node, 0, 2, context.temp_allocator)
	for imp in ast.imports {
		// A reserved-root path (`engine.*`) is a stdlib import seam 2 owns; keep
		// only the user-module imports (arena_world, arena).
		if !module_under_reserved_root(imp.segments[0]) {
			append(&user_imports, imp)
		}
	}
	out := ast
	out.imports = user_imports[:]
	return out
}

// import_block_prefix returns the source prefix through the last `import` line —
// the contiguous leading run of `@doc` directives and `import` declarations,
// stopping at the first top-level keyword that opens a non-import declaration
// (let/fn/behavior/thing/data/enum/signal/pipeline/test). It is a line scan: an
// import block is line-oriented, and stopping before the first body declaration
// keeps the prefix free of the unsupported body grammar. Tolerant of leading
// @doc lines and blank lines between imports.
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
		// A top-level declaration keyword ends the import block.
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
	// AC: an import naming a user module that is NOT in the index rejects as
	// .Unknown_Module — the user-module arm's miss is the same reject the
	// stdlib arm gives an unknown engine.* module. Built entirely in-memory, so
	// no spec checkout is needed.
	consumer := "import arena_world.{Player}\n"
	ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	// The index has the seam but NOT arena_world — the imported module is
	// unknown.
	index := build_module_index_from_asts({"arena"}, {arena_seam_standin()})
	_, err := resolve_imports_indexed(ast, index)
	testing.expect_value(t, err, Type_Error.Unknown_Module)
}

@(test)
test_multi_module_unknown_member_rejected :: proc(t: ^testing.T) {
	// AC: an import of a KNOWN user module naming a member that module does NOT
	// export rejects as .Unknown_Member — the user-module analogue of the
	// stdlib arm's unknown-member reject. In-memory, no spec checkout needed.
	world := "thing Player { pos: Int }\nthing Hunter { pos: Int }\n"
	world_ast, world_parse := stage_parse(stage_lex(world))
	testing.expect_value(t, world_parse, Parse_Error.None)

	consumer := "import arena_world.{Player, Goblin}\n" // Goblin is not exported
	consumer_ast, consumer_parse := stage_parse(stage_lex(consumer))
	testing.expect_value(t, consumer_parse, Parse_Error.None)

	index := build_module_index_from_asts({"arena_world"}, {world_ast})
	_, err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_multi_module_dotted_single_member_resolves :: proc(t: ^testing.T) {
	// A dotted single-member import of a user module (`import arena_world.Player`,
	// no brace group) resolves the final segment against the leading module's
	// exports — the dotted arm's user-module path, mirroring the member-group arm.
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
	// A user-module import whose member name already binds to a DIFFERENT
	// in-scope import is .Name_Collision (spec §02 one-name-one-meaning): here a
	// user module exports `Vec2`, which the prelude/math surface already owns, so
	// importing it collides. The §02 rule holds across the stdlib and user-module
	// namespaces alike.
	world := "thing Vec2 { x: Int }\n" // shadows the engine.math Vec2
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
	// Item (3): a field/param naming a sibling-module type resolves to the
	// checker's nominal User_Type during typecheck. A consumer imports a thing
	// from a sibling and types a fn param by it; resolve_env (threaded the index)
	// grounds the param to the owning module's User_Type with the right §06 kind.
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

// ── multi-module let-export (the §19 assets seam's typed handle constants) ──

@(test)
test_module_exports_module_level_let_as_const :: proc(t: ^testing.T) {
	// A let-emitting seam (the §19 assets seam) exports its module-level `let`
	// constants as .Const term-position bindings — the cross-module CONST surface a
	// consumer reaches through `assets.coin_sfx`. collect_module_exports lifts each
	// let into the export list; the typed index fills its declared type. In-memory,
	// no spec checkout needed.
	seam := "import engine.assets.{SoundHandle, MeshHandle}\n" +
		"let coin: MeshHandle = MeshHandle{name: \"coin\"}\n" +
		"let coin_sfx: SoundHandle = SoundHandle{name: \"coin_sfx\"}\n"
	seam_ast, parse_err := stage_parse(stage_lex(seam))
	testing.expect_value(t, parse_err, Parse_Error.None)

	// The name-only index records the two lets as .Const exports (a behavior would
	// not export — only types, fns, and lets do).
	name_index := build_module_index_from_asts({"assets"}, {seam_ast})
	entry, has_entry := module_index_lookup(name_index, "assets")
	testing.expect(t, has_entry)
	coin_sfx_export, exported := module_export_lookup(entry, "coin_sfx")
	testing.expect(t, exported)
	testing.expect_value(t, coin_sfx_export.kind, Module_Export_Kind.Const)
	// The name-only index leaves the let type nil — only the typed index fills it.
	testing.expect(t, coin_sfx_export.let_type == nil)

	// The typed index fills each .Const export's declared type (the cross-module
	// CONST surface): coin_sfx grounds to the SoundHandle engine type.
	typed_index := build_module_index_typed({"assets"}, {seam_ast})
	typed_entry, _ := module_index_lookup(typed_index, "assets")
	coin_sfx_typed, _ := module_export_lookup(typed_entry, "coin_sfx")
	testing.expect_value(t, coin_sfx_typed.kind, Module_Export_Kind.Const)
	engine_type, is_engine := coin_sfx_typed.let_type.(^Engine_Type)
	testing.expect(t, is_engine)
	if is_engine {
		testing.expect_value(t, engine_type.kind, Engine_Kind.SoundHandle)
	}
	// A .Const export binds as a .Value (the term-position value kind), so a
	// member-group import of it populates Bindings identically to a stdlib value.
	binding := module_export_binding("assets", coin_sfx_typed)
	testing.expect_value(t, binding.kind, Decl_Kind.Value)
	testing.expect_value(t, binding.module, "assets")
}

@(test)
test_module_qualified_const_typechecks :: proc(t: ^testing.T) {
	// Item (2): a module-qualified const reference (`assets.coin_sfx`) grounds to
	// the let's declared type during typecheck. A consumer whole-module imports the
	// seam (`import assets`) and references the const in a test; stage_typecheck
	// (threaded the typed index) types the member access as SoundHandle through the
	// module_const_type arm — the term-position analogue of module_record_schema.
	// In-memory, no spec checkout needed.
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

	// The whole-module `import assets` binds the handle to the sibling user module.
	bindings, bind_err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, bind_err, Type_Error.None)
	handle, bound := bindings.names["assets"]
	testing.expect(t, bound)
	testing.expect_value(t, handle.kind, Decl_Kind.Module)
	testing.expect_value(t, handle.module, "assets")

	// module_const_type resolves the const's declared type through the handle.
	const_type, found := module_const_type(index, bindings, "assets", "coin_sfx")
	testing.expect(t, found)
	engine_type, is_engine := const_type.(^Engine_Type)
	testing.expect(t, is_engine)
	if is_engine {
		testing.expect_value(t, engine_type.kind, Engine_Kind.SoundHandle)
	}

	// The whole consumer typechecks clean — the `assets.coin_sfx == sound(...)`
	// equality types (both sides are SoundHandle).
	_, type_err := stage_typecheck_indexed(consumer_ast, index)
	testing.expect_value(t, type_err, Type_Error.None)
}

@(test)
test_module_qualified_unknown_member_rejected :: proc(t: ^testing.T) {
	// Negative: an UNKNOWN member of a whole-module user handle is .Unknown_Member —
	// the term-position analogue of a member-group import's unknown-member reject.
	// `assets.not_a_const` names no export of the seam, so the closed module surface
	// rejects it rather than silently typing it. In-memory, no spec checkout needed.
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
	// Coverage gap: an EXPORTED but non-const member of a whole-module handle is
	// .Unsupported_Expr — a module-qualified type or fn name is not a value. The
	// seam exports a `data Item` type and a top-level fn; reaching either through
	// `handle.NAME` in a value position grounds to .Unsupported_Expr (module_member_check
	// kind != .Const arm), distinct from the .Unknown_Member an unexported member gives.
	// In-memory, no spec checkout needed.
	seam := "data Item { id: Int }\n" + "fn count() -> Int { return 0 }\n"
	seam_ast, seam_parse := stage_parse(stage_lex(seam))
	testing.expect_value(t, seam_parse, Parse_Error.None)

	// A type member (`store.Item`) reached as a value through the handle.
	type_consumer := "import store\n" +
		"test \"a module-qualified type is not a value\" {\n" +
		"  assert store.Item == store.Item\n" +
		"}\n"
	type_ast, type_parse := stage_parse(stage_lex(type_consumer))
	testing.expect_value(t, type_parse, Parse_Error.None)
	type_index := build_module_index_typed({"store", "consumer"}, {seam_ast, type_ast})
	_, type_err := stage_typecheck_indexed(type_ast, type_index)
	testing.expect_value(t, type_err, Type_Error.Unsupported_Expr)

	// A fn member (`store.count`) reached as a value through the handle — also not
	// a value, the same .Unsupported_Expr the type member gives.
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
	// Coverage gap: a local `let` binding of the handle name SHADOWS the module
	// handle — `handle.member` is then a field access on the local value, not a
	// module-qualified const access. The test binds `assets` to an Int, so
	// `assets.coin_sfx` types through field_member on Int (a Ground type with no
	// such field) → .Type_Mismatch, NOT the SoundHandle the module-handle arm would
	// give. module_member_check's in-scope guard routes the local binding away from
	// the cross-module arm (spec §02 one-name-one-meaning, innermost scope wins).
	// In-memory, no spec checkout needed.
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
	// The local Int has no `coin_sfx` field — the shadow won, so the cross-module
	// const arm never fired (which would have typed it SoundHandle and passed).
	testing.expect_value(t, type_err, Type_Error.Type_Mismatch)
}

@(test)
test_module_handle_name_collision_with_user_decl :: proc(t: ^testing.T) {
	// Coverage gap: a user declaration named like an imported WHOLE-MODULE handle is
	// .Name_Collision — the §02 one-name-one-meaning rule holds across the module-handle
	// namespace too. `import assets` binds `assets` as a .Module handle in bindings.names;
	// a user `let assets = …` then claims the same name, which name_taken rejects (the
	// handle is an in-scope import). The user decl is a `let`, not a `data`/`enum`: a
	// §15 module name is lowercase, so it can only collide in the lowercase term
	// namespace (a PascalCase type name could never spell a module name). The collision
	// fires at resolve, before typing. In-memory, no spec checkout needed.
	seam := "import engine.assets.{SoundHandle}\n" +
		"let coin_sfx: SoundHandle = SoundHandle{name: \"coin_sfx\"}\n"
	seam_ast, _ := stage_parse(stage_lex(seam))

	// The consumer whole-module imports `assets` AND declares a user `let assets` —
	// the name now means both the module handle and a const, which §02 forbids.
	consumer := "import assets\n" + "let assets: Int = 5\n"
	consumer_ast, parse_err := stage_parse(stage_lex(consumer))
	testing.expect_value(t, parse_err, Parse_Error.None)

	index := build_module_index_typed({"assets", "consumer"}, {seam_ast, consumer_ast})

	// Resolution rejects the colliding decl: the whole-module handle and the user
	// const cannot share the name.
	bindings, bind_err := resolve_imports_indexed(consumer_ast, index)
	testing.expect_value(t, bind_err, Type_Error.None)
	_, env_err := resolve_env(consumer_ast, bindings, index)
	testing.expect_value(t, env_err, Type_Error.Name_Collision)
}
