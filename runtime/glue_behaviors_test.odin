// Glue-behavior proof for yard's twelve pure transitions (spec §06 §3, §11, §24):
// the canonical semantics of each behavior is what THIS interpreter computes over
// the §2.7 node forest, so every glue behavior is pinned EXACTLY against a
// HAND-BUILT program — the enums/things/consts/focus-helper and each behavior step
// body built node-by-node, NOT loaded from an emitted artifact (the yard artifact
// is the sibling-compiler epic's leaf; runtime proves the engine arms compose
// ahead of it, the interp_test/hunt_fixtures_test hand-built-fixture pattern, team
// Lore #8).
//
// The bodies mirror yard.fun's in-source `test` blocks verbatim in node form, so
// the interpreter evaluates yard's REAL glue: drive (input.axis → body intent),
// deliver (a Trigger-gated ([Despawn], [Delivered]) split), tally (a +len count),
// follow (a fixed-fraction camera ease over a View[Player]), shake (the
// kick-then-flip-and-halve oscillation), view (the Draw::Camera projection),
// save_key/restore_key (a key-gated command emit), toggle_motion (a NESTED
// with-update through self.settings.access), apply_settings (a dirty-gated
// ApplySettings emit), and on_persist_result/on_settings_applied (a fold over an
// engine signal list, matching Result::Ok/Err). The NEW interp arms this story
// lands — body.apply_impulse (a non-Input method receiver), the Shape2::Box{size}
// struct-pun match, the Settings.defaults() static constructor, len, and the
// lambda-combiner fold — are each exercised by the behavior bodies below, not in
// isolation. No float (spec §10): every numeric assertion is the bit-exact kernel
// value.
package funpack_runtime

import "core:strconv"
import "core:testing"

// --- module consts (yard.fun verbatim) ------------------------------------

// GLUE_ACCEL/GLUE_FOLLOW/GLUE_SHAKE_KICK/GLUE_SHAKE_DAMP mirror yard.fun's tuning
// consts (§11): the impulse per full deflection, the camera-ease fraction, the
// delivery shake kick, and the per-tick shake factor (negative — the offset flips
// sign and halves each tick). Restated here so each behavior's expected result is
// the same kernel value its body folds, never a re-derived magnitude.
@(private = "file")
GLUE_ACCEL :: 8
@(private = "file")
GLUE_SHAKE_KICK :: 4

// glue_follow is FOLLOW = 0.25 (a quarter), binary-exact in Q32.32 so the eased
// path is bit-identical (yard.fun's @doc note). 1/4 is a perfect power-of-two
// fraction, so to_fixed division yields it exactly.
@(private = "file")
glue_follow :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(4))
}

// glue_shake_damp is SHAKE_DAMP = -0.5 (negative half): the shake offset flips
// sign and halves each idle tick — a decaying oscillation, deterministic in
// fixed-point (yard.fun's @doc note).
@(private = "file")
glue_shake_damp :: proc() -> Fixed {
	return fixed_neg(fixed_div(to_fixed(1), to_fixed(2)))
}

// GLUE_SLOT is the single quicksave slot key SLOT = "quicksave" (a dynamic String
// key created at runtime, §24) the save/restore commands carry.
@(private = "file")
GLUE_SLOT :: "quicksave"

// --- (1) apply_impulse: the Body intent method ----------------------------

// apply_impulse accumulates intent on the body; two pushes sum to Vec2{1, 2}
// (yard.fun's in-source apply_impulse test). The method is a non-Input receiver
// arm (the receiver is a Body record column), and the write is a functional
// update — the second push reads the first push's accumulated impulse and sums
// onto it, proving the solver's per-tick intent is additive (§11). Driven through
// a hand-built `body.apply_impulse(p1).apply_impulse(p2)` node forest so the
// dispatch arm is exercised, not a Vec2 add in isolation.
@(test)
test_glue_apply_impulse_accumulates :: proc(t: ^testing.T) {
	interp := glue_interp()

	body := glue_body_record(VEC2_ZERO)
	// body.apply_impulse({1,0}).apply_impulse({0,2})
	inner := glue_apply_impulse_call(name_node("b", glue_a()), vec2_literal(to_fixed(1), to_fixed(0)))
	outer := glue_apply_impulse_call(inner, vec2_literal(to_fixed(0), to_fixed(2)))

	env := glue_env()
	env.names["b"] = body
	result, ok := eval(&interp, &outer, &env)
	testing.expect(t, ok)
	rec := result.(Record_Value)
	expect_glue_vec2(t, rec, "impulse", Vec2{to_fixed(1), to_fixed(2)})
}

// --- box_size: the Shape2::Box{size} struct-pun match ---------------------

// box_size puns the size off a Box shape, and falls back to a small square for a
// non-Box (yard's draw_wall/draw_pad size read). A Shape2::Box{size: {24,24}}
// matches the struct-pun arm and returns {24,24}; a Shape2::Circle takes the
// wildcard arm and returns Vec2{8,8}. Both arms are forced, proving the new
// struct_binds match pattern this story lands.
@(test)
test_glue_box_size_struct_pun :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)

	// Box{size: {24, 24}} → the punned size.
	box := glue_shape2_box(Vec2{to_fixed(24), to_fixed(24)})
	box_result, b_ok := glue_call_one(&interp, "box_size", box)
	testing.expect(t, b_ok)
	got := box_result.(Vec2)
	testing.expect_value(t, got.x, to_fixed(24))
	testing.expect_value(t, got.y, to_fixed(24))

	// A non-Box shape → the wildcard fallback Vec2{8, 8}.
	circle := Variant_Value{enum_type = "Shape2", case_name = "Circle"}
	circle_result, c_ok := glue_call_one(&interp, "box_size", circle)
	testing.expect(t, c_ok)
	fallback := circle_result.(Vec2)
	testing.expect_value(t, fallback.x, to_fixed(8))
	testing.expect_value(t, fallback.y, to_fixed(8))
}

// --- (2) drive: input.axis → a body impulse -------------------------------

// drive converts the move axis into a body impulse scaled by ACCEL: a P1 axis of
// {1, 0} drives the player's body impulse to Vec2{ACCEL, 0} (yard.fun's in-source
// drive test). The body reads `input.axis(P1, Drive::Move) * ACCEL` (Vec2 * scalar)
// then accumulates it through apply_impulse — so the test composes the input read,
// the scale, and the intent method off one bound Input snapshot.
@(test)
test_glue_drive_axis_to_impulse :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)

	move_def, _ := registry_find_token(interp.registry, "Drive::Move")
	move_id := move_def.id
	snap := with_axis(empty(), .P1, move_id, Vec2{to_fixed(1), to_fixed(0)})
	defer delete_input(snap)
	interp.input = snap

	drive := program_behavior(&program, "drive")
	testing.expect(t, drive != nil)

	player := glue_player_record(Vec2{to_fixed(80), to_fixed(60)}, glue_body_record(VEC2_ZERO))
	env := glue_env()
	env.names["self"] = player
	env.names["input"] = input_marker(&interp)
	result, ok := eval_behavior_body(&interp, drive.body, &env)
	testing.expect(t, ok)
	rec := result.(Record_Value)
	body := rec.fields["body"].(Record_Value)
	expect_glue_vec2(t, body, "impulse", Vec2{to_fixed(GLUE_ACCEL), to_fixed(0)})
}

// --- (3) deliver: a Trigger-gated ([Despawn], [Delivered]) split ----------

// a crate the engine routed a Trigger to delivers — it despawns itself and reports
// a Delivered ([Despawn()], [Delivered{}]); a crate with no Trigger is inert ([],
// []) (yard.fun's two in-source deliver tests). The behavior returns a two-list
// tuple the tick splits into its self-despawn and signal halves; both arms are
// forced so the gate is total.
@(test)
test_glue_deliver_on_pad_and_inert :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	deliver := program_behavior(&program, "deliver")
	testing.expect(t, deliver != nil)

	// On the pad: one Trigger → ([Despawn()], [Delivered{}]).
	on_pad := glue_env()
	on_pad.names["self"] = glue_crate_record()
	on_pad.names["pads"] = glue_list(glue_trigger())
	delivered, d_ok := eval_behavior_body(&interp, deliver.body, &on_pad)
	testing.expect(t, d_ok)
	expect_deliver_result(t, delivered, true)

	// Off the pad: no Trigger → ([], []).
	off_pad := glue_env()
	off_pad.names["self"] = glue_crate_record()
	off_pad.names["pads"] = glue_list()
	inert, i_ok := eval_behavior_body(&interp, deliver.body, &off_pad)
	testing.expect(t, i_ok)
	expect_deliver_result(t, inert, false)
}

