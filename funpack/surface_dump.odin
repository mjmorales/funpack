// The compiler-authoritative stdlib-surface dump (`funpack introspect`): a
// read-only, byte-stable JSON projection of the LIVE surface.odin tables — the
// SAME tables `funpack check` enforces an import/typecheck against. It exists so
// corpus regeneration is mechanical (the .fun parity check compares against
// ground truth, not a hand-kept mirror) AND an author/agent has a fallback when
// the docs corpus and the compiler disagree: the exact gap that made the §26
// surface regression invisible was that there was no way to SEE the live
// surface.odin signatures except by trial compilation.
//
// SINGLE SOURCE, WALKED BY INDEX (the determinism tripwire): every section is
// generated FROM the surface.odin tables. The genuinely index-walkable rodata —
// STDLIB_SURFACE, STDLIB_REEXPORTS, CLOSED_VARIANT_SETS — is walked directly. The
// switch-keyed typed surfaces (surface_signatures / surface_enum_variant /
// surface_struct_variant / surface_engine_method / surface_static_method /
// surface_associated) are NOT iterable Odin tables, so the dump PROBES them: the
// free-function signatures are probed with the `.Func` decl names STDLIB_SURFACE
// already carries (those rows ARE the keys), and the variant/receiver surfaces
// are probed with the co-located closed probe tables below. A map is NEVER
// iterated; every walk is over an index-ordered slice, so the same source tree
// yields byte-identical bytes.
//
// THE PROBE-TABLE DRIFT SEAM (deliberate, gated by a parity test): the probe
// tables (SURFACE_DUMP_ENUM_PROBES etc.) mirror the switch arms WITHOUT
// modifying them — the §26 restore is dumped, never disturbed. test_surface_dump
// asserts every probed key types LIVE (found = true) and a curated negative set
// is rejected, so a probe that drifts from its switch is a loud test failure, not
// a silent omission. The drift-IMPOSSIBLE alternative (make the switches DELEGATE
// to index-walkable rodata) is a deliberate surface.odin refactor surfaced for
// the driver rather than taken under the "do not disturb the restore" directive.
//
// SCHEMA VERSION: the dump is self-describing through SURFACE_DUMP_SCHEMA_VERSION,
// its OWN constant — NOT INTROSPECT_SCHEMA_VERSION (the §28 capture-protocol
// version the funpack↔MCP contract owns) and NOT a new contract `schemas.*` slot.
// The embedded version keeps the dump self-describing without a cross-team
// contract change.
//
// PURITY (spec §29 §1): build_surface_dump is a pure function of the compile-time
// rodata alone — no clock, no host state, no IO — so surface_dump_json is
// byte-stable for a given source tree, and run_introspect_verb's exit contract is
// exactly {0} (an informational read, no refusal, no counted failure).
package funpack

import "core:encoding/json"
import "core:fmt"
import "core:reflect"
import "core:strings"

// SURFACE_DUMP_SCHEMA_VERSION is the dump's OWN self-describing version, bumped
// when the dump's JSON SHAPE changes (a section added/removed, a record field
// renamed) — NOT when the surface it projects grows (that is a population
// change, the same open-window discipline ARTIFACT_SCHEMA_VERSION holds). It is
// intentionally distinct from INTROSPECT_SCHEMA_VERSION: that constant mirrors
// the §28 runtime capture-protocol version the funpack↔MCP contract pins, a
// different concern from the compiler's stdlib-surface projection. The dump
// carries this version inline so a consumer reads it from the artifact itself,
// with no contract slot.
SURFACE_DUMP_SCHEMA_VERSION :: 1

// Surface_Dump is the whole dump as one marshal-able struct: field-declaration
// order is the emitted JSON key order (the Decl_Record marshal convention), and
// every field is a scalar or an index-ordered slice — no map — so a double
// encoding of the same source tree is byte-identical. schema_version leads so a
// consumer reads the shape version first.
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

// Dump_Module is one STDLIB_SURFACE partition: the dotted module path and its
// owned decls, in the table's declared order.
Dump_Module :: struct {
	path:  string,
	decls: []Dump_Decl,
}

// Dump_Decl is one Surface_Decl row: the importable name and its Decl_Kind
// (emitted as its readable name via use_enum_names — Type_Name / Func / Value /
// Module).
Dump_Decl :: struct {
	name: string,
	kind: Decl_Kind,
}

// Dump_Reexport is one STDLIB_REEXPORTS row: the re-exporting partition, the
// re-exported name, and the owning module the binding records (§26 §3).
Dump_Reexport :: struct {
	module: string,
	name:   string,
	owner:  string,
}

// Dump_Signature is one typed free-function overload set: the function name and
// each overload's rendered signature string (surface_type_string). A combinator
// row (fold/map/or_else — surface_signatures returns found = false) carries no
// signature line and so never appears here.
Dump_Signature :: struct {
	name:      string,
	overloads: []string,
}

// Dump_Enum_Variants is one engine enum's full closed variant set: the enum's
// type name and the variant names that type to it (surface_enum_variant), in the
// probe table's declared order.
Dump_Enum_Variants :: struct {
	type_name: string,
	variants:  []string,
}

