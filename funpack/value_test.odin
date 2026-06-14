// The evaluator's value model junction (value.odin + the surface-schema default
// fill in surface.odin/evaluate.odin): structural equality (value_equal),
// deterministic rendering (value_display), and the rule that an engine record
// fills an omitted field from its surface-schema default. These pin the value
// model DIRECTLY — constructing Values and asserting equality/display, and
// reading defaults off the one surface schema — so the file reads as a living
// spec of how a sanctioned engine command/record is represented and compared.
// The end-to-end "a behavior body evaluates these constructs" coverage lives in
// the example goldens (golden_yard/arena/krognid_test); this file owns the
// units beneath them.
package funpack

import "core:testing"

// ── value_equal: tagged-record structural equality ───────────────────────────

@(test)
test_value_equal_fieldless_command_is_reflexive_and_tag_discriminated :: proc(t: ^testing.T) {
	// A fieldless engine command/signal is a Record_Value tagged with its type
	// name (Despawn(), Trigger{}, Killed{} all take this shape): two of the same
	// tag are value_equal, and a different tag discriminates — the structural
	// equality `[Despawn()] == [Despawn()]` and the Save/ApplySettings command
	// asserts rest on.
	despawn := Record_Value{type_name = "Despawn"}
	other := Record_Value{type_name = "Despawn"}
	testing.expect(t, value_equal(despawn, other))
	killed := Record_Value{type_name = "Killed"}
	testing.expect(t, !value_equal(despawn, killed))
}

@(test)
test_value_equal_engine_record_matches_by_field_set :: proc(t: ^testing.T) {
	// A field-bearing engine command (Save{slot}) compares equal iff its field
	// VALUES match — the §24 persistence command equality. A differing slot
	// discriminates, so the records compare structurally rather than by identity.
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
	// value_equal matches fields BY NAME, so two records carrying the same field
	// set in a different order compare equal — the invariant that lets an engine
	// record's schema-default fill (appended after the literal's named fields)
	// still compare equal regardless of which optional fields a literal named.
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

// ── value_display: deterministic operand rendering ───────────────────────────

@(test)
test_value_display_scalars_and_list_render_deterministically :: proc(t: ^testing.T) {
	// value_display is the operand renderer the assert-failure body relies on: an
	// Int, a Bool, and a list each render their one deterministic form (the bytes
	// the assert-failure goldens in diagnostics_test are built from).
	testing.expect_value(t, value_display(i64(42), context.temp_allocator), "42")
	testing.expect_value(t, value_display(true, context.temp_allocator), "true")
	testing.expect_value(t, value_display(false, context.temp_allocator), "false")
	list := List_Value{elements = {i64(1), i64(2), i64(3)}}
	testing.expect_value(t, value_display(list, context.temp_allocator), "[1, 2, 3]")
}

@(test)
test_value_display_fieldless_record_renders_braces :: proc(t: ^testing.T) {
	// A fieldless command record renders `Name{}` — the Despawn operand display a
	// failed command-equality assert shows.
	despawn := Record_Value{type_name = "Despawn"}
	testing.expect_value(t, value_display(despawn, context.temp_allocator), "Despawn{}")
}

// ── schema-default fill: the surface schema is the single source of truth ─────

@(test)
test_engine_record_schema_carries_spec_defaults :: proc(t: ^testing.T) {
	// The surface schema (surface_engine_record) is the SINGLE SOURCE OF TRUTH for
	// both a field's type AND its spec `data` default. The §11 §2 Body defaults
	// (mass 1.0, restitution 0.0, friction 0.5, sensor false, impulse zero) and the
	// required fields (kind/shape/layer/mask carry no default) are read directly
	// off the schema here — there is no parallel default table.
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
	// 0.5 exact in fixed-point — half of FIXED_ONE.
	testing.expect(t, value_equal(friction.default, FIXED_ONE / 2))

	sensor := surface_field_by_name(fields, "sensor")
	testing.expect(t, sensor.has_default)
	testing.expect(t, value_equal(sensor.default, false))

	impulse := surface_field_by_name(fields, "impulse")
	testing.expect(t, impulse.has_default)
	testing.expect(t, value_equal(impulse.default, Vec2_Value{}))

	// A required field carries no default — never omitted in a checked literal.
	kind := surface_field_by_name(fields, "kind")
	testing.expect(t, !kind.has_default)
	shape := surface_field_by_name(fields, "shape")
	testing.expect(t, !shape.has_default)
}

@(test)
test_engine_record_literal_fills_omitted_fields_from_schema_default :: proc(t: ^testing.T) {
	// An engine-record literal that omits a defaulted field carries that field's
	// SCHEMA default in the evaluated value — the omitted Body fields read their
	// §11 §2 defaults (impulse zero, mass 1.0, sensor false) sourced off the one
	// surface schema, not a parallel default table. Exercised through the real
	// eval_record path so the literal → value fill is the production code.
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
	// §24 §2 AccessOpts.reduce_motion = false is carried on the surface schema (the
	// one source Settings.defaults() and the runtime mirror both seed from). The
	// all-omitted construction reads the schema default false.
	_, fields, found := surface_engine_record("AccessOpts")
	testing.expect(t, found)
	reduce := surface_field_by_name(fields, "reduce_motion")
	testing.expect(t, reduce.has_default)
	testing.expect(t, value_equal(reduce.default, false))

	// Settings.defaults() builds its `access` AccessOpts through the schema-default
	// path, so the nested reduce_motion reads the same schema-sourced false.
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
	// Settings.defaults() is deterministic, so two calls compare equal — the
	// invariant the §24 ApplySettings command-equality assert rests on (both sides
	// carry the same defaults() value).
	testing.expect(t, value_equal(settings_defaults(), settings_defaults()))
}

// surface_field_by_name looks one engine-record field up by name in a schema
// slice, returning the zero Surface_Field when absent — a test-local read of the
// surface schema so the default assertions name the field they pin.
surface_field_by_name :: proc(fields: []Surface_Field, name: string) -> Surface_Field {
	for field in fields {
		if field.name == name {
			return field
		}
	}
	return Surface_Field{}
}
