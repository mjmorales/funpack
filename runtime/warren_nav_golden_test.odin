package funpack_runtime

import "core:testing"

WARREN_ARTIFACT := #load("testdata/warren.artifact", string)

warren_doe :: proc() -> Vec2 {
	return Vec2{x = to_fixed(12), y = to_fixed(84)}
}
warren_den :: proc() -> Vec2 {
	return Vec2{x = to_fixed(116), y = to_fixed(84)}
}
warren_sealed :: proc() -> Vec2 {
	return Vec2{x = to_fixed(28), y = to_fixed(20)}
}
warren_hob :: proc() -> Vec2 {
	return Vec2{x = to_fixed(116), y = to_fixed(20)}
}

warren_nav_world :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(WARREN_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "warren golden artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

warren_eval_nav :: proc(program: ^Program, method: string, args: ..Value) -> (result: Value, ok: bool) {
	version := World_Version {
		tilemaps = program.tilemaps,
	}
	interp := new_interp(program, &version, nil, empty(), tilemap_time_resource(), context.temp_allocator)
	return nav_eval_method(&interp, nav_handle_value("maze"), method, ..args)
}

@(test)
test_warren_golden_graph_decodes_exact :: proc(t: ^testing.T) {
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.navs), 1)
	testing.expect_value(t, program.navs[0].name, "maze")
	testing.expect_value(t, len(program.navs[0].centers), 80)
	degree := 0
	for neighbors in program.navs[0].adj {
		degree += len(neighbors)
	}
	testing.expect_value(t, degree, 160)
	testing.expect_value(t, program.navs[0].centers[0], warren_doe())
}

@(test)
test_warren_golden_path_unique_route_exact :: proc(t: ^testing.T) {
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	result, eval_ok := warren_eval_nav(&program, "path", warren_den(), Vec2{x = to_fixed(116), y = to_fixed(68)})
	testing.expect(t, eval_ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Ok")
	route := variant.payload^.(Record_Value)
	steps := route.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), 3)
	testing.expect_value(t, steps.elements[0].(Vec2), warren_den())
	testing.expect_value(t, steps.elements[1].(Vec2), Vec2{x = to_fixed(116), y = to_fixed(76)})
	testing.expect_value(t, steps.elements[2].(Vec2), Vec2{x = to_fixed(116), y = to_fixed(68)})
	testing.expect_value(t, route.fields["cost"].(Fixed), to_fixed(16))
}

@(test)
test_warren_golden_chase_route_exact_length :: proc(t: ^testing.T) {
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	result, eval_ok := warren_eval_nav(&program, "path", warren_hob(), warren_doe())
	testing.expect(t, eval_ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Ok")
	route := variant.payload^.(Record_Value)
	steps := route.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), 28)
	testing.expect_value(t, steps.elements[0].(Vec2), warren_hob())
	testing.expect_value(t, steps.elements[27].(Vec2), warren_doe())
	testing.expect_value(t, route.fields["cost"].(Fixed), to_fixed(216))
}

@(test)
test_warren_golden_sealed_burrow_unreachable :: proc(t: ^testing.T) {
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	result, eval_ok := warren_eval_nav(&program, "path", warren_doe(), warren_sealed())
	testing.expect(t, eval_ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Err")
	testing.expect_value(t, variant.payload^.(Variant_Value).case_name, "Unreachable")
	reach, reach_ok := warren_eval_nav(&program, "reachable", warren_doe(), warren_sealed())
	testing.expect(t, reach_ok)
	testing.expect_value(t, reach.(bool), false)
	open, open_ok := warren_eval_nav(&program, "reachable", warren_doe(), warren_hob())
	testing.expect(t, open_ok)
	testing.expect_value(t, open.(bool), true)
}

@(test)
test_warren_golden_offnav_and_containing_cell :: proc(t: ^testing.T) {
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	walled, walled_ok := warren_eval_nav(&program, "path", Vec2{x = to_fixed(4), y = to_fixed(92)}, warren_doe())
	testing.expect(t, walled_ok)
	variant := walled.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Err")
	testing.expect_value(t, variant.payload^.(Variant_Value).case_name, "OffNav")
	off_center, oc_ok := warren_eval_nav(&program, "path", Vec2{x = to_fixed(114), y = to_fixed(86)}, Vec2{x = to_fixed(116), y = to_fixed(68)})
	testing.expect(t, oc_ok)
	resolved := off_center.(Variant_Value)
	testing.expect_value(t, resolved.case_name, "Ok")
	route := resolved.payload^.(Record_Value)
	steps := route.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), 3)
	testing.expect_value(t, steps.elements[0].(Vec2), warren_den())
	testing.expect_value(t, route.fields["cost"].(Fixed), to_fixed(16))
}

@(test)
test_warren_golden_startup_spawns_carried_schema :: proc(t: ^testing.T) {
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator), context.temp_allocator)

	rabbits := version_find_table(&version, "Rabbit")
	ferrets := version_find_table(&version, "Ferret")
	burrows := version_find_table(&version, "Burrow")
	if !testing.expect(t, rabbits != nil && ferrets != nil && burrows != nil) {
		return
	}
	testing.expect_value(t, len(rabbits.rows), 1)
	testing.expect_value(t, len(ferrets.rows), 1)
	testing.expect_value(t, len(burrows.rows), 2)

	doe := rabbits.rows[0]
	testing.expect_value(t, doe.fields["pos"].(Vec2), warren_doe())
	testing.expect_value(t, doe.fields["hidden"].(bool), false)
	doe_path, doe_path_is_record := doe.fields["path"].(Record_Value)
	testing.expect(t, doe_path_is_record)
	if doe_path_is_record {
		testing.expect_value(t, doe_path.type_name, "Path")
		steps, steps_is_list := doe_path.fields["steps"].(List_Value)
		testing.expect(t, steps_is_list)
		testing.expect_value(t, len(steps.elements), 0)
		testing.expect_value(t, doe_path.fields["cost"].(Fixed), Fixed(0))
	}

	hob := ferrets.rows[0]
	testing.expect_value(t, hob.fields["pos"].(Vec2), warren_hob())
	testing.expect_value(t, hob.fields["repath_t"].(Fixed), Fixed(0))
	hob_path, hob_path_is_record := hob.fields["path"].(Record_Value)
	testing.expect(t, hob_path_is_record)
	if hob_path_is_record {
		testing.expect_value(t, hob_path.type_name, "Path")
	}

	testing.expect_value(t, burrows.rows[0].fields["pos"].(Vec2), warren_den())
	testing.expect_value(t, burrows.rows[1].fields["pos"].(Vec2), warren_sealed())
}

@(test)
test_warren_golden_los_over_the_baked_maze :: proc(t: ^testing.T) {
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	clear, clear_ok := warren_eval_nav(&program, "los", warren_doe(), Vec2{x = to_fixed(44), y = to_fixed(84)})
	testing.expect(t, clear_ok)
	testing.expect_value(t, clear.(bool), true)
	blocked, blocked_ok := warren_eval_nav(&program, "los", warren_doe(), warren_den())
	testing.expect(t, blocked_ok)
	testing.expect_value(t, blocked.(bool), false)
}
