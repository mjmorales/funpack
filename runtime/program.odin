package funpack_runtime

Enum_Kind :: enum {
	None,
	Axis,
	Button,
	Collision_Layer,
	Num,
}

Enum_Variant :: struct {
	name:    string,
	payload: string,
}

Enum_Decl :: struct {
	name:     string,
	kind:     Enum_Kind,
	variants: []Enum_Variant,
}

Field_Decl :: struct {
	name:            string,
	type:            string,
	has_default:     bool,
	default_encoded: string,
	migrate_from:    string,
	has_from:        bool,
	migrate_with:    string,
	has_with:        bool,
}

Data_Decl :: struct {
	name:       string,
	mutable:    bool,
	fields:     []Field_Decl,
	prior_name: string,
	has_prior:  bool,
}

Signal_Decl :: struct {
	name:   string,
	fields: []Field_Decl,
}

Thing_Decl :: struct {
	name:      string,
	singleton: bool,
	gtags:     []string,
	fields:    []Field_Decl,
}

Function_Kind :: enum {
	Fn,
	Const,
	Bindings,
	Startup,
}

Param_Decl :: struct {
	name: string,
	type: string,
}

Function_Decl :: struct {
	name:        string,
	kind:        Function_Kind,
	params:      []Param_Decl,
	return_type: string,
	span_module: string,
	span_line:   int,
	body:        []Node,
}

Query_Index_Kind :: enum {
	Index,
	Spatial,
}

Index_Req :: struct {
	kind:  Query_Index_Kind,
	thing: string,
	field: string,
}

Query_Decl :: struct {
	name:        string,
	params:      []Param_Decl,
	return_type: string,
	indexes:     []Index_Req,
	span_module: string,
	span_line:   int,
	body:        []Node,
}

Behavior_Decl :: struct {
	name:     string,
	on_thing: string,
	stage:    string,
	contract: string,
	gtags:    []string,
	params:   []Param_Decl,
	emits:    []string,
	body:     []Node,
}

Probe_Kind :: enum {
	Break,
	Log,
	Watch,
	Trace,
}

Probe_Decl :: struct {
	kind:   Probe_Kind,
	target: string,
	body:   []Node,
}

Pipeline_Step :: struct {
	ordinal:  int,
	stage:    string,
	behavior: string,
}

Signal_Endpoint :: struct {
	ordinal:  int,
	behavior: string,
}

Signal_Route :: struct {
	signal:    string,
	producers: []Signal_Endpoint,
	consumers: []Signal_Endpoint,
}

Spawn_Value_Kind :: enum {
	Int,
	Fixed,
	Variant,
	Vec2,
	Record,
	List,
}

Spawn_Field :: struct {
	name:    string,
	kind:    Spawn_Value_Kind,
	int_val: i64,
	fixed:   Fixed,
	variant: string,
	vec2_x:  Fixed,
	vec2_y:  Fixed,
	encoded: string,
}

Spawn_Command :: struct {
	thing:  string,
	fields: []Spawn_Field,
}

Binding :: struct {
	kind:   string,
	player: string,
	action: string,
	source: string,
}

Entrypoint :: struct {
	name:      string,
	pipeline:  string,
	tick_hz:   int,
	logical_w: int,
	logical_h: int,
	bindings:  string,
	has_seed:  bool,
	seed:      i64,
}

Project_Meta :: struct {
	name:    string,
	version: string,
}

Program :: struct {
	schema_version: int,
	meta:           Project_Meta,
	enums:          []Enum_Decl,
	data:           []Data_Decl,
	signals:        []Signal_Decl,
	things:         []Thing_Decl,
	functions:      []Function_Decl,
	behaviors:      []Behavior_Decl,
	pipeline:       []Pipeline_Step,
	routing:        []Signal_Route,
	setup:          []Spawn_Command,
	bindings:       []Binding,
	entrypoint:     Entrypoint,
	queries:        []Query_Decl,
	tilemaps:       []Tile_Layer,
	navs:           []Nav_Graph,
	assets:         Asset_Set,
	probes:         []Probe_Decl,
	registry:       Action_Registry,
}

program_query :: proc(program: ^Program, name: string) -> ^Query_Decl {
	for &query in program.queries {
		if query.name == name {
			return &query
		}
	}
	return nil
}

Thing_Id :: distinct u32

Thing_Table :: struct {
	thing:     string,
	singleton: bool,
	next_id:   Thing_Id,
}

World :: struct {
	tables:   []Thing_Table,
	tilemaps: []Tile_Layer,
}

world_find_table :: proc(world: ^World, thing: string) -> ^Thing_Table {
	for &table in world.tables {
		if table.thing == thing {
			return &table
		}
	}
	return nil
}

new_world :: proc(program: Program, allocator := context.allocator) -> World {
	tables := make([]Thing_Table, len(program.things), allocator)
	for thing, i in program.things {
		tables[i] = Thing_Table {
			thing     = thing.name,
			singleton = thing.singleton,
			next_id   = Thing_Id(0),
		}
	}
	return World{tables = tables, tilemaps = program.tilemaps}
}
