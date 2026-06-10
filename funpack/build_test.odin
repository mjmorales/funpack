// The build-verb integration golden: the `funpack build` seam (build.odin) read
// against a real §14 project tree must write BOTH the runtime artifact and the
// Index Contract NDJSON on success, write NEITHER on a compile/gate failure, and
// be byte-identical on a re-build (spec §09/§29 end-to-end determinism). These
// tests exercise the integration path on disk — they copy the live pong tree
// into a temp root, build it, and assert the products land — so the CLI exit
// contract (§29 §3) is proven against a real tree, not a hand-shaped stub. The
// compile-error and malformed-tree cases use a deliberately-broken temp tree so
// the exit-2-writes-no-product path is covered. Like the emit/index goldens they
// resolve the sibling pong checkout (or FUNPACK_PONG_DIR) and SKIP loudly when
// it is absent, so a missing checkout never silently passes.
package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// test_build_pong_tree_exits_zero_and_writes_both_products is the load-bearing
// acceptance: building the live pong tree (copied to a temp root) succeeds and
// writes both products under `.funpack/`. It drives the exact stage_build →
// write_build_products path the CLI verb runs, then asserts both files exist on
// disk — the §29 §3 success outcome (exit 0, both products).
@(test)
test_build_pong_tree_exits_zero_and_writes_both_products :: proc(t: ^testing.T) {
	root, ok := copy_pong_tree_to_temp()
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
	// Both products are non-empty: the artifact carries the v1 magic line and
	// the NDJSON carries the schema_version object.
	testing.expect(t, strings.has_prefix(product.artifact, ARTIFACT_MAGIC))
	testing.expect(t, strings.has_prefix(product.index, "{\"schema_version\":"))
	log.infof("build verb: pong tree build exits 0 and writes both products (artifact + index NDJSON)")
}

// test_build_pong_double_build_identical proves the build is deterministic end
// to end (spec §09/§29): building the same pong tree twice writes byte-identical
// artifact AND byte-identical Index Contract NDJSON. The output paths are derived
// from the project root with no machine-specific component, so the bytes carry no
// datum that varies between builds.
@(test)
test_build_pong_double_build_identical :: proc(t: ^testing.T) {
	root, ok := copy_pong_tree_to_temp()
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	first, first_verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, first_verdict.err, Build_Error.None)
	second, second_verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, second_verdict.err, Build_Error.None)
	if first_verdict.err != .None || second_verdict.err != .None {
		return
	}
	testing.expect(t, first.artifact == second.artifact)
	testing.expect(t, first.index == second.index)
	if first.artifact == second.artifact && first.index == second.index {
		// A passing-run confirmation the acceptance gate reads: the double build
		// is byte-identical for both products (end-to-end determinism).
		log.infof(
			"build identical: double build of pong is byte-identical artifact (%d bytes) and index NDJSON (%d bytes)",
			len(first.artifact),
			len(first.index),
		)
	}
}

// test_build_double_build_identical_no_checkout proves the build is
// deterministic without the sibling pong checkout: it materializes a minimal
// valid §14 tree in temp, builds it twice, and asserts byte-identical artifact
// AND byte-identical Index Contract NDJSON. The output paths derive from the
// project root with no machine-specific component, so the bytes carry no datum
// that varies between builds — the end-to-end bit-identity obligation (spec
// §09/§29), provable on every host regardless of the checkout.
@(test)
test_build_double_build_identical_no_checkout :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	first, first_verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, first_verdict.err, Build_Error.None)
	second, second_verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, second_verdict.err, Build_Error.None)
	if first_verdict.err != .None || second_verdict.err != .None {
		return
	}
	testing.expect(t, first.artifact == second.artifact)
	testing.expect(t, first.index == second.index)
	if first.artifact == second.artifact && first.index == second.index {
		// A passing-run confirmation the acceptance gate reads: a double build of
		// the same tree is byte-identical for both products (end-to-end
		// determinism), without depending on the sibling checkout.
		log.infof(
			"double build identical: building the same tree twice is byte-identical artifact (%d bytes) and index NDJSON (%d bytes)",
			len(first.artifact),
			len(first.index),
		)
	}
}

