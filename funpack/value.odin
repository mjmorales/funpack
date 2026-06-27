package funpack

import "core:fmt"
import "core:strings"

Value :: union {
	Fixed,
	i64,
	bool,
	string,
	Option_Value,
	Vec2_Value,
	Vec3_Value,
	Quat_Value,
	List_Value,
	Map_Value,
	Tuple_Value,
	Lambda_Value,
	Enum_Value,
	Record_Value,
	Input_Value,
	Time_Value,
	Transform_Value,
	Pose_Value,
	Tilemap_Value,
	Nav_Value,
	Rng,
}

Nav_Value :: struct {
	route:  Record_Value,
	failed: bool,
	err:    string,
}

Transform_Value :: struct {
	pos:   Vec3_Value,
	rot:   Quat_Value,
	scale: Vec3_Value,
}

Pose_Value :: struct {
	bones: []Pose_Bone_Transform,
}

Pose_Bone_Transform :: struct {
	bone:      string,
	transform: Transform_Value,
}

List_Value :: struct {
	elements: []Value,
}

Map_Value :: struct {
	entries: []Map_Entry,
}

Map_Entry :: struct {
	key:   Value,
	value: Value,
}

Tuple_Value :: struct {
	elements: []Value,
}

Tilemap_Value :: struct {
	cell_size:      i64,
	cell_type_name: string,
	cells:          []Tilemap_Seed_Cell,
}

Tilemap_Seed_Cell :: struct {
	x:     i64,
	y:     i64,
	tile:  string,
	solid: bool,
}

Input_Value :: struct {
	pressed:  []Input_Press,
	analog1d: []Input_Analog_Value,
	analog2d: []Input_Analog_Axis,
}

Input_Press :: struct {
	player: string,
	action: string,
}

Input_Analog_Value :: struct {
	player: string,
	axis:   string,
	value:  Fixed,
}

Input_Analog_Axis :: struct {
	player: string,
	axis:   string,
	value:  Vec2_Value,
}

Time_Value :: struct {
	dt: Fixed,
	t:  Fixed,
}

Enum_Value :: struct {
	type_name: string,
	variant:   string,
	payload:   ^Value,
}

Record_Value :: struct {
	type_name: string,
	variant:   string,
	fields:    []Record_Field_Value,
}

Record_Field_Value :: struct {
	name:  string,
	value: Value,
}

Lambda_Value :: struct {
	node: ^Lambda_Expr,
	env:  ^Env,
}

Option_Value :: struct {
	is_some: bool,
	payload: ^Value,
}

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
	case string:
		bv, ok := b.(string)
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
	case Map_Value:
		bv, ok := b.(Map_Value)
		if !ok || len(av.entries) != len(bv.entries) {
			return false
		}
		for entry, i in av.entries {
			if !value_equal(entry.key, bv.entries[i].key) ||
			   !value_equal(entry.value, bv.entries[i].value) {
				return false
			}
		}
		return true
	case Tuple_Value:
		bv, ok := b.(Tuple_Value)
		if !ok || len(av.elements) != len(bv.elements) {
			return false
		}
		for element, i in av.elements {
			if !value_equal(element, bv.elements[i]) {
				return false
			}
		}
		return true
	case Input_Value:
		return false
	case Tilemap_Value:
		return false
	case Nav_Value:
		return false
	case Time_Value:
		bv, ok := b.(Time_Value)
		return ok && av.dt == bv.dt
	case Lambda_Value:
		return false
	case Enum_Value:
		bv, ok := b.(Enum_Value)
		if !ok || av.type_name != bv.type_name || av.variant != bv.variant {
			return false
		}
		if (av.payload == nil) != (bv.payload == nil) {
			return false
		}
		if av.payload == nil {
			return true
		}
		return value_equal(av.payload^, bv.payload^)
	case Record_Value:
		bv, ok := b.(Record_Value)
		if !ok || av.type_name != bv.type_name || av.variant != bv.variant {
			return false
		}
		return record_fields_equal(av.fields, bv.fields)
	case Transform_Value:
		bv, ok := b.(Transform_Value)
		return ok && av == bv
	case Pose_Value:
		bv, ok := b.(Pose_Value)
		return ok && pose_bones_equal(av.bones, bv.bones)
	case Rng:
		bv, ok := b.(Rng)
		return ok && av.state == bv.state
	}
	return false
}

