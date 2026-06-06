// Native fixed-point physics solver acceptance (spec §11; runtime Lore #9). The
// solver is an engine-closed `physics:` stage running a PURE DETERMINISTIC FOLD —
// audited bit-identical, with physical CORRECTNESS proven at the golden leaf (OUT
// of this epic). So these tests prove DETERMINISM and the CONTRACT SURFACE, not a
// physically faithful response:
//
//   - DETERMINISM: a hand-built two-body fixture stepped through `physics: solve`
//     TWICE from the same prior version yields BYTE-IDENTICAL pos/vel columns —
//     fixed-point only, a fixed iteration count, stable pair order, so a lockstep/
//     replay re-fold reproduces the run bit-for-bit (§11 §1).
//   - IMPULSE CONSUMED: the solver consumes and zeroes Body.impulse each step
//     (§11 §2) — a body carrying intent reads VEC2_ZERO impulse after a step.
//   - SENSOR → TRIGGER: a sensor (Pad) overlap routes a Trigger to each
//     overlapping body and is NEVER positionally resolved (§11 §4) — the sensor's
//     position is unchanged, and one Trigger lands in the mailbox per overlapping
//     body.
//   - LAYER/MASK FILTER: a mask-mismatched pair produces NO contact and NO
//     Trigger (§11 §5 symmetric AND) — two bodies collide iff each mask contains
//     the other's layer.
//
// The fixtures are HAND-BUILT committed versions (the Lore #8 fixture strategy):
// the solver runs over the tick's working rows, so a base World_Version carrying
// Body columns + a minimal Program with the `physics: solve` step is the whole
// harness — no artifact, no compiler-emitted golden. The yard bodies
// (wall/crate/player/Pad) are the reference shapes these fixtures model.
package funpack_runtime

import "core:mem"
import "core:testing"

// --- Determinism: a double-fold is byte-identical ------------------------

// Two independent step_tick folds of the same two-body fixture commit
// BYTE-IDENTICAL pos/vel columns (§11 §1 determinism): the solver is a pure
// deterministic fold — fixed-point only, a fixed iteration count, stable pair
// order — so re-folding the same prior version reproduces the run bit-for-bit.
@(test)
test_solver_double_fold_is_byte_identical :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := solve_program(a)
	// A dynamic crate moving right, with a wall it will be pushed against — a contact
	// the solver resolves, so the determinism covers integration AND resolution.
	base := two_body_world(
		a,
		moving_crate(Vec2{to_fixed(50), to_fixed(40)}, Vec2{to_fixed(8), to_fixed(0)}),
		static_wall(Vec2{to_fixed(60), to_fixed(40)}, Vec2{to_fixed(8), to_fixed(40)}),
	)

	first := step_tick(&program, base, empty(), solver_time(a), a)
	second := step_tick(&program, base, empty(), solver_time(a), a)

	// The two folds commit bit-identical world versions — the determinism contract.
	if !testing.expect(t, world_versions_equal(first, second)) {
		return
	}

	// Spell out the column-level identity the criterion names: same pos AND vel on
	// the resolved crate across both folds.
	crate_a, _ := view_at(view_of_type(&first, "Crate"), 0)
	crate_b, _ := view_at(view_of_type(&second, "Crate"), 0)
	pos_a, _ := row_field(crate_a, "pos")
	pos_b, _ := row_field(crate_b, "pos")
	vel_a, _ := row_field(crate_a, "vel")
	vel_b, _ := row_field(crate_b, "vel")
	testing.expect_value(t, pos_a.(Vec2), pos_b.(Vec2))
	testing.expect_value(t, vel_a.(Vec2), vel_b.(Vec2))
}

// --- Contract surface: impulse consumed and zeroed -----------------------

