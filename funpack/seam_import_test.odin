// The §17 seam-import path: a baked gen/*.gen.fun seam joins the source set and
// rides the lex → parse → gates → typecheck pipeline like any .fun module, under
// the §17 schema/seam/behavior acyclic-import layering (a seam imports schema
// modules + engine.* only — importing a behavior module is a compile error).
//
// The arena exemplar is the live proof: gen/arena.gen.fun is the generated seam
// (module `arena`, derived by stripping the gen/ prefix exactly as src/ is
// stripped), it imports engine.world + arena_world (schema) only, and arena_game
// is the behavior module the layering forbids the seam from importing. The unit
// fixtures pin the derivation, the merge collision checks, and the layering arm
// without a spec checkout; the negative seam derives from the LIVE arena seam
// with a loud anchor (the negative-fixtures-derive-from-live-golden pattern), so
// it cannot drift from the committed exemplar.
package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// ── §15 gen/ module derivation ─────────────────────────────────────────
// gen/ is a derived source root peer to src/: a seam's module is its location
// under gen/ with the gen/ prefix and the `.gen.fun` suffix stripped and
// interior directories dotted.

@(test)
test_derive_seam_module_name_flat :: proc(t: ^testing.T) {
	// The arena golden case: gen/arena.gen.fun ⇒ module `arena` — NOT `gen.arena`
	// — because gen/ is stripped exactly as src/ is, and the full `.gen.fun`
	// suffix (not bare `.fun`) drops so the module is `arena`, not `arena.gen`.
	module := derive_seam_module_name("/proj/gen", "/proj/gen/arena.gen.fun")
	testing.expect_value(t, module, "arena")
}

@(test)
test_derive_seam_module_name_nested :: proc(t: ^testing.T) {
	// The derivation generalizes beyond the flat case: a nested seam dots its
	// interior directory — gen/town/market.gen.fun ⇒ `town.market`, proving the
	// rule is a pure function of the path against the gen/ root.
	module := derive_seam_module_name("/proj/gen", "/proj/gen/town/market.gen.fun")
	testing.expect_value(t, module, "town.market")
}

// ── §15.6 / §15.7 merge collision checks across the combined set ────────

@(test)
test_merge_sources_combines_and_sorts :: proc(t: ^testing.T) {
	// The src/ and gen/ sets merge into one source set in deterministic
	// sorted-by-path order — the order downstream stages walk by index.
	src := []Source{{path = "/p/src/arena_world.fun", module = "arena_world"}}
	seam := []Source{{path = "/p/gen/arena.gen.fun", module = "arena"}}
	merged, err, _ := merge_sources(src, seam)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(merged), 2)
	if len(merged) == 2 {
		// "/p/gen/..." sorts before "/p/src/..." (g < s).
		testing.expect_value(t, merged[0].module, "arena")
		testing.expect_value(t, merged[1].module, "arena_world")
	}
}

@(test)
test_merge_sources_cross_set_duplicate_module_rejected :: proc(t: ^testing.T) {
	// A seam whose derived module equals a hand-written src/ module is a §15.6
	// cross-set collision — neither per-set pass could see it, so the merge's
	// combined-set re-check catches it as Duplicate_Module.
	src := []Source{{path = "/p/src/arena.fun", module = "arena"}}
	seam := []Source{{path = "/p/gen/arena.gen.fun", module = "arena"}}
	_, err, _ := merge_sources(src, seam)
	testing.expect_value(t, err, Project_Error.Duplicate_Module)
}

@(test)
test_capabilities_any_on :: proc(t: ^testing.T) {
	// An all-OFF tree (pong/numerics/yard) has no gen/ source root, so its source
	// set is exactly src/ — the precondition collect_seam_sources gates on.
	testing.expect(t, !capabilities_any_on(Capabilities{}))
	testing.expect(t, capabilities_any_on(Capabilities{levels = true}))
	testing.expect(t, capabilities_any_on(Capabilities{assets = true}))
}

// ── extern fn parse admission (the committed seam's accessor form) ──────

