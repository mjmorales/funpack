package funpack

import "core:strings"
import "core:testing"

PHYS_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.world.{Spawn, Despawn, View}\n" +
	"import engine.input.{Input, PlayerId}\n" +
	"import engine.physics.{Body, BodyKind, Shape2, Trigger, solve}\n" +
	"import engine.save.{Save, Restore, ApplySettings, Saved, Restored, SettingsApplied, Settings}\n" +
	"import engine.list.{is_empty, fold}\n" +
	"enum Layer: CollisionLayer { Wall, Player, Crate, Pad }\n" +
	"thing Crate { pos: Vec2, vel: Vec2, body: Body }\n" +
	"singleton Menu { settings: Settings = Settings.defaults(), dirty: Bool = false, status: Option[String] = Option::None }\n" +
	"signal Delivered {}\n"

typecheck_phys :: proc(body: string) -> Type_Error {
	source := strings.concatenate({PHYS_HEADER, body}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

pipeline_phys :: proc(body: string) -> Pipeline_Error {
	source := strings.concatenate({PHYS_HEADER, body}, context.temp_allocator)
	_, err := run_test_pipeline(source)
	return err
}

@(test)
test_body_literal_types_against_surface_schema :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Dynamic, shape: Shape2::Box{size: Vec2{x: 12.0, y: 12.0}}, mass: 2.0, layer: Layer::Crate, mask: [Layer::Wall, Layer::Player] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_body_shape_circle_payload_typed :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Dynamic, shape: Shape2::Circle{radius: 5.0}, layer: Layer::Player, mask: [Layer::Wall] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_body_shape_circle_payload_wrong_type_rejected :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Dynamic, shape: Shape2::Circle{radius: Vec2{x: 1.0, y: 0.0}}, layer: Layer::Player, mask: [Layer::Wall] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_apply_impulse_chains_returning_body :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"behavior drive on Crate {\n" +
		"  fn step(self: Crate, push: Vec2) -> Crate {\n" +
		"    return self with { body: self.body.apply_impulse(push).apply_impulse(push) }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_apply_impulse_wrong_arg_rejected :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"behavior drive on Crate {\n" +
		"  fn step(self: Crate, push: Fixed) -> Crate {\n" +
		"    return self with { body: self.body.apply_impulse(push) }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_body_shape_field_read_types :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn shape_of(self: Crate) -> Shape2 {\n" +
		"  return self.body.shape\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_trigger_inbound_signal_typed :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"behavior deliver on Crate {\n" +
		"  fn step(self: Crate, pads: [Trigger]) -> ([Despawn], [Delivered]) {\n" +
		"    if is_empty(pads) { return ([], []) }\n" +
		"    return ([Despawn()], [Delivered{}])\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_shape2_box_pattern_binds_size_vec2 :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn box_size(shape: Shape2) -> Vec2 {\n" +
		"  return match shape {\n" +
		"    Shape2::Box{size} => size\n" +
		"    _                 => Vec2{x: 8.0, y: 8.0}\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_shape2_box_bound_size_used_as_vec2 :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn box_width(shape: Shape2) -> Fixed {\n" +
		"  return match shape {\n" +
		"    Shape2::Box{size} => size.x\n" +
		"    _                 => 8.0\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_save_command_constructor_types :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"behavior save_key on Menu {\n" +
		"  fn step(self: Menu, input: Input) -> [Save] {\n" +
		"    return [Save{slot: \"quicksave\"}]\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_apply_settings_command_carries_settings :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"behavior apply_settings on Menu {\n" +
		"  fn step(self: Menu, input: Input) -> [ApplySettings] {\n" +
		"    return [ApplySettings{settings: self.settings}]\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_result_outcome_match_both_arms_types :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"behavior on_persist_result on Menu {\n" +
		"  fn step(self: Menu, saved: [Saved]) -> Menu {\n" +
		"    return fold(saved, self, fn(m, r) {\n" +
		"      return match r.result {\n" +
		"        Result::Ok(_)  => m with { status: Option::Some(\"saved\") }\n" +
		"        Result::Err(_) => m with { status: Option::Some(\"failed\") }\n" +
		"      }\n" +
		"    })\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_result_match_one_arm_rejected :: proc(t: ^testing.T) {
	err := pipeline_phys(
		"behavior on_persist_result on Menu {\n" +
		"  fn step(self: Menu, saved: [Saved]) -> Menu {\n" +
		"    return fold(saved, self, fn(m, r) {\n" +
		"      return match r.result {\n" +
		"        Result::Ok(_) => m with { status: Option::Some(\"saved\") }\n" +
		"      }\n" +
		"    })\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_settings_defaults_static_builder_types :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn fresh() -> Settings {\n" +
		"  return Settings.defaults()\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_settings_nested_access_read_and_with :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"behavior toggle on Menu {\n" +
		"  fn step(self: Menu, input: Input) -> Menu {\n" +
		"    let access = self.settings.access with { reduce_motion: not self.settings.access.reduce_motion }\n" +
		"    return self with { settings: self.settings with { access: access }, dirty: true }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_registered_layer_passes :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Wall, mask: [Layer::Player, Layer::Crate] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_unregistered_layer_in_layer_field_rejected :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Ghost, mask: [Layer::Player] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Unregistered_Layer)
}

@(test)
test_unregistered_layer_in_mask_rejected :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Wall, mask: [Layer::Player, Layer::Ghost] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Unregistered_Layer)
}

@(test)
test_layer_unregistered_without_collisionlayer_enum :: proc(t: ^testing.T) {
	source := "import engine.math.{Fixed, Vec2}\n" +
		"import engine.physics.{Body, BodyKind, Shape2, solve}\n" +
		"enum Layer { Wall, Player }\n" +
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Wall, mask: [Layer::Player] }\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.Unregistered_Layer)
}

@(test)
test_unregistered_layer_in_stub_fallback_rejected :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn make() -> Body @stub(Body, Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Ghost, mask: [Layer::Player] })\n")
	testing.expect_value(t, err, Type_Error.Unregistered_Layer)
}

@(test)
test_registered_layer_in_stub_fallback_typechecks :: proc(t: ^testing.T) {
	err := typecheck_phys(
		"fn make() -> Body @stub(Body, Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Wall, mask: [Layer::Player] })\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_user_signal_named_trigger_rejected :: proc(t: ^testing.T) {
	source := "signal Trigger {}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.Reserved_Signal_Name)
}

@(test)
test_user_signal_named_contact_rejected :: proc(t: ^testing.T) {
	source := "signal Contact {}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.Reserved_Signal_Name)
}

@(test)
test_reserved_signal_diagnostic_wins_over_collision :: proc(t: ^testing.T) {
	err := typecheck_phys("signal Trigger {}\n")
	testing.expect_value(t, err, Type_Error.Reserved_Signal_Name)
}

@(test)
test_ordinary_user_signal_passes_reservation :: proc(t: ^testing.T) {
	source := "signal TriggerHappy {}\nsignal Scored {}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_known_battery_solve_passes :: proc(t: ^testing.T) {
	err := pipeline_phys(
		"behavior tick on Crate {\n" +
		"  fn step(self: Crate, push: Vec2) -> Crate {\n" +
		"    return self with { body: self.body.apply_impulse(push) }\n" +
		"  }\n" +
		"}\n" +
		"pipeline Yard {\n" +
		"  control: [tick]\n" +
		"  physics: solve\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
}

@(test)
test_unknown_battery_rejected :: proc(t: ^testing.T) {
	err := pipeline_phys(
		"behavior tick on Crate {\n" +
		"  fn step(self: Crate, push: Vec2) -> Crate {\n" +
		"    return self with { body: self.body.apply_impulse(push) }\n" +
		"  }\n" +
		"}\n" +
		"pipeline Yard {\n" +
		"  control: [tick]\n" +
		"  physics: integrate\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.Contract_Failed)
}
