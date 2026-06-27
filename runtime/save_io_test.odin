package funpack_runtime

import "core:fmt"
import "core:testing"

@(private = "file")
p_aprintf :: proc(a: Runtime_Allocator, format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args, allocator = a)
}

@(private = "file")
SAVE_BTN :: ActionId(0)
@(private = "file")
RESTORE_BTN :: ActionId(1)
@(private = "file")
APPLY_BTN :: ActionId(2)

@(private = "file")
STEER :: ActionId(3)

@(private = "file")
PERSIST_SLOT :: "quicksave"

@(test)
test_save_snapshot_round_trips_committed_version :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	committed := persist_startup(&program)

	bytes := serialize_snapshot(&program, committed)
	restored, _, _, ok := deserialize_snapshot(bytes)
	if !testing.expect(t, ok) {
		return
	}

	testing.expect(t, world_versions_equal(committed, restored))

	saved_digest := frame_digest(committed, nil)
	restored_digest := frame_digest(restored, nil)
	testing.expect_value(t, restored_digest.digest, saved_digest.digest)
}

@(test)
test_snapshot_codec_is_a_fixed_point :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	committed := persist_startup(&program)

	first := serialize_snapshot(&program, committed)
	restored, _, _, ok := deserialize_snapshot(first)
	if !testing.expect(t, ok) {
		return
	}
	second := serialize_snapshot(&program, restored)

	testing.expect_value(t, len(second), len(first))
	for b, i in first {
		if i < len(second) {
			testing.expect_value(t, second[i], b)
		}
	}
}

@(test)
test_save_snapshot_round_trips_nested_payload_variant :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	size_fields := make(map[string]Value)
	size_fields["size"] = Vec2{to_fixed(160), to_fixed(4)}
	shape_payload := new(Value)
	shape_payload^ = Record_Value{type_name = "", fields = size_fields}

	mask := make([]Value, 2)
	mask[0] = Variant_Value{enum_type = "Layer", case_name = "Player"}
	mask[1] = Variant_Value{enum_type = "Layer", case_name = "Crate"}

	body_fields := make(map[string]Value)
	body_fields["kind"] = Variant_Value{enum_type = "BodyKind", case_name = "Static"}
	body_fields["shape"] = Variant_Value{enum_type = "Shape2", case_name = "Box", payload = shape_payload}
	body_fields["mask"] = List_Value{elements = mask}

	status_payload := new(Value)
	status_payload^ = String_Value{text = "saved"}

	row_fields := make(map[string]Field_Value)
	row_fields["pos"] = Vec2{to_fixed(80), to_fixed(2)}
	row_fields["body"] = Record_Value{type_name = "Body", fields = body_fields}
	row_fields["status"] = Variant_Value{enum_type = "Option", case_name = "Some", payload = status_payload}
	row_fields["note"] = String_Value{text = "quicksave row"}

	rows := make([]Row, 1)
	rows[0] = Row{id = Id{raw = 1}, fields = row_fields}
	tables := make([]Version_Table, 1)
	tables[0] = Version_Table{thing = "Wall", singleton = false, rows = rows, next_id = 2}
	committed := World_Version{tick = 7, tables = tables}

	bare_program := Program{}
	bytes := serialize_snapshot(&bare_program, committed)
	restored, _, _, ok := deserialize_snapshot(bytes)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect(t, world_versions_equal(committed, restored))

	restored_body := restored.tables[0].rows[0].fields["body"].(Record_Value)
	restored_shape := restored_body.fields["shape"].(Variant_Value)
	if !testing.expect(t, restored_shape.payload != nil) {
		return
	}
	payload_rec := restored_shape.payload^.(Record_Value)
	testing.expect_value(t, payload_rec.fields["size"].(Vec2), Vec2{to_fixed(160), to_fixed(4)})

	restored_status := restored.tables[0].rows[0].fields["status"].(Variant_Value)
	if !testing.expect(t, restored_status.payload != nil) {
		return
	}
	testing.expect_value(t, restored_status.payload^.(String_Value).text, "saved")
	testing.expect_value(t, restored.tables[0].rows[0].fields["note"].(String_Value).text, "quicksave row")
}

