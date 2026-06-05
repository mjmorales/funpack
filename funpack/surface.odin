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
// render surface, the §04 core resources, and the list combinators.
// One responsibility per module — the owning module is the only
// exporter of each name (§26). Enums and resource types both occupy the
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
		// `Fixed` is the prelude's always-in-scope numeric type, but the
		// golden source imports it through engine.math alongside Vec2 — the
		// numerics module re-exports it so `engine.math.{Fixed, …}` resolves.
		// Same name, same Type_Name meaning, whichever module names it.
		path = "engine.math",
		decls = {
			{"Fixed", .Type_Name},
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
		// table; Spawn is a closed §04 command-type constructor.
		path = "engine.world",
		decls = {
			{"View", .Type_Name},
			{"Spawn", .Type_Name},
		},
	},
	{
		// §23: the input surface. Input is the read-only resource;
		// PlayerId/Key/Stick are enums; Bindings is the builder type;
		// keys_axis/stick_y are engine-provided source helpers.
		path = "engine.input",
		decls = {
			{"Input", .Type_Name},
			{"Key", .Type_Name},
			{"PlayerId", .Type_Name},
			{"Bindings", .Type_Name},
			{"Stick", .Type_Name},
			{"keys_axis", .Func},
			{"stick_y", .Func},
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
		path = "engine.list",
		decls = {
			{"fold", .Func},
			{"map", .Func},
			{"filter", .Func},
			{"find", .Func},
			{"first", .Func},
		},
	},
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
			decl, declared := surface_lookup(module, member)
			if !declared {
				return .Unknown_Member
			}
			bindings.names[member] = Binding{module = module.path, kind = decl.kind}
		}
		return .None
	}
	if module, found := surface_module(join_path(node.segments)); found {
		// A whole-module import binds the module's own name; members
		// are reached through it (spec §04: assets.coin_sfx).
		handle := node.segments[len(node.segments) - 1]
		bindings.names[handle] = Binding{module = module.path, kind = .Module}
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
	decl, declared := surface_lookup(module, member)
	if !declared {
		return .Unknown_Member
	}
	bindings.names[member] = Binding{module = module.path, kind = decl.kind}
	return .None
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
// bindings() chains .axis(…) onto. Distinct from surface_associated, which
// types a Type's associated constants and constructors; a static builder
// returns an engine value (the builder itself) rather than a ground value.
surface_static_method :: proc(type_name: string, member: string) -> (signature: Type, found: bool) {
	switch type_name {
	case "Bindings":
		switch member {
		case "empty":
			return func_of({}, engine_type_of(.Bindings)), true
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
// (spec §23): Input.value reads a player's bound axis as a fixed scalar;
// Bindings.axis registers one axis mapping and returns the builder for
// chaining. The axis-role parameter (Input.value's second arg, Bindings.axis's
// second arg) and the axis-source parameter (Bindings.axis's third arg) have
// no checker ground, so they type as the nil unknown that unifies with the
// user axis enum and the keys_axis/stick_y result.
surface_engine_method :: proc(receiver: ^Engine_Type, member: string) -> (signature: Type, found: bool) {
	#partial switch receiver.kind {
	case .Input:
		switch member {
		case "value":
			return func_of({engine_type_of(.PlayerId), nil}, Ground_Type.Fixed), true
		}
	case .Bindings:
		switch member {
		case "axis":
			return func_of({engine_type_of(.PlayerId), nil, nil}, engine_type_of(.Bindings)), true
		}
	}
	return nil, false
}

// surface_command types an engine command constructor applied as a call
// (spec §04): Spawn(thing) wraps a thing's blackboard into a spawn command.
// The single argument is any thing — a §06 thing/singleton record — so the
// param is the nil unknown the call site's record type unifies with.
surface_command :: proc(name: string) -> (signature: Type, found: bool) {
	switch name {
	case "Spawn":
		return func_of({nil}, engine_type_of(.Spawn)), true
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
