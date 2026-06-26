// The check-verb integration tests: `funpack check` (main.odin run_check_verb)
// is build's verdict with the write deleted (spec §29 §3), so every test here
// asserts BOTH halves of that contract — the exit tier (0 clean, 2 for any
// Build_Error arm, never 1) AND the no-write floor (no `.funpack/` appears, a
// pre-existing `.funpack/` stays byte-untouched). They mirror build_test.odin's
// temp-tree patterns: hand-materialized trees for the refusal tiers, and the
// live numerics (clean, FUNPACK_NUMERICS_DIR) and drift (holed,
// FUNPACK_DRIFT_DIR) spec examples as the goldens, resolved via the
// resolve_spec_dir env-override/SKIP-warn protocol — a skipped golden warns
// loudly, never silently passes.
package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

// test_check_clean_tree_exits_zero_no_products is the §29 §3 success outcome:
// a clean tree adjudicates exit 0 and check writes NOTHING — no `.funpack/`
// exists afterward, because the verb discards the computed product bytes and
// never reaches a write.
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

// test_check_compile_error_exits_two covers the compile floor: a
// deliberately-broken source on an otherwise-valid §14 tree refuses with exit 2
// (Compile_Failed mapped through the verb), never 1 — a compile error is never
// a counted failure — and still writes nothing.
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

// test_check_runs_structural_gates_on_a_package pins the check/test gate-agreement
// floor: a §01 P5 structural gate a module overshoots (here a deep-nesting fn past
// the ceiling of 3) must refuse check exit 2, not pass it. The case is a PACKAGE
// (no entrypoints.fcfg, so stage_build emits no artifact and the emit-path gate
// never runs) — exactly where check was a FALSE GREEN: it returned 0 while
// `funpack test` rejected the same source on Nesting_Exceeded. With stage_build's
// per-module gate pass, check now agrees with test. Nothing is written on refusal.
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

// test_check_malformed_tree_exits_two covers the tree floor: a root with no
// funpack_configs/ is rejected by read_project (Malformed_Tree), so check
// refuses with exit 2 — the same no-product refusal tier as a compile error.
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

// test_check_holed_tree_dev_zero_release_two is the §29 §4 hole-ban through the
// check verb: the SAME holed tree adjudicates exit 0 in Dev (a hole is a
// first-class dev citizen) and refuses exit 2 under --release
// (Holed_Declaration — shippability adjudicated without emission), with no
// `.funpack/` after either verdict.
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

// test_check_probed_tree_dev_zero_release_two is the §05 §5 / §28 §4
// debug-directive ban through the check verb, the hole-ban's sibling tier: the
// SAME probed tree adjudicates exit 0 in Dev (a probe is a first-class dev
// citizen) and refuses exit 2 under --release (Debug_Directive — shippability
// adjudicated without emission), with no `.funpack/` after either verdict.
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

// test_check_preexisting_funpack_untouched pins the no-write floor against a
// stale prior build: a `.funpack/` already on disk (with bytes a fresh build
// would NOT produce) survives a check byte-untouched — check neither
// overwrites, deletes, nor adds a product, so the stale sentinel bytes read
// back identical after a clean exit-0 adjudication.
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

// The `--release` flag seam both build and check ride is now pinned in
// cli_funpack_test.odin (the CLI tree maps `--release` to Build_Mode.Release and
// its absence to Dev, and a typo'd or trailing argument is the usage tier); the
// integration tests below exercise the resulting exit contract end-to-end.

// ── recursive multi-project sweep ─────────────
// `funpack check --recursive [root]` discovers every funpack_configs project
// under a directory tree with the pure Odin walker (no `find`, no shell-out) and
// adjudicates each through the SAME single-project seam — so these tests fold the
// multi-project walk into the check verb's living-spec junction, asserting the
// discovery set, the aggregate exit tier, and the byte-stable report that NAMES a
// failing project.

// write_project_under materializes one §14 project at `<parent>/<name>` carrying
// the given single source — the multi-project fixture primitive. A MINI_SOURCE
// project compiles clean; a deliberately-broken source reaches the compile floor.
// The configs mirror write_minimal_valid_tree so read_project and the index's
// authored read succeed; only the source decides the verdict, isolating clean-vs-
// failed to the compile floor.
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

// write_games_tree materializes a `games/`-style parent dir holding several
// sibling projects (mirroring the dogfood agent's sweep target) plus prune noise:
// a `.git` dir, a stray `.funpack` build-output dir, and a NESTED project under one
// project's own subtree. The nested project and the prune dirs prove the walk's
// pruning — a discovered project's subtree is not descended, and .git/.funpack are
// skipped — so discovery returns exactly the top-level siblings. `bad` is the one
// project given a broken source (the rest are clean); pass "" for an all-clean tree.
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
	// Prune noise: a .git dir, a build-output .funpack dir (each holding a
	// funpack_configs/ that must NOT be discovered as a project), and a nested
	// project under the first sibling's own subtree (must NOT be double-counted).
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

// test_check_recursive_discovers_every_project pins the discovery walk: over a
// games/ tree of N sibling projects (plus .git/.funpack noise and a nested project
// under one sibling), discover_project_roots returns EXACTLY the N top-level roots,
// SORTED by path — the .git/.funpack subtrees are pruned and the nested project is
// not descended into. This is the pure-walk junction the recursive verb loops over.
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
	// Sorted by path: the discovered roots' basenames are the siblings in sorted
	// order, and the nested project + .git/.funpack subtrees never appear. The walker
	// realpath-roots its fullpaths (the macOS /var → /private/var symlink case), so
	// compare the symlink-invariant basenames rather than the full path.
	expected := slice.clone(names, context.temp_allocator)
	slice.sort(expected)
	for want, i in expected {
		testing.expect_value(t, filepath.base(roots[i]), want)
	}
	log.infof("check recursive discover: %d sibling projects discovered, nested + .git/.funpack pruned", len(roots))
}

