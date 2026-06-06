// decode_default fixtures (spec §06, §13; docs/artifact-format.md §6) — the
// runtime DECODER half of the composite-default contract. The emitter writes a
// thing/data field default as a single space-free §6 token; this layer decodes it
// back into a blackboard column. Pong exercised only the scalar forms (Int/Fixed/
// enum); snake adds the Bool, empty-list, and composite-record forms, so these
// fixtures pin each new arm to its exact decoded column:
//
//   - `=false`/`=true`   → a bool column;
//   - `=[]`              → an empty List_Value column (snake's `body: [Cell]`);
//   - `=Cell(x=10,y=10)` → a Record_Value column whose fields decode by the data
//     decl's field types (Cell.x/y are Int, so the coords are i64, the SAME shape a
//     runtime `Cell{…}` literal evaluates to);
//   - a nested `Vec2(x=…,y=…)` record default collapses to a Vec2 column.
//
// The values are pinned to exact kernel-stable bits (i64 coords, the empty-list
// length) — a decode that drifts is a determinism break the snake golden would also
// catch, but pinned here at the decoder leaf for a precise failure signal.
package funpack_runtime

import "core:fmt"
import "core:testing"

// dd_program builds a minimal Program carrying a `Cell { x: Int, y: Int }` data
// decl, so decode_record_default can resolve a `Cell(x=…,y=…)` default's nested
// field types. It is the schema-lookup substrate the composite-default decode reads.
// The decl slices are allocated on the supplied allocator (NOT a stack-local slice
// literal) so they outlive this proc's return — a freed decl would make
// data_field_type read garbage and decode `x=10` as a Fixed instead of an Int.
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

// dd_physics_program adds the §6 engine-type data decls the v5 yard surface
// introduces — `Body { vel: Vec2, layer: CollisionLayer, contact: Option }` and
// `Settings { volume: Int, fullscreen: Bool }` — so decode_record_default can
// resolve each composite default's nested field types from the data decl. The
// slices live on the supplied allocator so they outlive this proc's return; a
// freed decl would make data_field_type read garbage and mis-type a nested field.
@(private = "file")
dd_physics_program :: proc(allocator := context.allocator) -> Program {
	body_fields := make([]Field_Decl, 3, allocator)
	body_fields[0] = Field_Decl{name = "vel", type = "Vec2"}
	body_fields[1] = Field_Decl{name = "layer", type = "CollisionLayer"}
	body_fields[2] = Field_Decl{name = "contact", type = "Option"}

	settings_fields := make([]Field_Decl, 2, allocator)
	settings_fields[0] = Field_Decl{name = "volume", type = "Int"}
	settings_fields[1] = Field_Decl{name = "fullscreen", type = "Bool"}

	data := make([]Data_Decl, 2, allocator)
	data[0] = Data_Decl{name = "Body", fields = body_fields}
	data[1] = Data_Decl{name = "Settings", fields = settings_fields}
	program := Program{}
	program.data = data
	return program
}