// test_build_compile_error_exits_two_writes_no_artifact covers the §29 §3
// failure outcome: a deliberately-broken source on an otherwise-valid §14 tree
// fails the checked pipeline, so stage_build returns Compile_Failed and writes no
// product. A compile error is NEVER a counted failure (the build verb has no
// assertion tier) — it is the exit-2 path, and no artifact lands on disk.
@(test)
test_build_compile_error_exits_two_writes_no_artifact :: proc(t: ^testing.T) {
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Dev, context.temp_allocator)
	// The broken source parses to a malformed program the checked pipeline
	// rejects, so the build refuses with Compile_Failed and emits nothing.
	testing.expect_value(t, verdict.err, Build_Error.Compile_Failed)

	// No artifact and no index were written: stage_build returns before the
	// write side, so the derived `.funpack/` products are absent.
	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("build exit 2: compile error on the project tree writes no artifact (the build is exit 2, never a counted failure)")
}

// test_build_malformed_tree_exits_two covers the malformed-§14-tree failure: a
// tree missing funpack_configs/ is rejected by read_project, so stage_build
// returns Malformed_Tree (the exit-2 path) and writes no product. A malformed
// tree and a compile error share the exit-2 outcome — the build emits both
// products or none.
@(test)
test_build_malformed_tree_exits_two :: proc(t: ^testing.T) {
	root := scratch_join({scratch_base(), tprintf_seq("funpack-build-malformed")})
	remove_scratch_tree(root)
	if !ensure_dir(root) {
		log.warnf("SKIP build malformed tree: cannot create %s", root)
		return
	}
	defer remove_scratch_tree(root)
	// The root has no funpack_configs/ — read_project rejects it, so the build
	// is a malformed-tree exit-2.
	_, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Malformed_Tree)
}

// test_build_writes_index_ndjson is the whole-stream acceptance: building the
// live pong tree writes a .funpack/index.ndjson carrying BOTH §29 §2 record
// kinds — the `project` record on line 1 and one `decl` record line per
// declaration after it. It drives the same stage_build → write_build_products
// path the CLI verb runs, reads the written product back from disk, and asserts
// the multi-record stream landed (not just the single project record). SKIPs
// loudly when the sibling pong checkout is absent.
@(test)
test_build_writes_index_ndjson :: proc(t: ^testing.T) {
	root, ok := copy_pong_tree_to_temp()
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

	// Read the written NDJSON back from disk: it must be the whole stream.
	written, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	stream := string(written)
	// The `project` record leads (its v3 schema_version stamp prefixes line 1),
	// and the stream carries a `decl` record kind after it (a project-only field
	// vs a decl-only field both appear) — the multi-record stream, not a lone
	// project record.
	testing.expect(t, strings.has_prefix(stream, "{\"schema_version\":3,"))
	testing.expect(t, strings.contains(stream, "\"pipeline_flattened\":")) // project record
	testing.expect(t, strings.contains(stream, "\"qualified_name\":")) // a decl record
	testing.expect(t, strings.contains(stream, "\"dup_class\":")) // a decl-only field
	// More than one record: a multi-line stream (the project line + decl lines).
	testing.expect(t, strings.count(stream, "\n") > 1)
	log.infof("build verb: pong index.ndjson carries the whole project+decl multi-record stream")
}

// test_build_index_byte_identical_twice proves the LARGER (multi-record) index
// stream is still byte-identical across two builds (spec §09/§29): building the
// same pong tree twice yields byte-identical index.ndjson, end to end through the
// build seam. The stream concatenates the project record then the decl records in
// fixed order with no map/clock/float, so the bytes carry no datum that varies
// between builds. The no-checkout twin (test_build_double_build_identical_no_checkout)
// covers host-independent determinism on the minimal tree.
@(test)
test_build_index_byte_identical_twice :: proc(t: ^testing.T) {
	root, ok := copy_pong_tree_to_temp()
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	first, first_verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, first_verdict.err, Build_Error.None)
	second, second_verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, second_verdict.err, Build_Error.None)
	if first_verdict.err != .None || second_verdict.err != .None {
		return
	}
	// The whole multi-record stream is byte-identical between the two builds.
	testing.expect(t, first.index == second.index)
	// It is genuinely the larger stream, not a lone project record (a decl record
	// kind is present), so the determinism obligation covers the decl lines too.
	testing.expect(t, strings.contains(first.index, "\"qualified_name\":"))
	testing.expect(t, strings.count(first.index, "\n") > 1)
	if first.index == second.index {
		log.infof(
			"build identical: double build of pong is byte-identical multi-record index NDJSON (%d bytes, %d records)",
			len(first.index),
			strings.count(first.index, "\n"),
		)
	}
}

