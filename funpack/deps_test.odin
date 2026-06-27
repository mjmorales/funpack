package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_parse_deps_fcfg_all_three_sources :: proc(t: ^testing.T) {
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
	deps, err := parse_deps_fcfg("")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(deps), 0)
}

@(test)
test_parse_deps_fcfg_rejects_malformed :: proc(t: ^testing.T) {
	malformed := []string {
		"use hexgrid git \"somewhere\"\n",
		"use hexgrid version \"0.4\"\n",
		"use steering url \"https://example.com/x.tar\"\n",
		"use shared path \"../studio-shared\" hash \"sha256:1c77\"\n",
		"use shared path \"../a\"\nuse shared path \"../b\"\n",
		"dep hexgrid version \"0.4\" hash \"sha256:1c77\"\n",
		"use shared path ../studio-shared\n",
	}
	for content in malformed {
		_, err := parse_deps_fcfg(content)
		testing.expect_value(t, err, Project_Error.Malformed_Deps_Fcfg)
	}
}

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
		project_fcfg_for(dep_project_name),
	)
	wrote &&= write_scratch_file(scratch_join({dep_root, "src", "layout.fun"}), dep_layout_fun)
	if !wrote {
		remove_scratch_tree(root)
		log.warnf("SKIP deps scratch tree: cannot write under %s", root)
		return "", false
	}
	return root, true
}

project_fcfg_for :: proc(project_name: string) -> string {
	return strings.concatenate(
		{"project ", project_name, " { version = \"0.4.0\" }\n"},
		context.temp_allocator,
	)
}

write_scratch_file :: proc(path: string, content: string) -> bool {
	dir := filepath.dir(path)
	if !os.is_dir(dir) && os.make_directory_all(dir) != nil {
		return false
	}
	return os.write_entire_file(path, transmute([]u8)content) == nil
}

@(test)
test_path_dep_resolves_under_project_name_root :: proc(t: ^testing.T) {
	consumer := "import hexgrid.layout.{axial_to_pixel}\n" +
		"test \"imports under the dependency's root namespace\" {\n" +
		"  assert axial_to_pixel(3) == 3\n" +
		"}\n"
	root, ok := write_dep_scratch_tree(t, consumer, "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err, _ := read_project(root)
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
	testing.expect_value(t, len(project.sources), 1)
	if len(project.sources) == 1 {
		testing.expect_value(t, project.sources[0].module, "game")
		testing.expect_value(t, project.sources[0].package_root, "")
	}

	report := run_project_pipeline(project_pipeline_sources(project))
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_path_dep_fn_in_combinator_slot :: proc(t: ^testing.T) {
	consumer := "import engine.list.{map, contains}\n" +
		"import hexgrid.layout.{axial_to_pixel}\n" +
		"test \"imported fn rides the combinator slot\" {\n" +
		"  assert contains(map([3, 4], axial_to_pixel), 4)\n" +
		"}\n"
	root, ok := write_dep_scratch_tree(t, consumer, "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	if err != .None {
		return
	}
	report := run_project_pipeline(project_pipeline_sources(project))
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_path_dep_checks_builds_and_indexes :: proc(t: ^testing.T) {
	consumer := "import hexgrid.layout.{axial_to_pixel}\n" +
		"fn double_pixel(q: Int) -> Int {\n" +
		"  return axial_to_pixel(q) + axial_to_pixel(q)\n" +
		"}\n"
	root, ok := write_dep_scratch_tree(t, consumer, "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	testing.expect(t, strings.contains(product.index, `"qualified_name":"game.double_pixel"`))
	testing.expect(t, strings.contains(product.index, `"qualified_name":"hexgrid.layout.axial_to_pixel"`))
	testing.expect_value(t, run_check_verb(root, .Dev), 0)
}

@(test)
test_path_dep_hole_refuses_release_build :: proc(t: ^testing.T) {
	holed_dep := "@expose\n" +
		"fn axial_to_pixel(q: Int) -> Int @stub(Int)\n"
	root, ok := write_dep_scratch_tree(t, "@doc(\"consumer\")\n", "hexgrid", "hexgrid", holed_dep)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Holed_Declaration)
	testing.expect(t, strings.contains(verdict.offender, "hexgrid.layout"))
}

@(test)
test_path_dep_private_member_fails_project_walk :: proc(t: ^testing.T) {
	consumer := "import hexgrid.layout.{cube_round}\n" +
		"test \"private member refused\" {\n" +
		"  assert cube_round(2) == 2\n" +
		"}\n"
	root, ok := write_dep_scratch_tree(t, consumer, "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	if err != .None {
		return
	}
	report := run_project_pipeline(project_pipeline_sources(project))
	testing.expect_value(t, report.module_err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_dep_imports_dep_structural_refusal :: proc(t: ^testing.T) {
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

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Package_Imports_Package)
}

@(test)
test_package_named_like_engine_root_refused :: proc(t: ^testing.T) {
	root, ok := write_dep_scratch_tree(t, "@doc(\"consumer\")\n", "engine", "engine", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Package_Shadows_Engine_Root)
}

@(test)
test_local_module_shadowing_dep_root_refused :: proc(t: ^testing.T) {
	root, ok := write_dep_scratch_tree(t, "@doc(\"consumer\")\n", "hexgrid", "hexgrid", HEXGRID_LAYOUT_FUN, "hexgrid.fun")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Module_Shadows_Package_Root)
}

@(test)
test_dep_name_mismatch_refused :: proc(t: ^testing.T) {
	root, ok := write_dep_scratch_tree(t, "@doc(\"consumer\")\n", "hexgrid", "hexgrove", HEXGRID_LAYOUT_FUN)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, detail := read_project(root)
	testing.expect_value(t, err, Project_Error.Dep_Name_Mismatch)
	testing.expect(t, strings.contains(detail, "hexgrid"))
	testing.expect(t, strings.contains(detail, "hexgrove"))
}

@(test)
test_path_dep_with_entrypoint_is_not_a_package :: proc(t: ^testing.T) {
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

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Malformed_Package_Tree)
}

@(test)
test_path_dep_missing_tree_refused :: proc(t: ^testing.T) {
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

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Malformed_Package_Tree)
}

PLACEHOLDER_PIN :: "use hexgrid version \"0.4\" hash \"sha256:dead\"\n"

write_pinned_dep_scratch_tree :: proc(t: ^testing.T, deps_fcfg: string, vendor_name: string = "") -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), fmt.tprintf("funpack-deps-%d", scratch_seq())})
	remove_scratch_tree(root)
	wrote := write_scratch_file(scratch_join({root, "funpack_configs", "project.fcfg"}), "project consumer { version = \"0.1.0\" }\n")
	wrote &&= write_scratch_file(scratch_join({root, "funpack_configs", "deps.fcfg"}), deps_fcfg)
	wrote &&= write_scratch_file(scratch_join({root, "src", "game.fun"}), "fn tick(x: Int) -> Int {\n  return x\n}\n")
	if vendor_name != "" {
		dep_root := scratch_join({root, "packages", vendor_name})
		wrote &&= write_scratch_file(
			scratch_join({dep_root, "funpack_configs", "project.fcfg"}),
			project_fcfg_for(vendor_name),
		)
		wrote &&= write_scratch_file(scratch_join({dep_root, "src", "layout.fun"}), HEXGRID_LAYOUT_FUN)
	}
	if !wrote {
		remove_scratch_tree(root)
		log.warnf("SKIP pinned-dep scratch tree: cannot write under %s", root)
		return "", false
	}
	return root, true
}

