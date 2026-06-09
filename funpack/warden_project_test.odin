// The warden decl-predicate projection tests: the shared filter-and-reproject
// core re-emits matches byte-identical to their producer lines in the input
// stream's pinned order (no re-sort, no map iteration — two passes over the
// same slice concatenate the same bytes), the holes/debt predicates match
// exactly their §29 §4 semantics (stub; todo OR the registered `debt` gtag),
// an empty match set projects to "" and exits 0 at the verb tier
// (empty-result-is-success — the warden adjudicates nothing), and the live
// drift tree's two §05 typed holes (drag, launch_speed) project end-to-end
// through the producer's own emitted stream. The drift fixture SKIP-warns
// when the sibling checkout is absent, mirroring the golden skip semantics.
package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// warden_match_all is the identity predicate: every record matches, so the
// core's output must be the producer lines' exact concatenation — the
// byte-identity and order pin with no filtering in the way.
warden_match_all :: proc(decl: Decl_Record, needle: string) -> bool {
	_ = decl
	_ = needle
	return true
}

// warden_match_none is the empty predicate: no record matches, so the core's
// output must be "" — the empty projection, a success and not an error.
warden_match_none :: proc(decl: Decl_Record, needle: string) -> bool {
	_ = decl
	_ = needle
	return false
}

// warden_project_fixture builds a three-record slice with distinct hole/debt
// shapes: a stubbed fn (holes hit), an intact data record carrying the
// registered `debt` gtag (debt hit), and an intact behavior with neither
// (no query hits it). The slice order is the pinned "stream" order every
// order assertion reads against.
warden_project_fixture :: proc() -> []Decl_Record {
	stubbed := decl_record_fixture(.Fn) // fixture stamps stub = true
	stubbed.qualified_name = "drift.launch_speed"

	indebted := decl_record_fixture(.Data)
	indebted.qualified_name = "drift.board"
	indebted.stub = false
	debt_tags := make([]string, 2, context.temp_allocator)
	debt_tags[0], debt_tags[1] = "game", WARDEN_DEBT_GTAG
	indebted.gtags = debt_tags

	clean := decl_record_fixture(.Behavior)
	clean.qualified_name = "drift.steer"
	clean.stub = false

	decls := make([]Decl_Record, 3, context.temp_allocator)
	decls[0], decls[1], decls[2] = stubbed, indebted, clean
	return decls
}

@(test)
test_warden_project_decls_byte_identity_and_order :: proc(t: ^testing.T) {
	// The identity projection: every record re-emits, and the output is the
	// producer lines' exact concatenation in input order — a projected line
	// is byte-identical to its producer line, never a re-marshal drift.
	decls := warden_project_fixture()
	want := strings.concatenate(
		{
			emit_decl_record(decls[0], context.temp_allocator),
			emit_decl_record(decls[1], context.temp_allocator),
			emit_decl_record(decls[2], context.temp_allocator),
		},
		context.temp_allocator,
	)
	got := warden_project_decls(decls, warden_match_all, "", context.temp_allocator)
	testing.expect_value(t, got, want)

	// Determinism pin: a second pass over the same slice is byte-identical.
	again := warden_project_decls(decls, warden_match_all, "", context.temp_allocator)
	testing.expect_value(t, again, got)
}

@(test)
test_warden_project_decls_filter_preserves_stream_order :: proc(t: ^testing.T) {
	// A filtering predicate (holes ∪ debt here: records 0 and 1, not 2) keeps
	// the survivors in input order — the filter pass never re-sorts.
	decls := warden_project_fixture()
	either := proc(decl: Decl_Record, needle: string) -> bool {
		return warden_holes_predicate(decl, needle) || warden_debt_predicate(decl, needle)
	}
	want := strings.concatenate(
		{
			emit_decl_record(decls[0], context.temp_allocator),
			emit_decl_record(decls[1], context.temp_allocator),
		},
		context.temp_allocator,
	)
	got := warden_project_decls(decls, either, "", context.temp_allocator)
	testing.expect_value(t, got, want)
}