// test_build_no_partial_product covers the §29 §3 no-partial-product floor with
// the larger stream in play: a compile error on an otherwise-valid §14 tree fails
// the checked pipeline, so stage_build returns before the write side and NEITHER
// product lands — no artifact, no (multi-record) index.ndjson. The build emits
// both products or none; a failure leaves no partial product set behind.
@(test)
test_build_no_partial_product :: proc(t: ^testing.T) {
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Dev, context.temp_allocator)
	// The broken source is rejected by the checked pipeline, so the build refuses
	// with Compile_Failed and emits nothing — the exit-2 path.
	testing.expect_value(t, verdict.err, Build_Error.Compile_Failed)

	// No partial product: neither the artifact nor the index.ndjson is on disk.
	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("build no partial product: a compile error writes neither product (the whole-stream build is all-or-nothing)")
}

// ── multi-module + package build (Gap A + Gap C) ─────────────────────────

// test_build_multi_module_arena is the multi-module-build acceptance: the live
// arena tree (arena_world schema + the arena seam + arena_game behaviors, copied
// to a temp root) builds exit 0 (Build_Error.None) and writes BOTH products. The
// index stream carries decl records from EVERY module — the entrypoint module
// (arena_game), the schema (arena_world), and the generated seam (arena) — and a
// multi-module stream module-qualifies each decl by its §15 name (`arena_game.gate_logic`,
// `arena_world.Player`, `arena.Arena`), so a name two modules both declare
// disambiguates. It proves the §14-tree multi-module compile entry (one project-
// wide module index feeding both products) end to end against a real tree. SKIPs
// loudly when the sibling checkout is absent.
@(test)
test_build_multi_module_arena :: proc(t: ^testing.T) {
	root, ok := copy_spec_tree_to_temp(resolve_arena_dir(), "arena", "FUNPACK_ARENA_DIR")
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

	// A game writes BOTH products — the runtime artifact (the entrypoint module's,
	// arena_game) and the multi-module Index Contract NDJSON.
	testing.expect(t, os.exists(product.artifact_path))
	testing.expect(t, os.exists(product.index_path))
	testing.expect(t, strings.has_prefix(product.artifact, ARTIFACT_MAGIC))

	// The index stream carries decl records from every module, EACH §15
	// module-qualified (the multi-module qualification — a single-module game keeps
	// bare names; a cross-module stream qualifies). The three modules' decls all
	// appear, so the index is the whole-project stream, not the entrypoint's alone.
	stream := product.index
	testing.expect(t, strings.contains(stream, "\"qualified_name\":\"arena_game."))
	testing.expect(t, strings.contains(stream, "\"qualified_name\":\"arena_world."))
	testing.expect(t, strings.contains(stream, "\"qualified_name\":\"arena."))
	log.infof("build multi-module arena: exit 0, both products written, index carries decl records from all 3 modules (arena_game + arena_world + arena seam)")
}

// test_index_stream_multi_module_order pins the multi-module DECL-BLOCK order: the
// ENTRYPOINT module's block (arena_game, the entrypoints.fcfg `use <module>`
// clause) leads, then the remaining modules in Project.sources order (sorted-by-
// path via merge_sources — gen/arena.gen.fun ⇒ `arena` before src/arena_world.fun
// ⇒ `arena_world`). So the first decl-block prefix is arena_game., the next module
// prefix encountered is arena., then arena_world. — a deterministic permutation
// off ONE module-index build, pinned EXACTLY so a re-order fails loudly. SKIPs
// loudly when the sibling is absent.
@(test)
test_index_stream_multi_module_order :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP build multi-module order: %s not found — set FUNPACK_ARENA_DIR or check out funpack-spec as a sibling", dir)
		return
	}
	stream, err, compiled := read_index_project(dir, context.temp_allocator)
	testing.expect_value(t, err, Index_Contract_Error.None)
	testing.expect(t, compiled)
	if err != .None || !compiled {
		return
	}

	// The module-block order: the FIRST decl is the entrypoint module's
	// (arena_game), and the modules appear in the pinned order entrypoint → arena →
	// arena_world (sources order, sorted-by-path, with the entrypoint hoisted).
	order := module_prefix_order(stream)
	testing.expect_value(t, len(order), 3)
	if len(order) != 3 {
		return
	}
	testing.expect_value(t, order[0], "arena_game")
	testing.expect_value(t, order[1], "arena")
	testing.expect_value(t, order[2], "arena_world")
	log.infof("index multi-module order: decl blocks emit entrypoint-first then sorted-by-path remainder (%v)", order)
}