@(test)
test_commit_lowering_preserves_payload_and_string :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	payload := new(Value)
	payload^ = String_Value{text = "saved"}
	some := Variant_Value{enum_type = "Option", case_name = "Some", payload = payload}

	fv, ok := value_to_field_value(some)
	testing.expect(t, ok)
	committed, is_variant := fv.(Variant_Value)
	if !testing.expect(t, is_variant) {
		return
	}
	testing.expect_value(t, committed.payload^.(String_Value).text, "saved")

	unit_fv, unit_ok := value_to_field_value(Variant_Value{enum_type = "Side", case_name = "Left"})
	testing.expect(t, unit_ok)
	testing.expect_value(t, unit_fv.(string), "Side::Left")

	str_fv, str_ok := value_to_field_value(String_Value{text = "note"})
	testing.expect(t, str_ok)
	testing.expect_value(t, str_fv.(String_Value).text, "note")

	testing.expect(t, values_equal(field_value_to_value(fv), some))
}

@(test)
test_save_emits_saved_outcome_next_tick :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store()
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	save_input := with_pressed(empty(), .P1, SAVE_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, save_input, time, carrier)
	testing.expect_value(t, menu_status(&v0), "")

	snapshot, slot_ok := store_read_slot(&store, PERSIST_SLOT)
	testing.expect(t, slot_ok)
	testing.expect(t, len(snapshot.bytes) > 0)

	v1: World_Version
	v1, carrier = step_tick_persist(&program, v0, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v1), "Saved")
}

@(test)
test_restore_swaps_world_and_signals_next_tick :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store()
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	t0_input := with_pressed(with_value(empty(), .P1, STEER, to_fixed(1)), .P1, SAVE_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, t0_input, time, carrier)
	saved_pos := player_pos(&v0)

	cur := v0
	for _ in 0 ..< 3 {
		steer := with_value(empty(), .P1, STEER, to_fixed(1))
		cur, carrier = step_tick_persist(&program, cur, steer, time, carrier)
	}
	advanced_pos := player_pos(&cur)
	testing.expect(t, advanced_pos.x != saved_pos.x)

	restore_input := with_pressed(empty(), .P1, RESTORE_BTN)
	v4: World_Version
	v4, carrier = step_tick_persist(&program, cur, restore_input, time, carrier)

	v5: World_Version
	v5, carrier = step_tick_persist(&program, v4, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v5), "Restored")
	testing.expect_value(t, player_pos(&v5).x, saved_pos.x)
}

@(test)
test_apply_settings_persists_and_signals_next_tick :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store()
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	apply_input := with_pressed(empty(), .P1, APPLY_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, apply_input, time, carrier)

	_, settings_ok := store_read_settings(&store)
	testing.expect(t, settings_ok)

	v1: World_Version
	v1, carrier = step_tick_persist(&program, v0, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v1), "SettingsApplied")
}

@(test)
test_forced_io_error_yields_err_outcome :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_on_disk_store("/proc/nonexistent-funpack-save-dir/\x00bad")
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	save_input := with_pressed(empty(), .P1, SAVE_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, save_input, time, carrier)

	v1: World_Version
	v1, carrier = step_tick_persist(&program, v0, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v1), "SaveFailed")
}

@(test)
test_restore_missing_slot_yields_err :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store()
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	restore_input := with_pressed(empty(), .P1, RESTORE_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, restore_input, time, carrier)
	v1: World_Version
	v1, carrier = step_tick_persist(&program, v0, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v1), "RestoreFailed")
}

@(test)
test_restore_rejects_content_hash_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store()
	committed := persist_startup(&program)

	testing.expect(t, apply_save(&store, &program, committed, PERSIST_SLOT))
	snapshot, read_ok := store_read_slot(&store, PERSIST_SLOT)
	testing.expect(t, read_ok)
	snapshot.content_hash = snapshot.content_hash ~ 0xDEAD_BEEF
	store_write_slot(&store, PERSIST_SLOT, snapshot)

	_, restore_ok := apply_restore(&store, &program, PERSIST_SLOT)
	testing.expect(t, !restore_ok)
}

