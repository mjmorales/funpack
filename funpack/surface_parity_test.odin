// The deliberate spec for the surface-parity gate (surface_parity.odin) —
// re-homed from the deleted Go MCP module's surface_parity_test.go into the
// funpack compiler package that owns the live dump (surface_dump_test.odin sits
// beside this) and reads the stdlib/engine/*.fun signature files from disk
// (golden_fmt_test.odin). Five junctions are pinned:
//
//  1. THE GATE PROPER — against the current (restored, in-parity) surface, the
//     .fun signature files advertise no surface the LIVE build_surface_dump()
//     lacks beyond the audited RESIDUAL_OVER_DECLARES allow-list. This is the
//     content-level check the version-string corpus-pin detector cannot be.
//  2. THE NEGATIVE CONTROL — an injected same-version divergence (a documented
//     enum/struct variant or module type the dump rejects, not on the allow-list)
//     is DETECTED, NAMED with .Docs_Ahead_Of_Compiler + the .fun source, and
//     surfaced in the failure message — proving the gate is a real detector.
//  3. NO STALE ALLOW-LIST — every RESIDUAL_OVER_DECLARES entry still corresponds
//     to a live docs-ahead divergence, so a restored symbol forces its entry's
//     removal (the allow-list shrinks toward empty as the tracker task drains).
//  4. MODELS NON-EMPTY — a silently-empty model (a parser regression) reading as
//     falsely-in-parity is guarded; the canonical Color palette must be present in
//     BOTH the compiler and .fun models.
//  5. EXCLUDED-SURFACE DOCUMENTED — every EXCLUDED_SURFACE axis carries a WHY, so
//     an exclusion can never silently become a coverage hole.
//
// Unlike the Go path the gate runs INSIDE the toolchain off the in-memory dump:
// no fixture, no temp build, no introspect subprocess. The .fun arm reads
// stdlib/engine/*.fun via resolve_stdlib_dir(); an absent tree SKIPs loudly (the
// golden_fmt_test.odin discipline), keeping the suite hermetic in a bare checkout.
package funpack

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// load_fun_sources reads the stdlib/engine/*.fun signature files into Fun_Source
// records keyed by their engine.<module> path (input.fun -> engine.input), in
// sorted filename order for determinism. ok = false (with a loud warn) when the
// tree is absent, so a checkout without the fixture SKIPs rather than yielding an
// empty (falsely-in-parity) model. Mirrors the Go LoadFunSources + the
// golden_fmt_test.odin resolve/SKIP protocol. Allocated on alloc.
load_fun_sources :: proc(alloc := context.allocator) -> (sources: []Fun_Source, ok: bool) {
	dir := resolve_stdlib_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP surface-parity .fun arm: %s not found — set FUNPACK_STDLIB_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return nil, false
	}
	paths := make([dynamic]string, 0, STDLIB_SURFACE_FILE_COUNT, alloc)
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, ".fun") {
			continue
		}
		append(&paths, strings.clone(info.fullpath, alloc))
	}
	slice.sort(paths[:])

	out := make([dynamic]Fun_Source, 0, len(paths), alloc)
	for path in paths {
		bytes, read_err := os.read_entire_file_from_path(path, alloc)
		if read_err != nil {
			log.errorf("surface-parity: read %s failed: %v", path, read_err)
			continue
		}
		// module = "engine." + the .fun file stem.
		base := path[strings.last_index_byte(path, '/') + 1:]
		stem := strings.trim_suffix(base, ".fun")
		append(&out, Fun_Source{module = strings.concatenate({"engine.", stem}, alloc), text = string(bytes)})
	}
	return out[:], true
}