// test_build_numerics_package_index_only is the §30 §7 package-build acceptance:
// the live numerics tree (a package — no entrypoints.fcfg, copied to a temp root)
// builds exit 0 (Build_Error.None) and writes the Index Contract NDJSON ONLY. With
// no entrypoint there is no runtime artifact to select, so artifact_path stays
// empty, no artifact lands on disk, and the index is the build's single product —
// the all-or-nothing write contract is per-project-kind (a package writes its
// index or nothing). SKIPs loudly when the sibling is absent.
@(test)
test_build_numerics_package_index_only :: proc(t: ^testing.T) {
	root, ok := copy_spec_tree_to_temp(resolve_golden_dir(), "numerics", "FUNPACK_NUMERICS_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}

	// A package emits NO runtime artifact: artifact_path is empty (no entrypoint to
	// select), and the index is the single product.
	testing.expect_value(t, product.artifact_path, "")
	testing.expect_value(t, product.artifact, "")
	testing.expect(t, product.index_path != "")
	testing.expect(t, strings.has_prefix(product.index, "{\"schema_version\":3,"))
	// The package's `project` record carries an empty entrypoints list and no
	// pipeline (no entrypoint ⇒ empty pipeline_flattened) — governance data, §30 §7.
	testing.expect(t, strings.contains(product.index, "\"entrypoints\":[]"))
	testing.expect(t, strings.contains(product.index, "\"pipeline_flattened\":[]"))

	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)

	// On disk: the index landed, NO artifact (the package writes one product).
	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, os.exists(product.index_path))
	testing.expect(t, !os.exists(artifact_path))
	log.infof("build package numerics: §30 §7 index-only build (exit 0, index.ndjson written, NO runtime artifact)")
}

// ── --release hole-ban (§29 §4: you cannot ship a hole) ──────────────────

// test_build_release_holed_tree_exits_two is the release hole-ban acceptance: a
// §14 tree carrying a §05 typed hole built in Release mode refuses with a
// Holed_Declaration verdict NAMING the holed declaration (approx_speed; bare —
// the fixture is single-module, lore #11) — the exit-2 compile-error outcome
// (NEVER a counted failure; the build verb has no assertion tier) — and writes
// NEITHER product.
@(test)
test_build_release_holed_tree_exits_two :: proc(t: ^testing.T) {
	root, ok := write_holed_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Holed_Declaration)
	testing.expect_value(t, verdict.offender, "approx_speed")

	// The ban refuses before either emission surface runs, so no product lands.
	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("release hole-ban: a holed decl under --release is Holed_Declaration (exit 2, compile error, no product) — a hole cannot ship")
}

// test_build_dev_holed_tree_exits_zero is the dev half of the §29 §4 contract:
// the SAME holed tree built in Dev mode (the no-flag default) compiles exit 0
// and writes both products — a hole is a first-class dev citizen; only release
// refuses it.
@(test)
test_build_dev_holed_tree_exits_zero :: proc(t: ^testing.T) {
	root, ok := write_holed_tree(t)
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
	log.infof("dev holes compile: the same holed tree builds exit 0 in dev mode and writes both products")
}

// test_build_release_hole_free_tree_matches_dev pins the mode flag's purity: on
// a hole-free tree, Release succeeds exactly like Dev AND emits byte-identical
// products — the mode is a pure (AST, mode) gate input, never a datum reaching
// the emitted bytes, so release-vs-dev differs only in whether a hole refuses.
@(test)
test_build_release_hole_free_tree_matches_dev :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	dev, dev_verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, dev_verdict.err, Build_Error.None)
	release, release_verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, release_verdict.err, Build_Error.None)
	if dev_verdict.err != .None || release_verdict.err != .None {
		return
	}
	testing.expect(t, dev.artifact == release.artifact)
	testing.expect(t, dev.index == release.index)
	log.infof("release purity: a hole-free tree builds byte-identical products in dev and release (the mode flag gates, never perturbs)")
}

