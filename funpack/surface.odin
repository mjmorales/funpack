// The stdlib interface surface and the import resolver over it. The
// surface is a closed declaration table (spec §26): one partition per
// module, each owning the names it exports — type constructors,
// free functions, and value constants. resolve_imports validates every
// parsed import form against the table and populates the Bindings
// carrier the name-resolution stage consumes; an unknown module or
// member is a compile error. The table and the import list are walked
// by index — no map is ever iterated (the determinism tripwire) — and
// the Bindings map is insert-and-lookup only.
package funpack

import "core:strings"

Decl_Kind :: enum {
	Module,    // a whole-module import handle (never a table entry)
	Type_Name, // a type constructor / type-position name (Vec2, Option)
	Func,      // an importable free function (sin, fold, to_fixed)
	Value,     // an importable value constant (pi, tau)
}

Surface_Decl :: struct {
	name: string,
	kind: Decl_Kind,
}

Module_Surface :: struct {
	path:  string, // the dotted module path as written in imports
	decls: []Surface_Decl,
}

// STDLIB_SURFACE partitions the importable stdlib names by owning
// module (spec §26): the prelude's always-in-scope core, the §10 math
// surface, the §08 world read surface, the §23 input surface, the §20
// render surface, the §04 core resources, the list combinators, the
// engine.rand threaded-RNG surface, and the engine.grid helper surface.
// One responsibility per module — the owning module is the only
// exporter of each name (§26), and a cross-partition duplicate is legal
// only as a declared STDLIB_REEXPORTS row. Enums and resource types both occupy the
// Type_Name slot (Decl_Kind has no separate enum kind): they are
// type-position names. Growing a partition is a deliberate edit to this
// closed table.
@(rodata)
STDLIB_SURFACE := []Module_Surface{
	{
		path = "engine.prelude",
		decls = {
			{"Bool", .Type_Name},
			{"Int", .Type_Name},
			{"Fixed", .Type_Name},
			{"Float", .Type_Name},
			{"String", .Type_Name},
			{"Option", .Type_Name},
			{"Result", .Type_Name},
			{"Ordering", .Type_Name},
				// to_fixed is the spec-03 prelude conversion (to_fixed(Int) -> Fixed):
				// 03-data-model.md lists it among the Prelude functions, and hud_demo.fun
				// imports it from engine.prelude (audio.md line 45). It is the OWNING
				// decl here; engine.math re-exports it (STDLIB_REEXPORTS) so the
				// numerics/snake `import engine.math.{... to_fixed}` route still resolves
				// to this owner. One name, one owner, two routes -- the Fixed precedent.
				{"to_fixed", .Func},
			// or_else is the §26 Option fallback combinator (`or_else(Option[T],
			// T) -> T`): the arena hunter's nearest_player folds players into an
			// Option[Vec2] and `or_else(best, from)` falls back to its own position
			// when there is none. Call-site-inferred (the fallback drives T), so it
			// is a combinator row — its typing rule is combinator inference's, not a
			// fixed signature (surface_signatures returns found = false for it).
			{"or_else", .Func},
			// compare is the spec-03 prelude total three-way comparison
			// (`compare(a: T, b: T) -> Ordering`, prelude.fun:50): it produces the
			// Ordering result a match destructures Less/Equal/Greater. T is the
			// spec's Ord bound; the kernel grounds Ord as the same ordered scalars the
			// `<`/`>` operators and `max` operate over (Fixed, Int), so its typing is a
			// closed overload set ({(Fixed,Fixed)->Ordering, (Int,Int)->Ordering}) in
			// surface_signatures, not a combinator. The owning prelude decl; matched
			// over via the Ordering enum variant surface and the CLOSED_VARIANT_SETS
			// exhaustiveness entry.
			{"compare", .Func},
		},
	},
	{
		// `Fixed` lives in STDLIB_REEXPORTS, not here: the golden sources
		// import it through engine.math alongside Vec2 (the documented §26 §3
		// exception), but the prelude owns it — a re-export is a declared
		// table row, never a second owning decl.
		path = "engine.math",
		decls = {
			{"Vec2", .Type_Name},
			{"Vec3", .Type_Name},
			{"Quat", .Type_Name},
			{"Mat4", .Type_Name},
			{"Aabb", .Type_Name},
			{"sin", .Func},
			{"cos", .Func},
			{"sqrt", .Func},
			{"abs", .Func},
			{"clamp", .Func},
			{"lerp", .Func},
			{"dot", .Func},
			{"cross", .Func},
			{"normalize", .Func},
			{"length", .Func},
			// to_fixed is OWNED by engine.prelude (spec-03 Prelude functions);
			// engine.math re-exports it via STDLIB_REEXPORTS, not as a second owning
			// decl, so numerics/snake's engine.math route binds to the prelude owner.
			{"trunc", .Func},
			{"floor", .Func},
			{"round", .Func},
			{"checked_div", .Func},
			{"max", .Func},
			{"pi", .Value},
			{"tau", .Value},
		},
	},
	{
		// §08: the read/reference surface. View[T] is the read-only table; Ref
		// is the typed reference the §17 level bake resolves names to (a
		// Door.gate, a generated seam's Ref[Player]); Spawn and Despawn are
		// closed §04 command-type constructors.
		path = "engine.world",
		decls = {
			{"View", .Type_Name},
			{"Ref", .Type_Name},
			{"Spawn", .Type_Name},
			{"Despawn", .Type_Name},
		},
	},
	{
		// §08 navigation surface: the read/query handle the chase AI imports
		// (`import engine.nav.{Nav, Path}`). Nav is the read/query handle
		// (Nav.path queries a route, Nav.of builds one); Path is the route value
		// a Hunter's `route: Path` field defaults to and Path.advance walks;
		// NavError is the query-failure variant Nav.path's Result wraps.
		path = "engine.nav",
		decls = {
			{"Nav", .Type_Name},
			{"Path", .Type_Name},
			{"NavError", .Type_Name},
		},
	},
	{
		// §23: the input surface. Input is the read-only resource;
		// PlayerId/Key/PadButton/MouseButton/Stick are the device enums (named
		// only inside bindings() — §23 §1 keeps them out of sim code); Bindings is
		// the builder type. The source helpers (§23 §3, ADR
		// 2026-06-15-engine-input-source-helpers-split): digital BUTTON sources are
		// the [Key::…] key-list literal (.button's 3rd arg, the canonical keyboard
		// form), pad(PadButton) for a gamepad button, and mouse(MouseButton) for a
		// mouse button; 1D AXIS sources are keys_axis(neg, pos)/stick_x/stick_y; 2D
		// AXIS sources are wasd()/arrows()/dpad() (keyboard + d-pad quads) and
		// stick(Stick). wasd covers the WASD quad, arrows the arrow-key quad (the
		// only arrow-key 2D path — keys_axis is 1D), dpad the gamepad d-pad as a
		// single 2D Vec2 (the only d-pad 2D path — a d-pad direction is otherwise
		// only bindable as a digital pad button). stick_x/stick_y are the
		// horizontal/vertical twins: a gamepad stick into a single-axis source
		// (krognid binds the left stick's x to Strafe and its y to Forward).
		// `key(Key)` was dropped as redundant with the single-element [Key::W] list.
		// dpad() lowers to the runtime Pad_Quad source (emit.odin); like mouse it
		// rides the v18 open window parsed-but-unemitted until a committed artifact
		// binds it (ADR 2026-06-15-engine-input-source-helpers-split).
		path = "engine.input",
		decls = {
			{"Input", .Type_Name},
			{"Key", .Type_Name},
			{"PadButton", .Type_Name},
			{"MouseButton", .Type_Name},
			{"PlayerId", .Type_Name},
			{"Bindings", .Type_Name},
			{"Stick", .Type_Name},
			{"keys_axis", .Func},
			{"stick_x", .Func},
			{"stick_y", .Func},
			{"wasd", .Func},
			{"arrows", .Func},
			{"dpad", .Func},
			{"stick", .Func},
			{"pad", .Func},
			{"mouse", .Func},
		},
	},
	{
		// §20: the 2D render surface. Draw is the closed §04 draw-command
		// type; Color is its palette enum; Flip is the §20 sprite-mirroring enum
		// (None | X | Y | XY) a Draw::Sprite's `flip` field names — one set of
		// atlas cells reused for both facings.
		path = "engine.render",
		decls = {
			{"Draw", .Type_Name},
			{"Color", .Type_Name},
			{"Flip", .Type_Name},
		},
	},
	{
		// §04: the engine resources read by Update behaviors.
		path = "engine.core",
		decls = {
			{"Time", .Type_Name},
		},
	},
	{
		// The list combinator surface. fold/map/filter/find/first/last plus the
		// snake/hunt combinators prepend/init/contains/concat/is_empty and the
		// yard length read len: every row's signature is call-site-inferred
		// (surface_signatures returns found = false for them), so admission here
		// is the Func table row — their typing rule is combinator inference's,
		// not a fixed signature.
		path = "engine.list",
		decls = {
			{"fold", .Func},
			{"map", .Func},
			{"filter", .Func},
			{"find", .Func},
			{"first", .Func},
			{"last", .Func},
			{"prepend", .Func},
			{"init", .Func},
			{"contains", .Func},
			{"concat", .Func},
			{"is_empty", .Func},
			{"len", .Func},
			{"get", .Func},
			// The §08 §3 spatial combinators ride this [T]-combinator surface
			// (§26's engine.list owns the `[T]` combinators; their typing rule
			// is spatial_combinator_check's call-site inference over the
			// enclosing query's @spatial declaration, not a fixed signature).
			{"within", .Func},
			{"nearest_first", .Func},
		},
	},
	{
		// engine.rand: the threaded-resource RNG surface. Rng is the §04-style
		// threaded handle (a behavior takes `rng: Rng` and returns it in its
		// tuple, so the stream advances deterministically); pick is the
		// call-site-inferred draw combinator (surface_signatures returns
		// found = false for it, like the list combinators).
		path = "engine.rand",
		decls = {
			{"Rng", .Type_Name},
			{"pick", .Func},
		},
	},
	{
		// engine.grid: the §26 integer-grid helper surface — the complete row
		// (`Cell`, grid_cells/neighbors/in_bounds). Cell is the stdlib's PLAIN
		// DATA record (stdlib/engine/grid.fun: `data Cell { x: Int, y: Int }`),
		// admitted as a STRUCTURAL record (surface_structural_record), never an
		// engine ground — an imported Cell types and evaluates exactly as the
		// same user-declared record would, so every call-site-inferred grid/
		// tilemap signature stays structural and a fixture-local
		// `data Cell` types the same way. grid_cells enumerates a grid's cells in two
		// arity-selected forms (§18 §4): the canonical grid_cells(size: Cell)
		// -> [Cell] over a cell-shaped record, and the non-idiomatic 3-arg
		// mapper taking the grid dims and a fn(x, y) -> Cell builder
		// (grid_cells_check selects the form). neighbors(cell) -> [Cell] and
		// in_bounds(cell, size) -> Bool are cell-shape-checked combinators
		// (neighbors_check / in_bounds_check) — structural over any {x: Int,
		// y: Int} record, the imported Cell or the user's own.
		path = "engine.grid",
		decls = {
			{"Cell", .Type_Name},
			{"grid_cells", .Func},
			{"neighbors", .Func},
			{"in_bounds", .Func},
		},
	},
	{
		// §11 physics surface: the Tier-2 dynamics names a behavior writes intent
		// against. Body is the §11 §2 record; BodyKind and Shape2 are its kind
		// and shape enums (Shape2 carries struct-payload Box/Circle variants);
		// Trigger is the §11 §4 zero-field signal the engine routes to a sensor
		// overlap. solve is the §11 §3 physics battery — the single member of the
		// engine-closed `physics:` stage, validated as a battery name (contracts),
		// never as a callable, so it occupies the Func slot like grid_cells.
		path = "engine.physics",
		decls = {
			{"Body", .Type_Name},
			{"BodyKind", .Type_Name},
			{"Shape2", .Type_Name},
			{"Trigger", .Type_Name},
			{"solve", .Func},
		},
	},
	{
		// §24 persistence surface: the command-out/Result-back save and settings
		// names (spec §24 §1/§2). Save/Restore/ApplySettings are the §04 command
		// constructors a behavior emits ({slot}/{settings} struct payloads);
		// Saved/Restored/SettingsApplied are the engine-routed outcome signals
		// each carrying a `result: Result[…]` matched Ok/Err. Settings is the §24
		// §2 per-machine preferences record (with the .defaults() builder and the
		// nested access sub-record).
		path = "engine.save",
		decls = {
			{"Save", .Type_Name},
			{"Restore", .Type_Name},
			{"ApplySettings", .Type_Name},
			{"Saved", .Type_Name},
			{"Restored", .Type_Name},
			{"SettingsApplied", .Type_Name},
			{"Settings", .Type_Name},
		},
	},
	{
		// §26 the shared asset sink the §19 bake's generated seam imports and the
		// §16 Modeling / §21 UI pipelines import too. The four typed handle types
		// (MeshHandle/TextureHandle/SoundHandle/AtlasHandle) are the §26 line-78
		// type-position names a `let NAME: KINDHandle = KINDHandle{name: "NAME"}`
		// seam constant binds, and the six string/cell constructors (mesh/texture/
		// sound/atlas/cell/frame) name an asset by string against the closed
		// registry. mesh/texture/sound/atlas carry a fixed (String) -> KINDHandle
		// signature (surface_signatures); cell/frame are self-first AtlasHandle
		// accessors (cell(self, col, row) / frame(self, clip, t) -> String) typed at
		// the call site as engine methods off the AtlasHandle receiver
		// (surface_engine_method), so admission here is the Func table row that lets
		// the bare import resolve, their typing rule the engine-method signature.
		// This is a TYPING partition riding the existing import grammar — a new
		// closed table + the handle record schemas (surface_engine_record), NOT new
		// grammar.
		path = "engine.assets",
		decls = {
			{"MeshHandle", .Type_Name},
			{"TextureHandle", .Type_Name},
			{"SoundHandle", .Type_Name},
			{"AtlasHandle", .Type_Name},
			{"mesh", .Func},
			{"texture", .Func},
			{"sound", .Func},
			{"atlas", .Func},
			{"cell", .Func},
			{"frame", .Func},
		},
	},
	{
		// §18 §2/§3/§4 / §26 the tilemap partition: TilesetHandle is the typed
		// constant a .tiles bake's generated seam binds (`let dungeon:
		// TilesetHandle = TilesetHandle{name: "dungeon"}`, the §19 manifest
		// path); TilemapHandle is the typed constant a level bake's seam binds
		// per §18 §3 tile layer (`let terrain: TilemapHandle =
		// TilemapHandle{name: "terrain"}`) — both admitted exactly as the
		// engine.assets handles are, a Type_Name row plus the
		// single-String-`name` record schema (surface_engine_record). The four
		// §18 §4 layer queries (tile_at/solid_at/cell_of/center_of) are
		// self-first TilemapHandle accessors typed at the call site as engine
		// methods off the handle receiver (surface_engine_method, the
		// AtlasHandle cell/frame mold), so admission here is the Func table
		// row that lets the dungeon's bare import resolve; the
		// TilemapHandle.of fixture types through surface_static_method.
		// SetTile is the §18 §4 destructible-terrain command record the
		// dungeon's dig imports and returns (`-> [SetTile]`): a Type_Name row
		// whose construction schema (map: TilemapHandle, cell: the user's
		// Cell record, tile: String) is surface_engine_record — the partition
		// is the complete §26 tilemap row. BuildLayer is SetTile's §18 §4
		// whole-layer twin: the same [Spawn]-class Type_Name row, a seeded
		// generation behavior folds an Rng into a whole layer and returns
		// `-> [BuildLayer]`; its construction schema (map: TilemapHandle, fill:
		// String, cells: [(Cell, String)]) is surface_engine_record too.
		path = "engine.tilemap",
		decls = {
			{"TilesetHandle", .Type_Name},
			{"TilemapHandle", .Type_Name},
			{"SetTile", .Type_Name},
			{"BuildLayer", .Type_Name},
			{"tile_at", .Func},
			{"solid_at", .Func},
			{"cell_of", .Func},
			{"center_of", .Func},
		},
	},
	{
		// §16 §7 the rig/animation surface the §16 generated rig seam and the §20
		// render3 pose generators import. The seven type names (Skeleton/PartSet/
		// Slot/Side/Pose/Bone/Transform) are §26 line-76's anim row; rot_x/up are
		// the free Transform builders a pose generator drives a bone with. Slot/
		// Side/Bone are enums (variants reached through surface_enum_variant); the
		// static builders (Skeleton.humanoid()/empty(), PartSet.empty(), Pose.empty()/
		// blend()/layer()) and the value methods (PartSet.bind/mirror, Pose.set/get)
		// type through surface_static_method / surface_engine_method, not the import
		// table. A TYPING partition riding the existing import grammar.
		path = "engine.anim",
		decls = {
			{"Skeleton", .Type_Name},
			{"PartSet", .Type_Name},
			{"Slot", .Type_Name},
			{"Side", .Type_Name},
			{"Pose", .Type_Name},
			{"Bone", .Type_Name},
			{"Transform", .Type_Name},
			{"rot_x", .Func},
			{"up", .Func},
		},
	},
	{
		// §20 §1 the 3D render surface. Draw3 is the closed §20 3D draw-command type
		// (Camera/Light/Plane/Rigged/Mesh struct-payload variants), a NEW engine type
		// distinct from the §20 2D Draw — render3 owns it, it never reuses Draw.
		// Material is the PBR surface a Draw3::Mesh names. Color is owned by
		// engine.render and re-exported here (STDLIB_REEXPORTS, §26 §3): one palette,
		// route-independent meaning, never a second owning row — so stroll.fun's
		// `import engine.render3.{Draw3, Color}` resolves Color to its owner.
		path = "engine.render3",
		decls = {
			{"Draw3", .Type_Name},
			{"Material", .Type_Name},
		},
	},
	{
		// §21 the UI surface (engine.ui): the retained-mode View[Msg] read tree, the
		// closed widget-builder set, and the UiAction/Theme handles. View is owned by
		// engine.world (§08) and RE-EXPORTED here (§26 §3 / §21: the §08 read table
		// doubles as the §21 view tree) — a declared STDLIB_REEXPORTS row, never a
		// second owning decl. The eleven builders (text/button/row/col/field/slider/
		// class/when/map plus the layout/content/input rest) are the closed §21 §1
		// widget set the hand-authored escape hatch uses; each is call-site-inferred
		// over the screen's Msg type (its signature depends on the View[Msg] receiver
		// /elements, so surface_signatures returns found = false and the typing rule is
		// the call site's — surface_engine_method for the value-receiver builders, the
		// View static/free arm for the constructors). map is the §21 §3 Elm Html.map
		// re-tag the router mounts screens through. A member outside this set is
		// Unknown_Member, the closed-table gate this partition rests on.
		path = "engine.ui",
		decls = {
			// View is owned by engine.world (§08) and re-exported here (the §08 read
			// table doubles as the §21 view tree) — a STDLIB_REEXPORTS row below, never
			// an owned decl, so the table-shape single-owner rule holds.
			{"UiAction", .Type_Name},
			{"Theme", .Type_Name},
			{"text", .Func},
			{"button", .Func},
			{"image", .Func},
			{"spacer", .Func},
			{"panel", .Func},
			{"row", .Func},
			{"col", .Func},
			{"grid", .Func},
			{"stack", .Func},
			{"scroll", .Func},
			{"icon", .Func},
			{"field", .Func},
			{"slider", .Func},
			{"toggle", .Func},
			{"select", .Func},
			{"class", .Func},
			{"when", .Func},
			// map is NOT owned here — it is the §08/§26 list combinator name, owned by
			// engine.list, re-exported by engine.ui below so `import engine.ui.{View,
			// map}` (the hud router's import) resolves. View.map vs list.map are
			// receiver-overloaded (§02 §4 UFCS): the bare-name binding records one
			// owner, and the actual method is selected at the call site by the receiver
			// type (value_method_check's View.map arm), so the table keeps one owning
			// row per name.
		},
	},
	{
		// §22 the audio surface (engine.audio), shared between the two regimes. Sound
		// is the §22 §1 one-shot command record (Sound.sfx/.sfx_at + .gain/.pitch/
		// .bus/.at adders); Audio the §22 §2 keyed sustained projection record
		// (Audio.track(key, clip) + the same adders); Bus the §22 §4 mixer-group enum
		// both regimes route to. The builders are associated constructors
		// (surface_static_method) and self-first chained adders (surface_engine_method)
		// per §26 §1.6 — they carry no free Func row, so this partition's importable
		// members are the three types alone; a member outside the set is Unknown_Member.
		path = "engine.audio",
		decls = {
			{"Sound", .Type_Name},
			{"Audio", .Type_Name},
			{"Bus", .Type_Name},
		},
	},
}

