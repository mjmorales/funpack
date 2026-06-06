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
			{"to_fixed", .Func},
			{"trunc", .Func},
			{"floor", .Func},
			{"round", .Func},
			{"checked_div", .Func},
			{"pi", .Value},
			{"tau", .Value},
		},
	},
	{
		// §08: the read/reference surface. View[T] is the read-only
		// table; Spawn and Despawn are closed §04 command-type constructors.
		path = "engine.world",
		decls = {
			{"View", .Type_Name},
			{"Spawn", .Type_Name},
			{"Despawn", .Type_Name},
		},
	},
	{
		// §23: the input surface. Input is the read-only resource;
		// PlayerId/Key/Stick are enums; Bindings is the builder type;
		// keys_axis/stick_y/wasd/stick are engine-provided axis-source helpers
		// (wasd is the 2D WASD axis source, stick a gamepad-stick axis source).
		path = "engine.input",
		decls = {
			{"Input", .Type_Name},
			{"Key", .Type_Name},
			{"PlayerId", .Type_Name},
			{"Bindings", .Type_Name},
			{"Stick", .Type_Name},
			{"keys_axis", .Func},
			{"stick_y", .Func},
			{"wasd", .Func},
			{"stick", .Func},
		},
	},
	{
		// §20: the 2D render surface. Draw is the closed §04 draw-command
		// type; Color is its palette enum.
		path = "engine.render",
		decls = {
			{"Draw", .Type_Name},
			{"Color", .Type_Name},
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
		// The list combinator surface. fold/map/filter/find/first plus the
		// snake/hunt combinators prepend/init/contains/concat/is_empty: every
		// row's signature is call-site-inferred (surface_signatures returns
		// found = false for them), so admission here is the Func table row —
		// their typing rule is combinator inference's, not a fixed signature.
		path = "engine.list",
		decls = {
			{"fold", .Func},
			{"map", .Func},
			{"filter", .Func},
			{"find", .Func},
			{"first", .Func},
			{"prepend", .Func},
			{"init", .Func},
			{"contains", .Func},
			{"concat", .Func},
			{"is_empty", .Func},
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
		// engine.grid: the grid helper surface. grid_cells enumerates a grid's
		// cells, taking the grid dims and a fn(x, y) -> Cell builder; its
		// signature is call-site-inferred (the Cell element is the user's, not
		// the engine's), so admission here is the Func table row.
		path = "engine.grid",
		decls = {
			{"grid_cells", .Func},
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

// STDLIB_REEXPORTS carries the one documented §26 §3 exception: engine.math
// re-exports the prelude's Fixed so the golden numerics import line
// (`import engine.math.{Fixed, Vec2, …}`) resolves.
@(rodata)
STDLIB_REEXPORTS := []Reexport{
	{"engine.math", "Fixed", "engine.prelude"},
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

// resolve_imports validates ast.imports against the surface and binds
// every imported name. The prelude is pre-bound — its names are always
// in scope without an import (spec §26).
resolve_imports :: proc(ast: Ast) -> (bindings: Bindings, err: Type_Error) {
	bindings.names = make(map[string]Binding, context.temp_allocator)
	prelude, _ := surface_module("engine.prelude")
	for decl in prelude.decls {
		bindings.names[decl.name] = Binding{module = prelude.path, kind = decl.kind}
	}
	for node in ast.imports {
		resolve_import(&bindings, node) or_return
	}
	return bindings, .None
}

// resolve_import discriminates the three parsed forms: a member group
// (segments name the module), a whole-module import (all segments are
// the module path), and a dotted single member (the final segment is a
// member of the module the leading segments name).
resolve_import :: proc(bindings: ^Bindings, node: Import_Node) -> Type_Error {
	if node.members != nil {
		module, found := surface_module(join_path(node.segments))
		if !found {
			return .Unknown_Module
		}
		for member in node.members {
			binding, declared := surface_resolve(module, member)
			if !declared {
				return .Unknown_Member
			}
			bind_name(bindings, member, binding) or_return
		}
		return .None
	}
	if module, found := surface_module(join_path(node.segments)); found {
		// A whole-module import binds the module's own name; members
		// are reached through it (spec §04: assets.coin_sfx).
		handle := node.segments[len(node.segments) - 1]
		bind_name(bindings, handle, Binding{module = module.path, kind = .Module}) or_return
		return .None
	}
	if len(node.segments) < 2 {
		return .Unknown_Module
	}
	prefix := node.segments[:len(node.segments) - 1]
	module, found := surface_module(join_path(prefix))
	if !found {
		return .Unknown_Module
	}
	member := node.segments[len(node.segments) - 1]
	binding, declared := surface_resolve(module, member)
	if !declared {
		return .Unknown_Member
	}
	return bind_name(bindings, member, binding)
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
	case "stick_y":
		// §23 source helper: a gamepad stick into a vertical axis source.
		return clone_types({func_of({engine_type_of(.Stick)}, nil)}), true
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
		case "W", "S", "A", "D", "Up", "Down", "Left", "Right", "Space":
			return engine_type_of(.Key), true
		}
	case "Stick":
		switch variant {
		case "Left", "Right":
			return engine_type_of(.Stick), true
		}
	case "Color":
		switch variant {
		case "White", "Black", "Red", "Green", "Blue":
			return engine_type_of(.Color), true
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
	}
	return nil, false
}

// surface_engine_member types a member read off an engine-typed value
// (spec §04): the §04 Time resource exposes dt, the frame delta in fixed
// seconds. The receiver's engine kind selects the member set; a member
// outside it is not a field.
surface_engine_member :: proc(receiver: ^Engine_Type, member: string) -> (type: Type, found: bool) {
	#partial switch receiver.kind {
	case .Time:
		switch member {
		case "dt":
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
		}
	case .Bindings:
		switch member {
		case "axis", "button":
			return func_of({engine_type_of(.PlayerId), nil, nil}, engine_type_of(.Bindings)), true
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
// (spec §20): Draw::Rect{at, size, color} and Draw::Text{at, text, color}
// are the §20 draw commands. fields is the closed field set with each
// field's expected type; an unknown field or a mismatched value rejects.
// The result is the engine Draw command type.
surface_struct_variant :: proc(type_name: string, variant: string) -> (result: Type, fields: []Surface_Field, found: bool) {
	if type_name != "Draw" {
		return nil, nil, false
	}
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
	}
	return nil, nil, false
}

// Surface_Field is one named field of an engine struct-payload variant — the
// field name and its expected value type the typing pass checks against.
Surface_Field :: struct {
	name: string,
	type: Type,
}

// clone_fields copies a compound-literal field set into the temp allocator so
// the call-site literal never escapes its stack frame, mirroring func_of's
// param clone.
clone_fields :: proc(set: []Surface_Field) -> []Surface_Field {
	cloned := make([]Surface_Field, len(set), context.temp_allocator)
	copy(cloned, set)
	return cloned
}
