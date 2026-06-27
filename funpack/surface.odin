package funpack

import "core:fmt"
import "core:slice"
import "core:strings"

Decl_Kind :: enum {
	Module,
	Type_Name,
	Func,
	Value,
}

Surface_Decl :: struct {
	name: string,
	kind: Decl_Kind,
}

Module_Surface :: struct {
	path:  string,
	decls: []Surface_Decl,
}

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
				{"to_fixed", .Func},
			{"to_int", .Func},
			{"or_else", .Func},
			{"is_some", .Func},
			{"compare", .Func},
		},
	},
	{
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
		path = "engine.world",
		decls = {
			{"View", .Type_Name},
			{"Ref", .Type_Name},
			{"Spawn", .Type_Name},
			{"Despawn", .Type_Name},
		},
	},
	{
		path = "engine.nav",
		decls = {
			{"Nav", .Type_Name},
			{"Path", .Type_Name},
			{"NavError", .Type_Name},
		},
	},
	{
		path = "engine.input",
		decls = {
			{"Input", .Type_Name},
			{"Key", .Type_Name},
			{"PadButton", .Type_Name},
			{"MouseButton", .Type_Name},
			{"PlayerId", .Type_Name},
			{"Bindings", .Type_Name},
			{"Stick", .Type_Name},
			{"Axis", .Type_Name},
			{"Button", .Type_Name},
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
		path = "engine.render",
		decls = {
			{"Draw", .Type_Name},
			{"Color", .Type_Name},
			{"Flip", .Type_Name},
			{"Align", .Type_Name},
		},
	},
	{
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
			{"last", .Func},
			{"prepend", .Func},
			{"append", .Func},
			{"reverse", .Func},
			{"init", .Func},
			{"contains", .Func},
			{"concat", .Func},
			{"is_empty", .Func},
			{"len", .Func},
			{"get", .Func},
			{"within", .Func},
			{"nearest_first", .Func},
		},
	},
	{
		path = "engine.rand",
		decls = {
			{"Rng", .Type_Name},
			{"seed", .Func},
			{"next", .Func},
			{"range", .Func},
			{"chance", .Func},
			{"split", .Func},
			{"pick", .Func},
		},
	},
	{
		path = "engine.grid",
		decls = {
			{"Cell", .Type_Name},
			{"grid_cells", .Func},
			{"neighbors", .Func},
			{"in_bounds", .Func},
		},
	},
	{
		path = "engine.map",
		decls = {
			{"Map", .Type_Name},
			{"empty", .Func},
			{"has", .Func},
			{"set", .Func},
			{"remove", .Func},
			{"keys", .Func},
			{"values", .Func},
		},
	},
	{
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
		path = "engine.render3",
		decls = {
			{"Draw3", .Type_Name},
			{"Material", .Type_Name},
		},
	},
	{
		path = "engine.ui",
		decls = {
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
		},
	},
	{
		path = "engine.audio",
		decls = {
			{"Sound", .Type_Name},
			{"Audio", .Type_Name},
			{"Bus", .Type_Name},
		},
	},
}

Reexport :: struct {
	module: string,
	name:   string,
	owner:  string,
}

@(rodata)
STDLIB_REEXPORTS := []Reexport{
	{"engine.math", "Fixed", "engine.prelude"},
	{"engine.math", "to_fixed", "engine.prelude"},
	{"engine.render3", "Color", "engine.render"},
	{"engine.ui", "View", "engine.world"},
	{"engine.ui", "map", "engine.list"},
	{"engine.map", "get", "engine.list"},
	{"engine.map", "len", "engine.list"},
}

Binding :: struct {
	module: string,
	kind:   Decl_Kind,
}

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

surface_reexport :: proc(module_path: string, name: string) -> (owner: string, found: bool) {
	for row in STDLIB_REEXPORTS {
		if row.module == module_path && row.name == name {
			return row.owner, true
		}
	}
	return "", false
}

bind_name :: proc(bindings: ^Bindings, name: string, binding: Binding) -> Type_Error {
	if existing, bound := bindings.names[name]; bound && existing != binding {
		return .Name_Collision
	}
	bindings.names[name] = binding
	return .None
}

