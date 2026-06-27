package funpack_runtime

TILE_CELL_EMPTY :: -1

Tile_Def :: struct {
	name:   string,
	solid:  bool,
	cell_x: int,
	cell_y: int,
}

Tile_Layer :: struct {
	name:      string,
	cell_size: i64,
	cols:      int,
	rows:      int,
	top_left:  Vec2,
	atlas:     string,
	palette:   []Tile_Def,
	cells:     []int,
}

program_tilemap :: proc(program: ^Program, name: string) -> ^Tile_Layer {
	for &layer in program.tilemaps {
		if layer.name == name {
			return &layer
		}
	}
	return nil
}

version_tilemap :: proc(version: ^World_Version, name: string) -> ^Tile_Layer {
	if version == nil {
		return nil
	}
	for &layer in version.tilemaps {
		if layer.name == name {
			return &layer
		}
	}
	return nil
}

tile_layers_equal :: proc(a, b: Tile_Layer) -> bool {
	if a.name != b.name ||
	   a.cell_size != b.cell_size ||
	   a.cols != b.cols ||
	   a.rows != b.rows ||
	   a.top_left != b.top_left ||
	   a.atlas != b.atlas {
		return false
	}
	if len(a.palette) != len(b.palette) || len(a.cells) != len(b.cells) {
		return false
	}
	for tile, i in a.palette {
		if tile != b.palette[i] {
			return false
		}
	}
	for cell, i in a.cells {
		if cell != b.cells[i] {
			return false
		}
	}
	return true
}

tilemap_tile_at :: proc(layer: ^Tile_Layer, col, row: int) -> (name: string, has: bool) {
	if col < 0 || col >= layer.cols || row < 0 || row >= layer.rows {
		return "", false
	}
	index := layer.cells[row * layer.cols + col]
	if index == TILE_CELL_EMPTY {
		return "", false
	}
	if index < 0 || index >= len(layer.palette) {
		return "", false
	}
	return layer.palette[index].name, true
}

tilemap_solid_at :: proc(layer: ^Tile_Layer, col, row: int) -> bool {
	if col < 0 || col >= layer.cols || row < 0 || row >= layer.rows {
		return false
	}
	index := layer.cells[row * layer.cols + col]
	if index < 0 || index >= len(layer.palette) {
		return false
	}
	return layer.palette[index].solid
}

tilemap_cell_of :: proc(layer: ^Tile_Layer, pos: Vec2) -> (col, row: i64) {
	cell_bits := i64(to_fixed(layer.cell_size))
	dx_bits := i64(fixed_sub(pos.x, layer.top_left.x))
	dy_bits := i64(fixed_sub(layer.top_left.y, pos.y))
	return floor_div(dx_bits, cell_bits), floor_div(dy_bits, cell_bits)
}

tilemap_center_of :: proc(layer: ^Tile_Layer, col, row: i64) -> Vec2 {
	half := fixed_div(to_fixed(layer.cell_size), to_fixed(2))
	x := fixed_add(layer.top_left.x, fixed_add(to_fixed(int_mul(col, layer.cell_size)), half))
	y := fixed_sub(layer.top_left.y, fixed_add(to_fixed(int_mul(row, layer.cell_size)), half))
	return Vec2{x = x, y = y}
}

SEGMENT_COORD_LIMIT: i128 : 1 << 62

