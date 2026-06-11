// The §11/§20/§24 cross-epic golden: the yard example tree
// (funpack-spec/examples/yard) is the live source the v5 surface and emitter
// must parse, type, flatten, and emit exactly. yard is the first surface to reach
// the physics solve battery (§11 §3), the camera draw command (§20 §3), the
// persistence save/restore/settings commands (§24), CollisionLayer-kinded enums
// (§03 §4), and engine-type/singleton field defaults (§6). Like the pong/snake
// goldens, the fixtures pin the declaration counts and the v5 emission sections
// against the live source — when the spec evolves, the counts change in lockstep;
// never loosen them to ranges. The fixture resolves the sibling checkout (or
// FUNPACK_YARD_DIR) and SKIPs loudly when it is absent, so a missing checkout
// never silently passes.
//
// SCOPE: yard's inline test ASSERTIONS exercise engine-value EXECUTION (Body
// intent, Input sampling, Despawn/Save command equality, View, nested Settings
// with-update) the funpack evaluator does not implement and the runtime owns, so
// this golden pins parse + typecheck + the compile pipeline THROUGH flatten/
// closure + EMISSION (the v5 story's deliverable), not full inline-assertion
// evaluation (cf. the pong/snake pipeline goldens, whose assertions touch only
// already-evaluable forms).
package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

YARD_DEFAULT_DIR :: "../funpack-spec/examples/yard"

// test_golden_yard_full_file_parses pins yard's v5 declaration inventory: the
// imports, the CollisionLayer-kinded Layer enum, the singleton-vs-thing split, and
// the physics-battery pipeline stage — the structural fingerprint the v5 surface
// and emitter both target.
@(test)
test_golden_yard_full_file_parses :: proc(t: ^testing.T) {
	source, ok := yard_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")

	// yard's v5 declaration inventory (§11/§20/§24): seven imports (math, world,
	// input, render, physics, save, list); three enums (Drive: Axis, Layer:
	// CollisionLayer, Cmd: Button); five module-level lets (SLOT, ACCEL, FOLLOW,
	// SHAKE_KICK, SHAKE_DAMP); seven things — four `thing` (Player, Crate, Wall,
	// Pad) and three `singleton` (Scoreboard, Camera, Menu); one signal
	// (Delivered); eight top-level fns (focus, box_size, wall_body, crate_body,
	// crate_at, player_body, setup, bindings); seventeen behaviors (drive, deliver,
	// tally, follow, shake, view, save_key, restore_key, on_persist_result,
	// toggle_motion, apply_settings, on_settings_applied, draw_wall, draw_pad,
	// draw_crate, draw_player, draw_score); one pipeline (Yard) with the physics
	// battery stage; fourteen inline tests.
	testing.expect_value(t, len(ast.imports), 7)
	testing.expect_value(t, len(ast.enums), 3)
	testing.expect_value(t, len(ast.lets), 5)
	testing.expect_value(t, len(ast.things), 7)
	testing.expect_value(t, len(ast.signals), 1)
	testing.expect_value(t, len(ast.fns), 8)
	testing.expect_value(t, len(ast.behaviors), 17)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 14)

	// The CollisionLayer role kind on Layer — type-constitutive (§03 §4), the v5
	// tag the emitter stamps.
	layer, found_layer := find_enum(ast, "Layer")
	testing.expect(t, found_layer)
	if found_layer {
		testing.expect_value(t, layer.kind, "CollisionLayer")
		testing.expect_value(t, len(layer.variants), 4)
	}

	// The singleton-vs-thing split: Camera is a `singleton`, Player a `thing`.
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

	// The Yard pipeline carries the §11 §3 physics battery stage — a bare-battery
	// stage (is_battery), distinct from the behavior-list stages around it.
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

// test_golden_yard_full_file_typechecks is the load-bearing surface acceptance:
// the full yard source types end-to-end through stage_typecheck — every behavior
// step, helper fn, bindings(), and setup() types over the resolved environment,
// with the §11 Body/.apply_impulse, §20 Draw::Camera, §24 Save/Restore/
// ApplySettings/Settings, len/fold combinators, and Input.with_axis sites all
// checking. It clears the gate stage too (the v5 nesting-metric refinement lets
// yard's fold-match-with-Option behaviors clear the §01 P5 budget).
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