resolve_imports :: proc(ast: Ast) -> (bindings: Bindings, err: Type_Error) {
	return resolve_imports_indexed(ast, Module_Index{})
}

stamp_import :: proc(site: ^Type_Diag_Site, node: Import_Node) {
	if site == nil || site.set {
		return
	}
	site.line = node.line
	site.col = node.col
	site.set = true
}

resolve_imports_indexed :: proc(ast: Ast, index: Module_Index, importer_root := "", site: ^Type_Diag_Site = nil) -> (bindings: Bindings, err: Type_Error) {
	bindings.names = make(map[string]Binding, context.temp_allocator)
	prelude, _ := surface_module("engine.prelude")
	for decl in prelude.decls {
		bindings.names[decl.name] = Binding{module = prelude.path, kind = decl.kind}
	}
	for node in ast.imports {
		if import_err := resolve_import(&bindings, node, index, importer_root); import_err != .None {
			stamp_import(site, node)
			return bindings, import_err
		}
	}
	return bindings, .None
}

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
		handle := node.segments[len(node.segments) - 1]
		bind_name(bindings, handle, Binding{module = module.path, kind = .Module}) or_return
		return .None
	}
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

surface_methods_for_receiver :: proc(receiver: Type, allocator := context.temp_allocator) -> string {
	names := make([dynamic]string, 0, 8, context.temp_allocator)
	if engine, is_engine := receiver.(^Engine_Type); is_engine {
		for key in SURFACE_DUMP_METHOD_PROBES {
			if key.kind != engine.kind {
				continue
			}
			if _, found := surface_engine_method(engine, key.member); found {
				append_unique(&names, key.member)
			}
		}
	}
	for module in STDLIB_SURFACE {
		for decl in module.decls {
			if decl.kind != .Func {
				continue
			}
			overloads, found := surface_signatures(decl.name)
			if !found {
				continue
			}
			for overload in overloads {
				fn, is_fn := overload.(^Func_Type)
				if !is_fn || len(fn.params) == 0 || fn.params[0] == nil {
					continue
				}
				if types_compatible(receiver, fn.params[0]) {
					append_unique(&names, decl.name)
					break
				}
			}
		}
	}
	for probe in SURFACE_COMBINATOR_PROBES {
		if surface_receiver_matches_combinator(receiver, probe.receiver) {
			append_unique(&names, probe.name)
		}
	}
	for member in SURFACE_GROUND_METHOD_NAMES {
		if _, found := surface_method(receiver, member); found {
			append_unique(&names, member)
		}
	}
	if len(names) == 0 {
		return ""
	}
	slice.sort(names[:])
	joined := strings.join(names[:], ", ", allocator)
	return fmt.aprintf("available methods: %s", joined, allocator = allocator)
}

Surface_Combinator_Receiver :: enum {
	List,
	List_Only,
	Rng,
	Option,
	Map,
}

Surface_Combinator_Probe :: struct {
	name:     string,
	receiver: Surface_Combinator_Receiver,
}

@(rodata)
SURFACE_COMBINATOR_PROBES := []Surface_Combinator_Probe{
	{"fold", .List},
	{"first", .List},
	{"find", .List},
	{"last", .List},
	{"map", .List},
	{"filter", .List},
	{"is_empty", .List},
	{"len", .List},
	{"get", .List},
	{"concat", .List_Only},
	{"append", .List_Only},
	{"reverse", .List_Only},
	{"contains", .List_Only},
	{"init", .List_Only},
	{"or_else", .Option},
	{"pick", .Rng},
	{"len", .Map},
	{"get", .Map},
	{"has", .Map},
	{"set", .Map},
	{"remove", .Map},
	{"keys", .Map},
	{"values", .Map},
}

surface_receiver_matches_combinator :: proc(receiver: Type, kind: Surface_Combinator_Receiver) -> bool {
	switch kind {
	case .List:
		_, ok := source_element(receiver)
		return ok
	case .List_Only:
		_, ok := receiver.(^List_Type)
		return ok
	case .Rng:
		return is_engine(receiver, .Rng)
	case .Option:
		_, ok := receiver.(^Option_Type)
		return ok
	case .Map:
		_, ok := receiver.(^Map_Type)
		return ok
	}
	return false
}

