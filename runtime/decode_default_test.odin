package funpack_runtime

import "core:fmt"
import "core:testing"

@(private = "file")
dd_program :: proc(allocator := context.allocator) -> Program {
	fields := make([]Field_Decl, 2, allocator)
	fields[0] = Field_Decl{name = "x", type = "Int"}
	fields[1] = Field_Decl{name = "y", type = "Int"}
	data := make([]Data_Decl, 1, allocator)
	data[0] = Data_Decl{name = "Cell", fields = fields}
	program := Program{}
	program.data = data
	return program
}

@(private = "file")
dd_physics_program :: proc(allocator := context.allocator) -> Program {
	body_fields := make([]Field_Decl, 3, allocator)
	body_fields[0] = Field_Decl{name = "vel", type = "Vec2"}
	body_fields[1] = Field_Decl{name = "layer", type = "CollisionLayer"}
	body_fields[2] = Field_Decl{name = "contact", type = "Option"}

	settings_fields := make([]Field_Decl, 3, allocator)
	settings_fields[0] = Field_Decl{name = "volume", type = "Int"}
	settings_fields[1] = Field_Decl{name = "fullscreen", type = "Bool"}
	settings_fields[2] = Field_Decl{name = "access", type = "AccessOpts"}

	access_fields := make([]Field_Decl, 1, allocator)
	access_fields[0] = Field_Decl{name = "reduce_motion", type = "Bool"}

	data := make([]Data_Decl, 3, allocator)
	data[0] = Data_Decl{name = "Body", fields = body_fields}
	data[1] = Data_Decl{name = "Settings", fields = settings_fields}
	data[2] = Data_Decl{name = "AccessOpts", fields = access_fields}
	program := Program{}
	program.data = data
	return program
}

@(test)
test_decode_default_bool :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := dd_program()

	fd_false := Field_Decl{name = "grow", type = "Bool", has_default = true, default_encoded = "false"}
	v_false, ok_false := decode_default(&program, fd_false, context.temp_allocator)
	if !testing.expect(t, ok_false) {
		return
	}
	b_false, is_bool_false := v_false.(bool)
	testing.expect(t, is_bool_false)
	testing.expect_value(t, b_false, false)

	fd_true := Field_Decl{name = "grow", type = "Bool", has_default = true, default_encoded = "true"}
	v_true, ok_true := decode_default(&program, fd_true, context.temp_allocator)
	if !testing.expect(t, ok_true) {
		return
	}
	b_true, is_bool_true := v_true.(bool)
	testing.expect(t, is_bool_true)
	testing.expect_value(t, b_true, true)
}

@(test)
test_decode_default_empty_list :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := dd_program()

	fd := Field_Decl{name = "body", type = "[Cell]", has_default = true, default_encoded = "[]"}
	v, ok := decode_default(&program, fd, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	list, is_list := v.(List_Value)
	if !testing.expect(t, is_list) {
		return
	}
	testing.expect_value(t, len(list.elements), 0)
}

@(test)
test_decode_default_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := dd_program()

	fd := Field_Decl {
		name            = "head",
		type            = "Cell",
		has_default     = true,
		default_encoded = "Cell(x=10,y=10)",
	}
	v, ok := decode_default(&program, fd, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	rec, is_rec := v.(Record_Value)
	if !testing.expect(t, is_rec) {
		return
	}
	testing.expect_value(t, rec.type_name, "Cell")

	x, x_ok := rec.fields["x"].(i64)
	testing.expect(t, x_ok)
	testing.expect_value(t, x, i64(10))

	y, y_ok := rec.fields["y"].(i64)
	testing.expect(t, y_ok)
	testing.expect_value(t, y, i64(10))
}

@(test)
test_decode_default_record_round_trips_to_value :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := dd_program()

	fd := Field_Decl {
		name            = "head",
		type            = "Cell",
		has_default     = true,
		default_encoded = "Cell(x=10,y=10)",
	}
	v, ok := decode_default(&program, fd, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	lifted := field_value_to_value(v)

	expected_fields := make(map[string]Value, context.temp_allocator)
	expected_fields["x"] = i64(10)
	expected_fields["y"] = i64(10)
	expected := Record_Value{type_name = "Cell", fields = expected_fields}

	testing.expect(t, values_equal(lifted, expected))
}

@(test)
test_decode_default_nested_vec2_collapses :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := dd_program()

	zero_bits := i64(to_fixed(0))
	encoded := fmt.tprintf("Vec2(x=%d,y=%d)", zero_bits, zero_bits)

	fd := Field_Decl{name = "at", type = "Vec2", has_default = true, default_encoded = encoded}
	v, ok := decode_default(&program, fd, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	vec, is_vec := v.(Vec2)
	if !testing.expect(t, is_vec) {
		return
	}
	testing.expect_value(t, vec.x, to_fixed(0))
	testing.expect_value(t, vec.y, to_fixed(0))
}

@(test)
test_decode_default_body_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := dd_physics_program()

	zero := i64(to_fixed(0))
	encoded := fmt.tprintf(
		"Body(vel=Vec2(x=%d,y=%d),layer=CollisionLayer::Solid,contact=Option::None)",
		zero,
		zero,
	)
	fd := Field_Decl{name = "body", type = "Body", has_default = true, default_encoded = encoded}
	v, ok := decode_default(&program, fd, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	rec, is_rec := v.(Record_Value)
	if !testing.expect(t, is_rec) {
		return
	}
	testing.expect_value(t, rec.type_name, "Body")

	vel, vel_ok := rec.fields["vel"].(Vec2)
	if !testing.expect(t, vel_ok) {
		return
	}
	testing.expect_value(t, vel.x, to_fixed(0))
	testing.expect_value(t, vel.y, to_fixed(0))

	layer, layer_ok := rec.fields["layer"].(Variant_Value)
	if !testing.expect(t, layer_ok) {
		return
	}
	testing.expect_value(t, layer.enum_type, "CollisionLayer")
	testing.expect_value(t, layer.case_name, "Solid")

	contact, contact_ok := rec.fields["contact"].(Variant_Value)
	if !testing.expect(t, contact_ok) {
		return
	}
	testing.expect_value(t, contact.enum_type, "Option")
	testing.expect_value(t, contact.case_name, "None")
	testing.expect(t, contact.payload == nil)
}

@(test)
test_decode_default_settings_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := dd_physics_program()

	fd := Field_Decl {
		name            = "settings",
		type            = "Settings",
		has_default     = true,
		default_encoded = "Settings(volume=128,fullscreen=false,access=AccessOpts(reduce_motion=false))",
	}
	v, ok := decode_default(&program, fd, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	rec, is_rec := v.(Record_Value)
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
test_decode_default_option_none :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := dd_physics_program()

	fd := Field_Decl {
		name            = "target",
		type            = "Option",
		has_default     = true,
		default_encoded = "Option::None",
	}
	v, ok := decode_default(&program, fd, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	token, is_token := v.(string)
	if !testing.expect(t, is_token) {
		return
	}
	testing.expect_value(t, token, "Option::None")

	lifted := field_value_to_value(v)
	variant, is_variant := lifted.(Variant_Value)
	if !testing.expect(t, is_variant) {
		return
	}
	testing.expect_value(t, variant.enum_type, "Option")
	testing.expect_value(t, variant.case_name, "None")
	testing.expect(t, variant.payload == nil)
}
