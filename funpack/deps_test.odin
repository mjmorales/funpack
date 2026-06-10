// §30 dependency-surface fixtures: the deps.fcfg grammar (§30 §3), the
// path-source package resolution that roots a dependency's modules under its
// project name (§30 §7, §15 §5), and the two named refusals the package edge
// rests on — the §30 §2 star-graph violation (a package importing a package,
// pinned both structurally over a scratch tree and at the import level
// in-memory) and the reserved-root collisions (a package named like the
// unshadowable `engine` root; a local module shadowing a dependency's root).
// The tree fixtures ride the project_test scratch helpers; the dependency's
// exposed API is fully @expose'd so no fixture depends on the (parallel)
// exposure-closure story's verdicts.
package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// ── §30 §3 deps.fcfg grammar ─────────────────────────────────────────────

@(test)
test_parse_deps_fcfg_all_three_sources :: proc(t: ^testing.T) {
	// The §30 §3 exemplar: one dep per provenance source, with @doc admitted
	// under the P6 discipline. Each row carries its name/source/value, and
	// the hash rides only where the table grants one (registry + url).
	content := "@doc(\"the declared dependency set\")\n" +
		"use hexgrid version \"0.4\" hash \"sha256:1c77\"\n" +
		"use shared path \"../studio-shared\"\n" +
		"use steering url \"https://example.com/steering-2.0.tar\" hash \"sha256:9f3a\"\n"
	deps, err := parse_deps_fcfg(content)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(deps), 3)
	if len(deps) != 3 {
		return
	}
	testing.expect_value(t, deps[0].name, "hexgrid")
	testing.expect_value(t, deps[0].source, Dep_Source.Registry)
	testing.expect_value(t, deps[0].value, "0.4")
	testing.expect_value(t, deps[0].hash, "sha256:1c77")
	testing.expect_value(t, deps[1].name, "shared")
	testing.expect_value(t, deps[1].source, Dep_Source.Path)
	testing.expect_value(t, deps[1].value, "../studio-shared")
	testing.expect_value(t, deps[1].hash, "")
	testing.expect_value(t, deps[2].name, "steering")
	testing.expect_value(t, deps[2].source, Dep_Source.Url)
	testing.expect_value(t, deps[2].hash, "sha256:9f3a")
}

@(test)
test_parse_deps_fcfg_empty_is_zero_deps :: proc(t: ^testing.T) {
	// deps.fcfg is optional and an empty-but-present file declares nothing —
	// only a malformed construct rejects (mirroring builds.fcfg).
	deps, err := parse_deps_fcfg("")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(deps), 0)
}

@(test)
test_parse_deps_fcfg_rejects_malformed :: proc(t: ^testing.T) {
	// Every way out of the closed `use <name> <source> "…" [hash "…"]`
	// production is the named Malformed_Deps_Fcfg reject: an unknown source
	// kind (the set is closed), a registry/url dep missing its required hash
	// (§30 §4 — the pin IS the lockfile), a hash on a path dep (the table
	// grants path deps none), a duplicate dependency name, a non-`use`
	// top-level construct, and a bare value where a string belongs.
	malformed := []string {
		"use hexgrid git \"somewhere\"\n",                                    // unknown source kind
		"use hexgrid version \"0.4\"\n",                                      // registry without hash
		"use steering url \"https://example.com/x.tar\"\n",                   // url without hash
		"use shared path \"../studio-shared\" hash \"sha256:1c77\"\n",        // hash on a path dep
		"use shared path \"../a\"\nuse shared path \"../b\"\n",               // duplicate name
		"dep hexgrid version \"0.4\" hash \"sha256:1c77\"\n",                 // non-`use` opener
		"use shared path ../studio-shared\n",                                 // bare value, not a string
	}
	for content in malformed {
		_, err := parse_deps_fcfg(content)
		testing.expect_value(t, err, Project_Error.Malformed_Deps_Fcfg)
	}
}

// ── §30 §7 scratch trees: a consumer with one path dependency ────────────

// HEXGRID_LAYOUT_FUN is the dependency's one module: a fully
// @expose'd public API (so no fixture leans on the parallel exposure-closure
// story) beside a package-private helper, plus the dependency's own inline
// test — §30 §7: the dep is compiled through the consumer's pipeline with
// the same gates, so its assertions count in the consumer's run.
HEXGRID_LAYOUT_FUN :: "@expose\n" +
	"fn axial_to_pixel(q: Int) -> Int {\n" +
	"  return q\n" +
	"}\n" +
	"fn cube_round(x: Int) -> Int {\n" +
	"  return x\n" +
	"}\n" +
	"test \"package-internal helper\" {\n" +
	"  assert cube_round(2) == 2\n" +
	"}\n"

