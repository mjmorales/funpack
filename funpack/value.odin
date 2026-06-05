// Value is the evaluator's tagged runtime value. The scalar arms land
// with the kernel; composite arms (vectors, quaternions, Option, lists,
// lambdas) widen the union behind the same dispatch shape. There is no
// implicit promotion anywhere: equality and arithmetic demand matching
// tags, mirroring the type discipline of spec §10.
package funpack

Value :: union {
	Fixed,
	i64,  // Int — counts and indices
	bool, // Bool — the result of ==
	Option_Value,
	Vec2_Value,
	Vec3_Value,
	Quat_Value,
	List_Value,
	Lambda_Value,
	Enum_Value,
	Record_Value,
}

List_Value :: struct {
	elements: []Value,
}

// Enum_Value is a bare enum variant value — a user enum (Side::Left) or an
// engine enum (Color::White, PlayerId::P1). The pong surface's user enums
// carry no payload, so a variant is identified by its owning type and its
// variant name alone. Equality is by (type_name, variant): two variants are
// equal iff they name the same variant of the same enum (spec §10 demands
// matching tags; §03 §2 closes the variant set).
Enum_Value :: struct {
	type_name: string,
	variant:   string,
}

// Record_Value is a constructed record value: a user thing/data/signal
// (Goal{side: …}, Scoreboard{left: …}) or an engine struct-payload command
// variant (Draw::Rect{at: …}). type_name is the declared/engine type;
// variant is the struct-variant tag ("" for a plain record). fields carry
// the field name→value pairs in construction order; equality matches by
// field name, so construction order never reaches the result (§10).
Record_Value :: struct {
	type_name: string,
	variant:   string, // the engine struct-variant tag; "" for a plain record
	fields:    []Record_Field_Value,
}

// Record_Field_Value is one named field slot of a Record_Value.
Record_Field_Value :: struct {
	name:  string,
	value: Value,
}

// Lambda_Value captures its defining environment; application binds
// parameters in a child frame off it.
Lambda_Value :: struct {
	node: ^Lambda_Expr,
	env:  ^Env,
}

// Option_Value is the runtime Option: a present payload or none. The
// payload is a pointer because a union cannot contain itself by value.
Option_Value :: struct {
	is_some: bool,
	payload: ^Value, // nil when none
}

// value_equal is structural: tags must match, then the payloads compare
// bit-exactly (Fixed is transparent integer data, spec §10).
value_equal :: proc(a, b: Value) -> bool {
	switch av in a {
	case Fixed:
		bv, ok := b.(Fixed)
		return ok && av == bv
	case i64:
		bv, ok := b.(i64)
		return ok && av == bv
	case bool:
		bv, ok := b.(bool)
		return ok && av == bv
	case Option_Value:
		bv, ok := b.(Option_Value)
		if !ok || av.is_some != bv.is_some {
			return false
		}
		if !av.is_some {
			return true
		}
		return value_equal(av.payload^, bv.payload^)
	case Vec2_Value:
		bv, ok := b.(Vec2_Value)
		return ok && av == bv
	case Vec3_Value:
		bv, ok := b.(Vec3_Value)
		return ok && av == bv
	case Quat_Value:
		bv, ok := b.(Quat_Value)
		return ok && av == bv
	case List_Value:
		bv, ok := b.(List_Value)
		if !ok || len(av.elements) != len(bv.elements) {
			return false
		}
		for element, i in av.elements {
			if !value_equal(element, bv.elements[i]) {
				return false
			}
		}
		return true
	case Lambda_Value:
		// Functions have no extensional equality; comparing them is
		// always false rather than an identity check the language never
		// promises.
		return false
	case Enum_Value:
		bv, ok := b.(Enum_Value)
		return ok && av.type_name == bv.type_name && av.variant == bv.variant
	case Record_Value:
		bv, ok := b.(Record_Value)
		if !ok || av.type_name != bv.type_name || av.variant != bv.variant {
			return false
		}
		return record_fields_equal(av.fields, bv.fields)
	}
	return false
}

// record_fields_equal compares two record field sets by name: every field on
// one side must match a same-named field on the other with an equal value, and
// the two sides must carry the same field count. Matching by name (not
// position) makes construction order irrelevant — a `with`-update or a
// reordered literal compares equal to the canonical value (spec §10).
record_fields_equal :: proc(a, b: []Record_Field_Value) -> bool {
	if len(a) != len(b) {
		return false
	}
	for field in a {
		other, found := record_field_value(b, field.name)
		if !found || !value_equal(field.value, other) {
			return false
		}
	}
	return true
}

// record_field_value reads a field's value off a record value by name — a
// linear lookup, so field order never reaches the verdict.
record_field_value :: proc(fields: []Record_Field_Value, name: string) -> (value: Value, found: bool) {
	for field in fields {
		if field.name == name {
			return field.value, true
		}
	}
	return nil, false
}
