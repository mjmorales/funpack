// The warden consumer golden: the drift example tree (funpack-spec/examples/
// drift) proves the producer→consumer contract end-to-end — funpack builds the
// tree and writes `.funpack/index.ndjson`, and `funpack warden`'s acquisition
// seam (read_warden_index) decodes the SAME bytes back onto the producer's own
// record structs, with the §29 §1 refusal contract holding around it (missing
// product, doctored schema_version, over-shaped record — each a closed refusal
// the warden exit mapping turns into 2, never a recompile). Every assertion
// goes through the public consumer seams — read_warden_index plus
// warden_verb_exit — and the round-trip assertions are TYPED struct reads
// (Decl_Record / Project_Record field access), not string-contains greps: the
// decoder exists, so the golden asserts decoded values, the contract proof the
// pre-consumer contains-idiom in golden_drift_test could not make. Like the
// other goldens it resolves the sibling checkout (or FUNPACK_DRIFT_DIR) and
// SKIPs loudly when it is absent — a skipped golden is a warning, never a
// pass.
package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// build_drift_index_root copies the live drift tree into a fresh temp root,
// dev-builds it, writes both products, and reads the written index bytes back
// — the built fixture every golden warden case starts from, so each case
// exercises the index funpack REALLY wrote, never a hand-built stand-in. ok is
// false on the golden SKIP (absent checkout) or, test-failing, on any
// build/write/read failure; a false return owns the scratch-tree cleanup.
build_drift_index_root :: proc(t: ^testing.T) -> (root: string, stream: string, ok: bool) {
	copied: bool
	root, copied = copy_spec_tree_to_temp(resolve_drift_dir(), "drift-warden", "FUNPACK_DRIFT_DIR")
	if !copied {
		return "", "", false
	}
	product, build_err := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, build_err, Build_Error.None)
	if build_err != .None {
		remove_scratch_tree(root)
		return "", "", false
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)
	if write_err != .None {
		remove_scratch_tree(root)
		return "", "", false
	}
	index_bytes, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		remove_scratch_tree(root)
		return "", "", false
	}
	return root, string(index_bytes), true
}

// find_warden_decl finds a decoded decl record by qualified name — the typed
// counterpart of golden_drift_test's line grep. The drift project is
// single-module, so decls qualify to their bare names (read_index_project's
// lore-#11 rule); found = false keeps a renamed fixture loud, never a vacuous
// assert.
find_warden_decl :: proc(index: Warden_Index, qualified_name: string) -> (decl: Decl_Record, found: bool) {
	for candidate in index.decls {
		if candidate.qualified_name == qualified_name {
			return candidate, true
		}
	}
	return Decl_Record{}, false
}

@(test)
test_golden_warden_round_trip_typed_decode :: proc(t: ^testing.T) {
	// ROUND-TRIP: the consumer decodes the exact bytes funpack wrote. Typed
	// struct reads pin the contract — the project record carries this funpack's
	// schema stamp, the decl count equals the stream's decl lines (every line
	// after the leading project record), the bare drag hole decodes stub=true
	// and the intact damped caller stub=false — and the warden exit mapping is
	// 0 for EVERY command over the same root, the whole-stream success tier.
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, index.project.schema_version, INDEX_SCHEMA_VERSION)
	testing.expect_value(t, len(index.decls), len(ndjson_lines(stream)) - 1)

	drag, drag_found := find_warden_decl(index, "drag")
	testing.expect(t, drag_found)
	if drag_found {
		testing.expect(t, drag.stub)
	}
	damped, damped_found := find_warden_decl(index, "damped")
	testing.expect(t, damped_found)
	if damped_found {
		testing.expect(t, !damped.stub)
	}

	for cmd in Warden_Command {
		testing.expect_value(t, warden_verb_exit(root, cmd), 0)
	}
	log.infof("golden warden round-trip: the written drift index decodes whole through the consumer and every command exits 0")
}

