package funpack

import "core:strings"

Bake_Error :: enum {
	None,
	Unresolved_Name,
	Duplicate_Name,
	Type_Mismatched_Ref,
	Param_Not_On_Schema,
	At_Without_Pos,
	Outside_Bounds,
	Seam_Imports_Behavior,
	Prefab_Member_Not_Placed,
	Things_Module_Unresolved,
	Unknown_Thing_Type,
	Bad_Coordinate,
	Bad_Bounds,
	Char_Not_In_Legend,
	Grid_Not_Rectangular,
	Unknown_Tile_Name,
	Tile_Name_Collision,
	Cell_Outside_Grid,
	Tileset_Atlas_Conflict,
}

Baked_Coord :: struct {
	dim: Flvl_Dim,
	x:   Fixed,
	y:   Fixed,
	z:   Fixed,
}

Baked_Ref :: struct {
	name:       string,
	local_name: string,
	thing_type: string,
	id:         u64,
}

Baked_Param :: struct {
	field:  string,
	is_ref: bool,
	ref_id: u64,
	value:  Fixed,
}

Baked_Spawn :: struct {
	thing_type: string,
	id:         u64,
	has_facing: bool,
	pos:        Baked_Coord,
	facing:     Fixed,
	params:     []Baked_Param,
}

Baked_Prefab_Instance :: struct {
	name:    string,
	type:    string,
	members: []Baked_Ref,
}

Baked_Symbol_Kind :: enum {
	Ref,
	Prefab,
}

Baked_Symbol :: struct {
	kind:       Baked_Symbol_Kind,
	local_name: string,
	index:      int,
}

Baked_Level :: struct {
	level_name:    string,
	dim:           Flvl_Dim,
	schema_module: string,
	refs:          []Baked_Ref,
	spawns:        []Baked_Spawn,
	prefabs:       []Baked_Prefab_Instance,
	symbols:       []Baked_Symbol,
	tile_layers:   []Baked_Tile_Layer,
}

Project_Tile :: struct {
	name:    string,
	tileset: string,
	atlas:   string,
	solid:   bool,
	cell_x:  i64,
	cell_y:  i64,
	tags:    []string,
}

flvl_project_tile_table :: proc(tilesets: []Tileset_Asset, allocator := context.allocator) -> (table: []Project_Tile, err: Bake_Error) {
	entries := make([dynamic]Project_Tile, 0, 8, allocator)
	for tileset in tilesets {
		for tile in tileset.tiles {
			for claimed in entries {
				if claimed.name == tile.name {
					return nil, .Tile_Name_Collision
				}
			}
			append(&entries, Project_Tile{
				name    = tile.name,
				tileset = tileset.name,
				atlas   = tileset.atlas,
				solid   = tile.solid,
				cell_x  = tile.cell_x,
				cell_y  = tile.cell_y,
				tags    = tile.tags,
			})
		}
	}
	return entries[:], .None
}

