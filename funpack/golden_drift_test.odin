// The §05 §2 typed-holes governance golden: the drift example tree
// (funpack-spec/examples/drift) is the live fixture proving the whole @stub
// surface end-to-end — a bare @stub(T) hole a caller typechecks against, a
// @stub(T, fallback) hole whose approximation runs to its asserted value, the
// Index Contract carrying stub=true for both holed declarations, and the §29
// §4 release hole-ban refusing the same tree that dev builds clean (spec §01
// §5 / §29 §4: funpack does not grammar-include what it cannot run). Like the
// other goldens it resolves the sibling checkout (or FUNPACK_DRIFT_DIR) and
// SKIPs loudly when it is absent — a skipped golden is a warning, never a
// pass. The parse fixture pins exact declaration counts against the live
// source; when the spec evolves, the counts change in lockstep — never loosen
// them to ranges.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

DRIFT_DEFAULT_DIR :: "../funpack-spec/examples/drift"

resolve_drift_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_DRIFT_DIR", DRIFT_DEFAULT_DIR)
}

@(test)
test_golden_drift_full_file_parses :: proc(t: ^testing.T) {
	source, ok := drift_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")

	// The drift golden surface's exact declaration inventory: one import
	// (engine.input.Bindings); four top-level fns (drag, damped, launch_speed,
	// bindings); one pipeline (Drift, the empty hole-first schedule); one
	// inline test (the fallback observation).
	testing.expect_value(t, len(ast.imports), 1)
	testing.expect_value(t, len(ast.fns), 4)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 1)

	// The load-bearing hole shapes the counts alone do not pin: drag is the
	// bare typecheck-only hole (holed, no fallback), launch_speed is the
	// two-argument form (holed, fallback carried), and damped — the caller
	// typechecking against the drag hole — is an intact body, not a hole.
	drag, found_drag := find_fn(ast, "drag")
	testing.expect(t, found_drag)
	if found_drag {
		testing.expect(t, drag.holed)
		testing.expect(t, !drag.has_fallback)
	}
	launch, found_launch := find_fn(ast, "launch_speed")
	testing.expect(t, found_launch)
	if found_launch {
		testing.expect(t, launch.holed)
		testing.expect(t, launch.has_fallback)
	}
	damped, found_damped := find_fn(ast, "damped")
	testing.expect(t, found_damped)
	if found_damped {
		testing.expect(t, !damped.holed)
	}
}

@(test)
test_golden_drift_dev_pipeline_passes :: proc(t: ^testing.T) {
	// AC (dev compiles + caller-against-hole + fallback runs): the drift source
	// compiles clean through every stage — `damped` typechecks its `v * drag()`
	// body against the drag hole's declared Fixed in the same compile — and the
	// inline test observes the launch_speed fallback's value (boost + 6.0 with
	// boost bound to 1.5 ⇒ 7.5): one passed, zero failed, exit 0.
	source, ok := drift_source()
	if !ok {
		return
	}
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
	if err == .None && report.failed == 0 {
		log.infof("golden drift dev: compiles clean, the caller typechecks against the hole, and the fallback approximation runs to 7.5")
	}
}

