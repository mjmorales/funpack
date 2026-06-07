// The §21/§22 whole-hud golden: the LAST plan task of the bake-pipeline-seams
// epic — green only when every prior seam composes. It proves the complete UI
// pipeline against the LIVE examples/hud tree, never a hand-built stand-in:
//
//   (a) FOUR-SEAM BYTE MATCH — a fresh bake of the THREE ui/*.fui sources, run
//       together through the per-screen emitter (emit_screen_seam) and the
//       set-level routing emitter (emit_screens_seam), reproduces ALL FOUR
//       committed gen/*.gen.fun seams (hud/settings/pause + screens) byte-for-byte
//       in one integration check. The per-screen and screens emitters are the
//       7.2/7.3 stories' (golden_hud_seam_test.odin pins each individually); this
//       composes the whole set in a single bake, so the four seams are proven
//       current together, not just one at a time.
//
//   (b) WHOLE-TREE COMPILE + EVALUATE — read_project merges src/hud_demo.fun with
//       the four committed gen/ seams into one §14 source set, and
//       run_project_pipeline types every module end-to-end (the route fold over
//       the imported AppMsg union, the View.map mount lifting each screen's Msg,
//       the on_msg [Sound] one-shot return, the music [Audio] bed) and EVALUATES
//       hud_demo's inline tests. Every assert is funpack-evaluable against the
//       generated seams: the projections, the router as plain state, both audio
//       regimes, the §21 §3 variant-as-function value, and the two cross-module
//       record cases (settings preset row, empty pause view) the hud integration's
//       eval_module_record arm materializes. The count is pinned EXACTLY.
//
//   (c) DECLARATION INVENTORY — hud_demo.fun's §11/§21/§22 structural fingerprint
//       (imports, the App thing, the fns, the four behaviors, the Arcade pipeline's
//       five stages, the inline tests) is pinned the way golden_yard_test pins
//       yard's: an exact count per kind, never a range, so a surface drift fails
//       loudly in lockstep with the source.
//
// All three resolve the sibling funpack-spec checkout (or FUNPACK_HUD_DIR via
// resolve_hud_dir, shared with golden_hud_seam_test.odin) and SKIP LOUDLY when it
// is absent — a skipped golden is a warning, NEVER a pass. A successful run logs an
// execution trace so the acceptance gate can confirm the golden ran, not SKIPped.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// HUD_DEMO_PROJECT_ASSERT_COUNT is the count of funpack-evaluable inline asserts
// hud_demo.fun carries — 12 across its 10 test blocks (coin/pause each carry two,
// the rest one). Pinned EXACTLY (not a range): ALL twelve evaluate true against
// the GENERATED seams — the cross-module enum-variant values (Screen::Pause,
// AppMsg::Hud) and cross-module record literals (SettingsPresetRow, PauseView) the
// hud integration admitted to the typechecker and evaluator make the whole-tree
// run identical to the 5.2 hand-written-struct run (golden_hud_test.odin's 12). A
// surface drift moves this number in lockstep with the source; never loosen it.
HUD_DEMO_PROJECT_ASSERT_COUNT :: 12

// HUD_PROJECT_MODULES is the §15 module set read_project derives for the live hud
// tree, in collected (sorted) order: the four gen/ seam modules (gen/ prefix
// stripped, like src/) then the src/ behavior module. Listed explicitly so the
// whole-tree acceptance asserts the multi-module project the index types together
// is exactly these five — the four generated seams plus the consumer.
HUD_PROJECT_MODULES :: []string{"hud", "pause", "screens", "settings", "hud_demo"}

// ── (a) all four seams byte-match the committed gen/ in one bake ──────────────

