package funpack

import "core:encoding/json"
import "core:fmt"
import "core:reflect"
import "core:strings"

SURFACE_DUMP_SCHEMA_VERSION :: 2

Surface_Dump :: struct {
	schema_version:  int,
	modules:         []Dump_Module,
	reexports:       []Dump_Reexport,
	signatures:      []Dump_Signature,
	enum_variants:   []Dump_Enum_Variants,
	struct_variants: []Dump_Struct_Variant,
	engine_methods:  []Dump_Method,
	static_methods:  []Dump_Method,
	associated:      []Dump_Method,
}

Dump_Module :: struct {
	path:  string,
	decls: []Dump_Decl,
}

Dump_Decl :: struct {
	name: string,
	kind: Decl_Kind,
}

Dump_Reexport :: struct {
	module: string,
	name:   string,
	owner:  string,
}

Dump_Signature :: struct {
	name:               string,
	overloads:          []string,
	call_site_inferred: bool,
}

Dump_Enum_Variants :: struct {
	type_name: string,
	variants:  []string,
}

Dump_Struct_Variant :: struct {
	type_name: string,
	variant:   string,
	fields:    []Dump_Field,
}

Dump_Field :: struct {
	name: string,
	type: string,
}

Dump_Method :: struct {
	type_name: string,
	member:    string,
	signature: string,
}

Surface_Dump_Probe :: struct {
	type_name: string,
	variants:  []string,
}

@(rodata)
SURFACE_DUMP_ENUM_PROBES := []Surface_Dump_Probe{
	{"PlayerId", {"P1", "P2", "P3", "P4"}},
	{
		"Key",
		{
			"A",
			"B",
			"C",
			"D",
			"E",
			"F",
			"G",
			"H",
			"I",
			"J",
			"K",
			"L",
			"M",
			"N",
			"O",
			"P",
			"Q",
			"R",
			"S",
			"T",
			"U",
			"V",
			"W",
			"X",
			"Y",
			"Z",
			"Up",
			"Down",
			"Left",
			"Right",
			"Space",
			"Enter",
			"Escape",
			"Shift",
			"Tab",
			"F5",
			"F9",
		},
	},
	{
		"PadButton",
		{
			"A",
			"B",
			"X",
			"Y",
			"Start",
			"Back",
			"LeftShoulder",
			"RightShoulder",
			"DpadUp",
			"DpadDown",
			"DpadLeft",
			"DpadRight",
		},
	},
	{"MouseButton", {"Left", "Middle", "Right"}},
	{"Stick", {"Left", "Right"}},
	{"Ordering", {"Less", "Equal", "Greater"}},
	{"Color", {"White", "Black", "Red", "Green", "Blue", "Yellow", "Cyan", "Magenta", "Gray"}},
	{"Flip", {"None", "X", "Y", "XY"}},
	{"Align", {"Left", "Center", "Right"}},
	{
		"Slot",
		{
			"Torso",
			"Head",
			"LUpperArm",
			"LLowerArm",
			"RUpperArm",
			"RLowerArm",
			"LUpperLeg",
			"LLowerLeg",
			"RUpperLeg",
			"RLowerLeg",
			"LHand",
			"RHand",
			"LFoot",
			"RFoot",
			"Slot0",
			"Slot1",
			"Slot2",
			"Slot3",
		},
	},
	{"Side", {"L", "R"}},
	{
		"Bone",
		{
			"Hips",
			"Torso",
			"Neck",
			"Head",
			"LUpperArm",
			"LLowerArm",
			"RUpperArm",
			"RLowerArm",
			"LUpperLeg",
			"LLowerLeg",
			"RUpperLeg",
			"RLowerLeg",
			"LHand",
			"RHand",
			"LFoot",
			"RFoot",
			"Joint0",
			"Joint1",
			"Joint2",
			"Joint3",
			"Joint4",
			"Joint5",
			"Joint6",
			"Joint7",
		},
	},
	{"Bus", {"Master", "Music", "Sfx", "Ui", "Voice"}},
	{"BodyKind", {"Static", "Dynamic", "Kinematic"}},
	{"NavError", {"Unreachable", "OffNav"}},
}

