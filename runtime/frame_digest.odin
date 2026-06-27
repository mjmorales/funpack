package funpack_runtime

import "core:encoding/endian"
import "core:hash/xxhash"
import "core:slice"

FRAME_DIGEST_SCHEMA_VERSION :: 11

RGB_COLOR_TAG :: u8(255)

Field_Tag :: enum u8 {
	Int     = 0,
	Fixed   = 1,
	Variant = 2,
	Vec2    = 3,
	Ref     = 4,
	Bool    = 5,
	Record  = 6,
	List    = 7,
	Variant_Payload = 8,
	String = 9,
	Vec3 = 10,
	Map = 11,
}

Cmd_Tag :: enum u8 {
	Rect         = 0,
	Text         = 1,
	Camera       = 2,
	Draw3_Camera = 3,
	Draw3_Light  = 4,
	Draw3_Plane  = 5,
	Draw3_Rigged = 6,
	Tilemap      = 7,
	Sprite       = 8,
}

Frame_Digest :: struct {
	tick:   int,
	digest: u64,
}

Frame_Capture :: struct {
	per_tick: []Frame_Digest,
	session:  u64,
}

frame_bytes :: proc(
	version: World_Version,
	draw: Maybe(Draw_List),
	allocator := context.allocator,
) -> []u8 {
	buf := make([dynamic]u8, allocator)
	write_world_state(&buf, version)
	if list, has_draw := draw.?; has_draw {
		write_draw_list(&buf, list)
	}
	return buf[:]
}

frame_digest :: proc(
	version: World_Version,
	draw: Maybe(Draw_List),
	allocator := context.allocator,
) -> Frame_Digest {
	buf := frame_bytes(version, draw, allocator)
	defer delete(buf, allocator)
	return Frame_Digest{tick = version.tick, digest = u64(xxhash.XXH64(buf))}
}

FRAME_SESSION_SEED :: 2

fold_session :: proc(per_tick: []Frame_Digest, allocator := context.allocator) -> u64 {
	buf := make([dynamic]u8, allocator)
	defer delete(buf)
	put_u64_le(&buf, u64(FRAME_SESSION_SEED))
	for frame in per_tick {
		put_u64_le(&buf, u64(frame.tick))
		put_u64_le(&buf, frame.digest)
	}
	return u64(xxhash.XXH64(buf[:]))
}

@(private = "file")
write_world_state :: proc(buf: ^[dynamic]u8, version: World_Version) {
	put_u64_le(buf, u64(version.tick))
	put_u64_le(buf, u64(len(version.tables)))
	for table in version.tables {
		write_length_prefixed(buf, table.thing)
		put_u64_le(buf, u64(len(table.rows)))
		for row in table.rows {
			write_row(buf, row)
		}
	}
}

@(private = "file")
write_row :: proc(buf: ^[dynamic]u8, row: Row) {
	put_u64_le(buf, u64(row.id.raw))
	names := sorted_field_names(row.fields)
	defer delete(names)
	put_u64_le(buf, u64(len(names)))
	for name in names {
		write_length_prefixed(buf, name)
		write_field_value(buf, row.fields[name])
	}
}

@(private = "file")
sorted_field_names :: proc(fields: map[string]Field_Value) -> [dynamic]string {
	names := make([dynamic]string, 0, len(fields))
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names
}

@(private = "file")
write_field_value :: proc(buf: ^[dynamic]u8, value: Field_Value) {
	switch v in value {
	case i64:
		append(buf, u8(Field_Tag.Int))
		put_u64_le(buf, u64(v))
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		put_u64_le(buf, u64(i64(v)))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, v ? u8(1) : u8(0))
	case string:
		append(buf, u8(Field_Tag.Variant))
		write_length_prefixed(buf, v)
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		write_vec2(buf, v)
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		write_vec3(buf, v)
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		write_length_prefixed(buf, v.thing)
		put_u64_le(buf, u64(v.id.raw))
	case Record_Value:
		write_record_column(buf, v)
	case List_Value:
		write_list_column(buf, v)
	case Map_Value:
		write_map_column(buf, v)
	case Variant_Value:
		write_variant_column(buf, v)
	case String_Value:
		append(buf, u8(Field_Tag.String))
		write_length_prefixed(buf, v.text)
	}
}

@(private = "file")
write_variant_column :: proc(buf: ^[dynamic]u8, v: Variant_Value) {
	if v.payload == nil {
		append(buf, u8(Field_Tag.Variant))
		write_length_prefixed(buf, variant_to_token(v))
		return
	}
	append(buf, u8(Field_Tag.Variant_Payload))
	write_length_prefixed(buf, variant_to_token(v))
	write_column_value(buf, v.payload^)
}