// The solver CONSUMES AND ZEROES Body.impulse each step (§11 §2): a crate
// carrying an accumulated impulse reads VEC2_ZERO impulse after a step — the
// intent is spent on the integration and never lingers to double-apply next tick.
@(test)
test_solver_zeroes_impulse_after_step :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := solve_program(a)
	// One lone crate carrying a non-zero impulse — no contact, so the only effect is
	// the integrate-and-consume of the impulse.
	pushed := pushed_crate(Vec2{to_fixed(50), to_fixed(40)}, Vec2{to_fixed(5), to_fixed(3)})
	base := one_body_world(a, pushed)

	next := step_tick(&program, base, empty(), solver_time(a), a)

	crate, _ := view_at(view_of_type(&next, "Crate"), 0)
	body := body_column(crate)
	impulse := body.fields["impulse"].(Vec2)
	testing.expect_value(t, impulse, VEC2_ZERO)

	// The impulse was not silently dropped — it advanced the velocity (impulse/mass),
	// so the body integrated. vel is non-zero, confirming the intent was consumed,
	// not ignored.
	vel, _ := row_field(crate, "vel")
	testing.expect(t, vel.(Vec2) != VEC2_ZERO)
}

// --- Contract surface: sensor overlap routes Triggers, never resolved ----

// A sensor (Pad) overlap routes a Trigger to EACH overlapping body and is NEVER
// positionally resolved (§11 §4): a crate sitting on the pad lands a Trigger in
// the mailbox (the same Signal_Mailbox route_signals uses, so `deliver on Crate`
// consumes it), while the pad's position is unchanged — a sensor detects, it does
// not push.
@(test)
test_solver_sensor_overlap_routes_trigger_unresolved :: proc(t: ^testing.T) {
	a := context.temp_allocator
	// A crate overlapping a static Pad sensor. The crate's mask names Pad and the
	// pad's mask names Crate (the symmetric AND holds), so the overlap is detected.
	crate := resting_crate(Vec2{to_fixed(80), to_fixed(100)})
	pad := pad_sensor(Vec2{to_fixed(80), to_fixed(100)}, Vec2{to_fixed(24), to_fixed(24)})

	state := solve_one_step_state(a, crate, pad)

	// One Trigger landed in the mailbox — routed to the one overlapping (non-sensor)
	// body of the sensor pair (§11 §4: a Trigger per overlapping body).
	triggers := state.mailbox.by_type[SOLVER_TRIGGER_SIGNAL]
	testing.expect_value(t, len(triggers), 1)

	// The sensor (Pad) is NEVER resolved — its position is exactly where it started
	// (a sensor detects overlaps, it is never pushed).
	pad_table := find_tick_table(state.tables, "Pad")
	if !testing.expect(t, pad_table != nil) {
		return
	}
	pad_pos := pad_table.rows[0].fields["pos"].(Vec2)
	testing.expect_value(t, pad_pos, Vec2{to_fixed(80), to_fixed(100)})
}

// A sensor overlap routes ONE Trigger PER overlapping body (§11 §4): two crates on
// one pad land two Triggers in the mailbox — the per-participant routing, not a
// single broadcast. The pad is still never resolved.
@(test)
test_solver_sensor_routes_one_trigger_per_overlapping_body :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := solve_program(a)
	// Two crates both overlapping a wide pad sensor (the pad's box covers both crate
	// centers), so each crate is an overlapping participant.
	base := three_body_world(
		a,
		"Crate",
		resting_crate(Vec2{to_fixed(74), to_fixed(100)}),
		resting_crate(Vec2{to_fixed(86), to_fixed(100)}),
		"Pad",
		pad_sensor(Vec2{to_fixed(80), to_fixed(100)}, Vec2{to_fixed(40), to_fixed(40)}),
	)

	state := new_tick_state(base, a)
	prior := base
	interp := new_interp(&program, &prior, &state, empty(), solver_time(a), a)
	run_solve(&interp, &state)

	// One Trigger per overlapping crate — two crates, two Triggers.
	triggers := state.mailbox.by_type[SOLVER_TRIGGER_SIGNAL]
	testing.expect_value(t, len(triggers), 2)
}

// --- Contract surface: layer/mask AND mismatch yields no contact ---------