@(rodata)
SURFACE_GROUND_METHOD_NAMES := []string{"rotate", "mul", "slerp"}

surface_signatures :: proc(name: string) -> (overloads: []Type, found: bool) {
	switch name {
	case "seed":
		return clone_types({func_of({Ground_Type.Int}, engine_type_of(.Rng))}), true
	case "next":
		return clone_types({
			func_of({engine_type_of(.Rng)}, tuple_of({Ground_Type.Fixed, engine_type_of(.Rng)})),
		}), true
	case "range":
		return clone_types({
			func_of(
				{engine_type_of(.Rng), Ground_Type.Int, Ground_Type.Int},
				tuple_of({Ground_Type.Int, engine_type_of(.Rng)}),
			),
		}), true
	case "chance":
		return clone_types({
			func_of(
				{engine_type_of(.Rng), Ground_Type.Fixed},
				tuple_of({Ground_Type.Bool, engine_type_of(.Rng)}),
			),
		}), true
	case "split":
		return clone_types({
			func_of({engine_type_of(.Rng)}, tuple_of({engine_type_of(.Rng), engine_type_of(.Rng)})),
		}), true
	case "sin", "cos", "sqrt", "abs":
		return clone_types({func_of({Ground_Type.Fixed}, Ground_Type.Fixed)}), true
	case "clamp", "lerp":
		return clone_types({func_of({Ground_Type.Fixed, Ground_Type.Fixed, Ground_Type.Fixed}, Ground_Type.Fixed)}), true
	case "to_fixed":
		return clone_types({func_of({Ground_Type.Int}, Ground_Type.Fixed)}), true
	case "to_int":
		return clone_types({func_of({Ground_Type.Fixed}, Ground_Type.Int)}), true
	case "trunc", "floor", "round":
		return clone_types({func_of({Ground_Type.Fixed}, Ground_Type.Int)}), true
	case "checked_div":
		return clone_types({func_of({Ground_Type.Fixed, Ground_Type.Fixed}, option_of(Ground_Type.Fixed))}), true
	case "max":
		return clone_types({
			func_of({Ground_Type.Fixed, Ground_Type.Fixed}, Ground_Type.Fixed),
			func_of({Ground_Type.Int, Ground_Type.Int}, Ground_Type.Int),
		}), true
	case "compare":
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
		return clone_types({func_of({engine_type_of(.Key), engine_type_of(.Key)}, nil)}), true
	case "stick_x":
		return clone_types({func_of({engine_type_of(.Stick)}, nil)}), true
	case "stick_y":
		return clone_types({func_of({engine_type_of(.Stick)}, nil)}), true
	case "rot_x":
		return clone_types({func_of({Ground_Type.Fixed}, engine_type_of(.Transform))}), true
	case "up":
		return clone_types({func_of({Ground_Type.Fixed}, engine_type_of(.Transform))}), true
	case "wasd":
		return clone_types({func_of({}, nil)}), true
	case "arrows":
		return clone_types({func_of({}, nil)}), true
	case "dpad":
		return clone_types({func_of({}, nil)}), true
	case "stick":
		return clone_types({func_of({engine_type_of(.Stick)}, nil)}), true
	case "pad":
		return clone_types({func_of({engine_type_of(.PadButton)}, nil)}), true
	case "mouse":
		return clone_types({func_of({engine_type_of(.MouseButton)}, nil)}), true
	case "mesh":
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.MeshHandle))}), true
	case "texture":
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.TextureHandle))}), true
	case "sound":
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.SoundHandle))}), true
	case "atlas":
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.AtlasHandle))}), true
	case "text", "icon":
		return clone_types({func_of({engine_type_of(.String)}, engine_type_of(.View))}), true
	case "image":
		return clone_types({func_of({engine_type_of(.TextureHandle)}, engine_type_of(.View))}), true
	case "spacer":
		return clone_types({func_of({}, engine_type_of(.View))}), true
	case "panel", "row", "col", "grid", "stack":
		return clone_types({func_of({list_of(engine_type_of(.View))}, engine_type_of(.View))}), true
	case "scroll":
		return clone_types({func_of({engine_type_of(.View)}, engine_type_of(.View))}), true
	case "button":
		return clone_types({func_of({engine_type_of(.String), nil}, engine_type_of(.View))}), true
	case "field":
		return clone_types({func_of({engine_type_of(.String), func_of({engine_type_of(.String)}, nil)}, engine_type_of(.View))}), true
	case "slider":
		return clone_types({
			func_of(
				{Ground_Type.Int, Ground_Type.Int, Ground_Type.Int, func_of({Ground_Type.Int}, nil)},
				engine_type_of(.View),
			),
		}), true
	case "toggle":
		return clone_types({func_of({Ground_Type.Bool, func_of({Ground_Type.Bool}, nil)}, engine_type_of(.View))}), true
	}
	return nil, false
}