// Reexport declares one name a partition exposes on behalf of its owning
// module — the §26 §3 exception, a deliberate table row, never a second
// owning decl. The resolver binds a re-exported name to its OWNER, so one
// name has one meaning whichever import route named it; an undeclared
// duplicate across partitions is rejected by the table-shape test. Growing
// this table is a spec amendment to §26 §3 first.
Reexport :: struct {
	module: string, // the re-exporting partition, as written in imports
	name:   string,
	owner:  string, // the owning module the binding records
}

// STDLIB_REEXPORTS carries the §26 §3 exceptions: engine.math re-exports the
// prelude's Fixed so the golden numerics import line (`import engine.math.{Fixed,
// Vec2, …}`) resolves, and engine.render3 re-exports engine.render's Color so
// stroll.fun's `import engine.render3.{Draw3, Color}` resolves Color to its
// single owner. Color is one closed palette (§20 §1) shared across the 2D and 3D
// render surfaces — a re-export, never a second owning row.
@(rodata)
STDLIB_REEXPORTS := []Reexport{
	{"engine.math", "Fixed", "engine.prelude"},
	// engine.math re-exports the prelude's to_fixed (spec-03 lists it among the
	// Prelude functions): numerics/snake import it through engine.math alongside
	// Vec2, while hud_demo imports it from engine.prelude direct. One owner
	// (prelude), two import routes -- the Fixed precedent applied to a function.
	{"engine.math", "to_fixed", "engine.prelude"},
	{"engine.render3", "Color", "engine.render"},
	// §21/§26: engine.ui re-exports engine.world's View — the §08 read table IS the
	// §21 retained-mode view tree (one type, one meaning), so the hud seam's
	// `import engine.ui.View` resolves to the owning engine.world handle. A
	// declared re-export, not a second owning decl.
	{"engine.ui", "View", "engine.world"},
	// §21 §3/§02 §4: engine.ui re-exports the `map` name (owned by engine.list as
	// the [T] combinator) so the hud router's `import engine.ui.{View, map}`
	// resolves. View.map and list.map are receiver-overloaded methods (the Elm
	// Html.map re-tag vs the list map); the bare import binds the name to the
	// engine.list owner, and the value_method_check View.map arm selects the view
	// method at the call site by the View receiver — one owning table row, one
	// name, dispatched by `self`.
	{"engine.ui", "map", "engine.list"},
}

