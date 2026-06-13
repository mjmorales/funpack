// The §17 level bake: it lowers a parsed `.flvl` AST (flvl_parser.odin) against
// its `things` schema module into the baked level model — the typed Ref table,
// the deterministic spawn list, and every §17.4 compile-error gate. This is the
// one-way lowering of the ergonomic authoring sugar (anchors, loops, prefabs,
// references-by-name) to the flat initial-world data a save also produces
// (spec §17.3): a level is an initial snapshot.
//
// INPUT seam. The bake takes the parsed level, the schema module's full parsed
// Ast, and the project Module_Index. The index (module_index.odin) carries only
// export NAMES and positions — not field lists — so the index resolves the
// `things <module>` existence and that each placed type is a thing the module
// exports, while the schema Ast supplies the FULL Field_Decls the field-level
// gates need (a Ref[T]'s target type, a param's presence on the schema, a `pos`
// of the level's arity). The seam-imports-behavior gate (§17.2 layering) reads
// the seam module's own imports.
//
// DETERMINISM. The spawn list is declaration order with prefabs and for-loops
// expanded in place (spec §17.4). A named instance's Id is derived from its
// level-qualified dotted name (`Arena.right_gun.cannon`), so its Ref is constant
// across loads/saves/replays; anonymous scenery takes counter ids in declaration
// order. Coordinates are fixed-point (Q32.32, fixed.odin) so a level loads
// bit-identically on every machine — anchor resolution folds the offset
// arithmetic over the saturating Fixed kernel, never float.
//
// GATES. Every §17.4 gate is a distinct closed Bake_Error arm, never folded —
// the frontend's diagnostics are what an agent repairs against, so the arm names
// the exact violation.
package funpack

import "core:strings"

// Bake_Error is closed with one arm per §17.4 bake gate (spec §17.4), each a
// COMPILE ERROR — a level that trips any arm has no well-defined initial world,
// so the bake never produces a partial model. The arms are never folded: the
// arm IS the diagnostic an agent repairs against.
Bake_Error :: enum {
	None,
	Unresolved_Name,          // a reference-by-name (`gate: plate`) or anchor names no placed instance
	Duplicate_Name,           // two named instances share a level-qualified name (a duplicate NAMED MARKER is this same violation — a marker name is a level-qualified instance name, §18 §3/§5)
	Type_Mismatched_Ref,      // a Ref[T] field bound to an instance whose thing type is not T
	Param_Not_On_Schema,      // a param/override key not a field of the placed thing's schema
	At_Without_Pos,           // an `at` (or a §18 §3 marker cell) on a thing with no `pos` of the level's arity
	Outside_Bounds,           // a resolved coordinate lies outside the level's `bounds`
	Seam_Imports_Behavior,    // a .gen.fun seam imports a behavior module (§17.2 layering)
	Prefab_Member_Not_Placed, // an override names a prefab member the prefab never places
	Things_Module_Unresolved, // the `things <module>` line is absent or names no indexed module
	Unknown_Thing_Type,       // a `place <Type>` or a `spawn <Type>` marker names neither a prefab nor a schema thing
	Bad_Coordinate,           // an anchor/offset expression the bake cannot fold to a coordinate
	Bad_Bounds,               // the `bounds` corners are absent or not the level's arity
	// The §18 §5 tilemap gates, each its own closed arm — the arm IS the
	// diagnostic an agent repairs against, never folded.
	Char_Not_In_Legend,       // a grid char no legend entry binds (§18 §5)
	Grid_Not_Rectangular,     // the dedented grid rows differ in length, or the grid is empty (§18 §5)
	Unknown_Tile_Name,        // a legend tile name absent from the project-global tile table (§18 §5)
	Tile_Name_Collision,      // two tilesets declare the same tile name (one name, one tile — the ADR's cross-tileset gate, §18 §3)
	Cell_Outside_Grid,        // a `cell(col, row)` anchor outside the grid — or in a level with no grid (§18 §5)
	Tileset_Atlas_Conflict,   // one layer's palette mixes tiles from tilesets with DIFFERENT atlases (the §19 textured-render v17 per-layer-atlas link needs one atlas per layer; a mixed-atlas layer cannot carry a single atlas, so it is refused rather than silently picking one)
}

// Baked_Coord is one resolved placement coordinate: fixed-point components in
// declaration arity order (x, y for a 2d level; x, y, z for a 3d level). The
// components fold from the anchor + offset arithmetic over the Q32.32 kernel
// (fixed.odin) so the same source bakes to the same bits on every machine
// (spec §17.4). dim records the arity so a reader knows whether z is meaningful.
Baked_Coord :: struct {
	dim: Flvl_Dim,
	x:   Fixed,
	y:   Fixed,
	z:   Fixed, // meaningful only when dim == .D3
}

// Baked_Ref is one entry of the level's typed symbol table: a named instance's
// level-qualified name, the thing type it places, and its stable name-derived
// Id (spec §17.2 "stable ids by name"). The seam exposes this table as the
// `data <Level> { name: Ref[Type], … }` symbol type — a reader naming a field
// resolves to this entry's typed Ref. A prefab instance is NOT a Baked_Ref; it
// expands to a Baked_Prefab_Instance whose member Refs each get an entry.
Baked_Ref :: struct {
	name:       string, // the level-qualified dotted name (`Arena.exit`, `Arena.right_gun.cannon`)
	local_name: string, // the bare instance name as written (`exit`, used as the seam field key)
	thing_type: string, // the placed schema thing type the Ref targets (`Door`, `Cannon`)
	id:         u64,     // the stable Id derived from the level-qualified name
}

// Baked_Param is one resolved blackboard-field assignment carried onto a spawn:
// the schema field name and the param value's resolved form. A reference-by-name
// value resolves to a Ref Id (ref_id, is_ref true, pointing at a Baked_Ref); any
// other value folds to a Fixed scalar (value). The reserved `pos`/`facing`
// fields are NOT params — they ride the spawn's coord/facing directly.
Baked_Param :: struct {
	field:  string,
	is_ref: bool,
	ref_id: u64,   // the target instance's stable Id when is_ref
	value:  Fixed, // the folded scalar when !is_ref
}

// Baked_Spawn is one entry of the deterministic spawn list: a placed thing, its
// resolved `pos` coordinate, its optional `facing`, and its resolved non-reserved
// params (spec §17.2 — the declaration-order spawn list prefabs/loops expand
// into). It carries the instance's stable Id (a named instance) or a
// declaration-order counter id (anonymous scenery).
Baked_Spawn :: struct {
	thing_type: string,
	id:         u64,
	has_facing: bool,
	pos:        Baked_Coord,
	facing:     Fixed,
	params:     []Baked_Param,
}