surface_enum_variant :: proc(type_name: string, variant: string) -> (type: Type, found: bool) {
	switch type_name {
	case "PlayerId":
		switch variant {
		case "P1", "P2", "P3", "P4":
			return engine_type_of(.PlayerId), true
		}
	case "Key":
		switch variant {
		case "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
		     "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
		     "Up", "Down", "Left", "Right", "Space", "Enter", "Escape", "Shift", "Tab",
		     "F5", "F9":
			return engine_type_of(.Key), true
		}
	case "PadButton":
		switch variant {
		case "A", "B", "X", "Y", "Start", "Back",
		     "LeftShoulder", "RightShoulder",
		     "DpadUp", "DpadDown", "DpadLeft", "DpadRight":
			return engine_type_of(.PadButton), true
		}
	case "MouseButton":
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
		switch variant {
		case "Less", "Equal", "Greater":
			return engine_type_of(.Ordering), true
		}
	case "Color":
		switch variant {
		case "White", "Black", "Red", "Green", "Blue", "Yellow", "Cyan", "Magenta", "Gray":
			return engine_type_of(.Color), true
		}
	case "Flip":
		switch variant {
		case "None", "X", "Y", "XY":
			return engine_type_of(.Flip), true
		}
	case "Align":
		switch variant {
		case "Left", "Center", "Right":
			return engine_type_of(.Align), true
		}
	case "Slot":
		switch variant {
		case "Torso", "Head",
		     "LUpperArm", "LLowerArm", "RUpperArm", "RLowerArm",
		     "LUpperLeg", "LLowerLeg", "RUpperLeg", "RLowerLeg",
		     "LHand", "RHand", "LFoot", "RFoot",
		     "Slot0", "Slot1", "Slot2", "Slot3":
			return engine_type_of(.Slot), true
		}
	case "Side":
		switch variant {
		case "L", "R":
			return engine_type_of(.Side), true
		}
	case "Bone":
		switch variant {
		case "Hips", "Torso", "Neck", "Head",
		     "LUpperArm", "LLowerArm", "RUpperArm", "RLowerArm",
		     "LUpperLeg", "LLowerLeg", "RUpperLeg", "RLowerLeg",
		     "LHand", "RHand", "LFoot", "RFoot",
		     "Joint0", "Joint1", "Joint2", "Joint3",
		     "Joint4", "Joint5", "Joint6", "Joint7":
			return engine_type_of(.Bone), true
		}
	case "Bus":
		switch variant {
		case "Master", "Music", "Sfx", "Ui", "Voice":
			return engine_type_of(.Bus), true
		}
	case "BodyKind":
		switch variant {
		case "Static", "Dynamic", "Kinematic":
			return engine_type_of(.BodyKind), true
		}
	case "NavError":
		switch variant {
		case "Unreachable", "OffNav":
			return engine_type_of(.NavError), true
		}
	}
	return nil, false
}

