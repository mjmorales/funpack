package funpack_runtime

Draw_Palette :: enum u8 {
	White,
	Black,
	Red,
	Green,
	Blue,
	Yellow,
	Cyan,
	Magenta,
	Gray,
}

Draw_Color_Kind :: enum u8 {
	Named,
	Rgb,
}

Draw_Color :: struct {
	kind:    Draw_Color_Kind,
	palette: Draw_Palette,
	r:       Fixed,
	g:       Fixed,
	b:       Fixed,
}

named_color :: proc(palette: Draw_Palette) -> Draw_Color {
	return Draw_Color{kind = .Named, palette = palette}
}

rgb_color :: proc(r, g, b: Fixed) -> Draw_Color {
	return Draw_Color{kind = .Rgb, r = r, g = g, b = b}
}

Draw_Rect :: struct {
	at:    Vec2,
	size:  Vec2,
	color: Draw_Color,
}

Draw_Text :: struct {
	at:    Vec2,
	text:  string,
	color: Draw_Color,
}

Draw_Camera :: struct {
	at:       Vec2,
	zoom:     Fixed,
	rotation: Fixed,
}

Draw3_Camera :: struct {
	eye: Vec3,
	at:  Vec3,
	fov: Fixed,
}

Draw3_Light :: struct {
	dir:   Vec3,
	color: Draw_Color,
}

Draw3_Plane :: struct {
	at:    Vec3,
	size:  Vec2,
	color: Draw_Color,
}

Draw3_Rigged :: struct {
	skeleton: Handle_Value,
	parts:    Handle_Value,
	pose:     Pose_Value,
	at:       Vec3,
}

Draw_Tilemap :: struct {
	layer:            Tile_Layer,
	palette_textures: []Tile_Texture,
}

Tile_Texture :: struct {
	resolved:   bool,
	image_hash: string,
	px_x:       int,
	px_y:       int,
	px_w:       int,
	px_h:       int,
}

Draw_Sprite :: struct {
	atlas:   string,
	cell:    string,
	at:      Vec2,
	size:    Vec2,
	tint:    Draw_Color,
	flip:    string,
	layer:   i64,
	texture: Sprite_Texture,
}

Sprite_Texture :: struct {
	resolved:   bool,
	image_hash: string,
	px_x:       int,
	px_y:       int,
	px_w:       int,
	px_h:       int,
}

Draw_Cmd :: union {
	Draw_Rect,
	Draw_Text,
	Draw_Camera,
	Draw3_Camera,
	Draw3_Light,
	Draw3_Plane,
	Draw3_Rigged,
	Draw_Tilemap,
	Draw_Sprite,
}

Draw_List :: struct {
	cmds: []Draw_Cmd,
}

draw_cmd_equal :: proc(a, b: Draw_Cmd) -> bool {
	switch x in a {
	case Draw_Rect:
		y, ok := b.(Draw_Rect)
		return ok && x == y
	case Draw_Text:
		y, ok := b.(Draw_Text)
		return ok && x == y
	case Draw_Camera:
		y, ok := b.(Draw_Camera)
		return ok && x == y
	case Draw3_Camera:
		y, ok := b.(Draw3_Camera)
		return ok && x == y
	case Draw3_Light:
		y, ok := b.(Draw3_Light)
		return ok && x == y
	case Draw3_Plane:
		y, ok := b.(Draw3_Plane)
		return ok && x == y
	case Draw3_Rigged:
		y, ok := b.(Draw3_Rigged)
		if !ok {
			return false
		}
		return(
			handles_equal(x.skeleton, y.skeleton) &&
			handles_equal(x.parts, y.parts) &&
			poses_equal(x.pose, y.pose) &&
			x.at == y.at \
		)
	case Draw_Tilemap:
		y, ok := b.(Draw_Tilemap)
		if !ok || !tile_layers_equal(x.layer, y.layer) {
			return false
		}
		if len(x.palette_textures) != len(y.palette_textures) {
			return false
		}
		for tex, i in x.palette_textures {
			if tex != y.palette_textures[i] {
				return false
			}
		}
		return true
	case Draw_Sprite:
		y, ok := b.(Draw_Sprite)
		return ok && x == y
	}
	return a == nil && b == nil
}

