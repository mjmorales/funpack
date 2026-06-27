package funpack_runtime

import "core:strconv"
import "core:testing"

@(private = "file")
GLUE_ACCEL :: 8
@(private = "file")
GLUE_SHAKE_KICK :: 4

@(private = "file")
glue_follow :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(4))
}

@(private = "file")
glue_shake_damp :: proc() -> Fixed {
	return fixed_neg(fixed_div(to_fixed(1), to_fixed(2)))
}

@(private = "file")
GLUE_SLOT :: "quicksave"

@(test)
test_glue_apply_impulse_accumulates :: proc(t: ^testing.T) {
	interp := glue_interp()

	body := glue_body_record(VEC2_ZERO)
	inner := glue_apply_impulse_call(name_node("b", glue_a()), vec2_literal(to_fixed(1), to_fixed(0)))
	outer := glue_apply_impulse_call(inner, vec2_literal(to_fixed(0), to_fixed(2)))

	env := glue_env()
	env.names["b"] = body
	result, ok := eval(&interp, &outer, &env)
	testing.expect(t, ok)
	rec := result.(Record_Value)
	expect_glue_vec2(t, rec, "impulse", Vec2{to_fixed(1), to_fixed(2)})
}

@(test)
test_glue_box_size_struct_pun :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)

	box := glue_shape2_box(Vec2{to_fixed(24), to_fixed(24)})
	box_result, b_ok := glue_call_one(&interp, "box_size", box)
	testing.expect(t, b_ok)
	got := box_result.(Vec2)
	testing.expect_value(t, got.x, to_fixed(24))
	testing.expect_value(t, got.y, to_fixed(24))

	circle := Variant_Value{enum_type = "Shape2", case_name = "Circle"}
	circle_result, c_ok := glue_call_one(&interp, "box_size", circle)
	testing.expect(t, c_ok)
	fallback := circle_result.(Vec2)
	testing.expect_value(t, fallback.x, to_fixed(8))
	testing.expect_value(t, fallback.y, to_fixed(8))
}

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

@(test)
test_glue_deliver_on_pad_and_inert :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	deliver := program_behavior(&program, "deliver")
	testing.expect(t, deliver != nil)

	on_pad := glue_env()
	on_pad.names["self"] = glue_crate_record()
	on_pad.names["pads"] = glue_list(glue_trigger())
	delivered, d_ok := eval_behavior_body(&interp, deliver.body, &on_pad)
	testing.expect(t, d_ok)
	expect_deliver_result(t, delivered, true)

	off_pad := glue_env()
	off_pad.names["self"] = glue_crate_record()
	off_pad.names["pads"] = glue_list()
	inert, i_ok := eval_behavior_body(&interp, deliver.body, &off_pad)
	testing.expect(t, i_ok)
	expect_deliver_result(t, inert, false)
}

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

@(test)
test_glue_shake_kicks_and_decays :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	shake := program_behavior(&program, "shake")
	testing.expect(t, shake != nil)

	kicked := glue_env()
	kicked.names["self"] = glue_camera(VEC2_ZERO, VEC2_ZERO)
	kicked.names["done"] = glue_list(glue_delivered())
	kick_result, k_ok := eval_behavior_body(&interp, shake.body, &kicked)
	testing.expect(t, k_ok)
	expect_glue_vec2(t, kick_result.(Record_Value), "shake", Vec2{to_fixed(GLUE_SHAKE_KICK), to_fixed(0)})

	idle := glue_env()
	idle.names["self"] = glue_camera(VEC2_ZERO, Vec2{to_fixed(4), to_fixed(0)})
	idle.names["done"] = glue_list()
	decay_result, d_ok := eval_behavior_body(&interp, shake.body, &idle)
	testing.expect(t, d_ok)
	expect_glue_vec2(t, decay_result.(Record_Value), "shake", Vec2{fixed_neg(to_fixed(2)), to_fixed(0)})
}

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

	pressed_save := with_pressed(empty(), .P1, save_id)
	defer delete_input(pressed_save)
	interp.input = pressed_save
	saved, s_ok := glue_run_menu(&interp, save_key, glue_menu_default())
	testing.expect(t, s_ok)
	expect_command_list(t, saved, "Save", GLUE_SLOT)

	none_snap := empty()
	defer delete_input(none_snap)
	interp.input = none_snap
	empty_result, e_ok := glue_run_menu(&interp, save_key, glue_menu_default())
	testing.expect(t, e_ok)
	testing.expect_value(t, len(empty_result.(List_Value).elements), 0)

	pressed_restore := with_pressed(empty(), .P1, restore_id)
	defer delete_input(pressed_restore)
	interp.input = pressed_restore
	restored, r_ok := glue_run_menu(&interp, restore_key, glue_menu_default())
	testing.expect(t, r_ok)
	expect_command_list(t, restored, "Restore", GLUE_SLOT)
}

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

	dirty_menu := glue_menu_dirty()
	emitted, ap_ok := glue_run_menu(&interp, apply, dirty_menu)
	testing.expect(t, ap_ok)
	list := emitted.(List_Value)
	testing.expect_value(t, len(list.elements), 1)
	cmd := list.elements[0].(Record_Value)
	testing.expect_value(t, cmd.type_name, "ApplySettings")
	testing.expect(t, values_equal(cmd.fields["settings"], dirty_menu.(Record_Value).fields["settings"]))

	clean, c_ok := glue_run_menu(&interp, apply, glue_menu_default())
	testing.expect(t, c_ok)
	testing.expect_value(t, len(clean.(List_Value).elements), 0)
}