// test_golden_yard_compile_pipeline_flattens proves yard clears the whole compile
// pipeline through the §07 §3 flatten + §04/§07 effect-closure edge check — the
// stages downstream of typecheck. The physics battery occupies a flattened step
// (the §11 §3 engine boundary in the total order) and the Delivered signal closes
// (produced by `deliver`, consumed by `tally`/`shake` downstream). This is the
// "pipeline" half of the parse/typecheck/pipeline golden; it stops at flatten
// because yard's evaluable assertions are the runtime's, not the funpack
// evaluator's (see the file header).
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
	// The physics battery is a flattened step (stage:physics, behavior:solve), a
	// battery step distinct from a behavior step — the §11 §3 engine boundary in
	// the total order. It carries no [behaviors] record (is_battery).
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

// test_emit_yard_artifact_v5_round_trips is the yard-side emission acceptance: the
// production emitter, run over the live yard source, emits a well-formed v5
// artifact carrying the four v5 constructs — the singleton tick-0 marker, the
// physics-stage step, the CollisionLayer KIND tag, and the engine-type field
// defaults. The check pins the artifact carries ARTIFACT_SCHEMA_VERSION (5),
// parses well-formed through the funpack reader (every section count reconciles),
// and is deterministic (double-emit byte-identical). The per-construct assertions
// below pin the exact emitted tokens.
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

	// Deterministic emission (spec §09, §29): two emissions are byte-identical.
	second, second_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect(t, artifact == second)
	if artifact == second {
		log.infof("emit yard: schema-v5 artifact emits well-formed and byte-identical twice (%d bytes)", len(artifact))
	}
}

// test_emit_yard_v5_singleton_marker pins the §06 §2 singleton tick-0 spawn
// marker: a singleton's [things] row carries SINGLETON true plus its COMPLETE
// defaulted field schema, the only source the runtime has to spawn the singleton
// row. The three yard singletons exercise the full §6 default vocabulary — a bare
// Int (Scoreboard.delivered = 0), composite Vec2/Fixed (Camera), and the v5
// engine-type composite + enum-variant defaults (Menu's Settings.defaults() and
// Option::None). The four `thing`s carry SINGLETON false.
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

	// The three singletons carry the SINGLETON true tick-0 marker; the four plain
	// things carry SINGLETON false.
	testing.expect(t, artifact_has_line(artifact, "thing Scoreboard true 1 1"))
	testing.expect(t, artifact_has_line(artifact, "thing Camera true 1 3"))
	testing.expect(t, artifact_has_line(artifact, "thing Menu true 1 3"))
	testing.expect(t, artifact_has_line(artifact, "thing Player false 1 3"))

	// Scoreboard's complete defaulted schema: the bare Int default (§6 scalar).
	testing.expect(t, artifact_has_line(artifact, "field delivered Int =0"))

	// Camera's composite Vec2 + Fixed defaults, bit-exact (80.0/60.0 and 1.0 in
	// raw Q32.32). The tick-0 spawn fills these columns from the schema alone.
	testing.expect(t, artifact_has_line(artifact, "field at Vec2 =Vec2(x=343597383680,y=257698037760)"))
	testing.expect(t, artifact_has_line(artifact, "field zoom Fixed =4294967296"))
	testing.expect(t, artifact_has_line(artifact, "field shake Vec2 =Vec2(x=0,y=0)"))
}