render_version :: proc(
	program: ^Program,
	version: World_Version,
	input: Input,
	time: Record_Value,
	allocator := context.allocator,
	obs: ^Tick_Observe = nil,
	overlay := false,
) -> Draw_List {
	committed := version
	interp := new_interp(program, &committed, nil, input, time, allocator)

	cmds := make([dynamic]Draw_Cmd, allocator)
	for &layer in version.tilemaps {
		append(&cmds, Draw_Tilemap{layer = layer})
	}
	project_stage(&interp, program, "render", &cmds, draw_command_from_record, obs)
	if overlay {
		append_overlay_commands(&cmds, version)
	}
	resolve_sprite_textures(program, cmds[:])
	resolve_tilemap_textures(program, cmds[:], allocator)
	return Draw_List{cmds = cmds[:]}
}

append_overlay_commands :: proc(cmds: ^[dynamic]Draw_Cmd, version: World_Version) {
	v := version
	for table in v.tables {
		for row in table.rows {
			pos_field, has_pos := row.fields["pos"]
			if !has_pos {
				continue
			}
			pos, pos_ok := pos_field.(Vec2)
			if !pos_ok {
				continue
			}
			marker := to_fixed(2)
			append(cmds, Draw_Rect{at = pos, size = Vec2{marker, marker}, color = named_color(.Magenta)})

			size_field, has_size := row.fields["size"]
			if !has_size {
				continue
			}
			size, size_ok := size_field.(Vec2)
			if !size_ok {
				continue
			}
			half_x := fixed_div(size.x, to_fixed(2))
			half_y := fixed_div(size.y, to_fixed(2))
			thick := to_fixed(1)
			append(cmds, Draw_Rect{at = Vec2{pos.x, fixed_sub(pos.y, half_y)}, size = Vec2{size.x, thick}, color = named_color(.Magenta)})
			append(cmds, Draw_Rect{at = Vec2{pos.x, fixed_add(pos.y, half_y)}, size = Vec2{size.x, thick}, color = named_color(.Magenta)})
			append(cmds, Draw_Rect{at = Vec2{fixed_sub(pos.x, half_x), pos.y}, size = Vec2{thick, size.y}, color = named_color(.Magenta)})
			append(cmds, Draw_Rect{at = Vec2{fixed_add(pos.x, half_x), pos.y}, size = Vec2{thick, size.y}, color = named_color(.Magenta)})
		}
	}
}

render_overlay_commands :: proc(version: World_Version, allocator := context.allocator) -> []Draw_Cmd {
	cmds := make([dynamic]Draw_Cmd, allocator)
	append_overlay_commands(&cmds, version)
	return cmds[:]
}

resolve_tilemap_textures :: proc(program: ^Program, cmds: []Draw_Cmd, allocator := context.allocator) {
	for &cmd in cmds {
		tilemap, is_tilemap := &cmd.(Draw_Tilemap)
		if !is_tilemap {
			continue
		}
		textures := make([]Tile_Texture, len(tilemap.layer.palette), allocator)
		for tile, i in tilemap.layer.palette {
			image, region, ok := tile_cell_rect(program, tilemap.layer.atlas, tile.cell_x, tile.cell_y)
			if !ok {
				textures[i] = Tile_Texture{}
				continue
			}
			textures[i] = Tile_Texture {
				resolved   = true,
				image_hash = image.hash,
				px_x       = region.px_x,
				px_y       = region.px_y,
				px_w       = region.px_w,
				px_h       = region.px_h,
			}
		}
		tilemap.palette_textures = textures
	}
}

resolve_sprite_textures :: proc(program: ^Program, cmds: []Draw_Cmd) {
	for &cmd in cmds {
		sprite, is_sprite := &cmd.(Draw_Sprite)
		if !is_sprite {
			continue
		}
		image, region, ok := asset_region(program, sprite.atlas, sprite.cell)
		if !ok {
			sprite.texture = Sprite_Texture{}
			continue
		}
		sprite.texture = Sprite_Texture {
			resolved   = true,
			image_hash = image.hash,
			px_x       = region.px_x,
			px_y       = region.px_y,
			px_w       = region.px_w,
			px_h       = region.px_h,
		}
	}
}