// Binding records the declaration an imported name resolved to.
Binding :: struct {
	module: string,
	kind:   Decl_Kind,
}

// Bindings maps in-scope names to their one declaration (spec §02:
// one name, one meaning). Insert and lookup only — never iterated.
Bindings :: struct {
	names: map[string]Binding,
}

surface_module :: proc(path: string) -> (module: Module_Surface, found: bool) {
	for candidate in STDLIB_SURFACE {
		if candidate.path == path {
			return candidate, true
		}
	}
	return Module_Surface{}, false
}

surface_lookup :: proc(module: Module_Surface, name: string) -> (decl: Surface_Decl, found: bool) {
	for candidate in module.decls {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Surface_Decl{}, false
}

// surface_resolve resolves one member against a partition: an owned decl
// binds to this module; a declared re-export (§26 §3) resolves through its
// owning module and binds to the OWNER, so the binding is identical
// whichever import route named it. A name that is neither owned nor a
// declared re-export is not a member.
surface_resolve :: proc(module: Module_Surface, member: string) -> (binding: Binding, found: bool) {
	if decl, declared := surface_lookup(module, member); declared {
		return Binding{module = module.path, kind = decl.kind}, true
	}
	owner_path, reexported := surface_reexport(module.path, member)
	if !reexported {
		return Binding{}, false
	}
	owner, has_owner := surface_module(owner_path)
	if !has_owner {
		return Binding{}, false
	}
	decl, declared := surface_lookup(owner, member)
	if !declared {
		return Binding{}, false
	}
	return Binding{module = owner_path, kind = decl.kind}, true
}

// surface_reexport finds the declared re-export row for (partition, name),
// if any. Walked by index like every table here — never a map.
surface_reexport :: proc(module_path: string, name: string) -> (owner: string, found: bool) {
	for row in STDLIB_REEXPORTS {
		if row.module == module_path && row.name == name {
			return row.owner, true
		}
	}
	return "", false
}

// bind_name inserts one resolved name, rejecting a name already bound to a
// DIFFERENT declaration — duplicate admission is deliberate, never
// last-write-wins (spec §02 one-name-one-meaning at the resolver layer).
// Re-binding the identical declaration is legal: the prelude pre-binds
// Fixed, and a golden `engine.math.{Fixed, …}` import re-binds the same
// owner-recorded meaning.
bind_name :: proc(bindings: ^Bindings, name: string, binding: Binding) -> Type_Error {
	if existing, bound := bindings.names[name]; bound && existing != binding {
		return .Name_Collision
	}
	bindings.names[name] = binding
	return .None
}

// resolve_imports validates ast.imports against the stdlib surface ALONE and
// binds every imported name. The prelude is pre-bound — its names are always
// in scope without an import (spec §26). This is the single-source entry: a
// user-module import (a sibling .fun module) has no surface to resolve against
// here, so it is .Unknown_Module. resolve_imports_indexed is the multi-module
// entry that also resolves against a project-wide Module_Index.
resolve_imports :: proc(ast: Ast) -> (bindings: Bindings, err: Type_Error) {
	return resolve_imports_indexed(ast, Module_Index{})
}

// stamp_import anchors the located span sink on the offending `import` node's
// keyword line/col (Import_Node carries both, parser.odin) — the fix-criteria
// anchor for the import-resolution arms (Unknown_Module / Unknown_Member /
// Package_Private / Package_Imports_Package), which fire BEFORE any body sweep
// and so own no expression span. It writes first-write-wins (the `set` guard),
// like every other sink stamp, so the FIRST faulting import in source order is
// the anchor. A nil sink (the bare resolve_imports path, every existing caller)
// is a no-op, so import resolution's behavior is unchanged off the located pass.
stamp_import :: proc(site: ^Type_Diag_Site, node: Import_Node) {
	if site == nil || site.set {
		return
	}
	site.line = node.line
	site.col = node.col
	site.set = true
}

// resolve_imports_indexed validates ast.imports against the stdlib surface AND a
// project-wide Module_Index of sibling user modules, binding every imported name.
// The prelude is pre-bound (spec §26); each import then resolves through the
// stdlib arm first and the user-module arm second, so a name that is both a
// stdlib partition and a user module resolves as stdlib (the closed surface
// wins — a user module cannot shadow engine.*, §15.7). An empty index reduces
// this to the single-source resolve_imports: every user-module import is
// .Unknown_Module. importer_root is the importing module's own §30 package
// root: "" (the default — every consumer-project module) resolves the index
// by raw module name, while a PACKAGE module (a non-empty root) resolves its
// user-module imports from its own vantage — package-internal names map onto
// the consumer index's prefixed entries, and any import reaching outside the
// package + engine is the §30 §2 star-graph refusal (resolve_package_entry).
//
// site is the optional located span sink: when non-nil, a faulting import stamps
// its `import`-keyword line/col into it before the error unwinds (stamp_import),
// so the import-resolution arms anchor on the offending import rather than render
// header-only at line 0. nil (the bare resolve_imports / stage_typecheck_indexed
// path) disables stamping — every existing caller is unchanged.
resolve_imports_indexed :: proc(ast: Ast, index: Module_Index, importer_root := "", site: ^Type_Diag_Site = nil) -> (bindings: Bindings, err: Type_Error) {
	bindings.names = make(map[string]Binding, context.temp_allocator)
	prelude, _ := surface_module("engine.prelude")
	for decl in prelude.decls {
		bindings.names[decl.name] = Binding{module = prelude.path, kind = decl.kind}
	}
	for node in ast.imports {
		// The offending import is the one in hand at the reject, so the loop
		// stamps node.line/.col on a fault (the resolve_import arms return the
		// coarse Type_Error without the node) — the import-resolution analogue of
		// check_bodies stamping the offending declaration's line.
		if import_err := resolve_import(&bindings, node, index, importer_root); import_err != .None {
			stamp_import(site, node)
			return bindings, import_err
		}
	}
	return bindings, .None
}

// resolve_import discriminates the three parsed forms — a member group
// (segments name the module), a whole-module import (all segments are the
// module path), and a dotted single member (the final segment is a member of
// the module the leading segments name) — and within each form tries the stdlib
// surface first and the project-wide user-module index second. A path that is
// neither a stdlib partition nor a user module in the index is .Unknown_Module.
// importer_root threads the importing module's §30 package root into every
// user-module lookup (resolve_package_entry), so a package module resolves its
// own siblings and is refused anything beyond engine + itself (§30 §2).
resolve_import :: proc(bindings: ^Bindings, node: Import_Node, index: Module_Index, importer_root := "") -> Type_Error {
	if node.members != nil {
		path := join_path(node.segments)
		if module, found := surface_module(path); found {
			for member in node.members {
				binding, declared := surface_resolve(module, member)
				if !declared {
					return .Unknown_Member
				}
				bind_name(bindings, member, binding) or_return
			}
			return .None
		}
		entry, found := resolve_package_entry(index, path, importer_root) or_return
		if found {
			return resolve_user_import(bindings, entry, node.members, importer_root)
		}
		return .Unknown_Module
	}
	whole_path := join_path(node.segments)
	if module, found := surface_module(whole_path); found {
		// A whole-module import binds the module's own name; members
		// are reached through it (spec §04: assets.coin_sfx).
		handle := node.segments[len(node.segments) - 1]
		bind_name(bindings, handle, Binding{module = module.path, kind = .Module}) or_return
		return .None
	}
	// A whole-module import of a SIBLING USER module (the §19 assets seam:
	// `import assets`, then `assets.coin_sfx` reaches its exported handle const).
	// The handle binds to the user module so a member access resolves the member
	// against the module's exports — the user-module analogue of the stdlib
	// whole-module arm above. Tried before the dotted single-member arm so a
	// bare `import assets` (one segment) is a whole-module handle, not a missing
	// dotted member.
	if entry, found := resolve_package_entry(index, whole_path, importer_root) or_return; found {
		handle := node.segments[len(node.segments) - 1]
		return bind_name(bindings, handle, Binding{module = entry.module, kind = .Module})
	}
	if len(node.segments) < 2 {
		return .Unknown_Module
	}
	prefix := node.segments[:len(node.segments) - 1]
	prefix_path := join_path(prefix)
	member := node.segments[len(node.segments) - 1]
	if module, found := surface_module(prefix_path); found {
		binding, declared := surface_resolve(module, member)
		if !declared {
			return .Unknown_Member
		}
		return bind_name(bindings, member, binding)
	}
	entry, found := resolve_package_entry(index, prefix_path, importer_root) or_return
	if found {
		return resolve_user_import(bindings, entry, {member}, importer_root)
	}
	return .Unknown_Module
}

// resolve_package_entry is the importer-vantage user-module lookup behind every
// user arm of resolve_import. From the CONSUMING project ("" — the default
// vantage), it is a plain index lookup: every consumer module and every §30 §7
// prefixed package entry is nameable, and the §30 §6 expose gate downstream
// decides importability. From INSIDE a package (a non-empty importer_root R),
// §15 §5 fixes the namespace: the package's own modules root UNPREFIXED at its
// source root, so an import path P names the consumer index's prefixed entry
// `R.P` — tried first, and resolving it stays within the package (no edge). A
// path that instead names some OTHER entry of the index — another package's
// prefixed namespace, or a module of the consuming game — is the §30 §2
// star-graph refusal, the NAMED .Package_Imports_Package verdict: a package
// depends only on engine; it may not depend on another package (and the hub's
// modules are not in its namespace either). A raw path landing back inside the
// importer's OWN prefixed namespace (`import R.x` from within R) names a module
// that does not exist from the inside vantage — §15 §5: the project name is not
// a namespace prefix within the project — so it stays .Unknown_Module, never a
// star verdict against itself.
resolve_package_entry :: proc(index: Module_Index, path: string, importer_root: string) -> (entry: Module_Entry, found: bool, err: Type_Error) {
	if importer_root == "" {
		entry, found = module_index_lookup(index, path)
		return entry, found, .None
	}
	prefixed := strings.concatenate({importer_root, ".", path}, context.temp_allocator)
	if own, has_own := module_index_lookup(index, prefixed); has_own {
		return own, true, .None
	}
	if outside, has_outside := module_index_lookup(index, path); has_outside {
		if outside.package_root == importer_root {
			return Module_Entry{}, false, .Unknown_Module
		}
		return Module_Entry{}, false, .Package_Imports_Package
	}
	return Module_Entry{}, false, .None
}

join_path :: proc(segments: []string) -> string {
	return strings.join(segments, ".", context.temp_allocator)
}

surface_value_type :: proc(name: string) -> (type: Type, found: bool) {
	switch name {
	case "pi", "tau":
		return Ground_Type.Fixed, true
	}
	return nil, false
}

// surface_associated types a Type-name receiver's associated members —
// constants (Fixed.MAX) yield their value type, constructors
// (Quat.axis_angle) yield a Func signature. This is the declaration
// table the checker's receiver resolution consults; receiver names
// never match against ad-hoc strings outside it.
surface_associated :: proc(type_name: string, member: string) -> (type: Type, found: bool) {
	switch type_name {
	case "Fixed":
		switch member {
		case "MAX", "MIN":
			return Ground_Type.Fixed, true
		}
	case "Quat":
		switch member {
		case "identity":
			return Ground_Type.Quat, true
		case "axis_angle":
			return func_of({Ground_Type.Vec3, Ground_Type.Fixed}, Ground_Type.Quat), true
		}
	}
	return nil, false
}

// surface_method types a value receiver's methods, keyed by the
// receiver's checked type; Quat owns the only method set.
surface_method :: proc(receiver: Type, member: string) -> (signature: Type, found: bool) {
	if is_ground(receiver, .Quat) {
		switch member {
		case "rotate":
			return func_of({Ground_Type.Vec3}, Ground_Type.Vec3), true
		case "mul":
			return func_of({Ground_Type.Quat}, Ground_Type.Quat), true
		case "slerp":
			return func_of({Ground_Type.Quat, Ground_Type.Fixed}, Ground_Type.Quat), true
		}
	}
	return nil, false
}

// surface_signatures types the importable free functions as overload
// sets: most names carry one signature; dot/length/normalize carry one
// per vector width. The generic list combinators (fold, map, filter,
// find, first) return found = false — their parameters depend on the call
// site, which is combinator inference's judgment, not a table's.
surface_signatures :: proc(name: string) -> (overloads: []Type, found: bool) {
	switch name {
	case "sin", "cos", "sqrt", "abs":
		return clone_types({func_of({Ground_Type.Fixed}, Ground_Type.Fixed)}), true
	case "clamp", "lerp":
		return clone_types({func_of({Ground_Type.Fixed, Ground_Type.Fixed, Ground_Type.Fixed}, Ground_Type.Fixed)}), true
	case "to_fixed":
		return clone_types({func_of({Ground_Type.Int}, Ground_Type.Fixed)}), true
	case "trunc", "floor", "round":
		return clone_types({func_of({Ground_Type.Fixed}, Ground_Type.Int)}), true
	case "checked_div":
		return clone_types({func_of({Ground_Type.Fixed, Ground_Type.Fixed}, option_of(Ground_Type.Fixed))}), true
	case "max":
		// §10/§26 the binary maximum. The stdlib declares it over Fixed (max(a,
		// b: Fixed) -> Fixed); the hud `max(self.clock - 1, 0)` clamps an Int
		// countdown, so both an Int and a Fixed overload are admitted — each
		// total, neither promoting across the kinds (spec §10: the two sides
		// already agree).
		return clone_types({
			func_of({Ground_Type.Fixed, Ground_Type.Fixed}, Ground_Type.Fixed),
			func_of({Ground_Type.Int, Ground_Type.Int}, Ground_Type.Int),
		}), true
	case "compare":
		// §26/spec-03 the prelude total three-way comparison: `compare(a: T, b: T)
		// -> Ordering`. T is the spec's Ord bound; the kernel grounds Ord as the
		// same ordered scalars `<`/`>` and `max` operate over (Fixed, Int via
		// eval_comparison/compare_ordered), so the generic is realized as a closed
		// overload set — one arm per ordered ground, each demanding the two sides
		// already agree (overloads_check matches a pair against ONE arm, so
		// compare(1, 2.0) matches neither and is Type_Mismatch — the `a, b: T`
		// same-type constraint, no Int→Fixed promotion). Both yield the Ordering
		// engine enum a match destructures Less/Equal/Greater.
		return clone_types({
			func_of({Ground_Type.Fixed, Ground_Type.Fixed}, engine_type_of(.Ordering)),
			func_of({Ground_Type.Int, Ground_Type.Int}, engine_type_of(.Ordering)),
		}), true
	case "cross":
		return clone_types({func_of({Ground_Type.Vec3, Ground_Type.Vec3}, Ground_Type.Vec3)}), true
	case "dot":
		return clone_types({
			func_of({Ground_Type.Vec2, Ground_Type.Vec2}, Ground_Type.Fixed),
			func_of({Ground_Type.Vec3, Ground_Type.Vec3}, Ground_Type.Fixed),
		}), true
	case "length":
		return clone_types({
			func_of({Ground_Type.Vec2}, Ground_Type.Fixed),
			func_of({Ground_Type.Vec3}, Ground_Type.Fixed),
		}), true
	case "normalize":
		return clone_types({
			func_of({Ground_Type.Vec2}, Ground_Type.Vec2),
			func_of({Ground_Type.Vec3}, Ground_Type.Vec3),
		}), true
	case "keys_axis":
		// §23 source helper: two keyboard keys into an axis source. The axis
		// source has no checker ground — it is only consumed by Bindings.axis,
		// whose source param is the same nil unknown — so the result is nil.
		return clone_types({func_of({engine_type_of(.Key), engine_type_of(.Key)}, nil)}), true
	case "stick_x":
		// §23 source helper: a gamepad stick into a horizontal axis source — the
		// twin of stick_y. krognid binds the left stick's x to its Strafe axis.
		// Like every axis-source helper, the result is the nil unknown Bindings.axis
		// consumes (its source param is the same nil unknown).
		return clone_types({func_of({engine_type_of(.Stick)}, nil)}), true
	case "stick_y":
		// §23 source helper: a gamepad stick into a vertical axis source.
		return clone_types({func_of({engine_type_of(.Stick)}, nil)}), true
	case "rot_x":
		// §16 §7 the per-bone rotation builder: a fixed-point angle (radians) into a
		// Transform a pose generator sets on a bone (pose_walk's leg/arm swing).
		return clone_types({func_of({Ground_Type.Fixed}, engine_type_of(.Transform))}), true
	case "up":
		// §16 §7 the per-bone vertical-offset builder: a fixed-point displacement
		// into a Transform (pose_idle's torso breathing bob).
		return clone_types({func_of({Ground_Type.Fixed}, engine_type_of(.Transform))}), true
	case "wasd":
		// §23 source helper: the 2D WASD keyboard axis source — no argument. Its
		// result is the same nil axis-source unknown keys_axis/stick_y yield,
		// consumed only by Bindings.axis (whose source param is the nil unknown).
		return clone_types({func_of({}, nil)}), true
	case "arrows":
		// §23 source helper: the 2D arrow-key keyboard axis source — no argument,
		// the wasd() twin over Up/Down/Left/Right. It is the ONLY arrow-key 2D path
		// (keys_axis is 1D), so dropping it would lose arrow-key 2D movement (ADR
		// 2026-06-15-engine-input-source-helpers-split clause 3). Same nil
		// axis-source result wasd() yields; lowers to the arrow keys_quad in emit.
		return clone_types({func_of({}, nil)}), true
	case "dpad":
		// §23 source helper: the 2D gamepad-d-pad axis source — no argument, the
		// wasd()/arrows() twin over the four d-pad directions. It is the ONLY d-pad
		// 2D path (a d-pad direction is otherwise only a digital pad button), so it
		// closes the d-pad 2D gap the keyboard quads cannot. Same nil axis-source
		// result wasd()/arrows() yield; lowers to the runtime pad_quad source in emit.
		return clone_types({func_of({}, nil)}), true
	case "stick":
		// §23 source helper: a gamepad stick into a 2D axis source.
		return clone_types({func_of({engine_type_of(.Stick)}, nil)}), true
	case "pad":
		// §23 source helper: a gamepad digital BUTTON source — pad(PadButton::A).
		// The canonical gamepad button source ([Key::…] is keyboard-only), it types
		// like the axis helpers: the result is the nil unknown Bindings.button's
		// source param (its 3rd arg) consumes, the same slot the [Key::…] key-list
		// and the device source helpers feed.
		return clone_types({func_of({engine_type_of(.PadButton)}, nil)}), true
	case "mouse":
		// §23 source helper: a mouse digital BUTTON source — mouse(MouseButton::Left).
		// The mouse twin of pad(); neither is expressible by the keyboard-only
		// [Key::…] list, so both close a real device-coverage gap (ADR
		// 2026-06-15-engine-input-source-helpers-split). Result is the same nil
		// unknown Bindings.button's source slot consumes.
		return clone_types({func_of({engine_type_of(.MouseButton)}, nil)}), true
	case "mesh":
		// §19/§26 the manifest-checked string constructor: a String asset name into
		// the typed handle. The closed-registry gate (asset_registry.odin) validates
		// the name AND that the constructor's kind matches the registered asset's at
		// build; the signature here types the call as (String) -> the handle the kind
		// names, so the typed constant (assets.NAME) and the string form (kind("NAME"))
		// type the same.
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.MeshHandle))}), true
	case "texture":
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.TextureHandle))}), true
	case "sound":
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.SoundHandle))}), true
	case "atlas":
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.AtlasHandle))}), true
	case "text", "icon":
		// §21 §1 content builders that take a String and yield a view. The view's
		// Msg element is call-site-inferred (the composing tree's), so the result is
		// a View whose elem is the nil unknown the parent container unifies.
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.View))}), true
	case "image":
		// §21 §1 an image from a TextureHandle (owned by engine.assets).
		return clone_types({func_of({engine_type_of(.TextureHandle)}, engine_type_of(.View))}), true
	case "spacer":
		// §21 §1 a flexible empty cell — no argument.
		return clone_types({func_of({}, engine_type_of(.View))}), true
	case "panel", "row", "col", "grid", "stack":
		// §21 §1 the layout containers: a list of child views into one view. The
		// child Msg and the result Msg are the nil unknown (call-site-inferred), so
		// the param is a list of the nil-elem View and the result a nil-elem View.
		return clone_types({func_of({list_of(engine_type_of(.View))}, engine_type_of(.View))}), true
	case "scroll":
		// §21 §1 a clipped viewport around ONE child view.
		return clone_types({func_of({engine_type_of(.View)}, engine_type_of(.View))}), true
	case "button":
		// §21 §1 a button emitting a message when clicked: a String label and the
		// Msg value emitted on click. The Msg is the nil unknown (the screen's
		// message type), so the on_click param types as nil.
		return clone_types({func_of({engine_type_of(.String), nil}, engine_type_of(.View))}), true
	case "field":
		// §21 §1 a text field: the current String value and on_input: fn(String) ->
		// Msg (the two-way-bind lowering). The Msg is nil, so on_input types as
		// fn(String) -> nil.
		return clone_types({func_of({engine_type_of(.String), func_of({engine_type_of(.String)}, nil)}, engine_type_of(.View))}), true
	case "slider":
		// §21 §1 an integer slider over [min, max]: the current Int value, the Int
		// bounds, and on_change: fn(Int) -> Msg. The Msg is nil.
		return clone_types({
			func_of(
				{Ground_Type.Int, Ground_Type.Int, Ground_Type.Int, func_of({Ground_Type.Int}, nil)},
				engine_type_of(.View),
			),
		}), true
	case "toggle":
		// §21 §1 a boolean toggle: the current Bool and on_change: fn(Bool) -> Msg.
		return clone_types({func_of({Ground_Type.Bool, func_of({Ground_Type.Bool}, nil)}, engine_type_of(.View))}), true
	}
	return nil, false
}