// Baked_Prefab_Instance is one placed prefab: its name and the typed Refs of its
// expanded members (spec §17.2 — "a prefab instance expands to a small `data` of
// its members' Refs"). The members carry their member-relative dotted names
// (`cannon`) and the same name-derived Ids their Baked_Ref entries carry, so the
// seam's `data <Level>Prefab { member: Ref[Type], … }` reader resolves each.
Baked_Prefab_Instance :: struct {
	name:    string, // the prefab instance's level-qualified name (`Arena.right_gun`)
	type:    string, // the prefab type (`Turret`)
	members: []Baked_Ref,
}

// Baked_Symbol_Kind discriminates a top-level symbol-table entry: a simple named
// instance (a single Baked_Ref) or a placed prefab instance (a
// Baked_Prefab_Instance of member Refs). The seam's `data <Level>` record emits a
// `Ref[Type]` field for a simple symbol and a `<Level><PrefabType>` record field
// for a prefab symbol — so the projection reads this kind to choose the field
// type.
Baked_Symbol_Kind :: enum {
	Ref,    // a simple named instance — a single Baked_Ref entry
	Prefab, // a placed prefab instance — a Baked_Prefab_Instance entry
}

// Baked_Symbol is one entry of the level's TOP-LEVEL symbol table in DECLARATION
// order (spec §17.2 — the `data <Level> { name: Ref[Type], … }` reader's field
// order is the level's source order). It records only depth-0 named placements (a
// prefab member is reached through its prefab symbol, never a top-level field), so
// the seam's Arena record carries exactly the level's named top-level instances
// and prefab placements, interleaved in source order. local_name is the seam field
// key; the index points into refs (for a .Ref) or prefabs (for a .Prefab).
Baked_Symbol :: struct {
	kind:       Baked_Symbol_Kind,
	local_name: string,
	index:      int, // index into Baked_Level.refs (.Ref) or .prefabs (.Prefab)
}

// Baked_Level is the whole lowered model: the typed Ref symbol table (named
// instances only), the deterministic spawn list (every instance, named and
// anonymous, prefab/loop expanded in place), the placed prefab instances, the
// top-level symbol order (symbols) the seam's `data <Level>` record fields
// follow, and the §18 §3 baked tile layers in declaration order. It is the
// canonical initial-world data the seam emitter (the leaf story) renders to
// `<level>.gen.fun` and the runtime loads.
Baked_Level :: struct {
	level_name:    string,
	dim:           Flvl_Dim,
	// schema_module is the `things <module>` schema module the level placed
	// against — the seam's schema import path (the level seam imports its schema
	// module by this name, `import arena_world.{…}`).
	schema_module: string,
	refs:          []Baked_Ref,
	spawns:        []Baked_Spawn,
	prefabs:       []Baked_Prefab_Instance,
	symbols:       []Baked_Symbol,
	tile_layers:   []Baked_Tile_Layer,
}

// ── Tile layers (§18 §3) ────────────────────────────────────────────────────

// Project_Tile is one entry of the PROJECT-GLOBAL tile table the legend
// resolves through (the tilemap-legend ADR / spec §18 §3): every `.tiles`
// tileset contributes its tiles to one flat name set — a tilemap names no
// tileset. The entry carries the owning tileset (collision provenance), the
// owning tileset's ATLAS handle name (the §19 textured-render link, v17 — the
// same handle name the [assets] atlas record is keyed by, so the runtime resolves
// a tile's texture through asset_region(atlas, cell) like a sprite), the §18 §2
// baked collision verdict, the atlas cell, and the tags.
Project_Tile :: struct {
	name:    string,
	tileset: string, // the owning tileset's UPPER_IDENT name
	atlas:   string, // the owning tileset's atlas HANDLE name (the §19 texture link, v17)
	solid:   bool,
	cell_x:  i64,
	cell_y:  i64,
	tags:    []string,
}

