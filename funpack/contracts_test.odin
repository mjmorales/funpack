package funpack

import "core:strings"
import "core:testing"

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
	source, ok := pong_source()
	if !ok {
		return
	}
	verdict := contracts_of(source)
	testing.expect_value(t, verdict.err, Contract_Error.None)
}

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
	testing.expect(t, is_any_command_list(list_of(engine_type_of(.Spawn))))
	testing.expect(t, is_any_command_list(list_of(engine_type_of(.Despawn))))
	testing.expect(t, is_any_command_list(list_of(engine_type_of(.Draw))))
	testing.expect(t, is_any_command_list(list_of(engine_type_of(.Sound))))
	testing.expect(t, !is_any_command_list(list_of(user_type_of("Goal", .Signal))))
	testing.expect(t, !is_any_command_list(Ground_Type.Int))
}

@(test)
test_write_of_return_unwraps_command_tail :: proc(t: ^testing.T) {
	spawn_list := list_of(engine_type_of(.Spawn))
	rng := engine_type_of(.Rng)
	tuple_with_spawn := tuple_of({rng, spawn_list})
	unwrapped := write_of_return(tuple_with_spawn)
	testing.expect(t, is_command_list(unwrapped, .Spawn))

	testing.expect(t, is_command_list(write_of_return(spawn_list), .Spawn))

	scalar_tuple := tuple_of({rng, Ground_Type.Int})
	passed := write_of_return(scalar_tuple)
	testing.expect(t, !is_any_command_list(passed))
	testing.expect(t, !is_signal_list(passed))
}

@(test)
test_slot_of_stage_classification :: proc(t: ^testing.T) {
	testing.expect_value(t, slot_of_stage("startup"), Pipeline_Slot.Startup)
	testing.expect_value(t, slot_of_stage("render"), Pipeline_Slot.Render)
	testing.expect_value(t, slot_of_stage("ui"), Pipeline_Slot.Ui)
	testing.expect_value(t, slot_of_stage("audio"), Pipeline_Slot.Audio)
	testing.expect_value(t, slot_of_stage("control"), Pipeline_Slot.Update)
	testing.expect_value(t, slot_of_stage("collision"), Pipeline_Slot.Update)
	testing.expect_value(t, slot_of_stage("scoring"), Pipeline_Slot.Update)
}