// A layer/mask AND NON-match produces NO contact and NO Trigger (§11 §5): two
// overlapping bodies whose masks do not symmetrically name each other's layer do
// not collide at all. This is yard's player-over-pad case: the player's mask omits
// Pad, so the player walks over the pad sensor with no Trigger and no resolution,
// even though the pad's mask names Player would-be — the AND fails on the player
// side.
@(test)
test_solver_mask_mismatch_yields_no_contact :: proc(t: ^testing.T) {
	a := context.temp_allocator
	// A player (mask = [Wall, Crate], NO Pad) sitting exactly on a pad sensor whose
	// mask names Player. The player's mask omits Pad, so the symmetric AND fails:
	// no overlap is registered, no Trigger routed.
	player := player_over_pad(Vec2{to_fixed(80), to_fixed(100)})
	pad := pad_sensor_masking(Vec2{to_fixed(80), to_fixed(100)}, Vec2{to_fixed(24), to_fixed(24)}, "Player")

	state := solve_one_step_state_named(a, "Player", player, "Pad", pad)

	// No Trigger landed — the mask mismatch means no contact at all (§11 §5).
	triggers := state.mailbox.by_type[SOLVER_TRIGGER_SIGNAL]
	testing.expect_value(t, len(triggers), 0)

	// The player did not integrate a contact response either: its position is
	// unchanged (it carried no impulse and no velocity, and no contact pushed it).
	player_table := find_tick_table(state.tables, "Player")
	if !testing.expect(t, player_table != nil) {
		return
	}
	player_pos := player_table.rows[0].fields["pos"].(Vec2)
	testing.expect_value(t, player_pos, Vec2{to_fixed(80), to_fixed(100)})
}

// A matching pair that does NOT overlap also produces no Trigger — proving the
// no-Trigger result above is the mask filter, not merely a non-overlap. Two
// sensor-masked bodies far apart register no contact.
@(test)
test_solver_non_overlapping_matched_pair_no_trigger :: proc(t: ^testing.T) {
	a := context.temp_allocator
	// A crate and a pad whose masks DO match, but placed far apart — no overlap.
	crate := resting_crate(Vec2{to_fixed(10), to_fixed(10)})
	pad := pad_sensor(Vec2{to_fixed(200), to_fixed(200)}, Vec2{to_fixed(24), to_fixed(24)})

	state := solve_one_step_state(a, crate, pad)

	triggers := state.mailbox.by_type[SOLVER_TRIGGER_SIGNAL]
	testing.expect_value(t, len(triggers), 0)
}

// ==========================================================================
// Fixtures: hand-built bodies, worlds, and the solve program/time resource.
// ==========================================================================

// solver_time is the Time resource the solver reads its fixed dt off (the §11 §1
// fixed timestep): one `dt` field at the 60hz step, derived through the kernel —
// no float, identical bits every machine.
@(private = "file")
solver_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

// solve_program is the minimal Program the solver tests fold: a single pipeline
// step `physics: solve` (the engine-closed §11 §3 stage). The solver runs over the
// tick's WORKING rows, not over program.things, so no Thing_Decl or behavior is
// needed — the pipeline step alone dispatches the fold to run_solve.
@(private = "file")
solve_program :: proc(allocator := context.allocator) -> Program {
	pipeline := make([]Pipeline_Step, 1, allocator)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "physics", behavior = "solve"}
	return Program{pipeline = pipeline}
}

// solve_one_step_state folds one solve step over a two-body world (a Crate and a
// Pad) and returns the post-solve tick state — so a test can inspect the mailbox
// AND the working rows directly (the Trigger routing and the un-resolved sensor
// position both live on the tick state, before the commit).
@(private = "file")
solve_one_step_state :: proc(
	allocator: mem.Allocator,
	crate, pad: map[string]Field_Value,
) -> Tick_State {
	return solve_one_step_state_named(allocator, "Crate", crate, "Pad", pad)
}