projection_behavior_env :: proc(interp: ^Interp, behavior: ^Behavior_Decl, self_row: Row) -> Env {
	env := Env{names = make(map[string]Value, interp.allocator)}
	for param in behavior.params {
		switch param.type {
		case "Input":
			env.names[param.name] = input_marker(interp)
		case "Time":
			env.names[param.name] = interp.time
		case:
			env.names[param.name] = row_to_record(interp, self_row)
		}
	}
	return env
}

project_stage :: proc(
	interp: ^Interp,
	program: ^Program,
	stage: string,
	out: ^[dynamic]$T,
	lower: proc(record: Record_Value) -> (T, bool),
	obs: ^Tick_Observe = nil,
) {
	for step in program.pipeline {
		if step.stage != stage {
			continue
		}
		behavior := program_behavior(program, step.behavior)
		if behavior == nil {
			continue
		}
		view := view_of_type(interp.version, behavior.on_thing)
		for i in 0 ..< view_count(view) {
			row, _ := view_at(view, i)
			env := projection_behavior_env(interp, behavior, row)
			result, ok := eval_behavior_body(interp, behavior.body, &env)
			if obs != nil {
				observe_behavior_step(obs, step, behavior, row, env, result, ok)
			}
			if !ok {
				continue
			}
			fold_emitted_list(out, result, lower)
		}
	}
}

fold_emitted_list :: proc(out: ^[dynamic]$T, result: Value, lower: proc(record: Record_Value) -> (T, bool)) {
	list, is_list := result.(List_Value)
	if !is_list {
		return
	}
	for elem in list.elements {
		record, is_record := elem.(Record_Value)
		if !is_record {
			continue
		}
		if v, ok := lower(record); ok {
			append(out, v)
		}
	}
}

append_draw_commands :: proc(cmds: ^[dynamic]Draw_Cmd, result: Value) {
	fold_emitted_list(cmds, result, draw_command_from_record)
}

draw_command_from_record :: proc(record: Record_Value) -> (cmd: Draw_Cmd, ok: bool) {
	switch record.type_name {
	case "Draw::Rect":
		at, at_ok := record_vec2(record, "at")
		size, size_ok := record_vec2(record, "size")
		color, color_ok := record_color(record, "color")
		if !at_ok || !size_ok || !color_ok {
			return nil, false
		}
		return Draw_Rect{at = at, size = size, color = color}, true
	case "Draw::Text":
		at, at_ok := record_vec2(record, "at")
		text, text_ok := record_text(record, "text")
		color, color_ok := record_color(record, "color")
		if !at_ok || !text_ok || !color_ok {
			return nil, false
		}
		return Draw_Text{at = at, text = text, color = color}, true
	case "Draw::Camera":
		at, at_ok := record_vec2(record, "at")
		if !at_ok {
			return nil, false
		}
		zoom := record_fixed(record, "zoom")
		rotation := record_fixed(record, "rotation")
		return Draw_Camera{at = at, zoom = zoom, rotation = rotation}, true
	case "Draw3::Camera":
		eye, eye_ok := record_vec3(record, "eye")
		at, at_ok := record_vec3(record, "at")
		if !eye_ok || !at_ok {
			return nil, false
		}
		fov := record_fixed(record, "fov")
		return Draw3_Camera{eye = eye, at = at, fov = fov}, true
	case "Draw3::Light":
		dir, dir_ok := record_vec3(record, "dir")
		color, color_ok := record_color(record, "color")
		if !dir_ok || !color_ok {
			return nil, false
		}
		return Draw3_Light{dir = dir, color = color}, true
	case "Draw3::Plane":
		at, at_ok := record_vec3(record, "at")
		size, size_ok := record_vec2(record, "size")
		color, color_ok := record_color(record, "color")
		if !at_ok || !size_ok || !color_ok {
			return nil, false
		}
		return Draw3_Plane{at = at, size = size, color = color}, true
	case "Draw3::Rigged":
		skeleton, sk_ok := record_handle(record, "skeleton")
		parts, pt_ok := record_handle(record, "parts")
		pose, pose_ok := record_pose(record, "pose")
		at, at_ok := record_vec3(record, "at")
		if !sk_ok || !pt_ok || !pose_ok || !at_ok {
			return nil, false
		}
		return Draw3_Rigged{skeleton = skeleton, parts = parts, pose = pose, at = at}, true
	case "Draw::Sprite":
		atlas, atlas_ok := record_handle_name(record, "atlas")
		cell, cell_ok := record_text(record, "cell")
		at, at_ok := record_vec2(record, "at")
		size, size_ok := record_vec2(record, "size")
		tint, tint_ok := record_color(record, "tint")
		flip, flip_ok := record_variant_token(record, "flip")
		layer, layer_ok := record_int(record, "layer")
		if !atlas_ok || !cell_ok || !at_ok || !size_ok || !tint_ok || !flip_ok || !layer_ok {
			return nil, false
		}
		return Draw_Sprite {
				atlas = atlas,
				cell = cell,
				at = at,
				size = size,
				tint = tint,
				flip = flip,
				layer = layer,
			},
			true
	}
	return nil, false
}

