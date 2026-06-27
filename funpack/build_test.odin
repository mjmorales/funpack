package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

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
	testing.expect(t, strings.has_prefix(product.artifact, ARTIFACT_MAGIC))
	testing.expect(t, strings.has_prefix(product.index, "{\"schema_version\":"))
	log.infof("build verb: pong tree build exits 0 and writes both products (artifact + index NDJSON)")
}

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
		log.infof(
			"build identical: double build of pong is byte-identical artifact (%d bytes) and index NDJSON (%d bytes)",
			len(first.artifact),
			len(first.index),
		)
	}
}

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
		log.infof(
			"double build identical: building the same tree twice is byte-identical artifact (%d bytes) and index NDJSON (%d bytes)",
			len(first.artifact),
			len(first.index),
		)
	}
}

@(test)
test_build_compile_error_exits_two_writes_no_artifact :: proc(t: ^testing.T) {
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Compile_Failed)

	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("build exit 2: compile error on the project tree writes no artifact (the build is exit 2, never a counted failure)")
}

@(test)
test_build_malformed_tree_exits_two :: proc(t: ^testing.T) {
	root := scratch_join({scratch_base(), tprintf_seq("funpack-build-malformed")})
	remove_scratch_tree(root)
	if !ensure_dir(root) {
		log.warnf("SKIP build malformed tree: cannot create %s", root)
		return
	}
	defer remove_scratch_tree(root)
	_, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Malformed_Tree)
}

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

	written, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	stream := string(written)
	testing.expect(t, strings.has_prefix(stream, "{\"schema_version\":6,"))
	testing.expect(t, strings.contains(stream, "\"pipeline_flattened\":"))
	testing.expect(t, strings.contains(stream, "\"qualified_name\":"))
	testing.expect(t, strings.contains(stream, "\"dup_class\":"))
	testing.expect(t, strings.count(stream, "\n") > 1)
	log.infof("build verb: pong index.ndjson carries the whole project+decl multi-record stream")
}

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
	testing.expect(t, first.index == second.index)
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

@(test)
test_build_no_partial_product :: proc(t: ^testing.T) {
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Compile_Failed)

	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("build no partial product: a compile error writes neither product (the whole-stream build is all-or-nothing)")
}

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

	testing.expect(t, os.exists(product.artifact_path))
	testing.expect(t, os.exists(product.index_path))
	testing.expect(t, strings.has_prefix(product.artifact, ARTIFACT_MAGIC))

	stream := product.index
	testing.expect(t, strings.contains(stream, "\"qualified_name\":\"arena_game."))
	testing.expect(t, strings.contains(stream, "\"qualified_name\":\"arena_world."))
	testing.expect(t, strings.contains(stream, "\"qualified_name\":\"arena."))
	log.infof("build multi-module arena: exit 0, both products written, index carries decl records from all 3 modules (arena_game + arena_world + arena seam)")
}

@(test)
test_index_stream_multi_module_order :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP build multi-module order: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	stream, err, _, compiled := read_index_project(dir, context.temp_allocator)
	testing.expect_value(t, err, Index_Contract_Error.None)
	testing.expect(t, compiled)
	if err != .None || !compiled {
		return
	}

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

	testing.expect_value(t, product.artifact_path, "")
	testing.expect_value(t, product.artifact, "")
	testing.expect(t, product.index_path != "")
	testing.expect(t, strings.has_prefix(product.index, "{\"schema_version\":6,"))
	testing.expect(t, strings.contains(product.index, "\"entrypoints\":[]"))
	testing.expect(t, strings.contains(product.index, "\"pipeline_flattened\":[]"))

	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)

	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, os.exists(product.index_path))
	testing.expect(t, !os.exists(artifact_path))
	log.infof("build package numerics: §30 §7 index-only build (exit 0, index.ndjson written, NO runtime artifact)")
}

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

	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("release hole-ban: a holed decl under --release is Holed_Declaration (exit 2, compile error, no product) — a hole cannot ship")
}

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

