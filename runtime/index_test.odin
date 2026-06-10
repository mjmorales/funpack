// The §08 §3 engine-maintained index layer's determinism contract: the
// declared requirement set dedupes in first-declaration order, postings sit in
// the DEFINED ascending (key, Id) order (sign-biased numeric keys order
// numerically, the Id is the tiebreak), the reverse lookup answers in
// ascending-Id order and fails closed everywhere the spec admits no answer,
// the per-tick fold is value-equal to a from-scratch rebuild while SHARING the
// postings of every table the COW commit shared, and the index digest pins the
// maintained content exactly. Self-contained hand-built versions per test —
// the View.of mold lifted to committed Version_Tables.
package funpack_runtime

import "core:testing"

// index_blackboard builds one row's by-name blackboard for the fixtures — the
// state_test mold, allocated on the test temp allocator so the leak checker
// stays clean.
@(private = "file")
index_blackboard :: proc(pairs: ..struct {
		name:  string,
		value: Field_Value,
	}) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	for pair in pairs {
		fields[pair.name] = pair.value
	}
	return fields
}

// index_test_version builds a one-table committed version over hand-built
// blackboards, minting dense ascending Ids — the committed-world counterpart of
// the §08 §2 View.of fixture.
index_test_version :: proc(thing: string, blackboards: []map[string]Field_Value) -> World_Version {
	rows := make([]Row, len(blackboards), context.temp_allocator)
	for fields, i in blackboards {
		rows[i] = Row{id = Id{raw = Thing_Id(i)}, fields = fields}
	}
	tables := make([]Version_Table, 1, context.temp_allocator)
	tables[0] = Version_Table{thing = thing, singleton = false, rows = rows, next_id = Thing_Id(len(rows))}
	return World_Version{tick = 0, tables = tables}
}

// index_test_program builds a Program whose single query declares the given
// requirements — the declaration surface program_index_reqs reads.
index_test_program :: proc(reqs: []Index_Req) -> Program {
	queries := make([]Query_Decl, 1, context.temp_allocator)
	queries[0] = Query_Decl{name = "probe", indexes = reqs}
	return Program{queries = queries}
}

@(test)
test_index_reqs_dedupe_first_declaration_order :: proc(t: ^testing.T) {
	// AC (one structure per requirement): several queries declaring overlapping
	// (kind, thing, field) identities collapse to the distinct set in
	// first-declaration order — an index is a cache, one structure serves all.
	queries := make([]Query_Decl, 2, context.temp_allocator)
	queries[0] = Query_Decl {
		name    = "near",
		indexes = []Index_Req{{kind = .Spatial, thing = "Ball", field = "pos"}, {kind = .Index, thing = "Paddle", field = "side"}},
	}
	queries[1] = Query_Decl {
		name    = "keyed",
		indexes = []Index_Req{{kind = .Index, thing = "Paddle", field = "side"}, {kind = .Index, thing = "Ball", field = "pos"}},
	}
	program := Program{queries = queries}
	reqs := program_index_reqs(&program, context.temp_allocator)
	testing.expect_value(t, len(reqs), 3)
	testing.expect_value(t, reqs[0], Index_Req{kind = .Spatial, thing = "Ball", field = "pos"})
	testing.expect_value(t, reqs[1], Index_Req{kind = .Index, thing = "Paddle", field = "side"})
	testing.expect_value(t, reqs[2], Index_Req{kind = .Index, thing = "Ball", field = "pos"})
}

@(test)
test_index_build_defined_key_then_id_order :: proc(t: ^testing.T) {
	// AC (DEFINED iteration order, §08 §3): postings sort ascending by key with
	// the stable Id as the tiebreak — never the row order the table happened to
	// hold. Variant-token keys order by their token bytes; the two "Side::Left"
	// rows keep ascending Ids.
	version := index_test_version("Paddle", {
		index_blackboard({"side", string("Side::Right")}), // Id 0
		index_blackboard({"side", string("Side::Left")}), // Id 1
		index_blackboard({"side", string("Side::Left")}), // Id 2
	})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	state := build_index_state(&program, &version, context.temp_allocator)
	testing.expect_value(t, len(state.tables), 1)
	table := state.tables[0]
	testing.expect_value(t, table.supported, true)
	testing.expect_value(t, len(table.entries), 3)
	testing.expect_value(t, table.entries[0].id.raw, Thing_Id(1)) // Left, lower Id
	testing.expect_value(t, table.entries[1].id.raw, Thing_Id(2)) // Left, higher Id
	testing.expect_value(t, table.entries[2].id.raw, Thing_Id(0)) // Right
}