@(test)
test_warden_project_decls_empty_result_is_empty_output :: proc(t: ^testing.T) {
	// Zero matches project to zero bytes — an empty result is a successful
	// projection (the verb prints nothing and exits 0), never an error. The
	// empty input slice projects the same "" through the same path.
	decls := warden_project_fixture()
	testing.expect_value(t, warden_project_decls(decls, warden_match_none, "", context.temp_allocator), "")
	testing.expect_value(t, warden_project_decls(nil, warden_match_all, "", context.temp_allocator), "")
}

@(test)
test_warden_holes_predicate_is_stub :: proc(t: ^testing.T) {
	// holes ⇔ stub: the §05 §2 typed-hole flag alone decides — a debt gtag,
	// a todo, or any other field never makes a hole.
	decls := warden_project_fixture()
	testing.expect(t, warden_holes_predicate(decls[0], ""))  // stubbed fn
	testing.expect(t, !warden_holes_predicate(decls[1], "")) // intact, debt-tagged
	testing.expect(t, !warden_holes_predicate(decls[2], "")) // intact, untagged
}

@(test)
test_warden_debt_predicate_todo_or_debt_gtag :: proc(t: ^testing.T) {
	// debt ⇔ todo == true OR "debt" ∈ gtags — each half alone matches, both
	// together match (once), neither leaves the record out, and a non-debt
	// gtag never matches.
	decls := warden_project_fixture()
	testing.expect(t, warden_debt_predicate(decls[1], ""))  // gtag half, live
	testing.expect(t, !warden_debt_predicate(decls[0], "")) // stubbed but not debt
	testing.expect(t, !warden_debt_predicate(decls[2], "")) // neither half

	// The todo half: constant-false on every current tree (the parser does
	// not yet admit @todo), but the predicate reads the contract field as
	// defined — a decoded todo=true record is debt with no gtag needed.
	todo_only := decl_record_fixture(.Fn)
	todo_only.stub = false
	todo_only.todo = true
	testing.expect(t, warden_debt_predicate(todo_only, ""))

	both := decl_record_fixture(.Fn)
	both.todo = true
	both.gtags = decls[1].gtags
	testing.expect(t, warden_debt_predicate(both, ""))
}

@(test)
test_warden_verb_exit_empty_projection_zero :: proc(t: ^testing.T) {
	// Empty-result-is-success at the verb tier: the planted fixture stream
	// (data Board / signal Goal / fn add — no stubs, no gtags) matches
	// neither query, and both commands still exit 0 printing nothing. The
	// warden has no exit-1 tier; an empty projection is a clean verdict.
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	if !write_warden_index_product(t, root, stream) {
		return
	}
	testing.expect_value(t, warden_verb_exit(root, .Holes), 0)
	testing.expect_value(t, warden_verb_exit(root, .Debt), 0)
	log.infof("warden projection: an empty holes/debt result exits 0 — empty output is success")
}

@(test)
test_warden_holes_drift_live :: proc(t: ^testing.T) {
	// End-to-end over live data: the drift tree's emitted stream decodes
	// through the warden consumer and the holes projection lists EXACTLY the
	// two §05 typed holes — fn drag() @stub(Fixed) and fn launch_speed
	// @stub(Fixed, boost+6.0) — each line byte-identical to its producer
	// line in the stream. debt projects empty on drift: no @todo parses and
	// no `debt` gtag is authored there.
	dir := resolve_drift_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP warden holes drift: %s not found — set FUNPACK_DRIFT_DIR or check out funpack-spec as a sibling", dir)
		return
	}
	stream, err, compiled := read_index_project(dir, context.temp_allocator)
	testing.expect_value(t, err, Index_Contract_Error.None)
	testing.expect(t, compiled)
	if !compiled {
		return
	}
	index, refusal := decode_warden_index(stream, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}

	holes := warden_project_decls(index.decls, warden_holes_predicate, "", context.temp_allocator)
	hole_lines := ndjson_lines(holes)
	testing.expect_value(t, len(hole_lines), 2)
	testing.expect(t, strings.contains(holes, "drag"))
	testing.expect(t, strings.contains(holes, "launch_speed"))
	for line in hole_lines {
		full := strings.concatenate({line, "\n"}, context.temp_allocator)
		testing.expect(t, strings.contains(stream, full))
	}

	testing.expect_value(t, warden_project_decls(index.decls, warden_debt_predicate, "", context.temp_allocator), "")
	log.infof("warden projection: drift's two typed holes project byte-identically from the live stream")
}