// solve_one_step_state_named is the general two-body solve: it builds a base world
// from the two named bodies, folds one run_solve over a fresh tick state, and
// returns that state. The mailbox holds the routed Triggers; the working tables
// hold the (un)resolved positions — both the contract-surface assertions read.
@(private = "file")
solve_one_step_state_named :: proc(
	allocator: mem.Allocator,
	thing_a: string,
	body_a: map[string]Field_Value,
	thing_b: string,
	body_b: map[string]Field_Value,
) -> Tick_State {
	program := solve_program(allocator)
	base := two_body_world_named(allocator, thing_a, body_a, thing_b, body_b)
	state := new_tick_state(base, allocator)
	prior := base
	interp := new_interp(&program, &prior, &state, empty(), solver_time(allocator), allocator)
	run_solve(&interp, &state)
	return state
}

// --- World builders (hand-built committed base versions) ------------------

// one_body_world commits a base version with a single Crate row carrying the given
// blackboard (a `body`/`pos`/`vel` column map). The committed table is the prior
// the tick folds over.
@(private = "file")
one_body_world :: proc(allocator: mem.Allocator, crate: map[string]Field_Value) -> World_Version {
	tables := make([]Version_Table, 1, allocator)
	tables[0] = single_row_table("Crate", crate, allocator)
	return World_Version{tick = 0, tables = tables}
}

// two_body_world commits a base version with a Crate row and a Wall row (the
// resolve-against-static fixture). The two tables are committed in declaration
// order; each holds one row at Id 0.
@(private = "file")
two_body_world :: proc(allocator: mem.Allocator, crate, wall: map[string]Field_Value) -> World_Version {
	return two_body_world_named(allocator, "Crate", crate, "Wall", wall)
}

// two_body_world_named commits a base version with two named single-row tables —
// the general two-body fixture the sensor/mask tests build (Crate+Pad,
// Player+Pad). The tables commit in argument order, each with one row at Id 0, so
// the solver's stable (table, Id) gather order is deterministic.
@(private = "file")
two_body_world_named :: proc(
	allocator: mem.Allocator,
	thing_a: string,
	body_a: map[string]Field_Value,
	thing_b: string,
	body_b: map[string]Field_Value,
) -> World_Version {
	tables := make([]Version_Table, 2, allocator)
	tables[0] = single_row_table(thing_a, body_a, allocator)
	tables[1] = single_row_table(thing_b, body_b, allocator)
	return World_Version{tick = 0, tables = tables}
}

// three_body_world commits a base version with TWO rows in the first named table
// and one in the second — the two-crates-on-one-pad fixture. The first table's two
// rows are at Id 0 and 1 (ascending, the stable iteration order), so both crates
// are gathered as overlapping participants.
@(private = "file")
three_body_world :: proc(
	allocator: mem.Allocator,
	thing_a: string,
	body_a0, body_a1: map[string]Field_Value,
	thing_b: string,
	body_b: map[string]Field_Value,
) -> World_Version {
	tables := make([]Version_Table, 2, allocator)
	rows_a := make([]Row, 2, allocator)
	rows_a[0] = Row{id = Id{raw = 0}, fields = body_a0}
	rows_a[1] = Row{id = Id{raw = 1}, fields = body_a1}
	tables[0] = Version_Table{thing = thing_a, rows = rows_a, next_id = Thing_Id(2)}
	tables[1] = single_row_table(thing_b, body_b, allocator)
	return World_Version{tick = 0, tables = tables}
}

// single_row_table builds a committed Version_Table holding one row (Id 0) with
// the given blackboard — the per-thing fixture the world builders compose.
@(private = "file")
single_row_table :: proc(thing: string, fields: map[string]Field_Value, allocator := context.allocator) -> Version_Table {
	rows := make([]Row, 1, allocator)
	rows[0] = Row{id = Id{raw = 0}, fields = fields}
	return Version_Table{thing = thing, rows = rows, next_id = Thing_Id(1)}
}

// --- Body blackboard builders (the §11 §2 Body column shapes) -------------