@(test)
test_decode_default_bool :: proc(t: ^testing.T) {
	// `grow: Bool = false` decodes to a bool column; `= true` to its complement. The
	// Bool default token is the bare `true`/`false` the emitter writes (encode_literal).
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
	// `body: [Cell] = []` decodes to an EMPTY List_Value column — the only list
	// literal a §6 default admits. The column is a list of length 0, not a nil column.
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
	// `head: Cell = Cell(x=10,y=10)` decodes to a Record_Value column whose x/y are
	// i64 (Cell.x/y are declared Int), the SAME shape a runtime `Cell{x:10,y:10}`
	// literal evaluates to — so a `self.head` read and a `contains`/`==` over Cell
	// records compare equal. The coords are pinned to exact integers.
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
	// A decoded Record_Value column lifts back to the SAME Record_Value through
	// field_value_to_value (the column→Value inverse), and the lifted record equals a
	// hand-built `Cell{x:10,y:10}` value under the §03 universal-Eq surface
	// (values_equal) — so a default-decoded `head` and a runtime-constructed `head`
	// are interchangeable in the fold (the property the snake golden rests on).
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
	// A built-in Vec2 record default `Vec2(x=…,y=…)` collapses to a Vec2 COLUMN
	// (its x/y are Fixed components), not a by-name Record_Value — the same shape a
	// runtime `Vec2{…}` literal evaluates to. The components are raw Q32.32 bits, so
	// the default decodes from the same kernel the runtime arithmetic uses (no float).
	context.allocator = context.temp_allocator
	program := dd_program()

	// Build the Vec2 default token from the kernel's raw Q32.32 bits for 0, so the
	// fixture decodes the exact bytes the emitter would write for `Vec2{x:0,y:0}`.
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

// --- v5 engine-type composite defaults (§6, the yard physics surface) -------
// The v5 schema adds §6 composite defaults for the engine record types Body,
// Settings, and Option. Each is the SAME `Type(field=enc,…)` / `Enum::Case` token
// the decoder already shapes — these fixtures pin the engine-type forms the yard
// surface first reaches, proving the additive decode arms on hand-written tokens
// before any compiler-emitted yard.artifact exists (runtime Lore #8). No new
// decoder code: the arms exercise decode_record_default and the enum-token path.

@(test)
test_decode_default_body_record :: proc(t: ^testing.T) {
	// `body: Body = Body(vel=Vec2(x=0,y=0),layer=CollisionLayer::Solid,contact=Option::None)`
	// — the engine physics body default. It nests a Vec2 record (collapsing to a
	// Vec2 column), a CollisionLayer enum token, and an Option::None enum token,
	// each decoded by Body's declared field types. The top-level commas split at
	// paren depth 0, so the inner `Vec2(x=0,y=0)` is not split mid-record.
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

	// `vel` collapses to a Vec2 COLUMN (Vec2 is the built-in vector — its default
	// is a Vec2 value, not a by-name Record_Value), bit-exact through the kernel.
	vel, vel_ok := rec.fields["vel"].(Vec2)
	if !testing.expect(t, vel_ok) {
		return
	}
	testing.expect_value(t, vel.x, to_fixed(0))
	testing.expect_value(t, vel.y, to_fixed(0))

	// `layer` is a CollisionLayer enum token, carried verbatim as a Variant_Value.
	layer, layer_ok := rec.fields["layer"].(Variant_Value)
	if !testing.expect(t, layer_ok) {
		return
	}
	testing.expect_value(t, layer.enum_type, "CollisionLayer")
	testing.expect_value(t, layer.case_name, "Solid")

	// `contact` is Option::None — a unit enum token (nil payload).
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
	// `settings: Settings = Settings(volume=128,fullscreen=false)` — the
	// Settings.defaults()-shaped record default. Its fields decode by Settings'
	// declared types: `volume` is Int (an i64 column), `fullscreen` is Bool, so a
	// default-decoded Settings equals a runtime `Settings{…}` literal in the fold.
	context.allocator = context.temp_allocator
	program := dd_physics_program()

	fd := Field_Decl {
		name            = "settings",
		type            = "Settings",
		has_default     = true,
		default_encoded = "Settings(volume=128,fullscreen=false)",
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
}

@(test)
test_decode_default_option_none :: proc(t: ^testing.T) {
	// `target: Option = Option::None` — the Option engine type's default. An
	// Option::None default is an enum-variant token (it has a `::` and no `(`), so
	// it decodes to a verbatim string column that lifts to a unit Option::None
	// Variant_Value — the SAME shape none_value boxes a no-result first() into.
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
	// The column is the verbatim enum token (the enum-token arm, §2.6).
	token, is_token := v.(string)
	if !testing.expect(t, is_token) {
		return
	}
	testing.expect_value(t, token, "Option::None")

	// It lifts to a unit Option::None variant — interchangeable with none_value.
	lifted := field_value_to_value(v)
	variant, is_variant := lifted.(Variant_Value)
	if !testing.expect(t, is_variant) {
		return
	}
	testing.expect_value(t, variant.enum_type, "Option")
	testing.expect_value(t, variant.case_name, "None")
	testing.expect(t, variant.payload == nil)
}