// --- (4) tally: a +len count ----------------------------------------------

// tally counts the crates delivered this tick: a scoreboard at 1 folding two
// Delivered signals lands at 3 (yard.fun's in-source tally test). The body reads
// `self.delivered + len(done)` — the len builtin over a signal list onto the Int
// rail — so the count is the exact element count, not a float.
@(test)
test_glue_tally_counts_deliveries :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	tally := program_behavior(&program, "tally")
	testing.expect(t, tally != nil)

	env := glue_env()
	env.names["self"] = glue_scoreboard(2)
	env.names["done"] = glue_list(glue_delivered(), glue_delivered())
	result, ok := eval_behavior_body(&interp, tally.body, &env)
	testing.expect(t, ok)
	rec := result.(Record_Value)
	testing.expect_value(t, rec.fields["delivered"].(i64), i64(4))
}

// --- (5) follow: a fixed-fraction camera ease over a View[Player] ---------

// follow eases the camera a quarter of the way toward the player each tick: a
// camera at {0,0} with a player at {8,0} eases to Vec2{2, 0} (yard.fun's in-source
// follow test). The body reads `focus(players, self.at)` (the helper match over
// first(players)) then `self.at + (target - self.at) * FOLLOW` — the View[Player]
// binds as a List_Value of player records (View.of fixture).
@(test)
test_glue_follow_eases_toward_player :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	follow := program_behavior(&program, "follow")
	testing.expect(t, follow != nil)

	env := glue_env()
	env.names["self"] = glue_camera(Vec2{to_fixed(0), to_fixed(0)}, VEC2_ZERO)
	env.names["players"] = glue_player_view(Vec2{to_fixed(8), to_fixed(0)})
	result, ok := eval_behavior_body(&interp, follow.body, &env)
	testing.expect(t, ok)
	rec := result.(Record_Value)
	expect_glue_vec2(t, rec, "at", Vec2{to_fixed(2), to_fixed(0)})
}

// follow holds when there is no player: the focus fallback is the camera's own
// `at`, so the ease target equals `at` and the camera stays put at Vec2{5, 5}
// (yard.fun's in-source follow-holds test). The None arm of focus's match over an
// EMPTY View.of is forced, so the no-player path is total.
@(test)
test_glue_follow_holds_with_no_player :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	follow := program_behavior(&program, "follow")
	testing.expect(t, follow != nil)

	env := glue_env()
	env.names["self"] = glue_camera(Vec2{to_fixed(5), to_fixed(5)}, VEC2_ZERO)
	env.names["players"] = glue_empty_view()
	result, ok := eval_behavior_body(&interp, follow.body, &env)
	testing.expect(t, ok)
	rec := result.(Record_Value)
	expect_glue_vec2(t, rec, "at", Vec2{to_fixed(5), to_fixed(5)})
}

// --- (6) shake: kick-then-flip-and-halve ----------------------------------

// a delivery kicks the camera shake to Vec2{SHAKE_KICK, 0}, and idle the shake
// flips sign and halves toward rest — {4, 0} decays to Vec2{-2, 0} (yard.fun's two
// in-source shake tests). The kick arm gates on a non-empty signal list; the idle
// arm scales the prior shake by SHAKE_DAMP (-0.5), proving the decaying
// oscillation is exact in fixed-point.
@(test)
test_glue_shake_kicks_and_decays :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	shake := program_behavior(&program, "shake")
	testing.expect(t, shake != nil)

	// A delivery kicks the offset.
	kicked := glue_env()
	kicked.names["self"] = glue_camera(VEC2_ZERO, VEC2_ZERO)
	kicked.names["done"] = glue_list(glue_delivered())
	kick_result, k_ok := eval_behavior_body(&interp, shake.body, &kicked)
	testing.expect(t, k_ok)
	expect_glue_vec2(t, kick_result.(Record_Value), "shake", Vec2{to_fixed(GLUE_SHAKE_KICK), to_fixed(0)})

	// Idle, {4, 0} flips and halves to {-2, 0}.
	idle := glue_env()
	idle.names["self"] = glue_camera(VEC2_ZERO, Vec2{to_fixed(4), to_fixed(0)})
	idle.names["done"] = glue_list()
	decay_result, d_ok := eval_behavior_body(&interp, shake.body, &idle)
	testing.expect(t, d_ok)
	expect_glue_vec2(t, decay_result.(Record_Value), "shake", Vec2{fixed_neg(to_fixed(2)), to_fixed(0)})
}

// --- (7) view: the Draw::Camera projection --------------------------------

// view emits the camera at its shaken position: a camera at {80,60} with shake
// {2,0} returns [Draw::Camera{at: {82,60}, zoom: 1.0, rotation: 0.0}] (yard.fun's
// in-source view test). The behavior RETURNS the Draw::Camera record value — the
// lowering to a Draw_Cmd is the camera story's, so this asserts the returned
// List_Value of the Draw::Camera record, not a projected draw command.
@(test)
test_glue_view_emits_shaken_camera :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	view := program_behavior(&program, "view")
	testing.expect(t, view != nil)

	env := glue_env()
	env.names["self"] = glue_camera(Vec2{to_fixed(80), to_fixed(60)}, Vec2{to_fixed(2), to_fixed(0)})
	result, ok := eval_behavior_body(&interp, view.body, &env)
	testing.expect(t, ok)
	list := result.(List_Value)
	testing.expect_value(t, len(list.elements), 1)
	cam := list.elements[0].(Record_Value)
	testing.expect_value(t, cam.type_name, "Draw::Camera")
	expect_glue_vec2(t, cam, "at", Vec2{to_fixed(82), to_fixed(60)})
	testing.expect_value(t, cam.fields["zoom"].(Fixed), to_fixed(1))
	testing.expect_value(t, cam.fields["rotation"].(Fixed), to_fixed(0))
}

// --- (8) save_key / (9) restore_key: key-gated command emits --------------

// the save key emits a Save command for the quicksave slot, and nothing without
// the key; the load key emits a Restore for the same slot (yard.fun's in-source
// save/restore tests). Each body gates a `[Save{slot}]` / `[Restore{slot}]` emit
// on an input.pressed read — a pure command decision, the disk write being the
// engine's (§24).
@(test)
test_glue_save_restore_key_emit :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)

	save_def, _ := registry_find_token(interp.registry, "Cmd::Save")
	save_id := save_def.id
	restore_def, _ := registry_find_token(interp.registry, "Cmd::Restore")
	restore_id := restore_def.id

	save_key := program_behavior(&program, "save_key")
	restore_key := program_behavior(&program, "restore_key")
	testing.expect(t, save_key != nil && restore_key != nil)

	// Save pressed → [Save{slot: "quicksave"}].
	pressed_save := with_pressed(empty(), .P1, save_id)
	defer delete_input(pressed_save)
	interp.input = pressed_save
	saved, s_ok := glue_run_menu(&interp, save_key, glue_menu_default())
	testing.expect(t, s_ok)
	expect_command_list(t, saved, "Save", GLUE_SLOT)

	// No key → [].
	none_snap := empty()
	defer delete_input(none_snap)
	interp.input = none_snap
	empty_result, e_ok := glue_run_menu(&interp, save_key, glue_menu_default())
	testing.expect(t, e_ok)
	testing.expect_value(t, len(empty_result.(List_Value).elements), 0)

	// Restore pressed → [Restore{slot: "quicksave"}].
	pressed_restore := with_pressed(empty(), .P1, restore_id)
	defer delete_input(pressed_restore)
	interp.input = pressed_restore
	restored, r_ok := glue_run_menu(&interp, restore_key, glue_menu_default())
	testing.expect(t, r_ok)
	expect_command_list(t, restored, "Restore", GLUE_SLOT)
}

// --- (10) toggle_motion: a NESTED with-update -----------------------------