// surface_enum_variant types an engine-enum variant value (spec §20/§23):
// PlayerId::P1, Key::W, Stick::Left, Color::White. The member is the variant
// name; the result is the owning engine enum's nominal handle. An enum's
// full variant set is the closed surface — a variant outside it is not a
// value, mirroring how a user-enum variant must belong to its declared set.
surface_enum_variant :: proc(type_name: string, variant: string) -> (type: Type, found: bool) {
	switch type_name {
	case "PlayerId":
		switch variant {
		case "P1", "P2":
			return engine_type_of(.PlayerId), true
		}
	case "Key":
		switch variant {
		case "W", "S", "A", "D", "Up", "Down", "Left", "Right", "Space",
		     "F5", "F9", "M", "Enter":
			// yard's menu keybinds (quicksave/quickload/toggle-motion/apply) bind to
			// the function keys, M, and Enter; the runtime treats a key code as an
			// opaque interned string, so admitting the variant here is the whole gate.
			return engine_type_of(.Key), true
		}
	case "PadButton":
		// §23 the gamepad digital-button enum a pad(PadButton::X) source names. The
		// closed set is exactly the runtime's SDL→§23 pad map (device_live.odin
		// pad_code_from_button): the four face buttons, Start/Back, the two
		// shoulders, and the four d-pad directions (a d-pad direction binds as a
		// digital button here; a single d-pad 2D axis is the dpad() form, which
		// lowers these same four direction codes into a Pad_Quad source).
		switch variant {
		case "A", "B", "X", "Y", "Start", "Back",
		     "LeftShoulder", "RightShoulder",
		     "DpadUp", "DpadDown", "DpadLeft", "DpadRight":
			return engine_type_of(.PadButton), true
		}
	case "MouseButton":
		// §23 the mouse digital-button enum a mouse(MouseButton::Left) source names.
		// The closed set is the three standard buttons SDL reports
		// (BUTTON_LEFT/MIDDLE/RIGHT), matching the runtime's mouse_code_from_button
		// map (device_live.odin).
		switch variant {
		case "Left", "Middle", "Right":
			return engine_type_of(.MouseButton), true
		}
	case "Stick":
		switch variant {
		case "Left", "Right":
			return engine_type_of(.Stick), true
		}
	case "Ordering":
		// §26/spec-03 the prelude total-comparison result (prelude.fun:19,
		// `enum Ordering { Less, Equal, Greater }`): the value `compare` produces and
		// a match destructures three-way. The closed set is exactly the three
		// declared variants — an entry outside them is not a value, mirroring the
		// other engine enums. Its CLOSED_VARIANT_SETS twin (gates.odin) makes a
		// match over it exhaustiveness-checked (the spec doc "forces a match").
		switch variant {
		case "Less", "Equal", "Greater":
			return engine_type_of(.Ordering), true
		}
	case "Color":
		// §20 §1 the one closed palette shared across engine.render (2D) and
		// engine.render3 (3D, via re-export). The named palette is exactly
		// render.fun:12-15: White/Black/Red/Green/Blue/Yellow/Cyan/Magenta/Gray
		// (Gray is the ground-plane shade stroll.fun's Draw3::Plane uses; Rgb is the
		// struct-payload escape variant in surface_struct_variant). The
		// secondary/CMY trio (Yellow/Cyan/Magenta) completes the spec-declared set.
		switch variant {
		case "White", "Black", "Red", "Green", "Blue", "Yellow", "Cyan", "Magenta", "Gray":
			return engine_type_of(.Color), true
		}
	case "Flip":
		// §20 the sprite-mirroring enum a Draw::Sprite's `flip` field names: None
		// draws the cells as authored, X/Y/XY mirror horizontally/vertically/both —
		// reusing one set of atlas cells for both facings (pickups' Flip::None).
		switch variant {
		case "None", "X", "Y", "XY":
			return engine_type_of(.Flip), true
		}
	case "Slot":
		// §16 §7 the part-attach slots krognid.gen.fun binds meshes to. The
		// left-side slots plus their right-mirror twins — PartSet.mirror(L, R)
		// derives the R set, but a binding may target either side explicitly, so
		// the full closed set is admitted (matching the .fpm rig's slot space).
		switch variant {
		case "Torso", "Head",
		     "LUpperArm", "LLowerArm", "RUpperArm", "RLowerArm",
		     "LUpperLeg", "LLowerLeg", "RUpperLeg", "RLowerLeg":
			return engine_type_of(.Slot), true
		}
	case "Side":
		// §16 §7 the mirror sides PartSet.mirror(Side::L, Side::R) names.
		switch variant {
		case "L", "R":
			return engine_type_of(.Side), true
		}
	case "Bone":
		// §16 §7 the skeleton bones a pose generator drives (Pose.set(Bone::…, t)).
		// The humanoid bone set: torso/head plus the four-limb upper/lower bones,
		// both sides (a pose drives both legs and both arms in counter-swing).
		switch variant {
		case "Torso", "Head",
		     "LUpperArm", "LLowerArm", "RUpperArm", "RLowerArm",
		     "LUpperLeg", "LLowerLeg", "RUpperLeg", "RLowerLeg":
			return engine_type_of(.Bone), true
		}
	case "Bus":
		// §22 §4 the audio bus groups (Master/Music/Sfx/Ui/Voice) BOTH regimes
		// route to. Shared with the §22 §1 one-shot Sound regime (sibling 5.2):
		// Audio.bus(Bus::Sfx) here, Sound.bus(Bus::Ui) there.
		switch variant {
		case "Master", "Music", "Sfx", "Ui", "Voice":
			return engine_type_of(.Bus), true
		}
	case "BodyKind":
		// §11 §2: the body kind enum. Static never moves, Dynamic is fully
		// solved, Kinematic is moved by user code. A bare-variant value
		// (BodyKind::Dynamic) selecting a Body's `kind` field.
		switch variant {
		case "Static", "Dynamic", "Kinematic":
			return engine_type_of(.BodyKind), true
		}
	case "NavError":
		// §12 the nav query-failure variants (`enum NavError { Unreachable, OffNav }`):
		// the value a failed path() wraps as Result::Err, matched exhaustively by the
		// chase's `routed` (Result::Err(NavError::Unreachable)). Both are nullary, so
		// a NavError value is the bare engine variant the match destructures.
		switch variant {
		case "Unreachable", "OffNav":
			return engine_type_of(.NavError), true
		}
	}
	return nil, false
}