find_project_tile :: proc(table: []Project_Tile, name: string) -> (tile: Project_Tile, found: bool) {
	for candidate in table {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Project_Tile{}, false
}

Baked_Tile :: struct {
	name:   string,
	solid:  bool,
	cell_x: i64,
	cell_y: i64,
}

Baked_Tile_Layer :: struct {
	name:      string,
	cell_size: i64,
	cols:      int,
	rows:      int,
	anchor_x:  Fixed,
	anchor_y:  Fixed,
	atlas:     string,
	palette:   []Baked_Tile,
	cells:     []int,
}

TILE_LAYER_EMPTY_CELL :: -1

flvl_schema_thing :: proc(schema: Ast, name: string) -> (thing: Thing_Node, found: bool) {
	for candidate in schema.things {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Thing_Node{}, false
}

flvl_schema_field :: proc(thing: Thing_Node, name: string) -> (field: Field_Decl, found: bool) {
	for candidate in thing.fields {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Field_Decl{}, false
}

pos_arity_matches :: proc(field: Field_Decl, dim: Flvl_Dim) -> bool {
	switch dim {
	case .D2:
		return field.type.name == "Vec2"
	case .D3:
		return field.type.name == "Vec3"
	}
	return false
}

ref_target_type :: proc(field: Field_Decl) -> (target: string, is_ref: bool) {
	if field.type.name == "Ref" && len(field.type.args) == 1 {
		return field.type.args[0].name, true
	}
	return "", false
}

Bake_Scope :: struct {
	name_prefix: string,
	origin:      Baked_Coord,
	loop_vars:   map[string]i64,
	siblings:    map[string]Baked_Coord,
	prefabs:     []Flvl_Prefab,
	grid:        Flvl_Grid_Info,
}

Flvl_Grid_Info :: struct {
	present:   bool,
	cols:      int,
	rows:      int,
	cell_size: i64,
}

Bake_Context :: struct {
	level:        Flvl_Level,
	schema:       Ast,
	names:        map[string]bool,
	anon_counter: u64,
	refs:         [dynamic]Baked_Ref,
	spawns:       [dynamic]Baked_Spawn,
	prefabs:      [dynamic]Baked_Prefab_Instance,
	symbols:      [dynamic]Baked_Symbol,
	tiles:        []Project_Tile,
	tile_layers:  [dynamic]Baked_Tile_Layer,
}

bake_flvl :: proc(level: Flvl_Level, schema: Ast, schema_module: string, index: Module_Index, tiles: []Project_Tile = nil) -> (baked: Baked_Level, err: Bake_Error) {
	if level.things_module == "" {
		return Baked_Level{}, .Things_Module_Unresolved
	}
	if level.things_module != schema_module {
		return Baked_Level{}, .Things_Module_Unresolved
	}
	if _, found := module_index_lookup(index, level.things_module); !found {
		return Baked_Level{}, .Things_Module_Unresolved
	}

	if !level.has_bounds {
		return Baked_Level{}, .Bad_Bounds
	}
	bounds_min := coord_of_components(level.bounds_min.components, level.dim) or_return
	bounds_max := coord_of_components(level.bounds_max.components, level.dim) or_return

	ctx := Bake_Context {
		level       = level,
		schema      = schema,
		names       = make(map[string]bool, 16, context.temp_allocator),
		refs        = make([dynamic]Baked_Ref, 0, 16, context.temp_allocator),
		spawns      = make([dynamic]Baked_Spawn, 0, 16, context.temp_allocator),
		prefabs     = make([dynamic]Baked_Prefab_Instance, 0, 4, context.temp_allocator),
		symbols     = make([dynamic]Baked_Symbol, 0, 8, context.temp_allocator),
		tiles       = tiles,
		tile_layers = make([dynamic]Baked_Tile_Layer, 0, 2, context.temp_allocator),
	}

	root := Bake_Scope {
		name_prefix = level.name,
		origin      = bounds_min,
		loop_vars   = make(map[string]i64, 4, context.temp_allocator),
		siblings    = make(map[string]Baked_Coord, 16, context.temp_allocator),
		prefabs     = level.prefabs,
		grid        = level_grid_info(level),
	}

	expand_items(&ctx, &root, level.items, level.places, level.fors, level.tilemaps, bounds_min, bounds_max) or_return

	return Baked_Level {
		level_name    = level.name,
		dim           = level.dim,
		schema_module = schema_module,
		refs          = ctx.refs[:],
		spawns        = ctx.spawns[:],
		prefabs       = ctx.prefabs[:],
		symbols       = ctx.symbols[:],
		tile_layers   = ctx.tile_layers[:],
	}, .None
}

level_grid_info :: proc(level: Flvl_Level) -> Flvl_Grid_Info {
	if len(level.tilemaps) == 0 {
		return Flvl_Grid_Info{}
	}
	first := level.tilemaps[0]
	cols := 0
	if len(first.rows) > 0 {
		cols = len(first.rows[0])
	}
	return Flvl_Grid_Info {
		present   = true,
		cols      = cols,
		rows      = len(first.rows),
		cell_size = first.cell_size,
	}
}

is_top_level_scope :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope) -> bool {
	return scope.name_prefix == ctx.level.name
}

expand_items :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, items: []Flvl_Item, places: []Flvl_Place, fors: []Flvl_For, tilemaps: []Flvl_Tilemap, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	for item in items {
		switch item.kind {
		case .Place:
			expand_place(ctx, scope, places[item.index], bounds_min, bounds_max) or_return
		case .For:
			expand_for(ctx, scope, fors[item.index], bounds_min, bounds_max) or_return
		case .Prefab:
		case .Tilemap:
			expand_tilemap(ctx, scope, tilemaps[item.index], bounds_min, bounds_max) or_return
		}
	}
	return .None
}

expand_for :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, loop: Flvl_For, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	lo := fold_int(scope, loop.lo) or_return
	hi := fold_int(scope, loop.hi) or_return
	visible := make([dynamic]Flvl_Prefab, 0, len(scope.prefabs) + len(loop.nested), context.temp_allocator)
	append(&visible, ..scope.prefabs)
	append(&visible, ..loop.nested)
	for i := lo; i < hi; i += 1 {
		child := Bake_Scope {
			name_prefix = scope.name_prefix,
			origin      = scope.origin,
			loop_vars   = make(map[string]i64, len(scope.loop_vars) + 1, context.temp_allocator),
			siblings    = scope.siblings,
			prefabs     = visible[:],
			grid        = scope.grid,
		}
		for k, v in scope.loop_vars {
			child.loop_vars[k] = v
		}
		child.loop_vars[loop.var] = i
		expand_items(ctx, &child, loop.items, loop.places, loop.fors, nil, bounds_min, bounds_max) or_return
	}
	return .None
}

