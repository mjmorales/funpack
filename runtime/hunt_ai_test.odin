// AI-fold proof for hunt's patrol/chase/search state machine (spec §13 §1 §2,
// §08): the canonical semantics of hunt's decomposed AI is what THIS interpreter
// computes over the §2.7 node forest, so each transition arm is pinned against a
// HAND-BUILT hunt program — the things/enums/functions/think behavior built
// node-by-node, NOT loaded from an emitted artifact (the hunt artifact is the
// sibling-compiler epic's leaf; runtime proves the engine arms compose ahead of
// it, the interp_test/state_test hand-built-fixture pattern, team Lore #8).
//
// Two surfaces are proven here:
//   1. The AI transition unit tests pin every arm under EXACT equality — patrol→
//      chase on sight (records last_seen), chase→search-with-full-timer on lost
//      sight, search re-acquire→chase, search give-up→patrol at timer zero, and
//      think dispatch ending a patrolling-and-sighting hunter in Chase. Each runs
//      hunt's real body forest through eval, so it is the §13 state machine = enum
//      + exhaustive match (the match IS the transition function), the perception a
//      pure predicate over a View, and the countdown a Fixed field folded by Time
//      (search_t - dt, t <= 0.0) — never an async delay.
//   2. A behavior-fold test over a TWO-Hunter + one-Player population proves
//      run_behavior_over_instances folds each Hunter INDEPENDENTLY in stable Id
//      order against the SHARED Player View (§08 §2): the near hunter flips to
//      Chase, the far hunter stays Patrol, off one step_tick — the multi-row
//      surface pong's single Ball/Paddle never exercised.
package funpack_runtime

import "core:testing"

// SEARCH_TIME mirrors hunt.fun's give-up countdown const (spec §13 §2): the full
// timer the chase→search drop resets, asserted bit-exact through the kernel so no
// float reaches the value (§10). SIGHT and H_SPEED travel inside the hand-built
// program (hunt_fixtures_test.odin), so only the timer the chase test pins back is
// restated here.
@(private = "file")
HUNT_SEARCH_TIME :: 2

// --- AI transition unit tests (every arm, exact equality) -----------------

// patrol flips to Chase and records the sighting the moment the player is seen
// (§13 §1: the match IS the transition function). The Some(p) arm binds the
// seen point and writes `ai: Chase, last_seen: p`; the result is pinned exactly.
@(test)
test_hunt_patrol_switches_to_chase_on_sight :: proc(t: ^testing.T) {
	program := hunt_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := hunt_interp(&program, &version)

	self := hunter_value(Vec2{to_fixed(0), to_fixed(0)}, Vec2{to_fixed(0), to_fixed(0)}, "Patrol")
	seen := some_value(&interp, Vec2{to_fixed(5), to_fixed(0)})

	after, ok := hunt_call_two(&interp, "patrol", self, seen)
	testing.expect(t, ok)
	rec := after.(Record_Value)
	expect_hunt_state(t, rec, "Chase")
	expect_vec2_field(t, rec, "last_seen", Vec2{to_fixed(5), to_fixed(0)})
}

// patrol with no sight walks home and stays Patrol — the None arm steps pos
// toward home by H_SPEED and leaves ai untouched. Both patrol arms are forced
// (the Some arm above), so the state machine's patrol row is total. The step is
// step_to's `from + delta * (speed / d)`: from=0, delta=10, speed=1, d=10, so the
// x advance is the EXACT kernel value of 10 * (1/10) — NOT the idealized 1.0, since
// 1/10 has no exact Q32.32 representation. Pinning the kernel computation (not an
// idealized magnitude) IS the determinism contract: the motion is whatever the
// fixed-point math yields, bit-for-bit (§10).
@(test)
test_hunt_patrol_walks_home_when_unseen :: proc(t: ^testing.T) {
	program := hunt_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := hunt_interp(&program, &version)

	// Home is 10 to the right; one H_SPEED=1 step advances pos toward it.
	self := hunter_value(Vec2{to_fixed(0), to_fixed(0)}, Vec2{to_fixed(10), to_fixed(0)}, "Patrol")
	after, ok := hunt_call_two(&interp, "patrol", self, none_value())
	testing.expect(t, ok)
	rec := after.(Record_Value)
	expect_hunt_state(t, rec, "Patrol")
	// The exact kernel value of `0 + 10 * (1/10)` over Q32.32 (a near-1.0 the
	// fixed-point division rounds, never the idealized to_fixed(1)).
	want_x := fixed_add(to_fixed(0), fixed_mul(to_fixed(10), fixed_div(to_fixed(1), to_fixed(10))))
	expect_vec2_field(t, rec, "pos", Vec2{want_x, to_fixed(0)})
}