repin_deps_fcfg :: proc(root: string, dep_name: string, hash: string) -> bool {
	return write_scratch_file(
		scratch_join({root, "funpack_configs", "deps.fcfg"}),
		fmt.tprintf("use %s version \"0.4\" hash \"%s\"\n", dep_name, hash),
	)
}

@(test)
test_vendored_pin_match_builds_clean :: proc(t: ^testing.T) {
	root, ok := write_pinned_dep_scratch_tree(t, PLACEHOLDER_PIN, "hexgrid")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	actual, hashed := hash_vendored_tree(vendored_package_dir(root, "hexgrid"))
	testing.expect(t, hashed)
	if !hashed {
		return
	}
	if !repin_deps_fcfg(root, "hexgrid", actual) {
		log.warnf("SKIP pin match: cannot rewrite deps.fcfg under %s", root)
		return
	}

	project, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, len(project.deps), 1)
	testing.expect_value(t, len(project.package_sources), 0)

	_, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
}

@(test)
test_vendored_pin_mismatch_refused_with_fix_it :: proc(t: ^testing.T) {
	root, ok := write_pinned_dep_scratch_tree(t, PLACEHOLDER_PIN, "hexgrid")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, detail := read_project(root)
	testing.expect_value(t, err, Project_Error.Package_Hash_Mismatch)
	testing.expect(t, strings.contains(detail, "re-pin"))

	_, build_verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, build_verdict.err, Build_Error.Malformed_Tree)
	build_message := build_refusal_message(build_verdict, context.temp_allocator)
	testing.expect(t, strings.contains(build_message, "Package_Hash_Mismatch"))
	testing.expect(t, strings.contains(build_message, "re-pin"))

	verify_err, fix_it := verify_vendored_deps(
		root,
		[]Dep{{name = "hexgrid", source = .Registry, value = "0.4", hash = "sha256:dead"}},
	)
	testing.expect_value(t, verify_err, Project_Error.Package_Hash_Mismatch)
	actual, hashed := hash_vendored_tree(vendored_package_dir(root, "hexgrid"))
	testing.expect(t, hashed)
	if hashed {
		testing.expect(t, strings.contains(fix_it, actual))
	}
	testing.expect(t, strings.contains(fix_it, "sha256:dead"))
	testing.expect(t, strings.contains(fix_it, "re-pin"))
}

