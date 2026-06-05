// Read-layer proof for the §08 world-as-database surface: View[T] iterates in
// stable Id order, Ref resolves to Some on a live row and None on a despawned or
// absent one (both arms forced via the View.of fixture, §08 §2), a singleton
// exposes exactly one row accessed by type while pong's ordinary single-instance
// Scoreboard rides the plain View path, and a COW-committed tick version is
// readable without mutating the prior version (structural sharing, §08 §4).
// Every assertion is a pure read of a committed version — no mutation, no spawn,
// no setup (the read side, §08 §1 CQRS).
package funpack_runtime

import "core:testing"

// blackboard_with builds one row's by-name blackboard for the fixtures — the
// descriptor-driven stand-in for a typed struct literal. Allocated on the test
// temp allocator so the leak checker stays clean.
@(private = "file")
blackboard_with :: proc(pairs: ..struct {
		name:  string,
		value: Field_Value,
	}) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	for pair in pairs {
		fields[pair.name] = pair.value
	}
	return fields
}

// View.of assigns each element a dense Id in order; iteration then walks that
// stable Id order. The fixture View is iteration-identical to a committed one.
@(test)
test_view_of_iterates_in_stable_id_order :: proc(t: ^testing.T) {
	view := view_of(
		"Paddle",
		{
			blackboard_with({"score", i64(0)}),
			blackboard_with({"score", i64(1)}),
			blackboard_with({"score", i64(2)}),
		},
		context.temp_allocator,
	)
	testing.expect_value(t, view_count(view), 3)

	// at(i) walks rows in ascending Id order — element i carries Id i and the
	// blackboard supplied at position i (§08 §2).
	for i in 0 ..< view_count(view) {
		row, ok := view_at(view, i)
		testing.expect(t, ok)
		testing.expect_value(t, row.id, Id{raw = Thing_Id(i)})
		score, present := row_field(row, "score")
		testing.expect(t, present)
		testing.expect_value(t, score.(i64), i64(i))
	}

	// at past the end takes the absent arm, never indexes past the view.
	_, oob := view_at(view, 3)
	testing.expect(t, !oob)
}

// Ref resolve forces BOTH arms via the View.of fixture (§08 §2): a ref(i) into a
// live view resolves Some to the i-th row; a ref to an Id no row carries
// resolves None — a use-after-despawn is unrepresentable as a live row (§08 §1).
@(test)
test_ref_resolves_some_on_live_none_on_absent :: proc(t: ^testing.T) {
	view := view_of(
		"Ball",
		{blackboard_with({"side", "Side::Left"}), blackboard_with({"side", "Side::Right"})},
		context.temp_allocator,
	)

	// Some arm: ref(1) -> Ref -> resolve back to the row at index 1.
	ref1, ok := view_ref(view, 1)
	testing.expect(t, ok)
	testing.expect_value(t, ref1.thing, "Ball")
	testing.expect_value(t, ref1.id, Id{raw = Thing_Id(1)})

	row, some := view_resolve(view, ref1)
	testing.expect(t, some)
	side, present := row_field(row, "side")
	testing.expect(t, present)
	testing.expect_value(t, side.(string), "Side::Right")

	// None arm: a Ref to an Id past the populated rows (a despawned/absent
	// referent) resolves None — totality forces the dangling case.
	dangling := Ref{thing = "Ball", id = Id{raw = Thing_Id(99)}}
	_, dangling_some := view_resolve(view, dangling)
	testing.expect(t, !dangling_some)

	// A Ref carrying a different thing type never resolves in this view —
	// referential integrity by phantom type (§08 §1).
	wrong_type := Ref{thing = "Paddle", id = Id{raw = Thing_Id(0)}}
	_, wrong_some := view_resolve(view, wrong_type)
	testing.expect(t, !wrong_some)
}