@(rodata)
SURFACE_DUMP_STRUCT_PROBES := []Surface_Dump_Variant_Key{
	{"Draw", "Rect"},
	{"Draw", "Text"},
	{"Draw", "Camera"},
	{"Draw", "Sprite"},
	{"Shape2", "Box"},
	{"Shape2", "Circle"},
	{"Color", "Rgb"},
	{"Draw3", "Camera"},
	{"Draw3", "Light"},
	{"Draw3", "Plane"},
	{"Draw3", "Rigged"},
	{"Draw3", "Mesh"},
}

Surface_Dump_Variant_Key :: struct {
	type_name: string,
	variant:   string,
}

@(rodata)
SURFACE_DUMP_METHOD_PROBES := []Surface_Dump_Method_Key{
	{.Input, "pressed"},
	{.Input, "released"},
	{.Input, "held"},
	{.Input, "value"},
	{.Input, "axis"},
	{.Input, "with_pressed"},
	{.Input, "with_value"},
	{.Input, "with_axis"},
	{.Bindings, "axis"},
	{.Bindings, "button"},
	{.Body, "apply_impulse"},
	{.View, "count"},
	{.View, "at"},
	{.View, "resolve"},
	{.View, "ref"},
	{.View, "class"},
	{.View, "when"},
	{.Nav, "path"},
	{.Nav, "los"},
	{.Nav, "reachable"},
	{.Nav, "nearest"},
	{.TilemapHandle, "tile_at"},
	{.TilemapHandle, "solid_at"},
	{.TilemapHandle, "cell_of"},
	{.TilemapHandle, "center_of"},
	{.Path, "advance"},
	{.PartSet, "bind"},
	{.PartSet, "mirror"},
	{.Pose, "set"},
	{.Pose, "get"},
	{.Sound, "gain"},
	{.Sound, "pitch"},
	{.Sound, "bus"},
	{.Sound, "at"},
	{.Audio, "gain"},
	{.Audio, "pitch"},
	{.Audio, "bus"},
	{.Audio, "at"},
	{.AtlasHandle, "cell"},
	{.AtlasHandle, "frame"},
}

Surface_Dump_Method_Key :: struct {
	kind:   Engine_Kind,
	member: string,
}

@(rodata)
SURFACE_DUMP_STATIC_PROBES := []Surface_Dump_Variant_Key{
	{"Bindings", "empty"},
	{"Input", "empty"},
	{"Time", "at"},
	{"View", "of"},
	{"Settings", "defaults"},
	{"Nav", "of"},
	{"Nav", "fail"},
	{"TilemapHandle", "of"},
	{"Skeleton", "humanoid"},
	{"Skeleton", "empty"},
	{"PartSet", "empty"},
	{"Pose", "empty"},
	{"Pose", "blend"},
	{"Pose", "layer"},
	{"Sound", "sfx"},
	{"Sound", "sfx_at"},
	{"Audio", "track"},
}

@(rodata)
SURFACE_DUMP_ASSOCIATED_PROBES := []Surface_Dump_Variant_Key{
	{"Fixed", "MAX"},
	{"Fixed", "MIN"},
	{"Quat", "identity"},
	{"Quat", "axis_angle"},
}

Surface_Dump_Combinator_Sig :: struct {
	name:      string,
	signature: string,
}

@(rodata)
SURFACE_DUMP_COMBINATOR_SIGS := []Surface_Dump_Combinator_Sig {
	{"pick", "fn(Rng, [T]) -> (Option[T], Rng)"},
	{"len", "fn([T]) -> Int"},
	{"is_empty", "fn([T]) -> Bool"},
	{"get", "fn([T], Int) -> Option[T]"},
	{"first", "fn([T]) -> Option[T]"},
	{"last", "fn([T]) -> Option[T]"},
	{"prepend", "fn([T], T) -> [T]"},
	{"init", "fn([T]) -> [T]"},
	{"concat", "fn([T], [T]) -> [T]"},
	{"contains", "fn([T], T) -> Bool"},
	{"map", "fn([T], fn(T) -> U) -> [U]"},
	{"filter", "fn([T], fn(T) -> Bool) -> [T]"},
	{"fold", "fn([T], A, fn(A, T) -> A) -> A"},
	{"within", "fn([T], Vec2, Fixed) -> [T]"},
	{"nearest_first", "fn([T], Vec2) -> [T]"},
	{"grid_cells", "fn(Cell) -> [Cell]"},
	{"neighbors", "fn(Cell) -> [Cell]"},
	{"in_bounds", "fn(Cell, Cell) -> Bool"},
	{"or_else", "fn(Option[T], T) -> T"},
	{"is_some", "fn(Option[T]) -> Bool"},
}

