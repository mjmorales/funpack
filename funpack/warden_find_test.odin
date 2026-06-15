// The warden find projection tests: the three filters carry exactly their
// stated match semantics (case-sensitive substring on qualified_name, exact
// closed Index_Decl_Kind member name, exact gtags membership — never fuzzy,
// folded, or prefixed), provided filters AND-compose through the shared
// filter-and-reproject core in a single pass that preserves the stream's
// pinned order, a zero-match query projects "" and exits 0 at the verb tier
// ("nothing to reuse — write it" is a successful answer, §29 §4), and the
// live drift tree's `fn damped` projects byte-identical to its producer line
// (the reuse-before-write lookup end-to-end). The drift fixture SKIP-warns
// when the sibling checkout is absent, mirroring the golden skip semantics.
package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_warden_find_name_predicate_substring_case_sensitive :: proc(t: ^testing.T) {
	// name-query ⇔ substring of qualified_name: interior matches hit, the
	// match is case-sensitive (no folding), and a non-substring misses.
	decl := decl_record_fixture(.Fn) // qualified_name "drift.launch_speed"
	testing.expect(t, warden_find_name_predicate(decl, "launch"))
	testing.expect(t, warden_find_name_predicate(decl, "drift.launch_speed"))
	testing.expect(t, warden_find_name_predicate(decl, "t.l"))
	testing.expect(t, !warden_find_name_predicate(decl, "Launch"))
	testing.expect(t, !warden_find_name_predicate(decl, "steer"))
}

@(test)
test_warden_find_kind_predicate_exact_member_name :: proc(t: ^testing.T) {
	// --kind ⇔ the record's kind equals the named closed-enum member —
	// exact, never case-folded, and a sibling member never matches. The
	// unknown-name arm is parse-refused upstream; here it defensively
	// matches nothing.
	fn := decl_record_fixture(.Fn)
	extern := decl_record_fixture(.Extern_Fn)
	testing.expect(t, warden_find_kind_predicate(fn, "Fn"))
	testing.expect(t, warden_find_kind_predicate(extern, "Extern_Fn"))
	testing.expect(t, !warden_find_kind_predicate(extern, "Fn"))
	testing.expect(t, !warden_find_kind_predicate(fn, "fn"))
	testing.expect(t, !warden_find_kind_predicate(fn, "Widget"))
}

@(test)
test_warden_find_gtag_predicate_exact_membership :: proc(t: ^testing.T) {
	// --gtag ⇔ exact membership in the record's gtags: any authored position
	// matches, a substring or prefix of a tag never does, and a tagless
	// record matches nothing.
	decl := decl_record_fixture(.Fn) // gtags ["game", "render"]
	testing.expect(t, warden_find_gtag_predicate(decl, "game"))
	testing.expect(t, warden_find_gtag_predicate(decl, "render"))
	testing.expect(t, !warden_find_gtag_predicate(decl, "rend"))
	testing.expect(t, !warden_find_gtag_predicate(decl, "debt"))
	testing.expect(t, !warden_find_gtag_predicate(empty_lists_decl_record(), "game"))
}

@(test)
test_warden_find_filters_one_per_provided_argument :: proc(t: ^testing.T) {
	// The query → filter-list projection: one filter per provided argument
	// in the fixed name → kind → gtag order, absent arguments contribute
	// nothing, and the full query carries all three.
	testing.expect_value(t, len(warden_find_filters({name = "damped"}, context.temp_allocator)), 1)
	testing.expect_value(t, len(warden_find_filters({kind = "Fn", gtag = "debt"}, context.temp_allocator)), 2)
	full := warden_find_filters({name = "damped", kind = "Fn", gtag = "debt"}, context.temp_allocator)
	testing.expect_value(t, len(full), 3)
	testing.expect_value(t, full[0].needle, "damped")
	testing.expect_value(t, full[1].needle, "Fn")
	testing.expect_value(t, full[2].needle, "debt")
}