record_vec2 :: proc(record: Record_Value, name: string) -> (v: Vec2, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return VEC2_ZERO, false
	}
	vec, is_vec := field.(Vec2)
	return vec, is_vec
}

record_vec3 :: proc(record: Record_Value, name: string) -> (v: Vec3, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return Vec3{}, false
	}
	vec, is_vec := field.(Vec3)
	return vec, is_vec
}

record_handle :: proc(record: Record_Value, name: string) -> (h: Handle_Value, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return Handle_Value{}, false
	}
	handle, is_handle := field.(Handle_Value)
	return handle, is_handle
}

record_pose :: proc(record: Record_Value, name: string) -> (p: Pose_Value, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return Pose_Value{}, false
	}
	pose, is_pose := field.(Pose_Value)
	return pose, is_pose
}

record_fixed :: proc(record: Record_Value, name: string) -> Fixed {
	field, present := record.fields[name]
	if !present {
		return Fixed(0)
	}
	value, is_fixed := field.(Fixed)
	if !is_fixed {
		return Fixed(0)
	}
	return value
}

record_text :: proc(record: Record_Value, name: string) -> (text: string, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return "", false
	}
	str, is_str := field.(String_Value)
	if !is_str {
		return "", false
	}
	return str.text, true
}

record_handle_name :: proc(record: Record_Value, name: string) -> (atlas: string, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return "", false
	}
	return handle_value_name(field)
}

record_variant_token :: proc(record: Record_Value, name: string) -> (token: string, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return "", false
	}
	variant, is_variant := field.(Variant_Value)
	if !is_variant {
		return "", false
	}
	return variant.case_name, true
}

record_int :: proc(record: Record_Value, name: string) -> (value: i64, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return 0, false
	}
	v, is_int := field.(i64)
	return v, is_int
}

record_color :: proc(record: Record_Value, name: string) -> (color: Draw_Color, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return named_color(.White), true
	}
	if rgb_record, is_record := field.(Record_Value); is_record && rgb_record.type_name == "Color::Rgb" {
		r, r_ok := record_color_channel(rgb_record, "r")
		g, g_ok := record_color_channel(rgb_record, "g")
		b, b_ok := record_color_channel(rgb_record, "b")
		if !r_ok || !g_ok || !b_ok {
			return named_color(.White), false
		}
		return rgb_color(r, g, b), true
	}
	variant, is_variant := field.(Variant_Value)
	if !is_variant {
		return named_color(.White), false
	}
	switch variant.case_name {
	case "White":
		return named_color(.White), true
	case "Black":
		return named_color(.Black), true
	case "Red":
		return named_color(.Red), true
	case "Green":
		return named_color(.Green), true
	case "Blue":
		return named_color(.Blue), true
	case "Yellow":
		return named_color(.Yellow), true
	case "Cyan":
		return named_color(.Cyan), true
	case "Magenta":
		return named_color(.Magenta), true
	case "Gray":
		return named_color(.Gray), true
	}
	return named_color(.White), false
}

record_color_channel :: proc(record: Record_Value, name: string) -> (value: Fixed, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return Fixed(0), false
	}
	v, is_fixed := field.(Fixed)
	return v, is_fixed
}
