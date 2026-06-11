// The fmt idempotence golden sweep — the canonical-formatter epic's
// surface-done proof across ALL TEN funpack-spec example trees plus the
// stdlib surface files. Per tree (on a temp copy, the committed checkout
// untouched): fmt writes exit 0, the written tree is canonical (`--check`
// exits 0 — on-disk idempotence), every formatted source re-parses to an AST
// equivalent to its pre-fmt parse (ast_equiv, modulo line spans), the
// canonical projection is byte-deterministic across two independent
// parse+render passes (the warden six-command double-acquisition discipline),
// and formatting NEVER changes `funpack check`'s verdict — the stage_build
// Build_Error arm is compared before/after, so a tree that refuses keeps
// refusing with the same arm and a clean tree stays clean. Every tree
// resolves through the resolve_spec_dir env-override/SKIP-warn protocol — a
// skipped golden warns loudly, never silently passes.
//
// The stdlib sweep covers the PARSEABLE subset of stdlib/engine/*.fun and
// pins both counts exactly (the golden-count discipline: when the spec or the
// grammar evolves, the pins change in lockstep — never loosened to ranges).
// The non-parsing files are a KNOWN frontend grammar gap — generic
// declaration headers (`enum Option[T]`, `data Ref[T]`, `extern type View[T]`)
// and function-typed parameters (`pred: fn(T) -> Bool`) are §02 §7 / §03 §3
// surface the parser does not yet admit (the bare `extern type Name` form IS
// admitted) — each SKIP names its file loudly; admitting them is a parser
// story, not a formatter workaround.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

// STDLIB_DEFAULT_DIR is the stdlib surface tree in the funpack-spec sibling
// checkout, resolved like every golden (FUNPACK_STDLIB_DIR overrides).
STDLIB_DEFAULT_DIR :: "../funpack-spec/stdlib/engine"

// STDLIB_SURFACE_FILE_COUNT pins the stdlib/engine/*.fun file count; a new
// or removed surface file moves this pin in lockstep.
STDLIB_SURFACE_FILE_COUNT :: 22

// STDLIB_PARSEABLE_FILE_COUNT pins how many stdlib surface files the §02
// grammar currently admits (and the sweep therefore proves fmt-idempotent).
// The remainder use generic declaration headers or function-typed parameters
// — the named grammar gap (`extern type Name` admission lifted the pin from 6
// to 12). When the parser grows that surface, this pin rises in lockstep.
STDLIB_PARSEABLE_FILE_COUNT :: 12

// resolve_stdlib_dir resolves the stdlib surface tree (env override, else
// the sibling checkout), mirroring the per-example resolvers.
resolve_stdlib_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_STDLIB_DIR", STDLIB_DEFAULT_DIR)
}

// expect_fmt_golden_tree runs the whole fmt golden contract over one live
// example tree: copy to temp, record the pre-fmt parse of every authored
// source and the stage_build verdict, prove the canonical projection
// byte-deterministic across two independent parse+render passes, fmt-write
// (exit 0), prove the written tree canonical (`--check` exit 0), re-parse
// every formatted source to an equivalent AST, and prove the post-fmt
// stage_build verdict arm unchanged. ok = false on the golden SKIP.
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
		// Byte-determinism: a second independent parse+render pass of the same
		// bytes projects identically (the double-acquisition discipline).
		first := render_canonical(ast, context.temp_allocator)
		again, again_err := stage_parse(stage_lex(string(bytes)))
		testing.expect_value(t, again_err, Parse_Error.None)
		testing.expect_value(t, render_canonical(again, context.temp_allocator), first)
		append(&paths, source.path)
		append(&pre_asts, ast)
	}
	testing.expect(t, len(paths) > 0)

	testing.expect_value(t, fmt_verb_exit(root, .Write), 0)
	// On-disk idempotence: the written tree is already canonical.
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
	// All ten committed spec examples through the full fmt golden contract.
	// Each entry SKIPs independently (loudly) when its checkout is absent.
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
	// The stdlib surface files, swept per-file (they are bare modules, not §14
	// trees): every file the grammar admits must render canonically such that
	// the rendering re-parses to an equivalent AST, renders idempotently, and
	// projects byte-identically across two independent passes. Both the total
	// and the parseable count are pinned exactly; a non-parsing file is the
	// named grammar gap, SKIP-logged per file, never silent.
	dir := resolve_stdlib_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden fmt stdlib: %s not found — set FUNPACK_STDLIB_DIR or check out funpack-spec as a sibling", dir)
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
		if parse_err != .None {
			// The named grammar gap: generic declaration headers and
			// function-typed parameters (spec §02 §7 / §03 §3 surface the parser
			// does not yet admit). Loud per-file, counted by the pin below.
			log.warnf("SKIP golden fmt stdlib %s: %v — outside the parser-admitted §02 surface", filepath.base(path), parse_err)
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
		// Byte-determinism: an independent second parse+render pass projects
		// the same bytes.
		again, again_err := stage_parse(stage_lex(string(bytes)))
		testing.expect_value(t, again_err, Parse_Error.None)
		testing.expect_value(t, render_canonical(again, context.temp_allocator), canonical)
		formatted_count += 1
	}
	testing.expect_value(t, formatted_count, STDLIB_PARSEABLE_FILE_COUNT)
	log.infof("golden fmt stdlib: %d of %d surface files are parser-admitted and fmt-idempotent; the remainder are the named generic-header/fn-typed-param grammar gap", formatted_count, len(paths))
}
