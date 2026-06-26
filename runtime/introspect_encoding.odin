package funpack_runtime

import "core:fmt"
import "core:slice"
import "core:strings"

// The funpack-Value → text renderer family — the §28 §2 "funpack values
// as strings" debug projection. Every observe result, probe payload, and
// draw-list dump encodes its blackboard columns, nested values, and draw
// commands through these procs, so the encoders live as one self-contained
// concern apart from the request/response fold.

// write_encoded_value JSON-quotes one interpreter Value rendered in the artifact
// literal encoding — the JSON-quoted twin of probes.odin's encode_value_text (the shared
// primitive), so a Value renders identically whether quoted here or emitted plain in an
// async-event payload.
write_encoded_value :: proc(b: ^strings.Builder, value: Value, allocator := context.allocator) {
	write_json_string(b, encode_value_text(value, allocator))
}

// write_encoded_field_value JSON-quotes one blackboard column rendered in the
// artifact literal encoding.
write_encoded_field_value :: proc(
	b: ^strings.Builder,
	value: Field_Value,
	allocator := context.allocator,
) {
	encoded := strings.builder_make(allocator)
	render_field_value_text(&encoded, value)
	write_json_string(b, strings.to_string(encoded))
}

// write_encoded_blackboard JSON-quotes one row's whole blackboard as a
// `Thing(field=enc,…)` record literal in sorted field-name order — the
// serialization-closure dump (§28 §1: dump any blackboard at any tick). The JSON-quoted
// twin of probes.odin's encode_blackboard_text (the shared primitive), so a blackboard
// renders identically whether quoted here or emitted plain in an async-event payload.
write_encoded_blackboard :: proc(
	b: ^strings.Builder,
	thing: string,
	fields: map[string]Field_Value,
	allocator := context.allocator,
) {
	write_json_string(b, encode_blackboard_text(thing, fields, allocator))
}

// sorted_blackboard_names returns a blackboard's field names in sorted order —
// the deterministic render order (map iteration order is not). Package-visible:
// the §28 §4 probe-honor serialization (probes.odin) reuses it to dump the
// breakpoint_hit/trace blackboard payload in the same deterministic order the
// observe trace renders.
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

// render_field_value_text renders one blackboard column in the §28 DEBUG PROJECTION
// — the inverse of decode_default_value(human=true), so an observe output pastes back
// as a control `set`/`spawn` payload (the observe→control round-trip). Fixed renders as its
// SOURCE-LITERAL decimal (`96.0` — float-free via write_source_fixed, the legible form
// an agent reads and writes), Vec2/Vec3 as their component constructors with decimal
// lanes, a record as `Type(f=enc,…)` sorted, a list as `[enc,…]`, a unit-variant token
// verbatim, a String as `Lk:bytes`. This is the debug surface, NOT the committed
// `.artifact` wire format (spec §16 §2.3, raw Q32.32) — that is the compiler's
// emit.odin, which this renderer never feeds.
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

// render_map_text renders an engine.map Map column in the §28 debug projection as
// `Map{k:v,…}` in insertion order — the deterministic order the value carries, shared
// by the Field_Value and nested-Value renderers so a Map renders identically wherever
// it appears.
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

// write_vec2_decimal / write_vec3_decimal render a §10 vector with SOURCE-LITERAL
// Fixed components (`Vec2(x=96.0,y=90.0)`) — the debug projection, legible at a
// glance instead of the raw Q32.32 lanes the artifact codec carried. They round-trip
// through decode_fixed(human=true), so an observed vector pastes back as a control
// payload. Both lanes go through write_source_fixed: float-free, byte-stable.
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

// render_value_text renders one interpreter Value in the §28 debug projection
// (Fixed as a source-literal decimal — see render_field_value_text). The transient
// arms a blackboard never carries (lambda, tuple, Rng, the anim values) render as
// readable opaque forms — they appear only in trace results, never in a control
// payload.
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
		// An engine.map Map renders its key->value pairs in insertion order, the same
		// shape a Map COLUMN renders (render_map_text) — readable in a §28 trace.
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
		// A §12 fixture nav handle (Nav.of/Nav.fail) — a behavior-test stand-in,
		// never a blackboard column; renders as a readable opaque form like the
		// other transient arms (it appears only in a trace result).
		fmt.sbprintf(b, "<nav failed=%v>", v.failed)
	case:
		// A nil Value (an unbound read) renders as the explicit absence token.
		strings.write_string(b, "<none>")
	}
}

// render_record_text renders a record literal `Type(f=enc,…)` in sorted
// field-name order; an anonymous record (a boxed variant payload) renders with
// an empty constructor name.
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

// render_list_text renders a `[enc,…]` list literal in element order.
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

// render_variant_text renders an enum value: the bare `Enum::Case` token for a
// unit variant, `Enum::Case(payload)` for a payload-carrying one (a boxed record
// payload renders its parenthesized fields, matching the §16 struct-variant form).
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

// render_transform_text renders a §16 §7 bone transform with SOURCE-LITERAL decimal
// lanes (the debug projection — see render_field_value_text). Every Q32.32 lane
// (pos/rot/scale, and the quat's w) goes through write_source_fixed: float-free,
// byte-stable, legible.
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

// render_pose_text renders the sparse Bone→Transform pose in its deterministic
// driven-bone order.
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

// render_handle_text renders an opaque anim handle as its builder log —
// `Skeleton.humanoid.bind(…)…` — the §03 identity the handle compares by.
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

// color_text renders the BODY of a §20 §1 Draw_Color for the draw-list dump's
// `Color::<body>` projection — the part after the `Color::` prefix the §28
// inspect_draw_list line carries. A NAMED color renders as its palette member name
// (`White`, `Gray` — so the existing `Color::White` line shape is unchanged after
// Draw_Color stopped being a bare enum that `%v` printed directly). A Color::Rgb
// renders as `Rgb(<r>,<g>,<b>)` with SOURCE-LITERAL decimal channels (the SAME
// write_source_fixed convention the Vec2 decimal lanes use here), so the dump is
// deterministic — no float, byte-stable across machines. The string is built in
// the supplied allocator (temp at the call site). DETERMINISM: this is a §28
// OBSERVE projection (a read-only string view of the draw-list), never re-entering
// the sim.
color_text :: proc(color: Draw_Color, allocator := context.allocator) -> string {
	switch color.kind {
	case .Named:
		return fmt.aprintf("%v", color.palette, allocator = allocator)
	case .Rgb:
		// Source-literal decimal channels (`Rgb(1.0,0.5,0.0)`) — the legible
		// projection, float-free via write_source_fixed, byte-stable across machines.
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

// render_draw_cmd_text renders one §20 draw command in the same constructor
// style the value encoding uses — the draw-list dump's line items. Every Q32.32 lane
// (every Vec2/Vec3 component and the scalar Fixed fields zoom/rotation/fov) renders as
// a SOURCE-LITERAL decimal via write_source_fixed: an inspect_draw_list line reads
// `Rect(at=Vec2(x=96.0,y=90.0),…)`, not the raw Q32.32 bits. Int lanes (Tilemap geometry,
// Sprite layer) stay decimal integers. The render stays float-free and byte-stable.
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
		// The batched §18 §3 layer dumps as its identity + geometry — the cell
		// content is the artifact's static table (and the digest's full fold),
		// so the line stays a readable item, not an inlined grid.
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
		// The §18 §1 entity sprite dumps its complete lowered state — the atlas
		// NAME, cell key, at/size, tint, flip token, and layer — the same fields
		// the digest folds, so the draw-list dump names what diverged.
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