pose_bones_equal :: proc(a, b: []Pose_Bone_Transform) -> bool {
	if len(a) != len(b) {
		return false
	}
	for driven in a {
		other, found := pose_bone_transform(b, driven.bone)
		if !found || driven.transform != other {
			return false
		}
	}
	return true
}

pose_bone_transform :: proc(bones: []Pose_Bone_Transform, bone: string) -> (transform: Transform_Value, found: bool) {
	for driven in bones {
		if driven.bone == bone {
			return driven.transform, true
		}
	}
	return Transform_Value{}, false
}

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

record_field_value :: proc(fields: []Record_Field_Value, name: string) -> (value: Value, found: bool) {
	for field in fields {
		if field.name == name {
			return field.value, true
		}
	}
	return nil, false
}

value_display :: proc(v: Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	value_display_into(&b, v)
	return strings.to_string(b)
}

value_display_into :: proc(b: ^strings.Builder, v: Value) {
	switch av in v {
	case i64:
		fmt.sbprintf(b, "%d", av)
	case bool:
		fmt.sbprint(b, "true" if av else "false")
	case string:
		fmt.sbprintf(b, "%q", av)
	case Fixed:
		fmt.sbprintf(b, "fixed(%d)", i64(av))
	case Option_Value:
		if !av.is_some {
			fmt.sbprint(b, "Option::None")
			return
		}
		fmt.sbprint(b, "Option::Some(")
		value_display_into(b, av.payload^)
		fmt.sbprint(b, ")")
	case Vec2_Value:
		fmt.sbprintf(b, "Vec2{{x: fixed(%d), y: fixed(%d)}}", i64(av.x), i64(av.y))
	case Vec3_Value:
		fmt.sbprintf(b, "Vec3{{x: fixed(%d), y: fixed(%d), z: fixed(%d)}}", i64(av.x), i64(av.y), i64(av.z))
	case List_Value:
		fmt.sbprint(b, "[")
		for element, i in av.elements {
			if i > 0 {
				fmt.sbprint(b, ", ")
			}
			value_display_into(b, element)
		}
		fmt.sbprint(b, "]")
	case Map_Value:
		fmt.sbprint(b, "Map{")
		for entry, i in av.entries {
			if i > 0 {
				fmt.sbprint(b, ", ")
			}
			value_display_into(b, entry.key)
			fmt.sbprint(b, ": ")
			value_display_into(b, entry.value)
		}
		fmt.sbprint(b, "}")
	case Tuple_Value:
		fmt.sbprint(b, "(")
		for element, i in av.elements {
			if i > 0 {
				fmt.sbprint(b, ", ")
			}
			value_display_into(b, element)
		}
		fmt.sbprint(b, ")")
	case Enum_Value:
		fmt.sbprintf(b, "%s::%s", av.type_name, av.variant)
		if av.payload != nil {
			fmt.sbprint(b, "(")
			value_display_into(b, av.payload^)
			fmt.sbprint(b, ")")
		}
	case Record_Value:
		fmt.sbprint(b, av.type_name)
		if av.variant != "" {
			fmt.sbprintf(b, "::%s", av.variant)
		}
		fmt.sbprint(b, "{")
		for field, i in av.fields {
			if i > 0 {
				fmt.sbprint(b, ", ")
			}
			fmt.sbprintf(b, "%s: ", field.name)
			value_display_into(b, field.value)
		}
		fmt.sbprint(b, "}")
	case Quat_Value:
		fmt.sbprintf(b, "Quat{{x: fixed(%d), y: fixed(%d), z: fixed(%d), w: fixed(%d)}}", i64(av.x), i64(av.y), i64(av.z), i64(av.w))
	case Lambda_Value:
		fmt.sbprint(b, "<fn>")
	case Input_Value:
		fmt.sbprint(b, "<Input>")
	case Tilemap_Value:
		fmt.sbprint(b, "<Tilemap>")
	case Nav_Value:
		fmt.sbprint(b, "<Nav>")
	case Time_Value:
		fmt.sbprint(b, "<Time>")
	case Transform_Value:
		fmt.sbprint(b, "<Transform>")
	case Pose_Value:
		fmt.sbprint(b, "<Pose>")
	case Rng:
		fmt.sbprintf(b, "Rng(%d)", av.state)
	}
}