// toggling reduce-motion edits the in-session settings and marks them unapplied:
// a default menu toggled sets reduce_motion true and dirty true (yard.fun's
// in-source toggle_motion test). The body does the NESTED update
// `self.settings.access with { reduce_motion: not … }` then `self with { settings:
// self.settings with { access: access }, dirty: true }` — a with through a field
// path, the new nested-update surface this story proves. The settings seed is
// Settings.defaults() (the static constructor), so reduce_motion starts false.
@(test)
test_glue_toggle_motion_nested_update :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)

	toggle_def, _ := registry_find_token(interp.registry, "Cmd::ToggleMotion")
	toggle_id := toggle_def.id
	toggle := program_behavior(&program, "toggle_motion")
	testing.expect(t, toggle != nil)

	pressed := with_pressed(empty(), .P1, toggle_id)
	defer delete_input(pressed)
	interp.input = pressed
	result, ok := glue_run_menu(&interp, toggle, glue_menu_default())
	testing.expect(t, ok)
	rec := result.(Record_Value)
	testing.expect_value(t, rec.fields["dirty"].(bool), true)
	settings := rec.fields["settings"].(Record_Value)
	access := settings.fields["access"].(Record_Value)
	testing.expect_value(t, access.fields["reduce_motion"].(bool), true)
}

// toggle_motion with no key is a pass-through: the body's `if not pressed { return
// self }` guard returns the menu untouched (reduce_motion still false, dirty still
// false), proving the input gate is total — the no-press arm of yard's edit path.
@(test)
test_glue_toggle_motion_no_key_passthrough :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	toggle := program_behavior(&program, "toggle_motion")
	testing.expect(t, toggle != nil)

	none_snap := empty()
	defer delete_input(none_snap)
	interp.input = none_snap
	result, ok := glue_run_menu(&interp, toggle, glue_menu_default())
	testing.expect(t, ok)
	rec := result.(Record_Value)
	testing.expect_value(t, rec.fields["dirty"].(bool), false)
}

// --- (11) apply_settings: a dirty-gated ApplySettings emit -----------------

// apply emits ApplySettings only when there are unapplied edits: a dirty menu with
// Apply pressed emits [ApplySettings{settings}]; a clean menu emits nothing
// (yard.fun's in-source apply test). The body gates on `self.dirty and
// input.pressed(P1, Cmd::Apply)` — both the dirty flag and the key must hold, so
// the clean-menu arm is the empty emit.
@(test)
test_glue_apply_settings_dirty_gated :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)

	apply_def, _ := registry_find_token(interp.registry, "Cmd::Apply")
	apply_id := apply_def.id
	apply := program_behavior(&program, "apply_settings")
	testing.expect(t, apply != nil)

	pressed := with_pressed(empty(), .P1, apply_id)
	defer delete_input(pressed)
	interp.input = pressed

	// Dirty + pressed → [ApplySettings{settings}].
	dirty_menu := glue_menu_dirty()
	emitted, ap_ok := glue_run_menu(&interp, apply, dirty_menu)
	testing.expect(t, ap_ok)
	list := emitted.(List_Value)
	testing.expect_value(t, len(list.elements), 1)
	cmd := list.elements[0].(Record_Value)
	testing.expect_value(t, cmd.type_name, "ApplySettings")
	// The emitted command carries the menu's settings unchanged.
	testing.expect(t, values_equal(cmd.fields["settings"], dirty_menu.(Record_Value).fields["settings"]))

	// Clean menu + pressed → [] (the dirty gate blocks the emit).
	clean, c_ok := glue_run_menu(&interp, apply, glue_menu_default())
	testing.expect(t, c_ok)
	testing.expect_value(t, len(clean.(List_Value).elements), 0)
}

// --- (12) on_persist_result / on_settings_applied: signal-list folds -------

// on_persist_result folds the save/restore outcomes into the menu status, matching
// Result::Ok/Err over each signal (spec §24, AX4 — the error case can never be
// silently dropped). A single Saved{Ok} sets status "saved"; a Restored{Err} over
// it sets status "restore failed" — proving the lambda-combiner fold threads the
// accumulator and the Result match covers both arms.
@(test)
test_glue_on_persist_result_folds :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	on_persist := program_behavior(&program, "on_persist_result")
	testing.expect(t, on_persist != nil)

	// A successful save sets status "saved" (no restore this tick).
	saved_env := glue_env()
	saved_env.names["self"] = glue_menu_default()
	saved_env.names["saved"] = glue_list(glue_result_signal("Saved", "Ok"))
	saved_env.names["restored"] = glue_list()
	saved_result, s_ok := eval_behavior_body(&interp, on_persist.body, &saved_env)
	testing.expect(t, s_ok)
	expect_status(t, saved_result, "saved")

	// A failed restore over a fresh menu sets status "restore failed" — the Err arm
	// is forced, so a failed read is never dropped.
	failed_env := glue_env()
	failed_env.names["self"] = glue_menu_default()
	failed_env.names["saved"] = glue_list()
	failed_env.names["restored"] = glue_list(glue_result_signal("Restored", "Err"))
	failed_result, f_ok := eval_behavior_body(&interp, on_persist.body, &failed_env)
	testing.expect(t, f_ok)
	expect_status(t, failed_result, "restore failed")
}

// on_settings_applied records the apply outcome and clears the unapplied flag once
// the engine persisted the settings (spec §24): a SettingsApplied{Ok} over a dirty
// menu sets status "settings applied" AND clears dirty to false; a SettingsApplied
// {Err} sets the failure status and LEAVES dirty set (the edits are still
// unapplied). Both Result arms are forced off the same dirty fixture.
@(test)
test_glue_on_settings_applied_folds :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	on_applied := program_behavior(&program, "on_settings_applied")
	testing.expect(t, on_applied != nil)

	// Ok → status "settings applied", dirty cleared.
	ok_env := glue_env()
	ok_env.names["self"] = glue_menu_dirty()
	ok_env.names["applied"] = glue_list(glue_result_signal("SettingsApplied", "Ok"))
	ok_result, o_ok := eval_behavior_body(&interp, on_applied.body, &ok_env)
	testing.expect(t, o_ok)
	ok_rec := ok_result.(Record_Value)
	expect_status(t, ok_result, "settings applied")
	testing.expect_value(t, ok_rec.fields["dirty"].(bool), false)

	// Err → failure status, dirty STILL set (the edits remain unapplied).
	err_env := glue_env()
	err_env.names["self"] = glue_menu_dirty()
	err_env.names["applied"] = glue_list(glue_result_signal("SettingsApplied", "Err"))
	err_result, e_ok := eval_behavior_body(&interp, on_applied.body, &err_env)
	testing.expect(t, e_ok)
	err_rec := err_result.(Record_Value)
	expect_status(t, err_result, "settings save failed")
	testing.expect_value(t, err_rec.fields["dirty"].(bool), true)
}

// ==========================================================================
// The hand-built yard program: enums/things/consts/focus + the twelve behaviors.
// ==========================================================================

// glue_program builds the yard glue surface in memory: the Drive (Axis) and Cmd
// (Button) enums the registry mints actions from, the consts, the focus helper,
// and the twelve glue behaviors as §2.7 node forests. Allocated in the test temp
// arena so the leak checker stays clean. This is the substrate the glue tests
// evaluate against (team Lore #8 hand-built fixture — no emitted artifact).
@(private = "file")
glue_program :: proc() -> Program {
	a := context.temp_allocator

	enums := make([]Enum_Decl, 2, a)
	enums[0] = Enum_Decl{name = "Drive", kind = .Axis, variants = glue_one_variant("Move", a)}
	enums[1] = Enum_Decl{name = "Cmd", kind = .Button, variants = glue_cmd_variants(a)}

	functions := make([]Function_Decl, 5, a)
	functions[0] = glue_const_fn("ACCEL", glue_fixed_node(to_fixed(GLUE_ACCEL), a), a)
	functions[1] = glue_const_fn("FOLLOW", glue_fixed_node(glue_follow(), a), a)
	functions[2] = glue_const_fn("SHAKE_KICK", glue_fixed_node(to_fixed(GLUE_SHAKE_KICK), a), a)
	functions[3] = glue_focus_fn(a)
	functions[4] = glue_box_size_fn(a)
	// SHAKE_DAMP and SLOT are read inline in their bodies (a Fixed literal / a String
	// literal node), so they need no const-fn — shake folds the literal directly.

	behaviors := make([]Behavior_Decl, 12, a)
	behaviors[0] = glue_drive_behavior(a)
	behaviors[1] = glue_deliver_behavior(a)
	behaviors[2] = glue_tally_behavior(a)
	behaviors[3] = glue_follow_behavior(a)
	behaviors[4] = glue_shake_behavior(a)
	behaviors[5] = glue_view_behavior(a)
	behaviors[6] = glue_save_key_behavior(a)
	behaviors[7] = glue_restore_key_behavior(a)
	behaviors[8] = glue_toggle_motion_behavior(a)
	behaviors[9] = glue_apply_settings_behavior(a)
	behaviors[10] = glue_on_persist_result_behavior(a)
	behaviors[11] = glue_on_settings_applied_behavior(a)

	return Program{enums = enums, functions = functions, behaviors = behaviors}
}

