// The §17 cross-epic arena golden: the live arena example tree
// (funpack-spec/examples/arena) is the leaf that closes the levels-bake pipeline
// end-to-end. It proves three things against the real committed sources, never a
// hand-built stand-in:
//   1. BYTE MATCH — a fresh bake of levels/arena.flvl, projected onto the shared
//      .gen.fun Seam (flvl_emit.odin) and emitted (gen_emit.odin), reproduces the
//      committed gen/arena.gen.fun byte-for-byte (the ArenaTurret per-prefab
//      record, the Arena symbol table with name-derived stable ids, the two
//      extern-fn accessors with the prefab + pillar-loop expanded in declaration
//      order). EXACT match, never a range.
//   2. PROJECT TYPECHECKS — read_project merges src/ + the committed gen/ seam,
//      builds the project-wide module index, and every module (arena_world schema,
//      the arena seam, arena_game behaviors) types and clears the compile pipeline
//      end-to-end through flatten/closure. This is the multi-module path the
//      single-source pipeline could not reach.
//   3. INLINE TESTS — arena_game's inline asserts in the FUNPACK EVALUATOR's
//      domain pass. SCOPE (the yard golden's contract, golden_yard_test.odin): the
//      arena asserts that touch ENGINE-VALUE execution (View.resolve/.ref/.of,
//      Nav.of/.path/.advance, cross-module record construction) are the RUNTIME's,
//      not the funpack evaluator's — so this golden pins compile-pipeline clearance
//      + the evaluable asserts, the same split yard draws between funpack-evaluable
//      and runtime-owned assertions.
//
// All three resolve the sibling funpack-spec checkout (or FUNPACK_ARENA_DIR via
// resolve_arena_dir) and SKIP LOUDLY when it is absent — a skipped golden is a
// warning, NEVER a pass.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// ARENA_FILE_DOC / ARENA_PREFAB_DOC / ARENA_SYMBOLS_DOC / ARENA_SPAWNS_DOC /
// ARENA_ACCESSOR_DOC are the committed seam's authored @doc strings, carried
// verbatim from funpack-spec/examples/arena/gen/arena.gen.fun. They are bake
// metadata (the seam's prose is not derivable from the bake alone — the same
// pass-through contract the krognid rig golden uses for its digest docs), so a
// faithful bake stamps them onto the projected Seam. The em-dash in
// ARENA_SYMBOLS_DOC is the exemplar's literal UTF-8 em-dash, kept verbatim so the
// byte comparison exercises multibyte content.
ARENA_FILE_DOC :: "Generated seam for levels/arena.flvl: typed references to the level's named instances and the deterministic spawn list, baked from the flat-text level. Imports the schema module only. Edit the level, not this file."
ARENA_PREFAB_DOC :: "A placed Turret prefab instance: typed references to its expanded members. Generated from the prefab in arena.flvl."
ARENA_SYMBOLS_DOC :: "Typed references to the Arena level's named instances. Ids are derived from the level-qualified names, so these are stable across loads, saves, and replays. Generated from arena.flvl — edit the level, not this file."
ARENA_SPAWNS_DOC :: "The deterministic spawn list for Arena, in declaration order (the prefab and the pillar loop expanded in place). Backed by arena.flvl."
ARENA_ACCESSOR_DOC :: "The Arena symbol table, valid once the level is loaded."

// arena_seam_docs assembles the committed seam's authored docs into the projection
// metadata the fresh bake stamps onto its Seam.
arena_seam_docs :: proc() -> Level_Seam_Docs {
	return Level_Seam_Docs {
		file     = ARENA_FILE_DOC,
		prefab   = ARENA_PREFAB_DOC,
		symbols  = ARENA_SYMBOLS_DOC,
		spawns   = ARENA_SPAWNS_DOC,
		accessor = ARENA_ACCESSOR_DOC,
	}
}