expand_place :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, place: Flvl_Place, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	if prefab, is_prefab := flvl_find_prefab(scope.prefabs, place.type_name); is_prefab {
		return stamp_prefab(ctx, scope, place, prefab, bounds_min, bounds_max)
	}
	if _, is_thing := flvl_schema_thing(ctx.schema, place.type_name); is_thing {
		return emit_thing_spawn(ctx, scope, place, bounds_min, bounds_max)
	}
	return .Unknown_Thing_Type
}

coord_of_components :: proc(components: []Flvl_Anchor_Expr, dim: Flvl_Dim) -> (coord: Baked_Coord, err: Bake_Error) {
	want := 2 if dim == .D2 else 3
	if len(components) != want {
		return Baked_Coord{}, .Bad_Bounds
	}
	empty := Bake_Scope{}
	coord.dim = dim
	coord.x = fold_fixed(&empty, components[0]) or_return
	coord.y = fold_fixed(&empty, components[1]) or_return
	if dim == .D3 {
		coord.z = fold_fixed(&empty, components[2]) or_return
	}
	return coord, .None
}

resolve_position :: proc(scope: ^Bake_Scope, expr: Flvl_Anchor_Expr, bounds_min, bounds_max: Baked_Coord, dim: Flvl_Dim) -> (coord: Baked_Coord, err: Bake_Error) {
	return fold_anchor(scope, expr, bounds_min, bounds_max, dim)
}

fold_anchor :: proc(scope: ^Bake_Scope, expr: Flvl_Anchor_Expr, bounds_min, bounds_max: Baked_Coord, dim: Flvl_Dim) -> (coord: Baked_Coord, err: Bake_Error) {
	switch e in expr {
	case ^Flvl_Name_Expr:
		return named_anchor(scope, e.name, bounds_min, bounds_max, dim)
	case ^Flvl_Member_Expr:
		base := fold_anchor(scope, e.receiver, bounds_min, bounds_max, dim) or_return
		return anchor_member(base, e.member, bounds_min, bounds_max)
	case ^Flvl_Call_Expr:
		return anchor_call(scope, e, bounds_min, bounds_max, dim)
	case ^Flvl_Int_Expr, ^Flvl_Fixed_Expr, ^Flvl_String_Expr, ^Flvl_Binary_Expr, ^Flvl_Unary_Expr:
		return Baked_Coord{}, .Bad_Coordinate
	}
	return Baked_Coord{}, .Bad_Coordinate
}