@(private = "file")
write_record_column :: proc(buf: ^[dynamic]u8, rec: Record_Value) {
	append(buf, u8(Field_Tag.Record))
	write_length_prefixed(buf, rec.type_name)
	put_u64_le(buf, u64(len(rec.fields)))
	names := sorted_value_field_names(rec.fields)
	defer delete(names)
	for name in names {
		write_length_prefixed(buf, name)
		write_column_value(buf, rec.fields[name])
	}
}

@(private = "file")
write_list_column :: proc(buf: ^[dynamic]u8, list: List_Value) {
	append(buf, u8(Field_Tag.List))
	put_u64_le(buf, u64(len(list.elements)))
	for elem in list.elements {
		write_column_value(buf, elem)
	}
}

@(private = "file")
write_map_column :: proc(buf: ^[dynamic]u8, m: Map_Value) {
	append(buf, u8(Field_Tag.Map))
	put_u64_le(buf, u64(len(m.entries)))
	for entry in m.entries {
		write_column_value(buf, entry.key)
		write_column_value(buf, entry.value)
	}
}

@(private = "file")
write_column_value :: proc(buf: ^[dynamic]u8, v: Value) {
	switch x in v {
	case i64:
		append(buf, u8(Field_Tag.Int))
		put_u64_le(buf, u64(x))
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		put_u64_le(buf, u64(i64(x)))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, x ? u8(1) : u8(0))
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		write_vec2(buf, x)
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		write_vec3(buf, x)
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		write_length_prefixed(buf, x.thing)
		put_u64_le(buf, u64(x.id.raw))
	case Variant_Value:
		write_variant_column(buf, x)
	case String_Value:
		append(buf, u8(Field_Tag.String))
		write_length_prefixed(buf, x.text)
	case Record_Value:
		write_record_column(buf, x)
	case List_Value:
		write_list_column(buf, x)
	case Map_Value:
		write_map_column(buf, x)
	case Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value:
	}
}

@(private = "file")
sorted_value_field_names :: proc(fields: map[string]Value) -> [dynamic]string {
	names := make([dynamic]string, 0, len(fields))
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names
}

@(private = "file")
write_draw_list :: proc(buf: ^[dynamic]u8, draw: Draw_List) {
	put_u64_le(buf, u64(len(draw.cmds)))
	for cmd in draw.cmds {
		write_draw_cmd(buf, cmd)
	}
}

@(private = "file")
write_draw_cmd :: proc(buf: ^[dynamic]u8, cmd: Draw_Cmd) {
	switch c in cmd {
	case Draw_Rect:
		append(buf, u8(Cmd_Tag.Rect))
		write_vec2(buf, c.at)
		write_vec2(buf, c.size)
		write_color(buf, c.color)
	case Draw_Text:
		append(buf, u8(Cmd_Tag.Text))
		write_vec2(buf, c.at)
		write_length_prefixed(buf, c.text)
		write_color(buf, c.color)
	case Draw_Camera:
		append(buf, u8(Cmd_Tag.Camera))
		write_vec2(buf, c.at)
		put_u64_le(buf, u64(i64(c.zoom)))
		put_u64_le(buf, u64(i64(c.rotation)))
	case Draw3_Camera:
		append(buf, u8(Cmd_Tag.Draw3_Camera))
		write_vec3(buf, c.eye)
		write_vec3(buf, c.at)
		put_u64_le(buf, u64(i64(c.fov)))
	case Draw3_Light:
		append(buf, u8(Cmd_Tag.Draw3_Light))
		write_vec3(buf, c.dir)
		write_color(buf, c.color)
	case Draw3_Plane:
		append(buf, u8(Cmd_Tag.Draw3_Plane))
		write_vec3(buf, c.at)
		write_vec2(buf, c.size)
		write_color(buf, c.color)
	case Draw3_Rigged:
		append(buf, u8(Cmd_Tag.Draw3_Rigged))
		write_handle(buf, c.skeleton)
		write_handle(buf, c.parts)
		write_pose(buf, c.pose)
		write_vec3(buf, c.at)
	case Draw_Tilemap:
		append(buf, u8(Cmd_Tag.Tilemap))
		write_length_prefixed(buf, c.layer.name)
		put_u64_le(buf, u64(c.layer.cell_size))
		put_u64_le(buf, u64(i64(c.layer.cols)))
		put_u64_le(buf, u64(i64(c.layer.rows)))
		write_vec2(buf, c.layer.top_left)
		put_u64_le(buf, u64(len(c.layer.palette)))
		for tile in c.layer.palette {
			write_length_prefixed(buf, tile.name)
			append(buf, u8(1) if tile.solid else u8(0))
			put_u64_le(buf, u64(i64(tile.cell_x)))
			put_u64_le(buf, u64(i64(tile.cell_y)))
		}
		write_length_prefixed(buf, c.layer.atlas)
		put_u64_le(buf, u64(len(c.layer.cells)))
		for cell in c.layer.cells {
			put_u64_le(buf, u64(i64(cell)))
		}
		put_u64_le(buf, u64(len(c.palette_textures)))
		for tex in c.palette_textures {
			write_tile_texture(buf, tex)
		}
	case Draw_Sprite:
		append(buf, u8(Cmd_Tag.Sprite))
		write_length_prefixed(buf, c.atlas)
		write_length_prefixed(buf, c.cell)
		write_vec2(buf, c.at)
		write_vec2(buf, c.size)
		write_color(buf, c.tint)
		write_length_prefixed(buf, c.flip)
		put_u64_le(buf, u64(c.layer))
		write_sprite_texture(buf, c.texture)
	}
}