// arena_fresh_bake bakes the live levels/arena.flvl against the live
// arena_world.fun schema and projects the result onto the shared .gen.fun Seam —
// the deterministic "fresh bake" whose bytes the committed gen/arena.gen.fun must
// equal. It asserts the level parses, the schema parses, and the bake clears every
// §17.4 gate (a malformed source or a gate-tripping level is not a bakeable seam),
// then projects with the committed seam's authored docs. ok = false (with a loud
// SKIP) when the sibling checkout is absent or a source cannot be read.
arena_fresh_bake :: proc(t: ^testing.T, allocator := context.allocator) -> (seam: Seam, ok: bool) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden arena: %s not found — set FUNPACK_ARENA_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return Seam{}, false
	}
	level_path := filepath.join({dir, "levels", "arena.flvl"}, context.temp_allocator) or_else ""
	schema_path := filepath.join({dir, "src", "arena_world.fun"}, context.temp_allocator) or_else ""
	level_bytes, level_read := os.read_entire_file_from_path(level_path, context.temp_allocator)
	schema_bytes, schema_read := os.read_entire_file_from_path(schema_path, context.temp_allocator)
	if level_read != nil || schema_read != nil {
		log.warnf("SKIP golden arena: cannot read arena.flvl / arena_world.fun under %s", dir)
		return Seam{}, false
	}

	level, level_parse := parse_flvl(string(level_bytes))
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	schema_ast, schema_parse := stage_parse(stage_lex(string(schema_bytes)))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	if level_parse != .None || schema_parse != .None {
		return Seam{}, false
	}

	index := build_module_index_from_asts({"arena_world"}, {schema_ast})
	baked, bake_err := bake_flvl(level, schema_ast, "arena_world", index)
	testing.expect_value(t, bake_err, Bake_Error.None)
	if bake_err != .None {
		return Seam{}, false
	}
	return level_seam_of_baked(baked, schema_ast, arena_seam_docs(), allocator), true
}

// test_golden_arena_gen_fun_byte_matches is the load-bearing byte contract: a
// fresh bake of levels/arena.flvl, projected and emitted through the shared
// emitter, reproduces the committed gen/arena.gen.fun byte-for-byte. A diff in any
// byte — a doc character (the multibyte em-dash), an import member, a field
// alignment space, a Ref[Type] token, the trailing newline — fails here. The
// committed path is found through the §14.4 capability reader (levels/arena.flvl ⇒
// gen/arena.gen.fun), driving the SAME reader the bake pipeline uses. SKIPs loudly
// when the sibling is absent (a skipped golden is not a pass).
@(test)
test_golden_arena_gen_fun_byte_matches :: proc(t: ^testing.T) {
	committed_path, path_ok := arena_committed_seam_path(t)
	if !path_ok {
		return
	}
	seam, bake_ok := arena_fresh_bake(t, context.temp_allocator)
	if !bake_ok {
		return
	}
	emitted := emit_gen_fun(seam, context.temp_allocator)

	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP golden arena: committed seam %s unreadable", committed_path)
		return
	}
	committed := string(committed_bytes)

	testing.expect_value(t, len(emitted), len(committed))
	testing.expect(t, emitted == committed)
	if emitted != committed {
		report_first_byte_diff(emitted, committed)
		return
	}
	// odin test echoes a name only on failure; announce the byte match so a passing
	// run leaves a trace the acceptance gate can read.
	log.infof("golden arena: freshly-baked levels/arena.flvl reproduces gen/arena.gen.fun byte-for-byte (%d bytes)", len(emitted))
}

// test_golden_arena_double_bake_identical proves the bake → project → emit chain
// is deterministic (spec §09, §29): two fresh bakes of the same source emit
// byte-identical bytes, so the seam carries no field whose value depends on when,
// where, or on which machine it was baked. SKIPs loudly when the sibling is absent.
@(test)
test_golden_arena_double_bake_identical :: proc(t: ^testing.T) {
	first, ok1 := arena_fresh_bake(t, context.temp_allocator)
	if !ok1 {
		return
	}
	second, ok2 := arena_fresh_bake(t, context.temp_allocator)
	if !ok2 {
		return
	}
	first_bytes := emit_gen_fun(first, context.temp_allocator)
	second_bytes := emit_gen_fun(second, context.temp_allocator)
	testing.expect(t, first_bytes == second_bytes)
	testing.expect_value(t, len(first_bytes), len(second_bytes))
	if first_bytes == second_bytes {
		log.infof("golden arena: two arena.flvl bakes are byte-identical (deterministic bake+emit, %d bytes)", len(first_bytes))
	}
}

// test_golden_arena_seam_compare_none drives the shared seam-compare harness over
// the LIVE arena bake: the freshly-baked-and-emitted bytes equal the committed
// gen/arena.gen.fun, so compare_seam returns None (the committed seam is current).
// A non-None verdict here is an exit-2-class build error (a stale committed seam),
// never a counted test failure. SKIPs loudly when the sibling is absent.
@(test)
test_golden_arena_seam_compare_none :: proc(t: ^testing.T) {
	committed_path, path_ok := arena_committed_seam_path(t)
	if !path_ok {
		return
	}
	seam, bake_ok := arena_fresh_bake(t, context.temp_allocator)
	if !bake_ok {
		return
	}
	emitted := emit_gen_fun(seam, context.temp_allocator)
	result := compare_seam(emitted, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.None)
	if result != .None {
		committed_bytes, cerr := os.read_entire_file_from_path(committed_path, context.temp_allocator)
		if cerr == nil {
			report_first_byte_diff(emitted, string(committed_bytes))
		}
	}
}

