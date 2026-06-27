package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

HUNT_DEFAULT_DIR :: "examples/hunt"

@(test)
test_golden_hunt_full_file_parses :: proc(t: ^testing.T) {
	source, ok := hunt_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")

	testing.expect_value(t, len(ast.imports), 6)
	testing.expect_value(t, len(ast.enums), 2)
	testing.expect_value(t, len(ast.datas), 0)
	testing.expect_value(t, len(ast.lets), 4)
	testing.expect_value(t, len(ast.things), 2)
	testing.expect_value(t, len(ast.signals), 0)
	testing.expect_value(t, len(ast.fns), 9)
	testing.expect_value(t, len(ast.behaviors), 4)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 6)

	drive, found_drive := find_enum(ast, "Drive")
	testing.expect(t, found_drive)
	if found_drive {
		testing.expect_value(t, drive.kind, "Axis")
		testing.expect_value(t, len(drive.variants), 1)
	}

	hunt_enum, found_hunt := find_enum(ast, "Hunt")
	testing.expect(t, found_hunt)
	if found_hunt {
		testing.expect_value(t, hunt_enum.kind, "")
		testing.expect_value(t, len(hunt_enum.variants), 3)
	}

	hunter, found_hunter := find_thing(ast, "Hunter")
	testing.expect(t, found_hunter)
	if found_hunter {
		testing.expect_value(t, len(hunter.fields), 5)
	}

	pipeline, found_pipeline := find_pipeline(ast, "Hunt")
	testing.expect(t, found_pipeline)
	if found_pipeline {
		testing.expect_value(t, len(pipeline.stages), 4)
		testing.expect_value(t, pipeline.stages[0].name, "startup")
		testing.expect_value(t, pipeline.stages[3].name, "render")
	}

	think, found_think := find_behavior(ast, "think")
	testing.expect(t, found_think)
	if found_think {
		testing.expect_value(t, think.target, "Hunter")
		testing.expect_value(t, think.step.name, "step")
	}
}

@(test)
test_golden_hunt_full_file_typechecks :: proc(t: ^testing.T) {
	source, ok := hunt_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
	_, type_err := stage_typecheck(ast)
	testing.expect_value(t, type_err, Type_Error.None)
}

@(test)
test_golden_hunt_full_pipeline_passes :: proc(t: ^testing.T) {
	source, ok := hunt_source()
	if !ok {
		return
	}
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 10)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_emit_hunt_artifact_carries_composite_defaults :: proc(t: ^testing.T) {
	inputs, ok := hunt_emit_inputs(t)
	if !ok {
		return
	}
	artifact, emit_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return
	}
	testing.expect(t, strings.contains(artifact, "field ai Hunt =Hunt::Patrol\n"))
	testing.expect(t, strings.contains(artifact, "field last_seen Vec2 =Vec2(x=0,y=0)\n"))
	testing.expect(t, strings.contains(artifact, "field search_t Fixed =0\n"))
	testing.expect(t, !strings.contains(artifact, " =\n"))
	second, second_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect(t, artifact == second)
	if artifact == second {
		log.infof("emit hunt: composite defaults emit as one-token forms, byte-identical twice (%d bytes)", len(artifact))
	}
}

hunt_emit_inputs :: proc(t: ^testing.T) -> (inputs: Pong_Emit_Inputs, ok: bool) {
	dir := resolve_hunt_dir()
	if !os.is_dir(dir) {
		_, present := hunt_source()
		_ = present
		return Pong_Emit_Inputs{}, false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None || len(project.sources) == 0 {
		return Pong_Emit_Inputs{}, false
	}
	source_bytes, src_err := os.read_entire_file_from_path(project.sources[0].path, context.temp_allocator)
	if src_err != nil {
		return Pong_Emit_Inputs{}, false
	}
	entrypoint_path, _ := filepath.join({dir, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	entrypoint_bytes, ep_err := os.read_entire_file_from_path(entrypoint_path, context.temp_allocator)
	if ep_err != nil {
		return Pong_Emit_Inputs{}, false
	}
	return Pong_Emit_Inputs {
			source          = string(source_bytes),
			module          = project.sources[0].module,
			project         = Project_Identity{name = project.name, version = project.version},
			entrypoint_fcfg = string(entrypoint_bytes),
		},
		true
}

hunt_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_hunt_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden hunt: %s not found — set FUNPACK_HUNT_DIR or ensure the in-repo fixture exists", dir)
		return "", false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None || len(project.sources) == 0 {
		return "", false
	}
	source_bytes, file_err := os.read_entire_file_from_path(project.sources[0].path, context.temp_allocator)
	if file_err != nil {
		return "", false
	}
	return string(source_bytes), true
}

resolve_hunt_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_HUNT_DIR", HUNT_DEFAULT_DIR)
}