@(test)
test_glue_on_persist_result_folds :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	on_persist := program_behavior(&program, "on_persist_result")
	testing.expect(t, on_persist != nil)

	saved_env := glue_env()
	saved_env.names["self"] = glue_menu_default()
	saved_env.names["saved"] = glue_list(glue_result_signal("Saved", "Ok"))
	saved_env.names["restored"] = glue_list()
	saved_result, s_ok := eval_behavior_body(&interp, on_persist.body, &saved_env)
	testing.expect(t, s_ok)
	expect_status(t, saved_result, "saved")

	failed_env := glue_env()
	failed_env.names["self"] = glue_menu_default()
	failed_env.names["saved"] = glue_list()
	failed_env.names["restored"] = glue_list(glue_result_signal("Restored", "Err"))
	failed_result, f_ok := eval_behavior_body(&interp, on_persist.body, &failed_env)
	testing.expect(t, f_ok)
	expect_status(t, failed_result, "restore failed")
}

@(test)
test_glue_on_settings_applied_folds :: proc(t: ^testing.T) {
	program := glue_program()
	interp := glue_interp_over(&program)
	on_applied := program_behavior(&program, "on_settings_applied")
	testing.expect(t, on_applied != nil)

	ok_env := glue_env()
	ok_env.names["self"] = glue_menu_dirty()
	ok_env.names["applied"] = glue_list(glue_result_signal("SettingsApplied", "Ok"))
	ok_result, o_ok := eval_behavior_body(&interp, on_applied.body, &ok_env)
	testing.expect(t, o_ok)
	ok_rec := ok_result.(Record_Value)
	expect_status(t, ok_result, "settings applied")
	testing.expect_value(t, ok_rec.fields["dirty"].(bool), false)

	err_env := glue_env()
	err_env.names["self"] = glue_menu_dirty()
	err_env.names["applied"] = glue_list(glue_result_signal("SettingsApplied", "Err"))
	err_result, e_ok := eval_behavior_body(&interp, on_applied.body, &err_env)
	testing.expect(t, e_ok)
	err_rec := err_result.(Record_Value)
	expect_status(t, err_result, "settings save failed")
	testing.expect_value(t, err_rec.fields["dirty"].(bool), true)
}

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

@(private = "file")
glue_one_variant :: proc(name: string, a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 1, a)
	v[0] = Enum_Variant{name = name, payload = "unit"}
	return v
}

@(private = "file")
glue_cmd_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 4, a)
	v[0] = Enum_Variant{name = "Save", payload = "unit"}
	v[1] = Enum_Variant{name = "Restore", payload = "unit"}
	v[2] = Enum_Variant{name = "ToggleMotion", payload = "unit"}
	v[3] = Enum_Variant{name = "Apply", payload = "unit"}
	return v
}

@(private = "file")
glue_drive_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	axis_read := glue_method_call(
		name_node("input", a),
		"axis",
		a,
		variant_unit_node("PlayerId", "P1", a),
		variant_unit_node("Drive", "Move", a),
	)
	body[0] = let_node("push", binary_node("mul", axis_read, name_node("ACCEL", a), a), a)
	impulse := glue_apply_impulse_call(
		field_node_h(name_node("self", a), "body", a),
		name_node("push", a),
	)
	body[1] = return_node_h(with_node(name_node("self", a), a, recfield_spec("body", impulse)), a)
	return glue_behavior("drive", "Player", glue_two_params("self", "Player", "input", "Input", a), body, a)
}