// test_golden_arena_project_typechecks is the multi-module acceptance: reading the
// live arena tree merges src/ + the committed gen/ seam into one source set, builds
// the project-wide module index, and every module — arena_world (schema), the
// arena seam (gen/arena.gen.fun), and arena_game (behaviors) — types and clears
// the compile pipeline end-to-end (no compile error). This is the path the
// single-source pipeline could not reach: arena_game imports BOTH arena_world and
// the seam, so it resolves cross-module types, fields, and the seam's extern-fn
// signatures through the index. A compile error in ANY module is the §29 §3 exit-2
// class (module_err set), never a counted assertion failure. SKIPs loudly when the
// sibling is absent.
@(test)
test_golden_arena_project_typechecks :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden arena: %s not found — set FUNPACK_ARENA_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	// The combined source set carries the three arena modules: the schema, the
	// generated seam, and the behavior module — the multi-module project the index
	// types together.
	_, has_world := find_source_module(project.sources, "arena_world")
	_, has_seam := find_source_module(project.sources, "arena")
	_, has_game := find_source_module(project.sources, "arena_game")
	testing.expect(t, has_world)
	testing.expect(t, has_seam)
	testing.expect(t, has_game)

	report := run_project_pipeline(project.sources)
	// The whole project compiles end-to-end: the index built (no read/parse
	// failure) and every module cleared parse → gates → typecheck → contracts →
	// flatten/closure (no compile error). A compile error fails THIS acceptance.
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden arena: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}
	log.infof("golden arena: the full arena project (arena_world + arena seam + arena_game) types and clears the compile pipeline end-to-end")
}

// test_golden_arena_inline_tests_pass pins the arena project's inline asserts that
// lie in the FUNPACK EVALUATOR's domain. SCOPE (the yard golden's contract): the
// arena asserts that touch ENGINE-VALUE execution — View.of/.resolve/.ref and
// Nav.of/.path/.advance — are the RUNTIME's to execute, not the funpack
// evaluator's, so they are NOT counted here (mirroring how the yard golden pins
// compile-clearance + emission, not full inline-assertion evaluation). What IS
// pinned: the project compiles clean end-to-end, and the funpack-evaluable arena
// asserts evaluate to their golden values — the pure-numeric step_to snap, the
// Option::None gate-shut case, AND the two gate_open(Some(Switch{…})) cases whose
// CROSS-MODULE record construction the evaluator now materializes (the hud
// integration's cross-module-record eval arm lifted these from runtime-owned to
// funpack-evaluable, so the boundary moved and this pin moves with it). A
// regression that drops a funpack-evaluable assert, or that lets a compile error
// through, fails here. SKIPs loudly when the sibling is absent.
@(test)
test_golden_arena_inline_tests_pass :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden arena: %s not found — set FUNPACK_ARENA_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	report := run_project_pipeline(project.sources)
	// The project must COMPILE clean — an inline assert can only run once its
	// module types and clears the pipeline (a compile error is exit-2, never a
	// counted assertion).
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		return
	}

	// The funpack-evaluable arena asserts pass — ALL EIGHT, end-to-end. arena_game
	// carries the pure-numeric `step_to` snap, the `gate_open(Option::None) ==
	// false` shut case, the two `gate_open(Option::Some(Switch{…}))` cases (true
	// while on, false while off) whose CROSS-MODULE Switch record construction the
	// evaluator materializes via the hud integration's eval_module_record arm, the
	// two `nearest_player` cases (eval_or_else makes the fold-then-or_else default
	// shape funpack-evaluable end-to-end), the `chase advances` case (the Nav_Value
	// funpack-eval arm runs the whole AI fold, its `step_to` landing `(delta *
	// speed) / d` through the Vec2/Fixed div kernel — `((10,0) * 0.8) / 10 == (0.8,
	// 0)`, exact), AND the `gate_logic resolves its switch and opens` case: the §08
	// View reference surface (View.ref(i)/View.resolve(ref)) is now funpack-evaluable
	// over a materialized View, so `gate_logic.step(door, switches).open == true`
	// runs in the evaluator and the 7 → 8 move follows the same boundary-shift
	// lockstep that lifted Nav.of/.path/.advance. The count is pinned EXACTLY: a
	// regression that drops a funpack-evaluable assert, or that mis-evaluates one,
	// moves this number — never loosen it to a range.
	testing.expect_value(t, report.passed, 8)
	log.infof(
		"golden arena: project compiles end-to-end; all %d inline asserts pass in the funpack evaluator (View.ref/resolve is now funpack-evaluable)",
		report.passed,
	)
}

// The committed gen/arena.gen.fun path resolves through the shared
// arena_committed_seam_path (golden_seam_test.odin), which drives the §14.4
// capability reader (levels/arena.flvl ⇒ gen/arena.gen.fun) and SKIPs loudly when
// the sibling checkout is absent — the same reader the bake pipeline uses, not a
// hard-coded gen/ path.