build_surface_dump :: proc() -> Surface_Dump {
	return Surface_Dump {
		schema_version  = SURFACE_DUMP_SCHEMA_VERSION,
		modules         = dump_modules(),
		reexports       = dump_reexports(),
		signatures      = dump_signatures(),
		enum_variants   = dump_enum_variants(),
		struct_variants = dump_struct_variants(),
		engine_methods  = dump_engine_methods(),
		static_methods  = dump_static_methods(),
		associated      = dump_associated(),
	}
}

dump_modules :: proc() -> []Dump_Module {
	modules := make([]Dump_Module, len(STDLIB_SURFACE), context.temp_allocator)
	for module, i in STDLIB_SURFACE {
		decls := make([]Dump_Decl, len(module.decls), context.temp_allocator)
		for decl, j in module.decls {
			decls[j] = Dump_Decl{name = decl.name, kind = decl.kind}
		}
		modules[i] = Dump_Module{path = module.path, decls = decls}
	}
	return modules
}

dump_reexports :: proc() -> []Dump_Reexport {
	rows := make([]Dump_Reexport, len(STDLIB_REEXPORTS), context.temp_allocator)
	for row, i in STDLIB_REEXPORTS {
		rows[i] = Dump_Reexport{module = row.module, name = row.name, owner = row.owner}
	}
	return rows
}

dump_signatures :: proc() -> []Dump_Signature {
	sigs := make([dynamic]Dump_Signature, 0, 48, context.temp_allocator)
	for module in STDLIB_SURFACE {
		for decl in module.decls {
			if decl.kind != .Func {
				continue
			}
			overloads, found := surface_signatures(decl.name)
			if !found {
				continue
			}
			rendered := make([]string, len(overloads), context.temp_allocator)
			for overload, j in overloads {
				rendered[j] = surface_type_string(overload)
			}
			append(
				&sigs,
				Dump_Signature{name = decl.name, overloads = rendered, call_site_inferred = false},
			)
		}
	}
	for combinator in SURFACE_DUMP_COMBINATOR_SIGS {
		overload := make([]string, 1, context.temp_allocator)
		overload[0] = combinator.signature
		append(
			&sigs,
			Dump_Signature {
				name = combinator.name,
				overloads = overload,
				call_site_inferred = true,
			},
		)
	}
	return sigs[:]
}

dump_enum_variants :: proc() -> []Dump_Enum_Variants {
	sets := make([]Dump_Enum_Variants, len(SURFACE_DUMP_ENUM_PROBES), context.temp_allocator)
	for probe, i in SURFACE_DUMP_ENUM_PROBES {
		variants := make([dynamic]string, 0, len(probe.variants), context.temp_allocator)
		for variant in probe.variants {
			if _, found := surface_enum_variant(probe.type_name, variant); found {
				append(&variants, variant)
			}
		}
		sets[i] = Dump_Enum_Variants{type_name = probe.type_name, variants = variants[:]}
	}
	return sets
}

dump_struct_variants :: proc() -> []Dump_Struct_Variant {
	variants := make([dynamic]Dump_Struct_Variant, 0, len(SURFACE_DUMP_STRUCT_PROBES), context.temp_allocator)
	for key in SURFACE_DUMP_STRUCT_PROBES {
		_, fields, found := surface_struct_variant(key.type_name, key.variant)
		if !found {
			continue
		}
		dumped := make([]Dump_Field, len(fields), context.temp_allocator)
		for field, j in fields {
			dumped[j] = Dump_Field{name = field.name, type = surface_type_string(field.type)}
		}
		append(
			&variants,
			Dump_Struct_Variant{type_name = key.type_name, variant = key.variant, fields = dumped},
		)
	}
	return variants[:]
}