@(test)
test_replay_log_carries_no_persist_entry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program := persist_program()
	identity := identity_from_program(program, "persist-fixture-bytes")
	writer := open_replay_writer(identity)
	defer delete_replay_writer(&writer)
	record_tick(&writer, with_pressed(empty(), .P1, SAVE_BTN))
	record_tick(&writer, empty())
	log_bytes := finish_replay(&writer)

	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	testing.expect_value(t, len(log.snapshots), 2)
	testing.expect(t, pressed(log.snapshots[0], .P1, SAVE_BTN))
}

@(test)
test_refold_across_restore_is_bit_identical :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	inputs := persist_restore_session()

	live := persist_capture(&program, inputs)
	refold := persist_capture(&program, inputs)

	if !testing.expect_value(t, len(refold), len(live)) {
		return
	}
	for frame, i in live {
		testing.expect_value(t, refold[i].tick, frame.tick)
		testing.expect_value(t, refold[i].digest, frame.digest)
	}

	steered := persist_capture(&program, persist_steer_only_session())
	if !testing.expect_value(t, len(steered), len(live)) {
		return
	}
	testing.expect(t, live[5].digest != steered[5].digest)
}

@(private = "file")
persist_steer_only_session :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, 8, allocator)
	for i in 0 ..< 8 {
		inputs[i] = with_value(empty(), .P1, STEER, to_fixed(1))
	}
	return inputs
}

@(private = "file")
persist_restore_session :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, 8, allocator)
	inputs[0] = with_value(empty(), .P1, STEER, to_fixed(1))
	inputs[1] = with_pressed(with_value(empty(), .P1, STEER, to_fixed(1)), .P1, SAVE_BTN)
	inputs[2] = with_value(empty(), .P1, STEER, to_fixed(1))
	inputs[3] = with_value(empty(), .P1, STEER, to_fixed(1))
	inputs[4] = with_pressed(empty(), .P1, RESTORE_BTN)
	inputs[5] = empty()
	inputs[6] = empty()
	inputs[7] = empty()
	return inputs
}

@(private = "file")
persist_capture :: proc(program: ^Program, inputs: []Input, allocator := context.allocator) -> []Frame_Digest {
	store := new_in_memory_store(allocator)
	committed := persist_startup(program, allocator)
	carrier := new_persist_carrier(&store)
	time := persist_time(60, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	cur := committed
	for input in inputs {
		cur, carrier = step_tick_persist(program, cur, input, time, carrier, allocator)
		append(&per_tick, capture_frame(cur, nil, allocator))
	}
	return per_tick[:]
}

@(private = "file")
persist_program :: proc(allocator := context.allocator) -> Program {
	a := allocator

	enums := make([]Enum_Decl, 2, a)
	enums[0] = Enum_Decl{name = "Cmd", kind = .Button, variants = persist_cmd_variants(a)}
	enums[1] = Enum_Decl{name = "Drive", kind = .Axis, variants = persist_axis_variants(a)}

	player_fields := make([]Field_Decl, 1, a)
	player_fields[0] = Field_Decl {
		name            = "pos",
		type            = "Vec2",
		has_default     = true,
		default_encoded = pos_default(a),
	}

	menu_fields := make([]Field_Decl, 1, a)
	menu_fields[0] = Field_Decl {
		name            = "status",
		type            = "Option",
		has_default     = true,
		default_encoded = "Option::None",
	}

	things := make([]Thing_Decl, 2, a)
	things[0] = Thing_Decl{name = "Player", singleton = true, fields = player_fields}
	things[1] = Thing_Decl{name = "Menu", singleton = true, fields = menu_fields}

	behaviors := make([]Behavior_Decl, 6, a)
	behaviors[0] = persist_player_step_behavior(a)
	behaviors[1] = persist_save_key_behavior(a)
	behaviors[2] = persist_restore_key_behavior(a)
	behaviors[3] = persist_apply_settings_behavior(a)
	behaviors[4] = persist_on_persist_result_behavior(a)
	behaviors[5] = persist_on_settings_applied_behavior(a)

	pipeline := make([]Pipeline_Step, 6, a)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "control", behavior = "player_step"}
	pipeline[1] = Pipeline_Step{ordinal = 1, stage = "control", behavior = "save_key"}
	pipeline[2] = Pipeline_Step{ordinal = 2, stage = "control", behavior = "restore_key"}
	pipeline[3] = Pipeline_Step{ordinal = 3, stage = "control", behavior = "apply_settings"}
	pipeline[4] = Pipeline_Step{ordinal = 4, stage = "scoring", behavior = "on_persist_result"}
	pipeline[5] = Pipeline_Step{ordinal = 5, stage = "scoring", behavior = "on_settings_applied"}

	program := Program{}
	program.enums = enums
	program.things = things
	program.behaviors = behaviors
	program.pipeline = pipeline
	program.entrypoint = Entrypoint{tick_hz = 60, logical_w = 160, logical_h = 120}
	return program
}