// write_dep_scratch_tree materializes a consumer tree with one path
// dependency: the consumer's identity + deps.fcfg + a src/game.fun of the
// given content, and the dependency package under packages/<dep_name>/ with
// its own identity (project name = dep_project_name) and a single
// src/layout.fun. ok = false (logged skip) when scratch I/O fails, matching
// write_scratch_tree's sandboxed-runner degradation.
write_dep_scratch_tree :: proc(
	t: ^testing.T,
	consumer_fun: string,
	dep_name: string,
	dep_project_name: string,
	dep_layout_fun: string,
	consumer_extra_src: string = "",
) -> (
	root: string,
	ok: bool,
) {
	root = scratch_join({scratch_base(), fmt.tprintf("funpack-deps-%d", scratch_seq())})
	remove_scratch_tree(root)
	dep_root := scratch_join({root, "packages", dep_name})
	wrote := write_scratch_file(scratch_join({root, "funpack_configs", "project.fcfg"}), "project consumer { version = \"0.1.0\" }\n")
	wrote &&= write_scratch_file(
		scratch_join({root, "funpack_configs", "deps.fcfg"}),
		fmt.tprintf("use %s path \"packages/%s\"\n", dep_name, dep_name),
	)
	wrote &&= write_scratch_file(scratch_join({root, "src", "game.fun"}), consumer_fun)
	if consumer_extra_src != "" {
		wrote &&= write_scratch_file(scratch_join({root, "src", consumer_extra_src}), "@doc(\"shadow\")\n")
	}
	wrote &&= write_scratch_file(
		scratch_join({dep_root, "funpack_configs", "project.fcfg"}),
		fmt.tprintf("project %s { version = \"0.4.0\" }\n", dep_project_name),
	)
	wrote &&= write_scratch_file(scratch_join({dep_root, "src", "layout.fun"}), dep_layout_fun)
	if !wrote {
		remove_scratch_tree(root)
		log.warnf("SKIP deps scratch tree: cannot write under %s", root)
		return "", false
	}
	return root, true
}

// write_scratch_file writes one file, creating its interior directories.
write_scratch_file :: proc(path: string, content: string) -> bool {
	if os.make_directory_all(filepath.dir(path)) != nil {
		return false
	}
	return os.write_entire_file(path, transmute([]u8)content) == nil
}