// project_tile_table aggregates the project's imported tilesets into the one
// flat §18 §3 tile namespace, in tileset slice order then tile source order —
// never a map, so the table is deterministic. Two tilesets declaring the same
// tile name is the Tile_Name_Collision bake gate (one name, one tile — the
// duplicate-named-marker discipline applied to tiles, per the ADR); the
// WITHIN-tileset duplicate is the importer's own Duplicate_Tile_Name reject,
// upstream of this table.
project_tile_table :: proc(tilesets: []Tileset_Asset, allocator := context.allocator) -> (table: []Project_Tile, err: Bake_Error) {
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

// find_project_tile resolves a legend tile name against the project table,
// walked by index. found = false is the Unknown_Tile_Name gate's trigger.
find_project_tile :: proc(table: []Project_Tile, name: string) -> (tile: Project_Tile, found: bool) {
	for candidate in table {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Project_Tile{}, false
}

// Baked_Tile is one palette entry of a baked tile layer: the project-global
// tile name, its §18 §2 collision verdict, and its ATLAS-CELL coordinate (the
// §19 textured-render link, v17 — the grid coordinate into the layer's atlas the
// tile draws from). The (name, solid) pair the runtime renders/collides from is
// joined by (cell_x, cell_y), so the runtime resolves the tile's pixels through
// the layer's atlas exactly as a sprite resolves through asset_region(atlas, cell).
// The artifact's `tile NAME SOLID CELL_X CELL_Y` sub-record carries all four.
Baked_Tile :: struct {
	name:   string,
	solid:  bool,
	cell_x: i64,
	cell_y: i64,
}

// Baked_Tile_Layer is one lowered `tilemap` layer (spec §18 §3): the layer
// name (also the seam's TilemapHandle constant name), the per-cell logical
// size, the grid dimensions, the grid→world anchor, the tile palette (the
// legend's tile binds in LEGEND order, used or not — declaration order, never
// first-use order), and the row-major per-cell palette indices. A cell with no
// tile — an `empty` bind or a marker cell (a marker places an entity, it
// paints no terrain) — carries TILE_LAYER_EMPTY_CELL. Markers are NOT here:
// they lower to the spawn list like every placement.
//
// anchor_x/anchor_y are the world point of the grid's TOP-LEFT corner —
// (bounds_min.x, bounds_max.y), the same corner the marker/cell() lowering
// anchors on (cell_center) — carried as authoritative v12 format data on the
// [tilemaps] lead line (the tilemap-anchor ADR), so the runtime reproduces the
// bake's mapping from the record alone for ANY level bounds.
Baked_Tile_Layer :: struct {
	name:      string,
	cell_size: i64,
	cols:      int,
	rows:      int,
	anchor_x:  Fixed, // world x of the grid's top-left corner (bounds_min.x)
	anchor_y:  Fixed, // world y of the grid's top-left corner (bounds_max.y)
	// atlas is the layer's tileset atlas HANDLE name (the §19 textured-render link,
	// v17) — the same handle name the [assets] atlas record is keyed by, so the
	// runtime resolves each palette tile's (cell_x, cell_y) into pixels through
	// asset_region(atlas, cell) the way a sprite does. Every palette tile in a layer
	// shares one atlas (the §18 §3 layer draws from one tileset's atlas — a layer
	// mixing tilesets with different atlases is the Tileset_Atlas_Conflict bake gate,
	// so a single per-layer atlas is always well-defined). "" only for the degenerate
	// empty-palette layer (an all-`empty`/all-marker layer paints no terrain).
	atlas:     string,
	palette:   []Baked_Tile,
	cells:     []int, // row-major palette index per cell; TILE_LAYER_EMPTY_CELL = no tile
}

// TILE_LAYER_EMPTY_CELL marks a tile-less grid cell in Baked_Tile_Layer.cells
// (an `empty` legend bind or a spawn-marker cell).
TILE_LAYER_EMPTY_CELL :: -1

// ── Schema view ─────────────────────────────────────────────────────────────
// The bake reads the schema module's thing types from its parsed Ast. A thing
// type's fields are the placement's typecheck surface (a param must be a field;
// `at` needs a `pos` of the level's arity; a Ref[T] field's target type T is the
// reference's required thing type).

// schema_thing finds a thing declaration by name in the schema module's Ast,
// walked by index (never a map — the determinism tripwire). found = false when
// the name is not a schema thing (it may still be a prefab type, checked by the
// caller).
schema_thing :: proc(schema: Ast, name: string) -> (thing: Thing_Node, found: bool) {
	for candidate in schema.things {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Thing_Node{}, false
}

// schema_field finds a field by name on a thing, walked by index. The §17.4
// param-not-on-schema and at-without-pos gates both ask this question — a param
// key must name a field, and `at` needs a `pos` field.
schema_field :: proc(thing: Thing_Node, name: string) -> (field: Field_Decl, found: bool) {
	for candidate in thing.fields {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Field_Decl{}, false
}

// pos_arity_matches reports whether a `pos` field's type has the level's arity
// (spec §17.1 "Reserved fields" — `at` writes a `pos` that must be `Vec2` in a
// 2d level, `Vec3` in 3d; this IS the dimensionality check). The field is matched
// by name (`pos`); the arity is read off the type-ref head name (Vec2/Vec3).
pos_arity_matches :: proc(field: Field_Decl, dim: Flvl_Dim) -> bool {
	switch dim {
	case .D2:
		return field.type.name == "Vec2"
	case .D3:
		return field.type.name == "Vec3"
	}
	return false
}

// ref_target_type extracts the target type name T of a `Ref[T]` field
// (spec §08/§17.1 — `gate: Ref[Switch]` targets `Switch`). is_ref = false when
// the field is not a Ref[T] (a plain `rate: Fixed`), so a reference-by-name
// value bound to a non-Ref field is a type mismatch the caller rejects.
ref_target_type :: proc(field: Field_Decl) -> (target: string, is_ref: bool) {
	if field.type.name == "Ref" && len(field.type.args) == 1 {
		return field.type.args[0].name, true
	}
	return "", false
}

// ── Expansion ───────────────────────────────────────────────────────────────
// Prefabs and for-loops expand in place into a flat declaration-ordered list of
// resolved placements before any spawn is built (spec §17.4). The expander
// carries the local origin (the anchor a prefab/loop body resolves against) and
// the per-instance name prefix so a member at any depth gets its level-qualified
// dotted name. A loop binds its var to each value in `lo..hi` (inclusive low,
// exclusive high) so a body offset reads the var.

// Bake_Scope is one expansion frame: the level-qualified name prefix (`Arena`,
// then `Arena.right_gun`), the local origin a body resolves anchors against
// (the bounds for the top level, the prefab placement point for a prefab body),
// and the in-scope loop-var bindings (name → value). Sibling placements within
// the scope are resolved into `siblings` so an instance-relative `base.offset`
// reads a prior sibling's pos.
Bake_Scope :: struct {
	name_prefix: string,
	origin:      Baked_Coord,
	loop_vars:   map[string]i64,
	siblings:    map[string]Baked_Coord,
	// The prefab declarations a `place <Type>` in this scope can stamp: the
	// level's top-level prefabs at the root, plus the current prefab's nested
	// declarations inside a prefab body (so prefabs nest to arbitrary depth via
	// `place <Nested>` — spec §17.1).
	prefabs:     []Flvl_Prefab,
	// The level's grid reference the `cell(col, row)` anchor resolves against
	// (spec §18 §3) — level structure, shared by every child scope.
	grid:        Flvl_Grid_Info,
}

// Flvl_Grid_Info is the level-wide grid reference the `cell(col, row)` anchor
// resolves against: the FIRST declared tilemap layer's dimensions and cell
// size (declaration order — the grid is level structure, so the anchor is
// independent of where the `place` sits relative to the layer). present =
// false in a layer-less level, where every cell() is the Cell_Outside_Grid
// gate (any cell is outside a grid that does not exist).
Flvl_Grid_Info :: struct {
	present:   bool,
	cols:      int,
	rows:      int,
	cell_size: i64,
}

// Bake_Context threads the level header (arity, bounds), the schema things, the
// project index/schema-module name, and the running id/duplicate-name state
// through the recursive expansion. names tracks every claimed level-qualified
// name so the duplicate-name gate fires; anon_counter is the declaration-order
// counter anonymous scenery takes.
Bake_Context :: struct {
	level:        Flvl_Level,
	schema:       Ast,
	names:        map[string]bool, // claimed level-qualified names (duplicate-name gate)
	anon_counter: u64,
	refs:         [dynamic]Baked_Ref,
	spawns:       [dynamic]Baked_Spawn,
	prefabs:      [dynamic]Baked_Prefab_Instance,
	// symbols is the TOP-LEVEL symbol order (depth-0 named placements) in
	// declaration order — the seam's `data <Level>` record field order. A nested
	// (prefab-member) placement is reached through its prefab symbol, so only
	// depth-0 placements append here (scope.name_prefix == level.name).
	symbols:      [dynamic]Baked_Symbol,
	// tiles is the project-global §18 §3 tile table the legends resolve through;
	// tile_layers accumulates the lowered layers in declaration order.
	tiles:        []Project_Tile,
	tile_layers:  [dynamic]Baked_Tile_Layer,
}

// ── Entry ───────────────────────────────────────────────────────────────────

// bake_flvl lowers a parsed level against its schema module into the baked
// model, or rejects with the §17.4 gate the level trips. The schema is the
// `things <module>` module's parsed Ast; index is the project name index used to
// resolve that the `things` module exists; tiles is the project-global §18 §3
// tile table (project_tile_table over every imported .tiles tileset) the
// tilemap legends resolve through — nil is the layer-less default, where any
// legend tile name is Unknown_Tile_Name. This is the bake story's single seam;
// the seam-emit byte contract is the leaf story's, downstream of this.
bake_flvl :: proc(level: Flvl_Level, schema: Ast, schema_module: string, index: Module_Index, tiles: []Project_Tile = nil) -> (baked: Baked_Level, err: Bake_Error) {
	// (1) Resolve `things <module>` against the index: the line is required and
	// must name an indexed module (spec §17.1).
	if level.things_module == "" {
		return Baked_Level{}, .Things_Module_Unresolved
	}
	if level.things_module != schema_module {
		return Baked_Level{}, .Things_Module_Unresolved
	}
	if _, found := module_index_lookup(index, level.things_module); !found {
		return Baked_Level{}, .Things_Module_Unresolved
	}

	// Bounds are required and must be the level's arity — anchor resolution and
	// the out-of-bounds gate both read them.
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

	// The top-level scope: the level name is the qualified-name root, and the
	// origin is the bounds_min (the `origin` anchor's coordinate). The grid
	// reference (the cell() anchor's target) is the FIRST declared tilemap
	// layer — level structure, so it resolves independently of item order.
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

// level_grid_info derives the cell()-anchor grid reference from the level's
// FIRST tilemap layer (declaration order). Dimensions read the dedented rows
// as parsed; the §18 §5 rectangularity gate fires when the layer itself
// expands, so a ragged grid still rejects even when a cell() resolves first.
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

// is_top_level_scope reports whether a scope is the level's depth-0 scope — the
// only depth a placement contributes a TOP-LEVEL symbol-table entry. A loop body
// shares the parent's name_prefix (a loop is repetition, not a namespace), so a
// named placement inside a top-level loop still records as top-level; a prefab
// body extends the prefix (`Arena.left_gun`), so its members never do.
is_top_level_scope :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope) -> bool {
	return scope.name_prefix == ctx.level.name
}

// expand_items expands one body's items in DECLARATION order (spec §17.4 — the
// spawn list is source order with prefabs/loops expanded in place; a §18 §3
// tilemap layer's markers expand row-major where the layer is declared). It
// walks the interleaved `items` record (parser order across the kinds),
// dispatching each to its per-kind slice: a `place` of a prefab type stamps the
// prefab and a `place` of a schema thing emits a spawn; a `for` expands its body
// once per loop value with the var bound; a `tilemap` lowers to its tile layer
// plus its marker spawns. A nested prefab DECLARATION carries no spawn — it is
// a type stamped only where a `place <Nested>` names it. tilemaps is the
// level's layer slice — a prefab or for body admits no tilemap (the grammar's
// PrefabItem), so those callers pass nil.
expand_items :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, items: []Flvl_Item, places: []Flvl_Place, fors: []Flvl_For, tilemaps: []Flvl_Tilemap, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	for item in items {
		switch item.kind {
		case .Place:
			expand_place(ctx, scope, places[item.index], bounds_min, bounds_max) or_return
		case .For:
			expand_for(ctx, scope, fors[item.index], bounds_min, bounds_max) or_return
		case .Prefab:
			// A nested prefab declaration is a type, not a placement — no spawn.
		case .Tilemap:
			expand_tilemap(ctx, scope, tilemaps[item.index], bounds_min, bounds_max) or_return
		}
	}
	return .None
}

// expand_for expands a `for <i> in <lo>..<hi> { … }` once per value (inclusive
// low, exclusive high — spec §17.1 `for i in 0..5` is five iterations). The loop
// var is folded to an i64 bound and bound into a child scope so a body offset
// (`center.offset(x: -48 + i * 24)`) reads it; the body shares the parent's
// origin and name prefix (a loop is repetition, not a new namespace).
expand_for :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, loop: Flvl_For, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	lo := fold_int(scope, loop.lo) or_return
	hi := fold_int(scope, loop.hi) or_return
	// The loop body's visible prefab set is the enclosing scope's plus the loop's
	// own nested declarations, so a body `place <Nested>` resolves to depth.
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

// expand_place stamps one placement. A `place <Type>` whose type is a declared
// prefab expands the prefab in a child scope at the resolved placement point
// (data composition, not a spawn); a `place <Type>` whose type is a schema thing
// emits one spawn. An unknown type — neither prefab nor schema thing — is the
// unknown-thing-type reject.
expand_place :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, place: Flvl_Place, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	if prefab, is_prefab := find_prefab(scope.prefabs, place.type_name); is_prefab {
		return stamp_prefab(ctx, scope, place, prefab, bounds_min, bounds_max)
	}
	// A placed type that is not a prefab must be a schema thing the things module
	// exports. The things-module existence was proven up front (bake_flvl); here
	// the schema Ast supplies the thing's full fields. A type that is neither a
	// prefab nor a schema thing is Unknown_Thing_Type.
	if _, is_thing := schema_thing(ctx.schema, place.type_name); is_thing {
		return emit_thing_spawn(ctx, scope, place, bounds_min, bounds_max)
	}
	return .Unknown_Thing_Type
}

// ── Coordinate folding ──────────────────────────────────────────────────────

// coord_of_components folds a parsed coordinate tuple (the bounds corners) to a
// Baked_Coord of the level's arity, rejecting a wrong-arity tuple (the
// dimensionality check on the bounds themselves). Each component folds to a
// Fixed via fold_fixed over an empty scope (bounds corners are literal numbers,
// no anchors or vars).
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

// resolve_position folds an `at <where>` anchor expression to a Baked_Coord
// (spec §17.1 "Killing raw coordinates"): a bounds anchor (`center`,
// `left_edge.center`, `right_edge.center`, `origin`), an instance-relative base
// (a sibling placement's name), and `.offset(x:, y:[, z:])`. The fold is over
// the saturating Q32.32 kernel so the coordinate is bit-identical everywhere.
resolve_position :: proc(scope: ^Bake_Scope, expr: Flvl_Anchor_Expr, bounds_min, bounds_max: Baked_Coord, dim: Flvl_Dim) -> (coord: Baked_Coord, err: Bake_Error) {
	return fold_anchor(scope, expr, bounds_min, bounds_max, dim)
}

// fold_anchor folds an anchor/offset expression to a coordinate. The closed form
// set: a bare name (a bounds anchor or a sibling base), a `.center` member step
// (the midpoint of a named edge), a `.offset(…)` call (a per-component delta),
// and the recursive base of each. A form outside this set is Bad_Coordinate.
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
		// A raw number/string/arithmetic node is not a placement anchor — the
		// grammar kills raw coordinates (spec §17.1); these only appear inside an
		// `.offset(…)` arg, folded by anchor_call.
		return Baked_Coord{}, .Bad_Coordinate
	}
	return Baked_Coord{}, .Bad_Coordinate
}