// test_golden_hud_all_seams_byte_match is the integration byte contract: a fresh
// bake of the live ui/*.fui set reproduces ALL FOUR committed gen/*.gen.fun seams
// byte-for-byte — the three per-screen seams through emit_screen_seam and the
// set-level routing seam through emit_screens_seam — proven together through the
// shared compare_seam harness (None each). A divergence in ANY seam is an
// exit-2-class Stale_Seam build error the diff reporter locates, never a
// silently-passing range. SKIPs loudly when the sibling is absent.
@(test)
test_golden_hud_all_seams_byte_match :: proc(t: ^testing.T) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden hud project: %s not found — set FUNPACK_HUD_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return
	}

	// The three per-screen seams: each ui/<screen>.fui baked and matched against
	// its committed gen/<screen>.gen.fun. emit_committed_screen_seam (the 7.2 seam
	// test) reads+parses+infers+emits one screen with its pinned docs.
	matched := 0
	for screen in FUI_SCREEN_STEMS {
		emitted, golden, ok := emit_committed_screen_seam(screen)
		if !ok {
			return
		}
		testing.expect_value(t, len(emitted), len(golden))
		testing.expect(t, emitted == golden)
		if emitted != golden {
			report_first_byte_diff(emitted, golden)
			return
		}
		matched += 1
	}

	// The set-level routing seam: the SET of three parsed screens baked through
	// emit_screens_seam and matched against the committed gen/screens.gen.fun via
	// compare_seam (None = current). hud_screens (the 7.3 seam test) reads+parses
	// the three sources in file-set order.
	screens, ok := hud_screens(t)
	if !ok {
		return
	}
	screens_emitted := emit_screens_seam(screens, context.temp_allocator)
	screens_path, _ := filepath.join({dir, "gen", "screens.gen.fun"}, context.temp_allocator)
	result := compare_seam(screens_emitted, screens_path)
	testing.expect_value(t, result, Seam_Compare_Error.None)
	if result != .None {
		committed_bytes, read_err := os.read_entire_file_from_path(screens_path, context.temp_allocator)
		if read_err == nil {
			report_first_byte_diff(screens_emitted, string(committed_bytes))
		}
		return
	}
	matched += 1

	// All four seams reproduced. The count guards against a silently-skipped
	// per-screen loop (matched < 4) passing the test by vacuity.
	testing.expect_value(t, matched, 4)
	log.infof(
		"golden hud project: all 4 committed seams (hud/settings/pause + screens) reproduce the live ui/*.fui bake byte-for-byte",
	)
}

// ── (b) the whole hud tree compiles and evaluates 12 asserts ──────────────────

// test_golden_hud_whole_tree_evaluates is the load-bearing integration acceptance:
// the live hud tree — src/hud_demo.fun plus the four committed gen/ seams — reads
// as one §14 project, types end-to-end across all five modules, and evaluates
// hud_demo's inline tests to ALL-PASS against the GENERATED seams (not the 5.2
// hand-written structs). It confirms the run was NOT skipped (the sibling checkout
// is present and all five modules joined the source set), then pins the assert
// count EXACTLY. A compile error in any module (module_err) is exit-2-class, never
// a counted failure; a dropped or mis-evaluated assert moves the pin. SKIPs loudly
// when the sibling is absent.
@(test)
test_golden_hud_whole_tree_evaluates :: proc(t: ^testing.T) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden hud project: %s not found — set FUNPACK_HUD_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return
	}
	project, read_err := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	// The combined source set is the four generated seams + the consumer behavior
	// module — the multi-module project hud_demo imports across (hud/pause/
	// settings/screens). Asserting every module joined confirms the run is the
	// REAL whole-tree path, not a single-source fallback (the "not skipped" floor).
	for module in HUD_PROJECT_MODULES {
		_, found := find_source_module(project.sources, module)
		testing.expectf(t, found, "module %s did not join the hud source set", module)
	}
	testing.expect_value(t, len(project.sources), len(HUD_PROJECT_MODULES))

	report := run_project_pipeline(project.sources)
	// The whole project compiles end-to-end: the index built (no read/parse
	// failure) and every module cleared parse → gates → typecheck → contracts →
	// flatten/closure. A compile error fails THIS acceptance (it is never a counted
	// assertion, §29 §3).
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden hud project: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}

	// Every hud_demo inline assert evaluates true against the generated seams — the
	// projections, the router as plain state, both audio regimes, the View.map
	// mount, the §21 §3 variant-as-function value, and the two cross-module record
	// cases. Pinned EXACTLY: 12 passed, 0 failed.
	testing.expect_value(t, report.passed, HUD_DEMO_PROJECT_ASSERT_COUNT)
	testing.expect_value(t, report.failed, 0)
	log.infof(
		"golden hud project: the whole hud tree (4 generated seams + hud_demo) types end-to-end and its %d inline asserts evaluate true against the GENERATED seams",
		report.passed,
	)
}

