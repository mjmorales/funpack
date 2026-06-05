// The §06 §6 behavior-contract node-check fixtures: the pong golden clears
// the node-check with every behavior classified into its pipeline slot and
// validated against that slot's allowed inputs/returns, and the negative
// fixtures — a render-slot behavior emitting a signal, a render-slot behavior
// taking an inbound signal, and a startup-slot behavior reading an unspawned
// thing — each reject at the contract stage with the diagnostic naming the
// behavior. The positive fixture reads the live pong golden (the load-bearing
// surface); the negative fixtures are small self-contained sources, so a
// missing golden checkout never silences the rejection proofs.
package funpack

import "core:strings"
import "core:testing"

// contracts_of resolves and typechecks a source, then runs the contract node
// check, returning its verdict. A parse/typecheck failure surfaces as a
// None-behavior verdict with a synthetic error so a malformed fixture is
// visibly distinct from a clean contract pass; the negative fixtures all
// typecheck clean and reject only at the contract stage.
contracts_of :: proc(source: string) -> Contract_Verdict {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Contract_Verdict{err = .Render_No_Draw, behavior = "<parse-failed>"}
	}
	typed, type_err := stage_typecheck(ast)
	if type_err != .None {
		return Contract_Verdict{err = .Render_No_Draw, behavior = "<typecheck-failed>"}
	}
	return stage_contracts(typed)
}

@(test)
test_pong_golden_clears_node_check :: proc(t: ^testing.T) {
	// AC: the full pong source clears the behavior-contract node check — every
	// pipeline-slot occupant classifies into its slot and its signature
	// validates against that slot's allowed inputs/returns. setup() in the
	// startup slot returns [Spawn] reading no thing; the control/collision/
	// scoring Update behaviors each write their blackboard or emit a list; the
	// render behaviors each return only [Draw] taking no signal. The fixture
	// reads the live golden source and SKIPs loudly when absent.
	source, ok := pong_source()
	if !ok {
		return
	}
	verdict := contracts_of(source)
	testing.expect_value(t, verdict.err, Contract_Error.None)
}

// CONTRACT_UNIT_HEADER declares the minimal surface a negative contract
// fixture needs: the engine imports, a Paddle thing to read/write, and a Goal
// signal to emit or consume. A fixture appends its violating behavior and the
// pipeline that places it in a slot.
CONTRACT_UNIT_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.world.{View, Spawn}\n" +
	"import engine.render.{Draw, Color}\n" +
	"thing Paddle { x: Fixed, y: Fixed }\n" +
	"signal Goal { side: Fixed }\n"

contract_unit :: proc(body: string) -> Contract_Verdict {
	source := strings.concatenate({CONTRACT_UNIT_HEADER, body}, context.temp_allocator)
	return contracts_of(source)
}

