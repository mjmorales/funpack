package funpack

import "core:strings"
import "core:testing"

@(test)
test_surface_dump_is_byte_stable :: proc(t: ^testing.T) {
	first := surface_dump_json(context.temp_allocator)
	second := surface_dump_json(context.temp_allocator)
	testing.expect(t, first == second, "the surface dump is byte-identical across two builds")
	testing.expect(t, len(first) > 0, "the dump is non-empty")
}

@(test)
test_surface_dump_carries_schema_version :: proc(t: ^testing.T) {
	dump := build_surface_dump()
	testing.expect_value(t, dump.schema_version, SURFACE_DUMP_SCHEMA_VERSION)

	json := surface_dump_json(context.temp_allocator)
	testing.expect(
		t,
		strings.has_prefix(json, `{"schema_version":2`),
		"the dump JSON opens with its schema_version",
	)
}

@(test)
test_surface_dump_makes_the_restore_visible :: proc(t: ^testing.T) {
	dump := build_surface_dump()

	compare_found := false
	for sig in dump.signatures {
		if sig.name != "compare" {
			continue
		}
		compare_found = true
		testing.expect_value(t, len(sig.overloads), 2)
		testing.expect(t, slice_has(sig.overloads, "fn(Fixed, Fixed) -> Ordering"))
		testing.expect(t, slice_has(sig.overloads, "fn(Int, Int) -> Ordering"))
		testing.expect(t, !sig.call_site_inferred, "compare is a fixed-signature function")
	}
	testing.expect(t, compare_found, "compare appears in the dumped signatures")

	count_found, at_found := false, false
	for m in dump.engine_methods {
		if m.type_name == "View" && m.member == "count" {
			count_found = true
			testing.expect_value(t, m.signature, "fn(_) -> Int")
		}
		if m.type_name == "View" && m.member == "at" {
			at_found = true
			testing.expect_value(t, m.signature, "fn(Int) -> T")
		}
	}
	testing.expect(t, count_found, "View.count appears in the dumped engine methods")
	testing.expect(t, at_found, "View.at appears in the dumped engine methods")

	palette_found := false
	for set in dump.enum_variants {
		if set.type_name != "Color" {
			continue
		}
		palette_found = true
		for want in ([]string{
			"White",
			"Black",
			"Red",
			"Green",
			"Blue",
			"Yellow",
			"Cyan",
			"Magenta",
			"Gray",
		}) {
			testing.expectf(t, slice_has(set.variants, want), "Color palette includes %s", want)
		}
	}
	testing.expect(t, palette_found, "the Color enum's variant set appears in the dump")

	rgb_found := false
	for sv in dump.struct_variants {
		if sv.type_name != "Color" || sv.variant != "Rgb" {
			continue
		}
		rgb_found = true
		testing.expect_value(t, len(sv.fields), 3)
		want_fields := []string{"r", "g", "b"}
		for field, i in sv.fields {
			testing.expect_value(t, field.name, want_fields[i])
			testing.expect_value(t, field.type, "Fixed")
		}
	}
	testing.expect(t, rgb_found, "Color::Rgb appears in the dumped struct variants")
}

@(test)
test_surface_dump_surfaces_call_site_inferred_combinators :: proc(t: ^testing.T) {
	dump := build_surface_dump()

	pick_found := false
	for sig in dump.signatures {
		if sig.name != "pick" {
			continue
		}
		pick_found = true
		testing.expect(t, sig.call_site_inferred, "pick is marked call_site_inferred")
		testing.expect_value(t, len(sig.overloads), 1)
		testing.expect_value(t, sig.overloads[0], "fn(Rng, [T]) -> (Option[T], Rng)")
	}
	testing.expect(t, pick_found, "engine.rand.pick appears in the dumped signatures")

	Want :: struct {
		name:      string,
		signature: string,
	}
	wants := []Want{{"map", "fn([T], fn(T) -> U) -> [U]"}, {"fold", "fn([T], A, fn(A, T) -> A) -> A"}}
	for want in wants {
		found := false
		for sig in dump.signatures {
			if sig.name != want.name {
				continue
			}
			found = true
			testing.expectf(t, sig.call_site_inferred, "%s is marked call_site_inferred", want.name)
			testing.expect_value(t, len(sig.overloads), 1)
			testing.expect_value(t, sig.overloads[0], want.signature)
		}
		testing.expectf(t, found, "engine.list.%s appears in the dumped signatures", want.name)
	}
}

@(test)
test_surface_dump_combinator_probe_completeness :: proc(t: ^testing.T) {
	for combinator in SURFACE_DUMP_COMBINATOR_SIGS {
		is_func_decl := false
		for module in STDLIB_SURFACE {
			for decl in module.decls {
				if decl.name == combinator.name && decl.kind == .Func {
					is_func_decl = true
				}
			}
		}
		testing.expectf(t, is_func_decl, "combinator probe %s is a live .Func decl", combinator.name)
		_, has_fixed := surface_signatures(combinator.name)
		testing.expectf(
			t,
			!has_fixed,
			"combinator probe %s carries no fixed surface_signatures row",
			combinator.name,
		)
	}

	for name in COMBINATOR_CHECK_NAMES {
		covered := false
		for combinator in SURFACE_DUMP_COMBINATOR_SIGS {
			if combinator.name == name {
				covered = true
			}
		}
		testing.expectf(
			t,
			covered,
			"combinator_call_check name %s is surfaced by the dump's combinator probe table",
			name,
		)
	}
}