// Losing the player in Chase drops to Search with a FULL give-up timer (§13 §2:
// the wait is a field, set to SEARCH_TIME, never an async delay). The None arm
// writes `ai: Search, search_t: SEARCH_TIME`.
@(test)
test_hunt_chase_drops_to_search_with_full_timer :: proc(t: ^testing.T) {
	program := hunt_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := hunt_interp(&program, &version)

	self := hunter_value(Vec2{to_fixed(0), to_fixed(0)}, Vec2{to_fixed(0), to_fixed(0)}, "Chase")
	after, ok := hunt_call_two(&interp, "chase", self, none_value())
	testing.expect(t, ok)
	rec := after.(Record_Value)
	expect_hunt_state(t, rec, "Search")
	// search_t is reset to the full SEARCH_TIME constant, exactly.
	expect_fixed_field(t, rec, "search_t", to_fixed(HUNT_SEARCH_TIME))
}

// Re-acquiring the player in Search flips straight back to Chase (§13 §1): the
// Some(p) arm short-circuits the countdown and writes `ai: Chase, last_seen: p`,
// regardless of how much timer remained.
@(test)
test_hunt_search_re_acquires_to_chase :: proc(t: ^testing.T) {
	program := hunt_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := hunt_interp(&program, &version)

	self := hunter_with_timer(Vec2{to_fixed(0), to_fixed(0)}, "Search", to_fixed(1))
	seen := some_value(&interp, Vec2{to_fixed(2), to_fixed(0)})
	after, ok := hunt_call_three(&interp, "search", self, seen, dt_half())
	testing.expect(t, ok)
	rec := after.(Record_Value)
	expect_hunt_state(t, rec, "Chase")
	expect_vec2_field(t, rec, "last_seen", Vec2{to_fixed(2), to_fixed(0)})
}

// The search countdown is folded by dt (§13 §2): it GIVES UP to Patrol at zero,
// and KEEPS searching while time remains. Both seek arms are forced off one
// fixture — search_t 0.5 minus dt 0.5 hits t <= 0 (→ Patrol, timer 0); search_t
// 2.0 minus dt 0.5 leaves 1.5 > 0 (→ Search). The state pivots on a Fixed
// compare, not a wall clock.
@(test)
test_hunt_search_gives_up_to_patrol_at_zero :: proc(t: ^testing.T) {
	program := hunt_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := hunt_interp(&program, &version)

	// search_t (0.5) - dt (0.5) == 0 → the t <= 0 arm gives up to Patrol, timer 0.
	expiring := hunter_with_timer(Vec2{to_fixed(0), to_fixed(0)}, "Search", dt_half())
	gave_up, gu_ok := hunt_call_three(&interp, "search", expiring, none_value(), dt_half())
	testing.expect(t, gu_ok)
	gu_rec := gave_up.(Record_Value)
	expect_hunt_state(t, gu_rec, "Patrol")
	expect_fixed_field(t, gu_rec, "search_t", to_fixed(0))

	// search_t (2.0) - dt (0.5) == 1.5 > 0 → still searching, timer decremented.
	searching := hunter_with_timer(Vec2{to_fixed(0), to_fixed(0)}, "Search", to_fixed(2))
	still, s_ok := hunt_call_three(&interp, "search", searching, none_value(), dt_half())
	testing.expect(t, s_ok)
	s_rec := still.(Record_Value)
	expect_hunt_state(t, s_rec, "Search")
	expect_fixed_field(t, s_rec, "search_t", fixed_sub(to_fixed(2), dt_half()))
}

