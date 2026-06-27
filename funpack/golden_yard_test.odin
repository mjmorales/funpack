package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

YARD_DEFAULT_DIR :: "examples/yard"

@(test)
test_golden_yard_full_file_parses :: proc(t: ^testing.T) {
	source, ok := yard_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")

	testing.expect_value(t, len(ast.imports), 7)
	testing.expect_value(t, len(ast.enums), 3)
	testing.expect_value(t, len(ast.lets), 5)
	testing.expect_value(t, len(ast.things), 7)
	testing.expect_value(t, len(ast.signals), 1)
	testing.expect_value(t, len(ast.fns), 8)
	testing.expect_value(t, len(ast.behaviors), 17)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 14)

	layer, found_layer := find_enum(ast, "Layer")
	testing.expect(t, found_layer)
	if found_layer {
		testing.expect_value(t, layer.kind, "CollisionLayer")
		testing.expect_value(t, len(layer.variants), 4)
	}

	camera, found_cam := find_thing(ast, "Camera")
	testing.expect(t, found_cam)
	if found_cam {
		testing.expect(t, camera.is_singleton)
		testing.expect_value(t, len(camera.fields), 3)
	}
	player, found_player := find_thing(ast, "Player")
	testing.expect(t, found_player)
	if found_player {
		testing.expect(t, !player.is_singleton)
	}

	yard, found_yard := find_pipeline(ast, "Yard")
	testing.expect(t, found_yard)
	if found_yard {
		testing.expect_value(t, len(yard.stages), 7)
		physics, found_physics := find_stage(yard, "physics")
		testing.expect(t, found_physics)
		if found_physics {
			testing.expect(t, physics.is_battery)
			testing.expect_value(t, physics.battery, "solve")
		}
	}
}

@(test)
test_golden_yard_full_file_typechecks :: proc(t: ^testing.T) {
	source, ok := yard_source()
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
test_golden_yard_compile_pipeline_flattens :: proc(t: ^testing.T) {
	source, ok := yard_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
	typed, type_err := stage_typecheck(ast)
	testing.expect_value(t, type_err, Type_Error.None)
	if type_err != .None {
		return
	}
	testing.expect_value(t, stage_contracts(typed).err, Contract_Error.None)
	verdict := stage_flatten(typed)
	testing.expect_value(t, verdict.err, Flatten_Error.None)
	if verdict.err != .None {
		return
	}
	physics_steps := 0
	for step in verdict.flat.order {
		if step.stage == "physics" {
			testing.expect_value(t, step.behavior, "solve")
			testing.expect(t, step.is_battery)
			physics_steps += 1
		}
	}
	testing.expect_value(t, physics_steps, 1)
}

@(test)
test_emit_yard_artifact_v5_round_trips :: proc(t: ^testing.T) {
	inputs, ok := yard_emit_inputs(t)
	if !ok {
		return
	}
	artifact, emit_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return
	}
	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)

	second, second_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect(t, artifact == second)
	if artifact == second {
		log.infof("emit yard: schema-v5 artifact emits well-formed and byte-identical twice (%d bytes)", len(artifact))
	}
}

@(test)
test_emit_yard_v5_singleton_marker :: proc(t: ^testing.T) {
	inputs, ok := yard_emit_inputs(t)
	if !ok {
		return
	}
	artifact, emit_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return
	}

	testing.expect(t, artifact_has_line(artifact, "thing Scoreboard true 1 1"))
	testing.expect(t, artifact_has_line(artifact, "thing Camera true 1 3"))
	testing.expect(t, artifact_has_line(artifact, "thing Menu true 1 3"))
	testing.expect(t, artifact_has_line(artifact, "thing Player false 1 3"))

	testing.expect(t, artifact_has_line(artifact, "field delivered Int =0"))

	testing.expect(t, artifact_has_line(artifact, "field at Vec2 =Vec2(x=343597383680,y=257698037760)"))
	testing.expect(t, artifact_has_line(artifact, "field zoom Fixed =4294967296"))
	testing.expect(t, artifact_has_line(artifact, "field shake Vec2 =Vec2(x=0,y=0)"))
}

@(test)
test_emit_yard_v5_engine_type_defaults :: proc(t: ^testing.T) {
	inputs, ok := yard_emit_inputs(t)
	if !ok {
		return
	}
	artifact, emit_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return
	}

	testing.expect(t, artifact_has_line(artifact, "data Settings 3 false"))
	testing.expect(t, artifact_has_line(artifact, "field volume Int -"))
	testing.expect(t, artifact_has_line(artifact, "field fullscreen Bool -"))
	testing.expect(t, artifact_has_line(artifact, "field access AccessOpts -"))
	testing.expect(t, artifact_has_line(artifact, "data AccessOpts 1 false"))
	testing.expect(t, artifact_has_line(artifact, "field reduce_motion Bool -"))

	testing.expect(t, artifact_has_line(artifact, "field settings Settings =Settings(volume=128,fullscreen=false,access=AccessOpts(reduce_motion=false))"))

	testing.expect(t, artifact_has_line(artifact, "field status Option[String] =Option::None"))

	testing.expect(t, artifact_has_line(artifact, "field dirty Bool =false"))
}