named_anchor :: proc(scope: ^Bake_Scope, name: string, bounds_min, bounds_max: Baked_Coord, dim: Flvl_Dim) -> (coord: Baked_Coord, err: Bake_Error) {
	mid_x := fixed_div(fixed_add(bounds_min.x, bounds_max.x), to_fixed(2))
	mid_y := fixed_div(fixed_add(bounds_min.y, bounds_max.y), to_fixed(2))
	mid_z := fixed_div(fixed_add(bounds_min.z, bounds_max.z), to_fixed(2))
	switch name {
	case "origin":
		return scope.origin, .None
	case "center":
		return Baked_Coord{dim = dim, x = mid_x, y = mid_y, z = mid_z}, .None
	case "left_edge":
		return Baked_Coord{dim = dim, x = bounds_min.x, y = mid_y, z = mid_z}, .None
	case "right_edge":
		return Baked_Coord{dim = dim, x = bounds_max.x, y = mid_y, z = mid_z}, .None
	case "bottom_edge":
		return Baked_Coord{dim = dim, x = mid_x, y = bounds_min.y, z = mid_z}, .None
	case "top_edge":
		return Baked_Coord{dim = dim, x = mid_x, y = bounds_max.y, z = mid_z}, .None
	}
	if sib, found := scope.siblings[name]; found {
		return sib, .None
	}
	return Baked_Coord{}, .Unresolved_Name
}

anchor_member :: proc(base: Baked_Coord, member: string, bounds_min, bounds_max: Baked_Coord) -> (coord: Baked_Coord, err: Bake_Error) {
	if member == "center" {
		return base, .None
	}
	return Baked_Coord{}, .Bad_Coordinate
}

anchor_call :: proc(scope: ^Bake_Scope, call: ^Flvl_Call_Expr, bounds_min, bounds_max: Baked_Coord, dim: Flvl_Dim) -> (coord: Baked_Coord, err: Bake_Error) {
	if name, is_name := call.callee.(^Flvl_Name_Expr); is_name && name.name == "cell" {
		return resolve_cell_anchor(scope, call, bounds_min, bounds_max, dim)
	}
	member, is_member := call.callee.(^Flvl_Member_Expr)
	if !is_member || member.member != "offset" {
		return Baked_Coord{}, .Bad_Coordinate
	}
	base := fold_anchor(scope, member.receiver, bounds_min, bounds_max, dim) or_return
	coord = base
	for arg, i in call.args {
		delta := fold_fixed(scope, arg) or_return
		switch call.arg_names[i] {
		case "x":
			coord.x = fixed_add(coord.x, delta)
		case "y":
			coord.y = fixed_add(coord.y, delta)
		case "z":
			coord.z = fixed_add(coord.z, delta)
		case:
			return Baked_Coord{}, .Bad_Coordinate
		}
	}
	return coord, .None
}

resolve_cell_anchor :: proc(scope: ^Bake_Scope, call: ^Flvl_Call_Expr, bounds_min, bounds_max: Baked_Coord, dim: Flvl_Dim) -> (coord: Baked_Coord, err: Bake_Error) {
	if len(call.args) != 2 {
		return Baked_Coord{}, .Bad_Coordinate
	}
	if call.arg_names[0] != "" || call.arg_names[1] != "" {
		return Baked_Coord{}, .Bad_Coordinate
	}
	col := fold_int(scope, call.args[0]) or_return
	row := fold_int(scope, call.args[1]) or_return
	grid := scope.grid
	if !grid.present {
		return Baked_Coord{}, .Cell_Outside_Grid
	}
	if col < 0 || col >= i64(grid.cols) || row < 0 || row >= i64(grid.rows) {
		return Baked_Coord{}, .Cell_Outside_Grid
	}
	return flvl_cell_center(col, row, grid.cell_size, bounds_min, bounds_max, dim), .None
}

flvl_cell_center :: proc(col, row: i64, cell_size: i64, bounds_min, bounds_max: Baked_Coord, dim: Flvl_Dim) -> Baked_Coord {
	half := fixed_div(to_fixed(cell_size), to_fixed(2))
	x := fixed_add(bounds_min.x, fixed_add(to_fixed(int_mul(col, cell_size)), half))
	y := fixed_sub(bounds_max.y, fixed_add(to_fixed(int_mul(row, cell_size)), half))
	coord := Baked_Coord{dim = dim, x = x, y = y}
	if dim == .D3 {
		coord.z = bounds_min.z
	}
	return coord
}