tilemap_segment_clear :: proc(layer: ^Tile_Layer, from, to: Vec2) -> bool {
	cell := i128(i64(to_fixed(layer.cell_size)))
	u0 := i128(i64(from.x)) - i128(i64(layer.top_left.x))
	v0 := i128(i64(layer.top_left.y)) - i128(i64(from.y))
	u1 := i128(i64(to.x)) - i128(i64(layer.top_left.x))
	v1 := i128(i64(layer.top_left.y)) - i128(i64(to.y))
	if !segment_coord_ok(u0) ||
	   !segment_coord_ok(v0) ||
	   !segment_coord_ok(u1) ||
	   !segment_coord_ok(v1) ||
	   cell > SEGMENT_COORD_LIMIT {
		return false
	}
	if u1 < u0 {
		u0, u1 = u1, u0
		v0, v1 = v1, v0
	}
	du := u1 - u0
	dv := v1 - v0
	den: i128 = 1
	if du != 0 {
		den = du
	}
	row_den := cell * den
	c_lo := ceil_div(u0, cell) - 1
	c_hi := floor_div(u1, cell)
	if c_lo < 0 {
		c_lo = 0
	}
	if c_hi > i128(layer.cols - 1) {
		c_hi = i128(layer.cols - 1)
	}
	for c := c_lo; c <= c_hi; c += 1 {
		vmin_num, vmax_num: i128
		if du == 0 {
			vmin_num = min(v0, v1)
			vmax_num = max(v0, v1)
		} else {
			p_enter := c * cell - u0
			if p_enter < 0 {
				p_enter = 0
			}
			p_exit := (c + 1) * cell - u0
			if p_exit > du {
				p_exit = du
			}
			va := v0 * du + p_enter * dv
			vb := v0 * du + p_exit * dv
			vmin_num = min(va, vb)
			vmax_num = max(va, vb)
		}
		r_lo := ceil_div(vmin_num, row_den) - 1
		r_hi := floor_div(vmax_num, row_den)
		if r_lo < 0 {
			r_lo = 0
		}
		if r_hi > i128(layer.rows - 1) {
			r_hi = i128(layer.rows - 1)
		}
		for r := r_lo; r <= r_hi; r += 1 {
			if tilemap_solid_at(layer, int(c), int(r)) {
				return false
			}
		}
	}
	return true
}

segment_coord_ok :: proc(coord: i128) -> bool {
	return coord >= -SEGMENT_COORD_LIMIT && coord <= SEGMENT_COORD_LIMIT
}

floor_div :: proc(a, b: $T) -> T {
	q := a / b
	if a % b != 0 && (a < 0) != (b < 0) {
		q -= 1
	}
	return q
}

ceil_div :: proc(a, b: $T) -> T {
	q := a / b
	if a % b != 0 && (a < 0) == (b < 0) {
		q += 1
	}
	return q
}

eval_tilemap_method :: proc(
	interp: ^Interp,
	node: ^Node,
	env: ^Env,
	handle: Record_Value,
	method: string,
) -> (
	value: Value,
	ok: bool,
	is_tilemap_method: bool,
) {
	switch method {
	case "tile_at", "solid_at", "cell_of", "center_of":
	case:
		return nil, false, false
	}
	layer := tilemap_of_handle(interp, handle)
	if layer == nil || len(node.children) != 2 {
		return nil, false, true
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false, true
	}

	switch method {
	case "tile_at":
		col, row, cell_ok := cell_arg(arg)
		if !cell_ok {
			return nil, false, true
		}
		name, has := tilemap_tile_at(layer, col, row)
		if !has {
			return none_value(), true, true
		}
		return some_value(interp, String_Value{text = name}), true, true
	case "solid_at":
		col, row, cell_ok := cell_arg(arg)
		if !cell_ok {
			return nil, false, true
		}
		return tilemap_solid_at(layer, col, row), true, true
	case "cell_of":
		pos, is_vec2 := arg.(Vec2)
		if !is_vec2 {
			return nil, false, true
		}
		col, row := tilemap_cell_of(layer, pos)
		return cell_value(interp, col, row), true, true
	case "center_of":
		col, row, cell_ok := cell_arg(arg)
		if !cell_ok {
			return nil, false, true
		}
		return tilemap_center_of(layer, i64(col), i64(row)), true, true
	}
	return nil, false, true
}

tilemap_of_handle :: proc(interp: ^Interp, handle: Record_Value) -> ^Tile_Layer {
	name, ok := tilemap_handle_name(handle)
	if !ok {
		return nil
	}
	return version_tilemap(interp.version, name)
}

tilemap_handle_name :: proc(handle: Record_Value) -> (name: string, ok: bool) {
	return record_name_field(handle, "name")
}

cell_arg :: proc(arg: Value) -> (col, row: int, ok: bool) {
	cell, is_record := arg.(Record_Value)
	if !is_record {
		return 0, 0, false
	}
	x, x_present := cell.fields["x"]
	y, y_present := cell.fields["y"]
	if !x_present || !y_present {
		return 0, 0, false
	}
	xi, x_is_int := x.(i64)
	yi, y_is_int := y.(i64)
	if !x_is_int || !y_is_int {
		return 0, 0, false
	}
	return int(xi), int(yi), true
}