// glue_one_variant is a one-case enum variant set (Drive::Move) — the Axis action
// drive binds to.
@(private = "file")
glue_one_variant :: proc(name: string, a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 1, a)
	v[0] = Enum_Variant{name = name, payload = "unit"}
	return v
}

// glue_cmd_variants is the Cmd:Button enum's four menu actions (Save/Restore/
// ToggleMotion/Apply) — the buttons the menu behaviors gate on. The registry mints
// one ActionId per variant in this order.
@(private = "file")
glue_cmd_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 4, a)
	v[0] = Enum_Variant{name = "Save", payload = "unit"}
	v[1] = Enum_Variant{name = "Restore", payload = "unit"}
	v[2] = Enum_Variant{name = "ToggleMotion", payload = "unit"}
	v[3] = Enum_Variant{name = "Apply", payload = "unit"}
	return v
}

// --- behavior bodies (yard.fun verbatim, in node form) --------------------

// glue_drive_behavior builds drive on Player: `let push = input.axis(P1,
// Drive::Move) * ACCEL; return self with { body: self.body.apply_impulse(push) }`
// — the move-axis read scaled to an impulse and accumulated on the body intent.
@(private = "file")
glue_drive_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	// let push = input.axis(P1, Drive::Move) * ACCEL
	axis_read := glue_method_call(
		name_node("input", a),
		"axis",
		a,
		variant_unit_node("PlayerId", "P1", a),
		variant_unit_node("Drive", "Move", a),
	)
	body[0] = let_node("push", binary_node("mul", axis_read, name_node("ACCEL", a), a), a)
	// return self with { body: self.body.apply_impulse(push) }
	impulse := glue_apply_impulse_call(
		field_node_h(name_node("self", a), "body", a),
		name_node("push", a),
	)
	body[1] = return_node_h(with_node(name_node("self", a), a, recfield_spec("body", impulse)), a)
	return glue_behavior("drive", "Player", glue_two_params("self", "Player", "input", "Input", a), body, a)
}

// glue_deliver_behavior builds deliver on Crate: `if is_empty(pads) { return ([],
// []) }; return ([Despawn()], [Delivered{}])` — the Trigger-gated despawn/signal
// split (a tuple of two lists the tick splits).
@(private = "file")
glue_deliver_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	// if is_empty(pads) { return ([], []) }
	empty_tuple := tuple_node(a, list_node(a), list_node(a))
	body[0] = if_return_node(call_node_h(a, "is_empty", name_node("pads", a)), empty_tuple, a)
	// return ([Despawn()], [Delivered{}])
	despawn := call_node_h(a, "Despawn")
	delivered := glue_record_node("Delivered", a)
	full_tuple := tuple_node(a, list_node(a, despawn), list_node(a, delivered))
	body[1] = return_node_h(full_tuple, a)
	return glue_behavior("deliver", "Crate", glue_two_params("self", "Crate", "pads", "[Trigger]", a), body, a)
}

// glue_tally_behavior builds tally on Scoreboard: `return self with { delivered:
// self.delivered + len(done) }` — the +len fold of this tick's deliveries.
@(private = "file")
glue_tally_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 1, a)
	count := binary_node(
		"add",
		field_node_h(name_node("self", a), "delivered", a),
		call_node_h(a, "len", name_node("done", a)),
		a,
	)
	body[0] = return_node_h(with_node(name_node("self", a), a, recfield_spec("delivered", count)), a)
	return glue_behavior("tally", "Scoreboard", glue_two_params("self", "Scoreboard", "done", "[Delivered]", a), body, a)
}

// glue_focus_fn builds focus(players, fallback): `return match first(players) {
// Some(p) => p.pos, None => fallback }` — the camera-track point helper follow
// reads (the first player's position, or the fallback when there is none).
@(private = "file")
glue_focus_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "players", type = "View[Player]"}
	params[1] = Param_Decl{name = "fallback", type = "Vec2"}

	scrutinee := call_node_h(a, "first", name_node("players", a))
	some_arm := variant_binds_arm("Option", "Some", "p", a)
	some_body := field_node_h(name_node("p", a), "pos", a)
	none_arm := bare_variant_arm("Option", "None", a)
	none_body := name_node("fallback", a)
	match := match_node(scrutinee, a, some_arm, some_body, none_arm, none_body)

	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "focus", kind = .Fn, params = params, body = body}
}

// glue_box_size_fn builds box_size(shape): `return match shape { Shape2::Box{size}
// => size, _ => Vec2{8.0, 8.0} }` — the struct-field-pun match (yard's draw_wall/
// draw_pad size read). The Box arm puns the `size` field off the variant's struct
// payload; the wildcard arm falls back to a small square. This proves the new
// struct_binds match pattern this story lands.
@(private = "file")
glue_box_size_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 1, a)
	params[0] = Param_Decl{name = "shape", type = "Shape2"}

	box_arm := glue_struct_binds_arm("Shape2", "Box", a, "size")
	box_body := name_node("size", a)
	wild_arm := glue_wildcard_arm(a)
	wild_body := vec2_literal(to_fixed(8), to_fixed(8))
	match := match_node(name_node("shape", a), a, box_arm, box_body, wild_arm, wild_body)

	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "box_size", kind = .Fn, params = params, body = body}
}

// glue_follow_behavior builds follow on Camera: `let target = focus(players,
// self.at); return self with { at: self.at + (target - self.at) * FOLLOW }` — the
// fixed-fraction camera ease toward the tracked point.
@(private = "file")
glue_follow_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	body[0] = let_node(
		"target",
		call_node_h(a, "focus", name_node("players", a), field_node_h(name_node("self", a), "at", a)),
		a,
	)
	// self.at + (target - self.at) * FOLLOW
	gap := binary_node("sub", name_node("target", a), field_node_h(name_node("self", a), "at", a), a)
	eased := binary_node("add", field_node_h(name_node("self", a), "at", a), binary_node("mul", gap, name_node("FOLLOW", a), a), a)
	body[1] = return_node_h(with_node(name_node("self", a), a, recfield_spec("at", eased)), a)
	return glue_behavior("follow", "Camera", glue_two_params("self", "Camera", "players", "View[Player]", a), body, a)
}

// glue_shake_behavior builds shake on Camera: `if not is_empty(done) { return self
// with { shake: Vec2{SHAKE_KICK, 0.0} } }; return self with { shake: self.shake *
// SHAKE_DAMP }` — the kick-on-delivery / flip-and-halve-idle oscillation. SHAKE_DAMP
// (-0.5) is a Fixed literal node folded inline.
@(private = "file")
glue_shake_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	// if not is_empty(done) { return self with { shake: Vec2{SHAKE_KICK, 0.0} } }
	kick := with_node(
		name_node("self", a),
		a,
		recfield_spec("shake", glue_vec2_record(name_node("SHAKE_KICK", a), glue_fixed_node(to_fixed(0), a), a)),
	)
	guard := unary_node("not", call_node_h(a, "is_empty", name_node("done", a)), a)
	body[0] = if_return_node(guard, kick, a)
	// return self with { shake: self.shake * SHAKE_DAMP }
	decayed := binary_node("mul", field_node_h(name_node("self", a), "shake", a), glue_fixed_node(glue_shake_damp(), a), a)
	body[1] = return_node_h(with_node(name_node("self", a), a, recfield_spec("shake", decayed)), a)
	return glue_behavior("shake", "Camera", glue_two_params("self", "Camera", "done", "[Delivered]", a), body, a)
}

