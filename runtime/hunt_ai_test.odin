package funpack_runtime

import "core:testing"

@(private = "file")
HUNT_SEARCH_TIME :: 2

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

@(test)
test_hunt_patrol_walks_home_when_unseen :: proc(t: ^testing.T) {
	program := hunt_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := hunt_interp(&program, &version)

	self := hunter_value(Vec2{to_fixed(0), to_fixed(0)}, Vec2{to_fixed(10), to_fixed(0)}, "Patrol")
	after, ok := hunt_call_two(&interp, "patrol", self, none_value())
	testing.expect(t, ok)
	rec := after.(Record_Value)
	expect_hunt_state(t, rec, "Patrol")
	want_x := fixed_add(to_fixed(0), fixed_mul(to_fixed(10), fixed_div(to_fixed(1), to_fixed(10))))
	expect_vec2_field(t, rec, "pos", Vec2{want_x, to_fixed(0)})
}

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
	expect_fixed_field(t, rec, "search_t", to_fixed(HUNT_SEARCH_TIME))
}

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

@(test)
test_hunt_search_gives_up_to_patrol_at_zero :: proc(t: ^testing.T) {
	program := hunt_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := hunt_interp(&program, &version)

	expiring := hunter_with_timer(Vec2{to_fixed(0), to_fixed(0)}, "Search", dt_half())
	gave_up, gu_ok := hunt_call_three(&interp, "search", expiring, none_value(), dt_half())
	testing.expect(t, gu_ok)
	gu_rec := gave_up.(Record_Value)
	expect_hunt_state(t, gu_rec, "Patrol")
	expect_fixed_field(t, gu_rec, "search_t", to_fixed(0))

	searching := hunter_with_timer(Vec2{to_fixed(0), to_fixed(0)}, "Search", to_fixed(2))
	still, s_ok := hunt_call_three(&interp, "search", searching, none_value(), dt_half())
	testing.expect(t, s_ok)
	s_rec := still.(Record_Value)
	expect_hunt_state(t, s_rec, "Search")
	expect_fixed_field(t, s_rec, "search_t", fixed_sub(to_fixed(2), dt_half()))
}

@(test)
test_hunt_think_dispatches_on_current_state :: proc(t: ^testing.T) {
	program := hunt_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := hunt_interp(&program, &version)

	think := program_behavior(&program, "think")
	testing.expect(t, think != nil)

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

@(test)
test_hunt_two_hunter_population_folds_independently :: proc(t: ^testing.T) {
	program := hunt_program()
	world := new_world(program, context.temp_allocator)
	base := run_startup(&program, initial_version(world, context.temp_allocator), context.temp_allocator)

	testing.expect_value(t, view_count(view_of_type(&base, "Player")), 1)
	testing.expect_value(t, view_count(view_of_type(&base, "Hunter")), 2)

	next := step_tick(&program, base, empty(), hunt_time(context.temp_allocator), context.temp_allocator)

	hunters := view_of_type(&next, "Hunter")
	testing.expect_value(t, view_count(hunters), 2)

	near, near_ok := view_at(hunters, 0)
	testing.expect(t, near_ok)
	near_ai, near_present := row_field(near, "ai")
	testing.expect(t, near_present)
	testing.expect_value(t, near_ai.(string), "Hunt::Chase")
	near_seen, seen_present := row_field(near, "last_seen")
	testing.expect(t, seen_present)
	testing.expect_value(t, near_seen.(Vec2).x, to_fixed(10))
	testing.expect_value(t, near_seen.(Vec2).y, to_fixed(0))

	far, far_ok := view_at(hunters, 1)
	testing.expect(t, far_ok)
	far_ai, far_present := row_field(far, "ai")
	testing.expect(t, far_present)
	testing.expect_value(t, far_ai.(string), "Hunt::Patrol")
}

@(private = "file")
expect_hunt_state :: proc(t: ^testing.T, rec: Record_Value, case_name: string) {
	ai, present := rec.fields["ai"]
	testing.expect(t, present)
	variant, is_variant := ai.(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, variant.case_name, case_name)
}

@(private = "file")
expect_vec2_field :: proc(t: ^testing.T, rec: Record_Value, field: string, want: Vec2) {
	v, present := rec.fields[field]
	testing.expect(t, present)
	got, is_vec2 := v.(Vec2)
	testing.expect(t, is_vec2)
	testing.expect_value(t, got.x, want.x)
	testing.expect_value(t, got.y, want.y)
}

@(private = "file")
expect_fixed_field :: proc(t: ^testing.T, rec: Record_Value, field: string, want: Fixed) {
	v, present := rec.fields[field]
	testing.expect(t, present)
	got, is_fixed := v.(Fixed)
	testing.expect(t, is_fixed)
	testing.expect_value(t, got, want)
}

@(private = "file")
dt_half :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(2))
}

@(private = "file")
hunt_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
hunt_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	return new_interp(program, version, nil, empty(), hunt_time(context.temp_allocator), context.temp_allocator)
}

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

@(private = "file")
hunter_with_timer :: proc(pos: Vec2, ai_case: string, search_t: Fixed) -> Value {
	rec := hunter_value(pos, pos, ai_case).(Record_Value)
	rec.fields["search_t"] = search_t
	return rec
}

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

@(private = "file")
hunt_token :: proc(case_name: string) -> string {
	return concat_temp("Hunt::", case_name)
}

@(private = "file")
player_view_list :: proc(interp: ^Interp, pos: Vec2) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["pos"] = pos
	player := Record_Value{type_name = "Player", fields = fields}
	elements := make([]Value, 1, context.temp_allocator)
	elements[0] = player
	return List_Value{elements = elements}
}

@(private = "file")
concat_temp :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}