// A Ref column read from one row resolves to a row in another table through a
// committed version — the §08 §1 resolve-then-read join (Door.gate: Ref[Switch]).
@(test)
test_ref_column_resolves_across_tables :: proc(t: ^testing.T) {
	// A committed version with two switches and one door whose gate Refs switch 1.
	switches := []Row {
		{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"open", i64(0)})},
		{id = Id{raw = Thing_Id(1)}, fields = blackboard_with({"open", i64(1)})},
	}
	gate_ref := Ref{thing = "Switch", id = Id{raw = Thing_Id(1)}}
	doors := []Row{{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"gate", gate_ref})}}

	version := World_Version {
		tick = 0,
		tables = {
			{thing = "Switch", singleton = false, rows = switches, next_id = Thing_Id(2)},
			{thing = "Door", singleton = false, rows = doors, next_id = Thing_Id(1)},
		},
	}

	door_view := view_of_type(&version, "Door")
	door, ok := view_at(door_view, 0)
	testing.expect(t, ok)

	// Read the Ref column, resolve it world-wide to the live switch row.
	ref, ref_ok := row_ref(door, "gate")
	testing.expect(t, ref_ok)
	switch_row, some := resolve_ref(&version, ref)
	testing.expect(t, some)
	open, present := row_field(switch_row, "open")
	testing.expect(t, present)
	testing.expect_value(t, open.(i64), i64(1))
}

// A singleton exposes exactly ONE row accessed by type (§08 §3, §06 §2): the
// row-count-1 slot resolves to its single row, and a not-yet-spawned singleton
// (zero rows) takes the absent arm rather than assume a row.
@(test)
test_singleton_exposes_exactly_one_row_by_type :: proc(t: ^testing.T) {
	the_row := Row{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"phase", "Phase::Day"})}
	version := World_Version {
		tick = 0,
		tables = {
			{thing = "GameState", singleton = true, rows = {the_row}, next_id = Thing_Id(1)},
			{thing = "Empty", singleton = true, rows = nil, next_id = Thing_Id(0)},
		},
	}

	// The spawned singleton resolves by type to its one row — no index needed.
	row, ok := singleton_row(&version, "GameState")
	testing.expect(t, ok)
	phase, present := row_field(row, "phase")
	testing.expect(t, present)
	testing.expect_value(t, phase.(string), "Phase::Day")

	// A singleton with no committed row takes the absent arm (un-spawned).
	_, empty_ok := singleton_row(&version, "Empty")
	testing.expect(t, !empty_ok)

	// An undeclared thing is the absent arm too.
	_, missing_ok := singleton_row(&version, "Nonexistent")
	testing.expect(t, !missing_ok)
}

// Pong's ordinary single-instance path: a NON-singleton thing holding exactly
// one row is read through the plain View (the singleton slot stays generic while
// pong rides this path, per the execution-model decision). The singleton accessor
// refuses it — it is not a declared singleton.
@(test)
test_ordinary_single_instance_thing_path :: proc(t: ^testing.T) {
	scoreboard := Row {
		id     = Id{raw = Thing_Id(0)},
		fields = blackboard_with({"left", i64(3)}, {"right", i64(5)}),
	}
	version := World_Version {
		tick   = 0,
		tables = {{thing = "Scoreboard", singleton = false, rows = {scoreboard}, next_id = Thing_Id(1)}},
	}

	// Scoreboard is a plain thing: read it through the ordinary View, one row.
	view := view_of_type(&version, "Scoreboard")
	testing.expect_value(t, view_count(view), 1)
	row, ok := view_at(view, 0)
	testing.expect(t, ok)
	left, l_present := row_field(row, "left")
	right, r_present := row_field(row, "right")
	testing.expect(t, l_present && r_present)
	testing.expect_value(t, left.(i64), i64(3))
	testing.expect_value(t, right.(i64), i64(5))

	// The singleton accessor refuses an ordinary thing — both paths coexist.
	_, singleton_ok := singleton_row(&version, "Scoreboard")
	testing.expect(t, !singleton_ok)
}