// test_surface_parity_gate is the gate proper: against the CURRENT (restored,
// in-parity) surface, the .fun signature files advertise no surface the LIVE
// build_surface_dump() lacks BEYOND the audited RESIDUAL_OVER_DECLARES allow-list.
// A fresh same-version surface divergence — a .fun symbol the compiler rejects,
// not on the allow-list — fails here, named. This is the check the version-string
// corpus-pin detector cannot be.
@(test)
test_surface_parity_gate :: proc(t: ^testing.T) {
	sources, ok := load_fun_sources(context.temp_allocator)
	if !ok {
		return // absent fixture tree — SKIP loudly (already warned).
	}
	fun := parse_fun_model(sources, context.temp_allocator)
	compiler := compiler_model_from_dump(build_surface_dump(), context.temp_allocator)

	blocking := blocking_findings(fun, compiler, context.temp_allocator)
	if len(blocking) > 0 {
		testing.expectf(t, false, "%s", format_blocking_findings(blocking, context.temp_allocator))
	}
}

// test_surface_parity_detects_synthetic_divergence is the negative control proving
// the gate is a real DETECTOR, not a no-op: it injects a same-version surface
// divergence into a FRESH-PARSED copy of the .fun model — a documented symbol the
// compiler dump does not admit — and asserts the gate (a) FAILS and (b) NAMES the
// injected symbol with the harmful direction, source, and kind. This is the exact
// shape of the canonical break (a documented Color-palette member the compiler
// rejects). Three sub-cases span the three doc-ahead granularities.
@(test)
test_surface_parity_detects_synthetic_divergence :: proc(t: ^testing.T) {
	sources, ok := load_fun_sources(context.temp_allocator)
	if !ok {
		return
	}
	compiler := compiler_model_from_dump(build_surface_dump(), context.temp_allocator)

	Injection :: enum {
		Enum_Variant, // Color::Chartreuse — a palette member the compiler lacks.
		Struct_Variant, // Draw::Hologram — a struct-payload variant on a known type.
		Module_Type, // engine.render::Hologram — a type the compiler does not know.
	}
	Case :: struct {
		name:   string,
		inject: Injection,
		symbol: string,
		kind:   Parity_Kind,
	}
	cases := []Case {
		{
			"documented enum variant the compiler lacks (the Color-palette shape)",
			.Enum_Variant,
			"Color::Chartreuse",
			.Enum_Variant,
		},
		{"documented struct variant the compiler lacks", .Struct_Variant, "Draw::Hologram", .Struct_Variant},
		{"documented module type the compiler lacks", .Module_Type, "engine.render::Hologram", .Module_Type},
	}

	for tc in cases {
		// Fresh-parse the .fun model each case so the synthetic symbol is the ONLY
		// new divergence and the real residuals stay allow-listed (the deep-clone the
		// Go cloneModel gave; parse_fun_model builds independent maps each call).
		mutated := parse_fun_model(sources, context.temp_allocator)
		switch tc.inject {
		case .Enum_Variant:
			add_to_set(&mutated.enum_bare_variants, "Color", "Chartreuse", context.temp_allocator)
		case .Struct_Variant:
			add_to_set(&mutated.struct_variants, "Draw", "Hologram", context.temp_allocator)
		case .Module_Type:
			add_to_set(&mutated.module_types, "engine.render", "Hologram", context.temp_allocator)
		}

		blocking := blocking_findings(mutated, compiler, context.temp_allocator)
		if len(blocking) == 0 {
			testing.expectf(t, false, "[%s] synthetic divergence %q was NOT detected — the gate is a no-op", tc.name, tc.symbol)
			continue
		}
		found: Maybe(Finding)
		for f in blocking {
			if f.symbol == tc.symbol {
				found = f
				break
			}
		}
		fv, named := found.?
		if !named {
			testing.expectf(t, false, "[%s] gate fired but did not name %q", tc.name, tc.symbol)
			continue
		}
		testing.expect_value(t, fv.kind, tc.kind)
		testing.expect_value(t, fv.direction, Direction.Docs_Ahead_Of_Compiler)
		testing.expect_value(t, fv.source, ".fun")

		msg := format_blocking_findings(blocking, context.temp_allocator)
		testing.expectf(t, strings.contains(msg, tc.symbol), "[%s] failure message does not name %q:\n%s", tc.name, tc.symbol, msg)
		testing.expectf(t, strings.contains(msg, "compiler dump"), "[%s] failure message lacks the compiler-dump framing:\n%s", tc.name, msg)
	}
}