// think dispatches on the CURRENT state (§13 §1: sense once, then match self.ai):
// a patrolling hunter that sees the player ends the tick in Chase. The behavior
// body runs visible() over the View[Player] (perception predicate, length-gated)
// then matches self.ai → patrol(self, seen), proving the whole think→state→arm
// chain composes off one bound env.
@(test)
test_hunt_think_dispatches_on_current_state :: proc(t: ^testing.T) {
	program := hunt_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := hunt_interp(&program, &version)

	think := program_behavior(&program, "think")
	testing.expect(t, think != nil)

	// A patrolling hunter at the origin, a player 5 units away (within SIGHT=30).
	self_row := hunter_row(Vec2{to_fixed(0), to_fixed(0)}, Vec2{to_fixed(50), to_fixed(0)}, "Patrol")
	players := player_view_list(&interp, Vec2{to_fixed(5), to_fixed(0)})

	env := Env{names = make(map[string]Value, context.temp_allocator)}
	env.names["self"] = row_to_record(&interp, self_row)
	env.names["players"] = players
	env.names["time"] = interp.time

	result, ok := eval_behavior_body(&interp, think.body, &env)
	testing.expect(t, ok)
	rec := result.(Record_Value)
	expect_hunt_state(t, rec, "Chase")
}

// --- two-Hunter population fold (stable Id order, per-instance independence) -

// run_behavior_over_instances folds think ONCE PER Hunter in stable Id order
// against the SHARED Player View (§08 §2): two hunters, one player, off ONE
// step_tick. Hunter 0 sits within SIGHT of the player and flips to Chase; Hunter
// 1 sits far away and stays Patrol. The two outcomes off one shared View prove
// each instance is folded independently (one hunter's transition never leaks into
// the other's) and the population iterates in ascending Id order — the multi-row
// surface pong's single Ball/Paddle never reached.
@(test)
test_hunt_two_hunter_population_folds_independently :: proc(t: ^testing.T) {
	program := hunt_program()
	world := new_world(program, context.temp_allocator)
	base := run_startup(&program, initial_version(world, context.temp_allocator), context.temp_allocator)

	// Startup spawned one Player and two Hunters in declaration order (§13 setup):
	// Player at (10, 0); Hunter 0 at (5, 0) — within SIGHT(30) of the player; Hunter
	// 1 at (200, 0) — far outside SIGHT. Both start Patrol.
	testing.expect_value(t, view_count(view_of_type(&base, "Player")), 1)
	testing.expect_value(t, view_count(view_of_type(&base, "Hunter")), 2)

	next := step_tick(&program, base, empty(), hunt_time(context.temp_allocator), context.temp_allocator)

	// The committed Hunter table stays ascending by Id: index 0 is the near hunter,
	// index 1 the far one (stable Id order, §08 §2). Each folded against the SAME
	// Player View, independently.
	hunters := view_of_type(&next, "Hunter")
	testing.expect_value(t, view_count(hunters), 2)

	near, near_ok := view_at(hunters, 0)
	testing.expect(t, near_ok)
	near_ai, near_present := row_field(near, "ai")
	testing.expect(t, near_present)
	// Hunter 0 saw the player (5 units < SIGHT 30) → flipped to Chase, recording
	// the sighting; its transition did not depend on the other hunter.
	testing.expect_value(t, near_ai.(string), "Hunt::Chase")
	near_seen, seen_present := row_field(near, "last_seen")
	testing.expect(t, seen_present)
	testing.expect_value(t, near_seen.(Vec2).x, to_fixed(10))
	testing.expect_value(t, near_seen.(Vec2).y, to_fixed(0))

	far, far_ok := view_at(hunters, 1)
	testing.expect(t, far_ok)
	far_ai, far_present := row_field(far, "ai")
	testing.expect(t, far_present)
	// Hunter 1 did NOT see the player (200 units > SIGHT 30) → stayed Patrol,
	// independent of Hunter 0's flip to Chase. Per-instance independence.
	testing.expect_value(t, far_ai.(string), "Hunt::Patrol")
}

// --- expectation helpers --------------------------------------------------

// expect_hunt_state asserts a hunter record's `ai` column is Hunt::CASE — the
// enum value the match arms write back. A returned record carries the Variant_Value
// the `with { ai: Hunt::… }` produced.
@(private = "file")
expect_hunt_state :: proc(t: ^testing.T, rec: Record_Value, case_name: string) {
	ai, present := rec.fields["ai"]
	testing.expect(t, present)
	variant, is_variant := ai.(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, variant.case_name, case_name)
}

