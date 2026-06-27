package funpack_runtime

import "core:fmt"
import "core:slice"
import "core:strings"

write_encoded_value :: proc(b: ^strings.Builder, value: Value, allocator := context.allocator) {
	write_json_string(b, encode_value_text(value, allocator))
}

write_encoded_field_value :: proc(
	b: ^strings.Builder,
	value: Field_Value,
	allocator := context.allocator,
) {
	encoded := strings.builder_make(allocator)
	render_field_value_text(&encoded, value)
	write_json_string(b, strings.to_string(encoded))
}

write_encoded_blackboard :: proc(
	b: ^strings.Builder,
	thing: string,
	fields: map[string]Field_Value,
	allocator := context.allocator,
) {
	write_json_string(b, encode_blackboard_text(thing, fields, allocator))
}

sorted_blackboard_names :: proc(
	fields: map[string]Field_Value,
	allocator := context.allocator,
) -> []string {
	names := make([dynamic]string, 0, len(fields), allocator)
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names[:]
}

render_field_value_text :: proc(b: ^strings.Builder, value: Field_Value) {
	switch v in value {
	case i64:
		fmt.sbprintf(b, "%d", v)
	case Fixed:
		write_source_fixed(b, v)
	case bool:
		strings.write_string(b, v ? "true" : "false")
	case string:
		strings.write_string(b, v)
	case Vec2:
		write_vec2_decimal(b, v)
	case Vec3:
		write_vec3_decimal(b, v)
	case Ref:
		fmt.sbprintf(b, "Ref(thing=%s,id=%d)", v.thing, v.id.raw)
	case Record_Value:
		render_record_text(b, v)
	case List_Value:
		render_list_text(b, v)
	case Map_Value:
		render_map_text(b, v)
	case Variant_Value:
		render_variant_text(b, v)
	case String_Value:
		fmt.sbprintf(b, "L%d:%s", len(v.text), v.text)
	}
}

render_map_text :: proc(b: ^strings.Builder, m: Map_Value) {
	strings.write_string(b, "Map{")
	for entry, i in m.entries {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		render_value_text(b, entry.key)
		strings.write_byte(b, ':')
		render_value_text(b, entry.value)
	}
	strings.write_byte(b, '}')
}

write_vec2_decimal :: proc(b: ^strings.Builder, v: Vec2) {
	strings.write_string(b, "Vec2(x=")
	write_source_fixed(b, v.x)
	strings.write_string(b, ",y=")
	write_source_fixed(b, v.y)
	strings.write_byte(b, ')')
}

write_vec3_decimal :: proc(b: ^strings.Builder, v: Vec3) {
	strings.write_string(b, "Vec3(x=")
	write_source_fixed(b, v.x)
	strings.write_string(b, ",y=")
	write_source_fixed(b, v.y)
	strings.write_string(b, ",z=")
	write_source_fixed(b, v.z)
	strings.write_byte(b, ')')
}

render_value_text :: proc(b: ^strings.Builder, value: Value) {
	switch v in value {
	case i64:
		fmt.sbprintf(b, "%d", v)
	case Fixed:
		write_source_fixed(b, v)
	case bool:
		strings.write_string(b, v ? "true" : "false")
	case Vec2:
		write_vec2_decimal(b, v)
	case Vec3:
		write_vec3_decimal(b, v)
	case Ref:
		fmt.sbprintf(b, "Ref(thing=%s,id=%d)", v.thing, v.id.raw)
	case Record_Value:
		render_record_text(b, v)
	case List_Value:
		render_list_text(b, v)
	case Variant_Value:
		render_variant_text(b, v)
	case Lambda_Value:
		fmt.sbprintf(b, "<lambda/%d>", len(v.params))
	case String_Value:
		fmt.sbprintf(b, "L%d:%s", len(v.text), v.text)
	case Tuple_Value:
		strings.write_byte(b, '(')
		for element, i in v.elements {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			render_value_text(b, element)
		}
		strings.write_byte(b, ')')
	case Map_Value:
		render_map_text(b, v)
	case Rng:
		fmt.sbprintf(b, "Rng(state=%d)", v.state)
	case Transform_Value:
		render_transform_text(b, v)
	case Pose_Value:
		render_pose_text(b, v)
	case Handle_Value:
		render_handle_text(b, v)
	case Nav_Value:
		fmt.sbprintf(b, "<nav failed=%v>", v.failed)
	case:
		strings.write_string(b, "<none>")
	}
}

@(private = "file")
render_record_text :: proc(b: ^strings.Builder, record: Record_Value) {
	strings.write_string(b, record.type_name)
	strings.write_byte(b, '(')
	names := make([dynamic]string, 0, len(record.fields), context.temp_allocator)
	for name in record.fields {
		append(&names, name)
	}
	slice.sort(names[:])
	for name, i in names {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		strings.write_string(b, name)
		strings.write_byte(b, '=')
		render_value_text(b, record.fields[name])
	}
	strings.write_byte(b, ')')
}

@(private = "file")
render_list_text :: proc(b: ^strings.Builder, list: List_Value) {
	strings.write_byte(b, '[')
	for element, i in list.elements {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		render_value_text(b, element)
	}
	strings.write_byte(b, ']')
}

@(private = "file")
render_variant_text :: proc(b: ^strings.Builder, variant: Variant_Value) {
	strings.write_string(b, variant.enum_type)
	strings.write_string(b, "::")
	strings.write_string(b, variant.case_name)
	if variant.payload == nil {
		return
	}
	if record, is_record := variant.payload^.(Record_Value); is_record && record.type_name == "" {
		render_record_text(b, record)
		return
	}
	strings.write_byte(b, '(')
	render_value_text(b, variant.payload^)
	strings.write_byte(b, ')')
}

