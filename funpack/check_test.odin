package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
test_check_clean_tree_exits_zero_no_products :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("check clean: a clean tree adjudicates exit 0 and no .funpack/ is created (the verdict-only verb)")
}

@(test)
test_check_compile_error_exits_two :: proc(t: ^testing.T) {
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, run_check_verb(root, .Dev), 2)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("check compile error: the broken tree refuses exit 2 (never a counted failure) and writes nothing")
}

@(test)
test_check_runs_structural_gates_on_a_package :: proc(t: ^testing.T) {
	root := scratch_join({scratch_base(), tprintf_seq("funpack-check-gate-pkg")})
	remove_scratch_tree(root)
	defer remove_scratch_tree(root)
	nested :=
		"fn corridors_for(a: Int, b: Int, c: Int, d: Int, e: Int) -> Int {\n" +
		"  return if a > 0 {\n    if b > 0 {\n      if c > 0 {\n        if d > 0 {\n" +
		"          if e > 0 { 1 } else { 2 }\n        } else { 3 }\n      } else { 4 }\n" +
		"    } else { 5 }\n  } else { 6 }\n}\n"
	ok := write_scratch_file(scratch_join({root, "funpack_configs", "project.fcfg"}), "project pkg {\n  version = \"0.1.0\"\n}\n")
	ok &&= write_scratch_file(scratch_join({root, "src", "pkg.fun"}), nested)
	if !ok {
		log.warnf("SKIP check structural-gate package: cannot write under %s", root)
		return
	}
	testing.expect_value(t, run_check_verb(root, .Dev), 2)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("check structural gate: a package module overshooting §01 P5 refuses exit 2 — no longer a false green vs test")
}

@(test)
test_check_malformed_tree_exits_two :: proc(t: ^testing.T) {
	root := scratch_join({scratch_base(), tprintf_seq("funpack-check-malformed")})
	remove_scratch_tree(root)
	if !ensure_dir(root) {
		log.warnf("SKIP check malformed tree: cannot create %s", root)
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, run_check_verb(root, .Dev), 2)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
}

@(test)
test_check_holed_tree_dev_zero_release_two :: proc(t: ^testing.T) {
	root, ok := write_holed_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect_value(t, run_check_verb(root, .Release), 2)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("check hole-ban: the holed tree is exit 0 in dev and exit 2 under --release, with nothing written either way")
}

@(test)
test_check_probed_tree_dev_zero_release_two :: proc(t: ^testing.T) {
	root, ok := write_probed_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect_value(t, run_check_verb(root, .Release), 2)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("check debug ban: the probed tree is exit 0 in dev and exit 2 under --release, with nothing written either way")
}

@(test)
test_check_preexisting_funpack_untouched :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	stale_artifact :: "stale artifact bytes a build would never emit\n"
	stale_index :: "stale index bytes a build would never emit\n"
	build_dir := scratch_join({root, FUNPACK_BUILD_DIR})
	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	if !ensure_dir(build_dir) ||
	   os.write_entire_file(artifact_path, transmute([]u8)string(stale_artifact)) != nil ||
	   os.write_entire_file(index_path, transmute([]u8)string(stale_index)) != nil {
		log.warnf("SKIP check pre-existing .funpack: cannot materialize stale products under %s", build_dir)
		return
	}

	testing.expect_value(t, run_check_verb(root, .Dev), 0)

	artifact_after, artifact_err := os.read_entire_file_from_path(artifact_path, context.temp_allocator)
	testing.expect(t, artifact_err == nil)
	index_after, index_err := os.read_entire_file_from_path(index_path, context.temp_allocator)
	testing.expect(t, index_err == nil)
	if artifact_err != nil || index_err != nil {
		return
	}
	testing.expect_value(t, string(artifact_after), stale_artifact)
	testing.expect_value(t, string(index_after), stale_index)
	log.infof("check no-write: a pre-existing .funpack/ survives a clean check byte-untouched (neither overwritten nor deleted)")
}