fold_fixed :: proc(scope: ^Bake_Scope, expr: Flvl_Anchor_Expr) -> (value: Fixed, err: Bake_Error) {
	switch e in expr {
	case ^Flvl_Int_Expr:
		return to_fixed(e.value), .None
	case ^Flvl_Fixed_Expr:
		return e.bits, .None
	case ^Flvl_Name_Expr:
		if v, found := scope.loop_vars[e.name]; found {
			return to_fixed(v), .None
		}
		return Fixed(0), .Bad_Coordinate
	case ^Flvl_Unary_Expr:
		operand := fold_fixed(scope, e.operand) or_return
		return fixed_neg(operand), .None
	case ^Flvl_Binary_Expr:
		lhs := fold_fixed(scope, e.lhs) or_return
		rhs := fold_fixed(scope, e.rhs) or_return
		#partial switch e.op {
		case .Plus:
			return fixed_add(lhs, rhs), .None
		case .Minus:
			return fixed_sub(lhs, rhs), .None
		case .Star:
			return fixed_mul(lhs, rhs), .None
		case .Slash:
			return fixed_div(lhs, rhs), .None
		}
		return Fixed(0), .Bad_Coordinate
	case ^Flvl_String_Expr, ^Flvl_Member_Expr, ^Flvl_Call_Expr:
		return Fixed(0), .Bad_Coordinate
	}
	return Fixed(0), .Bad_Coordinate
}

fold_int :: proc(scope: ^Bake_Scope, expr: Flvl_Anchor_Expr) -> (value: i64, err: Bake_Error) {
	switch e in expr {
	case ^Flvl_Int_Expr:
		return e.value, .None
	case ^Flvl_Fixed_Expr:
		return fixed_trunc(e.bits), .None
	case ^Flvl_Name_Expr:
		if v, found := scope.loop_vars[e.name]; found {
			return v, .None
		}
		return 0, .Bad_Coordinate
	case ^Flvl_Unary_Expr:
		operand := fold_int(scope, e.operand) or_return
		return int_neg(operand), .None
	case ^Flvl_Binary_Expr:
		lhs := fold_int(scope, e.lhs) or_return
		rhs := fold_int(scope, e.rhs) or_return
		#partial switch e.op {
		case .Plus:
			return int_add(lhs, rhs), .None
		case .Minus:
			return int_sub(lhs, rhs), .None
		case .Star:
			return int_mul(lhs, rhs), .None
		case .Slash:
			return int_div(lhs, rhs), .None
		}
		return 0, .Bad_Coordinate
	case ^Flvl_String_Expr, ^Flvl_Member_Expr, ^Flvl_Call_Expr:
		return 0, .Bad_Coordinate
	}
	return 0, .Bad_Coordinate
}

flvl_within_bounds :: proc(coord, bounds_min, bounds_max: Baked_Coord) -> bool {
	if coord.x < bounds_min.x || coord.x > bounds_max.x {
		return false
	}
	if coord.y < bounds_min.y || coord.y > bounds_max.y {
		return false
	}
	if coord.dim == .D3 {
		if coord.z < bounds_min.z || coord.z > bounds_max.z {
			return false
		}
	}
	return true
}

emit_thing_spawn :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, place: Flvl_Place, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	thing, _ := flvl_schema_thing(ctx.schema, place.type_name)

	pos_field, has_pos := flvl_schema_field(thing, "pos")
	if !has_pos || !pos_arity_matches(pos_field, ctx.level.dim) {
		return .At_Without_Pos
	}

	pos := resolve_position(scope, place.position, bounds_min, bounds_max, ctx.level.dim) or_return
	if !flvl_within_bounds(pos, bounds_min, bounds_max) {
		return .Outside_Bounds
	}

	id: u64
	if place.has_name {
		qualified := flvl_qualify(scope.name_prefix, place.instance_name)
		if ctx.names[qualified] {
			return .Duplicate_Name
		}
		ctx.names[qualified] = true
		id = flvl_stable_id(qualified)
		ref_index := len(ctx.refs)
		append(&ctx.refs, Baked_Ref{
			name       = qualified,
			local_name = place.instance_name,
			thing_type = place.type_name,
			id         = id,
		})
		if is_top_level_scope(ctx, scope) {
			append(&ctx.symbols, Baked_Symbol{
				kind       = .Ref,
				local_name = place.instance_name,
				index      = ref_index,
			})
		}
		scope.siblings[place.instance_name] = pos
	} else {
		id = ctx.anon_counter
		ctx.anon_counter += 1
	}

	facing: Fixed
	if place.has_facing {
		facing = fold_fixed(scope, place.facing) or_return
	}

	params, perr := resolve_params(ctx, scope, thing, place.params)
	if perr != .None {
		return perr
	}

	append(&ctx.spawns, Baked_Spawn{
		thing_type = place.type_name,
		id         = id,
		has_facing = place.has_facing,
		pos        = pos,
		facing     = facing,
		params     = params,
	})
	return .None
}