@(test)
test_parse_extern_fn_seam_accessors :: proc(t: ^testing.T) {
	// The §17 seam's `extern fn` accessors parse: a body-less native-boundary fn
	// with a signature but no `{ … }`. It lands in ast.fns with is_extern set, so
	// it exports its name like any fn. `extern` is a reserved keyword (it lexes as
	// .Extern), so the declaration dispatches off it the way `fn` does.
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
	// An extern fn exports its name into the module index like any top-level fn,
	// so a behavior module's `import arena.{arena_spawns}` resolves — the seam's
	// accessor is a term-position export.
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

// ── §17 layering classification (in-memory) ─────────────────────────────

@(test)
test_source_is_behavior_module_classifies :: proc(t: ^testing.T) {
	// A module declaring a behavior or a pipeline is a §17 behavior module; a
	// schema module (thing/data/enum/signal only) is not. The classification reads
	// the parsed declarations off disk, so the fixtures write real sources to a
	// scratch tree and classify them by module name.
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
	// A module not in the set is not classified as a behavior module — the
	// layering check rejects only a positively-proven behavior import.
	testing.expect(t, !source_is_behavior_module(src, "absent"))
}

// ── arena exemplar (acceptance) ─────────────────────────────────────────

// test_seam_import_arena is the load-bearing positive acceptance: reading the
// live arena tree merges gen/arena.gen.fun into the source set as module `arena`,
// and that seam parses + typechecks importing schema + engine only (no behavior
// import). It resolves the sibling funpack-spec checkout (or FUNPACK_ARENA_DIR)
// and SKIPs loudly when absent, so a missing checkout never silently passes.
@(test)
test_seam_import_arena :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP seam-import arena: %s not found — set FUNPACK_ARENA_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return
	}

	project, err, _ := read_project(dir)
	testing.expect_value(t, err, Project_Error.None)
	if err != .None {
		return
	}

	// (1) The gen/ seam joined the source set as module `arena` with the correct
	// §15 derived name — gen/arena.gen.fun ⇒ `arena`, not `gen.arena`.
	seam_source, has_seam := find_source_module(project.sources, "arena")
	testing.expect(t, has_seam)
	if !has_seam {
		return
	}
	testing.expect(t, strings.has_suffix(seam_source.path, "arena.gen.fun"))
	// arena_world (the schema) is in the combined set alongside the seam.
	_, has_world := find_source_module(project.sources, "arena_world")
	testing.expect(t, has_world)

	// (2) The seam lexes + parses + typechecks cleanly through the project-wide
	// index, importing engine.world + arena_world (schema) only — no behavior
	// import. The seam imports arena_world (a USER module), so it types against the
	// project-wide index, not the single-source stage_typecheck.
	seam_bytes, read_err := os.read_entire_file_from_path(seam_source.path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	seam_ast, parse_err := stage_parse(stage_lex(string(seam_bytes)))
	testing.expect_value(t, parse_err, Parse_Error.None)
	// Gates and the index-threaded resolve/env are the seam's pipeline staging.
	testing.expect_value(t, stage_gates(seam_ast), Gate_Error.None)

	index := build_seam_test_index(project.sources)
	bindings, bind_err := resolve_imports_indexed(seam_ast, index)
	testing.expect_value(t, bind_err, Type_Error.None)
	_, env_err := resolve_env(seam_ast, bindings, index)
	testing.expect_value(t, env_err, Type_Error.None)

	// The cross-module schema names bind to arena_world; Spawn binds to engine.world.
	player_binding, has_player := bindings.names["Player"]
	testing.expect(t, has_player)
	testing.expect_value(t, player_binding.module, "arena_world")
	spawn_binding, has_spawn := bindings.names["Spawn"]
	testing.expect(t, has_spawn)
	testing.expect_value(t, spawn_binding.module, "engine.world")

	log.infof("seam-import arena: gen/arena.gen.fun joined the set as `arena`; parses+typechecks importing schema+engine only")
}