@(test)
test_contract_unit_positive_render_clears :: proc(t: ^testing.T) {
	// The control for the render negatives: a behavior on Paddle in the render
	// slot that returns a [Draw] list, reading no signal, clears the contract —
	// so each render negative rejects for its named reason, not an incidental
	// header gap.
	verdict := contract_unit(
		"behavior draw_paddle on Paddle {\n" +
		"  fn step(self: Paddle) -> [Draw] {\n" +
		"    return [Draw::Rect{at: Vec2{x: self.x, y: self.y}, size: Vec2{x: 4.0, y: 16.0}, color: Color::White}]\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  render: [draw_paddle]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.None)
}

@(test)
test_contract_render_emitting_signal_rejected :: proc(t: ^testing.T) {
	// AC (render emits): a render-slot behavior returning a [Goal] signal list
	// rejects — Render is output-only, only [Draw] may leave it. The diagnostic
	// names the behavior, not the slot.
	verdict := contract_unit(
		"behavior bad_render on Paddle {\n" +
		"  fn step(self: Paddle) -> [Goal] {\n" +
		"    return [Goal{side: self.x}]\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  render: [bad_render]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.Render_Emits)
	testing.expect_value(t, verdict.behavior, "bad_render")
}

@(test)
test_contract_render_taking_signal_rejected :: proc(t: ^testing.T) {
	// AC (render takes an inbound signal): a render-slot behavior with an
	// inbound [Goal] param rejects — Render has no inbound signal edge (that is
	// exactly why Ui, not Render, owns the one inbound visual contract). The
	// diagnostic names the behavior.
	verdict := contract_unit(
		"behavior bad_render on Paddle {\n" +
		"  fn step(self: Paddle, goals: [Goal]) -> [Draw] {\n" +
		"    return [Draw::Rect{at: Vec2{x: self.x, y: self.y}, size: Vec2{x: 4.0, y: 16.0}, color: Color::White}]\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  render: [bad_render]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.Render_Takes_Signal)
	testing.expect_value(t, verdict.behavior, "bad_render")
}

@(test)
test_contract_startup_reading_thing_rejected :: proc(t: ^testing.T) {
	// AC (startup reads an unspawned thing): a startup-slot behavior whose step
	// reads a Paddle blackboard rejects — a startup occupant reads engine
	// resources only, never an unspawned thing (nothing is spawned before tick
	// 0). The diagnostic names the behavior.
	verdict := contract_unit(
		"behavior bad_startup on Paddle {\n" +
		"  fn step(self: Paddle) -> [Spawn] {\n" +
		"    return [Spawn(Paddle{x: 0.0, y: 0.0})]\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  startup: [bad_startup]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.Startup_Reads_Thing)
	testing.expect_value(t, verdict.behavior, "bad_startup")
}

@(test)
test_contract_unplaced_behavior_takes_no_contract :: proc(t: ^testing.T) {
	// The slot-conferred boundary: a behavior in NO pipeline stage takes on no
	// contract (spec §06 §6 — a behavior is constrained only by occupying a
	// slot). The same render-emitting-a-signal shape that rejects in the render
	// slot clears here because no pipeline lists it.
	verdict := contract_unit(
		"behavior unplaced on Paddle {\n" +
		"  fn step(self: Paddle) -> [Goal] {\n" +
		"    return [Goal{side: self.x}]\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.None)
}

@(test)
test_pipeline_contract_violation_is_contract_failed :: proc(t: ^testing.T) {
	// Through the whole pipeline a slot-contract violation rejects as
	// Contract_Failed — a compile error after typecheck, distinct from a gate
	// or typecheck failure. The render behavior emitting a [Goal] reaches the
	// contract stage (it parses, gates, and typechecks clean) and is rejected
	// there. This pins the stage's wiring into run_test_pipeline.
	source := strings.concatenate({CONTRACT_UNIT_HEADER,
		"behavior bad_render on Paddle {\n" +
		"  fn step(self: Paddle) -> [Goal] {\n" +
		"    return [Goal{side: self.x}]\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  render: [bad_render]\n" +
		"}\n"}, context.temp_allocator)
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Contract_Failed)
}

@(test)
test_pong_golden_compiles_clean_through_contracts :: proc(t: ^testing.T) {
	// The full pong golden compiles clean through every static stage — lex,
	// parse, gates, typecheck, contracts: run_test_pipeline returns no compile
	// error, so the contract stage (like the gate and typecheck stages before
	// it) is transparent to the well-formed gameplay surface. The verdict is
	// never one of the four compile-error arms; the evaluator path for the
	// behavior-invocation/match assert forms is downstream work, so the
	// inline-assert evaluation outcome is not this node-check's concern.
	source, ok := pong_source()
	if !ok {
		return
	}
	_, err := run_test_pipeline(source)
	testing.expect(t, err != Pipeline_Error.Parse_Failed)
	testing.expect(t, err != Pipeline_Error.Gate_Failed)
	testing.expect(t, err != Pipeline_Error.Typecheck_Failed)
	testing.expect(t, err != Pipeline_Error.Contract_Failed)
}

@(test)
test_slot_of_stage_classification :: proc(t: ^testing.T) {
	// The slot classifier pins the reserved stage names: startup/render/ui/audio
	// confer their named slots, and every other (interior) stage name is Update
	// (spec §07 §1: terminal projection stages are reserved, interiors are
	// Update).
	testing.expect_value(t, slot_of_stage("startup"), Pipeline_Slot.Startup)
	testing.expect_value(t, slot_of_stage("render"), Pipeline_Slot.Render)
	testing.expect_value(t, slot_of_stage("ui"), Pipeline_Slot.Ui)
	testing.expect_value(t, slot_of_stage("audio"), Pipeline_Slot.Audio)
	testing.expect_value(t, slot_of_stage("control"), Pipeline_Slot.Update)
	testing.expect_value(t, slot_of_stage("collision"), Pipeline_Slot.Update)
	testing.expect_value(t, slot_of_stage("scoring"), Pipeline_Slot.Update)
}