// glue_view_behavior builds view on Camera: `return [Draw::Camera{at: self.at +
// self.shake, zoom: self.zoom, rotation: 0.0}]` — the camera projection offset by
// the current shake. The behavior returns the Draw::Camera record; the lowering is
// the camera story's.
@(private = "file")
glue_view_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 1, a)
	at := binary_node("add", field_node_h(name_node("self", a), "at", a), field_node_h(name_node("self", a), "shake", a), a)
	cam := glue_record_node_fields(
		"Draw::Camera",
		a,
		recfield_spec("at", at),
		recfield_spec("zoom", field_node_h(name_node("self", a), "zoom", a)),
		recfield_spec("rotation", glue_fixed_node(to_fixed(0), a)),
	)
	body[0] = return_node_h(list_node(a, cam), a)
	return glue_behavior("view", "Camera", glue_one_param("self", "Camera", a), body, a)
}

// glue_save_key_behavior builds save_key on Menu: `if input.pressed(P1, Cmd::Save)
// { return [Save{slot: SLOT}] }; return []` — the key-gated quicksave command emit.
@(private = "file")
glue_save_key_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	return glue_command_key_behavior("save_key", "Save", "Save", a)
}

// glue_restore_key_behavior builds restore_key on Menu: `if input.pressed(P1,
// Cmd::Restore) { return [Restore{slot: SLOT}] }; return []` — the key-gated
// quickload command emit.
@(private = "file")
glue_restore_key_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	return glue_command_key_behavior("restore_key", "Restore", "Restore", a)
}

// glue_command_key_behavior is the shared body of save_key/restore_key: gate a
// `[Command{slot: SLOT}]` emit on `input.pressed(P1, Cmd::Button)`, else emit [].
// Both behaviors differ only by the Cmd button and the command type, so one builder
// parametrizes them (the slot is the SLOT String literal).
@(private = "file")
glue_command_key_behavior :: proc(name, button, command: string, a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	pressed := glue_method_call(
		name_node("input", a),
		"pressed",
		a,
		variant_unit_node("PlayerId", "P1", a),
		variant_unit_node("Cmd", button, a),
	)
	cmd := glue_record_node_fields(command, a, recfield_spec("slot", glue_string_node(GLUE_SLOT, a)))
	body[0] = if_return_node(pressed, list_node(a, cmd), a)
	body[1] = return_node_h(list_node(a), a)
	return glue_behavior(name, "Menu", glue_two_params("self", "Menu", "input", "Input", a), body, a)
}

// glue_toggle_motion_behavior builds toggle_motion on Menu: `if not input.pressed(
// P1, Cmd::ToggleMotion) { return self }; let access = self.settings.access with {
// reduce_motion: not self.settings.access.reduce_motion }; return self with {
// settings: self.settings with { access: access }, dirty: true }` — the nested
// with-update through a field path.
@(private = "file")
glue_toggle_motion_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 3, a)
	// if not input.pressed(P1, Cmd::ToggleMotion) { return self }
	pressed := glue_method_call(
		name_node("input", a),
		"pressed",
		a,
		variant_unit_node("PlayerId", "P1", a),
		variant_unit_node("Cmd", "ToggleMotion", a),
	)
	body[0] = if_return_node(unary_node("not", pressed, a), name_node("self", a), a)
	// let access = self.settings.access with { reduce_motion: not self.settings.access.reduce_motion }
	access_path := field_node_h(field_node_h(name_node("self", a), "settings", a), "access", a)
	current := field_node_h(field_node_h(field_node_h(name_node("self", a), "settings", a), "access", a), "reduce_motion", a)
	body[1] = let_node(
		"access",
		with_node(access_path, a, recfield_spec("reduce_motion", unary_node("not", current, a))),
		a,
	)
	// return self with { settings: self.settings with { access: access }, dirty: true }
	settings_update := with_node(field_node_h(name_node("self", a), "settings", a), a, recfield_spec("access", name_node("access", a)))
	body[2] = return_node_h(
		with_node(
			name_node("self", a),
			a,
			recfield_spec("settings", settings_update),
			recfield_spec("dirty", name_node("true", a)),
		),
		a,
	)
	return glue_behavior("toggle_motion", "Menu", glue_two_params("self", "Menu", "input", "Input", a), body, a)
}

// glue_apply_settings_behavior builds apply_settings on Menu: `if self.dirty and
// input.pressed(P1, Cmd::Apply) { return [ApplySettings{settings: self.settings}]
// }; return []` — the dirty-AND-key-gated ApplySettings command emit.
@(private = "file")
glue_apply_settings_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	pressed := glue_method_call(
		name_node("input", a),
		"pressed",
		a,
		variant_unit_node("PlayerId", "P1", a),
		variant_unit_node("Cmd", "Apply", a),
	)
	gate := binary_node("and", field_node_h(name_node("self", a), "dirty", a), pressed, a)
	cmd := glue_record_node_fields(
		"ApplySettings",
		a,
		recfield_spec("settings", field_node_h(name_node("self", a), "settings", a)),
	)
	body[0] = if_return_node(gate, list_node(a, cmd), a)
	body[1] = return_node_h(list_node(a), a)
	return glue_behavior("apply_settings", "Menu", glue_two_params("self", "Menu", "input", "Input", a), body, a)
}

// glue_on_persist_result_behavior builds on_persist_result on Menu: a fold over
// [Saved] then over [Restored], each lambda matching `r.result { Ok(_) => m with {
// status: Some("…") }, Err(_) => m with { status: Some("… failed") } }` — the
// outcome-recording fold (AX4: the error case is never dropped).
@(private = "file")
glue_on_persist_result_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	// let after_save = fold(saved, self, fn(m, r) { match r.result { Ok => "saved", Err => "save failed" } })
	body[0] = let_node(
		"after_save",
		call_node_h(a, "fold", name_node("saved", a), name_node("self", a), glue_result_fold_lambda("saved", "save failed", a)),
		a,
	)
	// return fold(restored, after_save, fn(m, r) { match r.result { Ok => "restored", Err => "restore failed" } })
	body[1] = return_node_h(
		call_node_h(a, "fold", name_node("restored", a), name_node("after_save", a), glue_result_fold_lambda("restored", "restore failed", a)),
		a,
	)
	params := make([]Param_Decl, 3, a)
	params[0] = Param_Decl{name = "self", type = "Menu"}
	params[1] = Param_Decl{name = "saved", type = "[Saved]"}
	params[2] = Param_Decl{name = "restored", type = "[Restored]"}
	return glue_behavior("on_persist_result", "Menu", params, body, a)
}

// glue_on_settings_applied_behavior builds on_settings_applied on Menu: `return
// fold(applied, self, fn(m, r) { match r.result { Ok(_) => m with { dirty: false,
// status: Some("settings applied") }, Err(_) => m with { status: Some("settings
// save failed") } } })` — the apply-outcome fold that clears dirty on success.
@(private = "file")
glue_on_settings_applied_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 1, a)
	body[0] = return_node_h(
		call_node_h(a, "fold", name_node("applied", a), name_node("self", a), glue_settings_applied_lambda(a)),
		a,
	)
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "self", type = "Menu"}
	params[1] = Param_Decl{name = "applied", type = "[SettingsApplied]"}
	return glue_behavior("on_settings_applied", "Menu", params, body, a)
}

// glue_result_fold_lambda builds an `fn(m, r) { return match r.result { Ok(_) => m
// with { status: Some(ok_text) }, Err(_) => m with { status: Some(err_text) } } }`
// combiner — the per-signal Result match the persist fold threads. The bodies set
// only `status` (a Some-wrapped String), so the prior menu carries forward.
@(private = "file")
glue_result_fold_lambda :: proc(ok_text, err_text: string, a := context.allocator) -> Node {
	ok_arm := variant_binds_arm("Result", "Ok", "_", a)
	ok_body := with_node(name_node("m", a), a, recfield_spec("status", glue_some_string(ok_text, a)))
	err_arm := variant_binds_arm("Result", "Err", "_", a)
	err_body := with_node(name_node("m", a), a, recfield_spec("status", glue_some_string(err_text, a)))
	match := match_node(field_node_h(name_node("r", a), "result", a), a, ok_arm, ok_body, err_arm, err_body)
	return glue_lambda(a, match, "m", "r")
}