// surface_static_method types a Type-name static builder applied as a method
// (spec §23): Bindings.empty() is the empty input-binding builder the pong
// bindings() chains .axis(…)/.button(…) onto, Input.empty() the empty input
// snapshot the inline tests seed with .with_pressed(…), Time.at(dt) a fixed-dt
// Time resource, and View.of(list) a §08 read table built from a literal list
// (its element is call-site-inferred, so the View elem is the nil unknown).
// Distinct from surface_associated, which types a Type's associated constants
// and constructors; a static builder returns an engine value (the builder /
// resource itself) rather than a ground value.
surface_static_method :: proc(type_name: string, member: string) -> (signature: Type, found: bool) {
	switch type_name {
	case "Bindings":
		switch member {
		case "empty":
			return func_of({}, engine_type_of(.Bindings)), true
		}
	case "Input":
		switch member {
		case "empty":
			return func_of({}, engine_type_of(.Input)), true
		}
	case "Time":
		switch member {
		case "at":
			return func_of({Ground_Type.Fixed}, engine_type_of(.Time)), true
		}
	case "View":
		switch member {
		case "of":
			return func_of({nil}, engine_type_of(.View)), true
		}
	case "Settings":
		switch member {
		case "defaults":
			// §24 §2: the factory-default settings the Menu singleton seeds with
			// (yard `Settings.defaults()`). No argument; yields the Settings record.
			return func_of({}, engine_type_of(.Settings)), true
		}
	case "Nav":
		switch member {
		case "of":
			// §08: the test producer that builds a Nav query handle from a Path
			// route (the chase-AI fixture's `Nav.of(route)`), the nav twin of
			// View.of — yields the Nav handle Nav.path then queries.
			return func_of({engine_type_of(.Path)}, engine_type_of(.Nav)), true
		case "fail":
			// §12: the Err-arm fixture twin of Nav.of — builds a failed Nav from a
			// NavError so the failed-query branch is testable end-to-end.
			return func_of({engine_type_of(.NavError)}, engine_type_of(.Nav)), true
		}
	case "TilemapHandle":
		switch member {
		case "of":
			// §18 §4 TilemapHandle.of(cell_size, cells): the fixture tile layer
			// an inline test seeds where a baked layer would be — the
			// View.of/Nav.of mold for the tilemap handle. Takes the Int cell
			// size and the (cell, tile, solid) seed rows; the row's cell is a
			// structural Cell record with no checker ground (the grid_cells
			// discipline — the imported engine.grid Cell and a user-declared
			// one both type structurally), so its tuple position is the nil
			// unknown.
			return func_of(
				{Ground_Type.Int, list_of(tuple_of({nil, engine_type_of(.String), Ground_Type.Bool}))},
				engine_type_of(.TilemapHandle),
			), true
		}
	case "Skeleton":
		// §16 §7 the named-topology skeleton builders: Skeleton.humanoid() is the
		// standard humanoid the krognid rig seam returns; empty() seeds an inline
		// rig tree. Each yields the opaque Skeleton engine value (no argument).
		switch member {
		case "humanoid", "empty":
			return func_of({}, engine_type_of(.Skeleton)), true
		}
	case "PartSet":
		// §16 §7 PartSet.empty() seeds the part→slot bindings the rig seam chains
		// .bind(Slot, MeshHandle) / .mirror(Side, Side) onto. No argument; yields
		// the PartSet the value methods (surface_engine_method) thread forward.
		switch member {
		case "empty":
			return func_of({}, engine_type_of(.PartSet)), true
		}
	case "Pose":
		// §16 §7 the pose builders/combinators applied as Type-name statics:
		// empty() seeds a sparse pose a generator .set()s bones on; blend(a, b, w)
		// per-bone lerps two poses (the speed-weighted idle/walk blend); layer(base,
		// overlay) lets the overlay win per bone. set/get are VALUE methods (they
		// receive a Pose value), typed in surface_engine_method.
		switch member {
		case "empty":
			return func_of({}, engine_type_of(.Pose)), true
		case "blend":
			return func_of(
				{engine_type_of(.Pose), engine_type_of(.Pose), Ground_Type.Fixed},
				engine_type_of(.Pose),
			), true
		case "layer":
			return func_of(
				{engine_type_of(.Pose), engine_type_of(.Pose)},
				engine_type_of(.Pose),
			), true
		}
	case "Sound":
		// §22 §1 the one-shot constructors: Sound.sfx(clip) builds a non-positional
		// one-shot at unity gain/pitch on the Sfx bus; Sound.sfx_at(clip, pos) places
		// it in the world. Each takes the §26 SoundHandle (owned by engine.assets,
		// not re-admitted here) and yields a Sound the .gain/.pitch/.bus/.at adders
		// then chain.
		switch member {
		case "sfx":
			return func_of({engine_type_of(.SoundHandle)}, engine_type_of(.Sound)), true
		case "sfx_at":
			return func_of({engine_type_of(.SoundHandle), Ground_Type.Vec3}, engine_type_of(.Sound)), true
		}
	case "Audio":
		// §22 §2 the sustained-audio track builder: Audio.track(key, clip) seeds the
		// keyed scene value the .pitch/.gain/.bus builders (surface_engine_method)
		// chain onto. The key is the stable String diff-key, the clip a SoundHandle.
		switch member {
		case "track":
			return func_of(
				{engine_type_of(.String), engine_type_of(.SoundHandle)},
				engine_type_of(.Audio),
			), true
		}
	}
	return nil, false
}

