package funpack

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

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
		base := path[strings.last_index_byte(path, '/') + 1:]
		stem := strings.trim_suffix(base, ".fun")
		append(&out, Fun_Source{module = strings.concatenate({"engine.", stem}, alloc), text = string(bytes)})
	}
	return out[:], true
}

@(test)
test_surface_parity_gate :: proc(t: ^testing.T) {
	sources, ok := load_fun_sources(context.temp_allocator)
	if !ok {
		return
	}
	fun := parse_fun_model(sources, context.temp_allocator)
	compiler := compiler_model_from_dump(build_surface_dump(), context.temp_allocator)

	blocking := blocking_findings(fun, compiler, context.temp_allocator)
	if len(blocking) > 0 {
		testing.expectf(t, false, "%s", format_blocking_findings(blocking, context.temp_allocator))
	}
}

@(test)
test_surface_parity_detects_synthetic_divergence :: proc(t: ^testing.T) {
	sources, ok := load_fun_sources(context.temp_allocator)
	if !ok {
		return
	}
	compiler := compiler_model_from_dump(build_surface_dump(), context.temp_allocator)

	Injection :: enum {
		Enum_Variant,
		Struct_Variant,
		Module_Type,
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

@(test)
test_no_stale_residual_allow_list_entry :: proc(t: ^testing.T) {
	sources, ok := load_fun_sources(context.temp_allocator)
	if !ok {
		return
	}
	fun := parse_fun_model(sources, context.temp_allocator)
	compiler := compiler_model_from_dump(build_surface_dump(), context.temp_allocator)

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

@(test)
test_excluded_surface_documented :: proc(t: ^testing.T) {
	testing.expect(t, len(EXCLUDED_SURFACE) > 0, "EXCLUDED_SURFACE is empty — the gate's intentional exclusions must stay documented and auditable")
	for why, i in EXCLUDED_SURFACE {
		testing.expectf(t, strings.trim_space(why) != "", "EXCLUDED_SURFACE[%d] has an empty WHY — every exclusion must state its reason", i)
	}
}