// test_release_holed_decl_walk unit-tests the pure-AST finder (gates.odin) the
// build-seam ban consults: a holed fn is found by its own name, a holed
// behavior STEP anchors on the behavior's name (never the reserved `step`),
// and a hole-free AST reports none.
@(test)
test_release_holed_decl_walk :: proc(t: ^testing.T) {
	holed_fn_ast, fn_err := stage_parse(stage_lex("fn speed() -> Fixed @stub(Fixed)\n"))
	testing.expect_value(t, fn_err, Parse_Error.None)
	declaration, holed := release_holed_decl(holed_fn_ast)
	testing.expect(t, holed)
	testing.expect_value(t, declaration, "speed")

	holed_step_ast, step_err := stage_parse(stage_lex("behavior serve on Ball {\n  fn step(self: Ball) -> Ball @stub(Ball)\n}\n"))
	testing.expect_value(t, step_err, Parse_Error.None)
	declaration, holed = release_holed_decl(holed_step_ast)
	testing.expect(t, holed)
	testing.expect_value(t, declaration, "serve")

	clean_ast, clean_err := stage_parse(stage_lex("fn whole() -> Fixed {\n  return 1.5\n}\n"))
	testing.expect_value(t, clean_err, Parse_Error.None)
	_, holed = release_holed_decl(clean_ast)
	testing.expect(t, !holed)
	log.infof("release_holed_decl: finds a holed fn and a holed behavior step (anchored on the behavior name), none on a hole-free AST")
}

// test_gates_skip_holed_units proves dev mode compiles MULTIPLE holes: a holed
// fn is body-less (the hole stands in body position), so like an extern fn it
// is not a unit the structural gates score — two holes must NOT collide on the
// duplication gate (two empty bodies hash identically), or a second hole would
// break the dev build the §05 contract promises compiles.
@(test)
test_gates_skip_holed_units :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex("fn first_hole() -> Fixed @stub(Fixed)\nfn second_hole() -> Fixed @stub(Fixed)\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
	log.infof("gates skip holed units: two holes in one module pass the duplication gate (a hole is body-less, not a scored code unit)")
}

// ── --release debug-directive ban (§05 §5 / §28 §4: debug residue cannot ship) ──

// test_build_release_probed_tree_exits_two is the release debug-directive-ban
// acceptance, the hole-ban's sibling: a §14 tree carrying a §05 §5 debug probe
// built in Release mode refuses with a Debug_Directive verdict NAMING the
// probed declaration (drift, the @log-probed behavior; bare — the fixture is
// single-module, lore #11) — the exit-2 compile-error outcome (NEVER a counted
// failure; the build verb has no assertion tier) — and writes NEITHER product.
@(test)
test_build_release_probed_tree_exits_two :: proc(t: ^testing.T) {
	root, ok := write_probed_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Debug_Directive)
	testing.expect_value(t, verdict.offender, "drift")

	// The ban refuses before either emission surface runs, so no product lands.
	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("release debug ban: a probed decl under --release is Debug_Directive (exit 2, compile error, no product) — debug residue cannot ship")
}

// test_build_dev_probed_tree_exits_zero_and_indexes_probe is the dev half of
// the §05 §5 contract: the SAME probed tree built in Dev mode (the no-flag
// default) compiles exit 0, writes both products, AND its emitted index
// derives the probe into the decl's debug field — replacing the
// mandatory-present empty, so the §28 §4 task-registration surface sees the
// outstanding probe.
@(test)
test_build_dev_probed_tree_exits_zero_and_indexes_probe :: proc(t: ^testing.T) {
	root, ok := write_probed_tree(t)
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
	// The probed behavior's decl line carries the DERIVED debug field — the
	// @log probe by its directive name — while the probe-free bindings fn stays
	// the mandatory-present empty.
	testing.expect(t, strings.contains(product.index, "\"qualified_name\":\"drift\""))
	testing.expect(t, strings.contains(product.index, "\"debug\":[\"log\"]"))
	testing.expect(t, strings.contains(product.index, "\"debug\":[]"))
	log.infof("dev probes compile: the probed tree builds exit 0 in dev mode and the index derives the probe (debug=[\"log\"])")
}