// Dump_Struct_Variant is one struct-payload engine-enum variant (Color::Rgb,
// Draw::Sprite, Shape2::Box): the owning type, the variant, and its closed field
// set with each field's rendered type.
Dump_Struct_Variant :: struct {
	type_name: string,
	variant:   string,
	fields:    []Dump_Field,
}

// Dump_Field is one named field of a struct-payload variant: the field name and
// its rendered expected type (surface_type_string).
Dump_Field :: struct {
	name: string,
	type: string,
}

// Dump_Method is one receiver/static/associated member: the receiver type name,
// the member name, and its rendered signature string. The same record shape
// serves the engine-method (value-receiver), static-method (Type-name builder),
// and associated (Type-name constant/constructor) surfaces — they differ only by
// which probe table fills them.
Dump_Method :: struct {
	type_name: string,
	member:    string,
	signature: string,
}

// Surface_Dump_Probe pairs an engine enum type name with the candidate variant
// names the dump probes surface_enum_variant against. The pair is the closed
// probe set; a member that does not type LIVE (found = false) is a probe-table
// drift the parity test (test_surface_dump) fails on, never a silently-emitted
// phantom variant.
Surface_Dump_Probe :: struct {
	type_name: string,
	variants:  []string,
}

// SURFACE_DUMP_ENUM_PROBES mirrors the surface_enum_variant switch arms — every
// engine enum and its full declared variant set — WITHOUT modifying the switch.
// Walked by index. This is the §26 restore's Color palette (Yellow/Cyan/Magenta
// among White/Black/Red/Green/Blue/Gray) plus every other engine enum's set, so
// the dump makes a dropped palette entry visible. The drift seam (a switch arm
// not added here) is gated by test_surface_dump's "every probed key types live"
// assertion.
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

// SURFACE_DUMP_STRUCT_PROBES mirrors the surface_struct_variant switch's
// (type_name, variant) keys — the struct-payload engine-enum variants, Color::Rgb
// among them — WITHOUT modifying the switch. Walked by index; the field set and
// each field's type come from the LIVE surface_struct_variant call, so the dump
// projects exactly what the checker enforces.
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

// Surface_Dump_Variant_Key is one (type_name, variant) probe key for the
// struct-payload surface — the closed key set the dump walks by index.
Surface_Dump_Variant_Key :: struct {
	type_name: string,
	variant:   string,
}

// SURFACE_DUMP_METHOD_PROBES mirrors the surface_engine_method switch's
// (receiver-kind, member) keys — the value-receiver surfaces (View.count/at,
// Input queries, Sound/Audio adders, the AtlasHandle/TilemapHandle accessors) —
// keyed by the receiver's engine KIND so the dump can build a probe receiver.
// Walked by index. The receiver element (View[T]) is supplied a structural
// stand-in (a Data User_Type) so the parameterized arms (at/resolve/ref) render
// their element-keyed signatures.
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

// Surface_Dump_Method_Key is one (receiver-kind, member) probe key for the
// engine-method surface — keyed by Engine_Kind so the dump can construct the
// receiver Engine_Type before probing.
Surface_Dump_Method_Key :: struct {
	kind:   Engine_Kind,
	member: string,
}

// SURFACE_DUMP_STATIC_PROBES mirrors the surface_static_method switch's
// (type_name, member) keys — the Type-name static builders (Bindings.empty,
// View.of, Pose.blend, Sound.sfx, …). Walked by index.
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

// SURFACE_DUMP_ASSOCIATED_PROBES mirrors the surface_associated switch's
// (type_name, member) keys — the Type-name associated constants and constructors
// (Fixed.MAX/MIN, Quat.identity/axis_angle). Walked by index.
@(rodata)
SURFACE_DUMP_ASSOCIATED_PROBES := []Surface_Dump_Variant_Key{
	{"Fixed", "MAX"},
	{"Fixed", "MIN"},
	{"Quat", "identity"},
	{"Quat", "axis_angle"},
}

// build_surface_dump assembles the whole dump from the live surface tables. Every
// section is a forward index walk — STDLIB_SURFACE / STDLIB_REEXPORTS walked
// directly, the switch-keyed surfaces probed in their probe table's declared
// order — so the result is a deterministic function of the rodata alone (no map
// iteration, no clock). Allocated in the temp allocator (the call site is the
// verb's request scope).
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

// dump_modules walks STDLIB_SURFACE by index, projecting each partition's path
// and its decls (name + kind) in declared order.
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

// dump_reexports walks STDLIB_REEXPORTS by index, projecting each §26 §3 row.
dump_reexports :: proc() -> []Dump_Reexport {
	rows := make([]Dump_Reexport, len(STDLIB_REEXPORTS), context.temp_allocator)
	for row, i in STDLIB_REEXPORTS {
		rows[i] = Dump_Reexport{module = row.module, name = row.name, owner = row.owner}
	}
	return rows
}