@(private = "file")
glue_deliver_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	empty_tuple := tuple_node(a, list_node(a), list_node(a))
	body[0] = if_return_node(call_node_h(a, "is_empty", name_node("pads", a)), empty_tuple, a)
	despawn := call_node_h(a, "Despawn")
	delivered := glue_record_node("Delivered", a)
	full_tuple := tuple_node(a, list_node(a, despawn), list_node(a, delivered))
	body[1] = return_node_h(full_tuple, a)
	return glue_behavior("deliver", "Crate", glue_two_params("self", "Crate", "pads", "[Trigger]", a), body, a)
}

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

@(private = "file")
glue_follow_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	body[0] = let_node(
		"target",
		call_node_h(a, "focus", name_node("players", a), field_node_h(name_node("self", a), "at", a)),
		a,
	)
	gap := binary_node("sub", name_node("target", a), field_node_h(name_node("self", a), "at", a), a)
	eased := binary_node("add", field_node_h(name_node("self", a), "at", a), binary_node("mul", gap, name_node("FOLLOW", a), a), a)
	body[1] = return_node_h(with_node(name_node("self", a), a, recfield_spec("at", eased)), a)
	return glue_behavior("follow", "Camera", glue_two_params("self", "Camera", "players", "View[Player]", a), body, a)
}

@(private = "file")
glue_shake_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	kick := with_node(
		name_node("self", a),
		a,
		recfield_spec("shake", glue_vec2_record(name_node("SHAKE_KICK", a), glue_fixed_node(to_fixed(0), a), a)),
	)
	guard := unary_node("not", call_node_h(a, "is_empty", name_node("done", a)), a)
	body[0] = if_return_node(guard, kick, a)
	decayed := binary_node("mul", field_node_h(name_node("self", a), "shake", a), glue_fixed_node(glue_shake_damp(), a), a)
	body[1] = return_node_h(with_node(name_node("self", a), a, recfield_spec("shake", decayed)), a)
	return glue_behavior("shake", "Camera", glue_two_params("self", "Camera", "done", "[Delivered]", a), body, a)
}

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

@(private = "file")
glue_save_key_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	return glue_command_key_behavior("save_key", "Save", "Save", a)
}

@(private = "file")
glue_restore_key_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	return glue_command_key_behavior("restore_key", "Restore", "Restore", a)
}

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

@(private = "file")
glue_toggle_motion_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 3, a)
	pressed := glue_method_call(
		name_node("input", a),
		"pressed",
		a,
		variant_unit_node("PlayerId", "P1", a),
		variant_unit_node("Cmd", "ToggleMotion", a),
	)
	body[0] = if_return_node(unary_node("not", pressed, a), name_node("self", a), a)
	access_path := field_node_h(field_node_h(name_node("self", a), "settings", a), "access", a)
	current := field_node_h(field_node_h(field_node_h(name_node("self", a), "settings", a), "access", a), "reduce_motion", a)
	body[1] = let_node(
		"access",
		with_node(access_path, a, recfield_spec("reduce_motion", unary_node("not", current, a))),
		a,
	)
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

@(private = "file")
glue_on_persist_result_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	body[0] = let_node(
		"after_save",
		call_node_h(a, "fold", name_node("saved", a), name_node("self", a), glue_result_fold_lambda("saved", "save failed", a)),
		a,
	)
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

@(private = "file")
glue_result_fold_lambda :: proc(ok_text, err_text: string, a := context.allocator) -> Node {
	ok_arm := variant_binds_arm("Result", "Ok", "_", a)
	ok_body := with_node(name_node("m", a), a, recfield_spec("status", glue_some_string(ok_text, a)))
	err_arm := variant_binds_arm("Result", "Err", "_", a)
	err_body := with_node(name_node("m", a), a, recfield_spec("status", glue_some_string(err_text, a)))
	match := match_node(field_node_h(name_node("r", a), "result", a), a, ok_arm, ok_body, err_arm, err_body)
	return glue_lambda(a, match, "m", "r")
}

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

@(private = "file")
glue_body_record :: proc(impulse: Vec2) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["impulse"] = impulse
	return Record_Value{type_name = "Body", fields = fields}
}

