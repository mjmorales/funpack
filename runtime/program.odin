// The in-memory game model the runtime executes over (docs/artifact-format.md
// §17 step 4). `Program` is the loaded artifact: the enum/data/signal/thing
// type descriptors, the function and behavior bodies (serialized checked-AST
// node forests, §2.7), the one flattened pipeline total order (§11), the signal
// routing map (§12), the fully-evaluated setup Spawn batch (§13, fixed literals
// decoded bit-exact through the kernel), the binding table (§14), and the
// entrypoint wiring (§15).
//
// `World` is the empty runtime substrate the sim executes over:
// thing tables keyed by stable Id and the singleton row slots. This file
// BUILDS the empty tables; it does NOT run setup or any tick — the spawn batch
// is loaded into `Program.setup`, but applying it (and folding the pipeline)
// belongs to the tick transaction.
package funpack_runtime

// --- Type descriptors (§5–§8) --------------------------------------------

// Enum_Kind is the §03 §4 role kind ascribed to an enum, or None. The kind is
// type-constitutive — only an Axis-kinded enum binds to an analog input (§23) —
// so it travels with the enum in the artifact.
Enum_Kind :: enum {
	None, // `-` in the artifact
	Axis,
	Button,
	Collision_Layer,
	Num,
}

Enum_Variant :: struct {
	name:    string,
	payload: string, // "unit", "tuple K", or "struct K" verbatim (pong is all unit)
}

Enum_Decl :: struct {
	name:     string,
	kind:     Enum_Kind,
	variants: []Enum_Variant,
}

// Field_Decl is one declared field on a data/signal/thing: its name, its type
// (a name; a generic is `Ctor[Arg]`), and its default. `has_default` carries
// whether `default_encoded` is meaningful (the §6 `-` vs `=ENCODED` flag).
// The migrate halves are the v8 [data] `migrate FROM WITH` carry — the §05 §6
// rename/retype metadata the schema-diff kernel reads (schema_diff.odin); only
// a [data] field ever carries them (the artifact emits the line nowhere else),
// and the has_* flags discriminate absence exactly as has_default does.
Field_Decl :: struct {
	name:            string,
	type:            string,
	has_default:     bool,
	default_encoded: string, // the raw `ENCODED` token after `=`, decoded by position
	migrate_from:    string, // the §05 §6 prior key (v8 `migrate FROM …`); meaningful iff has_from
	has_from:        bool,
	migrate_with:    string, // the §05 §6 conversion fn name (v8 `migrate … WITH`); meaningful iff has_with
	has_with:        bool,
}

Data_Decl :: struct {
	name:       string,
	mutable:    bool, // true for `mut data` (§03 §7)
	fields:     []Field_Decl,
	prior_name: string, // a renamed TYPE declaration's prior name (v8 decl-level `migrate FROM -`); meaningful iff has_prior
	has_prior:  bool,
}

Signal_Decl :: struct {
	name:   string,
	fields: []Field_Decl, // mut is always false for a signal (§7)
}

Thing_Decl :: struct {
	name:      string,
	singleton: bool, // true for a singleton: a guaranteed-single-row thing (§06 §2)
	gtags:     []string, // registered @gtag set, source order (§05 registry)
	fields:    []Field_Decl, // the blackboard schema
}

// --- Function and behavior bodies (§9, §10) ------------------------------

Function_Kind :: enum {
	Fn, // a pure helper
	Const, // a module-level `let`
	Bindings, // the one §23 fn() -> Bindings
	Startup, // the one §06 setup() -> [Spawn]
}

Param_Decl :: struct {
	name: string,
	type: string,
}

// Function_Decl is a module-level fn/let/bindings/setup. The body is the carried
// node forest (§2.7), so the runtime evaluates it from the artifact alone — a
// const like BOARD or a Spawn that reads BOARD.w resolves against the
// interpreted constant, no source needed.
Function_Decl :: struct {
	name:        string,
	kind:        Function_Kind,
	params:      []Param_Decl,
	return_type: string,
	span_module: string, // §15 module name — diagnostic provenance only
	span_line:   int, // 1-based source line — diagnostic provenance only
	body:        []Node, // body_count top-level statement subtrees, source order
}

// --- State queries and their index requirements (§16, schema v9) ----------

// Query_Index_Kind is the closed §05 §3 directive vocabulary: an `@index`
// reverse/key lookup or a `@spatial` radius/nearest structure. The kind decides
// which engine-maintained shape index.odin builds for the requirement.
Query_Index_Kind :: enum {
	Index,
	Spatial,
}

