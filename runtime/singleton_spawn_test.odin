package funpack_runtime

import "core:fmt"
import "core:testing"

@(private = "file")
yard_singleton_program :: proc(allocator := context.allocator) -> Program {
	settings_fields := make([]Field_Decl, 3, allocator)
	settings_fields[0] = Field_Decl{name = "volume", type = "Int"}
	settings_fields[1] = Field_Decl{name = "fullscreen", type = "Bool"}
	settings_fields[2] = Field_Decl{name = "access", type = "AccessOpts"}
	access_fields := make([]Field_Decl, 1, allocator)
	access_fields[0] = Field_Decl{name = "reduce_motion", type = "Bool"}
	data := make([]Data_Decl, 2, allocator)
	data[0] = Data_Decl{name = "Settings", fields = settings_fields}
	data[1] = Data_Decl{name = "AccessOpts", fields = access_fields}

	scoreboard_fields := make([]Field_Decl, 1, allocator)
	scoreboard_fields[0] = Field_Decl {
		name            = "delivered",
		type            = "Int",
		has_default     = true,
		default_encoded = "0",
	}

	camera_fields := make([]Field_Decl, 3, allocator)
	camera_fields[0] = Field_Decl {
		name            = "at",
		type            = "Vec2",
		has_default     = true,
		default_encoded = fmt.aprintf(
			"Vec2(x=%d,y=%d)",
			i64(to_fixed(80)),
			i64(to_fixed(60)),
			allocator = allocator,
		),
	}
	camera_fields[1] = Field_Decl {
		name            = "zoom",
		type            = "Fixed",
		has_default     = true,
		default_encoded = fmt.aprintf("%d", i64(to_fixed(1)), allocator = allocator),
	}
	camera_fields[2] = Field_Decl {
		name            = "shake",
		type            = "Vec2",
		has_default     = true,
		default_encoded = fmt.aprintf(
			"Vec2(x=%d,y=%d)",
			i64(to_fixed(0)),
			i64(to_fixed(0)),
			allocator = allocator,
		),
	}

	menu_fields := make([]Field_Decl, 3, allocator)
	menu_fields[0] = Field_Decl {
		name            = "settings",
		type            = "Settings",
		has_default     = true,
		default_encoded = "Settings(volume=128,fullscreen=false,access=AccessOpts(reduce_motion=false))",
	}
	menu_fields[1] = Field_Decl {
		name            = "dirty",
		type            = "Bool",
		has_default     = true,
		default_encoded = "false",
	}
	menu_fields[2] = Field_Decl {
		name            = "status",
		type            = "Option",
		has_default     = true,
		default_encoded = "Option::None",
	}

	things := make([]Thing_Decl, 3, allocator)
	things[0] = Thing_Decl{name = "Scoreboard", singleton = true, fields = scoreboard_fields}
	things[1] = Thing_Decl{name = "Camera", singleton = true, fields = camera_fields}
	things[2] = Thing_Decl{name = "Menu", singleton = true, fields = menu_fields}

	program := Program{}
	program.data = data
	program.things = things
	return program
}

@(private = "file")
startup_singletons :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	return run_startup(program, base, allocator)
}

@(test)
test_singletons_spawn_one_row_per_decl :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := yard_singleton_program()
	base := startup_singletons(&program)

	testing.expect_value(t, view_count(view_of_type(&base, "Scoreboard")), 1)
	testing.expect_value(t, view_count(view_of_type(&base, "Camera")), 1)
	testing.expect_value(t, view_count(view_of_type(&base, "Menu")), 1)

	scoreboard, sb_ok := singleton_row(&base, "Scoreboard")
	testing.expect(t, sb_ok)
	delivered, d_present := row_field(scoreboard, "delivered")
	testing.expect(t, d_present)
	testing.expect_value(t, delivered.(i64), i64(0))

	camera, cam_ok := singleton_row(&base, "Camera")
	testing.expect(t, cam_ok)
	at, at_present := row_field(camera, "at")
	zoom, zoom_present := row_field(camera, "zoom")
	shake, shake_present := row_field(camera, "shake")
	testing.expect(t, at_present && zoom_present && shake_present)
	testing.expect_value(t, at.(Vec2), Vec2{to_fixed(80), to_fixed(60)})
	testing.expect_value(t, zoom.(Fixed), to_fixed(1))
	testing.expect_value(t, shake.(Vec2), Vec2{to_fixed(0), to_fixed(0)})

	menu, menu_ok := singleton_row(&base, "Menu")
	testing.expect(t, menu_ok)
	dirty, dirty_present := row_field(menu, "dirty")
	testing.expect(t, dirty_present)
	testing.expect_value(t, dirty.(bool), false)

	status, status_present := row_field(menu, "status")
	testing.expect(t, status_present)
	status_token, is_token := status.(string)
	testing.expect(t, is_token)
	testing.expect_value(t, status_token, "Option::None")
	lifted := field_value_to_value(status)
	variant, is_variant := lifted.(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, variant.enum_type, "Option")
	testing.expect_value(t, variant.case_name, "None")
	testing.expect(t, variant.payload == nil)
}

@(test)
test_singleton_composite_default_decodes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := yard_singleton_program()
	base := startup_singletons(&program)

	menu, menu_ok := singleton_row(&base, "Menu")
	testing.expect(t, menu_ok)
	settings, settings_present := row_field(menu, "settings")
	testing.expect(t, settings_present)
	rec, is_rec := settings.(Record_Value)
	if !testing.expect(t, is_rec) {
		return
	}
	testing.expect_value(t, rec.type_name, "Settings")

	volume, volume_ok := rec.fields["volume"].(i64)
	testing.expect(t, volume_ok)
	testing.expect_value(t, volume, i64(128))

	fullscreen, fs_ok := rec.fields["fullscreen"].(bool)
	testing.expect(t, fs_ok)
	testing.expect_value(t, fullscreen, false)

	access, access_ok := rec.fields["access"].(Record_Value)
	if !testing.expect(t, access_ok) {
		return
	}
	testing.expect_value(t, access.type_name, "AccessOpts")
	reduce_motion, rm_ok := access.fields["reduce_motion"].(bool)
	testing.expect(t, rm_ok)
	testing.expect_value(t, reduce_motion, false)
}

@(test)
test_singleton_spawn_is_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := yard_singleton_program()

	first := startup_singletons(&program)
	second := startup_singletons(&program)

	testing.expect(t, world_versions_equal(first, second))

	for thing in ([]string{"Scoreboard", "Camera", "Menu"}) {
		row_first, ok_first := singleton_row(&first, thing)
		row_second, ok_second := singleton_row(&second, thing)
		testing.expect(t, ok_first && ok_second)
		testing.expect_value(t, row_first.id, Id{raw = Thing_Id(0)})
		testing.expect_value(t, row_second.id, row_first.id)
	}
}

@(test)
test_non_singleton_not_engine_spawned :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fields := make([]Field_Decl, 1, context.temp_allocator)
	fields[0] = Field_Decl{name = "score", type = "Int", has_default = true, default_encoded = "0"}
	things := make([]Thing_Decl, 1, context.temp_allocator)
	things[0] = Thing_Decl{name = "Scoreboard", singleton = false, fields = fields}
	program := Program{}
	program.things = things

	base := startup_singletons(&program)

	testing.expect_value(t, view_count(view_of_type(&base, "Scoreboard")), 0)
}