@(private = "file")
persist_startup :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	return run_startup(program, initial_version(world, allocator), allocator)
}

@(private = "file")
persist_time :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
pos_default :: proc(a := context.allocator) -> string {
	return p_aprintf(a, "Vec2(x=%d,y=%d)", i64(to_fixed(0)), i64(to_fixed(0)))
}

@(private = "file")
persist_cmd_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 3, a)
	v[0] = Enum_Variant{name = "Save", payload = "unit"}
	v[1] = Enum_Variant{name = "Restore", payload = "unit"}
	v[2] = Enum_Variant{name = "Apply", payload = "unit"}
	return v
}

@(private = "file")
persist_axis_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 1, a)
	v[0] = Enum_Variant{name = "Step", payload = "unit"}
	return v
}

@(private = "file")
persist_player_step_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 1, a)
	axis := p_method_call(p_name("input", a), "axis", a, p_variant_unit("PlayerId", "P1", a), p_variant_unit("Drive", "Step", a))
	advanced := p_binary("add", p_field(p_name("self", a), "pos", a), axis, a)
	body[0] = p_return(p_with(p_name("self", a), a, p_recfield("pos", advanced)), a)
	return p_behavior("player_step", "Player", "control", p_two_params("self", "Player", "input", "Input", a), p_emit_self("Player", a), body, a)
}

@(private = "file")
persist_save_key_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	return persist_command_key_behavior("save_key", "Save", "Save", a)
}

@(private = "file")
persist_restore_key_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	return persist_command_key_behavior("restore_key", "Restore", "Restore", a)
}

@(private = "file")
persist_command_key_behavior :: proc(name, button, command: string, a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	pressed := p_method_call(p_name("input", a), "pressed", a, p_variant_unit("PlayerId", "P1", a), p_variant_unit("Cmd", button, a))
	cmd := p_record_fields(command, a, p_recfield("slot", p_string(PERSIST_SLOT, a)))
	body[0] = p_if_return(pressed, p_list(a, cmd), a)
	body[1] = p_return(p_list(a), a)
	emit := make([]string, 1, a)
	emit[0] = p_aprintf(a, "[%s]", command)
	return Behavior_Decl{name = name, on_thing = "Menu", stage = "control", params = p_two_params("self", "Menu", "input", "Input", a), emits = emit, body = body}
}

@(private = "file")
persist_apply_settings_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	pressed := p_method_call(p_name("input", a), "pressed", a, p_variant_unit("PlayerId", "P1", a), p_variant_unit("Cmd", "Apply", a))
	settings := p_record_fields("Settings", a, p_recfield("volume", p_int(1, a)))
	cmd := p_record_fields("ApplySettings", a, p_recfield("settings", settings))
	body[0] = p_if_return(pressed, p_list(a, cmd), a)
	body[1] = p_return(p_list(a), a)
	emit := make([]string, 1, a)
	emit[0] = "[ApplySettings]"
	return Behavior_Decl{name = "apply_settings", on_thing = "Menu", stage = "control", params = p_two_params("self", "Menu", "input", "Input", a), emits = emit, body = body}
}