write_project_under :: proc(parent: string, name: string, source: string) -> (root: string, ok: bool) {
	root = scratch_join({parent, name})
	configs := scratch_join({root, "funpack_configs"})
	src_path := scratch_join({root, "src", "mini.fun"})
	if !ensure_dir(configs) || !ensure_dir(scratch_join({root, "src"})) {
		return "", false
	}
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project mini {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		os.write_entire_file(src_path, source) == nil
	return root, ok_writes
}

write_games_tree :: proc(label: string, names: []string, bad: string) -> (parent: string, ok: bool) {
	parent = scratch_join({scratch_base(), tprintf_seq(fmt.tprintf("funpack-check-games-%s", label))})
	remove_scratch_tree(parent)
	if !ensure_dir(parent) {
		return "", false
	}
	for name in names {
		source := MINI_SOURCE
		if name == bad {
			source = "fn broken( {\n"
		}
		if _, wrote := write_project_under(parent, name, source); !wrote {
			remove_scratch_tree(parent)
			return "", false
		}
	}
	noise_ok :=
		ensure_dir(scratch_join({parent, ".git", "funpack_configs"})) &&
		ensure_dir(scratch_join({parent, FUNPACK_BUILD_DIR, "funpack_configs"}))
	if len(names) > 0 {
		if _, wrote := write_project_under(scratch_join({parent, names[0], "src"}), "nested", MINI_SOURCE); !wrote {
			noise_ok = false
		}
	}
	if !noise_ok {
		remove_scratch_tree(parent)
		return "", false
	}
	return parent, true
}

@(test)
test_check_recursive_discovers_every_project :: proc(t: ^testing.T) {
	names := []string{"alpha", "beta", "gamma"}
	parent, ok := write_games_tree("discover", names, "")
	if !ok {
		log.warnf("SKIP check recursive discover: cannot materialize games tree")
		return
	}
	defer remove_scratch_tree(parent)

	roots := discover_project_roots(parent, context.temp_allocator)
	testing.expect_value(t, len(roots), len(names))
	expected := slice.clone(names, context.temp_allocator)
	slice.sort(expected)
	for want, i in expected {
		testing.expect_value(t, filepath.base(roots[i]), want)
	}
	log.infof("check recursive discover: %d sibling projects discovered, nested + .git/.funpack pruned", len(roots))
}

@(test)
test_check_recursive_prunes_the_vendor_dir :: proc(t: ^testing.T) {
	parent, ok := write_games_tree("vendor", []string{"game"}, "")
	if !ok {
		log.warnf("SKIP check recursive vendor-prune: cannot materialize games tree")
		return
	}
	defer remove_scratch_tree(parent)
	if _, wrote := write_project_under(scratch_join({parent, VENDOR_DIR}), "dep", MINI_SOURCE); !wrote {
		log.warnf("SKIP check recursive vendor-prune: cannot materialize vendored dep")
		return
	}

	roots := discover_project_roots(parent, context.temp_allocator)
	testing.expect_value(t, len(roots), 1)
	testing.expect_value(t, filepath.base(roots[0]), "game")
	for r in roots {
		testing.expect(t, !strings.contains(r, VENDOR_DIR), "no discovered root lives under the packages/ vendor dir")
	}
	log.infof("check recursive vendor-prune: packages/<dep> not double-counted, sibling game discovered")
}

@(test)
test_check_recursive_clean_tree_exits_zero :: proc(t: ^testing.T) {
	names := []string{"alpha", "beta", "gamma"}
	parent, ok := write_games_tree("clean", names, "")
	if !ok {
		log.warnf("SKIP check recursive clean: cannot materialize games tree")
		return
	}
	defer remove_scratch_tree(parent)

	roots := discover_project_roots(parent, context.temp_allocator)
	output, failed := check_recursive_report(roots, .Dev, context.temp_allocator)
	testing.expect_value(t, failed, 0)
	testing.expect(t, strings.contains(output, "funpack check: 3 projects, 3 clean, 0 failed"))
	for name in names {
		testing.expect(t, strings.contains(output, strings.concatenate({filepath.SEPARATOR_STRING, name, ": clean"}, context.temp_allocator)))
	}
	testing.expect_value(t, run_check_recursive_verb(parent, .Dev), 0)
	for name in names {
		testing.expect(t, !os.exists(scratch_join({parent, name, FUNPACK_BUILD_DIR})))
	}
	log.infof("check recursive clean: %d-project sweep exits 0 with a deterministic summary and no products", len(names))
}

@(test)
test_check_recursive_failing_tree_exits_two_names_it :: proc(t: ^testing.T) {
	names := []string{"alpha", "beta", "gamma"}
	bad := "beta"
	parent, ok := write_games_tree("failing", names, bad)
	if !ok {
		log.warnf("SKIP check recursive failing: cannot materialize games tree")
		return
	}
	defer remove_scratch_tree(parent)

	roots := discover_project_roots(parent, context.temp_allocator)
	output, failed := check_recursive_report(roots, .Dev, context.temp_allocator)
	testing.expect_value(t, failed, 1)
	testing.expect(t, strings.contains(output, strings.concatenate({filepath.SEPARATOR_STRING, bad, ": failed"}, context.temp_allocator)))
	testing.expect(t, strings.contains(output, strings.concatenate({filepath.SEPARATOR_STRING, "alpha", ": clean"}, context.temp_allocator)))
	testing.expect(t, strings.contains(output, "funpack check: 3 projects, 2 clean, 1 failed"))
	testing.expect_value(t, run_check_recursive_verb(parent, .Dev), 2)
	log.infof("check recursive failing: the sweep exits 2 and NAMES %s, clean siblings still report clean", bad)
}

@(test)
test_check_recursive_no_project_root_exits_two :: proc(t: ^testing.T) {
	empty := scratch_join({scratch_base(), tprintf_seq("funpack-check-recursive-empty")})
	remove_scratch_tree(empty)
	if !ensure_dir(scratch_join({empty, "just", "some", "dirs"})) {
		log.warnf("SKIP check recursive empty: cannot create %s", empty)
		return
	}
	defer remove_scratch_tree(empty)

	testing.expect_value(t, len(discover_project_roots(empty, context.temp_allocator)), 0)
	testing.expect_value(t, run_check_recursive_verb(empty, .Dev), 2)
	log.infof("check recursive empty: a project-less root sweeps to exit 2, never a silent no-op")
}

@(test)
test_check_recursive_root_is_project_exits_zero :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	if _, wrote := write_project_under(scratch_join({root, "src"}), "nested", MINI_SOURCE); !wrote {
		log.warnf("SKIP check recursive root-is-project: cannot write nested project")
		return
	}

	roots := discover_project_roots(root, context.temp_allocator)
	testing.expect_value(t, len(roots), 1)
	testing.expect_value(t, filepath.base(roots[0]), filepath.base(root))
	testing.expect_value(t, run_check_recursive_verb(root, .Dev), 0)
	log.infof("check recursive root-is-project: the root project is the whole answer, no nested descent")
}

@(test)
test_golden_check_numerics_clean_exits_zero :: proc(t: ^testing.T) {
	root, ok := copy_spec_tree_to_temp(resolve_golden_dir(), "check-numerics", "FUNPACK_NUMERICS_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("golden check numerics: the live clean tree adjudicates exit 0 with no .funpack/ created")
}

@(test)
test_golden_check_drift_dev_zero_release_two :: proc(t: ^testing.T) {
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "check-drift", "FUNPACK_DRIFT_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect_value(t, run_check_verb(root, .Release), 2)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("golden check drift: the live holed tree is exit 0 in dev, exit 2 under --release, nothing written")
}
