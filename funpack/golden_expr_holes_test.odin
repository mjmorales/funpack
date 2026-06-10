// The §05 §2 EXPRESSION-position typed-hole governance golden (grammar/fun.ebnf
// §15: StubExpr is an Atom), the drift body-hole golden's sibling: one fixture
// tree whose ONLY holes stand in expression position — a fallback hole inside
// an intact fn body and a bare hole inside a test assert — and the compile
// modes adjudicate it exactly as the spec promises: dev builds green (writing
// BOTH products) and the index registers each containing declaration as stub
// debt, while release refuses with Holed_Declaration writing nothing, on both
// adjudicating verbs (build AND check). An expression hole is governed exactly
// like a body hole — same index field, same §29 §4 ban — with no body-position
// hole anywhere in the tree to mask the verdict.
//
// FIXTURE TECHNIQUE: no committed spec example authors an expression-position
// hole yet, so the fixture follows the probes golden's amended-scratch mold
// (golden_probes_test.odin): the live PONG tree is copied to temp and the hole
// addendum appended BEFORE the build, so every asserted byte is what funpack
// really wrote over the amended tree — never a doctored product. Pong, not
// drift, is the base deliberately: drift already carries §05 BODY-position
// holes, so its tree could never isolate the release refusal (or the stub
// index bit) to the expression position alone; pong is hole-free, making this
// an expression-hole-ONLY tree. When a spec example authors an expression
// hole, these pins move to the pristine tree. Like the other goldens it
// resolves the sibling checkout (or FUNPACK_PONG_DIR) and SKIPs loudly when
// absent — a skipped golden is a warning, never a pass.
package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// EXPR_HOLE_GOVERNANCE_ADDITION is the expression-hole addendum appended to
// the copied pong source: a fn whose INTACT body carries the two-argument
// `@stub(Fixed, 0.5)` hole (the emitted-record case — the fallback is the dev
// value the artifact lowers), and a test block whose assert carries the BARE
// `@stub(Bool)` hole (the never-emitted case — tests join the index, not the
// artifact, so the bare form's dev-compile is proven without touching the
// runtime byte format). The names share no substring with any pristine pong
// decl, so a per-name index lookup answers exactly one record.
EXPR_HOLE_GOVERNANCE_ADDITION ::
	"\n@doc(\"Hole fixture: an expression-position fallback hole standing inside an intact fn body.\")\n" +
	"fn hole_serve_boost(base: Fixed) -> Fixed {\n" +
	"  return base + @stub(Fixed, 0.5)\n" +
	"}\n" +
	"\n" +
	"test \"hole fixture: a bare expression hole stands in a test assert\" {\n" +
	"  assert @stub(Bool)\n" +
	"}\n"

// EXPR_HOLE_TEST_DECL_NAME is the addendum's test-block declaration name — the
// quoted string a test indexes under (single-module pong qualifies decls to
// their bare names).
EXPR_HOLE_TEST_DECL_NAME :: "hole fixture: a bare expression hole stands in a test assert"

// amend_expr_holed_pong_root copies the live pong tree into a fresh temp root
// and appends the expression-hole addendum to its source BEFORE any build —
// the probes golden's pre-build amendment seam, so the products under test are
// exactly what funpack wrote over the amended tree. ok = false on the golden
// SKIP (absent checkout) or a write failure; a false return owns the cleanup.
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
	// AC (dev green + indexed): the expression-holed tree built in Dev mode
	// (the no-flag default) is exit 0 and writes BOTH products — an expression
	// hole is a first-class dev citizen exactly like a body hole — and the
	// written index registers stub=true on EACH declaration containing a hole
	// (the fallback-holed fn AND the bare-holed test), while a pristine pong
	// decl keeps stub=false — the index discriminates the holed decls, not
	// merely the file.
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
	// AC (release ban): the SAME expression-holed tree under --release is the
	// exit-2 compile-error outcome on BOTH adjudicating verbs — stage_build
	// refuses with Holed_Declaration (the §29 §4 hole-ban, fired by the
	// EXPRESSION hole alone: pong carries no body hole) writing NEITHER
	// product, and the check verb adjudicates dev 0 / release 2 with no
	// `.funpack/` after either verdict. Never a counted failure: neither verb
	// has an exit-1 tier.
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