// test_emit_yard_v5_engine_type_defaults pins the §6 engine-type field defaults —
// the v5 default forms yard first reaches. A Settings static-builder default
// (`Settings.defaults()`) lowers to its evaluated factory record inline against a
// synthesized §8 Settings data projection; an Option[String] default is the
// enum-variant Option::None token. These are the exact tokens the runtime's
// composite-default decode reads (runtime/decode_default_test.odin), so they must
// be byte-exact — the cross-product contract.
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

	// The synthesized §8 Settings data projection (volume: Int, fullscreen: Bool,
	// access: AccessOpts) the runtime decodes a Settings composite default's nested
	// field types against — plus the nested AccessOpts sub-record's own §8 decl, so
	// `reduce_motion` resolves to a Bool (a missing AccessOpts decl would lift it to a
	// bare string token). `access` is LOAD-BEARING: yard reads settings.access.
	// reduce_motion, so the spawned Menu singleton must carry the access column.
	testing.expect(t, artifact_has_line(artifact, "data Settings 3 false"))
	testing.expect(t, artifact_has_line(artifact, "field volume Int -"))
	testing.expect(t, artifact_has_line(artifact, "field fullscreen Bool -"))
	testing.expect(t, artifact_has_line(artifact, "field access AccessOpts -"))
	testing.expect(t, artifact_has_line(artifact, "data AccessOpts 1 false"))
	testing.expect(t, artifact_has_line(artifact, "field reduce_motion Bool -"))

	// Menu's engine-type composite default: Settings.defaults() lowered to the
	// evaluated factory record inline (the one-token §6 composite slot), carrying the
	// nested access sub-record so the spawned singleton's settings.access.reduce_motion
	// read resolves.
	testing.expect(t, artifact_has_line(artifact, "field settings Settings =Settings(volume=128,fullscreen=false,access=AccessOpts(reduce_motion=false))"))

	// Menu's Option[String] singleton default: the enum-variant Option::None token
	// (the field's [String] element shapes only its TYPE column, not the default).
	testing.expect(t, artifact_has_line(artifact, "field status Option[String] =Option::None"))

	// Menu's Bool default carries the bare-token form.
	testing.expect(t, artifact_has_line(artifact, "field dirty Bool =false"))
}

// test_emit_yard_v5_physics_stage_and_collision_layer pins the remaining two v5
// constructs: the §11 §3 physics-stage step (`stage:physics behavior:solve` — a
// battery step distinct from a behavior step, the engine boundary in the
// flattened total order) and the §03 §4 CollisionLayer enum KIND tag (the
// `enum Layer CollisionLayer 4` [enums] record).
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

	// The CollisionLayer KIND tag on the Layer enum record (§5).
	testing.expect(t, artifact_has_line(artifact, "enum Layer CollisionLayer 4"))

	// The physics battery step in [pipeline_flattened]: the (physics, solve) pair
	// the runtime dispatches to the native solver, not a behavior lookup (§11 §3).
	testing.expect(t, artifact_contains(artifact, "stage:physics behavior:solve"))
}

