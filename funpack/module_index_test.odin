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
	// the NEXT seam admits (lore #11 seam 2: engine.world.Ref + engine.nav), and
	// arena_game's BODY uses if-expressions and tuple match patterns the parser
	// does not yet admit (deliberate grammar boundaries, expr.odin). So the proof
	// reads arena_game's REAL user-module import declarations (parse_arena_game_user_imports)
	// and resolves exactly those against the index — the user-module arms this
	// seam owns — isolated from the engine.* arms and body grammar another seam owns.
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
