package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

STDLIB_DEFAULT_DIR :: "stdlib/engine"

STDLIB_SURFACE_FILE_COUNT :: 22

STDLIB_PARSEABLE_FILE_COUNT :: 22

resolve_stdlib_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_STDLIB_DIR", STDLIB_DEFAULT_DIR)
}

expect_fmt_golden_tree :: proc(t: ^testing.T, src: string, label: string, env_name: string) {
	root, copied := copy_spec_tree_to_temp(src, label, env_name)
	if !copied {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict_before := stage_build(root, .Dev, context.temp_allocator)

	project, project_err, _ := read_project(root)
	testing.expect_value(t, project_err, Project_Error.None)
	if project_err != .None {
		return
	}
	paths := make([dynamic]string, 0, len(project.sources), context.temp_allocator)
	pre_asts := make([dynamic]Ast, 0, len(project.sources), context.temp_allocator)
	for source in project.sources {
		if strings.has_suffix(source.path, GEN_SUFFIX) {
			continue
		}
		bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		testing.expect(t, read_err == nil)
		if read_err != nil {
			return
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		testing.expect_value(t, parse_err, Parse_Error.None)
		if parse_err != .None {
			return
		}
		first := render_canonical(ast, context.temp_allocator)
		again, again_err := stage_parse(stage_lex(string(bytes)))
		testing.expect_value(t, again_err, Parse_Error.None)
		testing.expect_value(t, render_canonical(again, context.temp_allocator), first)
		append(&paths, source.path)
		append(&pre_asts, ast)
	}
	testing.expect(t, len(paths) > 0)

	testing.expect_value(t, fmt_verb_exit(root, .Write), 0)
	testing.expect_value(t, fmt_verb_exit(root, .Check), 0)

	for path, i in paths {
		formatted, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		testing.expect(t, read_err == nil)
		if read_err != nil {
			return
		}
		reparsed, reparse_err := stage_parse(stage_lex(string(formatted)))
		testing.expect_value(t, reparse_err, Parse_Error.None)
		if reparse_err != .None {
			return
		}
		testing.expect(t, ast_equiv(pre_asts[i], reparsed), "post-fmt AST differs from the pre-fmt parse")
	}

	_, verdict_after := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict_after.err, verdict_before.err)
	log.infof("golden fmt %s: %d authored sources canonicalize idempotently, re-parse equivalent, verdict arm unchanged (%v)", label, len(paths), verdict_before.err)
}

@(test)
test_golden_fmt_ten_example_idempotence_sweep :: proc(t: ^testing.T) {
	Sweep_Entry :: struct {
		dir:      string,
		label:    string,
		env_name: string,
	}
	entries := [?]Sweep_Entry {
		{resolve_arena_dir(), "fmt-arena", "FUNPACK_ARENA_DIR"},
		{resolve_assets_dir(), "fmt-assets", "FUNPACK_ASSETS_DIR"},
		{resolve_drift_dir(), "fmt-drift", "FUNPACK_DRIFT_DIR"},
		{resolve_hud_dir(), "fmt-hud", "FUNPACK_HUD_DIR"},
		{resolve_hunt_dir(), "fmt-hunt", "FUNPACK_HUNT_DIR"},
		{resolve_krognid_dir(), "fmt-krognid", "FUNPACK_KROGNID_DIR"},
		{resolve_golden_dir(), "fmt-numerics", "FUNPACK_NUMERICS_DIR"},
		{resolve_pong_dir(), "fmt-pong", "FUNPACK_PONG_DIR"},
		{resolve_snake_dir(), "fmt-snake", "FUNPACK_SNAKE_DIR"},
		{resolve_yard_dir(), "fmt-yard", "FUNPACK_YARD_DIR"},
	}
	for entry in entries {
		expect_fmt_golden_tree(t, entry.dir, entry.label, entry.env_name)
	}
}

@(test)
test_golden_fmt_stdlib_surface_sweep :: proc(t: ^testing.T) {
	dir := resolve_stdlib_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden fmt stdlib: %s not found — set FUNPACK_STDLIB_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	paths := make([dynamic]string, 0, STDLIB_SURFACE_FILE_COUNT, context.temp_allocator)
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, ".fun") {
			continue
		}
		append(&paths, strings.clone(info.fullpath, context.temp_allocator))
	}
	slice.sort(paths[:])
	testing.expect_value(t, len(paths), STDLIB_SURFACE_FILE_COUNT)

	formatted_count := 0
	for path in paths {
		bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		testing.expect(t, read_err == nil)
		if read_err != nil {
			continue
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		testing.expect_value(t, parse_err, Parse_Error.None)
		if parse_err != .None {
			log.errorf("golden fmt stdlib %s: %v — outside the parser-admitted §02 surface", filepath.base(path), parse_err)
			continue
		}
		canonical := render_canonical(ast, context.temp_allocator)
		reparsed, reparse_err := stage_parse(stage_lex(canonical))
		testing.expect_value(t, reparse_err, Parse_Error.None)
		if reparse_err != .None {
			continue
		}
		testing.expect(t, ast_equiv(ast, reparsed), "stdlib canonical form re-parses to a different AST")
		testing.expect_value(t, render_canonical(reparsed, context.temp_allocator), canonical)
		again, again_err := stage_parse(stage_lex(string(bytes)))
		testing.expect_value(t, again_err, Parse_Error.None)
		testing.expect_value(t, render_canonical(again, context.temp_allocator), canonical)
		formatted_count += 1
	}
	testing.expect_value(t, formatted_count, STDLIB_PARSEABLE_FILE_COUNT)
	log.infof("golden fmt stdlib: all %d of %d surface files are parser-admitted and fmt-idempotent — the sweep is total", formatted_count, len(paths))
}
