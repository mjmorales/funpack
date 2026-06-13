// The §28 §4 debug-probe placement gate (probe_placement_gate.odin): the
// On-table fixes which debug directive sits legally on which declaration kind,
// and the gate refuses a mis-placed probe with the named Probe_Wrong_Placement
// verdict. A DECLARATION-PREFIX probe is admitted only on a behavior; @watch
// also rides a `data` field and @trace also rides a pipeline stage (those
// sub-declaration positions the parser already gates, so they reach this gate
// already-legal). Pure-AST fixtures driven through stage_gates / gate_verdict,
// the query_index_gate.odin test mold; the verdict names the offending
// declaration, the agent-repair anchor.
//
// Two companion concerns are pinned here too: the §05 §5 / §28 §4 release ban
// (release_debug_decl) and the §29 §2 index derivation (derive_decl_records)
// must each ALSO see a `data`-field @watch and a pipeline-stage @trace — the
// folded-in field/stage probe positions — so a field @watch / stage @trace can
// no more slip through a --release build or out of the index than a
// declaration-prefix probe can (§28 §4: the operator sees every outstanding
// probe; debug residue can neither ship nor rot).
package funpack

import "core:testing"

@(test)
test_probe_placement_decl_prefix_on_behavior_passes :: proc(t: ^testing.T) {
	// AC: a declaration-prefix probe on a BEHAVIOR is the On-table's one legal
	// declaration-prefix placement for every directive, so all four clear the
	// gate clean.
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
	// AC (On-table: @break sits on a behavior): a declaration-prefix @break on a
	// fn is the named Probe_Wrong_Placement, naming the offending fn.
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
	// AC (On-table: @log sits on a behavior): a declaration-prefix @log on a
	// module-level `let` is Probe_Wrong_Placement, naming the let.
	ast := parse_for_gate(t,
		"@log(BIAS)\n" +
		"let BIAS: Fixed = 0.25\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "BIAS")
}

@(test)
test_probe_placement_watch_on_thing_decl_rejected :: proc(t: ^testing.T) {
	// AC (On-table: @watch sits on a behavior OR a `data` FIELD — never a `thing`
	// DECLARATION): a declaration-prefix @watch on a thing is
	// Probe_Wrong_Placement (a `thing` is not a `data` record, and the
	// declaration-prefix position admits only a behavior), naming the thing.
	ast := parse_for_gate(t,
		"@watch(self.pos)\n" +
		"thing Marker { pos: Vec2 }\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "Marker")
}

@(test)
test_probe_placement_watch_on_signal_rejected :: proc(t: ^testing.T) {
	// AC (On-table): a declaration-prefix @watch on a signal is
	// Probe_Wrong_Placement — a signal is neither a behavior nor a `data` field.
	ast := parse_for_gate(t,
		"@watch(self.side)\n" +
		"signal Goal { side: Side }\n")
	verdict := gate_verdict(ast)
	testing.expect_value(t, verdict.err, Gate_Error.Probe_Wrong_Placement)
	testing.expect_value(t, verdict.declaration, "Goal")
}

@(test)
test_probe_placement_trace_on_query_rejected :: proc(t: ^testing.T) {
	// AC (On-table: @trace sits on a behavior OR a pipeline STAGE — never a
	// query): a declaration-prefix @trace on a query is Probe_Wrong_Placement,
	// naming the query.
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
	// AC (On-table: @trace sits on a STAGE, not the pipeline DECLARATION): a
	// declaration-prefix @trace on a pipeline is Probe_Wrong_Placement — the
	// stage @trace rides Pipeline_Stage.probes, not the Pipeline_Node prefix.
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
	// AC (On-table: @watch sits on a `data` field): a @watch prefixing a `data`
	// field is a LEGAL placement (the parser admits it onto Field_Decl.probes),
	// so the gate passes clean — the gate does not re-reject a parser-admitted
	// field probe.
	ast := parse_for_gate(t,
		"data Board {\n" +
		"  @watch(self.bias)\n" +
		"  bias: Fixed\n" +
		"}\n")
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
}

@(test)
test_probe_placement_trace_on_stage_passes :: proc(t: ^testing.T) {
	// AC (On-table: @trace sits on a pipeline stage): a @trace prefixing a stage
	// entry is a LEGAL placement (the parser admits it onto
	// Pipeline_Stage.probes), so the gate passes clean.
	ast := parse_for_gate(t,
		"pipeline Game {\n" +
		"  @trace\n" +
		"  control: [move]\n" +
		"}\n")
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
}

@(test)
test_probe_placement_probe_before_test_rejected :: proc(t: ^testing.T) {
	// AC (the test-block silent-drop fix): a §05 §5 debug probe before a test
	// block is NOT silently dropped — the parser carries it onto the test node
	// (a test is not in the §28 §4 On-table) so the placement gate names the
	// test, Probe_Wrong_Placement. A probe before a test vanishing rather than
	// erroring was the .Test arm's prior bug.
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
	// AC (first-offender determinism): with TWO mis-placed probes the gate names
	// the SOURCE-ORDER first offender (the same order the release walkers and the
	// index emit), so a multi-violation source is deterministic. Here the @log
	// fn precedes the @watch signal, so the fn is named.
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
	// AC (folded-in field-probe release ban): a @watch on a `data` FIELD is
	// release-banned the same as a declaration-prefix probe — release_debug_decl
	// names the carrying `data` declaration, so a field @watch cannot slip
	// through a --release build unbanned (§28 §4: debug residue cannot ship).
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
	// AC (folded-in stage-probe release ban): a @trace on a pipeline STAGE is
	// release-banned the same as a declaration-prefix probe — release_debug_decl
	// names the carrying pipeline declaration, so a stage @trace cannot slip
	// through a --release build unbanned.
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
	// AC (first-offender across positions): a probe-free declaration that
	// precedes a field-watch-carrying `data` is NOT the offender — the ban walks
	// source order and names the first declaration whose ANY position (prefix,
	// field, or stage) carries a probe. Here the leading probe-free fn is skipped
	// and the field-watch `data` is named.
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
	// AC (folded-in field-probe index): a @watch on a `data` field projects onto
	// the carrying `data` declaration's `debug` index field (the §29 §2 per-decl
	// debug list — derive_decl_records via decl_probes_with_fields), so a field
	// @watch surfaces in the index, never unindexed (§28 §4: the operator sees
	// every outstanding probe). A probe-free data field adds nothing.
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
	// AC (folded-in stage-probe index): a @trace on a pipeline STAGE projects
	// onto the carrying pipeline declaration's `debug` index field
	// (decl_probes_with_stages), so a stage @trace surfaces in the index, never
	// unindexed. Two traced stages report "trace" twice, never deduped (§28 §4),
	// in stage order; an untraced stage adds nothing.
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