// glue_settings_applied_lambda builds the on_settings_applied combiner `fn(m, r) {
// return match r.result { Ok(_) => m with { dirty: false, status: Some("settings
// applied") }, Err(_) => m with { status: Some("settings save failed") } } }` — the
// Ok arm clears dirty AND sets status; the Err arm sets only status (dirty stays).
@(private = "file")
glue_settings_applied_lambda :: proc(a := context.allocator) -> Node {
	ok_arm := variant_binds_arm("Result", "Ok", "_", a)
	ok_body := with_node(
		name_node("m", a),
		a,
		recfield_spec("dirty", name_node("false", a)),
		recfield_spec("status", glue_some_string("settings applied", a)),
	)
	err_arm := variant_binds_arm("Result", "Err", "_", a)
	err_body := with_node(name_node("m", a), a, recfield_spec("status", glue_some_string("settings save failed", a)))
	match := match_node(field_node_h(name_node("r", a), "result", a), a, ok_arm, ok_body, err_arm, err_body)
	return glue_lambda(a, match, "m", "r")
}

// ==========================================================================
// Value fixtures (the records/lists/snapshots the bodies fold over).
// ==========================================================================

// glue_body_record builds a Body Record_Value carrying a starting impulse — the
// receiver `body.apply_impulse(…)` accumulates onto. The kind/shape/layer columns
// the solver reads are not pinned by the glue tests, so only impulse is set.
@(private = "file")
glue_body_record :: proc(impulse: Vec2) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["impulse"] = impulse
	return Record_Value{type_name = "Body", fields = fields}
}

// glue_player_record builds a Player blackboard with a pos and a body — the `self`
// drive folds (drive writes only the body's accumulated impulse).
@(private = "file")
glue_player_record :: proc(pos: Vec2, body: Value) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["pos"] = pos
	fields["body"] = body
	return Record_Value{type_name = "Player", fields = fields}
}

// glue_crate_record builds a Crate blackboard — deliver reads no field off it (it
// returns a constant tuple gated on the pads list), so the record is a bare marker.
@(private = "file")
glue_crate_record :: proc() -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	return Record_Value{type_name = "Crate", fields = fields}
}

// glue_scoreboard builds a Scoreboard with a delivered Int count — the `self`
// tally folds the +len onto.
@(private = "file")
glue_scoreboard :: proc(delivered: i64) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["delivered"] = delivered
	return Record_Value{type_name = "Scoreboard", fields = fields}
}

// glue_camera builds a Camera blackboard with `at`/`shake` Vec2s and zoom 1.0 — the
// `self` follow/shake/view fold.
@(private = "file")
glue_camera :: proc(at, shake: Vec2) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["at"] = at
	fields["zoom"] = to_fixed(1)
	fields["shake"] = shake
	return Record_Value{type_name = "Camera", fields = fields}
}

// glue_menu_default builds a Menu seeded from Settings.defaults() with dirty false
// and a None status — the fresh menu the toggle/save/persist behaviors fold from.
// The settings carry the canonical default (access.reduce_motion false).
@(private = "file")
glue_menu_default :: proc() -> Value {
	access := make(map[string]Value, context.temp_allocator)
	access["reduce_motion"] = false
	settings := make(map[string]Value, context.temp_allocator)
	settings["access"] = Record_Value{type_name = "Access", fields = access}

	fields := make(map[string]Value, context.temp_allocator)
	fields["settings"] = Record_Value{type_name = "Settings", fields = settings}
	fields["dirty"] = false
	fields["status"] = Variant_Value{enum_type = "Option", case_name = "None"}
	return Record_Value{type_name = "Menu", fields = fields}
}

// glue_menu_dirty builds a Menu with unapplied edits (dirty true) — the apply/
// settings-applied tests gate on the dirty flag.
@(private = "file")
glue_menu_dirty :: proc() -> Value {
	rec := glue_menu_default().(Record_Value)
	rec.fields["dirty"] = true
	return rec
}

// glue_player_view builds a View[Player] list with one player at `pos` — the
// View.of fixture follow's focus reads (a View[T] param binds as a List_Value of
// player records, tick.odin view_rows_as_list).
@(private = "file")
glue_player_view :: proc(pos: Vec2) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["pos"] = pos
	player := Record_Value{type_name = "Player", fields = fields}
	elements := make([]Value, 1, context.temp_allocator)
	elements[0] = player
	return List_Value{elements = elements}
}

// glue_empty_view builds an empty View[Player] — the no-player case follow's focus
// falls through to its fallback arm on.
@(private = "file")
glue_empty_view :: proc() -> Value {
	return List_Value{elements = make([]Value, 0, context.temp_allocator)}
}

// glue_trigger builds a Trigger signal record — the engine-routed pad overlap
// deliver gates on (a non-empty pads list means the crate landed on the pad).
@(private = "file")
glue_trigger :: proc() -> Value {
	return Record_Value{type_name = "Trigger", fields = make(map[string]Value, context.temp_allocator)}
}

// glue_delivered builds a Delivered signal record — the broadcast tally folds and
// shake gates the kick on.
@(private = "file")
glue_delivered :: proc() -> Value {
	return Record_Value{type_name = "Delivered", fields = make(map[string]Value, context.temp_allocator)}
}

// glue_result_signal builds a Saved/Restored/SettingsApplied signal carrying a
// `result: Result::Ok/Err` — the engine outcome the persist/apply folds match. The
// Result variant boxes a unit payload (a bare marker), the `_`-binder arm discards.
@(private = "file")
glue_result_signal :: proc(signal, outcome: string) -> Value {
	payload := new(Value, context.temp_allocator)
	payload^ = Record_Value{type_name = "", fields = make(map[string]Value, context.temp_allocator)}
	result := Variant_Value{enum_type = "Result", case_name = outcome, payload = payload}
	fields := make(map[string]Value, context.temp_allocator)
	fields["result"] = result
	return Record_Value{type_name = signal, fields = fields}
}

// glue_shape2_box builds a `Shape2::Box{size}` variant value — a struct-payload
// variant carrying a `size` Vec2 column as its Record_Value payload, the shape the
// struct-pun match destructures.
@(private = "file")
glue_shape2_box :: proc(size: Vec2) -> Value {
	payload_fields := make(map[string]Value, context.temp_allocator)
	payload_fields["size"] = size
	payload := new(Value, context.temp_allocator)
	payload^ = Record_Value{type_name = "", fields = payload_fields}
	return Variant_Value{enum_type = "Shape2", case_name = "Box", payload = payload}
}

// glue_call_one applies a one-param §9 helper against its seeded param, folding the
// body — the driver for box_size whose single arg is a runtime Shape2 value.
@(private = "file")
glue_call_one :: proc(interp: ^Interp, name: string, arg: Value) -> (result: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 1 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = arg
	return eval_body(interp, fn.body, &scope)
}

// glue_list builds a List_Value from element values — a signal/command list a body
// folds or returns.
@(private = "file")
glue_list :: proc(elements: ..Value) -> Value {
	out := make([]Value, len(elements), context.temp_allocator)
	copy(out, elements)
	return List_Value{elements = out}
}

// ==========================================================================
// Expectation helpers.
// ==========================================================================

// expect_glue_vec2 asserts a record's Vec2 column equals the expected vector
// bit-for-bit (the §10 kernel value, never a float).
@(private = "file")
expect_glue_vec2 :: proc(t: ^testing.T, rec: Record_Value, field: string, want: Vec2) {
	v, present := rec.fields[field]
	testing.expect(t, present)
	got, is_vec2 := v.(Vec2)
	testing.expect(t, is_vec2)
	testing.expect_value(t, got.x, want.x)
	testing.expect_value(t, got.y, want.y)
}

// expect_deliver_result asserts deliver's ([Despawn], [Delivered]) tuple: on a
// delivery (`on_pad`) the despawn list holds one Despawn and the signal list one
// Delivered; off the pad both are empty.
@(private = "file")
expect_deliver_result :: proc(t: ^testing.T, result: Value, on_pad: bool) {
	tuple, is_tuple := result.(Tuple_Value)
	testing.expect(t, is_tuple)
	testing.expect_value(t, len(tuple.elements), 2)
	despawns := tuple.elements[0].(List_Value)
	signals := tuple.elements[1].(List_Value)
	if on_pad {
		testing.expect_value(t, len(despawns.elements), 1)
		testing.expect_value(t, len(signals.elements), 1)
		testing.expect_value(t, despawns.elements[0].(Record_Value).type_name, "Despawn")
		testing.expect_value(t, signals.elements[0].(Record_Value).type_name, "Delivered")
	} else {
		testing.expect_value(t, len(despawns.elements), 0)
		testing.expect_value(t, len(signals.elements), 0)
	}
}