surface_static_method :: proc(type_name: string, member: string) -> (signature: Type, found: bool) {
	switch type_name {
	case "Rng":
		switch member {
		case "seed":
			return func_of({Ground_Type.Int}, engine_type_of(.Rng)), true
		}
	case "Map":
		switch member {
		case "empty":
			return func_of({}, map_of(nil, nil)), true
		}
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
			return func_of({}, engine_type_of(.Settings)), true
		}
	case "Nav":
		switch member {
		case "of":
			return func_of({engine_type_of(.Path)}, engine_type_of(.Nav)), true
		case "fail":
			return func_of({engine_type_of(.NavError)}, engine_type_of(.Nav)), true
		}
	case "TilemapHandle":
		switch member {
		case "of":
			return func_of(
				{Ground_Type.Int, list_of(tuple_of({nil, engine_type_of(.String), Ground_Type.Bool}))},
				engine_type_of(.TilemapHandle),
			), true
		}
	case "Skeleton":
		switch member {
		case "humanoid", "empty":
			return func_of({}, engine_type_of(.Skeleton)), true
		}
	case "PartSet":
		switch member {
		case "empty":
			return func_of({}, engine_type_of(.PartSet)), true
		}
	case "Pose":
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
		switch member {
		case "sfx":
			return func_of({engine_type_of(.SoundHandle)}, engine_type_of(.Sound)), true
		case "sfx_at":
			return func_of({engine_type_of(.SoundHandle), Ground_Type.Vec3}, engine_type_of(.Sound)), true
		}
	case "Audio":
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
			return func_of(
				{engine_type_of(.PlayerId), nil, Ground_Type.Fixed},
				engine_type_of(.Input),
			), true
		case "with_axis":
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
		if member == "apply_impulse" {
			return func_of({Ground_Type.Vec2}, engine_type_of(.Body)), true
		}
	case .View:
		switch member {
		case "count":
			return func_of({}, Ground_Type.Int), true
		case "at":
			return func_of({Ground_Type.Int}, receiver.elem), true
		case "resolve":
			return func_of({engine_type_of(.Ref, receiver.elem)}, option_of(receiver.elem)), true
		case "ref":
			return func_of({Ground_Type.Int}, engine_type_of(.Ref, receiver.elem)), true
		case "class":
			return func_of({engine_type_of(.String)}, engine_type_of(.View, receiver.elem)), true
		case "when":
			return func_of({Ground_Type.Bool}, engine_type_of(.View, receiver.elem)), true
		}
	case .Nav:
		switch member {
		case "path":
			return func_of({Ground_Type.Vec2, Ground_Type.Vec2}, engine_type_of(.Result)), true
		case "los", "reachable":
			return func_of({Ground_Type.Vec2, Ground_Type.Vec2}, Ground_Type.Bool), true
		case "nearest":
			return func_of({Ground_Type.Vec2}, option_of(Ground_Type.Vec2)), true
		}
	case .TilemapHandle:
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
		if member == "advance" {
			return func_of(
				{Ground_Type.Vec2, Ground_Type.Fixed},
				tuple_of({option_of(Ground_Type.Vec2), engine_type_of(.Path)}),
			), true
		}
	case .PartSet:
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
		switch member {
		case "gain", "pitch":
			return func_of({Ground_Type.Fixed}, engine_type_of(.Sound)), true
		case "bus":
			return func_of({engine_type_of(.Bus)}, engine_type_of(.Sound)), true
		case "at":
			return func_of({Ground_Type.Vec3}, engine_type_of(.Sound)), true
		}
	case .Audio:
		switch member {
		case "gain", "pitch":
			return func_of({Ground_Type.Fixed}, engine_type_of(.Audio)), true
		case "bus":
			return func_of({engine_type_of(.Bus)}, engine_type_of(.Audio)), true
		case "at":
			return func_of({Ground_Type.Vec3}, engine_type_of(.Audio)), true
		}
	case .AtlasHandle:
		switch member {
		case "cell":
			return func_of({Ground_Type.Int, Ground_Type.Int}, engine_type_of(.String)), true
		case "frame":
			return func_of({engine_type_of(.String), Ground_Type.Fixed}, engine_type_of(.String)), true
		}
	}
	return nil, false
}