// named_anchor resolves a bare anchor name to a coordinate: the bounds anchors
// (`origin`, `center`, `left_edge`, `right_edge`, `top_edge`, `bottom_edge`) and
// an instance-relative base (a sibling placement's name in scope). An unknown
// name is Unresolved_Name — the same reject a dangling reference gives, since an
// anchor naming no instance is itself a dangling reference.
named_anchor :: proc(scope: ^Bake_Scope, name: string, bounds_min, bounds_max: Baked_Coord, dim: Flvl_Dim) -> (coord: Baked_Coord, err: Bake_Error) {
	mid_x := fixed_div(fixed_add(bounds_min.x, bounds_max.x), to_fixed(2))
	mid_y := fixed_div(fixed_add(bounds_min.y, bounds_max.y), to_fixed(2))
	mid_z := fixed_div(fixed_add(bounds_min.z, bounds_max.z), to_fixed(2))
	switch name {
	case "origin":
		// `origin` is the scope's LOCAL origin: the level's bounds_min at the
		// root, the prefab placement point inside a prefab body (spec §17.1 — a
		// prefab places its members against its own local origin).
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
	// An instance-relative base: a prior sibling placement's resolved pos.
	if sib, found := scope.siblings[name]; found {
		return sib, .None
	}
	return Baked_Coord{}, .Unresolved_Name
}

// anchor_member applies a `.member` step to a resolved base coordinate. The only
// coordinate-valued member is `.center` (the midpoint of a named edge:
// `right_edge.center` is the edge's coordinate, already its midpoint, so
// `.center` on an edge is the edge coordinate itself). A non-`center` member is
// Bad_Coordinate (an `.offset` is a CALL, handled by anchor_call).
anchor_member :: proc(base: Baked_Coord, member: string, bounds_min, bounds_max: Baked_Coord) -> (coord: Baked_Coord, err: Bake_Error) {
	if member == "center" {
		// `<edge>.center` is the edge's midpoint; named_anchor already returns the
		// edge as its midpoint, so `.center` is identity over the edge coordinate.
		return base, .None
	}
	return Baked_Coord{}, .Bad_Coordinate
}

// anchor_call folds a call postfix step on a coordinate. `.offset(x:, y:[, z:])`
// adds the per-component deltas to its receiver (spec §17.1); the bare
// `cell(col, row)` call is the §18 §3 grid anchor, resolved to the cell's
// center against the level's grid reference. Any other call form is
// Bad_Coordinate. The offset callee is a `<base>.offset` Member_Expr whose
// receiver folds to the base coordinate; each named arg's value folds to a
// Fixed delta over the loop-var scope.
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

// resolve_cell_anchor folds the `cell(col, row)` grid anchor (spec §18 §3) to
// the named cell's center coordinate. The two args are positional integers
// (0-indexed col then row, origin top-left — the dungeon example's reading),
// folded over the loop-var scope like any range bound. A col/row outside the
// grid — or any cell() in a level with no tilemap layer — is the §18 §5
// Cell_Outside_Grid gate; a named arg or a wrong arity is a malformed anchor
// (Bad_Coordinate), the grammar-shape reject, not the range gate.
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
	return cell_center(col, row, grid.cell_size, bounds_min, bounds_max, dim), .None
}