@(test)
test_golden_warden_missing_index_refuses_naming_build :: proc(t: ^testing.T) {
	// MISSING-INDEX REFUSAL: the same copied tree WITHOUT a build has no
	// `.funpack/index.ndjson`, so the acquisition is the Missing_Index refusal
	// — line 0, no decls — whose fix-it names `funpack build` (the warden never
	// recompiles in the product's place, §29 §1) and whose exit mapping is 2.
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "drift-warden", "FUNPACK_DRIFT_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.Missing_Index)
	testing.expect_value(t, refusal.line, 0)
	testing.expect_value(t, len(index.decls), 0)
	message := warden_refusal_message(refusal, context.temp_allocator)
	testing.expect(t, strings.contains(message, "`funpack build`"))
	testing.expect(t, strings.contains(message, INDEX_PRODUCT_NAME))
	testing.expect_value(t, warden_verb_exit(root, .Find), 2)
	log.infof("golden warden missing index: an unbuilt drift tree refuses exit 2 with the `funpack build` fix-it")
}

@(test)
test_golden_warden_doctored_schema_version_refused :: proc(t: ^testing.T) {
	// DOCTORED-STREAM REFUSAL (schema): the written index bytes with every
	// line's schema_version stamp bumped to 999 refuse the whole stream as
	// Schema_Mismatch on line 1 — the version gate fires before any shape
	// reading — with the mismatch's OWN fix-it (rebuild with THIS funpack) and
	// exit 2. The surgery is asserted to have hit, so an emitter drift turns
	// the test loud, never vacuous.
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	anchor := fmt.tprintf("\"schema_version\":%d", INDEX_SCHEMA_VERSION)
	doctored, _ := strings.replace_all(stream, anchor, "\"schema_version\":999", context.temp_allocator)
	testing.expect(t, doctored != stream)
	if !write_warden_index_product(t, root, doctored) {
		return
	}

	_, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.Schema_Mismatch)
	testing.expect_value(t, refusal.line, 1)
	testing.expect_value(t, refusal.decode, Index_Read_Error.Schema_Mismatch)
	testing.expect(t, strings.contains(warden_refusal_message(refusal, context.temp_allocator), "rebuild the index with this funpack"))
	testing.expect_value(t, warden_verb_exit(root, .Holes), 2)
	log.infof("golden warden doctored schema: a bumped schema_version refuses the written index exit 2")
}

@(test)
test_golden_warden_injected_extra_key_refused :: proc(t: ^testing.T) {
	// DOCTORED-STREAM REFUSAL (exact-match): one decl line of the written index
	// with an extra top-level key injected is the over-shaped Record_Refused
	// refusal — the per-line decoder's Unknown_Field cause at the offending
	// line — never a best-effort read past it, and the exit mapping is 2 with
	// the generic rebuild fix-it.
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	lines := ndjson_lines(stream)
	testing.expect(t, len(lines) >= 2)
	if len(lines) < 2 {
		return
	}
	doctored := make([dynamic]string, 0, len(lines), context.temp_allocator)
	for line, i in lines {
		full := strings.concatenate({line, "\n"}, context.temp_allocator)
		if i == 1 {
			full = inject_top_level_key(t, full)
		}
		append(&doctored, full)
	}
	joined := strings.concatenate(doctored[:], context.temp_allocator)
	if !write_warden_index_product(t, root, joined) {
		return
	}

	_, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.Record_Refused)
	testing.expect_value(t, refusal.line, 2)
	testing.expect_value(t, refusal.decode, Index_Read_Error.Unknown_Field)
	testing.expect(t, strings.contains(warden_refusal_message(refusal, context.temp_allocator), "`funpack build`"))
	testing.expect_value(t, warden_verb_exit(root, .Graph), 2)
	log.infof("golden warden injected key: an over-shaped decl line refuses the written index exit 2")
}