// test_release_debug_decl_walk unit-tests the pure-AST finder (gates.odin) the
// build-seam ban consults, mirroring test_release_holed_decl_walk: a probed
// behavior is found by its own name, a probed fn by its name (the parser
// admits a probe on every directive-carrying decl; placement is a downstream
// concern, the ban refuses them all), and a probe-free AST reports none.
@(test)
test_release_debug_decl_walk :: proc(t: ^testing.T) {
	probed_behavior_ast, behavior_err := stage_parse(stage_lex("@trace\nbehavior serve on Ball {\n  fn step(self: Ball) -> Ball {\n    return self\n  }\n}\n"))
	testing.expect_value(t, behavior_err, Parse_Error.None)
	declaration, probed := release_debug_decl(probed_behavior_ast)
	testing.expect(t, probed)
	testing.expect_value(t, declaration, "serve")

	probed_fn_ast, fn_err := stage_parse(stage_lex("@log(speed)\nfn speed() -> Fixed {\n  return 1.5\n}\n"))
	testing.expect_value(t, fn_err, Parse_Error.None)
	declaration, probed = release_debug_decl(probed_fn_ast)
	testing.expect(t, probed)
	testing.expect_value(t, declaration, "speed")

	clean_ast, clean_err := stage_parse(stage_lex("fn whole() -> Fixed {\n  return 1.5\n}\n"))
	testing.expect_value(t, clean_err, Parse_Error.None)
	_, probed = release_debug_decl(clean_ast)
	testing.expect(t, !probed)
	log.infof("release_debug_decl: finds a probed behavior and a probed fn by name, none on a probe-free AST")
}

// test_build_release_multi_module_offender_qualified pins the offender's §15
// qualification on the multi-module path: a two-module tree whose hole lives in
// the beta module refuses with the MODULE-QUALIFIED offender
// (`beta.approx_speed`), matching the Index Contract's qualified_name — the
// single-module bare rule (lore #11) applies only to one-source projects.
@(test)
test_build_release_multi_module_offender_qualified :: proc(t: ^testing.T) {
	root, ok := write_two_module_holed_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Holed_Declaration)
	testing.expect_value(t, verdict.offender, "beta.approx_speed")
	log.infof("release offender qualification: a multi-module tree names the module-qualified offender (beta.approx_speed)")
}

// test_build_refusal_message_shapes pins build_refusal_message's two line
// shapes: an offender-less arm renders the closed arm's name alone, and a
// release-refusal verdict appends the module-qualified offender after a colon.
// The line is advisory wording (§29 §3 — the machine contract is the exit
// code) but deterministic, so the goldens pin it byte-for-byte.
@(test)
test_build_refusal_message_shapes :: proc(t: ^testing.T) {
	testing.expect_value(t, build_refusal_message(Build_Verdict{err = .Malformed_Tree}, context.temp_allocator), "Malformed_Tree")
	testing.expect_value(t, build_refusal_message(Build_Verdict{err = .Holed_Declaration, offender = "drag"}, context.temp_allocator), "Holed_Declaration: drag")
	testing.expect_value(t, build_refusal_message(Build_Verdict{err = .Debug_Directive, offender = "beta.DebugMarker"}, context.temp_allocator), "Debug_Directive: beta.DebugMarker")
}