// expect_command_list asserts a single-command emit list `[Command{slot}]` — the
// save/restore command shape carrying the quicksave slot String.
@(private = "file")
expect_command_list :: proc(t: ^testing.T, result: Value, command, slot: string) {
	list, is_list := result.(List_Value)
	testing.expect(t, is_list)
	testing.expect_value(t, len(list.elements), 1)
	cmd := list.elements[0].(Record_Value)
	testing.expect_value(t, cmd.type_name, command)
	str, is_str := cmd.fields["slot"].(String_Value)
	testing.expect(t, is_str)
	testing.expect_value(t, str.text, slot)
}

// expect_status asserts a menu record's status is Option::Some(text) — the
// outcome string the persist/apply folds set.
@(private = "file")
expect_status :: proc(t: ^testing.T, result: Value, text: string) {
	rec, is_record := result.(Record_Value)
	testing.expect(t, is_record)
	status, present := rec.fields["status"]
	testing.expect(t, present)
	variant, is_variant := status.(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, variant.case_name, "Some")
	testing.expect(t, variant.payload != nil)
	str, is_str := variant.payload^.(String_Value)
	testing.expect(t, is_str)
	testing.expect_value(t, str.text, text)
}

// ==========================================================================
// Interpreter + env + node-builder helpers.
// ==========================================================================

// glue_interp builds a read-only interpreter over an EMPTY program — for the
// standalone apply_impulse node test that reads no enum/behavior surface.
@(private = "file")
glue_interp :: proc() -> Interp {
	program := Program{}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	committed := new(World_Version, context.temp_allocator)
	committed^ = version
	return new_interp(&program, committed, nil, empty(), glue_time(), context.temp_allocator)
}

// glue_interp_over builds a read-only interpreter over the hand-built yard program
// (its registry mints the Drive/Cmd actions the menu/drive behaviors read). The
// version is the empty initial one — the glue tests bind their own self/View
// fixtures directly, never committing rows.
@(private = "file")
glue_interp_over :: proc(program: ^Program) -> Interp {
	version := initial_version(new_world(program^, context.temp_allocator), context.temp_allocator)
	committed := new(World_Version, context.temp_allocator)
	committed^ = version
	return new_interp(program, committed, nil, empty(), glue_time(), context.temp_allocator)
}

// glue_time is the Time resource a behavior's `time` param would bind to — one dt
// field at the fixed 60hz step, kernel-derived (no glue behavior reads dt, but the
// resource is bound regardless).
@(private = "file")
glue_time :: proc() -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

// glue_env opens a fresh evaluation scope for a behavior body — the tick's
// param-binding env the test seeds self/resources/signals/Views into.
@(private = "file")
glue_env :: proc() -> Env {
	return Env{names = make(map[string]Value, context.temp_allocator)}
}

// glue_run_menu binds a Menu behavior's (self, input) params and folds its body —
// the driver for the menu behaviors whose two reads are the self menu and the Input
// snapshot.
@(private = "file")
glue_run_menu :: proc(interp: ^Interp, behavior: ^Behavior_Decl, menu: Value) -> (result: Value, ok: bool) {
	env := glue_env()
	env.names["self"] = menu
	env.names["input"] = input_marker(interp)
	return eval_behavior_body(interp, behavior.body, &env)
}

// glue_a returns the test temp allocator — the arena every hand-built node escapes
// into (a compound slice literal cannot escape a stack frame in Odin).
@(private = "file")
glue_a :: proc() -> Runtime_Allocator {
	return context.temp_allocator
}

// glue_behavior builds a Behavior_Decl with one emit and the supplied params/body —
// the on-Thing transition the glue tests evaluate.
@(private = "file")
glue_behavior :: proc(name, on_thing: string, params: []Param_Decl, body: []Node, a := context.allocator) -> Behavior_Decl {
	emits := make([]string, 1, a)
	emits[0] = on_thing
	return Behavior_Decl{name = name, on_thing = on_thing, params = params, emits = emits, body = body}
}

// glue_one_param / glue_two_params build a behavior's param list — (self) and
// (self, second) in order, the read shapes the bodies bind.
@(private = "file")
glue_one_param :: proc(name, type: string, a := context.allocator) -> []Param_Decl {
	params := make([]Param_Decl, 1, a)
	params[0] = Param_Decl{name = name, type = type}
	return params
}

@(private = "file")
glue_two_params :: proc(n0, t0, n1, t1: string, a := context.allocator) -> []Param_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = n0, type = t0}
	params[1] = Param_Decl{name = n1, type = t1}
	return params
}

// glue_const_fn builds a module-level `let NAME = value` const (a nullary function
// the body resolves through eval_name — ACCEL/FOLLOW/SHAKE_KICK read this way).
@(private = "file")
glue_const_fn :: proc(name: string, value: Node, a := context.allocator) -> Function_Decl {
	body := make([]Node, 1, a)
	body[0] = return_node_h(value, a)
	return Function_Decl{name = name, kind = .Const, body = body}
}

// --- node constructors (file-private; sibling test files keep their own) ---
// These mirror the §2.7 subtree builders hunt_fixtures_test.odin defines, but
// every node-constructor there is @(private="file"), so this file carries its own
// copies — the file-private scope means the two sets never collide.

// name_node builds a `.Name` reference node — a param/let/const identifier the body
// resolves through the scope chain.
@(private = "file")
name_node :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

// field_node_h builds a `.Field` access node `recv.FIELD` over a single receiver
// child — the column reads the bodies perform (self.at, self.settings.access, …).
@(private = "file")
field_node_h :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

// binary_node builds a `.Binary` op node `lhs OP rhs` over the kernel — the
// arithmetic (add/sub/mul) and logical (and) the bodies fold through.
@(private = "file")
binary_node :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

// call_node_h builds a `.Call` node: child[0] the callee `.Name`, children[1:] the
// arg subtrees read positionally — the is_empty/len/fold/focus/Despawn calls.
@(private = "file")
call_node_h :: proc(a: Runtime_Allocator, callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = name_node(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

// match_node builds a `.Match` node: child[0] the scrutinee, the rest alternating
// arm/body in source order — focus's first-match and the fold lambdas' Result match.
@(private = "file")
match_node :: proc(scrutinee: Node, a: Runtime_Allocator, arms_bodies: ..Node) -> Node {
	children := make([]Node, len(arms_bodies) + 1, a)
	children[0] = scrutinee
	for n, i in arms_bodies {
		children[i + 1] = n
	}
	return Node{kind = .Match, children = children}
}

// Recfield_Spec_H is one `name = value` pair of a with/record update — the field
// name and its already-built value subtree.
@(private = "file")
Recfield_Spec_H :: struct {
	name:  string,
	value: Node,
}

// recfield_spec is the terse constructor for a Recfield_Spec_H pair.
@(private = "file")
recfield_spec :: proc(name: string, value: Node) -> Recfield_Spec_H {
	return Recfield_Spec_H{name = name, value = value}
}

// recfield_node_h builds a `.Recfield` node `NAME = value` — one field of a with/
// record literal, its value the carried subtree.
@(private = "file")
recfield_node_h :: proc(spec: Recfield_Spec_H, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = spec.name
	children := make([]Node, 1, a)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

// with_node builds a `.With` functional-update node — child[0] the base, the rest
// the replacement recfields (every `value with { … }` the bodies return).
@(private = "file")
with_node :: proc(base: Node, a: Runtime_Allocator, specs: ..Recfield_Spec_H) -> Node {
	children := make([]Node, len(specs) + 1, a)
	children[0] = base
	for spec, i in specs {
		children[i + 1] = recfield_node_h(spec, a)
	}
	return Node{kind = .With, children = children}
}

// variant_unit_node builds a unit `.Variant` value node `variant ENUM CASE false` —
// Option::None and the enum cases the bodies write.
@(private = "file")
variant_unit_node :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "false"
	return Node{kind = .Variant, fields = fields}
}

// variant_payload_node builds a single-payload `.Variant` value node `variant ENUM
// CASE true` with the payload subtree as its lone child — Option::Some("status").
@(private = "file")
variant_payload_node :: proc(enum_type, case_name: string, payload: Node, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "true"
	children := make([]Node, 1, a)
	children[0] = payload
	return Node{kind = .Variant, fields = fields, children = children}
}

// variant_binds_arm builds an `.Arm` pattern node `variant_binds ENUM CASE 1 BINDER`
// — the Some(p) / Result::Ok(_) arms binding the payload to one name (a `_` binder
// discards).
@(private = "file")
variant_binds_arm :: proc(enum_type, case_name, binder: string, a := context.allocator) -> Node {
	fields := make([]string, 5, a)
	fields[0] = "variant_binds"
	fields[1] = enum_type
	fields[2] = case_name
	fields[3] = "1"
	fields[4] = binder
	return Node{kind = .Arm, fields = fields}
}

// bare_variant_arm builds an `.Arm` pattern node `bare_variant ENUM CASE` — the
// no-binder case match (Option::None in focus).
@(private = "file")
bare_variant_arm :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = "bare_variant"
	fields[1] = enum_type
	fields[2] = case_name
	return Node{kind = .Arm, fields = fields}
}

// let_node builds a `.Let` statement node `let NAME = value` — the bindings the
// bodies thread (push, target, access, after_save).
@(private = "file")
let_node :: proc(name: string, value: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Let, fields = fields, children = children}
}

