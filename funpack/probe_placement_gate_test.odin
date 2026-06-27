package funpack

import "core:testing"

@(test)
test_probe_placement_decl_prefix_on_behavior_passes :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"thing Ball { pos: Vec2, vel: Vec2 }\n" +
		"@break(self.pos.x > 70.0)\n" +
		"@log(self.pos)\n" +
		"@watch(self.vel)\n" +
		"@trace\n" +
		"behavior watched on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
}

@(test)
test_probe_placement_break_on_fn_rejected :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@break(speed > 70.0)\n" +
		"fn speed() -> Fixed {\n" +
		"  return 1.5\n" +
		"}\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "speed")
}

@(test)
test_probe_placement_log_on_let_rejected :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@log(BIAS)\n" +
		"let BIAS: Fixed = 0.25\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "BIAS")
}

@(test)
test_probe_placement_watch_on_thing_decl_rejected :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@watch(self.pos)\n" +
		"thing Marker { pos: Vec2 }\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "Marker")
}

@(test)
test_probe_placement_watch_on_signal_rejected :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@watch(self.side)\n" +
		"signal Goal { side: Side }\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "Goal")
}

@(test)
test_probe_placement_trace_on_query_rejected :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@trace\n" +
		"query q(origin: Vec2) -> Vec2 {\n" +
		"  return origin\n" +
		"}\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "q")
}

@(test)
test_probe_placement_trace_on_pipeline_decl_rejected :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@trace\n" +
		"pipeline Game {\n" +
		"  control: [move]\n" +
		"}\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "Game")
}

@(test)
test_probe_placement_watch_on_data_field_passes :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"data Board {\n" +
		"  @watch(self.bias)\n" +
		"  bias: Fixed\n" +
		"}\n")
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
}

@(test)
test_probe_placement_trace_on_stage_passes :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"pipeline Game {\n" +
		"  @trace\n" +
		"  control: [move]\n" +
		"}\n")
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
}

@(test)
test_probe_placement_probe_before_test_rejected :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@watch(score)\n" +
		"test \"watched\" {\n" +
		"  assert 1 == 1\n" +
		"}\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "watched")
}

@(test)
test_probe_placement_first_offender_is_source_order :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@log(a)\n" +
		"fn a() -> Fixed {\n" +
		"  return 1.5\n" +
		"}\n" +
		"@watch(self.side)\n" +
		"signal Goal { side: Side }\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "a")
}

@(test)
test_release_ban_catches_data_field_watch :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"data Board {\n" +
		"  @watch(self.bias)\n" +
		"  bias: Fixed\n" +
		"}\n")
	declaration, probed := release_debug_decl(ast)
	testing.expect(t, probed)
	testing.expect_value(t, declaration, "Board")
}

@(test)
test_release_ban_catches_stage_trace :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"pipeline Game {\n" +
		"  @trace\n" +
		"  control: [move]\n" +
		"}\n")
	declaration, probed := release_debug_decl(ast)
	testing.expect(t, probed)
	testing.expect_value(t, declaration, "Game")
}

@(test)
test_release_ban_field_watch_source_order_offender :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"fn clean() -> Fixed {\n" +
		"  return 1.5\n" +
		"}\n" +
		"data Board {\n" +
		"  @watch(self.bias)\n" +
		"  bias: Fixed\n" +
		"}\n")
	declaration, probed := release_debug_decl(ast)
	testing.expect(t, probed)
	testing.expect_value(t, declaration, "Board")
}

@(test)
test_index_projects_data_field_watch_onto_decl :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"data Board {\n" +
		"  @watch(self.bias)\n" +
		"  bias: Fixed\n" +
		"  h: Fixed\n" +
		"}\n")
	records := derive_decl_records("", Typed_Ast{ast = ast}, Flattened_Pipeline{})
	board, found := find_record(records, "Board")
	testing.expect(t, found)
	testing.expect_value(t, len(board.debug), 1)
	if len(board.debug) == 1 {
		testing.expect_value(t, board.debug[0], "watch")
	}
}

@(test)
test_index_projects_stage_trace_onto_pipeline :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"pipeline Game {\n" +
		"  @trace\n" +
		"  control: [move]\n" +
		"  @trace\n" +
		"  render: [draw]\n" +
		"  audio: [mix]\n" +
		"}\n")
	records := derive_decl_records("", Typed_Ast{ast = ast}, Flattened_Pipeline{})
	game, found := find_record(records, "Game")
	testing.expect(t, found)
	testing.expect_value(t, len(game.debug), 2)
	if len(game.debug) == 2 {
		testing.expect_value(t, game.debug[0], "trace")
		testing.expect_value(t, game.debug[1], "trace")
	}
}