// module_prefix_order extracts the distinct §15 module prefixes from the index
// stream's decl lines in first-seen order — the multi-module decl-block order the
// order test pins. A decl line's qualified_name is `<module>.<name>`, so the
// prefix is the substring before the first dot; a bare (single-module) decl has no
// dot and is skipped. First-seen dedup over the line order recovers the block
// order without a map reaching the result, so the order is deterministic.
module_prefix_order :: proc(stream: string) -> []string {
	order := make([dynamic]string, 0, 4, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	needle :: "\"qualified_name\":\""
	rest := stream
	for {
		idx := strings.index(rest, needle)
		if idx < 0 {
			break
		}
		rest = rest[idx + len(needle):]
		end := strings.index(rest, "\"")
		if end < 0 {
			break
		}
		qualified := rest[:end]
		rest = rest[end:]
		dot := strings.index(qualified, ".")
		if dot < 0 {
			continue
		}
		prefix := qualified[:dot]
		if prefix in seen {
			continue
		}
		seen[prefix] = true
		append(&order, prefix)
	}
	return order[:]
}

// ── Helpers ────────────────────────────────────────────────────────────

// copy_pong_tree_to_temp copies the live pong project tree into a fresh temp
// root so a build test can write derived products without touching the committed
// checkout. ok = false (with the golden SKIP semantics) when the sibling pong
// checkout is absent or the copy fails. The copy is recursive over the tree's
// regular files, recreating the directory structure under the temp root.
copy_pong_tree_to_temp :: proc() -> (root: string, ok: bool) {
	return copy_spec_tree_to_temp(resolve_pong_dir(), "pong", "FUNPACK_PONG_DIR")
}

// copy_spec_tree_to_temp copies a live spec example tree into a fresh temp root so
// a build test can write derived products without touching the committed checkout
// — the generic form copy_pong_tree_to_temp and the multi-module/package build
// tests share. ok = false (with the golden SKIP semantics, naming the env
// override) when the sibling checkout is absent or the copy fails. The copy is
// recursive over the tree's regular files, recreating the directory structure
// under the temp root; the temp-root label keeps concurrent build tests from
// colliding.
copy_spec_tree_to_temp :: proc(src: string, label: string, env_name: string) -> (root: string, ok: bool) {
	if !os.is_dir(src) {
		log.warnf("SKIP build %s: %s not found — set %s or check out funpack-spec as a sibling", label, src, env_name)
		return "", false
	}
	root = scratch_join({scratch_base(), tprintf_seq(fmt.tprintf("funpack-build-%s", label))})
	remove_scratch_tree(root)
	if !copy_tree(src, root) {
		remove_scratch_tree(root)
		log.warnf("SKIP build %s: cannot copy %s tree into %s", label, label, root)
		return "", false
	}
	return root, true
}

// copy_tree recursively copies every regular file under `src` into `dst`,
// recreating the interior directory structure. It is scoped to the build test's
// fixture need (materialize a real §14 tree in temp) — it copies file bytes
// verbatim and skips non-regular entries, so the copied tree is a faithful build
// input. false on any directory-create or file-write failure.
copy_tree :: proc(src: string, dst: string) -> bool {
	if !ensure_dir(dst) {
		return false
	}
	walker := os.walker_create(src)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular {
			continue
		}
		rel, rel_err := filepath.rel(src, info.fullpath, context.temp_allocator)
		if rel_err != .None {
			return false
		}
		dst_path := scratch_join({dst, rel})
		if !ensure_dir(filepath.dir(dst_path)) {
			return false
		}
		bytes, read_err := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
		if read_err != nil {
			return false
		}
		if os.write_entire_file(dst_path, bytes) != nil {
			return false
		}
	}
	return true
}

// ensure_dir creates a directory and its parents idempotently: an
// already-present directory is success, not an error. os.make_directory_all
// reports General_Error.Exist when the path already exists, so a recursive copy
// that touches a shared parent more than once treats that as a no-op rather than
// a failure.
ensure_dir :: proc(path: string) -> bool {
	err := os.make_directory_all(path)
	return err == nil || err == os.General_Error.Exist
}

