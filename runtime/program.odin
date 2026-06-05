// The in-memory game model the runtime executes over (docs/artifact-format.md
// §16 step 4). `Program` is the loaded artifact: the enum/data/signal/thing
// type descriptors, the function and behavior bodies (serialized checked-AST
// node forests, §2.7), the one flattened pipeline total order (§11), the signal
// routing map (§12), the fully-evaluated setup Spawn batch (§13, fixed literals
// decoded bit-exact through the kernel), the binding table (§14), and the
// entrypoint wiring (§15).
//
// `World` is the empty runtime substrate the downstream stories execute over:
// thing tables keyed by stable Id and the singleton row slots. This story
// BUILDS the empty tables; it does NOT run setup or any tick — the spawn batch
// is loaded into `Program.setup`, but applying it (and folding the pipeline)
// belongs to the tick-transaction story (team Lore seam order).
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
Field_Decl :: struct {
	name:            string,
	type:            string,
	has_default:     bool,
	default_encoded: string, // the raw `ENCODED` token after `=`, decoded by position
}

Data_Decl :: struct {
	name:      string,
	mutable:   bool, // true for `mut data` (§03 §7)
	fields:    []Field_Decl,
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
// or a Vec2. The setup program carries NO expressions (§13) — every field is a
// primitive-encoded value already, so no initializer is interpreted here.
Spawn_Value_Kind :: enum {
	Int,
	Fixed,
	Variant, // a name-field enum variant like `Side::Left`
	Vec2, // a nested `vec2 x_bits y_bits` record
}

Spawn_Field :: struct {
	name:    string,
	kind:    Spawn_Value_Kind,
	int_val: i64, // Int
	fixed:   Fixed, // Fixed (decoded through the kernel — never float)
	variant: string, // Variant raw token (e.g. "Side::Left")
	vec2_x:  Fixed, // Vec2 x component
	vec2_y:  Fixed, // Vec2 y component
}

// Spawn_Command is one entry of the §13 [Spawn] batch: a thing type plus its
// supplied fields. A field omitted in source (a default) is NOT carried — the
// runtime applies the thing's Field_Decl default when it spawns (next story).
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

// Entrypoint is the §15 runtime wiring: pipeline ↔ tick ↔ bindings. tick_hz is
// the single fixed tick rate (60 for pong); there are no multi-rate ticks.
Entrypoint :: struct {
	name:     string,
	pipeline: string,
	tick_hz:  int,
	bindings: string, // the bindings function name
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
}

// --- The empty runtime substrate (§07 §4) --------------------------------

// Thing_Id is a stable per-thing-type row identity. The runtime keys thing
// tables by Id so iteration and Ref resolution are deterministic (team Lore: the
// state layer iterates a View[T] in stable-Id order). Ids are dense and
// monotonic within a table; this story creates the empty table — no row is
// populated until setup runs (the tick-transaction story).
Thing_Id :: distinct u32

// Thing_Table is the empty per-thing-type row store keyed by Id. It carries the
// type descriptor it was built from (its schema) and the next Id to mint. Rows
// are added when setup spawns them (next story), so `next_id` starts at 0 and
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
// by pong — team Lore). This story builds the empty tables; it runs neither
// setup nor any tick.
World :: struct {
	tables: []Thing_Table,
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
// substrate the setup batch and the per-tick fold will execute over in the next
// story; it is intentionally empty here.
new_world :: proc(program: Program, allocator := context.allocator) -> World {
	tables := make([]Thing_Table, len(program.things), allocator)
	for thing, i in program.things {
		tables[i] = Thing_Table {
			thing     = thing.name,
			singleton = thing.singleton,
			next_id   = Thing_Id(0),
		}
	}
	return World{tables = tables}
}