expand_tilemap :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, tilemap: Flvl_Tilemap, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	qualified := flvl_qualify(scope.name_prefix, tilemap.name)
	if ctx.names[qualified] {
		return .Duplicate_Name
	}
	ctx.names[qualified] = true

	rows := len(tilemap.rows)
	if rows == 0 {
		return .Grid_Not_Rectangular
	}
	cols := len(tilemap.rows[0])
	if cols == 0 {
		return .Grid_Not_Rectangular
	}
	for row in tilemap.rows {
		if len(row) != cols {
			return .Grid_Not_Rectangular
		}
	}

	palette := make([dynamic]Baked_Tile, 0, len(tilemap.legend), context.temp_allocator)
	layer_atlas := ""
	for entry in tilemap.legend {
		if entry.kind != .Tile {
			continue
		}
		tile, found := find_project_tile(ctx.tiles, entry.tile_name)
		if !found {
			return .Unknown_Tile_Name
		}
		if layer_atlas == "" {
			layer_atlas = tile.atlas
		} else if tile.atlas != layer_atlas {
			return .Tileset_Atlas_Conflict
		}
		if palette_index(palette[:], tile.name) < 0 {
			append(&palette, Baked_Tile{name = tile.name, solid = tile.solid, cell_x = tile.cell_x, cell_y = tile.cell_y})
		}
	}

	cells := make([]int, rows * cols, context.temp_allocator)
	for row, r in tilemap.rows {
		for c in 0 ..< cols {
			entry, found := find_legend_entry(tilemap.legend, row[c])
			if !found {
				return .Char_Not_In_Legend
			}
			cell_index := r * cols + c
			switch entry.kind {
			case .Tile:
				cells[cell_index] = palette_index(palette[:], entry.tile_name)
			case .Empty:
				cells[cell_index] = TILE_LAYER_EMPTY_CELL
			case .Spawn:
				cells[cell_index] = TILE_LAYER_EMPTY_CELL
				emit_marker_spawn(ctx, scope, entry, i64(c), i64(r), tilemap.cell_size, bounds_min, bounds_max) or_return
			}
		}
	}

	append(&ctx.tile_layers, Baked_Tile_Layer{
		name      = tilemap.name,
		cell_size = tilemap.cell_size,
		cols      = cols,
		rows      = rows,
		anchor_x  = bounds_min.x,
		anchor_y  = bounds_max.y,
		atlas     = layer_atlas,
		palette   = palette[:],
		cells     = cells,
	})
	return .None
}

find_legend_entry :: proc(legend: []Flvl_Legend_Entry, char: u8) -> (entry: Flvl_Legend_Entry, found: bool) {
	for candidate in legend {
		if candidate.char == char {
			return candidate, true
		}
	}
	return Flvl_Legend_Entry{}, false
}

palette_index :: proc(palette: []Baked_Tile, name: string) -> int {
	for tile, i in palette {
		if tile.name == name {
			return i
		}
	}
	return -1
}