cell_value :: proc(interp: ^Interp, col, row: i64) -> Value {
	fields := make(map[string]Value, interp.allocator)
	fields["x"] = col
	fields["y"] = row
	return Record_Value{type_name = "Cell", fields = fields}
}

Terrain_Command_Kind :: enum {
	Set_Tile,
	Build_Layer,
}

Terrain_Command :: struct {
	kind:   Terrain_Command_Kind,
	record: Record_Value,
}

Tile_Command_Refusal_Kind :: enum {
	Malformed_Command,
	Unknown_Layer,
	Unknown_Tile,
	Cell_Out_Of_Grid,
}

Tile_Command_Refusal :: struct {
	command: Terrain_Command_Kind,
	kind:    Tile_Command_Refusal_Kind,
	layer:   string,
	tile:    string,
	col:     int,
	row:     int,
}

tilemap_palette_index :: proc(layer: ^Tile_Layer, tile: string) -> int {
	for def, i in layer.palette {
		if def.name == tile {
			return i
		}
	}
	return -1
}

fold_tile_layers :: proc(prior: World_Version, state: ^Tick_State) -> []Tile_Layer {
	if len(state.terrain_commands) == 0 {
		return prior.tilemaps
	}
	layers := make([]Tile_Layer, len(prior.tilemaps), state.commit_allocator)
	copy(layers, prior.tilemaps)
	fresh := make([]bool, len(layers), state.allocator)

	for command in state.terrain_commands {
		switch command.kind {
		case .Set_Tile:
			settile_apply(command.record, layers, fresh, state)
		case .Build_Layer:
			buildlayer_apply(command.record, layers, fresh, state)
		}
	}
	return layers
}

settile_apply :: proc(record: Record_Value, layers: []Tile_Layer, fresh: []bool, state: ^Tick_State) {
	layer_name, cell, tile, shape_ok := settile_command_parts(record)
	if !shape_ok {
		append(&state.tile_refusals, Tile_Command_Refusal{command = .Set_Tile, kind = .Malformed_Command, layer = layer_name})
		return
	}
	index := find_layer_index(layers, layer_name)
	if index < 0 {
		append(&state.tile_refusals, Tile_Command_Refusal{command = .Set_Tile, kind = .Unknown_Layer, layer = layer_name, tile = tile, col = cell.x, row = cell.y})
		return
	}
	layer := &layers[index]
	palette := tilemap_palette_index(layer, tile)
	if palette < 0 {
		append(&state.tile_refusals, Tile_Command_Refusal{command = .Set_Tile, kind = .Unknown_Tile, layer = layer_name, tile = tile, col = cell.x, row = cell.y})
		return
	}
	if cell.x < 0 || cell.x >= layer.cols || cell.y < 0 || cell.y >= layer.rows {
		append(&state.tile_refusals, Tile_Command_Refusal{command = .Set_Tile, kind = .Cell_Out_Of_Grid, layer = layer_name, tile = tile, col = cell.x, row = cell.y})
		return
	}
	cow_layer_cells(layer, index, fresh, state)
	layer.cells[cell.y * layer.cols + cell.x] = palette
}

buildlayer_apply :: proc(record: Record_Value, layers: []Tile_Layer, fresh: []bool, state: ^Tick_State) {
	layer_name, fill, overrides, shape_ok := buildlayer_command_parts(record, state.allocator)
	if !shape_ok {
		append(&state.tile_refusals, Tile_Command_Refusal{command = .Build_Layer, kind = .Malformed_Command, layer = layer_name})
		return
	}
	index := find_layer_index(layers, layer_name)
	if index < 0 {
		append(&state.tile_refusals, Tile_Command_Refusal{command = .Build_Layer, kind = .Unknown_Layer, layer = layer_name, tile = fill})
		return
	}
	layer := &layers[index]
	fill_index := tilemap_palette_index(layer, fill)
	if fill_index < 0 {
		append(&state.tile_refusals, Tile_Command_Refusal{command = .Build_Layer, kind = .Unknown_Tile, layer = layer_name, tile = fill})
		return
	}
	override_indices := make([]int, len(overrides), state.allocator)
	for override, i in overrides {
		override_index := tilemap_palette_index(layer, override.tile)
		if override_index < 0 {
			append(&state.tile_refusals, Tile_Command_Refusal{command = .Build_Layer, kind = .Unknown_Tile, layer = layer_name, tile = override.tile, col = override.cell.x, row = override.cell.y})
			return
		}
		if override.cell.x < 0 || override.cell.x >= layer.cols || override.cell.y < 0 || override.cell.y >= layer.rows {
			append(&state.tile_refusals, Tile_Command_Refusal{command = .Build_Layer, kind = .Cell_Out_Of_Grid, layer = layer_name, tile = override.tile, col = override.cell.x, row = override.cell.y})
			return
		}
		override_indices[i] = override_index
	}
	cow_layer_cells(layer, index, fresh, state)
	for i in 0 ..< len(layer.cells) {
		layer.cells[i] = fill_index
	}
	for override, i in overrides {
		layer.cells[override.cell.y * layer.cols + override.cell.x] = override_indices[i]
	}
}