// if_return_node builds an `.If_Return` statement node `if GUARD { return VALUE }` —
// child[0] the guard, child[1] the returned value (the input/dirty gates).
@(private = "file")
if_return_node :: proc(guard, value: Node, a := context.allocator) -> Node {
	children := make([]Node, 2, a)
	children[0] = guard
	children[1] = value
	return Node{kind = .If_Return, children = children}
}

// return_node_h builds a `.Return` statement node wrapping its value subtree — the
// body terminator yielding a behavior's folded result.
@(private = "file")
return_node_h :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}

// glue_fixed_node builds a `.Fixed` literal node carrying the raw Q32.32 bits token
// decode_fixed parses back — the form a Fixed const/literal lowers to.
@(private = "file")
glue_fixed_node :: proc(f: Fixed, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	buf := make([]u8, 24, a)
	fields[0] = strconv.write_int(buf, i64(f), 10)
	return Node{kind = .Fixed, fields = fields}
}

// glue_string_node builds a `.String` literal node carrying the length-prefixed
// `Lk:<bytes>` token decode_string parses back — the SLOT quicksave key and the
// status texts. The interpreter resolves any interpolation holes; these strings
// carry none, so the rendered value is the literal text.
@(private = "file")
glue_string_node :: proc(s: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	buf := make([]u8, 24, a)
	prefix := strconv.write_int(buf, i64(len(s)), 10)
	token := make([]u8, 1 + len(prefix) + 1 + len(s), a)
	token[0] = 'L'
	copy(token[1:], prefix)
	token[1 + len(prefix)] = ':'
	copy(token[1 + len(prefix) + 1:], s)
	fields[0] = string(token)
	return Node{kind = .String, fields = fields}
}

// glue_struct_binds_arm builds an `.Arm` struct-field-pun pattern `struct_binds
// ENUM CASE FIELD_COUNT field_names…` — the Shape2::Box{size} pattern that puns
// each named field off the variant's struct payload into scope. arm_matches reads
// fields[3] as the field count and fields[4:] as the punned field names.
@(private = "file")
glue_struct_binds_arm :: proc(enum_type, case_name: string, a: Runtime_Allocator, field_names: ..string) -> Node {
	fields := make([]string, 4 + len(field_names), a)
	fields[0] = "struct_binds"
	fields[1] = enum_type
	fields[2] = case_name
	buf := make([]u8, 8, a)
	fields[3] = strconv.write_int(buf, i64(len(field_names)), 10)
	for fname, i in field_names {
		fields[4 + i] = fname
	}
	return Node{kind = .Arm, fields = fields}
}

// glue_wildcard_arm builds an `.Arm` wildcard pattern `wildcard - -` — the `_`
// fallback box_size lands a non-Box shape on.
@(private = "file")
glue_wildcard_arm :: proc(a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = "wildcard"
	fields[1] = "-"
	fields[2] = "-"
	return Node{kind = .Arm, fields = fields}
}

// glue_method_call builds a `recv.method(args)` `.Call` over a `.Field` callee —
// the input.axis/pressed and body.apply_impulse dispatch forms.
@(private = "file")
glue_method_call :: proc(recv: Node, method: string, a: Runtime_Allocator, args: ..Node) -> Node {
	field := field_node_h(recv, method, a)
	children := make([]Node, len(args) + 1, a)
	children[0] = field
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

// glue_apply_impulse_call builds a `recv.apply_impulse(arg)` method call — the Body
// intent accumulation (drive's body write and the standalone two-push test).
@(private = "file")
glue_apply_impulse_call :: proc(recv, arg: Node) -> Node {
	a := context.temp_allocator
	return glue_method_call(recv, "apply_impulse", a, arg)
}

// glue_record_node builds a no-field `.Record` literal node `record TYPE 0` — a
// bare signal value like Delivered{}.
@(private = "file")
glue_record_node :: proc(type_name: string, a := context.allocator) -> Node {
	fields := make([]string, 2, a)
	fields[0] = type_name
	fields[1] = "0"
	return Node{kind = .Record, fields = fields}
}

// glue_record_node_fields builds a `.Record` literal node with one recfield child
// per supplied pair — the Draw::Camera / Save / ApplySettings command records.
@(private = "file")
glue_record_node_fields :: proc(type_name: string, a: Runtime_Allocator, specs: ..Recfield_Spec_H) -> Node {
	fields := make([]string, 2, a)
	fields[0] = type_name
	buf := make([]u8, 8, a)
	fields[1] = strconv.write_int(buf, i64(len(specs)), 10)
	children := make([]Node, len(specs), a)
	for spec, i in specs {
		children[i] = recfield_node_h(spec, a)
	}
	return Node{kind = .Record, fields = fields, children = children}
}

// glue_vec2_record builds a `Vec2{x: …, y: …}` `.Record` node — collapses to a Vec2
// value (shake's kick offset).
@(private = "file")
glue_vec2_record :: proc(x, y: Node, a := context.allocator) -> Node {
	return glue_record_node_fields("Vec2", a, recfield_spec("x", x), recfield_spec("y", y))
}

// vec2_literal builds a `Vec2{x, y}` record node from raw Fixed components — the
// impulse args the apply_impulse tests push.
@(private = "file")
vec2_literal :: proc(x, y: Fixed) -> Node {
	a := context.temp_allocator
	return glue_vec2_record(glue_fixed_node(x, a), glue_fixed_node(y, a), a)
}

// glue_some_string builds an `Option::Some("text")` variant node — the status the
// persist/apply folds wrap their outcome string in.
@(private = "file")
glue_some_string :: proc(text: string, a := context.allocator) -> Node {
	return variant_payload_node("Option", "Some", glue_string_node(text, a), a)
}

// list_node builds a `.List` literal node from element subtrees — the signal/
// command lists the bodies return.
@(private = "file")
list_node :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	copy(children, elements)
	return Node{kind = .List, children = children}
}

// tuple_node builds a `.Tuple` literal node from element subtrees — deliver's
// ([Despawn], [Delivered]) two-list pair.
@(private = "file")
tuple_node :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	copy(children, elements)
	return Node{kind = .Tuple, children = children}
}

// unary_node builds a `.Unary` op node — the `not` guard on the menu/shake input
// gates.
@(private = "file")
unary_node :: proc(op: string, operand: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 1, a)
	children[0] = operand
	return Node{kind = .Unary, fields = fields, children = children}
}

// glue_lambda builds an `fn(params) => expr` `.Lambda` node over a single body
// EXPRESSION — the fold combiners on_persist_result/on_settings_applied pass.
// eval_lambda evaluates child[0] as an expression (never a statement), so a
// single-return lambda lowers to its bare returned expression (the match itself),
// the same convention hunt's visible predicate uses (hunt_fixtures_test
// lambda_node_h). The closure yields the match result directly.
@(private = "file")
glue_lambda :: proc(a: Runtime_Allocator, body: Node, params: ..string) -> Node {
	fields := make([]string, len(params) + 1, a)
	buf := make([]u8, 8, a)
	fields[0] = strconv.write_int(buf, i64(len(params)), 10)
	for p, i in params {
		fields[i + 1] = p
	}
	children := make([]Node, 1, a)
	children[0] = body
	return Node{kind = .Lambda, fields = fields, children = children}
}