@(test)
test_path_dep_resolves_under_project_name_root :: proc(t: ^testing.T) {
	// AC: a path-source package resolves with the PROJECT NAME as root
	// namespace — the dependency's module enters the build as
	// `hexgrid.layout` with package_root stamped, the consumer's
	// `import hexgrid.layout.{axial_to_pixel}` resolves across the edge, and
	// the full project walk (consumer + dependency, one index) runs both
	// modules' assertions green.
	consumer := "import hexgrid.layout.{axial_to_pixel}\n" +
		"test \"imports under the dependency's root namespace\" {\n" +
		"  assert axial_to_pixel(3) == 3\n" +
		"}\n"
	root, ok := write_dep_scratch_tree(t, consumer, "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, len(project.deps), 1)
	testing.expect_value(t, len(project.package_sources), 1)
	if len(project.package_sources) == 1 {
		testing.expect_value(t, project.package_sources[0].module, "hexgrid.layout")
		testing.expect_value(t, project.package_sources[0].package_root, "hexgrid")
	}
	// The consumer's own sources stay unprefixed and unstamped.
	testing.expect_value(t, len(project.sources), 1)
	if len(project.sources) == 1 {
		testing.expect_value(t, project.sources[0].module, "game")
		testing.expect_value(t, project.sources[0].package_root, "")
	}

	report := run_project_pipeline(project_pipeline_sources(project))
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	// Both the consumer's assertion and the dependency's own inline test
	// counted — the dep rides the same pipeline (§30 §7).
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_path_dep_private_member_fails_project_walk :: proc(t: ^testing.T) {
	// The §30 §6 edge holds through the full tree walk: the consumer
	// importing the dependency's package-private helper is a compile error
	// (the resolver's named .Package_Private verdict, surfaced as the
	// consumer module's Typecheck_Failed — never a counted test failure).
	consumer := "import hexgrid.layout.{cube_round}\n" +
		"test \"private member refused\" {\n" +
		"  assert cube_round(2) == 2\n" +
		"}\n"
	root, ok := write_dep_scratch_tree(t, consumer, "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	if err != .None {
		return
	}
	report := run_project_pipeline(project_pipeline_sources(project))
	testing.expect_value(t, report.module_err, Pipeline_Error.Typecheck_Failed)
}

// ── the two named refusals (AC: dep-imports-dep + engine-root collision) ──

@(test)
test_dep_imports_dep_structural_refusal :: proc(t: ^testing.T) {
	// AC: the §30 §2 star-graph violation, structurally — a path dependency
	// whose OWN tree declares dependencies is refused with the NAMED
	// Package_Imports_Package verdict: a package depends only on engine; the
	// graph is depth-1, always.
	root, ok := write_dep_scratch_tree(t, "@doc(\"consumer\")\n", "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	dep_deps := scratch_join({root, "packages", "hexgrid", "funpack_configs", "deps.fcfg"})
	if !write_scratch_file(dep_deps, "use steering path \"../steering\"\n") {
		log.warnf("SKIP dep-imports-dep: cannot write %s", dep_deps)
		return
	}

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Package_Imports_Package)
}

@(test)
test_package_named_like_engine_root_refused :: proc(t: ^testing.T) {
	// AC: a package whose project name is the reserved `engine` root is
	// refused with the NAMED Package_Shadows_Engine_Root verdict — the
	// package name joins `engine` as a root namespace (§30 §7) and reserved
	// roots are unshadowable (§15 §7).
	root, ok := write_dep_scratch_tree(t, "@doc(\"consumer\")\n", "engine", "engine", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Package_Shadows_Engine_Root)
}

@(test)
test_local_module_shadowing_dep_root_refused :: proc(t: ^testing.T) {
	// §30 §7's consumer-side half: a local src/hexgrid.fun beside a declared
	// `use hexgrid` dependency shadows the dependency's root namespace — the
	// named Module_Shadows_Package_Root compile error.
	root, ok := write_dep_scratch_tree(t, "@doc(\"consumer\")\n", "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN, "hexgrid.fun")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Module_Shadows_Package_Root)
}

@(test)
test_dep_name_mismatch_refused :: proc(t: ^testing.T) {
	// The deps.fcfg label IS the package identity (§14 §4): a `use hexgrid`
	// whose tree declares `project hexgrove` is the same label/identity
	// drift class §30 §4 refuses for hashes — the named Dep_Name_Mismatch.
	root, ok := write_dep_scratch_tree(t, "@doc(\"consumer\")\n", "hexgrid", "hexgrove", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Dep_Name_Mismatch)
}

@(test)
test_path_dep_with_entrypoint_is_not_a_package :: proc(t: ^testing.T) {
	// §30 §7's structural definition: a game RUNS (has entrypoints.fcfg), a
	// package is IMPORTED (has none) — a path dependency carrying an
	// entrypoint is a game, and depending on a game is the named
	// Malformed_Package_Tree refusal.
	root, ok := write_dep_scratch_tree(t, "@doc(\"consumer\")\n", "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	dep_entry := scratch_join({root, "packages", "hexgrid", "funpack_configs", "entrypoints.fcfg"})
	if !write_scratch_file(dep_entry, "use layout.{axial_to_pixel}\n") {
		log.warnf("SKIP entrypointed dep: cannot write %s", dep_entry)
		return
	}

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Malformed_Package_Tree)
}

@(test)
test_path_dep_missing_tree_refused :: proc(t: ^testing.T) {
	// A declared path that holds no package tree (no funpack_configs) is the
	// named Malformed_Package_Tree refusal, never a silent skip.
	root, ok := write_scratch_tree(t, "project consumer { version = \"0.1.0\" }\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	deps_path := scratch_join({root, "funpack_configs", "deps.fcfg"})
	if !write_scratch_file(deps_path, "use hexgrid path \"packages/hexgrid\"\n") {
		log.warnf("SKIP missing dep tree: cannot write %s", deps_path)
		return
	}

	_, err := read_project(root)
	testing.expect_value(t, err, Project_Error.Malformed_Package_Tree)
}

// ── the import-level star graph (in-memory, the resolver's vantage) ──────

// two_package_index builds a consumer-side index carrying one consumer
// module (`game`) and two §30 dependencies (`alpha.lib`, `beta.util`), every
// export @expose'd so the star verdicts below are visibility-independent.
two_package_index :: proc(t: ^testing.T) -> Module_Index {
	game_ast, game_err := stage_parse(stage_lex("fn tick(x: Int) -> Int {\n  return x\n}\n"))
	testing.expect_value(t, game_err, Parse_Error.None)
	alpha_ast, alpha_err := stage_parse(stage_lex("@expose\nfn alpha_fn(x: Int) -> Int {\n  return x\n}\nfn alpha_private(x: Int) -> Int {\n  return x\n}\n"))
	testing.expect_value(t, alpha_err, Parse_Error.None)
	beta_ast, beta_err := stage_parse(stage_lex("@expose\nfn beta_fn(x: Int) -> Int {\n  return x\n}\n"))
	testing.expect_value(t, beta_err, Parse_Error.None)
	return build_module_index_typed(
		{"game", "alpha.lib", "beta.util"},
		{game_ast, alpha_ast, beta_ast},
		{"", "alpha", "beta"},
	)
}

@(test)
test_package_importing_other_package_refused :: proc(t: ^testing.T) {
	// AC: the §30 §2 star-graph violation at the IMPORT level — a module
	// inside package alpha importing package beta's (even @expose'd) surface
	// is the NAMED .Package_Imports_Package verdict, never a resolve. The
	// expose gate is irrelevant here: the edge alpha→beta does not exist in
	// the star, exposed or not.
	index := two_package_index(t)
	forms := []string {
		"import beta.util.{beta_fn}\n", // member group
		"import beta.util\n",           // whole-module handle
		"import beta.util.beta_fn\n",   // dotted single member
	}
	for source in forms {
		ast, parse_err := stage_parse(stage_lex(source))
		testing.expect_value(t, parse_err, Parse_Error.None)
		_, err := resolve_imports_indexed(ast, index, "alpha")
		testing.expect_value(t, err, Type_Error.Package_Imports_Package)
	}
}

@(test)
test_package_importing_consumer_module_refused :: proc(t: ^testing.T) {
	// A package importing the consuming game's own module is the same §30 §2
	// refusal: a package depends only on engine — the hub's modules are not
	// in its namespace.
	index := two_package_index(t)
	ast, parse_err := stage_parse(stage_lex("import game.{tick}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports_indexed(ast, index, "alpha")
	testing.expect_value(t, err, Type_Error.Package_Imports_Package)
}

@(test)
test_package_internal_import_resolves_unprefixed_without_gate :: proc(t: ^testing.T) {
	// §15 §5: within the package, modules root UNPREFIXED at the package's
	// own source root — `import lib.{alpha_private}` from inside alpha maps
	// onto the consumer index's `alpha.lib` entry, and crossing NO edge it
	// never consults @expose (the package-private helper resolves).
	index := two_package_index(t)
	ast, parse_err := stage_parse(stage_lex("import lib.{alpha_private}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports_indexed(ast, index, "alpha")
	testing.expect_value(t, err, Type_Error.None)
	binding, bound := bindings.names["alpha_private"]
	testing.expect(t, bound)
	if bound {
		testing.expect_value(t, binding.module, "alpha.lib")
	}
}

@(test)
test_package_self_prefixed_import_unknown :: proc(t: ^testing.T) {
	// From INSIDE alpha, `import alpha.lib.{…}` names a module that does not
	// exist: the project name is not a namespace prefix within the project
	// (§15 §5) — the prefixed entry is the OUTSIDE view. .Unknown_Module,
	// never a star verdict against itself.
	index := two_package_index(t)
	ast, parse_err := stage_parse(stage_lex("import alpha.lib.{alpha_fn}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports_indexed(ast, index, "alpha")
	testing.expect_value(t, err, Type_Error.Unknown_Module)
}

@(test)
test_consumer_vantage_unchanged_by_star_arm :: proc(t: ^testing.T) {
	// The consumer ("" vantage, the default) keeps the wave-1 behavior
	// byte-for-byte: a package's @expose'd surface resolves, its private
	// surface is .Package_Private — never a star verdict (the game→package
	// edge IS the star).
	index := two_package_index(t)
	ok_ast, ok_parse := stage_parse(stage_lex("import alpha.lib.{alpha_fn}\n"))
	testing.expect_value(t, ok_parse, Parse_Error.None)
	_, ok_err := resolve_imports_indexed(ok_ast, index)
	testing.expect_value(t, ok_err, Type_Error.None)

	private_ast, private_parse := stage_parse(stage_lex("import alpha.lib.{alpha_private}\n"))
	testing.expect_value(t, private_parse, Parse_Error.None)
	_, private_err := resolve_imports_indexed(private_ast, index)
	testing.expect_value(t, private_err, Type_Error.Package_Private)
}