// Index_Req is one declared §05 §3 index requirement carried on a query
// (`index KIND THING FIELD`): the engine-maintained structure over THING's
// FIELD column the runtime keeps current across committed versions. Several
// queries may declare the same requirement; the maintainer dedupes to one
// structure per distinct (kind, thing, field) — an index is a cache, a pure
// function of state (§08 §3).
Index_Req :: struct {
	kind:  Query_Index_Kind,
	thing: string, // the indexed thing's type name
	field: string, // the indexed blackboard field on that thing
}

// Query_Decl is one §08 §3 first-class query declaration: a read-only function
// pure over (version, params), carried with its declared index requirements and
// its body node forest so the runtime evaluates a query call from the artifact
// alone. The body is a Block by grammar (never a stub subtree), and the spec's
// within-tick memoization rides the tick state, not this descriptor.
Query_Decl :: struct {
	name:        string,
	params:      []Param_Decl,
	return_type: string,
	indexes:     []Index_Req, // declared §05 §3 requirements, authored order
	span_module: string, // §15 module name — diagnostic provenance only
	span_line:   int, // 1-based source line — diagnostic provenance only
	body:        []Node, // body_count top-level statement subtrees, source order
}

// Behavior_Decl is one transition keyed to its pipeline stage (§10). The stage
// slot CONFERS the contract (§06 §6). `on_thing` is the blackboard this behavior
// writes; params are step's reads, emits are step's writes (§06 §3).
Behavior_Decl :: struct {
	name:     string,
	on_thing: string, // the owning thing whose blackboard step writes
	stage:    string, // control/collision/scoring/render/startup
	contract: string, // Update/Render/Ui/Audio/Startup (engine-closed, §06 §6)
	gtags:    []string,
	params:   []Param_Decl, // step's parameters in order: self, resources, signals, views
	emits:    []string, // step's emissions: blackboard type, signal lists, command lists
	body:     []Node, // body_count step-body statement subtrees, source order
}

// --- Pipeline, routing, setup, bindings, entrypoint (§11–§15) ------------

// Pipeline_Step is one position in the one total order (§11). `ordinal` is the
// 0-based, contiguous, gap-free index a tick's fold visits this step at.
Pipeline_Step :: struct {
	ordinal:  int,
	stage:    string,
	behavior: string,
}

// Signal_Endpoint is a producer or consumer of a signal, by flattened-order
// ordinal so forward flow is verifiable without re-deriving it (§12).
Signal_Endpoint :: struct {
	ordinal:  int,
	behavior: string,
}

Signal_Route :: struct {
	signal:    string,
	producers: []Signal_Endpoint,
	consumers: []Signal_Endpoint,
}

// Spawn_Field is one supplied field of a setup Spawn, decoded to its concrete
// value: a Fixed through the kernel (bit-exact), an Int, an enum variant name,
// a Vec2, OR a composite §6 token (a `Body(…)` record / a `[Layer::…]` list, the
// engine-record forms yard's setup first reaches). The setup program carries NO
// expressions (§13) — every field is a primitive-encoded value already, so no
// initializer is interpreted here. A composite Record/List keeps its raw §6
// `encoded` token because its nested field types resolve against the (not-yet-fully-
// built) Program; spawn_field_to_value decodes it lazily through the SAME
// decode_default_value machinery the §6 field-default path uses, once the Program
// is available.
Spawn_Value_Kind :: enum {
	Int,
	Fixed,
	Variant, // a name-field enum variant like `Side::Left`
	Vec2, // a nested `vec2 x_bits y_bits` record
	Record, // a composite §6 record token like `Body(kind=…,…)` — decoded lazily
	List, // a §6 list token like `[Layer::Wall,Layer::Crate]` — decoded lazily
}

Spawn_Field :: struct {
	name:    string,
	kind:    Spawn_Value_Kind,
	int_val: i64, // Int
	fixed:   Fixed, // Fixed (decoded through the kernel — never float)
	variant: string, // Variant raw token (e.g. "Side::Left")
	vec2_x:  Fixed, // Vec2 x component
	vec2_y:  Fixed, // Vec2 y component
	encoded: string, // Record/List raw §6 token, decoded lazily by field type
}

// Spawn_Command is one entry of the §13 [Spawn] batch: a thing type plus its
// supplied fields. A field omitted in source (a default) is NOT carried — the
// runtime applies the thing's Field_Decl default when setup spawns it.
Spawn_Command :: struct {
	thing:  string,
	fields: []Spawn_Field,
}

// Binding is one resolved §23 axis/button source map entry (§14). The device
// source is kept as the builder-call token it was produced by — the only
// device-aware data in the artifact.
Binding :: struct {
	kind:   string, // "axis" or "button"
	player: string, // PlayerId P1..P4
	action: string, // the enum variant the binding targets, e.g. "Steer::Move"
	source: string, // the device builder call, e.g. "keys_axis(Key::W,Key::S)"
}