// cell_center is the grid→world mapping (spec §18 §3 — a marker spawns "at its
// cell center", and cell() is the same point): the grid's top-left corner
// anchors at (bounds_min.x, bounds_max.y) — row 0 is the TOP row, the
// picture's reading, with the world's y-up pinned by the top_edge/bottom_edge
// anchors — so col grows +x and row grows -y. The fold is over the Q32.32
// kernel (a half-cell is exact in Fixed even for an odd cell size), so the
// center is bit-identical everywhere. A 3d level's grid layer sits at the
// bounds' z floor (stacked layers giving the third axis ride a later story).
cell_center :: proc(col, row: i64, cell_size: i64, bounds_min, bounds_max: Baked_Coord, dim: Flvl_Dim) -> Baked_Coord {
	half := fixed_div(to_fixed(cell_size), to_fixed(2))
	x := fixed_add(bounds_min.x, fixed_add(to_fixed(int_mul(col, cell_size)), half))
	y := fixed_sub(bounds_max.y, fixed_add(to_fixed(int_mul(row, cell_size)), half))
	coord := Baked_Coord{dim = dim, x = x, y = y}
	if dim == .D3 {
		coord.z = bounds_min.z
	}
	return coord
}

// fold_fixed folds an offset-arithmetic expression to a Fixed (spec §17.1
// `-48 + i * 24`). It evaluates over the saturating Q32.32 kernel — a literal
// Int lifts to Fixed, a Fixed literal is its bits, a loop var lifts its bound
// value, and the four binary ops route through fixed_add/sub/mul/div. Anchors
// have no Fixed value (a name in an offset arg must be a loop var), so a non-var
// name is Bad_Coordinate.
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
		// A string is a socket name and a member/call is an anchor — none has a
		// scalar offset value.
		return Fixed(0), .Bad_Coordinate
	}
	return Fixed(0), .Bad_Coordinate
}

// fold_int folds a for-range bound to an i64 (spec §17.1 `0..5`). Range bounds
// are literal numbers (or loop vars in a nested loop), so the fold is over the
// integer kernel — a Fixed-valued bound truncates toward zero (fixed_trunc).
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

// ── Bounds gate ─────────────────────────────────────────────────────────────