// test_no_stale_residual_allow_list_entry asserts every RESIDUAL_OVER_DECLARES
// entry corresponds to a divergence that ACTUALLY occurs against the current LIVE
// dump. A stale entry — one whose symbol the compiler now admits, or whose name
// drifted — would silently suppress a finding it no longer matches, masking a real
// future divergence. So when a restore lands and the dump grows, the matching
// entry MUST be removed or this fails. This is the mechanism that forces the
// allow-list to SHRINK toward empty as the residual tracker task is drained.
@(test)
test_no_stale_residual_allow_list_entry :: proc(t: ^testing.T) {
	sources, ok := load_fun_sources(context.temp_allocator)
	if !ok {
		return
	}
	fun := parse_fun_model(sources, context.temp_allocator)
	compiler := compiler_model_from_dump(build_surface_dump(), context.temp_allocator)

	// Collect the actual docs-ahead findings from the .fun source.
	doc_ahead := make(map[Residual_Key]bool, context.temp_allocator)
	for f in diff_surfaces(fun, compiler, ".fun", context.temp_allocator) {
		if f.direction == .Docs_Ahead_Of_Compiler {
			doc_ahead[Residual_Key{f.kind, f.symbol}] = true
		}
	}

	for r in RESIDUAL_OVER_DECLARES {
		live := Residual_Key{r.kind, r.symbol} in doc_ahead
		testing.expectf(
			t,
			live,
			"stale allow-list entry: {%s %q} no longer corresponds to a divergence — the compiler dump now admits it (or the symbol name drifted). Remove it from RESIDUAL_OVER_DECLARES (tracker %s).",
			parity_kind_label(r.kind),
			r.symbol,
			RESIDUAL_TRACKER_TASK,
		)
	}
}

// test_surface_parity_models_non_empty guards against a silently-empty model (a
// parser regression or a missing source) reading as falsely in-parity: an empty
// doc or compiler model would make every diff vacuous. Asserts each source yields
// a non-trivial surface, and that the canonical Color palette (the §26-restore
// proof: 5 named members + the Rgb struct payload) is present in BOTH models.
@(test)
test_surface_parity_models_non_empty :: proc(t: ^testing.T) {
	sources, ok := load_fun_sources(context.temp_allocator)
	if !ok {
		return
	}
	fun := parse_fun_model(sources, context.temp_allocator)
	compiler := compiler_model_from_dump(build_surface_dump(), context.temp_allocator)

	Named_Model :: struct {
		name: string,
		m:    Surface_Model,
	}
	models := []Named_Model{{"compiler", compiler}, {".fun", fun}}
	for nm in models {
		testing.expectf(t, len(nm.m.module_types) > 0, "%s model has zero module types — likely a source/parser regression", nm.name)
		testing.expectf(t, len(nm.m.enum_bare_variants) > 0, "%s model has zero enum variant sets — likely a source/parser regression", nm.name)

		colors := nm.m.enum_bare_variants["Color"]
		palette := []string{"White", "Yellow", "Cyan", "Magenta", "Gray"}
		for named in palette {
			testing.expectf(t, named in colors, "%s model is missing Color::%s — the palette restore regressed or the parser missed it", nm.name, named)
		}
		rgb := nm.m.struct_variants["Color"]
		testing.expectf(t, "Rgb" in rgb, "%s model is missing the Color::Rgb struct payload", nm.name)
	}
}

// test_excluded_surface_documented guards the audited exclusion list: every
// comparison axis the gate deliberately skips must carry a non-empty WHY, so an
// exclusion can never silently become a coverage hole (and the list stays
// referenced, not dead).
@(test)
test_excluded_surface_documented :: proc(t: ^testing.T) {
	testing.expect(t, len(EXCLUDED_SURFACE) > 0, "EXCLUDED_SURFACE is empty — the gate's intentional exclusions must stay documented and auditable")
	for why, i in EXCLUDED_SURFACE {
		testing.expectf(t, strings.trim_space(why) != "", "EXCLUDED_SURFACE[%d] has an empty WHY — every exclusion must state its reason", i)
	}
}