@(test)
test_golden_drift_variant_hole_disagreeing_type_rejected :: proc(t: ^testing.T) {
	// The negative obligation through the live fixture: re-typing drag's bare
	// hole to disagree with its `-> Fixed` ascription (`@stub(Int)`) rejects the
	// whole file at typecheck — the signature callers see and the hole standing
	// for the body must be the same type, so the golden cannot drift into a
	// hole the caller check would not catch.
	source, ok := drift_source()
	if !ok {
		return
	}
	variant, found := golden_variant(source, "@stub(Fixed)", "@stub(Int)")
	testing.expect(t, found)
	_, err := run_test_pipeline(variant)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_golden_drift_index_carries_stub_for_both_holes :: proc(t: ^testing.T) {
	// AC (Index Contract): the emitted .funpack/index.ndjson carries stub=true
	// for BOTH holed declarations — the bare @stub(T) drag and the
	// @stub(T, fallback) launch_speed — and stub=false for the intact caller,
	// so the index discriminates the holes, not merely the file. Asserted on
	// the written product's bytes, the same file `funpack warden` reads.
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "drift", "FUNPACK_DRIFT_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)

	index_bytes, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	stream := string(index_bytes)

	drag_line, drag_found := index_decl_line(stream, "drag")
	testing.expect(t, drag_found)
	testing.expect(t, strings.contains(drag_line, "\"stub\":true"))
	launch_line, launch_found := index_decl_line(stream, "launch_speed")
	testing.expect(t, launch_found)
	testing.expect(t, strings.contains(launch_line, "\"stub\":true"))
	damped_line, damped_found := index_decl_line(stream, "damped")
	testing.expect(t, damped_found)
	testing.expect(t, strings.contains(damped_line, "\"stub\":false"))
	if drag_found && launch_found {
		log.infof("golden drift index: stub=true for both holed decls (drag, launch_speed), stub=false for the intact caller (damped)")
	}
}

@(test)
test_golden_drift_release_build_exits_two :: proc(t: ^testing.T) {
	// AC (release hole-ban): `funpack build --release` over the drift tree is
	// the exit-2 compile-error outcome — stage_build refuses with a
	// Holed_Declaration verdict NAMING the first holed declaration (drag, the
	// bare @stub(T) hole; drift is single-module so the qualified name is bare,
	// lore #11) and writes NEITHER product. The refusal line is pinned
	// byte-for-byte for determinism — stdout/stderr stay advisory (§29 §3, the
	// machine contract is the exit code), but the NAME in the message is the
	// deliverable. Never a counted failure: build has no exit-1 tier.
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "drift", "FUNPACK_DRIFT_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Holed_Declaration)
	testing.expect_value(t, verdict.offender, "drag")
	testing.expect_value(t, build_refusal_message(verdict, context.temp_allocator), "Holed_Declaration: drag")

	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("golden drift release: the hole-ban refuses the tree naming the offender (Holed_Declaration: drag, exit 2, no product)")
}

@(test)
test_golden_drift_dev_build_exits_zero_writes_both_products :: proc(t: ^testing.T) {
	// AC (dev build): the SAME holed tree built in Dev mode (the no-flag
	// default) is exit 0 and writes BOTH products — a hole is a first-class dev
	// citizen; only release refuses it.
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "drift", "FUNPACK_DRIFT_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)
	testing.expect(t, os.exists(product.artifact_path))
	testing.expect(t, os.exists(product.index_path))
	log.infof("golden drift dev build: exit 0, both products written (artifact + index NDJSON)")
}

@(test)
test_resolve_drift_dir_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_drift_dir()))
}

// drift_source reads the drift project's single source file via the §14
// project-tree reader; ok = false (with a loud SKIP warning) when the sibling
// checkout is absent, matching the numerics/pong goldens' skip semantics.
drift_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_drift_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden drift: %s not found — set FUNPACK_DRIFT_DIR or check out funpack-spec as a sibling of the repo", dir)
		return "", false
	}
	project, read_err := read_project(dir)
	if read_err != .None || len(project.sources) == 0 {
		return "", false
	}
	source_bytes, file_err := os.read_entire_file_from_path(project.sources[0].path, context.temp_allocator)
	if file_err != nil {
		return "", false
	}
	return string(source_bytes), true
}

// index_decl_line finds the NDJSON line carrying the given qualified_name —
// the per-decl record the stub assertions read. The drift project is
// single-module, so decls qualify to their bare names (read_index_project's
// lore-#11 rule); found = false when no line names the decl, so a renamed
// fixture fails loudly instead of silently asserting nothing.
index_decl_line :: proc(stream: string, qualified_name: string) -> (line: string, found: bool) {
	needle := strings.concatenate({"\"qualified_name\":\"", qualified_name, "\""}, context.temp_allocator)
	rest := stream
	for candidate in strings.split_lines_iterator(&rest) {
		if strings.contains(candidate, needle) {
			return candidate, true
		}
	}
	return "", false
}