@(test)
test_vendored_pin_exact_match_discipline :: proc(t: ^testing.T) {
	root, ok := write_pinned_dep_scratch_tree(t, PLACEHOLDER_PIN, "hexgrid")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	actual, hashed := hash_vendored_tree(vendored_package_dir(root, "hexgrid"))
	testing.expect(t, hashed)
	if !hashed {
		return
	}

	partial_pins := []string{actual[:len(actual) - 8], strings.to_upper(actual, context.temp_allocator)}
	for pin in partial_pins {
		if !repin_deps_fcfg(root, "hexgrid", pin) {
			log.warnf("SKIP exact-match discipline: cannot rewrite deps.fcfg under %s", root)
			return
		}
		_, err, _ := read_project(root)
		testing.expect_value(t, err, Project_Error.Package_Hash_Mismatch)
	}
}

@(test)
test_pinned_dep_missing_vendored_tree_refused :: proc(t: ^testing.T) {
	root, ok := write_pinned_dep_scratch_tree(
		t,
		"use steering url \"https://example.com/steering-2.0.tar\" hash \"sha256:9f3a\"\n",
	)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Missing_Vendored_Package)

	verify_err, fix_it := verify_vendored_deps(
		root,
		[]Dep{{name = "steering", source = .Url, value = "https://example.com/steering-2.0.tar", hash = "sha256:9f3a"}},
	)
	testing.expect_value(t, verify_err, Project_Error.Missing_Vendored_Package)
	testing.expect(t, strings.contains(fix_it, "packages/steering"))
	testing.expect(t, strings.contains(fix_it, "never fetch"))
}

@(test)
test_path_dep_never_hash_verified :: proc(t: ^testing.T) {
	err, fix_it := verify_vendored_deps(
		"/nonexistent-funpack-root",
		[]Dep{{name = "shared", source = .Path, value = "../studio-shared"}},
	)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, fix_it, "")
}

@(test)
test_hash_vendored_tree_deterministic_and_content_sensitive :: proc(t: ^testing.T) {
	root, ok := write_pinned_dep_scratch_tree(t, PLACEHOLDER_PIN, "hexgrid")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	dir := vendored_package_dir(root, "hexgrid")

	first, ok_first := hash_vendored_tree(dir)
	second, ok_second := hash_vendored_tree(dir)
	testing.expect(t, ok_first)
	testing.expect(t, ok_second)
	testing.expect_value(t, first, second)
	testing.expect(t, strings.has_prefix(first, HASH_PREFIX))

	if !write_scratch_file(scratch_join({root, "packages", "hexgrid", "src", "layout.fun"}), "fn tampered(x: Int) -> Int {\n  return x\n}\n") {
		log.warnf("SKIP hash sensitivity: cannot rewrite vendored source under %s", root)
		return
	}
	content_changed, ok_changed := hash_vendored_tree(dir)
	testing.expect(t, ok_changed)
	testing.expect(t, content_changed != first)

	if !write_scratch_file(scratch_join({root, "packages", "hexgrid", "src", "extra.fun"}), "@doc(\"added\")\n") {
		log.warnf("SKIP hash sensitivity: cannot add vendored source under %s", root)
		return
	}
	structure_changed, ok_structure := hash_vendored_tree(dir)
	testing.expect(t, ok_structure)
	testing.expect(t, structure_changed != content_changed)
}

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
	index := two_package_index(t)
	forms := []string {
		"import beta.util.{beta_fn}\n",
		"import beta.util\n",
		"import beta.util.beta_fn\n",
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
	index := two_package_index(t)
	ast, parse_err := stage_parse(stage_lex("import game.{tick}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports_indexed(ast, index, "alpha")
	testing.expect_value(t, err, Type_Error.Package_Imports_Package)
}

@(test)
test_package_internal_import_resolves_unprefixed_without_gate :: proc(t: ^testing.T) {
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
	index := two_package_index(t)
	ast, parse_err := stage_parse(stage_lex("import alpha.lib.{alpha_fn}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports_indexed(ast, index, "alpha")
	testing.expect_value(t, err, Type_Error.Unknown_Module)
}

@(test)
test_consumer_vantage_unchanged_by_star_arm :: proc(t: ^testing.T) {
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