// A committed COW tick version is readable without mutating the prior version
// (§08 §4): committing a next tick that changes only one table SHARES the
// untouched tables by reference, and the prior version still reads its own rows.
@(test)
test_cow_commit_shares_and_leaves_prior_readable :: proc(t: ^testing.T) {
	world := load_two_table_world(t)
	defer delete(world.tables)
	base := initial_version(world, context.temp_allocator)

	// Commit tick 0: populate only Ball with one row; Paddle is shared empty.
	ball_row := Row{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"speed", to_fixed(2)})}
	changed := make(map[string]Version_Table, context.temp_allocator)
	changed["Ball"] = Version_Table {
		thing   = "Ball",
		rows    = {ball_row},
		next_id = Thing_Id(1),
	}
	v0 := commit_version(base, changed, context.temp_allocator)
	testing.expect_value(t, v0.tick, 0)

	// v0 reads the new Ball row; base (the prior version) still reads empty Ball
	// — the prior version was NOT mutated by the commit.
	v0_balls := view_of_type(&v0, "Ball")
	testing.expect_value(t, view_count(v0_balls), 1)
	base_balls := view_of_type(&base, "Ball")
	testing.expect_value(t, view_count(base_balls), 0)

	// The untouched Paddle table is SHARED from base into v0 by reference —
	// structural sharing, not a copy (§08 §4). Same backing rows slice.
	base_paddle := version_find_table(&base, "Paddle")
	v0_paddle := version_find_table(&v0, "Paddle")
	testing.expect(t, base_paddle != nil && v0_paddle != nil)
	testing.expect_value(t, raw_data(v0_paddle.rows), raw_data(base_paddle.rows))

	// Commit tick 1 on top of v0, changing only Paddle: v0's Ball is still
	// readable, proving each version is an independent immutable MVCC snapshot.
	paddle_row := Row{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"y", to_fixed(0)})}
	changed1 := make(map[string]Version_Table, context.temp_allocator)
	changed1["Paddle"] = Version_Table {
		thing   = "Paddle",
		rows    = {paddle_row},
		next_id = Thing_Id(1),
	}
	v1 := commit_version(v0, changed1, context.temp_allocator)
	testing.expect_value(t, v1.tick, 1)

	// v1 sees both the inherited Ball (shared from v0) and the new Paddle row.
	testing.expect_value(t, view_count(view_of_type(&v1, "Ball")), 1)
	testing.expect_value(t, view_count(view_of_type(&v1, "Paddle")), 1)
	// v0 is unchanged: it never gained the Paddle row tick 1 added.
	testing.expect_value(t, view_count(view_of_type(&v0, "Paddle")), 0)
}

// load_two_table_world builds a minimal two-thing empty World directly (Paddle,
// Ball) without the full artifact, so the COW test exercises the version model in
// isolation from the loader. The state layer lifts any World into the versioned
// read model — it does not depend on the golden artifact for its own proof.
@(private = "file")
load_two_table_world :: proc(t: ^testing.T) -> World {
	tables := make([]Thing_Table, 2)
	tables[0] = Thing_Table{thing = "Paddle", singleton = false, next_id = Thing_Id(0)}
	tables[1] = Thing_Table{thing = "Ball", singleton = false, next_id = Thing_Id(0)}
	return World{tables = tables}
}

// The state layer lifts the GOLDEN pong world into the versioned read model: the
// initial empty version mirrors the loader's three declared things, each with an
// empty View, proving the read surface composes over the real artifact substrate
// (Paddle, Ball, Scoreboard — and Scoreboard is the ordinary single-instance
// thing, not a singleton).
@(test)
test_initial_version_over_golden_world :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := initial_version(world, context.temp_allocator)

	// Three declared things, every View empty before setup runs.
	testing.expect_value(t, len(version.tables), 3)
	testing.expect_value(t, view_count(view_of_type(&version, "Paddle")), 0)
	testing.expect_value(t, view_count(view_of_type(&version, "Ball")), 0)
	testing.expect_value(t, view_count(view_of_type(&version, "Scoreboard")), 0)

	// Scoreboard is a plain thing, not a singleton — the singleton accessor
	// refuses it even on an empty version (the descriptor says non-singleton).
	scoreboard := version_find_table(&version, "Scoreboard")
	testing.expect(t, scoreboard != nil)
	testing.expect(t, !scoreboard.singleton)
}