// surface_engine_member types a member read off an engine-typed value
// (spec §04): the §04 Time resource exposes dt and t — `dt` is the per-tick
// frame delta in fixed seconds, `t` is the accumulated logical time since
// startup (engine.core.Time is `data Time { dt: Fixed, t: Fixed }`). Both are
// Fixed; the renderer reads `time.t` to drive an idle bob, a gait behavior reads
// `time.dt` to step the cycle. The receiver's engine kind selects the member
// set; a member outside it is not a field.
surface_engine_member :: proc(receiver: ^Engine_Type, member: string) -> (type: Type, found: bool) {
	#partial switch receiver.kind {
	case .Time:
		switch member {
		case "dt", "t":
			return Ground_Type.Fixed, true
		}
	}
	return nil, false
}

// surface_engine_method types a method call off an engine-typed value
// (spec §23): the five §23 §2 Input queries — pressed/released/held read a
// player's bound button action as the edge/level Bools, value/axis read a
// bound axis action as a fixed scalar / a Vec2 — plus with_pressed, the
// test-producer that returns an Input snapshot with a player's button held;
// and the two Bindings registrars — axis maps one axis action, button one
// button action — each returning the builder for chaining. The action-role
// parameter (each query's second arg, each registrar's second arg) and the
// source/key-list parameter (axis's third arg, button's third arg) have no
// checker ground, so they type as the nil unknown that unifies with the user
// Button/Axis enum and the keys_axis/stick_y/wasd/stick result.
surface_engine_method :: proc(receiver: ^Engine_Type, member: string) -> (signature: Type, found: bool) {
	#partial switch receiver.kind {
	case .Input:
		switch member {
		case "pressed", "released", "held":
			return func_of({engine_type_of(.PlayerId), nil}, Ground_Type.Bool), true
		case "value":
			return func_of({engine_type_of(.PlayerId), nil}, Ground_Type.Fixed), true
		case "axis":
			return func_of({engine_type_of(.PlayerId), nil}, Ground_Type.Vec2), true
		case "with_pressed":
			return func_of({engine_type_of(.PlayerId), nil}, engine_type_of(.Input)), true
		case "with_value":
			// §23 §5 the 1D analog producer: seeds a Fixed value on an axis action of
			// a test Input snapshot (Input.empty().with_value(P1, Drive::Strafe, 0.0)),
			// the scalar twin of with_axis. The action-role arg is the nil unknown (the
			// user Axis enum); the value is the Fixed sample.
			return func_of(
				{engine_type_of(.PlayerId), nil, Ground_Type.Fixed},
				engine_type_of(.Input),
			), true
		case "with_axis":
			// The test producer that seeds an axis action's Vec2 on an Input
			// snapshot (yard's drive test: with_axis(P1, Drive::Move, Vec2{1,0})),
			// the analog twin of with_pressed. The action-role arg is the nil
			// unknown (the user Axis enum); the value is the Vec2 sample.
			return func_of(
				{engine_type_of(.PlayerId), nil, Ground_Type.Vec2},
				engine_type_of(.Input),
			), true
		}
	case .Bindings:
		switch member {
		case "axis", "button":
			return func_of({engine_type_of(.PlayerId), nil, nil}, engine_type_of(.Bindings)), true
		}
	case .Body:
		// §11 §2: a behavior influences physics only by writing its OWN body —
		// apply_impulse(Vec2) returns a new Body with the impulse accumulated (no
		// call into the solver, no hidden accumulator). It chains (yard sums two
		// pushes: b.apply_impulse(j).apply_impulse(k)), so receiver and result are
		// both Body.
		if member == "apply_impulse" {
			return func_of({Ground_Type.Vec2}, engine_type_of(.Body)), true
		}
	case .View:
		// §08: the read table's iteration + reference surface (world.fun:24-33).
		// count() reports how many things the view matched (an Int); at(i) reads the
		// i-th matched thing in stable id order as the element T (world.fun:24/:27).
		// The reference surface: resolve(Ref[T]) yields Option[T] (None when the
		// referent despawned — the gate behavior reads `switches.resolve(self.gate)`);
		// ref(Int) mints a Ref[T] to the i-th row (the test producer
		// `switches.ref(0)`). count/at/ref/resolve all key off the receiver's element
		// T, so a View[Switch] counts switches, reads a Switch at i, and resolves a
		// Ref[Switch] to an Option[Switch].
		switch member {
		case "count":
			return func_of({}, Ground_Type.Int), true
		case "at":
			return func_of({Ground_Type.Int}, receiver.elem), true
		case "resolve":
			return func_of({engine_type_of(.Ref, receiver.elem)}, option_of(receiver.elem)), true
		case "ref":
			return func_of({Ground_Type.Int}, engine_type_of(.Ref, receiver.elem)), true
		// §21 §1 the view-decorating self-first adders: class(tokens) applies theme
		// style tokens, when(cond) gates visibility — both keep the receiver's Msg
		// element (View.map, which re-tags it, lives in value_method_check).
		case "class":
			return func_of({engine_type_of(.String)}, engine_type_of(.View, receiver.elem)), true
		case "when":
			return func_of({Ground_Type.Bool}, engine_type_of(.View, receiver.elem)), true
		}
	case .Nav:
		// §12: the chase AI queries the baked nav graph off the injected Nav
		// handle. path(from, to) returns a Result[Path] (the route, or a NavError
		// when no path exists); Result carries no payload ground on this surface,
		// so the result is the bare Result engine value matched Ok/Err downstream.
		// los/reachable are the cheap yes/no segment and reachability checks; both
		// take a (from, to) Vec2 pair and read Bool. nearest(point) snaps an
		// arbitrary point onto walkable space, returning Option[Vec2] (None when
		// the nav is empty). These four are the §12 query surface the warren chase
		// drives — admitting them flips the warren pin from Unsupported_Expr.
		switch member {
		case "path":
			return func_of({Ground_Type.Vec2, Ground_Type.Vec2}, engine_type_of(.Result)), true
		case "los", "reachable":
			return func_of({Ground_Type.Vec2, Ground_Type.Vec2}, Ground_Type.Bool), true
		case "nearest":
			return func_of({Ground_Type.Vec2}, option_of(Ground_Type.Vec2)), true
		}
	case .TilemapHandle:
		// §18 §4 the four layer queries off the handle receiver — the dungeon's
		// method-style spelling (map.tile_at(cell)). The cell parameter and the
		// cell_of result are a structural Cell record with no checker ground
		// (the grid_cells discipline — the imported engine.grid Cell and a
		// user-declared one both type structurally), so each types as the nil
		// unknown; every other position is exact. tile_at is total: an unseeded
		// or out-of-grid cell is Option::None, never a fault.
		switch member {
		case "tile_at":
			return func_of({nil}, option_of(engine_type_of(.String))), true
		case "solid_at":
			return func_of({nil}, Ground_Type.Bool), true
		case "cell_of":
			return func_of({Ground_Type.Vec2}, nil), true
		case "center_of":
			return func_of({nil}, Ground_Type.Vec2), true
		}
	case .Path:
		// §08: advance(from, arrive) walks the route one waypoint — `from` is the
		// current position (Vec2), `arrive` the arrival radius (Fixed). It returns
		// the pair (next waypoint as Option[Vec2], remaining Path), so a behavior
		// reads the next target and threads the shortened route forward.
		if member == "advance" {
			return func_of(
				{Ground_Type.Vec2, Ground_Type.Fixed},
				tuple_of({option_of(Ground_Type.Vec2), engine_type_of(.Path)}),
			), true
		}
	case .PartSet:
		// §16 §7 the part-binding chain the rig seam threads off PartSet.empty():
		// bind(Slot, MeshHandle) attaches a baked mesh to a slot, mirror(Side, Side)
		// derives one side's bindings from the other. Both return the PartSet, so the
		// chain composes (krognid_parts binds six slots then mirrors L→R).
		switch member {
		case "bind":
			return func_of(
				{engine_type_of(.Slot), engine_type_of(.MeshHandle)},
				engine_type_of(.PartSet),
			), true
		case "mirror":
			return func_of(
				{engine_type_of(.Side), engine_type_of(.Side)},
				engine_type_of(.PartSet),
			), true
		}
	case .Pose:
		// §16 §7 the pose value methods: set(Bone, Transform) drives one bone
		// (returning the Pose, so a generator chains .set across bones), get(Bone)
		// reads a bone's Transform (the pose_walk test asserts get(LUpperLeg)).
		switch member {
		case "set":
			return func_of(
				{engine_type_of(.Bone), engine_type_of(.Transform)},
				engine_type_of(.Pose),
			), true
		case "get":
			return func_of({engine_type_of(.Bone)}, engine_type_of(.Transform)), true
		}
	case .Sound:
		// §22 §1 the one-shot self-first adders, each returning a new Sound so they
		// chain (Sound.sfx(clip).bus(Bus::Ui).gain(g)): gain/pitch take a Fixed, bus
		// a Bus, at a world Vec3.
		switch member {
		case "gain", "pitch":
			return func_of({Ground_Type.Fixed}, engine_type_of(.Sound)), true
		case "bus":
			return func_of({engine_type_of(.Bus)}, engine_type_of(.Sound)), true
		case "at":
			return func_of({Ground_Type.Vec3}, engine_type_of(.Sound)), true
		}
	case .Audio:
		// §22 §2 the sustained self-first adders (same shape as Sound's), each
		// returning a new Audio so they chain (Audio.track(k, c).gain(g).bus(b)).
		// (Task 5.1 owns the sustained regime; shared for the music-bed test.)
		switch member {
		case "gain", "pitch":
			return func_of({Ground_Type.Fixed}, engine_type_of(.Audio)), true
		case "bus":
			return func_of({engine_type_of(.Bus)}, engine_type_of(.Audio)), true
		case "at":
			return func_of({Ground_Type.Vec3}, engine_type_of(.Audio)), true
		}
	case .AtlasHandle:
		// §26 the two §26 line-78 atlas accessors, self-first functions reached as
		// methods off an AtlasHandle (pickups' `assets.pickups.frame("spin",
		// self.spin_t)`). cell(col, row) names a grid cell by column/row; frame(clip,
		// t) names the cell of a named animation clip at clock t. The `self`
		// AtlasHandle is the receiver, so the tail params are typed here; each yields
		// the String cell name a Draw::Sprite's `cell` field carries. Admitted as
		// .Func import rows (surface.odin) so a bare import resolves; the call-site
		// typing rule is this fixed engine-method signature.
		switch member {
		case "cell":
			return func_of({Ground_Type.Int, Ground_Type.Int}, engine_type_of(.String)), true
		case "frame":
			return func_of({engine_type_of(.String), Ground_Type.Fixed}, engine_type_of(.String)), true
		}
	}
	return nil, false
}