emit_marker_spawn :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, entry: Flvl_Legend_Entry, col, row: i64, cell_size: i64, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	thing, is_thing := flvl_schema_thing(ctx.schema, entry.spawn_type)
	if !is_thing {
		return .Unknown_Thing_Type
	}
	pos_field, has_pos := flvl_schema_field(thing, "pos")
	if !has_pos || !pos_arity_matches(pos_field, ctx.level.dim) {
		return .At_Without_Pos
	}

	pos := flvl_cell_center(col, row, cell_size, bounds_min, bounds_max, ctx.level.dim)
	if !flvl_within_bounds(pos, bounds_min, bounds_max) {
		return .Outside_Bounds
	}

	id: u64
	if entry.has_spawn_name {
		qualified := flvl_qualify(scope.name_prefix, entry.spawn_name)
		if ctx.names[qualified] {
			return .Duplicate_Name
		}
		ctx.names[qualified] = true
		id = flvl_stable_id(qualified)
		ref_index := len(ctx.refs)
		append(&ctx.refs, Baked_Ref{
			name       = qualified,
			local_name = entry.spawn_name,
			thing_type = entry.spawn_type,
			id         = id,
		})
		if is_top_level_scope(ctx, scope) {
			append(&ctx.symbols, Baked_Symbol{
				kind       = .Ref,
				local_name = entry.spawn_name,
				index      = ref_index,
			})
		}
		scope.siblings[entry.spawn_name] = pos
	} else {
		id = ctx.anon_counter
		ctx.anon_counter += 1
	}

	append(&ctx.spawns, Baked_Spawn{
		thing_type = entry.spawn_type,
		id         = id,
		pos        = pos,
	})
	return .None
}

resolve_params :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, thing: Thing_Node, params: []Flvl_Param) -> (out: []Baked_Param, err: Bake_Error) {
	list := make([dynamic]Baked_Param, 0, len(params), context.temp_allocator)
	for param in params {
		if len(param.path) != 1 {
			return nil, .Param_Not_On_Schema
		}
		field_name := param.path[0]
		field, has_field := flvl_schema_field(thing, field_name)
		if !has_field {
			return nil, .Param_Not_On_Schema
		}
		baked, berr := resolve_param_value(ctx, scope, field, param.value)
		if berr != .None {
			return nil, berr
		}
		baked.field = field_name
		append(&list, baked)
	}
	return list[:], .None
}

resolve_param_value :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, field: Field_Decl, value: Flvl_Anchor_Expr) -> (baked: Baked_Param, err: Bake_Error) {
	target_type, is_ref_field := ref_target_type(field)
	if name_expr, is_name := value.(^Flvl_Name_Expr); is_name && !is_loop_var(scope, name_expr.name) {
		if !is_ref_field {
			return Baked_Param{}, .Type_Mismatched_Ref
		}
		ref, found := flvl_find_ref(ctx.refs[:], name_expr.name)
		if !found {
			return Baked_Param{}, .Unresolved_Name
		}
		if ref.thing_type != target_type {
			return Baked_Param{}, .Type_Mismatched_Ref
		}
		return Baked_Param{is_ref = true, ref_id = ref.id}, .None
	}
	if is_ref_field {
		return Baked_Param{}, .Type_Mismatched_Ref
	}
	folded := fold_fixed(scope, value) or_return
	return Baked_Param{value = folded}, .None
}

is_loop_var :: proc(scope: ^Bake_Scope, name: string) -> bool {
	_, found := scope.loop_vars[name]
	return found
}

stamp_prefab :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, place: Flvl_Place, prefab: Flvl_Prefab, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	origin := resolve_position(scope, place.position, bounds_min, bounds_max, ctx.level.dim) or_return
	if !flvl_within_bounds(origin, bounds_min, bounds_max) {
		return .Outside_Bounds
	}

	prefix := scope.name_prefix
	inst_name := place.instance_name
	if place.has_name {
		prefix = flvl_qualify(scope.name_prefix, place.instance_name)
		if ctx.names[prefix] {
			return .Duplicate_Name
		}
		ctx.names[prefix] = true
	} else {
		prefix = flvl_qualify(scope.name_prefix, strings.to_lower(place.type_name, context.temp_allocator))
		inst_name = strings.to_lower(place.type_name, context.temp_allocator)
	}

	visible := make([dynamic]Flvl_Prefab, 0, len(scope.prefabs) + len(prefab.nested), context.temp_allocator)
	append(&visible, ..scope.prefabs)
	append(&visible, ..prefab.nested)

	child := Bake_Scope {
		name_prefix = prefix,
		origin      = origin,
		loop_vars   = scope.loop_vars,
		siblings    = make(map[string]Baked_Coord, 8, context.temp_allocator),
		prefabs     = visible[:],
		grid        = scope.grid,
	}

	before := len(ctx.refs)

	merged := apply_overrides(ctx, prefab, place.params) or_return

	expand_prefab_body(ctx, &child, merged, bounds_min, bounds_max) or_return

	members := make([dynamic]Baked_Ref, 0, len(ctx.refs) - before, context.temp_allocator)
	for i := before; i < len(ctx.refs); i += 1 {
		append(&members, ctx.refs[i])
	}
	prefab_index := len(ctx.prefabs)
	append(&ctx.prefabs, Baked_Prefab_Instance{
		name    = prefix,
		type    = place.type_name,
		members = members[:],
	})
	if place.has_name && is_top_level_scope(ctx, scope) {
		append(&ctx.symbols, Baked_Symbol{
			kind       = .Prefab,
			local_name = inst_name,
			index      = prefab_index,
		})
	}
	return .None
}