// Entrypoint is the §15 runtime wiring: pipeline ↔ tick ↔ logical ↔ bindings.
// tick_hz is the single fixed tick rate (60 for pong); there are no multi-rate
// ticks. logical_w/logical_h are the fixed logical draw space (§20 §3) in
// integer world units — the extent the present pass scales and letterboxes to
// the window.
Entrypoint :: struct {
	name:      string,
	pipeline:  string,
	tick_hz:   int,
	logical_w: int,
	logical_h: int,
	bindings:  string, // the bindings function name
}

// Project_Meta is the §4 (project.fcfg) identity: name + version. No build clock,
// no platform — those are build-driver concerns, not artifact fields.
Project_Meta :: struct {
	name:    string,
	version: string,
}

// Program is the whole loaded artifact: every section's in-memory model, in the
// order a tick will consult them. It owns its allocations (the loader's
// allocator); the parsed node forests live for the program's lifetime.
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
	tilemaps:       []Tile_Layer, // the §18 §3 baked tile layers (v12 [tilemaps], tilemap.odin)
}

// program_query finds a §16 query declaration by name, or nil. The query call
// surface (interp_call.odin) and the index maintainer (index.odin) both resolve
// through this single bare-name lookup, mirroring program_function's contract.
program_query :: proc(program: ^Program, name: string) -> ^Query_Decl {
	for &query in program.queries {
		if query.name == name {
			return &query
		}
	}
	return nil
}

// --- The empty runtime substrate (§07 §4) --------------------------------

// Thing_Id is a stable per-thing-type row identity. The runtime keys thing
// tables by Id so iteration and Ref resolution are deterministic (the state
// layer iterates a View[T] in stable-Id order, §08). Ids are dense and
// monotonic within a table; this file creates the empty table — no row is
// populated until setup runs in the tick transaction.
Thing_Id :: distinct u32

// Thing_Table is the empty per-thing-type row store keyed by Id. It carries the
// type descriptor it was built from (its schema) and the next Id to mint. Rows
// are added when setup spawns them, so `next_id` starts at 0 and
// the table is empty here — this is the substrate, not a populated world.
Thing_Table :: struct {
	thing:     string, // the Thing_Decl.name this table holds rows of
	singleton: bool, // mirrors the descriptor — a singleton is row-count-1 once spawned
	next_id:   Thing_Id, // the next Id to mint when a row is spawned (0 in the empty world)
}

// World is the empty in-memory substrate: one Thing_Table per declared thing,
// in the program's thing-declaration order. A singleton is an ordinary thing
// table the spawn step will fill with exactly one row (pong models the score as
// a once-spawned ordinary thing, so the singleton path is generic but unexercised
// by pong). This file builds the empty tables; it runs neither
// setup nor any tick.
//
// `tilemaps` is the §18 §4 DYNAMIC tile-state seed: an ALIAS of the program's
// decoded [tilemaps] tables (a slice-header copy, no clone) that initial_version
// lifts onto version -1, so tile state rides the COW version chain from tick 0.
// The program's decoded tables stay pristine forever — a SetTile tick
// copy-on-writes the touched layer's cells at commit (fold_tile_layers), never
// mutates in place, which is what keeps every re-fold (replay, §28 refold,
// control-class branches) reading its own version's terrain.
World :: struct {
	tables:   []Thing_Table,
	tilemaps: []Tile_Layer,
}

// world_find_table returns the (mutable pointer to the) table holding rows of
// the named thing, or nil when no such thing was declared.
world_find_table :: proc(world: ^World, thing: string) -> ^Thing_Table {
	for &table in world.tables {
		if table.thing == thing {
			return &table
		}
	}
	return nil
}

// new_world builds the empty thing/singleton tables from a loaded program — one
// table per declared thing, keyed by Id, with no rows. This is the §07 §4
// substrate the setup batch and the per-tick fold will execute over; it is
// intentionally empty here.
new_world :: proc(program: Program, allocator := context.allocator) -> World {
	tables := make([]Thing_Table, len(program.things), allocator)
	for thing, i in program.things {
		tables[i] = Thing_Table {
			thing     = thing.name,
			singleton = thing.singleton,
			next_id   = Thing_Id(0),
		}
	}
	// The dynamic-tile seed ALIASES the program's decoded layers (COW: the
	// first SetTile commit replaces the slice, never the bake's bytes).
	return World{tables = tables, tilemaps = program.tilemaps}
}