dump_engine_methods :: proc() -> []Dump_Method {
	methods := make([dynamic]Dump_Method, 0, len(SURFACE_DUMP_METHOD_PROBES), context.temp_allocator)
	for key in SURFACE_DUMP_METHOD_PROBES {
		receiver := engine_type_of(key.kind, user_type_of("T", .Data)).(^Engine_Type)
		signature, found := surface_engine_method(receiver, key.member)
		if !found {
			continue
		}
		append(
			&methods,
			Dump_Method {
				type_name = engine_kind_dump_name(key.kind),
				member = key.member,
				signature = surface_type_string(signature),
			},
		)
	}
	return methods[:]
}

dump_static_methods :: proc() -> []Dump_Method {
	methods := make([dynamic]Dump_Method, 0, len(SURFACE_DUMP_STATIC_PROBES), context.temp_allocator)
	for key in SURFACE_DUMP_STATIC_PROBES {
		signature, found := surface_static_method(key.type_name, key.variant)
		if !found {
			continue
		}
		append(
			&methods,
			Dump_Method {
				type_name = key.type_name,
				member = key.variant,
				signature = surface_type_string(signature),
			},
		)
	}
	return methods[:]
}

dump_associated :: proc() -> []Dump_Method {
	methods := make([dynamic]Dump_Method, 0, len(SURFACE_DUMP_ASSOCIATED_PROBES), context.temp_allocator)
	for key in SURFACE_DUMP_ASSOCIATED_PROBES {
		type, found := surface_associated(key.type_name, key.variant)
		if !found {
			continue
		}
		append(
			&methods,
			Dump_Method {
				type_name = key.type_name,
				member = key.variant,
				signature = surface_type_string(type),
			},
		)
	}
	return methods[:]
}

surface_type_string :: proc(type: Type) -> string {
	switch t in type {
	case Ground_Type:
		name, _ := reflect.enum_name_from_value(t)
		return strings.clone(name, context.temp_allocator)
	case ^Engine_Type:
		base, _ := reflect.enum_name_from_value(t.kind)
		if t.elem == nil {
			return strings.clone(base, context.temp_allocator)
		}
		return strings.concatenate(
			{base, "[", surface_type_string(t.elem), "]"},
			context.temp_allocator,
		)
	case ^Option_Type:
		return strings.concatenate(
			{"Option[", surface_type_string(t.elem), "]"},
			context.temp_allocator,
		)
	case ^List_Type:
		return strings.concatenate({"[", surface_type_string(t.elem), "]"}, context.temp_allocator)
	case ^Map_Type:
		return strings.concatenate(
			{"Map[", surface_type_string(t.key), ", ", surface_type_string(t.value), "]"},
			context.temp_allocator,
		)
	case ^Tuple_Type:
		return surface_tuple_string(t.elements)
	case ^Func_Type:
		return surface_func_string(t)
	case ^User_Type:
		return strings.clone(t.name, context.temp_allocator)
	}
	return "_"
}

surface_func_string :: proc(t: ^Func_Type) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "fn(")
	if t.params == nil {
		strings.write_string(&b, "_")
	} else {
		for param, i in t.params {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, surface_type_string(param))
		}
	}
	strings.write_string(&b, ") -> ")
	strings.write_string(&b, surface_type_string(t.result))
	return strings.to_string(b)
}

surface_tuple_string :: proc(elements: []Type) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "(")
	for elem, i in elements {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, surface_type_string(elem))
	}
	strings.write_string(&b, ")")
	return strings.to_string(b)
}

engine_kind_dump_name :: proc(kind: Engine_Kind) -> string {
	name, _ := reflect.enum_name_from_value(kind)
	return strings.clone(name, context.temp_allocator)
}

surface_dump_json :: proc(allocator := context.allocator) -> string {
	dump := build_surface_dump()
	bytes, _ := json.marshal(dump, {use_enum_names = true}, context.temp_allocator)
	return strings.clone(string(bytes), allocator)
}

run_introspect_verb :: proc() -> int {
	fmt.println(surface_dump_json(context.temp_allocator))
	return 0
}
