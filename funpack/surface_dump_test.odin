// The deliberate spec for the compiler-authoritative stdlib-surface dump
// (surface_dump.odin / `funpack introspect`). Three junctions are pinned: (1)
// DETERMINISM — the dump is byte-identical across two builds over the same source
// tree (the determinism floor the whole funpack pipeline holds, §29 §1); (2) the
// §26 RESTORE IS VISIBLE — the four §26-restored constructs (compare, View.count/
// at, the full Color palette, Color::Rgb) appear in the dump, so the dump would
// have made the regression that motivated it visible without a trial compile; and
// (3) PROBE-TABLE PARITY — every key the dump probes against the switch-keyed
// surfaces types LIVE (found = true), so a probe table that drifts from its switch
// is a loud failure here, never a silent omission.
package funpack

import "core:strings"
import "core:testing"

// test_surface_dump_is_byte_stable pins the determinism floor: two independent
// builds of the dump over the same (compile-time) surface tables produce
// byte-identical JSON. The dump walks only index-ordered slices (never a map), so
// any nondeterminism — a map iteration creeping in, an unordered probe — moves the
// bytes and fails here. This is the same double-emit determinism the artifact and
// Index Contract goldens hold.
@(test)
test_surface_dump_is_byte_stable :: proc(t: ^testing.T) {
	first := surface_dump_json(context.temp_allocator)
	second := surface_dump_json(context.temp_allocator)
	testing.expect(t, first == second, "the surface dump is byte-identical across two builds")
	testing.expect(t, len(first) > 0, "the dump is non-empty")
}

// test_surface_dump_carries_schema_version pins the self-describing envelope: the
// dump leads with its OWN schema_version (SURFACE_DUMP_SCHEMA_VERSION, distinct
// from INTROSPECT_SCHEMA_VERSION which the funpack↔MCP contract owns), so a
// consumer reads the dump's shape version from the artifact itself with no
// contract slot.
@(test)
test_surface_dump_carries_schema_version :: proc(t: ^testing.T) {
	dump := build_surface_dump()
	testing.expect_value(t, dump.schema_version, SURFACE_DUMP_SCHEMA_VERSION)

	json := surface_dump_json(context.temp_allocator)
	// schema_version is the FIRST key (field-declaration order is the marshal
	// order), so the JSON opens with it — the version --json envelope convention.
	testing.expect(
		t,
		strings.has_prefix(json, `{"schema_version":2`),
		"the dump JSON opens with its schema_version",
	)
}

