package funpack

import "core:testing"

typecheck_probe :: proc(t: ^testing.T, source: string) -> Type_Error {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return .None
	}
	_, err := stage_typecheck(ast)
	return err
}

PROBE_UNIT_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"thing Ball { pos: Vec2, vel: Vec2 }\n"

@(test)
test_probe_behavior_watch_self_field_typechecks :: proc(t: ^testing.T) {
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@watch(self.pos)\n" +
		"behavior watched on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_probe_behavior_break_predicate_typechecks :: proc(t: ^testing.T) {
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@break(self.pos.x > 70.0)\n" +
		"behavior breaker on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_probe_behavior_watch_out_of_scope_name_rejected :: proc(t: ^testing.T) {
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@watch(self.missing)\n" +
		"behavior watched on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_probe_behavior_log_unresolved_name_rejected :: proc(t: ^testing.T) {
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@log(ghost)\n" +
		"behavior logger on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Unresolved_Name)
}

@(test)
test_probe_data_field_watch_self_field_typechecks :: proc(t: ^testing.T) {
	err := typecheck_probe(t,
		"data Board {\n" +
		"  @watch(self.bias)\n" +
		"  bias: Fixed\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_probe_data_field_watch_unknown_field_rejected :: proc(t: ^testing.T) {
	err := typecheck_probe(t,
		"data Board {\n" +
		"  @watch(self.drift)\n" +
		"  bias: Fixed\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_probe_data_field_watch_bare_name_rejected :: proc(t: ^testing.T) {
	err := typecheck_probe(t,
		"data Board {\n" +
		"  @watch(bias)\n" +
		"  bias: Fixed\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Unresolved_Name)
}

@(test)
test_probe_trace_no_argument_typechecks :: proc(t: ^testing.T) {
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@trace\n" +
		"behavior traced on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}