surface_command :: proc(name: string) -> (signature: Type, found: bool) {
	switch name {
	case "Spawn":
		return func_of({nil}, engine_type_of(.Spawn)), true
	case "Despawn":
		return func_of({}, engine_type_of(.Despawn)), true
	}
	return nil, false
}

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
			return engine_type_of(.Draw), clone_fields({
					{name = "at", type = Ground_Type.Vec2},
					{name = "zoom", type = Ground_Type.Fixed},
					{name = "rotation", type = Ground_Type.Fixed},
				}), true
		case "Sprite":
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
		switch variant {
		case "Rgb":
			return engine_type_of(.Color), clone_fields({
					{name = "r", type = Ground_Type.Fixed},
					{name = "g", type = Ground_Type.Fixed},
					{name = "b", type = Ground_Type.Fixed},
				}), true
		}
	case "Draw3":
		switch variant {
		case "Camera":
			return engine_type_of(.Draw3), clone_fields({
					{name = "eye", type = Ground_Type.Vec3},
					{name = "at", type = Ground_Type.Vec3},
					{name = "fov", type = Ground_Type.Fixed},
				}), true
		case "Light":
			return engine_type_of(.Draw3), clone_fields({
					{name = "dir", type = Ground_Type.Vec3},
					{name = "color", type = engine_type_of(.Color)},
				}), true
		case "Plane":
			return engine_type_of(.Draw3), clone_fields({
					{name = "at", type = Ground_Type.Vec3},
					{name = "size", type = Ground_Type.Vec2},
					{name = "color", type = engine_type_of(.Color)},
				}), true
		case "Rigged":
			return engine_type_of(.Draw3), clone_fields({
					{name = "skeleton", type = engine_type_of(.Skeleton)},
					{name = "parts", type = engine_type_of(.PartSet)},
					{name = "pose", type = engine_type_of(.Pose)},
					{name = "at", type = Ground_Type.Vec3},
				}), true
		case "Mesh":
			return engine_type_of(.Draw3), clone_fields({
					{name = "handle", type = engine_type_of(.MeshHandle)},
					{name = "at", type = Ground_Type.Vec3},
					{name = "material", type = engine_type_of(.Material)},
				}), true
		}
	}
	return nil, nil, false
}

surface_engine_record :: proc(name: string) -> (result: Type, fields: []Surface_Field, found: bool) {
	switch name {
	case "Trigger":
		return engine_type_of(.Trigger), clone_fields({}), true
	case "Path":
		return engine_type_of(.Path), clone_fields({
				{name = "steps", type = list_of(Ground_Type.Vec2)},
				{name = "cost", type = Ground_Type.Fixed},
			}), true
	case "Body":
		return engine_type_of(.Body), clone_fields({
				{name = "kind", type = engine_type_of(.BodyKind)},
				{name = "shape", type = engine_type_of(.Shape2)},
				{name = "mass", type = Ground_Type.Fixed, default = FIXED_ONE, has_default = true},
				{name = "restitution", type = Ground_Type.Fixed, default = Fixed(0), has_default = true},
				{name = "friction", type = Ground_Type.Fixed, default = FIXED_ONE / 2, has_default = true},
				{name = "layer", type = nil},
				{name = "mask", type = nil},
				{name = "sensor", type = Ground_Type.Bool, default = false, has_default = true},
				{name = "impulse", type = Ground_Type.Vec2, default = Vec2_Value{}, has_default = true},
			}), true
	case "Settings":
		return engine_type_of(.Settings), clone_fields({
				{name = "volume", type = nil},
				{name = "binds", type = engine_type_of(.Bindings)},
				{name = "graphics", type = nil},
				{name = "access", type = engine_type_of(.AccessOpts)},
			}), true
	case "AccessOpts":
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
		return engine_type_of(.SetTile), clone_fields({
				{name = "map", type = engine_type_of(.TilemapHandle)},
				{name = "cell", type = nil},
				{name = "tile", type = engine_type_of(.String)},
			}), true
	case "BuildLayer":
		return engine_type_of(.BuildLayer), clone_fields({
				{name = "map", type = engine_type_of(.TilemapHandle)},
				{name = "fill", type = engine_type_of(.String)},
				{name = "cells", type = list_of(tuple_of({nil, engine_type_of(.String)}))},
			}), true
	}
	return nil, nil, false
}

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

surface_engine_member_record :: proc(receiver: ^Engine_Type, member: string) -> (type: Type, found: bool) {
	#partial switch receiver.kind {
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

Surface_Field :: struct {
	name:        string,
	type:        Type,
	default:     Value,
	has_default: bool,
}

// Clone so a call-site []Surface_Field{...} stack literal can't dangle past the constructor (mirrors clone_types).
clone_fields :: proc(set: []Surface_Field) -> []Surface_Field {
	cloned := make([]Surface_Field, len(set), context.temp_allocator)
	copy(cloned, set)
	return cloned
}