// test_seam_imports_behavior_rejects is the load-bearing negative: a gen/ seam
// importing a BEHAVIOR module rejects with Seam_Imports_Behavior (§17 acyclic
// layering). The negative seam derives from the LIVE arena seam with one exact
// anchor swap — the schema import line replaced with an import of arena_game (the
// behavior module) — so it cannot drift from the committed exemplar
// (negative-fixtures-derive-from-live-golden). The asserted `found` turns any
// golden-file evolution into a loud re-anchor failure.
@(test)
test_seam_imports_behavior_rejects :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP seam-imports-behavior: %s not found — set FUNPACK_ARENA_DIR or check out funpack-spec as a sibling of the repo",
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

	// Derive the negative from the LIVE seam: swap its schema import line for an
	// import of arena_game (the behavior module). The §17 layering reject keys on
	// the IMPORTED module's classification (declares a behavior/pipeline), not on
	// the import members, so the swap isolates the behavior-import reject. The
	// asserted `found` turns any golden-seam evolution into a loud re-anchor
	// failure (negative-fixtures-derive-from-live-golden).
	anchor := "import arena_world.{Player, Hunter, Pillar, Switch, Door, Base, Cannon}"
	variant, found := golden_variant(string(seam_bytes), anchor, "import arena_game.{gate_open}")
	testing.expect(t, found) // anchor moved in the golden seam → re-anchor this fixture
	if !found {
		return
	}

	// Materialize a scratch arena-shaped tree: the live-derived behavior-import
	// seam in gen/, the real arena_world (schema) in src/, and a PARSEABLE
	// arena_game behavior-module stand-in. The real arena_game.fun uses
	// if-expressions and tuple match patterns the frontend does not yet admit
	// (lore #11), so it does not parse; the §17 classification reads the imported
	// module's declarations, so the stand-in spells a behavior + the gate_open
	// export with the current grammar — exactly the parseable-stand-in shape
	// module_index_test uses for the not-yet-supported arena seam. A non-empty
	// levels/ turns the levels capability ON so collect_seam_sources walks gen/.
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

// find_source_module finds a Source by its derived module name in the combined
// source set, walked by index (never a map). Used by the acceptance to assert the
// seam joined the set under the right §15 name.
find_source_module :: proc(sources: []Source, module: string) -> (source: Source, found: bool) {
	for candidate in sources {
		if candidate.module == module {
			return candidate, true
		}
	}
	return Source{}, false
}

// build_seam_test_index builds a project-wide Module_Index over the combined
// source set so the seam types against its sibling user modules (arena_world).
// It reads and parses each source, SKIPPING any source the parser rejects: the
// arena behavior module (arena_game.fun) uses if-expressions and tuple match
// patterns the frontend does not yet admit (lore #11 — a downstream seam owns
// that body grammar), so a project-wide build_module_index over the whole arena
// tree would fail. The seam imports the SCHEMA module + engine only, so only the
// parseable schema sources need to be in the index for the seam to resolve; the
// behavior module is never imported by the seam and is correctly left out.
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

// Seam_Scratch_File pairs a source-tree-relative path with its file content for
// write_seam_scratch_tree — the richer scratch helper the seam tests need, which
// writes REAL source bytes (not the placeholder write_scratch_tree_multi uses) at
// arbitrary roots (src/, gen/, levels/), so a seam test can materialize a
// multi-module arena-shaped tree.
Seam_Scratch_File :: struct {
	rel:     string, // path relative to the project root, e.g. "gen/arena.gen.fun"
	content: string,
}

// write_seam_scratch_tree materializes a §14 project tree under a unique temp
// root: funpack_configs/project.fcfg plus the given files at their relative
// paths (creating interior directories). It is write_scratch_tree_multi with
// per-file content and arbitrary roots — the seam tests need real source bytes
// and the gen/ + levels/ roots, which the placeholder helper does not provide.
// ok = false (with a logged skip) when the scratch I/O fails, matching the
// project_test.odin scratch helpers' sandbox-degrades-to-skip policy.
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
		// make_directory_all returns .Exist when the dir already exists (a second
		// file under the same src/ root), which is NOT a failure — only a create
		// error that leaves the dir absent should skip.
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