@(private = "file")
persist_on_persist_result_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	body[0] = p_let("after_save", p_call(a, "fold", p_name("saved", a), p_name("self", a), persist_result_lambda("Saved", "SaveFailed", a)), a)
	body[1] = p_return(p_call(a, "fold", p_name("restored", a), p_name("after_save", a), persist_result_lambda("Restored", "RestoreFailed", a)), a)
	params := make([]Param_Decl, 3, a)
	params[0] = Param_Decl{name = "self", type = "Menu"}
	params[1] = Param_Decl{name = "saved", type = "[Saved]"}
	params[2] = Param_Decl{name = "restored", type = "[Restored]"}
	return Behavior_Decl{name = "on_persist_result", on_thing = "Menu", stage = "scoring", params = params, emits = p_emit_self("Menu", a), body = body}
}

@(private = "file")
persist_on_settings_applied_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 1, a)
	body[0] = p_return(p_call(a, "fold", p_name("applied", a), p_name("self", a), persist_result_lambda("SettingsApplied", "SettingsSaveFailed", a)), a)
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "self", type = "Menu"}
	params[1] = Param_Decl{name = "applied", type = "[SettingsApplied]"}
	return Behavior_Decl{name = "on_settings_applied", on_thing = "Menu", stage = "scoring", params = params, emits = p_emit_self("Menu", a), body = body}
}

@(private = "file")
persist_result_lambda :: proc(ok_case, err_case: string, a := context.allocator) -> Node {
	ok_arm := p_variant_binds_arm("Result", "Ok", "_", a)
	ok_body := p_with(p_name("m", a), a, p_recfield("status", p_variant_unit("Status", ok_case, a)))
	err_arm := p_variant_binds_arm("Result", "Err", "_", a)
	err_body := p_with(p_name("m", a), a, p_recfield("status", p_variant_unit("Status", err_case, a)))
	match := p_match(p_field(p_name("r", a), "result", a), a, ok_arm, ok_body, err_arm, err_body)
	return p_lambda(a, match, "m", "r")
}

@(private = "file")
menu_status :: proc(version: ^World_Version) -> string {
	menu, ok := singleton_row(version, "Menu")
	if !ok {
		return ""
	}
	status, present := menu.fields["status"]
	if !present {
		return ""
	}
	lifted := field_value_to_value(status)
	variant, is_variant := lifted.(Variant_Value)
	if !is_variant || variant.enum_type != "Status" {
		return ""
	}
	return variant.case_name
}

@(private = "file")
player_pos :: proc(version: ^World_Version) -> Vec2 {
	player, ok := singleton_row(version, "Player")
	if !ok {
		return VEC2_ZERO
	}
	pos, present := player.fields["pos"]
	if !present {
		return VEC2_ZERO
	}
	if v, is_vec2 := pos.(Vec2); is_vec2 {
		return v
	}
	return VEC2_ZERO
}

@(private = "file")
p_name :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
p_field :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

@(private = "file")
p_binary :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

