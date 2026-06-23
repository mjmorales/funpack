// The §06 §6 behavior-contract node-check fixtures: the pong golden clears
// the node-check with every behavior classified into its pipeline slot and
// validated against that slot's allowed inputs/returns, and the negative
// fixtures — a render-slot behavior emitting a signal, a render-slot behavior
// taking an inbound signal, a render-slot behavior taking an Rng resource, and
// a startup-slot behavior reading an unspawned thing — each reject at the
// contract stage with the diagnostic naming the behavior. The snake/hunt
// admission fixtures (CONTRACT_SIM_HEADER) clear the Startup/Update contracts on
// the RNG-threaded tuple write `(Rng, [Spawn])` and the [Despawn] command
// write, and pin that a tuple with no command/signal position is still dead
// code. The positive golden fixture reads the live pong golden (the
// load-bearing surface); the negative and snake/hunt fixtures are small
// self-contained sources, so a missing golden checkout never silences the
// proofs.
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

// CONTRACT_SIM_HEADER declares the snake/hunt-shaped surface the new slot
// fixtures need: the engine.rand Rng handle, the §04 Spawn/Despawn commands, a
// Snake thing the Update/Startup behaviors write, and a Food thing a Spawn
// carries. It is the contract-stage analogue of typecheck_sim_test's SIM_HEADER,
// scoped to just the imports/declarations the slot fixtures reference, so a
// missing golden checkout never silences these node-check proofs.
CONTRACT_SIM_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.world.{View, Spawn, Despawn}\n" +
	"import engine.render.{Draw, Color}\n" +
	"import engine.rand.{Rng}\n" +
	"data Cell { x: Int, y: Int }\n" +
	"thing Snake { head: Cell = Cell{x: 0, y: 0} }\n" +
	"thing Food { cell: Cell }\n"

contract_sim :: proc(body: string) -> Contract_Verdict {
	source := strings.concatenate({CONTRACT_SIM_HEADER, body}, context.temp_allocator)
	return contracts_of(source)
}

