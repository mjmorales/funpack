// The §06/§07 AI golden: the hunt example tree (examples/hunt) is
// the live source the declaration grammar must parse exactly and the full checked
// pipeline must compile and evaluate. The full-file fixture pins hunt's
// declaration inventory against that source — when the spec evolves, the counts
// change in lockstep; never loosen them to ranges. Like the pong/snake goldens,
// the fixture resolves the sibling checkout (or FUNPACK_HUNT_DIR) and SKIPs
// loudly when it is absent, so a missing checkout never silently passes. hunt is
// the patrol/chase/search enemy AI: the state machine is a blackboard enum + an
// exhaustive match, the search timeout is a Fixed countdown folded by Time, and
// the whole AI is a pure replay-stable fold — it emits NO signals (pure folds
// plus Draw plus a startup Spawn), so its pipeline closes vacuously, and it
// exercises the §08 read-side surface (View.of/first), the §04 Time resource, and
// the §02 Option match the perception predicate returns.
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

	// The hunt golden surface's exact declaration inventory (§06/§07): six
	// imports; two enums (Drive: Axis — the role-enum form — and Hunt, the AI
	// state set); no data; four module-level lets (SIGHT, H_SPEED, P_SPEED,
	// SEARCH_TIME); two things (Player, Hunter); no signals (the AI is a pure
	// fold); nine top-level fns (step_to, visible, patrol, chase, search, seek,
	// hunter_color, bindings, setup); four behaviors (think, drive, draw_hunter,
	// draw_player); one pipeline (Hunt); six inline tests.
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

	// Spot-check the load-bearing details the count alone does not pin: the
	// role-enum kind on Drive (the §23 axis-action set), the Hunt state enum's
	// three variants, the Hunter thing's blackboard fields, and the pipeline's
	// four ordered stages with the state-machine behavior on its target.
	drive, found_drive := find_enum(ast, "Drive")
	testing.expect(t, found_drive)
	if found_drive {
		testing.expect_value(t, drive.kind, "Axis")
		testing.expect_value(t, len(drive.variants), 1)
	}

	hunt_enum, found_hunt := find_enum(ast, "Hunt")
	testing.expect(t, found_hunt)
	if found_hunt {
		// Patrol/Chase/Search — the enum IS the state set (the match in `think`
		// is the transition function, exhaustiveness the totality guarantee).
		testing.expect_value(t, hunt_enum.kind, "")
		testing.expect_value(t, len(hunt_enum.variants), 3)
	}

	hunter, found_hunter := find_thing(ast, "Hunter")
	testing.expect(t, found_hunter)
	if found_hunter {
		// pos/home/ai/last_seen/search_t — five blackboard fields (pos/home
		// undefaulted, the rest defaulted).
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
	// The load-bearing acceptance: the full hunt golden source typechecks
	// end-to-end through stage_typecheck — every behavior step body, the AI helper
	// fns (step_to/visible/patrol/chase/search/seek/hunter_color), bindings(), and
	// setup() type over the resolved environment, with the View[Player]/first
	// perception predicate, the Option match, the Time.dt countdown fold, and the
	// input.axis 2D read all checking. The fixture resolves the live golden source
	// (or FUNPACK_HUNT_DIR) and SKIPs loudly when absent.
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
	// The §06/§07 AI golden's defining outcome: the full hunt source compiles
	// clean through every stage — parse → gates → typecheck → contracts → flatten →
	// effect-closure (which closes VACUOUSLY: hunt emits no signals) — and its six
	// inline test blocks evaluate to their golden values. The six blocks carry ten
	// asserts total (several blocks assert twice): visible-in-range (a View.of read
	// table through first's perception predicate, two asserts: in range Some, out
	// of range None), patrol→chase (the patrol transition records the sighting, two
	// asserts), chase→search (losing sight drops to Search with a full timer, two
	// asserts), search-reacquire (one assert), search-gives-up (the Time.dt
	// countdown gives up at zero and keeps searching while time remains, two
	// asserts), and think-dispatches (the think.step state-machine behavior over a
	// View.of + Time.at, one assert). Passing all six exercises the §08 read-side
	// surface, the §04 Time resource, and the §02 Option match the pong golden does
	// not reach. The fixture reads the live golden source (or FUNPACK_HUNT_DIR) and
	// SKIPs loudly when absent.
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

// test_emit_hunt_artifact_carries_composite_defaults is the end-to-end emission
// acceptance for the §6 composite field-default fix: the production emitter, run
// over the live hunt source, must carry hunt's two composite Hunter defaults as
// their one-token forms — `field ai Hunt =Hunt::Patrol` (the enum-variant default
// that cures the no-arm-match freeze) and `field last_seen Vec2 =Vec2(x=0,y=0)`
// (the composite record default) — never the bare `=` the encode_literal-only
// path produced. The check also pins the scalar Fixed default (`search_t: Fixed =
// 0.0` → `=0`) byte-identical and proves emission stays deterministic. The fixture
// resolves the live hunt source (or FUNPACK_HUNT_DIR) and SKIPs loudly when absent.
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
	// The two freeze-relevant composite defaults, each a single space-free token.
	testing.expect(t, strings.contains(artifact, "field ai Hunt =Hunt::Patrol\n"))
	testing.expect(t, strings.contains(artifact, "field last_seen Vec2 =Vec2(x=0,y=0)\n"))
	// The scalar Fixed default stays the original raw-bits form (0.0 → 0).
	testing.expect(t, strings.contains(artifact, "field search_t Fixed =0\n"))
	// No bare `=` default leaks (a default token always carries an encoded value).
	testing.expect(t, !strings.contains(artifact, " =\n"))
	// Deterministic emission (spec §09, §29): two emissions are byte-identical.
	second, second_err := stage_emit(inputs.source, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect(t, artifact == second)
	if artifact == second {
		log.infof("emit hunt: composite defaults emit as one-token forms, byte-identical twice (%d bytes)", len(artifact))
	}
}

// hunt_emit_inputs resolves the hunt project tree and reads the emitter's inputs
// (source bytes, §15 module, §14 identity, entrypoints.fcfg) — the same shape
// snake_emit_inputs/pong_emit_inputs read (golden_emit_test.odin). ok = false
// (with the golden SKIP warning through hunt_source) when the checkout is absent.
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

// hunt_source reads the hunt project's single source file via the §14
// project-tree reader; ok = false (with a SKIP warning) when the sibling
// checkout is absent, matching the pong golden's skip semantics.
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