// ── (c) hud_demo.fun declaration inventory ────────────────────────────────────

// test_golden_hud_demo_declaration_inventory pins hud_demo.fun's §11/§21/§22
// structural fingerprint the way golden_yard_test pins yard's: thirteen imports
// (the engine.* surface — now including engine.input for the §14 §4 bindings fn —
// plus the four generated seam modules), the single App thing, no local
// enums/lets/signals (the seams own the Screen/AppMsg/HudMsg/… enums now), ten
// top-level fns (the three projections, the three on_* handlers, route,
// click_sfx, setup, and the §14 §4 empty bindings fn), four behaviors (on_msg,
// music, tick_clock, view), one Arcade pipeline with its five §11 stages
// (startup/input/update/ui/audio), and ten inline test blocks. Pinned EXACTLY: a
// surface drift moves a count in lockstep with the source (the spec a522568 fix
// added the engine.input import and the bindings fn, moving imports 12→13 and fns
// 9→10), so a loosened bound never hides it. SKIPs loudly when the sibling is
// absent.
@(test)
test_golden_hud_demo_declaration_inventory :: proc(t: ^testing.T) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden hud project: %s not found — set FUNPACK_HUD_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return
	}
	project, read_err := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}
	demo_src, found := find_source_module(project.sources, "hud_demo")
	testing.expect(t, found)
	if !found {
		return
	}
	demo_bytes, file_err := os.read_entire_file_from_path(demo_src.path, context.temp_allocator)
	if file_err != nil {
		log.warnf("SKIP golden hud project: %s not readable", demo_src.path)
		return
	}
	ast, parse_err := stage_parse(stage_lex(string(demo_bytes)))
	testing.expect_value(t, parse_err, Parse_Error.None)

	// The declaration inventory: thirteen imports (engine.prelude/input/math/core/
	// world/ui/audio/assets/list + the four seam modules hud/pause/settings/screens),
	// the single App thing, zero local enums/lets/signals (the seams own them now),
	// ten fns (incl. the §14 §4 empty bindings fn), four behaviors, one pipeline, ten
	// test blocks.
	testing.expect_value(t, len(ast.imports), 13)
	testing.expect_value(t, len(ast.things), 1)
	testing.expect_value(t, len(ast.enums), 0)
	testing.expect_value(t, len(ast.lets), 0)
	testing.expect_value(t, len(ast.signals), 0)
	testing.expect_value(t, len(ast.fns), 10)
	testing.expect_value(t, len(ast.behaviors), 4)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 10)

	// hud_demo.fun carries a file-leading @doc separated from the first import by a
	// blank line; the parser skips that blank line before the module-doc import
	// check, so the doc lands as the module doc rather than being dropped.
	testing.expect(t, ast.module_doc != "")
	testing.expect(
		t,
		strings.has_prefix(ast.module_doc, "A tiny arcade demo with three screens"),
	)

	// The App thing carries its seven §11 fields (screen/score/clock/paused/
	// game_over/player_name/volume) and is a plain thing, not a singleton.
	app, found_app := find_thing(ast, "App")
	testing.expect(t, found_app)
	if found_app {
		testing.expect(t, !app.is_singleton)
		testing.expect_value(t, len(app.fields), 7)
	}

	// The Arcade pipeline carries the five §11 §1 stages in canonical order —
	// startup, input, update, ui, audio (the §22 audio stage and the §21 ui stage
	// alongside the core three).
	arcade, found_arcade := find_pipeline(ast, "Arcade")
	testing.expect(t, found_arcade)
	if found_arcade {
		testing.expect_value(t, len(arcade.stages), 5)
		wanted_stages := []string{"startup", "input", "update", "ui", "audio"}
		for want in wanted_stages {
			_, has_stage := find_stage(arcade, want)
			testing.expectf(t, has_stage, "Arcade pipeline missing the %s stage", want)
		}
	}
	log.infof("golden hud project: hud_demo.fun declaration inventory pinned (13 imports, 1 thing, 10 fns, 4 behaviors, 1 pipeline, 10 tests)")
}