// within_bounds reports whether a coordinate lies inside the level's bounds box
// (inclusive of the corners). A placement outside the bounds is the §17.4
// out-of-bounds compile error.
within_bounds :: proc(coord, bounds_min, bounds_max: Baked_Coord) -> bool {
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

// ── Thing spawn ─────────────────────────────────────────────────────────────

// emit_thing_spawn resolves one schema-thing placement to a spawn (and a Ref
// table entry when named): it claims the name (duplicate-name gate), resolves
// `at` to a `pos` coordinate (at-without-pos + out-of-bounds gates), resolves
// each param against the thing's schema (param-not-on-schema + Ref typing), and
// records the resolved spawn. The instance's coordinate is recorded as a sibling
// so a later instance-relative base resolves against it.
emit_thing_spawn :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, place: Flvl_Place, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	thing, _ := schema_thing(ctx.schema, place.type_name)

	// `at` writes `pos`: the thing must declare a `pos` of the level's arity
	// (spec §17.1 — the dimensionality check). No `pos`, or a wrong-arity `pos`,
	// is at-without-pos.
	pos_field, has_pos := schema_field(thing, "pos")
	if !has_pos || !pos_arity_matches(pos_field, ctx.level.dim) {
		return .At_Without_Pos
	}

	pos := resolve_position(scope, place.position, bounds_min, bounds_max, ctx.level.dim) or_return
	if !within_bounds(pos, bounds_min, bounds_max) {
		return .Outside_Bounds
	}

	// The level-qualified name and the instance's stable Id (a counter id for
	// anonymous scenery). A named instance claims its qualified name (duplicate
	// gate) and gets a Ref table entry.
	id: u64
	if place.has_name {
		qualified := qualify(scope.name_prefix, place.instance_name)
		if ctx.names[qualified] {
			return .Duplicate_Name
		}
		ctx.names[qualified] = true
		id = stable_id(qualified)
		ref_index := len(ctx.refs)
		append(&ctx.refs, Baked_Ref{
			name       = qualified,
			local_name = place.instance_name,
			thing_type = place.type_name,
			id         = id,
		})
		// A depth-0 named instance is a top-level symbol-table field; a nested
		// (prefab-member) named instance is reached through its prefab symbol, so
		// only top-level placements append to the seam's `data <Level>` field order.
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

	// `facing` writes `facing` (spec §17.1) — folded to a Fixed angle (2d) over
	// the offset kernel. A facing on a thing with no `facing` field is allowed to
	// pass through as a spawn value; the per-field facing schema check is the
	// runtime's, not a §17.4 bake gate.
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

// ── Tilemap expansion (§18 §3) ──────────────────────────────────────────────

// expand_tilemap lowers one `tilemap` layer where it is declared: the layer
// name claims its level-qualified name (one namespace with instances — a layer
// and a marker cannot collide silently), the dedented grid passes the §18 §5
// rectangularity gate, the legend's tile binds resolve through the
// project-global tile table into the palette (LEGEND order, used or not —
// resolution gates a declared name, not its first use), and the grid walks
// row-major: a tile cell records its palette index, an `empty` or marker cell
// records no tile, and a marker cell emits its spawn at the cell center — the
// §18 §3 row-major derivation that makes marker ids deterministic.
expand_tilemap :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, tilemap: Flvl_Tilemap, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	qualified := qualify(scope.name_prefix, tilemap.name)
	if ctx.names[qualified] {
		return .Duplicate_Name
	}
	ctx.names[qualified] = true

	// The §18 §5 rectangularity gate, AFTER the parser's dedent (the grammar's
	// strip-before-gate order): every dedented row carries the same column
	// count, and a rowless or columnless grid is degenerate — also the gate.
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

	// The palette: the legend's tile binds in LEGEND order, de-duplicated by
	// name (two chars may bind one tile), each resolved through the
	// project-global table — an unresolved name is the §18 §5 gate whether or
	// not the grid uses the char. Each palette tile carries its atlas-cell
	// coordinate (the §19 textured-render link, v17), and the layer's single atlas
	// is resolved from the palette: every tile shares one atlas (the §18 §3 layer
	// draws from one tileset's atlas), so a palette mixing atlases is the
	// Tileset_Atlas_Conflict gate — refused, never silently resolved to one atlas.
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

	// The row-major walk: terrain cells take their palette index; empty and
	// marker cells take no tile (a marker places an entity, it paints no
	// terrain); marker cells emit their spawns in walk order.
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
		// The grid→world anchor: the grid's top-left corner sits at
		// (bounds_min.x, bounds_max.y) — the same corner cell_center anchors
		// the marker/cell() lowering on, carried so the artifact's mapping is
		// self-describing (v12, the tilemap-anchor ADR).
		anchor_x  = bounds_min.x,
		anchor_y  = bounds_max.y,
		// The layer's single tileset atlas (the §19 textured-render link, v17) —
		// "" only for a degenerate all-empty/all-marker layer with no tile palette.
		atlas     = layer_atlas,
		palette   = palette[:],
		cells     = cells,
	})
	return .None
}

// find_legend_entry resolves a grid char against the legend, walked by index
// in declaration order (first match wins, deterministically). found = false is
// the Char_Not_In_Legend gate's trigger.
find_legend_entry :: proc(legend: []Flvl_Legend_Entry, char: u8) -> (entry: Flvl_Legend_Entry, found: bool) {
	for candidate in legend {
		if candidate.char == char {
			return candidate, true
		}
	}
	return Flvl_Legend_Entry{}, false
}

// palette_index finds a tile name's slot in the layer palette, walked by
// index; -1 when absent (the dedupe probe and the cell-index lookup share it).
palette_index :: proc(palette: []Baked_Tile, name: string) -> int {
	for tile, i in palette {
		if tile.name == name {
			return i
		}
	}
	return -1
}