@(test)
test_release_holed_decl_expression_positions :: proc(t: ^testing.T) {
	expr_fn_ast, fn_err := stage_parse(stage_lex("fn boost(base: Fixed) -> Fixed {\n  return base + @stub(Fixed, 0.5)\n}\n"))
	testing.expect_value(t, fn_err, Parse_Error.None)
	declaration, holed := release_holed_decl(expr_fn_ast)
	testing.expect(t, holed)
	testing.expect_value(t, declaration, "boost")

	let_ast, let_err := stage_parse(stage_lex("let SPEED: Fixed = @stub(Fixed, 1.5)\n"))
	testing.expect_value(t, let_err, Parse_Error.None)
	declaration, holed = release_holed_decl(let_ast)
	testing.expect(t, holed)
	testing.expect_value(t, declaration, "SPEED")

	field_ast, field_err := stage_parse(stage_lex("thing Marker {\n  bias: Fixed = @stub(Fixed, 0.0)\n}\n"))
	testing.expect_value(t, field_err, Parse_Error.None)
	declaration, holed = release_holed_decl(field_ast)
	testing.expect(t, holed)
	testing.expect_value(t, declaration, "Marker")

	test_ast, test_err := stage_parse(stage_lex("test \"holed assert\" {\n  assert @stub(Bool)\n}\n"))
	testing.expect_value(t, test_err, Parse_Error.None)
	declaration, holed = release_holed_decl(test_ast)
	testing.expect(t, holed)
	testing.expect_value(t, declaration, "holed assert")
	log.infof("release_holed_decl expression positions: an expression hole in a fn body, a let initializer, a field default, and a test body each name their declaration")
}

@(test)
test_release_walkers_source_order :: proc(t: ^testing.T) {
	holed_ast, holed_err := stage_parse(stage_lex("let FIRST: Fixed = @stub(Fixed, 1.5)\ndata Later { bias: Fixed = @stub(Fixed, 0.0) }\n"))
	testing.expect_value(t, holed_err, Parse_Error.None)
	declaration, holed := release_holed_decl(holed_ast)
	testing.expect(t, holed)
	testing.expect_value(t, declaration, "FIRST")

	probed_ast, probed_err := stage_parse(stage_lex("@log(FIRST)\nlet FIRST: Fixed = 1.5\n@watch(self.bias)\ndata Later { bias: Fixed }\n"))
	testing.expect_value(t, probed_err, Parse_Error.None)
	probed_decl, probed := release_debug_decl(probed_ast)
	testing.expect(t, probed)
	testing.expect_value(t, probed_decl, "FIRST")
	log.infof("release walkers source order: a let preceding a data in source is the first offender for both bans (never the per-kind regrouping)")
}

@(test)
test_gates_skip_holed_units :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex("fn first_hole() -> Fixed @stub(Fixed)\nfn second_hole() -> Fixed @stub(Fixed)\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
	log.infof("gates skip holed units: two holes in one module pass the duplication gate (a hole is body-less, not a scored code unit)")
}

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

	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("release debug ban: a probed decl under --release is Debug_Directive (exit 2, compile error, no product) — debug residue cannot ship")
}

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
	testing.expect(t, strings.contains(product.index, "\"qualified_name\":\"drift\""))
	testing.expect(t, strings.contains(product.index, "\"debug\":[\"log\"]"))
	testing.expect(t, strings.contains(product.index, "\"debug\":[]"))
	log.infof("dev probes compile: the probed tree builds exit 0 in dev mode and the index derives the probe (debug=[\"log\"])")
}

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

EPLAST_ALPHA_HOLED :: "@doc(\"The alpha module: first by sorted path, NOT the entrypoint.\")\n\n@doc(\"An expression hole the index lists AFTER zeta's.\")\nfn alpha_speed(base: Fixed) -> Fixed {\n  return base + @stub(Fixed, 0.5)\n}\n"

EPLAST_ZETA_HOLED :: MINI_SOURCE + "\n@doc(\"An expression hole in the entrypoint module — index-first.\")\nfn zeta_speed(base: Fixed) -> Fixed {\n  return base + @stub(Fixed, 0.5)\n}\n"

@(test)
test_build_release_holed_offender_walks_index_order :: proc(t: ^testing.T) {
	root, ok := write_entrypoint_last_tree(t, "holed", EPLAST_ALPHA_HOLED, EPLAST_ZETA_HOLED)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Holed_Declaration)
	testing.expect_value(t, verdict.offender, "zeta.zeta_speed")

	product, dev_verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, dev_verdict.err, Build_Error.None)
	if dev_verdict.err != .None {
		return
	}
	order := module_prefix_order(product.index)
	testing.expect_value(t, len(order), 2)
	if len(order) != 2 {
		return
	}
	testing.expect_value(t, order[0], "zeta")
	testing.expect_value(t, order[1], "alpha")
	log.infof("release hole-ban walk order: an entrypoint-last tree names the index-first offender (zeta.zeta_speed, never alpha.alpha_speed)")
}