@(rodata)
COMBINATOR_CHECK_NAMES := []string {
	"fold",
	"first",
	"last",
	"neighbors",
	"in_bounds",
	"within",
	"nearest_first",
	"or_else",
	"map",
	"filter",
	"concat",
	"contains",
	"prepend",
	"init",
	"is_empty",
	"len",
	"get",
	"pick",
	"grid_cells",
}

@(test)
test_surface_dump_lists_the_variant_readmit :: proc(t: ^testing.T) {
	dump := build_surface_dump()

	Want :: struct {
		type_name: string,
		variants:  []string,
	}
	wants := []Want {
		{"PlayerId", {"P1", "P2", "P3", "P4"}},
		{"Bone", {"Hips", "Neck", "LHand", "RHand", "LFoot", "RFoot", "Joint7"}},
		{"Slot", {"LHand", "RHand", "LFoot", "RFoot", "Slot0", "Slot3"}},
		{"Key", {"Q", "Escape", "Shift", "Tab"}},
		{"Align", {"Left", "Center", "Right"}},
	}
	for want in wants {
		found := false
		for set in dump.enum_variants {
			if set.type_name != want.type_name {
				continue
			}
			found = true
			for variant in want.variants {
				testing.expectf(
					t,
					slice_has(set.variants, variant),
					"%s::%s appears in the dumped variant set",
					want.type_name,
					variant,
				)
			}
		}
		testing.expectf(t, found, "the %s enum's variant set appears in the dump", want.type_name)
	}

	Decl_Want :: struct {
		path: string,
		name: string,
	}
	decl_wants := []Decl_Want {
		{"engine.render", "Align"},
		{"engine.input", "Axis"},
		{"engine.input", "Button"},
	}
	for want in decl_wants {
		found := false
		for module in dump.modules {
			if module.path != want.path {
				continue
			}
			for decl in module.decls {
				if decl.name == want.name && decl.kind == .Type_Name {
					found = true
				}
			}
		}
		testing.expectf(t, found, "%s::%s appears as a Type_Name decl in the dump", want.path, want.name)
	}
}

@(test)
test_surface_dump_walks_the_index_tables :: proc(t: ^testing.T) {
	dump := build_surface_dump()

	testing.expect_value(t, len(dump.modules), len(STDLIB_SURFACE))
	for module, i in STDLIB_SURFACE {
		testing.expect_value(t, dump.modules[i].path, module.path)
		testing.expect_value(t, len(dump.modules[i].decls), len(module.decls))
		for decl, j in module.decls {
			testing.expect_value(t, dump.modules[i].decls[j].name, decl.name)
			testing.expect_value(t, dump.modules[i].decls[j].kind, decl.kind)
		}
	}

	testing.expect_value(t, len(dump.reexports), len(STDLIB_REEXPORTS))
	for row, i in STDLIB_REEXPORTS {
		testing.expect_value(t, dump.reexports[i].module, row.module)
		testing.expect_value(t, dump.reexports[i].name, row.name)
		testing.expect_value(t, dump.reexports[i].owner, row.owner)
	}
}

@(test)
test_surface_dump_probe_tables_type_live :: proc(t: ^testing.T) {
	for probe in SURFACE_DUMP_ENUM_PROBES {
		for variant in probe.variants {
			_, found := surface_enum_variant(probe.type_name, variant)
			testing.expectf(t, found, "enum probe %s::%s types live", probe.type_name, variant)
		}
	}
	for key in SURFACE_DUMP_STRUCT_PROBES {
		_, _, found := surface_struct_variant(key.type_name, key.variant)
		testing.expectf(t, found, "struct probe %s::%s types live", key.type_name, key.variant)
	}
	for key in SURFACE_DUMP_METHOD_PROBES {
		receiver := engine_type_of(key.kind, user_type_of("T", .Data)).(^Engine_Type)
		_, found := surface_engine_method(receiver, key.member)
		testing.expectf(t, found, "method probe %v.%s types live", key.kind, key.member)
	}
	for key in SURFACE_DUMP_STATIC_PROBES {
		_, found := surface_static_method(key.type_name, key.variant)
		testing.expectf(t, found, "static probe %s.%s types live", key.type_name, key.variant)
	}
	for key in SURFACE_DUMP_ASSOCIATED_PROBES {
		_, found := surface_associated(key.type_name, key.variant)
		testing.expectf(t, found, "associated probe %s.%s types live", key.type_name, key.variant)
	}
}

slice_has :: proc(haystack: []string, value: string) -> bool {
	for candidate in haystack {
		if candidate == value {
			return true
		}
	}
	return false
}