@(test)
test_index_numeric_keys_order_numerically :: proc(t: ^testing.T) {
	// AC (order-preserving encoding): the sign-biased big-endian key bytes make
	// byte order EQUAL numeric order, so a negative Int/Fixed key sorts before
	// zero and positive keys — the arithmetic reading, not a raw-bits one.
	version := index_test_version("Probe", {
		index_blackboard({"n", i64(5)}), // Id 0
		index_blackboard({"n", i64(-3)}), // Id 1
		index_blackboard({"n", i64(0)}), // Id 2
	})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Probe", field = "n"}})
	state := build_index_state(&program, &version, context.temp_allocator)
	table := state.tables[0]
	testing.expect_value(t, table.entries[0].id.raw, Thing_Id(1)) // -3
	testing.expect_value(t, table.entries[1].id.raw, Thing_Id(2)) // 0
	testing.expect_value(t, table.entries[2].id.raw, Thing_Id(0)) // 5
}

@(test)
test_index_lookup_answers_ascending_ids_and_fails_closed :: proc(t: ^testing.T) {
	// AC (reverse lookup): the @index lookup answers every matching row in
	// ascending-Id order; a key no row carries is the legitimate empty answer;
	// an undeclared requirement is the absent arm — fail closed, never a guess.
	version := index_test_version("Paddle", {
		index_blackboard({"side", string("Side::Left")}),
		index_blackboard({"side", string("Side::Right")}),
		index_blackboard({"side", string("Side::Left")}),
	})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	state := build_index_state(&program, &version, context.temp_allocator)

	ids, ok := index_lookup(&state, "Paddle", "side", Field_Value(string("Side::Left")), context.temp_allocator)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, len(ids), 2)
	testing.expect_value(t, ids[0].raw, Thing_Id(0))
	testing.expect_value(t, ids[1].raw, Thing_Id(2))

	empty, empty_ok := index_lookup(&state, "Paddle", "side", Field_Value(string("Side::Up")), context.temp_allocator)
	testing.expect_value(t, empty_ok, true)
	testing.expect_value(t, len(empty), 0)

	_, undeclared_ok := index_lookup(&state, "Ball", "pos", Field_Value(string("Side::Left")), context.temp_allocator)
	testing.expect_value(t, undeclared_ok, false)
}

@(test)
test_index_fold_equals_rebuild_and_shares_unchanged :: proc(t: ^testing.T) {
	// AC (maintenance folds with the write set, COW respected): committing a
	// tick that replaces ONE table rebuilds exactly that table's postings,
	// SHARES the untouched table's postings by reference, and the folded state
	// is value-equal — and digest-equal — to a from-scratch rebuild of the
	// committed version.
	ball_rows := make([]Row, 1, context.temp_allocator)
	ball_rows[0] = Row{id = Id{raw = 0}, fields = index_blackboard({"pos", Vec2{to_fixed(1), to_fixed(2)}})}
	paddle_rows := make([]Row, 1, context.temp_allocator)
	paddle_rows[0] = Row{id = Id{raw = 0}, fields = index_blackboard({"side", string("Side::Left")})}
	tables := make([]Version_Table, 2, context.temp_allocator)
	tables[0] = Version_Table{thing = "Ball", rows = ball_rows, next_id = 1}
	tables[1] = Version_Table{thing = "Paddle", rows = paddle_rows, next_id = 1}
	prior := World_Version{tick = 0, tables = tables}

	program := index_test_program([]Index_Req{
		{kind = .Spatial, thing = "Ball", field = "pos"},
		{kind = .Index, thing = "Paddle", field = "side"},
	})
	prior_state := build_index_state(&program, &prior, context.temp_allocator)

	// Commit a next version replacing the Ball table only — the Paddle table is
	// shared by reference, the structural-sharing signature the fold reads.
	moved_rows := make([]Row, 1, context.temp_allocator)
	moved_rows[0] = Row{id = Id{raw = 0}, fields = index_blackboard({"pos", Vec2{to_fixed(7), to_fixed(2)}})}
	changed := make(map[string]Version_Table, context.temp_allocator)
	changed["Ball"] = Version_Table{thing = "Ball", rows = moved_rows, next_id = 1}
	next := commit_version(prior, changed, context.temp_allocator)

	folded := fold_index_state(prior_state, &prior, &next, context.temp_allocator)
	rebuilt := build_index_state(&program, &next, context.temp_allocator)

	testing.expect_value(t, index_states_equal(folded, rebuilt), true)
	testing.expect_value(t, index_state_digest(folded), index_state_digest(rebuilt))
	// The untouched Paddle postings are SHARED by reference (no rebuild); the
	// replaced Ball postings are fresh and carry the moved key.
	testing.expect(t, raw_data(folded.tables[1].entries) == raw_data(prior_state.tables[1].entries))
	testing.expect(t, raw_data(folded.tables[0].entries) != raw_data(prior_state.tables[0].entries))
	moved_key, _ := folded.tables[0].entries[0].key.(Vec2)
	testing.expect_value(t, moved_key.x, to_fixed(7))
}

