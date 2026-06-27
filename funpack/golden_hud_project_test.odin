package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

HUD_DEMO_PROJECT_ASSERT_COUNT :: 12

HUD_PROJECT_MODULES :: []string{"hud", "pause", "screens", "settings", "hud_demo"}

@(test)
test_golden_hud_all_seams_byte_match :: proc(t: ^testing.T) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden hud project: %s not found — set FUNPACK_HUD_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}

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

	testing.expect_value(t, matched, 4)
	log.infof(
		"golden hud project: all 4 committed seams (hud/settings/pause + screens) reproduce the live ui/*.fui bake byte-for-byte",
	)
}

@(test)
test_golden_hud_whole_tree_evaluates :: proc(t: ^testing.T) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden hud project: %s not found — set FUNPACK_HUD_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	for module in HUD_PROJECT_MODULES {
		_, found := find_source_module(project.sources, module)
		testing.expectf(t, found, "module %s did not join the hud source set", module)
	}
	testing.expect_value(t, len(project.sources), len(HUD_PROJECT_MODULES))

	report := run_project_pipeline(project.sources)
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden hud project: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}

	testing.expect_value(t, report.passed, HUD_DEMO_PROJECT_ASSERT_COUNT)
	testing.expect_value(t, report.failed, 0)
	log.infof(
		"golden hud project: the whole hud tree (4 generated seams + hud_demo) types end-to-end and its %d inline asserts evaluate true against the GENERATED seams",
		report.passed,
	)
}

@(test)
test_golden_hud_demo_declaration_inventory :: proc(t: ^testing.T) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden hud project: %s not found — set FUNPACK_HUD_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}
	project, read_err, _ := read_project(dir)
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

	testing.expect_value(t, len(ast.imports), 13)
	testing.expect_value(t, len(ast.things), 1)
	testing.expect_value(t, len(ast.enums), 0)
	testing.expect_value(t, len(ast.lets), 0)
	testing.expect_value(t, len(ast.signals), 0)
	testing.expect_value(t, len(ast.fns), 10)
	testing.expect_value(t, len(ast.behaviors), 4)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 10)

	testing.expect(t, ast.module_doc != "")
	testing.expect(
		t,
		strings.has_prefix(ast.module_doc, "A tiny arcade demo with three screens"),
	)

	app, found_app := find_thing(ast, "App")
	testing.expect(t, found_app)
	if found_app {
		testing.expect(t, !app.is_singleton)
		testing.expect_value(t, len(app.fields), 7)
	}

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