expand_prefab_body :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, prefab: Flvl_Prefab, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	return expand_items(ctx, scope, prefab.items, prefab.places, prefab.fors, nil, bounds_min, bounds_max)
}

apply_overrides :: proc(ctx: ^Bake_Context, prefab: Flvl_Prefab, overrides: []Flvl_Param) -> (merged: Flvl_Prefab, err: Bake_Error) {
	merged = prefab
	places := make([dynamic]Flvl_Place, len(prefab.places), context.temp_allocator)
	copy(places[:], prefab.places)

	for override in overrides {
		if len(override.path) < 2 {
			return Flvl_Prefab{}, .Prefab_Member_Not_Placed
		}
		member_name := override.path[0]
		field_path := override.path[1:]
		member_idx := find_place_index(places[:], member_name)
		if member_idx < 0 {
			return Flvl_Prefab{}, .Prefab_Member_Not_Placed
		}
		places[member_idx].params = merge_param(places[member_idx].params, field_path, override.value)
	}
	merged.places = places[:]
	return merged, .None
}

merge_param :: proc(existing: []Flvl_Param, field_path: []string, value: Flvl_Anchor_Expr) -> []Flvl_Param {
	list := make([dynamic]Flvl_Param, 0, len(existing) + 1, context.temp_allocator)
	replaced := false
	for param in existing {
		if param_path_equal(param.path, field_path) {
			append(&list, Flvl_Param{path = field_path, value = value})
			replaced = true
		} else {
			append(&list, param)
		}
	}
	if !replaced {
		append(&list, Flvl_Param{path = field_path, value = value})
	}
	return list[:]
}

param_path_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for seg, i in a {
		if seg != b[i] {
			return false
		}
	}
	return true
}

find_place_index :: proc(places: []Flvl_Place, name: string) -> int {
	for place, i in places {
		if place.has_name && place.instance_name == name {
			return i
		}
	}
	return -1
}

flvl_find_prefab :: proc(prefabs: []Flvl_Prefab, name: string) -> (prefab: Flvl_Prefab, found: bool) {
	for candidate in prefabs {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Flvl_Prefab{}, false
}

flvl_find_ref :: proc(refs: []Baked_Ref, local_name: string) -> (ref: Baked_Ref, found: bool) {
	for candidate in refs {
		if candidate.local_name == local_name {
			return candidate, true
		}
	}
	return Baked_Ref{}, false
}

flvl_qualify :: proc(prefix, name: string) -> string {
	return strings.concatenate({prefix, ".", name}, context.temp_allocator)
}

module_is_behavior :: proc(ast: Ast) -> bool {
	return len(ast.behaviors) > 0 || len(ast.pipelines) > 0
}

check_flvl_seam_layering :: proc(seam: Ast, module_asts: map[string]Ast) -> Bake_Error {
	for imp in seam.imports {
		module := imp.segments[0]
		if module_under_reserved_root(module) {
			continue
		}
		ast, known := module_asts[module]
		if !known {
			continue
		}
		if module_is_behavior(ast) {
			return .Seam_Imports_Behavior
		}
	}
	return .None
}

flvl_stable_id :: proc(qualified_name: string) -> u64 {
	hash: u64 = 0xcbf29ce484222325
	for b in transmute([]u8)qualified_name {
		hash ~= u64(b)
		hash *= 0x100000001b3
	}
	return hash
}