@(test)
test_index_digest_pins_maintained_content :: proc(t: ^testing.T) {
	// AC (digest-pinned determinism): two builds over the same committed
	// content digest identically, and a one-key difference names itself as a
	// different digest — the per-tick maintenance pin the goldens compare.
	version := index_test_version("Paddle", {
		index_blackboard({"side", string("Side::Left")}),
		index_blackboard({"side", string("Side::Right")}),
	})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	first := build_index_state(&program, &version, context.temp_allocator)
	second := build_index_state(&program, &version, context.temp_allocator)
	testing.expect_value(t, index_state_digest(first), index_state_digest(second))

	moved := index_test_version("Paddle", {
		index_blackboard({"side", string("Side::Left")}),
		index_blackboard({"side", string("Side::Left")}),
	})
	third := build_index_state(&program, &moved, context.temp_allocator)
	testing.expect(t, index_state_digest(first) != index_state_digest(third))
}

@(test)
test_index_unsupported_key_fails_closed :: proc(t: ^testing.T) {
	// AC (fail closed, never a partial index): a missing indexed column marks
	// the whole table unsupported — no postings, every lookup the absent arm —
	// and a key boxing a transient interpreter arm (unreachable off a committed
	// version, but the encoding's closed-set floor) is refused the same way.
	missing := index_test_version("Paddle", {index_blackboard({"other", i64(1)})})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	state := build_index_state(&program, &missing, context.temp_allocator)
	testing.expect_value(t, state.tables[0].supported, false)
	testing.expect_value(t, len(state.tables[0].entries), 0)
	_, ok := index_lookup(&state, "Paddle", "side", Field_Value(string("Side::Left")), context.temp_allocator)
	testing.expect_value(t, ok, false)

	transient := Value(Lambda_Value{})
	boxed := index_test_version("Paddle", {
		index_blackboard({"side", Variant_Value{enum_type = "Side", case_name = "Odd", payload = &transient}}),
	})
	boxed_state := build_index_state(&program, &boxed, context.temp_allocator)
	testing.expect_value(t, boxed_state.tables[0].supported, false)
}

@(test)
test_step_tick_folds_indices_at_commit_boundary :: proc(t: ^testing.T) {
	// AC (maintenance rides the per-tick transaction): step_tick with a
	// maintained Index_State folds it forward exactly once, at the commit
	// boundary, to the state a from-scratch rebuild of the committed version
	// produces — value-equal and digest-equal. No slice-sharing pin here: the
	// plain driver's commit_tick_tables re-packs EVERY working table into a
	// fresh row slice (the sort-by-Id repack), so the fold's COW fast path
	// never fires across a step_tick and every declared table rebuilds — an
	// allocation cost, never a semantic one (the sharing fast path is pinned at
	// the commit_version level by the fold test above).
	version := index_test_version("Paddle", {index_blackboard({"side", string("Side::Left")})})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	indices := build_index_state(&program, &version, context.temp_allocator)

	next := step_tick(&program, version, Input{}, time_resource(60, context.temp_allocator), context.temp_allocator, nil, &indices)
	rebuilt := build_index_state(&program, &next, context.temp_allocator)
	testing.expect_value(t, index_states_equal(indices, rebuilt), true)
	testing.expect_value(t, index_state_digest(indices), index_state_digest(rebuilt))
}