// emit_marker_spawn lowers one marker cell to its spawn (spec §18 §3): the
// marker's thing type must be a schema thing with a `pos` of the level's arity
// (the same Unknown_Thing_Type / At_Without_Pos floors a `place` clears), the
// pos is the CELL CENTER, and a named marker claims its level-qualified name
// exactly like a named placement — a Baked_Ref entry, a top-level seam symbol,
// and a sibling coordinate an instance-relative anchor can read. A duplicate
// named marker is therefore the Duplicate_Name gate (§18 §5); an anonymous
// marker takes the declaration-order counter id. A marker carries no params
// and no facing — every field beyond `pos` defaults (the dungeon schema's
// reading).
emit_marker_spawn :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, entry: Flvl_Legend_Entry, col, row: i64, cell_size: i64, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	thing, is_thing := schema_thing(ctx.schema, entry.spawn_type)
	if !is_thing {
		return .Unknown_Thing_Type
	}
	pos_field, has_pos := schema_field(thing, "pos")
	if !has_pos || !pos_arity_matches(pos_field, ctx.level.dim) {
		return .At_Without_Pos
	}

	pos := cell_center(col, row, cell_size, bounds_min, bounds_max, ctx.level.dim)
	if !within_bounds(pos, bounds_min, bounds_max) {
		return .Outside_Bounds
	}

	id: u64
	if entry.has_spawn_name {
		qualified := qualify(scope.name_prefix, entry.spawn_name)
		if ctx.names[qualified] {
			return .Duplicate_Name
		}
		ctx.names[qualified] = true
		id = stable_id(qualified)
		ref_index := len(ctx.refs)
		append(&ctx.refs, Baked_Ref{
			name       = qualified,
			local_name = entry.spawn_name,
			thing_type = entry.spawn_type,
			id         = id,
		})
		// A tilemap is a LevelItem, so its named markers are always depth-0
		// seam symbols — "the seam gains the named markers as Refs" (§18 §3).
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

// resolve_params resolves one placement's flat (non-dotted) params against the
// placed thing's schema (spec §17.1 — params typecheck against the schema). A
// param key naming no field is param-not-on-schema; a reference-by-name value on
// a Ref[T] field resolves to the target instance's Id and checks the target's
// thing type matches T; a non-reference value folds to a Fixed scalar. Dotted
// override keys are a prefab concern (handled by stamp_prefab), so a dotted key
// here is param-not-on-schema (a flat placement has no nested members).
resolve_params :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, thing: Thing_Node, params: []Flvl_Param) -> (out: []Baked_Param, err: Bake_Error) {
	list := make([dynamic]Baked_Param, 0, len(params), context.temp_allocator)
	for param in params {
		// A flat placement's params are single-segment keys; a dotted path on a
		// non-prefab placement names no field on the thing.
		if len(param.path) != 1 {
			return nil, .Param_Not_On_Schema
		}
		field_name := param.path[0]
		field, has_field := schema_field(thing, field_name)
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

// resolve_param_value resolves one param value against its schema field. A
// reference-by-name (a bare LOWER_IDENT) on a Ref[T] field resolves to the named
// instance's Id and checks the target's thing type matches T (unresolved-name +
// type-mismatched-ref gates); a value on a non-Ref field folds to a Fixed scalar.
// A bare name on a non-Ref field is treated as a reference target and rejected as
// a type mismatch (a non-Ref field cannot hold a reference).
resolve_param_value :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, field: Field_Decl, value: Flvl_Anchor_Expr) -> (baked: Baked_Param, err: Bake_Error) {
	target_type, is_ref_field := ref_target_type(field)
	if name_expr, is_name := value.(^Flvl_Name_Expr); is_name && !is_loop_var(scope, name_expr.name) {
		// A bare name (not a loop var) is a reference-by-name. It is only valid on
		// a Ref[T] field; on any other field it is a type mismatch.
		if !is_ref_field {
			return Baked_Param{}, .Type_Mismatched_Ref
		}
		ref, found := find_ref(ctx.refs[:], name_expr.name)
		if !found {
			return Baked_Param{}, .Unresolved_Name
		}
		if ref.thing_type != target_type {
			return Baked_Param{}, .Type_Mismatched_Ref
		}
		return Baked_Param{is_ref = true, ref_id = ref.id}, .None
	}
	// A non-reference value: fold to a Fixed scalar. A Ref[T] field cannot take a
	// scalar value, so a scalar on a Ref field is a type mismatch.
	if is_ref_field {
		return Baked_Param{}, .Type_Mismatched_Ref
	}
	folded := fold_fixed(scope, value) or_return
	return Baked_Param{value = folded}, .None
}

// is_loop_var reports whether a bare name is an in-scope loop var (so a `count: i`
// param reads the loop counter rather than being misread as a reference-by-name).
is_loop_var :: proc(scope: ^Bake_Scope, name: string) -> bool {
	_, found := scope.loop_vars[name]
	return found
}

// ── Prefab stamping ─────────────────────────────────────────────────────────

// stamp_prefab expands one placed prefab in a child scope at the resolved
// placement point (spec §17.1 — a prefab places its members against its own
// local origin). The prefab's members become Ref table entries under the
// placement's level-qualified name (`Arena.right_gun.cannon`), and the placement
// records a Baked_Prefab_Instance of the member Refs. Dotted-path overrides on
// the placement apply by name-path into the prefab's members, deterministically
// (outer placement over nested default, declaration order — spec §17.1).
stamp_prefab :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, place: Flvl_Place, prefab: Flvl_Prefab, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	// The prefab's local origin is the placement's resolved `at` point; member
	// `origin`/instance-relative anchors resolve against it.
	origin := resolve_position(scope, place.position, bounds_min, bounds_max, ctx.level.dim) or_return
	if !within_bounds(origin, bounds_min, bounds_max) {
		return .Outside_Bounds
	}

	// The placement's name prefixes every member's qualified name. A prefab
	// placement is named (anonymous prefab scenery is uncommon but allowed — it
	// takes the type name as a non-claiming prefix so members still qualify).
	prefix := scope.name_prefix
	inst_name := place.instance_name
	if place.has_name {
		prefix = qualify(scope.name_prefix, place.instance_name)
		if ctx.names[prefix] {
			return .Duplicate_Name
		}
		ctx.names[prefix] = true
	} else {
		prefix = qualify(scope.name_prefix, strings.to_lower(place.type_name, context.temp_allocator))
		inst_name = strings.to_lower(place.type_name, context.temp_allocator)
	}

	// The body's visible prefab set is the enclosing scope's prefabs plus this
	// prefab's nested declarations, so a member `place <Nested>` stamps a nested
	// prefab to arbitrary depth (spec §17.1).
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

	// Record the member-Ref count before expansion so the prefab instance can
	// slice exactly its own members off the refs list.
	before := len(ctx.refs)

	// Apply overrides into the member declarations before expanding (the
	// declaration-order, outer-over-nested fold). An override naming a member the
	// prefab never places is prefab-member-not-placed.
	merged := apply_overrides(ctx, prefab, place.params) or_return

	expand_prefab_body(ctx, &child, merged, bounds_min, bounds_max) or_return

	// Collect the prefab instance's member Refs (the entries added during this
	// expansion).
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
	// A depth-0 NAMED prefab placement is a top-level symbol-table field (a
	// `<Level><PrefabType>` record field); an anonymous prefab is not exposed in
	// the seam's symbol table, and a nested prefab is reached through its parent.
	if place.has_name && is_top_level_scope(ctx, scope) {
		append(&ctx.symbols, Baked_Symbol{
			kind       = .Prefab,
			local_name = inst_name,
			index      = prefab_index,
		})
	}
	return .None
}