find_layer_index :: proc(layers: []Tile_Layer, name: string) -> int {
	for &layer, i in layers {
		if layer.name == name {
			return i
		}
	}
	return -1
}

cow_cells :: proc(layer: ^Tile_Layer, index: int, fresh: []bool, allocator := context.allocator) {
	if fresh[index] {
		return
	}
	cells := make([]int, len(layer.cells), allocator)
	copy(cells, layer.cells)
	layer.cells = cells
	fresh[index] = true
}

cow_layer_cells :: proc(layer: ^Tile_Layer, index: int, fresh: []bool, state: ^Tick_State) {
	cow_cells(layer, index, fresh, state.commit_allocator)
}

Settile_Cell :: struct {
	x: int,
	y: int,
}

settile_command_parts :: proc(command: Record_Value) -> (layer: string, cell: Settile_Cell, tile: string, ok: bool) {
	map_field, has_map := command.fields["map"]
	if !has_map {
		return "", {}, "", false
	}
	handle, is_record := map_field.(Record_Value)
	if !is_record {
		return "", {}, "", false
	}
	name, name_ok := tilemap_handle_name(handle)
	if !name_ok {
		return "", {}, "", false
	}
	cell_field, has_cell := command.fields["cell"]
	if !has_cell {
		return name, {}, "", false
	}
	col, row, cell_ok := cell_arg(cell_field)
	if !cell_ok {
		return name, {}, "", false
	}
	tile_field, has_tile := command.fields["tile"]
	if !has_tile {
		return name, {}, "", false
	}
	text, is_string := tile_field.(String_Value)
	if !is_string {
		return name, {}, "", false
	}
	return name, Settile_Cell{x = col, y = row}, text.text, true
}

Buildlayer_Override :: struct {
	cell: Settile_Cell,
	tile: string,
}

buildlayer_command_parts :: proc(
	command: Record_Value,
	allocator := context.allocator,
) -> (layer: string, fill: string, overrides: []Buildlayer_Override, ok: bool) {
	map_field, has_map := command.fields["map"]
	if !has_map {
		return "", "", nil, false
	}
	handle, is_record := map_field.(Record_Value)
	if !is_record {
		return "", "", nil, false
	}
	name, name_ok := tilemap_handle_name(handle)
	if !name_ok {
		return "", "", nil, false
	}
	fill_field, has_fill := command.fields["fill"]
	if !has_fill {
		return name, "", nil, false
	}
	fill_text, fill_is_string := fill_field.(String_Value)
	if !fill_is_string {
		return name, "", nil, false
	}
	cells_field, has_cells := command.fields["cells"]
	if !has_cells {
		return name, fill_text.text, nil, false
	}
	list, is_list := cells_field.(List_Value)
	if !is_list {
		return name, fill_text.text, nil, false
	}
	parsed := make([dynamic]Buildlayer_Override, allocator)
	for elem in list.elements {
		tuple, is_tuple := elem.(Tuple_Value)
		if !is_tuple || len(tuple.elements) != 2 {
			return name, fill_text.text, parsed[:], false
		}
		col, row, cell_ok := cell_arg(tuple.elements[0])
		if !cell_ok {
			return name, fill_text.text, parsed[:], false
		}
		tile_text, tile_is_string := tuple.elements[1].(String_Value)
		if !tile_is_string {
			return name, fill_text.text, parsed[:], false
		}
		append(&parsed, Buildlayer_Override{cell = Settile_Cell{x = col, y = row}, tile = tile_text.text})
	}
	return name, fill_text.text, parsed[:], true
}