@(test)
test_emit_yard_v5_physics_stage_and_collision_layer :: proc(t: ^testing.T) {
	inputs, ok := yard_emit_inputs(t)
	if !ok {
		return
	}
	artifact, emit_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return
	}

	testing.expect(t, artifact_has_line(artifact, "enum Layer CollisionLayer 4"))

	testing.expect(t, artifact_contains(artifact, "stage:physics behavior:solve"))
}

@(test)
test_emit_yard_v5_setup_batch_compile_time_evaluates :: proc(t: ^testing.T) {
	inputs, ok := yard_emit_inputs(t)
	if !ok {
		return
	}
	artifact, emit_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return
	}

	testing.expect(t, artifact_has_line(artifact, "[setup 9]"))
	testing.expect_value(t, count_setup_spawns(artifact, "Wall"), 4)
	testing.expect_value(t, count_setup_spawns(artifact, "Pad"), 1)
	testing.expect_value(t, count_setup_spawns(artifact, "Player"), 1)
	testing.expect_value(t, count_setup_spawns(artifact, "Crate"), 3)

	testing.expect(t, artifact_has_line(artifact, "set body =Body(kind=BodyKind::Static,shape=Shape2::Box(size=Vec2(x=687194767360,y=17179869184)),layer=Layer::Wall,mask=[Layer::Player,Layer::Crate],mass=4294967296,restitution=0,friction=2147483648,sensor=false,impulse=Vec2(x=0,y=0))"))

	testing.expect(t, artifact_has_line(artifact, "set body =Body(kind=BodyKind::Static,shape=Shape2::Box(size=Vec2(x=103079215104,y=103079215104)),sensor=true,layer=Layer::Pad,mask=[Layer::Crate],mass=4294967296,restitution=0,friction=2147483648,impulse=Vec2(x=0,y=0))"))

	testing.expect(t, artifact_has_line(artifact, "set body =Body(kind=BodyKind::Dynamic,shape=Shape2::Box(size=Vec2(x=51539607552,y=51539607552)),mass=8589934592,friction=3865470566,layer=Layer::Crate,mask=[Layer::Wall,Layer::Player,Layer::Crate,Layer::Pad],restitution=0,sensor=false,impulse=Vec2(x=0,y=0))"))

	testing.expect(t, artifact_has_line(artifact, "set body =Body(kind=BodyKind::Dynamic,shape=Shape2::Circle(radius=21474836480),friction=3865470566,layer=Layer::Player,mask=[Layer::Wall,Layer::Crate],mass=4294967296,restitution=0,sensor=false,impulse=Vec2(x=0,y=0))"))
}

count_setup_spawns :: proc(artifact: string, thing: string) -> int {
	n := 0
	prefix := strings.concatenate({"spawn ", thing, " "}, context.temp_allocator)
	for candidate in strings.split(artifact, "\n", context.temp_allocator) {
		if strings.has_prefix(candidate, prefix) {
			n += 1
		}
	}
	return n
}

artifact_has_line :: proc(artifact: string, line: string) -> bool {
	for candidate in strings.split(artifact, "\n", context.temp_allocator) {
		if candidate == line {
			return true
		}
	}
	return false
}

artifact_contains :: proc(artifact: string, fragment: string) -> bool {
	return strings.contains(artifact, fragment)
}

artifact_has_line_prefix :: proc(artifact: string, prefix: string) -> bool {
	for candidate in strings.split(artifact, "\n", context.temp_allocator) {
		if strings.has_prefix(candidate, prefix) {
			return true
		}
	}
	return false
}

find_stage :: proc(pipeline: Pipeline_Node, name: string) -> (Pipeline_Stage, bool) {
	for stage in pipeline.stages {
		if stage.name == name {
			return stage, true
		}
	}
	return Pipeline_Stage{}, false
}

yard_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_yard_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden yard: %s not found — set FUNPACK_YARD_DIR or ensure the in-repo fixture exists", dir)
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

yard_emit_inputs :: proc(t: ^testing.T) -> (inputs: Pong_Emit_Inputs, ok: bool) {
	dir := resolve_yard_dir()
	if !os.is_dir(dir) {
		_, present := yard_source()
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
	entrypoint_path := strings.concatenate({dir, "/funpack_configs/entrypoints.fcfg"}, context.temp_allocator)
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

resolve_yard_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_YARD_DIR", YARD_DEFAULT_DIR)
}