// moving_crate builds a Crate blackboard: a Dynamic Box body with a velocity, no
// impulse — the integrate-and-resolve fixture. The body collides with Wall/Crate
// (yard's crate mask), so it resolves against a wall.
@(private = "file")
moving_crate :: proc(pos, vel: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["vel"] = vel
	fields["body"] = crate_body_col(VEC2_ZERO)
	return fields
}

// pushed_crate builds a Crate blackboard carrying an accumulated IMPULSE (no
// velocity) — the consume-and-zero fixture. After a step the solver must read the
// impulse, fold it into velocity, and zero the impulse column.
@(private = "file")
pushed_crate :: proc(pos, impulse: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["vel"] = VEC2_ZERO
	fields["body"] = crate_body_col(impulse)
	return fields
}

// resting_crate builds a Crate at rest (zero vel, zero impulse) — the sensor-
// overlap fixture, where the only solver effect is the Trigger routing (no
// integration moves it, and a sensor is never resolved).
@(private = "file")
resting_crate :: proc(pos: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["vel"] = VEC2_ZERO
	fields["body"] = crate_body_col(VEC2_ZERO)
	return fields
}

// static_wall builds a Wall blackboard: a Static Box body on the Wall layer
// (yard's wall_body). A Static carries no `vel` (it never integrates) — only a pos
// and a body. Its mask names Player/Crate, so a crate resolves against it.
@(private = "file")
static_wall :: proc(pos, size: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["body"] = wall_body_col(size)
	return fields
}

// pad_sensor builds a Pad blackboard: a Static SENSOR Box on the Pad layer whose
// mask names Crate (yard's Pad). A sensor is never resolved — an overlapping crate
// routes a Trigger.
@(private = "file")
pad_sensor :: proc(pos, size: Vec2) -> map[string]Field_Value {
	return pad_sensor_masking(pos, size, "Crate")
}

// pad_sensor_masking builds a Pad sensor whose mask names the given layer — the
// general sensor fixture the mask-mismatch test parameterizes (a pad masking
// Player, paired with a player whose mask omits Pad, so the symmetric AND fails).
@(private = "file")
pad_sensor_masking :: proc(pos, size: Vec2, mask_layer: string) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["body"] = sensor_body_col(size, mask_layer)
	return fields
}

// player_over_pad builds a Player blackboard: a Dynamic Circle on the Player layer
// whose mask names ONLY Wall/Crate (NOT Pad) — yard's player_body. Paired with a
// pad, the symmetric AND fails on the player side, so the player never triggers
// the pad (it walks over it freely).
@(private = "file")
player_over_pad :: proc(pos: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["vel"] = VEC2_ZERO
	fields["body"] = player_body_col()
	return fields
}

// --- Body Record_Value column builders ------------------------------------

// crate_body_col builds a Crate's §11 §2 Body column: a Dynamic Box (size 12×12,
// yard's crate), mass 2.0, friction 0.9, on the Crate layer, masking Wall/Player/
// Crate/Pad — yard's crate_body, with the given starting impulse.
@(private = "file")
crate_body_col :: proc(impulse: Vec2) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["kind"] = enum_token("BodyKind", "Dynamic")
	fields["shape"] = box_shape(Vec2{to_fixed(12), to_fixed(12)})
	fields["mass"] = to_fixed(2)
	fields["friction"] = fixed_from_decimal(0, "9")
	fields["sensor"] = false
	fields["layer"] = enum_token("Layer", "Crate")
	fields["mask"] = layer_mask("Wall", "Player", "Crate", "Pad")
	fields["impulse"] = impulse
	return Record_Value{type_name = "Body", fields = fields}
}

// wall_body_col builds a Wall's §11 §2 Body column: a Static Box of the given size
// on the Wall layer, masking Player/Crate — yard's wall_body. A Static has
// infinite mass and never integrates.
@(private = "file")
wall_body_col :: proc(size: Vec2) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["kind"] = enum_token("BodyKind", "Static")
	fields["shape"] = box_shape(size)
	fields["sensor"] = false
	fields["layer"] = enum_token("Layer", "Wall")
	fields["mask"] = layer_mask("Player", "Crate")
	return Record_Value{type_name = "Body", fields = fields}
}