// test_check_recursive_prunes_the_vendor_dir pins the VENDOR_DIR prune: a vendored
// dependency at <root>/packages/<dep> (a real funpack_configs tree a deps walk owns)
// must NOT be adjudicated as a standalone project by the recursive sweep. A sibling
// real game IS discovered, so the prune is scoped to the packages/ vendor root, not
// the whole walk. Before the prune named VENDOR_DIR (it named the foreign node_modules/
// .vendor instead), the sweep descended into packages/ and double-counted every dep.
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

// test_check_recursive_clean_tree_exits_zero is the all-clean sweep: a games/ tree
// of N clean projects adjudicates exit 0 in one invocation, and the byte-stable
// report lists every project clean plus the aggregate "N projects, N clean, 0
// failed" summary — ALWAYS non-empty output, deterministic across hosts.
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
		// Each project reports clean on its own verdict line (basename-keyed, so the
		// macOS /var → /private/var realpath rooting does not break the match).
		testing.expect(t, strings.contains(output, strings.concatenate({filepath.SEPARATOR_STRING, name, ": clean"}, context.temp_allocator)))
	}
	testing.expect_value(t, run_check_recursive_verb(parent, .Dev), 0)
	// No project's subtree was written to — a recursive check writes nothing.
	for name in names {
		testing.expect(t, !os.exists(scratch_join({parent, name, FUNPACK_BUILD_DIR})))
	}
	log.infof("check recursive clean: %d-project sweep exits 0 with a deterministic summary and no products", len(names))
}

// test_check_recursive_failing_tree_exits_two_names_it is the failure tier: a
// games/ tree with ONE broken project sweeps to exit 2, and the report NAMES the
// failing project on its verdict line, while every clean sibling still reports
// clean — so the failure is localized, not a whole-sweep blackout.
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
	// The failing project is NAMED on a "failed" verdict line (basename-keyed match,
	// symlink-invariant to the realpath rooting).
	testing.expect(t, strings.contains(output, strings.concatenate({filepath.SEPARATOR_STRING, bad, ": failed"}, context.temp_allocator)))
	// The clean siblings still report clean — the failure does not blackout the sweep.
	testing.expect(t, strings.contains(output, strings.concatenate({filepath.SEPARATOR_STRING, "alpha", ": clean"}, context.temp_allocator)))
	testing.expect(t, strings.contains(output, "funpack check: 3 projects, 2 clean, 1 failed"))
	testing.expect_value(t, run_check_recursive_verb(parent, .Dev), 2)
	log.infof("check recursive failing: the sweep exits 2 and NAMES %s, clean siblings still report clean", bad)
}

// test_check_recursive_no_project_root_exits_two pins the empty-sweep refusal: a
// root with no funpack_configs project anywhere under it is a usage error (exit 2),
// never a silent exit-0 no-op — a recursive sweep that found nothing is a mistake to
// surface, not a vacuous success.
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

// test_check_recursive_root_is_project_exits_zero pins the root-is-a-project case:
// when `root` ITSELF is a project (its own funpack_configs/), discovery returns
// exactly that one root and does NOT descend looking for nested projects (the
// first project on a path wins), so a single clean project at the root sweeps to
// exit 0 with a "1 projects, 1 clean, 0 failed" summary.
@(test)
test_check_recursive_root_is_project_exits_zero :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	// A nested project under the root's own subtree must NOT be discovered.
	if _, wrote := write_project_under(scratch_join({root, "src"}), "nested", MINI_SOURCE); !wrote {
		log.warnf("SKIP check recursive root-is-project: cannot write nested project")
		return
	}

	roots := discover_project_roots(root, context.temp_allocator)
	testing.expect_value(t, len(roots), 1)
	// The root itself is the one discovered project; compare basenames (the root-is-a-
	// project branch returns `root` as-passed, but keep the assertion symlink-robust).
	testing.expect_value(t, filepath.base(roots[0]), filepath.base(root))
	testing.expect_value(t, run_check_recursive_verb(root, .Dev), 0)
	log.infof("check recursive root-is-project: the root project is the whole answer, no nested descent")
}

// ── live-tree goldens (resolve_spec_dir SKIP-warn protocol) ──────────────

// test_golden_check_numerics_clean_exits_zero is the live clean-tree golden:
// the numerics spec example (a §30 §7 package) adjudicates exit 0 through the
// check verb and NO `.funpack/` exists afterward — the verdict-only contract
// proven against a real committed tree, not a hand-shaped stub. SKIPs loudly
// when the sibling checkout is absent (FUNPACK_NUMERICS_DIR overrides).
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

// test_golden_check_drift_dev_zero_release_two is the live hole-ban golden:
// the drift spec example (the authored §05 typed-hole governance tree)
// adjudicates exit 0 in Dev and refuses exit 2 under --release through the
// check verb, with no `.funpack/` after either run — the §29 §4 release
// decision proven shippability-adjudicable without emission. SKIPs loudly when
// the sibling checkout is absent (FUNPACK_DRIFT_DIR overrides).
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