@(test)
test_warden_find_filters_and_compose_in_stream_order :: proc(t: ^testing.T) {
	// AND-composition through the shared core over the three-record fixture
	// (drift.launch_speed Fn / drift.board Data debt-tagged / drift.steer
	// Behavior): a name filter alone keeps all three in stream order, each
	// added filter narrows the conjunction, and every projected line is
	// byte-identical to its producer line — the single pass never re-sorts.
	decls := warden_project_fixture()
	index := Warden_Index {
		decls = decls,
	}

	all := warden_find_output(index, {name = "drift."}, context.temp_allocator)
	want_all := strings.concatenate(
		{
			emit_decl_record(decls[0], context.temp_allocator),
			emit_decl_record(decls[1], context.temp_allocator),
			emit_decl_record(decls[2], context.temp_allocator),
		},
		context.temp_allocator,
	)
	testing.expect_value(t, all, want_all)

	// name ∧ kind: only the Fn record survives.
	narrowed := warden_find_output(index, {name = "drift.", kind = "Fn"}, context.temp_allocator)
	testing.expect_value(t, narrowed, emit_decl_record(decls[0], context.temp_allocator))

	// name ∧ gtag: only the debt-tagged Data record survives.
	tagged := warden_find_output(index, {name = "drift.", gtag = WARDEN_DEBT_GTAG}, context.temp_allocator)
	testing.expect_value(t, tagged, emit_decl_record(decls[1], context.temp_allocator))

	// name ∧ kind ∧ gtag with a contradictory conjunction: zero matches
	// project to zero bytes — the empty answer, not an error.
	testing.expect_value(t, warden_find_output(index, {name = "drift.", kind = "Fn", gtag = WARDEN_DEBT_GTAG}, context.temp_allocator), "")

	// Determinism pin: a second run of the same query is byte-identical.
	testing.expect_value(t, warden_find_output(index, {name = "drift.", kind = "Fn"}, context.temp_allocator), narrowed)
}

@(test)
test_warden_verb_exit_find_zero_matches_zero :: proc(t: ^testing.T) {
	// The verb tier over a really-planted index: a matching lookup and a
	// zero-match lookup BOTH exit 0 — an empty result means "nothing to
	// reuse — write it", a successful answer. The warden keeps no exit-1
	// tier.
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	if !write_warden_index_product(t, root, stream) {
		return
	}
	testing.expect_value(t, warden_verb_exit(root, .Find, "", {name = "add"}), 0)
	testing.expect_value(t, warden_verb_exit(root, .Find, "", {name = "no_such_decl"}), 0)
	testing.expect_value(t, warden_verb_exit(root, .Find, "", {kind = "Signal", gtag = "debt"}), 0)
	log.infof("warden find: a zero-match lookup exits 0 — nothing to reuse is a clean answer")
}

@(test)
test_warden_find_drift_live :: proc(t: ^testing.T) {
	// End-to-end over live data (reuse-before-write): the drift tree's
	// emitted stream decodes through the warden consumer and `find damped`
	// returns EXACTLY the one `fn damped` decl record, byte-identical to its
	// producer line; AND-ing --kind Fn keeps it, AND-ing a kind drift does
	// not declare drops it to the empty answer.
	dir := resolve_drift_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP warden find drift: %s not found — set FUNPACK_DRIFT_DIR or ensure the in-repo fixture exists", dir)
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

	found := warden_find_output(index, {name = "damped"}, context.temp_allocator)
	lines := ndjson_lines(found)
	testing.expect_value(t, len(lines), 1)
	testing.expect(t, strings.contains(found, "damped"))
	testing.expect(t, strings.contains(stream, found))

	testing.expect_value(t, warden_find_output(index, {name = "damped", kind = "Fn"}, context.temp_allocator), found)
	testing.expect_value(t, warden_find_output(index, {name = "damped", kind = "Data"}, context.temp_allocator), "")
	log.infof("warden find: drift's damped decl projects byte-identically from the live stream")
}