// expect_vec2_field asserts a hunter record's Vec2 column equals the expected
// vector component-for-component (bit-exact, the §10 kernel value).
@(private = "file")
expect_vec2_field :: proc(t: ^testing.T, rec: Record_Value, field: string, want: Vec2) {
	v, present := rec.fields[field]
	testing.expect(t, present)
	got, is_vec2 := v.(Vec2)
	testing.expect(t, is_vec2)
	testing.expect_value(t, got.x, want.x)
	testing.expect_value(t, got.y, want.y)
}

// expect_fixed_field asserts a hunter record's Fixed column equals the expected
// kernel bits — the countdown timer the seek arm folds.
@(private = "file")
expect_fixed_field :: proc(t: ^testing.T, rec: Record_Value, field: string, want: Fixed) {
	v, present := rec.fields[field]
	testing.expect(t, present)
	got, is_fixed := v.(Fixed)
	testing.expect(t, is_fixed)
	testing.expect_value(t, got, want)
}

// --- value fixtures -------------------------------------------------------

// dt_half is the half-second step the search-timer tests fold by — 0.5 in Q32.32
// derived through the kernel (no float reaches the value, §10).
@(private = "file")
dt_half :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(2))
}

// hunt_time is the Time resource think's `time` param binds to — one dt field at
// the fixed 60hz step, kernel-derived. The two-Hunter fold passes it through
// step_tick; think reads time.dt only down the Search path (unexercised by the
// patrol/chase fold, but the resource is bound regardless).
@(private = "file")
hunt_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

// hunt_interp builds the read-only interpreter over the hand-built hunt program
// with an empty input snapshot and the 60hz dt — the context a hunt body
// evaluation reads against. The version is the empty initial one; the fold tests
// commit their own rows through step_tick.
@(private = "file")
hunt_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	return new_interp(program, version, nil, empty(), hunt_time(context.temp_allocator), context.temp_allocator)
}

// hunter_value builds a Hunter blackboard as a Record_Value fixture — the `self`
// arg a patrol/chase/search body folds. ai is the Hunt enum case; last_seen and
// search_t default to zero (the fields a given test does not pin).
@(private = "file")
hunter_value :: proc(pos, home: Vec2, ai_case: string) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["pos"] = pos
	fields["home"] = home
	fields["ai"] = Variant_Value{enum_type = "Hunt", case_name = ai_case}
	fields["last_seen"] = Vec2{to_fixed(0), to_fixed(0)}
	fields["search_t"] = to_fixed(0)
	return Record_Value{type_name = "Hunter", fields = fields}
}

// hunter_with_timer builds a Hunter fixture carrying a specific search_t — the
// search/seek countdown tests pin the timer the give-up compare reads.
@(private = "file")
hunter_with_timer :: proc(pos: Vec2, ai_case: string, search_t: Fixed) -> Value {
	rec := hunter_value(pos, pos, ai_case).(Record_Value)
	rec.fields["search_t"] = search_t
	return rec
}

// hunter_row builds a Hunter blackboard Row — the working-table row form the tick
// binds `self` from and think reads through row_to_record. enum columns store the
// "Hunt::Case" token (state.odin's string column), so the match reads the case.
@(private = "file")
hunter_row :: proc(pos, home: Vec2, ai_case: string) -> Row {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["home"] = home
	fields["ai"] = hunt_token(ai_case)
	fields["last_seen"] = Vec2{to_fixed(0), to_fixed(0)}
	fields["search_t"] = to_fixed(0)
	return Row{id = Id{raw = Thing_Id(0)}, fields = fields}
}

// hunt_token renders a Hunt enum case as its stored "Hunt::Case" column token.
@(private = "file")
hunt_token :: proc(case_name: string) -> string {
	return concat_temp("Hunt::", case_name)
}

// player_view_list builds the View[Player] list think's perception folds over —
// one Player record at `pos`, the shared row the two-Hunter fold reads through a
// View. A View[T] param binds as a List_Value of record values (tick.odin
// view_rows_as_list), so the fixture matches that binding shape.
@(private = "file")
player_view_list :: proc(interp: ^Interp, pos: Vec2) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["pos"] = pos
	player := Record_Value{type_name = "Player", fields = fields}
	elements := make([]Value, 1, context.temp_allocator)
	elements[0] = player
	return List_Value{elements = elements}
}

// concat_temp joins two strings in the test temp arena — the stored-token builder
// for an enum column (avoids pulling core:strings into the test surface).
@(private = "file")
concat_temp :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}