// write_broken_pong_tree materializes a §14 tree whose configs are valid but
// whose single source is a deliberately-malformed program the checked pipeline
// rejects, so stage_build reaches the compile floor and refuses with
// Compile_Failed. The configs mirror the pong tree (so read_project and the
// index's authored read succeed) — only the source is broken, isolating the
// failure to the compile floor rather than a tree-shape error.
write_broken_pong_tree :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), tprintf_seq("funpack-build-broken")})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_path := scratch_join({root, "src", "pong.fun"})
	if !ensure_dir(configs) || !ensure_dir(filepath.dir(src_path)) {
		log.warnf("SKIP build broken tree: cannot create dirs under %s", root)
		return "", false
	}
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project pong {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		// A source that fails to parse — a `fn` head with no body and a dangling
		// brace — so the checked pipeline rejects it at the parse floor.
		os.write_entire_file(src_path, "fn broken( {\n") == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build broken tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

// write_minimal_valid_tree materializes a minimal valid §14 project tree whose
// configs and single source all compile, so stage_build emits both products. The
// source declares exactly what the entrypoint references — an empty pipeline
// and a deviceless bindings fn — so emission's reference validation (§07)
// resolves and the schedule flattens empty, exercising the full build path
// without reproducing the pong source. It is the pong-independent fixture the
// determinism test builds twice, so the byte-identity check holds on any host.
// MINI_SOURCE is the minimal compileable module the valid-tree fixture carries:
// it declares the `Loop` pipeline and `bindings` fn the fixture's
// entrypoints.fcfg references, so emission's reference validation resolves.
MINI_SOURCE :: "@doc(\"Minimal buildable module: an empty pipeline and a deviceless bindings fn.\")\n\nimport engine.input.{Bindings}\n\n@doc(\"No bindings — the minimal deviceless map.\")\nfn bindings() -> Bindings {\n  return Bindings.empty()\n}\n\n@doc(\"The empty schedule.\")\npipeline Loop {\n}\n"

write_minimal_valid_tree :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), tprintf_seq("funpack-build-mini")})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_path := scratch_join({root, "src", "mini.fun"})
	if !ensure_dir(configs) || !ensure_dir(filepath.dir(src_path)) {
		log.warnf("SKIP build minimal tree: cannot create dirs under %s", root)
		return "", false
	}
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project mini {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		os.write_entire_file(src_path, MINI_SOURCE) == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build minimal tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

// HOLED_SOURCE is the minimal compileable module plus one §05 typed hole — the
// fixture the release hole-ban tests build in both modes: dev compiles it
// (exit 0, both products), release refuses it (Holed_Declaration, exit 2, no
// product).
HOLED_SOURCE :: MINI_SOURCE + "\n@doc(\"A typed hole: dev compiles it, release refuses to ship it.\")\nfn approx_speed() -> Fixed @stub(Fixed)\n"

// write_holed_tree materializes the write_minimal_valid_tree fixture with one
// §05 typed hole added to its source (HOLED_SOURCE) — a valid §14 tree whose
// only "defect" is the hole, isolating the release-vs-dev verdict to the
// hole-ban rather than any tree-shape or compile floor.
write_holed_tree :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), tprintf_seq("funpack-build-holed")})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_path := scratch_join({root, "src", "mini.fun"})
	if !ensure_dir(configs) || !ensure_dir(filepath.dir(src_path)) {
		log.warnf("SKIP build holed tree: cannot create dirs under %s", root)
		return "", false
	}
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project mini {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		os.write_entire_file(src_path, HOLED_SOURCE) == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build holed tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

// write_two_module_holed_tree materializes a TWO-module §14 tree whose §05
// typed hole lives in the second-by-path module (src/beta.fun) — the fixture
// the offender-qualification test builds: with more than one source the
// release refusal must name the offender module-qualified (beta.approx_speed),
// never bare. src/alpha.fun is the clean entrypoint module; the refusal fires
// before emission, so only read_project + parse must succeed on the tree.
write_two_module_holed_tree :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), tprintf_seq("funpack-build-twomod-holed")})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_dir := scratch_join({root, "src"})
	if !ensure_dir(configs) || !ensure_dir(src_dir) {
		log.warnf("SKIP build two-module holed tree: cannot create dirs under %s", root)
		return "", false
	}
	holed_beta :: "@doc(\"The beta module: carries the typed hole the release refusal must qualify.\")\n\n@doc(\"A typed hole in a sibling module.\")\nfn approx_speed() -> Fixed @stub(Fixed)\n"
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project twomod {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), "use alpha.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		os.write_entire_file(scratch_join({src_dir, "alpha.fun"}), MINI_SOURCE) == nil &&
		os.write_entire_file(scratch_join({src_dir, "beta.fun"}), holed_beta) == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build two-module holed tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

// PROBED_SOURCE is the minimal compileable module plus one §05 §5 debug probe
// (a @log on a behavior, the §28 §4 placement) — the fixture the release
// debug-directive-ban tests build in both modes: dev compiles it AND derives
// the probe into the index's debug field; release refuses it
// (Debug_Directive, exit 2, no product).
PROBED_SOURCE :: MINI_SOURCE + "\n@doc(\"A probed thing the debug fixture observes.\")\nthing Ball {\n  pos: Int\n}\n\n@doc(\"A probed behavior: dev compiles and indexes the probe, release refuses to ship it.\")\n@log(self.pos)\nbehavior drift on Ball {\n  fn step(self: Ball) -> Ball {\n    return self\n  }\n}\n"

// write_probed_tree materializes the write_minimal_valid_tree fixture with one
// §05 §5 debug probe added to its source (PROBED_SOURCE) — a valid §14 tree
// whose only "defect" is the probe, isolating the release-vs-dev verdict to
// the debug-directive ban rather than any tree-shape or compile floor
// (mirroring write_holed_tree).
write_probed_tree :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), tprintf_seq("funpack-build-probed")})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_path := scratch_join({root, "src", "mini.fun"})
	if !ensure_dir(configs) || !ensure_dir(filepath.dir(src_path)) {
		log.warnf("SKIP build probed tree: cannot create dirs under %s", root)
		return "", false
	}
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project mini {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		os.write_entire_file(src_path, PROBED_SOURCE) == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build probed tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

// tprintf_seq builds a per-process-unique scratch dir name from a prefix and the
// shared scratch sequence counter, so concurrently-scheduled build tests never
// collide on a temp root.
tprintf_seq :: proc(prefix: string) -> string {
	return fmt.tprintf("%s-%d", prefix, scratch_seq())
}
