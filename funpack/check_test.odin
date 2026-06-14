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

import "core:log"
import "core:os"
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