// expand_prefab_body expands a prefab's (override-merged) body in declaration
// order, sharing the child scope (the prefab's local origin, the overridden
// member set, and the visible nested-prefab declarations). It walks the shared
// expand_items over the prefab's source-order `items` record — apply_overrides
// preserves the per-kind slice positions the items index into, so the merged
// body keeps its declaration order.
expand_prefab_body :: proc(ctx: ^Bake_Context, scope: ^Bake_Scope, prefab: Flvl_Prefab, bounds_min, bounds_max: Baked_Coord) -> Bake_Error {
	return expand_items(ctx, scope, prefab.items, prefab.places, prefab.fors, nil, bounds_min, bounds_max)
}

// apply_overrides folds a placement's dotted-path overrides into a clone of the
// prefab's member declarations (spec §17.1 — outer placement over nested default,
// declaration order). An override key is a dotted path into a member's field
// (`cannon.rate`): the head segment names a member placement, the tail names a
// field on that member's params. An override naming a member the prefab never
// places is prefab-member-not-placed; an override of a field not on the member's
// schema is param-not-on-schema (checked when the member's params resolve).
apply_overrides :: proc(ctx: ^Bake_Context, prefab: Flvl_Prefab, overrides: []Flvl_Param) -> (merged: Flvl_Prefab, err: Bake_Error) {
	merged = prefab
	places := make([dynamic]Flvl_Place, len(prefab.places), context.temp_allocator)
	copy(places[:], prefab.places)

	for override in overrides {
		if len(override.path) < 2 {
			// A single-segment key on a prefab placement names no member field —
			// a prefab override is always a dotted path into a member.
			return Flvl_Prefab{}, .Prefab_Member_Not_Placed
		}
		member_name := override.path[0]
		field_path := override.path[1:]
		member_idx := find_place_index(places[:], member_name)
		if member_idx < 0 {
			return Flvl_Prefab{}, .Prefab_Member_Not_Placed
		}
		// Merge the override as a param on the member placement: a flat field key
		// (`rate`) for a depth-1 override, retained as the member's param so the
		// member's resolve_params checks it against the member thing's schema.
		places[member_idx].params = merge_param(places[member_idx].params, field_path, override.value)
	}
	merged.places = places[:]
	return merged, .None
}

// merge_param adds (or replaces) one param on a member placement's param list:
// the override's field path becomes the param key, so the member's resolve_params
// (or a deeper apply_overrides for a nested prefab member) checks it against the
// schema. An existing param with the same key is replaced (the outer override
// wins — spec §17.1 outer-over-nested).
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

// find_place_index finds a member placement by its instance name within a
// prefab's placement list, walked by index. A negative result means the prefab
// never places a member of that name — the prefab-member-not-placed gate.
find_place_index :: proc(places: []Flvl_Place, name: string) -> int {
	for place, i in places {
		if place.has_name && place.instance_name == name {
			return i
		}
	}
	return -1
}

// ── Lookups & ids ───────────────────────────────────────────────────────────

// find_prefab finds a prefab declaration by type name in the level's top-level
// prefab list, walked by index. A `place <Type>` whose type matches stamps the
// prefab rather than emitting a thing spawn.
find_prefab :: proc(prefabs: []Flvl_Prefab, name: string) -> (prefab: Flvl_Prefab, found: bool) {
	for candidate in prefabs {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Flvl_Prefab{}, false
}

// find_ref finds a baked Ref table entry by its BARE local name (the name a
// reference-by-name writes — `gate: plate` names `plate`), walked by index. A
// reference is resolved against the entries claimed before it, so a forward
// reference (a name placed later) is Unresolved_Name at the point it is read —
// declaration order is the resolution order.
find_ref :: proc(refs: []Baked_Ref, local_name: string) -> (ref: Baked_Ref, found: bool) {
	for candidate in refs {
		if candidate.local_name == local_name {
			return candidate, true
		}
	}
	return Baked_Ref{}, false
}

// qualify joins a name prefix and a bare instance name into a level-qualified
// dotted name (`Arena` + `exit` → `Arena.exit`; `Arena.right_gun` + `cannon` →
// `Arena.right_gun.cannon`). The qualified name is the stable-Id seed and the
// duplicate-name key.
qualify :: proc(prefix, name: string) -> string {
	return strings.concatenate({prefix, ".", name}, context.temp_allocator)
}

// ── Seam layering gate (§17.2) ──────────────────────────────────────────────

// module_is_behavior reports whether a parsed module is a §17.2 BEHAVIOR module:
// one that declares a `behavior` or a `pipeline`. The generated seam (a
// `.gen.fun`) must import schema modules only (`thing`/`data`/`enum`/`signal`),
// so importing a behavior module breaks the acyclic schema→seam→behavior layering
// — the check below reads this predicate over each of the seam's imports.
module_is_behavior :: proc(ast: Ast) -> bool {
	return len(ast.behaviors) > 0 || len(ast.pipelines) > 0
}

// check_flvl_seam_layering enforces the §17.2 module layering on a generated level seam (the bake-local arm; the project-read arm is project.odin's check_seam_layering): a
// `.gen.fun` seam imports SCHEMA MODULES ONLY, never a behavior module
// (spec §17.2 — "a .gen.fun importing a behavior module is a compile error",
// keeping the import graph acyclic by construction). It walks the seam's USER
// imports (engine.* stdlib imports are never behavior modules) and rejects with
// Seam_Imports_Behavior the first that names a module declaring a behavior or
// pipeline. The module_kind lookup maps each user module name to its parsed Ast
// (the project's module set) so the behavior predicate reads the real
// declarations; a user import naming an unknown module is left to the resolver's
// own Unknown_Module gate (this check only judges the layering of KNOWN modules).
check_flvl_seam_layering :: proc(seam: Ast, module_asts: map[string]Ast) -> Bake_Error {
	for imp in seam.imports {
		module := imp.segments[0]
		// A stdlib import (the reserved `engine` root) is never a behavior module.
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

// stable_id derives a named instance's Id from its level-qualified name
// (spec §17.2 — "stable ids by name", so a Ref is constant across loads, saves,
// and replays). It is the FNV-1a 64-bit hash of the qualified-name bytes: a pure
// function of the name, deterministic on every machine, and renaming the instance
// changes the Id (the propagation property — a renamed name disappears from the
// seam, so every reader stops compiling at the spot to fix).
stable_id :: proc(qualified_name: string) -> u64 {
	hash: u64 = 0xcbf29ce484222325 // FNV-1a 64-bit offset basis
	for b in transmute([]u8)qualified_name {
		hash ~= u64(b)
		hash *= 0x100000001b3 // FNV-1a 64-bit prime
	}
	return hash
}