// test_surface_dump_makes_the_restore_visible is the stdlib surface-parity restore
// proof (ADR stdlib-surface-source-of-truth-parity-restore): the dump INCLUDES
// the four §26-restored constructs, so an author/agent inspecting the dump would
// have seen the regression (a dropped palette entry, a missing Color::Rgb, a
// gone compare overload, a lost View.count) WITHOUT a trial compilation — the exact
// gap that made the restore necessary. Asserts over the structured dump, not the
// JSON text, so a field rename is caught by the struct, not a brittle substring.
@(test)
test_surface_dump_makes_the_restore_visible :: proc(t: ^testing.T) {
	dump := build_surface_dump()

	// (1) compare — the prelude three-way comparison, BOTH ordered-ground overloads.
	compare_found := false
	for sig in dump.signatures {
		if sig.name != "compare" {
			continue
		}
		compare_found = true
		testing.expect_value(t, len(sig.overloads), 2)
		testing.expect(t, slice_has(sig.overloads, "fn(Fixed, Fixed) -> Ordering"))
		testing.expect(t, slice_has(sig.overloads, "fn(Int, Int) -> Ordering"))
		// compare is a FIXED-signature free function — not call-site-inferred — so it
		// partitions to the false side of the marker the combinators carry.
		testing.expect(t, !sig.call_site_inferred, "compare is a fixed-signature function")
	}
	testing.expect(t, compare_found, "compare appears in the dumped signatures")

	// (2) View.count and View.at — the §08 read-table iteration surface.
	count_found, at_found := false, false
	for m in dump.engine_methods {
		if m.type_name == "View" && m.member == "count" {
			count_found = true
			testing.expect_value(t, m.signature, "fn(_) -> Int")
		}
		if m.type_name == "View" && m.member == "at" {
			at_found = true
			// at(i) reads the element T off a View[T]; the dump probes with a
			// structural Data stand-in named T, so the signature reads (Int) -> T.
			testing.expect_value(t, m.signature, "fn(Int) -> T")
		}
	}
	testing.expect(t, count_found, "View.count appears in the dumped engine methods")
	testing.expect(t, at_found, "View.at appears in the dumped engine methods")

	// (3) the full Color palette — the restored CMY trio among the closed set.
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

	// (4) Color::Rgb — the struct-payload escape variant, three Fixed channels.
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

// test_surface_dump_surfaces_call_site_inferred_combinators is the combinator-
// surfacing junction: a call-site-inferred combinator (engine.rand.pick and the
// engine.list [T]-combinators) appears in the dumped signatures WITH its canonical
// polymorphic signature AND a call_site_inferred = true marker — so an agent reading
// the dump sees pick's shape (fn(Rng, [T]) -> (Option[T], Rng)) next to its five
// fixed-signature rand siblings and CANNOT mistake it for a broken/unsigned function.
// Asserts over the structured dump, so a field rename is caught by the struct. This
// is the living-spec junction for the combinator surfacing — it pins both the marker
// partition and the canonical spelling.
@(test)
test_surface_dump_surfaces_call_site_inferred_combinators :: proc(t: ^testing.T) {
	dump := build_surface_dump()

	// (1) engine.rand.pick — the combinator most easily misread as broken next to its
	// fixed siblings — is surfaced with its canonical self-first signature and the marker.
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

	// (2) at least one list combinator (map AND fold) is surfaced with its canonical
	// signature and the marker — the same partition pick rides.
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

// test_surface_dump_combinator_probe_completeness is the drift gate on the combinator
// probe table — the twin of test_surface_dump_probe_tables_type_live for the
// call-site-inferred free combinators. It asserts the bidirectional closure: every
// SURFACE_DUMP_COMBINATOR_SIGS name (a) is a real `.Func` decl somewhere in
// STDLIB_SURFACE and (b) is one surface_signatures REJECTS (found = false), so the
// table holds only genuine call-site-inferred combinators, never a phantom or a
// fixed-signature function mislabeled; and conversely that EVERY name
// combinator_call_check types is covered here, so a new combinator added to that
// switch cannot silently fall out of the dump.
@(test)
test_surface_dump_combinator_probe_completeness :: proc(t: ^testing.T) {
	// (a) every probe name is a live `.Func` decl that surface_signatures rejects.
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

	// (b) every name combinator_call_check types is covered by the probe table — so
	// the dump cannot silently drop a combinator the checker recognizes.
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

// COMBINATOR_CHECK_NAMES mirrors combinator_call_check's switch arms — the closed set
// of call-site-inferred free combinators the checker types. Pinned here so the
// completeness gate above asserts the dump's combinator probe table covers every one;
// a combinator added to combinator_call_check without a matching probe row fails the
// gate (and is a visible gap here, the same drift discipline the switch-mirroring
// probe tables follow).
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

// test_surface_dump_lists_the_variant_readmit is the mechanical variant-re-admit
// proof (story mechanical-variant-readmit): the dump projects the FULL restored
// closed sets (PlayerId P1-P4, Bone/Slot with their extremities + generic joints/
// slots) and the §20 Align enum's variant set — the same shape the Color palette
// restore takes — so the introspect dump an author/agent inspects shows every
// re-admitted variant without a trial compile, and the .fun parity gate compares
// against ground truth. Asserts over the structured dump (a field rename is caught
// by the struct, not a brittle substring).
@(test)
test_surface_dump_lists_the_variant_readmit :: proc(t: ^testing.T) {
	dump := build_surface_dump()

	// (1) the re-admitted closed enum sets appear with their full restored variants.
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

	// (2) Align (render) and Axis/Button (input) appear as engine TYPE decls — the
	// type-position projection the parity gate reads, distinct from a variant set.
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

// test_surface_dump_walks_the_index_tables pins that the index-walkable rodata is
// projected faithfully: the dumped module set IS STDLIB_SURFACE (same count, same
// paths in order) and the reexports ARE STDLIB_REEXPORTS — the dump is generated
// FROM the single source, never a hand-kept mirror. A module added to or removed
// from STDLIB_SURFACE moves these counts, so the dump can never silently lag the
// table it projects.
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

// test_surface_dump_probe_tables_type_live is the drift gate on the co-located
// probe tables: every key the dump probes against the switch-keyed surfaces must
// type LIVE (the same switch `funpack check` runs). A probe table arm that drifts
// from its switch — a variant the switch dropped, a method renamed — fails here, so
// the dump's projection can never silently diverge from what the checker enforces.
// This is the deliberate seam guard the probe-table design rests on (the
// drift-IMPOSSIBLE alternative — delegating the switches to the tables — is a
// surface.odin refactor left to a follow-up).
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

// slice_has reports whether a string slice contains value — the small linear scan
// the dump-content assertions read membership through (the dumped overload/variant
// lists are tiny, order is the table's, so a scan keeps the test legible).
slice_has :: proc(haystack: []string, value: string) -> bool {
	for candidate in haystack {
		if candidate == value {
			return true
		}
	}
	return false
}