// dump_signatures probes surface_signatures with every `.Func` decl name across
// STDLIB_SURFACE — those rows ARE the keys, so the probe set is the surface
// itself, never a hand-kept list. A combinator row (found = false) is omitted (it
// has no fixed signature — its typing is the call site's). The walk is over the
// index-ordered partitions and their index-ordered decls, so the order is
// deterministic.
dump_signatures :: proc() -> []Dump_Signature {
	sigs := make([dynamic]Dump_Signature, 0, 32, context.temp_allocator)
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
			append(&sigs, Dump_Signature{name = decl.name, overloads = rendered})
		}
	}
	return sigs[:]
}

// dump_enum_variants probes surface_enum_variant over SURFACE_DUMP_ENUM_PROBES by
// index. Every probed variant that types LIVE (found = true) is emitted; a
// variant that does NOT type is a probe-table drift skipped here and caught by
// test_surface_dump, never a phantom emitted as if it were a member.
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

// dump_struct_variants probes surface_struct_variant over SURFACE_DUMP_STRUCT_PROBES
// by index, projecting each variant's closed field set with each field's rendered
// type. A key that does not type LIVE is skipped (the parity test catches it).
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

// dump_engine_methods probes surface_engine_method over SURFACE_DUMP_METHOD_PROBES
// by index. Each key names a receiver KIND; the probe builds the receiver
// Engine_Type (with a structural Data element for the parameterized View arms) and
// renders the resolved signature. The receiver kind's readable name (reflect)
// is the emitted type_name.
dump_engine_methods :: proc() -> []Dump_Method {
	methods := make([dynamic]Dump_Method, 0, len(SURFACE_DUMP_METHOD_PROBES), context.temp_allocator)
	for key in SURFACE_DUMP_METHOD_PROBES {
		// The View arms key off the receiver's element T; a structural Data
		// User_Type stands in so at/resolve/ref render their element-keyed
		// signatures (the same stand-in the restore test seeds View[Switch] with).
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

// dump_static_methods probes surface_static_method over SURFACE_DUMP_STATIC_PROBES
// by index, rendering each Type-name static builder's resolved signature.
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

// dump_associated probes surface_associated over SURFACE_DUMP_ASSOCIATED_PROBES by
// index, rendering each associated constant's value type or constructor signature.
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

// surface_type_string renders a checker Type to a stable, human-readable string —
// the dump's signature/field-type spelling. It is a TOTAL function of the Type
// union (every arm handled), deterministic, and never reads a map: a Ground_Type
// and an Engine_Kind render through reflect.enum_name (their declared spelling),
// Option/List/Tuple/Func render structurally with their element types, and a nil
// Type (the one unknown — Option::None's element, a combinator parameter) renders
// "_". A Func with nil params (the opaque lambda placeholder) renders "fn(_)".
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
	case ^Tuple_Type:
		return surface_tuple_string(t.elements)
	case ^Func_Type:
		return surface_func_string(t)
	case ^User_Type:
		return strings.clone(t.name, context.temp_allocator)
	}
	// nil Type — the one unknown (Option::None's element, a combinator-inferred
	// parameter, the axis-source result). Rendered as the underscore the checker
	// model documents it as.
	return "_"
}

// surface_func_string renders a function type as `fn(p0, p1, …) -> R`. A nil
// params slice (the opaque lambda placeholder — func_of(nil, …)) renders the
// single `_` parameter the model documents; an empty (non-nil) params slice
// renders `fn() -> R`.
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

// surface_tuple_string renders a tuple type as `(e0, e1, …)` over its positional
// element types, in order.
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

// engine_kind_dump_name renders an Engine_Kind as the surface NAME a receiver is
// dumped under — the kind's declared enum spelling (reflect), which equals the
// surface type name for every method-bearing kind (View, Input, Sound, …). It is
// the dump-side twin of engine_kind_name (which only the record kinds need),
// covering every receiver kind the method probe table names.
engine_kind_dump_name :: proc(kind: Engine_Kind) -> string {
	name, _ := reflect.enum_name_from_value(kind)
	return strings.clone(name, context.temp_allocator)
}

// surface_dump_json renders the dump as one byte-stable JSON object: the compact
// struct marshal with enum values as their readable names (use_enum_names) —
// field-declaration order is the key order, no map is marshaled, so a double
// emission over the same source tree is byte-identical (§29 §1). No trailing
// newline: a machine surface emits exactly the JSON value (the version --json
// convention). Allocated in `allocator`.
surface_dump_json :: proc(allocator := context.allocator) -> string {
	dump := build_surface_dump()
	bytes, _ := json.marshal(dump, {use_enum_names = true}, context.temp_allocator)
	return strings.clone(string(bytes), allocator)
}

// run_introspect_verb prints the stdlib-surface dump JSON to stdout and exits 0.
// An informational read with a single success tier — no refusal, no counted
// failure — so its exit contract is exactly {0}, like `funpack version` (never
// the build verbs' 2 or the test verb's 1). Pure but for the print: the JSON is a
// function of the compile-time surface rodata alone.
run_introspect_verb :: proc() -> int {
	fmt.println(surface_dump_json(context.temp_allocator))
	return 0
}
