package funpack

import "core:testing"

@(test)
test_value_equal_fieldless_command_is_reflexive_and_tag_discriminated :: proc(t: ^testing.T) {
	despawn := Record_Value{type_name = "Despawn"}
	other := Record_Value{type_name = "Despawn"}
	testing.expect(t, value_equal(despawn, other))
	killed := Record_Value{type_name = "Killed"}
	testing.expect(t, !value_equal(despawn, killed))
}

@(test)
test_value_equal_engine_record_matches_by_field_set :: proc(t: ^testing.T) {
	a := Record_Value {
		type_name = "Save",
		fields    = {Record_Field_Value{name = "slot", value = "quicksave"}},
	}
	b := Record_Value {
		type_name = "Save",
		fields    = {Record_Field_Value{name = "slot", value = "quicksave"}},
	}
	testing.expect(t, value_equal(a, b))
	c := Record_Value {
		type_name = "Save",
		fields    = {Record_Field_Value{name = "slot", value = "other"}},
	}
	testing.expect(t, !value_equal(a, c))
}

@(test)
test_value_equal_field_order_independent :: proc(t: ^testing.T) {
	a := Record_Value {
		type_name = "Body",
		fields    = {
			Record_Field_Value{name = "mass", value = FIXED_ONE},
			Record_Field_Value{name = "sensor", value = false},
		},
	}
	b := Record_Value {
		type_name = "Body",
		fields    = {
			Record_Field_Value{name = "sensor", value = false},
			Record_Field_Value{name = "mass", value = FIXED_ONE},
		},
	}
	testing.expect(t, value_equal(a, b))
}

@(test)
test_value_display_scalars_and_list_render_deterministically :: proc(t: ^testing.T) {
	testing.expect_value(t, value_display(i64(42), context.temp_allocator), "42")
	testing.expect_value(t, value_display(true, context.temp_allocator), "true")
	testing.expect_value(t, value_display(false, context.temp_allocator), "false")
	list := List_Value{elements = {i64(1), i64(2), i64(3)}}
	testing.expect_value(t, value_display(list, context.temp_allocator), "[1, 2, 3]")
}

@(test)
test_value_display_fieldless_record_renders_braces :: proc(t: ^testing.T) {
	despawn := Record_Value{type_name = "Despawn"}
	testing.expect_value(t, value_display(despawn, context.temp_allocator), "Despawn{}")
}

@(test)
test_engine_record_schema_carries_spec_defaults :: proc(t: ^testing.T) {
	_, fields, found := surface_engine_record("Body")
	testing.expect(t, found)

	mass := surface_field_by_name(fields, "mass")
	testing.expect(t, mass.has_default)
	testing.expect(t, value_equal(mass.default, FIXED_ONE))

	restitution := surface_field_by_name(fields, "restitution")
	testing.expect(t, restitution.has_default)
	testing.expect(t, value_equal(restitution.default, Fixed(0)))

	friction := surface_field_by_name(fields, "friction")
	testing.expect(t, friction.has_default)
	testing.expect(t, value_equal(friction.default, FIXED_ONE / 2))

	sensor := surface_field_by_name(fields, "sensor")
	testing.expect(t, sensor.has_default)
	testing.expect(t, value_equal(sensor.default, false))

	impulse := surface_field_by_name(fields, "impulse")
	testing.expect(t, impulse.has_default)
	testing.expect(t, value_equal(impulse.default, Vec2_Value{}))

	kind := surface_field_by_name(fields, "kind")
	testing.expect(t, !kind.has_default)
	shape := surface_field_by_name(fields, "shape")
	testing.expect(t, !shape.has_default)
}

@(test)
test_engine_record_literal_fills_omitted_fields_from_schema_default :: proc(t: ^testing.T) {
	source := "import engine.math.{Vec2}\n" +
		"import engine.physics.{Body, BodyKind, Shape2}\n" +
		"enum Layer: CollisionLayer { Player, Wall }\n" +
		"test \"omitted body fields take their schema defaults\" {\n" +
		"  let b = Body{ kind: BodyKind::Dynamic, shape: Shape2::Circle{radius: 5.0}, layer: Layer::Player, mask: [Layer::Wall] }\n" +
		"  assert b.impulse == Vec2{x: 0.0, y: 0.0}\n" +
		"  assert b.mass == 1.0\n" +
		"  assert b.restitution == 0.0\n" +
		"  assert b.friction == 0.5\n" +
		"  assert b.sensor == false\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 5)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_access_opts_default_reduce_motion_false_from_schema :: proc(t: ^testing.T) {
	_, fields, found := surface_engine_record("AccessOpts")
	testing.expect(t, found)
	reduce := surface_field_by_name(fields, "reduce_motion")
	testing.expect(t, reduce.has_default)
	testing.expect(t, value_equal(reduce.default, false))

	settings := settings_defaults().(Record_Value)
	access_value, has_access := record_field_value(settings.fields, "access")
	testing.expect(t, has_access)
	access := access_value.(Record_Value)
	reduce_value, has_reduce := record_field_value(access.fields, "reduce_motion")
	testing.expect(t, has_reduce)
	testing.expect(t, value_equal(reduce_value, false))
}

@(test)
test_settings_defaults_is_deterministic :: proc(t: ^testing.T) {
	testing.expect(t, value_equal(settings_defaults(), settings_defaults()))
}

surface_field_by_name :: proc(fields: []Surface_Field, name: string) -> Surface_Field {
	for field in fields {
		if field.name == name {
			return field
		}
	}
	return Surface_Field{}
}