@(test)
test_build_release_probed_offender_walks_index_order :: proc(t: ^testing.T) {
	alpha :: "@doc(\"The alpha module: first by sorted path, NOT the entrypoint.\")\n\n@doc(\"A probed fn the index lists AFTER zeta's.\")\n@log(alpha_speed)\nfn alpha_speed() -> Fixed {\n  return 1.5\n}\n"
	zeta :: MINI_SOURCE + "\n@doc(\"A probed fn in the entrypoint module — index-first.\")\n@log(zeta_speed)\nfn zeta_speed() -> Fixed {\n  return 1.5\n}\n"
	root, ok := write_entrypoint_last_tree(t, "probed", alpha, zeta)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Debug_Directive)
	testing.expect_value(t, verdict.offender, "zeta.zeta_speed")
	log.infof("release debug-ban walk order: an entrypoint-last tree names the index-first offender (zeta.zeta_speed, never alpha.alpha_speed)")
}

@(test)
test_build_refusal_message_shapes :: proc(t: ^testing.T) {
	testing.expect_value(t, build_refusal_message(Build_Verdict{err = .Malformed_Tree}, context.temp_allocator), "Malformed_Tree")
	testing.expect_value(t, build_refusal_message(Build_Verdict{err = .Holed_Declaration, offender = "drag"}, context.temp_allocator), "Holed_Declaration: drag")
	testing.expect_value(t, build_refusal_message(Build_Verdict{err = .Debug_Directive, offender = "beta.DebugMarker"}, context.temp_allocator), "Debug_Directive: beta.DebugMarker")
}

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

copy_pong_tree_to_temp :: proc() -> (root: string, ok: bool) {
	return copy_spec_tree_to_temp(resolve_pong_dir(), "pong", "FUNPACK_PONG_DIR")
}

copy_spec_tree_to_temp :: proc(src: string, label: string, env_name: string) -> (root: string, ok: bool) {
	if !os.is_dir(src) {
		log.warnf("SKIP build %s: %s not found — set %s or ensure the in-repo fixture exists", label, src, env_name)
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

ensure_dir :: proc(path: string) -> bool {
	err := os.make_directory_all(path)
	return err == nil || err == os.General_Error.Exist
}

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
		os.write_entire_file(src_path, "fn broken( {\n") == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build broken tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

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

HOLED_SOURCE :: MINI_SOURCE + "\n@doc(\"A typed hole: dev compiles it, release refuses to ship it.\")\nfn approx_speed() -> Fixed @stub(Fixed)\n"

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

PROBED_SOURCE :: MINI_SOURCE + "\n@doc(\"A probed thing the debug fixture observes.\")\nthing Ball {\n  pos: Int\n}\n\n@doc(\"A probed behavior: dev compiles and indexes the probe, release refuses to ship it.\")\n@log(self.pos)\nbehavior drift on Ball {\n  fn step(self: Ball) -> Ball {\n    return self\n  }\n}\n"

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

write_entrypoint_last_tree :: proc(t: ^testing.T, label: string, alpha_source: string, zeta_source: string) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), tprintf_seq(fmt.tprintf("funpack-build-eplast-%s", label))})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_dir := scratch_join({root, "src"})
	if !ensure_dir(configs) || !ensure_dir(src_dir) {
		log.warnf("SKIP build entrypoint-last tree (%s): cannot create dirs under %s", label, root)
		return "", false
	}
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project eplast {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), "use zeta.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		os.write_entire_file(scratch_join({src_dir, "alpha.fun"}), alpha_source) == nil &&
		os.write_entire_file(scratch_join({src_dir, "zeta.fun"}), zeta_source) == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build entrypoint-last tree (%s): cannot write files under %s", label, root)
		return "", false
	}
	return root, true
}

tprintf_seq :: proc(prefix: string) -> string {
	return fmt.tprintf("%s-%d", prefix, scratch_seq())
}