@(private = "file")
glue_player_record :: proc(pos: Vec2, body: Value) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["pos"] = pos
	fields["body"] = body
	return Record_Value{type_name = "Player", fields = fields}
}

@(private = "file")
glue_crate_record :: proc() -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	return Record_Value{type_name = "Crate", fields = fields}
}

@(private = "file")
glue_scoreboard :: proc(delivered: i64) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["delivered"] = delivered
	return Record_Value{type_name = "Scoreboard", fields = fields}
}

@(private = "file")
glue_camera :: proc(at, shake: Vec2) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["at"] = at
	fields["zoom"] = to_fixed(1)
	fields["shake"] = shake
	return Record_Value{type_name = "Camera", fields = fields}
}

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

@(private = "file")
glue_menu_dirty :: proc() -> Value {
	rec := glue_menu_default().(Record_Value)
	rec.fields["dirty"] = true
	return rec
}

@(private = "file")
glue_player_view :: proc(pos: Vec2) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["pos"] = pos
	player := Record_Value{type_name = "Player", fields = fields}
	elements := make([]Value, 1, context.temp_allocator)
	elements[0] = player
	return List_Value{elements = elements}
}

@(private = "file")
glue_empty_view :: proc() -> Value {
	return List_Value{elements = make([]Value, 0, context.temp_allocator)}
}

@(private = "file")
glue_trigger :: proc() -> Value {
	return Record_Value{type_name = "Trigger", fields = make(map[string]Value, context.temp_allocator)}
}

@(private = "file")
glue_delivered :: proc() -> Value {
	return Record_Value{type_name = "Delivered", fields = make(map[string]Value, context.temp_allocator)}
}

@(private = "file")
glue_result_signal :: proc(signal, outcome: string) -> Value {
	payload := new(Value, context.temp_allocator)
	payload^ = Record_Value{type_name = "", fields = make(map[string]Value, context.temp_allocator)}
	result := Variant_Value{enum_type = "Result", case_name = outcome, payload = payload}
	fields := make(map[string]Value, context.temp_allocator)
	fields["result"] = result
	return Record_Value{type_name = signal, fields = fields}
}

@(private = "file")
glue_shape2_box :: proc(size: Vec2) -> Value {
	payload_fields := make(map[string]Value, context.temp_allocator)
	payload_fields["size"] = size
	payload := new(Value, context.temp_allocator)
	payload^ = Record_Value{type_name = "", fields = payload_fields}
	return Variant_Value{enum_type = "Shape2", case_name = "Box", payload = payload}
}

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

@(private = "file")
glue_list :: proc(elements: ..Value) -> Value {
	out := make([]Value, len(elements), context.temp_allocator)
	copy(out, elements)
	return List_Value{elements = out}
}

@(private = "file")
expect_glue_vec2 :: proc(t: ^testing.T, rec: Record_Value, field: string, want: Vec2) {
	v, present := rec.fields[field]
	testing.expect(t, present)
	got, is_vec2 := v.(Vec2)
	testing.expect(t, is_vec2)
	testing.expect_value(t, got.x, want.x)
	testing.expect_value(t, got.y, want.y)
}

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

@(private = "file")
glue_interp :: proc() -> Interp {
	program := Program{}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	committed := new(World_Version, context.temp_allocator)
	committed^ = version
	return new_interp(&program, committed, nil, empty(), glue_time(), context.temp_allocator)
}

@(private = "file")
glue_interp_over :: proc(program: ^Program) -> Interp {
	version := initial_version(new_world(program^, context.temp_allocator), context.temp_allocator)
	committed := new(World_Version, context.temp_allocator)
	committed^ = version
	return new_interp(program, committed, nil, empty(), glue_time(), context.temp_allocator)
}

@(private = "file")
glue_time :: proc() -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
glue_env :: proc() -> Env {
	return Env{names = make(map[string]Value, context.temp_allocator)}
}

@(private = "file")
glue_run_menu :: proc(interp: ^Interp, behavior: ^Behavior_Decl, menu: Value) -> (result: Value, ok: bool) {
	env := glue_env()
	env.names["self"] = menu
	env.names["input"] = input_marker(interp)
	return eval_behavior_body(interp, behavior.body, &env)
}

@(private = "file")
glue_a :: proc() -> Runtime_Allocator {
	return context.temp_allocator
}