// sensor_body_col builds a Pad's §11 §2 Body column: a Static SENSOR Box of the
// given size on the Pad layer, masking the given layer — yard's Pad. sensor=true
// is what routes a Trigger instead of resolving.
@(private = "file")
sensor_body_col :: proc(size: Vec2, mask_layer: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["kind"] = enum_token("BodyKind", "Static")
	fields["shape"] = box_shape(size)
	fields["sensor"] = true
	fields["layer"] = enum_token("Layer", "Pad")
	fields["mask"] = layer_mask(mask_layer)
	return Record_Value{type_name = "Body", fields = fields}
}

// player_body_col builds a Player's §11 §2 Body column: a Dynamic Circle (radius
// 5) on the Player layer masking ONLY Wall/Crate (NOT Pad) — yard's player_body.
// The omitted Pad in the mask is the whole point: the player never triggers the
// pad sensor (the symmetric AND fails on the player's side).
@(private = "file")
player_body_col :: proc() -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["kind"] = enum_token("BodyKind", "Dynamic")
	fields["shape"] = circle_shape(to_fixed(5))
	fields["friction"] = fixed_from_decimal(0, "9")
	fields["sensor"] = false
	fields["layer"] = enum_token("Layer", "Player")
	fields["mask"] = layer_mask("Wall", "Crate")
	fields["impulse"] = VEC2_ZERO
	return Record_Value{type_name = "Body", fields = fields}
}

// --- Shape / enum / mask value builders -----------------------------------

// box_shape builds a `Shape2::Box{size}` struct-payload variant — the shape column
// shape a committed Body record carries (a Variant_Value with a `size` Vec2 in its
// boxed payload record), matching glue_shape2_box.
@(private = "file")
box_shape :: proc(size: Vec2) -> Variant_Value {
	payload_fields := make(map[string]Value, context.temp_allocator)
	payload_fields["size"] = size
	payload := new(Value, context.temp_allocator)
	payload^ = Record_Value{type_name = "", fields = payload_fields}
	return Variant_Value{enum_type = "Shape2", case_name = "Box", payload = payload}
}

// circle_shape builds a `Shape2::Circle{radius}` struct-payload variant — a
// Variant_Value with a `radius` Fixed in its boxed payload record.
@(private = "file")
circle_shape :: proc(radius: Fixed) -> Variant_Value {
	payload_fields := make(map[string]Value, context.temp_allocator)
	payload_fields["radius"] = radius
	payload := new(Value, context.temp_allocator)
	payload^ = Record_Value{type_name = "", fields = payload_fields}
	return Variant_Value{enum_type = "Shape2", case_name = "Circle", payload = payload}
}

// enum_token builds an enum Variant_Value for a Body's enum column (kind/layer) —
// a nested Body record carries its enum fields as Variant_Values, not flattened
// string tokens (the string flattening applies only to a top-level blackboard
// column).
@(private = "file")
enum_token :: proc(enum_type, case_name: string) -> Variant_Value {
	return Variant_Value{enum_type = enum_type, case_name = case_name}
}

// layer_mask builds a §11 §5 `mask: [Layer]` List_Value of Layer enum tokens — the
// list-of-enum column the solver's layer/mask AND filter reads. Each element is a
// Layer Variant_Value.
@(private = "file")
layer_mask :: proc(layers: ..string) -> List_Value {
	elements := make([]Value, len(layers), context.temp_allocator)
	for layer, i in layers {
		elements[i] = enum_token("Layer", layer)
	}
	return List_Value{elements = elements}
}

// body_column reads a Crate/Player row's committed `body` Body record column — the
// post-step reader the impulse-zeroed assertion folds over.
@(private = "file")
body_column :: proc(row: Row) -> Record_Value {
	return row.fields["body"].(Record_Value)
}