// surface_command types an engine command constructor applied as a call
// (spec §04): Spawn(thing) wraps a thing's blackboard into a spawn command —
// its single argument is any thing (a §06 thing/singleton record), so the param
// is the nil unknown the call site's record type unifies with. Despawn() takes
// no argument: it despawns the behavior's own target thing (the §04 self-scoped
// despawn), so its param list is empty.
surface_command :: proc(name: string) -> (signature: Type, found: bool) {
	switch name {
	case "Spawn":
		return func_of({nil}, engine_type_of(.Spawn)), true
	case "Despawn":
		return func_of({}, engine_type_of(.Despawn)), true
	}
	return nil, false
}

// surface_struct_variant types a struct-payload engine-enum variant value
// (spec §20 Draw, §11 Shape2): Draw::Rect{at, size, color} / Draw::Text{at,
// text, color} are the §20 draw commands; Shape2::Box{size} / Shape2::Circle{
// radius} are the §11 §2 collision shapes. fields is the closed field set with
// each field's expected type; an unknown field or a mismatched value rejects.
// The result is the owning engine type (the Draw command, or the Shape2 value
// a Body's `shape` field holds).
surface_struct_variant :: proc(type_name: string, variant: string) -> (result: Type, fields: []Surface_Field, found: bool) {
	switch type_name {
	case "Draw":
		switch variant {
		case "Rect":
			return engine_type_of(.Draw), clone_fields({
					{name = "at", type = Ground_Type.Vec2},
					{name = "size", type = Ground_Type.Vec2},
					{name = "color", type = engine_type_of(.Color)},
				}), true
		case "Text":
			return engine_type_of(.Draw), clone_fields({
					{name = "at", type = Ground_Type.Vec2},
					{name = "text", type = engine_type_of(.String)},
					{name = "color", type = engine_type_of(.Color)},
				}), true
		case "Camera":
			// §20 §3: the 2D camera command — camera-as-data, the view a behavior
			// projects. `at` is the world point centered on, `zoom` scales the
			// world→pixel projection, `rotation` is carried for the command set
			// (yard's `view` behavior emits rotation: 0.0). The runtime present
			// pass reads these by name to build the world↔screen transform.
			return engine_type_of(.Draw), clone_fields({
					{name = "at", type = Ground_Type.Vec2},
					{name = "zoom", type = Ground_Type.Fixed},
					{name = "rotation", type = Ground_Type.Fixed},
				}), true
		case "Sprite":
			// §20 the textured-quad command: a named cell of an atlas, tinted,
			// flipped, and z-sorted by layer (pickups' draw_coin emits one). `atlas`
			// is the §26 AtlasHandle the cell lives in; `cell` the String cell name
			// (the cell/frame accessors yield it); `at`/`size` the top-left quad
			// placement; `tint` the palette multiply; `flip` the mirroring; `layer`
			// the Int z-sort key.
			return engine_type_of(.Draw), clone_fields({
					{name = "atlas", type = engine_type_of(.AtlasHandle)},
					{name = "cell", type = engine_type_of(.String)},
					{name = "at", type = Ground_Type.Vec2},
					{name = "size", type = Ground_Type.Vec2},
					{name = "tint", type = engine_type_of(.Color)},
					{name = "flip", type = engine_type_of(.Flip)},
					{name = "layer", type = Ground_Type.Int},
				}), true
		}
	case "Shape2":
		switch variant {
		case "Box":
			return engine_type_of(.Shape2), clone_fields({
					{name = "size", type = Ground_Type.Vec2},
				}), true
		case "Circle":
			return engine_type_of(.Shape2), clone_fields({
					{name = "radius", type = Ground_Type.Fixed},
				}), true
		}
	case "Color":
		// §20 §1 the palette enum's struct-payload escape variant (render.fun:14):
		// Color::Rgb{ r, g, b } is the exact-value form (0..1 Fixed channels) the
		// named palette entries cover the common cases of. It yields the same Color
		// engine type a named variant (surface_enum_variant's Color case) does, so a
		// `tint`/`color` field accepts either form. Three Fixed channels; an unknown
		// field or a mismatched value rejects (the Shape2::Box mold).
		switch variant {
		case "Rgb":
			return engine_type_of(.Color), clone_fields({
					{name = "r", type = Ground_Type.Fixed},
					{name = "g", type = Ground_Type.Fixed},
					{name = "b", type = Ground_Type.Fixed},
				}), true
		}
	case "Draw3":
		// §20 §1 the closed 3D draw-command enum (a NEW engine type, distinct from
		// the §20 2D Draw — render3 owns Draw3, never reuses .Draw). Every variant
		// yields the Draw3 command a render3 behavior emits in its [Draw3] list.
		switch variant {
		case "Camera":
			// the 3D camera: world eye point, look-at target, field of view (Fixed
			// degrees). The 3D twin of Draw::Camera; the listener defaults to it.
			return engine_type_of(.Draw3), clone_fields({
					{name = "eye", type = Ground_Type.Vec3},
					{name = "at", type = Ground_Type.Vec3},
					{name = "fov", type = Ground_Type.Fixed},
				}), true
		case "Light":
			// a directional light: world-space direction and palette color.
			return engine_type_of(.Draw3), clone_fields({
					{name = "dir", type = Ground_Type.Vec3},
					{name = "color", type = engine_type_of(.Color)},
				}), true
		case "Plane":
			// a flat ground plane: world center, XZ extent (Vec2), palette color.
			return engine_type_of(.Draw3), clone_fields({
					{name = "at", type = Ground_Type.Vec3},
					{name = "size", type = Ground_Type.Vec2},
					{name = "color", type = engine_type_of(.Color)},
				}), true
		case "Rigged":
			// a posed rigged mesh: the bone skeleton, the part→slot mesh bindings,
			// the composed pose, and the world position — the §16 §7 render seam
			// (krognid's draw_krognid emits Draw3::Rigged of the blended pose).
			return engine_type_of(.Draw3), clone_fields({
					{name = "skeleton", type = engine_type_of(.Skeleton)},
					{name = "parts", type = engine_type_of(.PartSet)},
					{name = "pose", type = engine_type_of(.Pose)},
					{name = "at", type = Ground_Type.Vec3},
				}), true
		case "Mesh":
			// a static mesh: the baked-mesh handle, world position, PBR material —
			// depth-tested against the active Draw3::Camera. Material gives the
			// admitted §20 §1 Material type its one consumer.
			return engine_type_of(.Draw3), clone_fields({
					{name = "handle", type = engine_type_of(.MeshHandle)},
					{name = "at", type = Ground_Type.Vec3},
					{name = "material", type = engine_type_of(.Material)},
				}), true
		}
	}
	return nil, nil, false
}