@(private = "file")
p_call :: proc(a: Runtime_Allocator, callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = p_name(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
p_method_call :: proc(recv: Node, method: string, a: Runtime_Allocator, args: ..Node) -> Node {
	field := p_field(recv, method, a)
	children := make([]Node, len(args) + 1, a)
	children[0] = field
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
p_match :: proc(scrutinee: Node, a: Runtime_Allocator, arms_bodies: ..Node) -> Node {
	children := make([]Node, len(arms_bodies) + 1, a)
	children[0] = scrutinee
	for n, i in arms_bodies {
		children[i + 1] = n
	}
	return Node{kind = .Match, children = children}
}

@(private = "file")
P_Recfield :: struct {
	name:  string,
	value: Node,
}

@(private = "file")
p_recfield :: proc(name: string, value: Node) -> P_Recfield {
	return P_Recfield{name = name, value = value}
}

@(private = "file")
p_recfield_node :: proc(spec: P_Recfield, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = spec.name
	children := make([]Node, 1, a)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

@(private = "file")
p_with :: proc(base: Node, a: Runtime_Allocator, specs: ..P_Recfield) -> Node {
	children := make([]Node, len(specs) + 1, a)
	children[0] = base
	for spec, i in specs {
		children[i + 1] = p_recfield_node(spec, a)
	}
	return Node{kind = .With, children = children}
}

@(private = "file")
p_variant_unit :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "false"
	return Node{kind = .Variant, fields = fields}
}

@(private = "file")
p_variant_payload :: proc(enum_type, case_name: string, payload: Node, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "true"
	children := make([]Node, 1, a)
	children[0] = payload
	return Node{kind = .Variant, fields = fields, children = children}
}

@(private = "file")
p_variant_binds_arm :: proc(enum_type, case_name, binder: string, a := context.allocator) -> Node {
	fields := make([]string, 5, a)
	fields[0] = "variant_binds"
	fields[1] = enum_type
	fields[2] = case_name
	fields[3] = "1"
	fields[4] = binder
	return Node{kind = .Arm, fields = fields}
}

@(private = "file")
p_let :: proc(name: string, value: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Let, fields = fields, children = children}
}

@(private = "file")
p_if_return :: proc(guard, value: Node, a := context.allocator) -> Node {
	children := make([]Node, 2, a)
	children[0] = guard
	children[1] = value
	return Node{kind = .If_Return, children = children}
}

@(private = "file")
p_return :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}

@(private = "file")
p_int :: proc(n: i64, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = p_aprintf(a, "%d", n)
	return Node{kind = .Int, fields = fields}
}

@(private = "file")
p_string :: proc(s: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = p_aprintf(a, "L%d:%s", i64(len(s)), s)
	return Node{kind = .String, fields = fields}
}

@(private = "file")
p_some_string :: proc(text: string, a := context.allocator) -> Node {
	return p_variant_payload("Option", "Some", p_string(text, a), a)
}

@(private = "file")
p_record_fields :: proc(type_name: string, a: Runtime_Allocator, specs: ..P_Recfield) -> Node {
	fields := make([]string, 2, a)
	fields[0] = type_name
	fields[1] = p_aprintf(a, "%d", i64(len(specs)))
	children := make([]Node, len(specs), a)
	for spec, i in specs {
		children[i] = p_recfield_node(spec, a)
	}
	return Node{kind = .Record, fields = fields, children = children}
}

@(private = "file")
p_list :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	copy(children, elements)
	return Node{kind = .List, children = children}
}

@(private = "file")
p_lambda :: proc(a: Runtime_Allocator, body: Node, params: ..string) -> Node {
	fields := make([]string, len(params) + 1, a)
	fields[0] = p_aprintf(a, "%d", i64(len(params)))
	for p, i in params {
		fields[i + 1] = p
	}
	children := make([]Node, 1, a)
	children[0] = body
	return Node{kind = .Lambda, fields = fields, children = children}
}

@(private = "file")
p_two_params :: proc(n0, t0, n1, t1: string, a := context.allocator) -> []Param_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = n0, type = t0}
	params[1] = Param_Decl{name = n1, type = t1}
	return params
}

@(private = "file")
p_emit_self :: proc(on_thing: string, a := context.allocator) -> []string {
	emit := make([]string, 1, a)
	emit[0] = on_thing
	return emit
}

@(private = "file")
p_behavior :: proc(name, on_thing, stage: string, params: []Param_Decl, emits: []string, body: []Node, a := context.allocator) -> Behavior_Decl {
	return Behavior_Decl{name = name, on_thing = on_thing, stage = stage, params = params, emits = emits, body = body}
}

@(private = "file")
sr_layer :: proc(
	name: string,
	cols, rows: int,
	palette: []Tile_Def,
	cells: []int,
	allocator := context.allocator,
) -> Tile_Layer {
	pal := make([]Tile_Def, len(palette), allocator)
	copy(pal, palette)
	cs := make([]int, len(cells), allocator)
	copy(cs, cells)
	return Tile_Layer {
		name = name,
		cell_size = 16,
		cols = cols,
		rows = rows,
		top_left = Vec2{x = to_fixed(0), y = to_fixed(i64(rows) * 16)},
		palette = pal,
		cells = cs,
	}
}

