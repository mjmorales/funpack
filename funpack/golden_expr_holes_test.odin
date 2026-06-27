package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

EXPR_HOLE_GOVERNANCE_ADDITION ::
	"\n@doc(\"Hole fixture: an expression-position fallback hole standing inside an intact fn body.\")\n" +
	"fn hole_serve_boost(base: Fixed) -> Fixed {\n" +
	"  return base + @stub(Fixed, 0.5)\n" +
	"}\n" +
	"\n" +
	"test \"hole fixture: a bare expression hole stands in a test assert\" {\n" +
	"  assert @stub(Bool)\n" +
	"}\n"

EXPR_HOLE_TEST_DECL_NAME :: "hole fixture: a bare expression hole stands in a test assert"

amend_expr_holed_pong_root :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	copied: bool
	root, copied = copy_spec_tree_to_temp(resolve_pong_dir(), "pong-expr-holes", "FUNPACK_PONG_DIR")
	if !copied {
		return "", false
	}
	if !append_scratch_tree_file(t, root, "src/pong.fun", EXPR_HOLE_GOVERNANCE_ADDITION) {
		remove_scratch_tree(root)
		return "", false
	}
	return root, true
}

@(test)
test_golden_expr_holed_pong_dev_build_indexes_stub_debt :: proc(t: ^testing.T) {
	root, ok := amend_expr_holed_pong_root(t)
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
	if write_err != .None {
		return
	}
	testing.expect(t, os.exists(build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)))
	testing.expect(t, os.exists(build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)))

	index_bytes, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	stream := string(index_bytes)

	fn_line, fn_found := index_decl_line(stream, "hole_serve_boost")
	testing.expect(t, fn_found)
	testing.expect(t, strings.contains(fn_line, "\"kind\":\"Fn\""))
	testing.expect(t, strings.contains(fn_line, "\"stub\":true"))

	test_line, test_found := index_decl_line(stream, EXPR_HOLE_TEST_DECL_NAME)
	testing.expect(t, test_found)
	testing.expect(t, strings.contains(test_line, "\"kind\":\"Test\""))
	testing.expect(t, strings.contains(test_line, "\"stub\":true"))

	pristine_line, pristine_found := index_decl_line(stream, "advance")
	testing.expect(t, pristine_found)
	testing.expect(t, strings.contains(pristine_line, "\"stub\":false"))
	log.infof("golden expression holes dev build: exit 0, both products, and the index registers stub=true on the holed fn and the holed test while pristine decls stay false")
}

@(test)
test_golden_expr_holed_pong_release_build_and_check_refuse :: proc(t: ^testing.T) {
	root, ok := amend_expr_holed_pong_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Holed_Declaration)
	testing.expect(t, !os.exists(build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)))
	testing.expect(t, !os.exists(build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)))

	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect_value(t, run_check_verb(root, .Release), 2)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("golden expression holes release: build refuses Holed_Declaration with no product and check adjudicates dev 0 / release 2 — an expression hole cannot ship")
}