// surface_engine_record types a constructable engine record (spec §11 §2 Body,
// §24 §1/§2 Save/Restore/ApplySettings/Settings/AccessOpts): the closed field
// set with each field's expected value type. result is the engine type a
// literal of this record yields (a Body value, a Save command, etc.), so the
// one schema serves both literal construction (record_check), member reads
// (field_member), and record-update (with_check). A record name with no schema
// is not an engine record. The §11 §5 layer/mask fields type as the nil unknown
// (they name the user's project-declared CollisionLayer enum, unknown to the
// closed surface) — the layer-registry gate validates their values, not this
// schema. Save/Restore carry a dynamic String slot (spec §24 §1: a save slot is
// an honest runtime String, not a closed registry).
surface_engine_record :: proc(name: string) -> (result: Type, fields: []Surface_Field, found: bool) {
	switch name {
	case "Trigger":
		// §11 §4: the zero-field sensor-overlap signal. A behavior consumes it as
		// an inbound [Trigger] list; a test constructs the empty Trigger{} value.
		// No fields, so any named field rejects.
		return engine_type_of(.Trigger), clone_fields({}), true
	case "Path":
		// §08 nav route value: the ordered waypoint list and the route's total
		// cost. A Hunter's `path` field defaults to `Path{steps: [], cost: 0.0}`
		// and the chase-AI fixture constructs `Path{steps: [Vec2{…}], cost: 10.0}`,
		// so both fields are typed (steps a [Vec2] list, cost a Fixed scalar) — the
		// route the §17 nav query returns and a behavior threads forward.
		return engine_type_of(.Path), clone_fields({
				{name = "steps", type = list_of(Ground_Type.Vec2)},
				{name = "cost", type = Ground_Type.Fixed},
			}), true
	case "Body":
		// §11 §2: `data Body { kind, shape, mass: Fixed = 1.0, restitution: Fixed
		// = 0.0, friction: Fixed = 0.5, layer, mask, sensor: Bool = false, impulse:
		// Vec2 = zero }`. Each defaulted field carries the spec `data` default
		// VALUE here (the schema is the single source of truth for both the type
		// and the default); the required fields (kind/shape/layer/mask) carry no
		// default. friction's 0.5 is FIXED_ONE/2 (= 0.5 exact in fixed-point), the
		// impulse zero is the empty Vec2 the apply_impulse accumulation builds on.
		return engine_type_of(.Body), clone_fields({
				{name = "kind", type = engine_type_of(.BodyKind)},
				{name = "shape", type = engine_type_of(.Shape2)},
				{name = "mass", type = Ground_Type.Fixed, default = FIXED_ONE, has_default = true},
				{name = "restitution", type = Ground_Type.Fixed, default = Fixed(0), has_default = true},
				{name = "friction", type = Ground_Type.Fixed, default = FIXED_ONE / 2, has_default = true},
				// layer/mask name the user's CollisionLayer enum — the nil unknown
				// here, gated by the layer registry rather than the field schema.
				{name = "layer", type = nil},
				{name = "mask", type = nil},
				{name = "sensor", type = Ground_Type.Bool, default = false, has_default = true},
				{name = "impulse", type = Ground_Type.Vec2, default = Vec2_Value{}, has_default = true},
			}), true
	case "Settings":
		// §24 §2 Settings { volume, binds, graphics, access }. Only `access` is
		// reached by yard's typecheck (settings.access.reduce_motion); the rest are
		// present as fields with the nil unknown so a `settings with {…}` over them
		// would still resolve, but their full sub-record shapes are out of scope.
		return engine_type_of(.Settings), clone_fields({
				{name = "volume", type = nil},
				{name = "binds", type = engine_type_of(.Bindings)},
				{name = "graphics", type = nil},
				{name = "access", type = engine_type_of(.AccessOpts)},
			}), true
	case "AccessOpts":
		// §24 §2 accessibility sub-record (`reduce_motion: Bool = false`).
		// reduce_motion is the one field yard reads and toggles; admit just it (the
		// registry gate's "just enough"), carrying its spec `data` default false so
		// Settings.defaults() sources reduce_motion from this one schema row.
		return engine_type_of(.AccessOpts), clone_fields({
				{name = "reduce_motion", type = Ground_Type.Bool, default = false, has_default = true},
			}), true
	case "Save":
		return engine_type_of(.Save), clone_fields({
				{name = "slot", type = engine_type_of(.String)},
			}), true
	case "Restore":
		return engine_type_of(.Restore), clone_fields({
				{name = "slot", type = engine_type_of(.String)},
			}), true
	case "ApplySettings":
		return engine_type_of(.ApplySettings), clone_fields({
				{name = "settings", type = engine_type_of(.Settings)},
			}), true
	case "MeshHandle":
		// §19/§26 the typed asset handles. Each is a single-field record over a
		// String `name` — the registered asset name the seam constant keys on (`let
		// coin: MeshHandle = MeshHandle{name: "coin"}`) — so a handle literal
		// record-checks against this schema and the typed constant carries the same
		// `name` the string constructor (mesh/texture/sound/atlas) names. The result
		// is the handle's engine type, so the constant and the constructor compare
		// equal (the §19 golden's assets.coin_sfx == sound("coin_sfx")).
		return engine_type_of(.MeshHandle), clone_fields({
				{name = "name", type = engine_type_of(.String)},
			}), true
	case "TextureHandle":
		return engine_type_of(.TextureHandle), clone_fields({
				{name = "name", type = engine_type_of(.String)},
			}), true
	case "SoundHandle":
		return engine_type_of(.SoundHandle), clone_fields({
				{name = "name", type = engine_type_of(.String)},
			}), true
	case "AtlasHandle":
		return engine_type_of(.AtlasHandle), clone_fields({
				{name = "name", type = engine_type_of(.String)},
			}), true
	case "TilesetHandle":
		return engine_type_of(.TilesetHandle), clone_fields({
				{name = "name", type = engine_type_of(.String)},
			}), true
	case "TilemapHandle":
		return engine_type_of(.TilemapHandle), clone_fields({
				{name = "name", type = engine_type_of(.String)},
			}), true
	case "SetTile":
		// §18 §4 the destructible-terrain command (the dungeon's dig returns
		// `[SetTile{map: map, cell: target, tile: "floor"}]`): `map` is the
		// level seam's TilemapHandle naming the layer to rewrite; `cell` is a
		// structural Cell record (the grid_cells/cell_of discipline — no
		// checker ground, so the nil unknown, the Body layer/mask mold; the
		// imported engine.grid Cell and a user-declared one both flow in);
		// `tile` is the project-global tile name the layer's palette resolves
		// at tick end. The result is the command's engine type, so a
		// `-> [SetTile]` return unifies with the constructed list.
		return engine_type_of(.SetTile), clone_fields({
				{name = "map", type = engine_type_of(.TilemapHandle)},
				{name = "cell", type = nil},
				{name = "tile", type = engine_type_of(.String)},
			}), true
	case "BuildLayer":
		// §18 §4 the whole-layer twin of SetTile (a seeded generation behavior
		// returns `[BuildLayer{map: terrain, fill: "floor", cells: [...]}]`):
		// `map` is the level seam's TilemapHandle naming the layer to build;
		// `fill` is the project-global base tile every cell takes (a String, the
		// SetTile `tile` discipline — names, not indices); `cells` is the
		// explicit (cell, tile-name) overrides as a list of tuples. The cells
		// row mirrors TilemapHandle.of's `[(Cell, String, Bool)]` seed-row
		// encoding minus the solid flag (BuildLayer carries no collision — the
		// tile name resolves collision through the layer's palette, like
		// SetTile): list_of(tuple_of({nil, String})). The first tuple position
		// is the nil unknown — a structural Cell record with no checker ground
		// (the grid_cells discipline: the imported engine.grid Cell and a
		// user-declared one both flow in structurally), exactly as SetTile's
		// `cell` field and TilemapHandle.of's row cell are. The result is the
		// command's engine type, so a `-> [BuildLayer]` return unifies with the
		// constructed list.
		return engine_type_of(.BuildLayer), clone_fields({
				{name = "map", type = engine_type_of(.TilemapHandle)},
				{name = "fill", type = engine_type_of(.String)},
				{name = "cells", type = list_of(tuple_of({nil, engine_type_of(.String)}))},
			}), true
	}
	return nil, nil, false
}

// surface_structural_record types an imported stdlib record that is PLAIN DATA
// rather than an opaque engine value — the stdlib file declares it as ordinary
// `data` surface syntax, so importing it must behave exactly as if the user had
// written the same declaration locally. The schema is keyed on (name, owning
// partition) through the import bindings, so a USER declaration named Cell in a
// module that never imports engine.grid is untouched, and the §02
// one-name-one-meaning collision rule rejects declaring AND importing the
// name. The only entry is engine.grid's `Cell { x: Int, y: Int }`
// (stdlib/engine/grid.fun, §26): it types as User_Type("Cell", .Data) — NO
// Engine_Kind ground is minted, preserving the grid_cells discipline — so
// construction, projection, `with`, equality, is_cell_shaped, and the evaluator
// all treat it as the structural record it is. Consulted as a fallback by
// resolve_type_ref (annotation position), ctx_record_schema (expression
// position), and the evaluator's record-literal arm.
surface_structural_record :: proc(bindings: Bindings, name: string) -> (schema: Record_Schema, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Type_Name {
		return Record_Schema{}, false
	}
	if name == "Cell" && binding.module == "engine.grid" {
		fields := make([]Field_Schema, 2, context.temp_allocator)
		fields[0] = Field_Schema{name = "x", type = Ground_Type.Int}
		fields[1] = Field_Schema{name = "y", type = Ground_Type.Int}
		return Record_Schema{type_name = "Cell", kind = .Data, fields = fields}, true
	}
	return Record_Schema{}, false
}

// surface_engine_member_record reads a field off an engine record value (spec
// §11 §2 / §24 §2): a Body's fields (a behavior reads self.body.shape,
// self.body.impulse), Settings.access, AccessOpts.reduce_motion, and an outcome
// signal's `result` field (Saved/Restored/SettingsApplied carry a
// Result[…] the §24 forced match destructures). The Body/Settings/AccessOpts
// reads share the construction schema (surface_engine_record), so a field is
// readable iff it is constructable. The result-signal `result` field is the
// Result engine value, typed here so its match scrutinee is well-formed.
surface_engine_member_record :: proc(receiver: ^Engine_Type, member: string) -> (type: Type, found: bool) {
	#partial switch receiver.kind {
	// Path joins the readable engine records (the warren's `route.steps`
	// drifted-route probe): a field is readable iff it is constructable, and
	// Path{steps, cost} construction is already §08 surface — reading the
	// fields back is the same record schema, NOT a §12 graph query.
	case .Body, .Settings, .AccessOpts, .Path:
		_, fields, has_schema := surface_engine_record(engine_kind_name(receiver.kind))
		if !has_schema {
			return nil, false
		}
		return surface_field_type(fields, member)
	case .Saved, .Restored, .SettingsApplied:
		if member == "result" {
			return engine_type_of(.Result), true
		}
	}
	return nil, false
}

// engine_kind_name maps the engine-record kinds back to their surface name, so
// a member read can look the construction schema up by name (the one schema
// table). Only the record kinds need a name; a non-record kind returns "".
engine_kind_name :: proc(kind: Engine_Kind) -> string {
	#partial switch kind {
	case .Path:
		return "Path"
	case .Body:
		return "Body"
	case .Settings:
		return "Settings"
	case .AccessOpts:
		return "AccessOpts"
	case .MeshHandle:
		return "MeshHandle"
	case .TextureHandle:
		return "TextureHandle"
	case .SoundHandle:
		return "SoundHandle"
	case .AtlasHandle:
		return "AtlasHandle"
	case .TilesetHandle:
		return "TilesetHandle"
	case .TilemapHandle:
		return "TilemapHandle"
	}
	return ""
}

// Surface_Field is one named field of an engine struct-payload variant or
// engine record — the field name, its expected value type the typing pass
// checks against, and (for a §11 §2 / §24 §2 record field with a spec `data`
// default) the value an omitted field takes. The schema is the SINGLE SOURCE OF
// TRUTH for both the field's type AND its default, faithfully mirroring the spec
// `data` declaration: the typechecker reads only `type` (it ignores the
// default), and the evaluator reads `default` when `has_default` (eval_engine_record).
// A field with no spec default (a required field, never omitted in a checked
// literal) carries has_default = false.
Surface_Field :: struct {
	name:        string,
	type:        Type,
	default:     Value,
	has_default: bool,
}

// clone_fields copies a compound-literal field set into the temp allocator so
// the call-site literal never escapes its stack frame, mirroring func_of's
// param clone.
clone_fields :: proc(set: []Surface_Field) -> []Surface_Field {
	cloned := make([]Surface_Field, len(set), context.temp_allocator)
	copy(cloned, set)
	return cloned
}