// test_emit_yard_v5_setup_batch_compile_time_evaluates pins the §13 Startup [Spawn]
// batch: yard's setup() spawns through user helper fns (crate_at, wall_body,
// player_body) and inline Body records with §11 §2 defaults left implicit, so the
// emitter must CONSTANT-FOLD the batch — inline the calls, resolve the nested
// records, and apply the omitted Body defaults — into a closed 9-row population (4
// Walls, 1 Pad, 1 Player, 3 Crates). Before this fold the batch was malformed (the
// 3 crate_at spawns were dropped and every `set body =` emitted an empty value), so
// the artifact could not spawn its world. The composite Body fields take the §6
// single-token nested form `Body(field=enc,…)`; the spot-checks pin the load-bearing
// columns the runtime solver reads (the Pad sensor, a crate's friction 0.9, the
// player's mask omitting Pad), so a regression in the fold or the default-fill is
// caught at exact-token granularity (never ranges — the hunt golden's discipline).
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

	// The batch is exactly nine spawns, in source list order (4 Walls, 1 Pad, 1
	// Player, 3 Crates). The 3 crate_at(…) calls are now inlined, not dropped.
	testing.expect(t, artifact_has_line(artifact, "[setup 9]"))
	testing.expect_value(t, count_setup_spawns(artifact, "Wall"), 4)
	testing.expect_value(t, count_setup_spawns(artifact, "Pad"), 1)
	testing.expect_value(t, count_setup_spawns(artifact, "Player"), 1)
	testing.expect_value(t, count_setup_spawns(artifact, "Crate"), 3)

	// Each Body field carries its COMPLETE resolved column set — the §11 §2 defaults
	// the source omits are filled (mass=1.0=4294967296, restitution=0, friction=0.5=
	// 2147483648, sensor=false, impulse=Vec2(x=0,y=0)). A Wall body is the bare
	// Static-box default shape: a §11 default fold with no source override but sensor.
	testing.expect(t, artifact_has_line(artifact, "set body =Body(kind=BodyKind::Static,shape=Shape2::Box(size=Vec2(x=687194767360,y=17179869184)),layer=Layer::Wall,mask=[Layer::Player,Layer::Crate],mass=4294967296,restitution=0,friction=2147483648,sensor=false,impulse=Vec2(x=0,y=0))"))

	// The Pad's inline Body carries the SENSOR override (sensor=true), kept over the
	// §11 default false — the load-bearing flag that makes the pad a trigger, not a
	// resolved collider (§11 §4).
	testing.expect(t, artifact_has_line(artifact, "set body =Body(kind=BodyKind::Static,shape=Shape2::Box(size=Vec2(x=103079215104,y=103079215104)),sensor=true,layer=Layer::Pad,mask=[Layer::Crate],mass=4294967296,restitution=0,friction=2147483648,impulse=Vec2(x=0,y=0))"))

	// A crate's Body: the friction 0.9 (3865470566) and mass 2.0 (8589934592) source
	// overrides kept over the §11 defaults, and the full four-layer mask (the crate
	// collides with everything including the Pad sensor). crate_at → crate_body() is
	// inlined to this resolved Body.
	testing.expect(t, artifact_has_line(artifact, "set body =Body(kind=BodyKind::Dynamic,shape=Shape2::Box(size=Vec2(x=51539607552,y=51539607552)),mass=8589934592,friction=3865470566,layer=Layer::Crate,mask=[Layer::Wall,Layer::Player,Layer::Crate,Layer::Pad],restitution=0,sensor=false,impulse=Vec2(x=0,y=0))"))

	// The player's Body: a Dynamic circle whose mask OMITS Pad (the player walks over
	// the pad sensor freely, §11 §5) — player_body() inlined with friction 0.9 kept
	// and mass/restitution/sensor/impulse defaulted.
	testing.expect(t, artifact_has_line(artifact, "set body =Body(kind=BodyKind::Dynamic,shape=Shape2::Circle(radius=21474836480),friction=3865470566,layer=Layer::Player,mask=[Layer::Wall,Layer::Crate],mass=4294967296,restitution=0,sensor=false,impulse=Vec2(x=0,y=0))"))
}

// count_setup_spawns counts the `spawn THING …` records in the [setup] section for a
// given thing type — the per-type population the §13 batch carries, read without
// pinning the field counts that follow each spawn.
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

// artifact_has_line reports whether the artifact carries `line` as a whole
// LF-delimited line — a stricter match than a substring so a field token is pinned
// exactly, never as a coincidental fragment of a longer line.
artifact_has_line :: proc(artifact: string, line: string) -> bool {
	for candidate in strings.split(artifact, "\n", context.temp_allocator) {
		if candidate == line {
			return true
		}
	}
	return false
}

// artifact_contains reports whether the artifact carries `fragment` anywhere — for
// a step line whose leading ordinal varies, so the (stage, behavior) tail is
// matched without pinning the ordinal.
artifact_contains :: proc(artifact: string, fragment: string) -> bool {
	return strings.contains(artifact, fragment)
}

// find_stage is a linear lookup of a pipeline's stage by name — the v5 fixtures
// read the physics battery stage without depending on its position.
find_stage :: proc(pipeline: Pipeline_Node, name: string) -> (Pipeline_Stage, bool) {
	for stage in pipeline.stages {
		if stage.name == name {
			return stage, true
		}
	}
	return Pipeline_Stage{}, false
}

// yard_source reads the yard project's single source file via the §14
// project-tree reader; ok = false (with a SKIP warning) when the sibling checkout
// is absent, matching the pong/snake golden skip semantics.
yard_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_yard_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden yard: %s not found — set FUNPACK_YARD_DIR or check out funpack-spec as a sibling of the repo", dir)
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

// yard_emit_inputs resolves the yard project tree and reads the emitter's inputs
// (source bytes, §15 module, §14 identity, entrypoints.fcfg) — the same shape
// pong_emit_inputs reads for pong. ok = false (with the golden SKIP warning
// through yard_source) when the sibling checkout is absent.
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