@(test)
test_save_restore_tile :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := context.temp_allocator

	wall_floor := []Tile_Def{{name = "wall", solid = true}, {name = "floor", solid = false}}

	{
		saving_bake := make([]Tile_Layer, 1, a)
		saving_bake[0] = sr_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = sr_layer("terrain", 3, 1, wall_floor, []int{0, 1, 0}, a)

		program := Program {
			tilemaps = saving_bake,
		}
		committed := World_Version {
			tick     = 7,
			tilemaps = live,
		}

		bytes := serialize_snapshot(&program, committed)
		_, _, delta, ok := deserialize_snapshot(bytes)
		if !testing.expect(t, ok) {
			return
		}
		testing.expect_value(t, len(delta.edits), 1)
		testing.expect_value(t, delta.edits[0].layer_name, "terrain")
		testing.expect_value(t, delta.edits[0].col, 1)
		testing.expect_value(t, delta.edits[0].row, 0)
		testing.expect_value(t, delta.edits[0].tile_name, "floor")

		restoring_bake := make([]Tile_Layer, 1, a)
		restoring_bake[0] = sr_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)
		carried := tile_carry_apply(delta, restoring_bake, a)
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect(t, layer != nil)
		testing.expect_value(t, tilemap_solid_at(layer, 1, 0), false)
		name, has := tilemap_tile_at(layer, 1, 0)
		testing.expect(t, has)
		testing.expect_value(t, name, "floor")
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), true)
		testing.expect_value(t, tilemap_solid_at(layer, 2, 0), true)
	}

	{
		bake := make([]Tile_Layer, 1, a)
		bake[0] = sr_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = sr_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)

		program := Program {
			tilemaps = bake,
		}
		committed := World_Version {
			tick     = 3,
			tilemaps = live,
		}

		first := serialize_snapshot(&program, committed)
		_, _, delta, ok := deserialize_snapshot(first)
		if !testing.expect(t, ok) {
			return
		}
		testing.expect_value(t, len(delta.edits), 0)

		second := serialize_snapshot(&program, deserialize_world(first, a))
		testing.expect_value(t, len(second), len(first))
		for b, i in first {
			if i < len(second) {
				testing.expect_value(t, second[i], b)
			}
		}

		restoring_bake := make([]Tile_Layer, 1, a)
		restoring_bake[0] = sr_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)
		carried := tile_carry_apply(delta, restoring_bake, a)
		testing.expect(t, raw_data(carried) == raw_data(restoring_bake))
	}

	{
		saving_bake := make([]Tile_Layer, 2, a)
		saving_bake[0] = sr_layer("terrain", 2, 2, wall_floor, []int{0, 0, 0, 0}, a)
		saving_bake[1] = sr_layer("decor", 2, 1, wall_floor, []int{0, 0}, a)
		live := make([]Tile_Layer, 2, a)
		live[0] = sr_layer("terrain", 2, 2, wall_floor, []int{0, 1, 1, 1}, a)
		live[1] = sr_layer("decor", 2, 1, wall_floor, []int{0, 0}, a)

		program := Program {
			tilemaps = saving_bake,
		}
		committed := World_Version {
			tick     = 11,
			tilemaps = live,
		}

		bytes := serialize_snapshot(&program, committed)
		_, _, delta, ok := deserialize_snapshot(bytes)
		if !testing.expect(t, ok) {
			return
		}
		testing.expect_value(t, len(delta.edits), 3)

		restoring_bake := make([]Tile_Layer, 2, a)
		restoring_bake[0] = sr_layer("terrain", 1, 2, wall_floor, []int{0, 0}, a)
		restoring_bake[1] = sr_layer("decor", 2, 1, wall_floor, []int{0, 0}, a)
		carried := tile_carry_apply(delta, restoring_bake, a)

		terrain := find_tile_layer(carried, "terrain")
		testing.expect(t, terrain != nil)
		testing.expect_value(t, tilemap_solid_at(terrain, 0, 0), true)
		testing.expect_value(t, tilemap_solid_at(terrain, 0, 1), false)

		decor_idx := -1
		for layer, i in carried {
			if layer.name == "decor" {
				decor_idx = i
				break
			}
		}
		testing.expect(t, decor_idx >= 0)
		testing.expect(t, raw_data(carried[decor_idx].cells) == raw_data(restoring_bake[decor_idx].cells))
	}
}

@(private = "file")
deserialize_world :: proc(bytes: []u8, allocator := context.allocator) -> World_Version {
	world, _, _, _ := deserialize_snapshot(bytes, allocator)
	return world
}