@(test)
test_contract_render_taking_rng_rejected :: proc(t: ^testing.T) {
	// AC (§06 render-slot Rng rejection): a render-slot behavior with an Rng
	// resource param rejects — Render is the deterministic projection stage, so
	// threading the RNG into it is forbidden (a frame's pixels are a pure
	// function of the world). The diagnostic names the behavior, distinct from
	// the inbound-signal reject. This is the epic's named render-slot node check
	// that the signal-only param loop did not yet cover.
	verdict := contract_sim(
		"behavior draw_snake on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> [Draw] {\n" +
		"    return [Draw::Rect{at: Vec2{x: 0.0, y: 0.0}, size: Vec2{x: 4.0, y: 4.0}, color: Color::White}]\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  render: [draw_snake]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.Render_Takes_Rng)
	testing.expect_value(t, verdict.behavior, "draw_snake")
}

@(test)
test_contract_startup_tuple_spawn_clears :: proc(t: ^testing.T) {
	// AC (startup-tuple accept): the RNG-threaded startup form — setup returning
	// the §04 §1 pair `(Rng, [Spawn])` with an rng: Rng engine-resource param —
	// clears the Startup contract. The tuple return is unwrapped to its [Spawn]
	// write position (write_of_return), and the rng param is a permitted engine
	// resource read, not an unspawned-thing read. This is snake's setup shape.
	verdict := contract_sim(
		"behavior setup on Snake {\n" +
		"  fn step(rng: Rng) -> (Rng, [Spawn]) {\n" +
		"    return (rng, [Spawn( Food{cell: Cell{x: 0, y: 0}} )])\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  startup: [setup]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.None)
}

@(test)
test_contract_update_tuple_spawn_is_write :: proc(t: ^testing.T) {
	// AC (update-tuple accept): snake's replenish is an interior-stage behavior
	// whose write is the §04 §1 pair `(Rng, [Spawn])`. check_update unwraps the
	// tuple to its [Spawn] command position and counts it as a write, not dead
	// code — so the RNG-threaded eat-stage behavior clears the Update contract.
	verdict := contract_sim(
		"behavior replenish on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> (Rng, [Spawn]) {\n" +
		"    return (rng, [Spawn( Food{cell: self.head} )])\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  eat: [replenish]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.None)
}

@(test)
test_contract_update_despawn_is_write :: proc(t: ^testing.T) {
	// AC (Despawn engine command): a [Despawn] return is recognized as an
	// engine-consumed command write — is_any_command_list admits Despawn
	// alongside Spawn/Draw — so an Update behavior returning [Despawn] clears the
	// write obligation. This is snake's despawn_eaten shape on the contract side,
	// the counterpart to surface.odin's Despawn admission.
	verdict := contract_sim(
		"behavior despawn_eaten on Food {\n" +
		"  fn step(self: Food) -> [Despawn] {\n" +
		"    return [Despawn()]\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  eat: [despawn_eaten]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.None)
}

@(test)
test_contract_update_tuple_self_rng_is_write :: proc(t: ^testing.T) {
	// AC (§04 §1 self+rng accept; ADR self-rng-is-a-legal-update-return-shape): an
	// interior-stage behavior that rewrites its own blackboard AND threads the Rng
	// it consumed returns `(Self, Rng)`. check_update recognizes the own-blackboard
	// `Self` slot of the tuple as a real write via writes_own_blackboard_in_return,
	// so the self-updating RNG-consuming behavior clears the Update contract. The
	// dead-code hole this pins shut: the `Self` slot was recognized only when its
	// sibling was a list, never when the sibling was the non-list Rng.
	verdict := contract_sim(
		"behavior wander on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> (Snake, Rng) {\n" +
		"    return (self with { head: Cell{x: 1, y: 0} }, rng)\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  eat: [wander]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.None)
}

@(test)
test_contract_update_tuple_rng_self_is_write :: proc(t: ^testing.T) {
	// AC (slot-order independence): the flipped `(Rng, Self)` shape clears the
	// Update contract exactly as `(Self, Rng)` does — writes_own_blackboard_in_return
	// scans BOTH tuple positions for the own-blackboard write, so the threaded-Rng
	// position is order-irrelevant. The flip must accept identically to `(Self, Rng)`;
	// both rejected identically while the dead-code hole stood.
	verdict := contract_sim(
		"behavior wander on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> (Rng, Snake) {\n" +
		"    return (rng, self with { head: Cell{x: 1, y: 0} })\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  eat: [wander]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.None)
}

@(test)
test_contract_update_tuple_no_command_is_dead :: proc(t: ^testing.T) {
	// AC (write_of_return falls through; the gate's true-positive is preserved): a
	// tuple return with NO command/signal position AND no own-blackboard position —
	// `(Rng, Int)` — carries no write, so check_update rejects it as Update_Dead.
	// The self+rng accept (writes_own_blackboard_in_return) admits a tuple with an
	// own-blackboard OR command/signal-list position WITHOUT admitting every tuple
	// as a write; a tuple that threads only non-write scalars is still dead code.
	// This is the genuinely-dead case the fix must keep catching.
	verdict := contract_sim(
		"behavior bad_update on Snake {\n" +
		"  fn step(self: Snake, rng: Rng) -> (Rng, Int) {\n" +
		"    return (rng, 0)\n" +
		"  }\n" +
		"}\n" +
		"pipeline Game {\n" +
		"  eat: [bad_update]\n" +
		"}\n")
	testing.expect_value(t, verdict.err, Contract_Error.Update_Dead)
	testing.expect_value(t, verdict.behavior, "bad_update")
}

@(test)
test_is_any_command_list_admits_despawn :: proc(t: ^testing.T) {
	// AC (is_any_command_list over the closed engine-command set): the set has
	// grown to {Spawn, Despawn, Draw, Save, Restore, ApplySettings, Sound}, so
	// is_any_command_list returns true for each fire-and-forget command list and
	// false for a signal list and a bare scalar. Sound is the §22 §1 one-shot an
	// Update behavior emits like Spawn/Draw (pickups' `(Coin, [Sound])`). This pins
	// the unit predicate the Render/Update contracts share, independent of any
	// source fixture.
	testing.expect(t, is_any_command_list(list_of(engine_type_of(.Spawn))))
	testing.expect(t, is_any_command_list(list_of(engine_type_of(.Despawn))))
	testing.expect(t, is_any_command_list(list_of(engine_type_of(.Draw))))
	testing.expect(t, is_any_command_list(list_of(engine_type_of(.Sound))))
	testing.expect(t, !is_any_command_list(list_of(user_type_of("Goal", .Signal))))
	testing.expect(t, !is_any_command_list(Ground_Type.Int))
}

@(test)
test_write_of_return_unwraps_command_tail :: proc(t: ^testing.T) {
	// The write-position extraction the node check rides: write_of_return pulls
	// the command/signal-list element out of an RNG-threaded tuple `(Rng,
	// [Spawn])` and passes a plain return through unchanged. A tuple with no
	// command/signal position — `(Rng, Int)` — passes through unchanged, so the
	// contract check rejects it rather than treating an arbitrary tuple as a
	// write.
	spawn_list := list_of(engine_type_of(.Spawn))
	rng := engine_type_of(.Rng)
	tuple_with_spawn := tuple_of({rng, spawn_list})
	unwrapped := write_of_return(tuple_with_spawn)
	testing.expect(t, is_command_list(unwrapped, .Spawn))

	// A plain (non-tuple) return is its own write.
	testing.expect(t, is_command_list(write_of_return(spawn_list), .Spawn))

	// A tuple of only scalars carries no write: it passes through as the tuple
	// itself, which is neither a command nor signal list.
	scalar_tuple := tuple_of({rng, Ground_Type.Int})
	passed := write_of_return(scalar_tuple)
	testing.expect(t, !is_any_command_list(passed))
	testing.expect(t, !is_signal_list(passed))
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