@(private = "file")
write_color :: proc(buf: ^[dynamic]u8, color: Draw_Color) {
	switch color.kind {
	case .Named:
		append(buf, u8(color.palette))
	case .Rgb:
		append(buf, RGB_COLOR_TAG)
		put_u64_le(buf, u64(i64(color.r)))
		put_u64_le(buf, u64(i64(color.g)))
		put_u64_le(buf, u64(i64(color.b)))
	}
}

@(private = "file")
write_sprite_texture :: proc(buf: ^[dynamic]u8, tex: Sprite_Texture) {
	append(buf, tex.resolved ? u8(1) : u8(0))
	write_length_prefixed(buf, tex.image_hash)
	put_u64_le(buf, u64(i64(tex.px_x)))
	put_u64_le(buf, u64(i64(tex.px_y)))
	put_u64_le(buf, u64(i64(tex.px_w)))
	put_u64_le(buf, u64(i64(tex.px_h)))
}

@(private = "file")
write_tile_texture :: proc(buf: ^[dynamic]u8, tex: Tile_Texture) {
	append(buf, tex.resolved ? u8(1) : u8(0))
	write_length_prefixed(buf, tex.image_hash)
	put_u64_le(buf, u64(i64(tex.px_x)))
	put_u64_le(buf, u64(i64(tex.px_y)))
	put_u64_le(buf, u64(i64(tex.px_w)))
	put_u64_le(buf, u64(i64(tex.px_h)))
}

@(private = "file")
write_vec3 :: proc(buf: ^[dynamic]u8, v: Vec3) {
	put_u64_le(buf, u64(i64(v.x)))
	put_u64_le(buf, u64(i64(v.y)))
	put_u64_le(buf, u64(i64(v.z)))
}

@(private = "file")
write_quat :: proc(buf: ^[dynamic]u8, q: Quat) {
	put_u64_le(buf, u64(i64(q.x)))
	put_u64_le(buf, u64(i64(q.y)))
	put_u64_le(buf, u64(i64(q.z)))
	put_u64_le(buf, u64(i64(q.w)))
}

@(private = "file")
write_transform :: proc(buf: ^[dynamic]u8, t: Transform_Value) {
	write_vec3(buf, t.pos)
	write_quat(buf, t.rot)
	write_vec3(buf, t.scale)
}

@(private = "file")
write_pose :: proc(buf: ^[dynamic]u8, pose: Pose_Value) {
	put_u64_le(buf, u64(len(pose.bones)))
	for driven in pose.bones {
		write_length_prefixed(buf, driven.bone)
		write_transform(buf, driven.transform)
	}
}

@(private = "file")
write_handle :: proc(buf: ^[dynamic]u8, handle: Handle_Value) {
	write_length_prefixed(buf, handle.kind)
	write_length_prefixed(buf, handle.factory)
	put_u64_le(buf, u64(len(handle.ops)))
	for op in handle.ops {
		write_length_prefixed(buf, op.method)
		put_u64_le(buf, u64(len(op.args)))
		for arg in op.args {
			write_length_prefixed(buf, arg)
		}
	}
}

@(private = "file")
write_vec2 :: proc(buf: ^[dynamic]u8, v: Vec2) {
	put_u64_le(buf, u64(i64(v.x)))
	put_u64_le(buf, u64(i64(v.y)))
}

@(private = "file")
write_length_prefixed :: proc(buf: ^[dynamic]u8, s: string) {
	put_u64_le(buf, u64(len(s)))
	append(buf, ..transmute([]u8)s)
}

@(private = "file")
put_u64_le :: proc(buf: ^[dynamic]u8, v: u64) {
	scratch: [8]u8
	_ = endian.put_u64(scratch[:], .Little, v)
	append(buf, ..scratch[:])
}

capture_frame :: proc(
	version: World_Version,
	draw: Maybe(Draw_List),
	allocator := context.allocator,
) -> Frame_Digest {
	return frame_digest(version, draw, allocator)
}

finish_capture :: proc(per_tick: []Frame_Digest, allocator := context.allocator) -> Frame_Capture {
	return Frame_Capture{per_tick = per_tick, session = fold_session(per_tick, allocator)}
}