@(private = "file")
render_transform_text :: proc(b: ^strings.Builder, t: Transform_Value) {
	strings.write_string(b, "Transform(pos=")
	write_vec3_decimal(b, t.pos)
	strings.write_string(b, ",rot=Quat(x=")
	write_source_fixed(b, t.rot.x)
	strings.write_string(b, ",y=")
	write_source_fixed(b, t.rot.y)
	strings.write_string(b, ",z=")
	write_source_fixed(b, t.rot.z)
	strings.write_string(b, ",w=")
	write_source_fixed(b, t.rot.w)
	strings.write_string(b, "),scale=")
	write_vec3_decimal(b, t.scale)
	strings.write_byte(b, ')')
}

@(private = "file")
render_pose_text :: proc(b: ^strings.Builder, pose: Pose_Value) {
	strings.write_string(b, "Pose(")
	for bone, i in pose.bones {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		strings.write_string(b, bone.bone)
		strings.write_byte(b, '=')
		render_transform_text(b, bone.transform)
	}
	strings.write_byte(b, ')')
}

@(private = "file")
render_handle_text :: proc(b: ^strings.Builder, handle: Handle_Value) {
	strings.write_string(b, handle.kind)
	strings.write_byte(b, '.')
	strings.write_string(b, handle.factory)
	for op in handle.ops {
		strings.write_byte(b, '.')
		strings.write_string(b, op.method)
		strings.write_byte(b, '(')
		for arg, i in op.args {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			strings.write_string(b, arg)
		}
		strings.write_byte(b, ')')
	}
}

color_text :: proc(color: Draw_Color, allocator := context.allocator) -> string {
	switch color.kind {
	case .Named:
		return fmt.aprintf("%v", color.palette, allocator = allocator)
	case .Rgb:
		b := strings.builder_make(allocator)
		strings.write_string(&b, "Rgb(")
		write_source_fixed(&b, color.r)
		strings.write_byte(&b, ',')
		write_source_fixed(&b, color.g)
		strings.write_byte(&b, ',')
		write_source_fixed(&b, color.b)
		strings.write_byte(&b, ')')
		return strings.to_string(b)
	}
	return fmt.aprintf("%v", color.palette, allocator = allocator)
}

render_draw_cmd_text :: proc(b: ^strings.Builder, cmd: Draw_Cmd) {
	switch c in cmd {
	case Draw_Rect:
		strings.write_string(b, "Rect(at=")
		write_vec2_decimal(b, c.at)
		strings.write_string(b, ",size=")
		write_vec2_decimal(b, c.size)
		fmt.sbprintf(b, ",color=Color::%s)", color_text(c.color, context.temp_allocator))
	case Draw_Text:
		strings.write_string(b, "Text(at=")
		write_vec2_decimal(b, c.at)
		fmt.sbprintf(b, ",text=L%d:%s,color=Color::%s)", len(c.text), c.text, color_text(c.color, context.temp_allocator))
	case Draw_Camera:
		strings.write_string(b, "Camera(at=")
		write_vec2_decimal(b, c.at)
		strings.write_string(b, ",zoom=")
		write_source_fixed(b, c.zoom)
		strings.write_string(b, ",rotation=")
		write_source_fixed(b, c.rotation)
		strings.write_byte(b, ')')
	case Draw3_Camera:
		strings.write_string(b, "Camera3(eye=")
		write_vec3_decimal(b, c.eye)
		strings.write_string(b, ",at=")
		write_vec3_decimal(b, c.at)
		strings.write_string(b, ",fov=")
		write_source_fixed(b, c.fov)
		strings.write_byte(b, ')')
	case Draw3_Light:
		strings.write_string(b, "Light(dir=")
		write_vec3_decimal(b, c.dir)
		fmt.sbprintf(b, ",color=Color::%s)", color_text(c.color, context.temp_allocator))
	case Draw3_Plane:
		strings.write_string(b, "Plane(at=")
		write_vec3_decimal(b, c.at)
		strings.write_string(b, ",size=")
		write_vec2_decimal(b, c.size)
		fmt.sbprintf(b, ",color=Color::%s)", color_text(c.color, context.temp_allocator))
	case Draw3_Rigged:
		strings.write_string(b, "Rigged(skeleton=")
		render_handle_text(b, c.skeleton)
		strings.write_string(b, ",parts=")
		render_handle_text(b, c.parts)
		strings.write_string(b, ",pose=")
		render_pose_text(b, c.pose)
		strings.write_string(b, ",at=")
		write_vec3_decimal(b, c.at)
		strings.write_byte(b, ')')
	case Draw_Tilemap:
		fmt.sbprintf(
			b,
			"Tilemap(name=L%d:%s,cell=%d,cols=%d,rows=%d)",
			len(c.layer.name),
			c.layer.name,
			c.layer.cell_size,
			c.layer.cols,
			c.layer.rows,
		)
	case Draw_Sprite:
		fmt.sbprintf(b, "Sprite(atlas=L%d:%s,cell=L%d:%s,at=", len(c.atlas), c.atlas, len(c.cell), c.cell)
		write_vec2_decimal(b, c.at)
		strings.write_string(b, ",size=")
		write_vec2_decimal(b, c.size)
		fmt.sbprintf(
			b,
			",tint=Color::%s,flip=L%d:%s,layer=%d)",
			color_text(c.tint, context.temp_allocator),
			len(c.flip),
			c.flip,
			c.layer,
		)
	}
}