@(private = "file")
glue_behavior :: proc(name, on_thing: string, params: []Param_Decl, body: []Node, a := context.allocator) -> Behavior_Decl {
	emits := make([]string, 1, a)
	emits[0] = on_thing
	return Behavior_Decl{name = name, on_thing = on_thing, params = params, emits = emits, body = body}
}

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

@(private = "file")
glue_const_fn :: proc(name: string, value: Node, a := context.allocator) -> Function_Decl {
	body := make([]Node, 1, a)
	body[0] = return_node_h(value, a)
	return Function_Decl{name = name, kind = .Const, body = body}
}

@(private = "file")
name_node :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
field_node_h :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

@(private = "file")
binary_node :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

@(private = "file")
call_node_h :: proc(a: Runtime_Allocator, callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = name_node(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
match_node :: proc(scrutinee: Node, a: Runtime_Allocator, arms_bodies: ..Node) -> Node {
	children := make([]Node, len(arms_bodies) + 1, a)
	children[0] = scrutinee
	for n, i in arms_bodies {
		children[i + 1] = n
	}
	return Node{kind = .Match, children = children}
}

@(private = "file")
Recfield_Spec_H :: struct {
	name:  string,
	value: Node,
}

@(private = "file")
recfield_spec :: proc(name: string, value: Node) -> Recfield_Spec_H {
	return Recfield_Spec_H{name = name, value = value}
}

@(private = "file")
recfield_node_h :: proc(spec: Recfield_Spec_H, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = spec.name
	children := make([]Node, 1, a)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

@(private = "file")
with_node :: proc(base: Node, a: Runtime_Allocator, specs: ..Recfield_Spec_H) -> Node {
	children := make([]Node, len(specs) + 1, a)
	children[0] = base
	for spec, i in specs {
		children[i + 1] = recfield_node_h(spec, a)
	}
	return Node{kind = .With, children = children}
}

@(private = "file")
variant_unit_node :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "false"
	return Node{kind = .Variant, fields = fields}
}

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

@(private = "file")
bare_variant_arm :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = "bare_variant"
	fields[1] = enum_type
	fields[2] = case_name
	return Node{kind = .Arm, fields = fields}
}

@(private = "file")
let_node :: proc(name: string, value: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Let, fields = fields, children = children}
}

@(private = "file")
if_return_node :: proc(guard, value: Node, a := context.allocator) -> Node {
	children := make([]Node, 2, a)
	children[0] = guard
	children[1] = value
	return Node{kind = .If_Return, children = children}
}

@(private = "file")
return_node_h :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}

@(private = "file")
glue_fixed_node :: proc(f: Fixed, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	buf := make([]u8, 24, a)
	fields[0] = strconv.write_int(buf, i64(f), 10)
	return Node{kind = .Fixed, fields = fields}
}

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

@(private = "file")
glue_wildcard_arm :: proc(a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = "wildcard"
	fields[1] = "-"
	fields[2] = "-"
	return Node{kind = .Arm, fields = fields}
}

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

@(private = "file")
glue_apply_impulse_call :: proc(recv, arg: Node) -> Node {
	a := context.temp_allocator
	return glue_method_call(recv, "apply_impulse", a, arg)
}

@(private = "file")
glue_record_node :: proc(type_name: string, a := context.allocator) -> Node {
	fields := make([]string, 2, a)
	fields[0] = type_name
	fields[1] = "0"
	return Node{kind = .Record, fields = fields}
}

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

@(private = "file")
glue_vec2_record :: proc(x, y: Node, a := context.allocator) -> Node {
	return glue_record_node_fields("Vec2", a, recfield_spec("x", x), recfield_spec("y", y))
}

@(private = "file")
vec2_literal :: proc(x, y: Fixed) -> Node {
	a := context.temp_allocator
	return glue_vec2_record(glue_fixed_node(x, a), glue_fixed_node(y, a), a)
}

@(private = "file")
glue_some_string :: proc(text: string, a := context.allocator) -> Node {
	return variant_payload_node("Option", "Some", glue_string_node(text, a), a)
}

@(private = "file")
list_node :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	copy(children, elements)
	return Node{kind = .List, children = children}
}

@(private = "file")
tuple_node :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	copy(children, elements)
	return Node{kind = .Tuple, children = children}
}

@(private = "file")
unary_node :: proc(op: string, operand: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 1, a)
	children[0] = operand
	return Node{kind = .Unary, fields = fields, children = children}
}

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
