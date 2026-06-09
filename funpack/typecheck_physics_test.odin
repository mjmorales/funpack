// The §11 physics / §24 persistence surface-and-typecheck fixtures: the
// engine.physics Body record and its kind/shape enums, the .apply_impulse
// value method, the engine-routed Trigger signal, the physics `solve` battery;
// the engine.save Save/Restore/ApplySettings command constructors, the
// Result-wildcard outcome match, Settings.defaults plus the nested access/with;
// and the §11 §5 CollisionLayer registry gate. Each fixture is a small
// self-contained source over a yard-shaped header, so a missing golden checkout
// never silences the proofs — the live yard file lands in a later story. The
// negative fixtures pin the unregistered-layer reject, the unknown-battery
// reject, and the forced both-arm Result match.
package funpack

import "core:strings"
import "core:testing"

// PHYS_HEADER declares a yard-shaped surface independent of the golden checkout:
// the engine.physics and engine.save imports, the CollisionLayer-kinded Layer
// enum (Wall/Player/Crate/Pad), a Crate thing carrying a Body, a Menu singleton
// carrying Settings, and a Delivered signal. A fixture appends one fn/behavior
// body and types the whole source. Layer's role is CollisionLayer, so its
// variants are the registered layer set the §11 §5 gate proves against.
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

// pipeline_phys runs the whole test pipeline (gates + contracts + flatten) over
// the header plus a body, so the battery contract and Result exhaustiveness — a
// gate/contract reject, not a typecheck one — are exercised end to end.
pipeline_phys :: proc(body: string) -> Pipeline_Error {
	source := strings.concatenate({PHYS_HEADER, body}, context.temp_allocator)
	_, err := run_test_pipeline(source)
	return err
}

// -- (A) engine.physics: Body, BodyKind, Shape2, .apply_impulse, Trigger ------

@(test)
test_body_literal_types_against_surface_schema :: proc(t: ^testing.T) {
	// AC (engine.physics Body + BodyKind + Shape2 payload): a Body literal with a
	// BodyKind variant, a Shape2::Box{size} payload, Fixed scalars, and a
	// registered layer/mask checks clean against the closed surface schema.
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Dynamic, shape: Shape2::Box{size: Vec2{x: 12.0, y: 12.0}}, mass: 2.0, layer: Layer::Crate, mask: [Layer::Wall, Layer::Player] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_body_shape_circle_payload_typed :: proc(t: ^testing.T) {
	// AC (Shape2::Circle{radius:Fixed}): the Circle payload's radius field is
	// Fixed; a Fixed literal checks, distinct from Box's Vec2 size.
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Dynamic, shape: Shape2::Circle{radius: 5.0}, layer: Layer::Player, mask: [Layer::Wall] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_body_shape_circle_payload_wrong_type_rejected :: proc(t: ^testing.T) {
	// AC (payload field type enforced): a Vec2 where Circle's radius wants Fixed
	// is a Type_Mismatch — the struct-payload schema is checked, not waved through.
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Dynamic, shape: Shape2::Circle{radius: Vec2{x: 1.0, y: 0.0}}, layer: Layer::Player, mask: [Layer::Wall] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_apply_impulse_chains_returning_body :: proc(t: ^testing.T) {
	// AC (.apply_impulse(Vec2)->Body): the method takes a Vec2 and returns a
	// Body, so it chains (b.apply_impulse(j).apply_impulse(k)) and the result
	// flows back into a `self with { body: … }` update.
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
	// AC (apply_impulse arg is Vec2): a Fixed where it wants a Vec2 is a
	// Type_Mismatch — the method signature is checked, not opaque.
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
	// AC (Body field reads): self.body.shape reads the Body's Shape2 field; a fn
	// returning Shape2 from it types clean, so a behavior can dispatch on the
	// shape (yard's box_size).
	err := typecheck_phys(
		"fn shape_of(self: Crate) -> Shape2 {\n" +
		"  return self.body.shape\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_trigger_inbound_signal_typed :: proc(t: ^testing.T) {
	// AC (Trigger): a behavior consumes [Trigger] as an inbound signal list and
	// emits Despawn/Delivered — the §11 §4 optional inbound edge, like Contact.
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
	// AC (Shape2::Box{size} destructure): the struct-payload field-pun binds
	// `size` to Vec2 (carry-forward seam #1), so an arm returning that bound
	// `size` where the match's type is Vec2 unifies — proving the binder resolved
	// to Vec2, not the nil unknown.
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
	// AC (binder is really Vec2): the bound `size` flows into a Vec2 component
	// read (size.x), which only types if `size` is Vec2 — a stronger proof than
	// returning it through the nil-tolerant match unification.
	err := typecheck_phys(
		"fn box_width(shape: Shape2) -> Fixed {\n" +
		"  return match shape {\n" +
		"    Shape2::Box{size} => size.x\n" +
		"    _                 => 8.0\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

// -- (B) engine.save: commands, Result match, Settings.defaults/access/with ---

@(test)
test_save_command_constructor_types :: proc(t: ^testing.T) {
	// AC (Save{slot:String}): the Save command constructor takes a String slot
	// and a behavior emits [Save] — the §24 §1 command-out form.
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
	// AC (ApplySettings{settings:Settings}): the command carries the in-session
	// Settings value read off the Menu blackboard.
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
	// AC (Result-wildcard signals): an outcome signal's `result` field is a
	// Result matched Ok(_)/Err(_) with wildcard payloads, both arms returning the
	// Menu — the §24 forced both-arms match.
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
	// AC (forced both arms): a Result match covering only Ok is non-exhaustive —
	// a failed save can never be silently dropped (§24 §1, AX4). It is a gate
	// reject (Gate_Failed), distinct from a typecheck one.
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
	// AC (Settings.defaults()): the factory-default builder yields a Settings the
	// Menu singleton seeds with — a static method with no argument.
	err := typecheck_phys(
		"fn fresh() -> Settings {\n" +
		"  return Settings.defaults()\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_settings_nested_access_read_and_with :: proc(t: ^testing.T) {
	// AC (nested access read + nested with-update): settings.access.reduce_motion
	// reads the AccessOpts Bool, and `settings with {access: access with
	// {reduce_motion: …}}` rebuilds both records — the yard toggle_motion shape.
	err := typecheck_phys(
		"behavior toggle on Menu {\n" +
		"  fn step(self: Menu, input: Input) -> Menu {\n" +
		"    let access = self.settings.access with { reduce_motion: not self.settings.access.reduce_motion }\n" +
		"    return self with { settings: self.settings with { access: access }, dirty: true }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

// -- (C) CollisionLayer role kind + the §11 §5 registry gate ------------------

@(test)
test_registered_layer_passes :: proc(t: ^testing.T) {
	// AC (registered layer passes): a Body whose layer/mask name variants of the
	// CollisionLayer-kinded Layer enum (Wall/Player/Crate/Pad) is accepted.
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Wall, mask: [Layer::Player, Layer::Crate] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_unregistered_layer_in_layer_field_rejected :: proc(t: ^testing.T) {
	// AC (unregistered layer is a compile error): a Body whose `layer` names a
	// value outside the CollisionLayer enum's variant set fails the §11 §5
	// registry gate with the layer-registry diagnostic.
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Ghost, mask: [Layer::Player] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Unregistered_Layer)
}

@(test)
test_unregistered_layer_in_mask_rejected :: proc(t: ^testing.T) {
	// AC (mask gated too): an unregistered layer in the mask list is rejected,
	// not only the single `layer` field — the gate walks both.
	err := typecheck_phys(
		"fn make() -> Body {\n" +
		"  return Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Wall, mask: [Layer::Player, Layer::Ghost] }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Unregistered_Layer)
}

@(test)
test_layer_unregistered_without_collisionlayer_enum :: proc(t: ^testing.T) {
	// AC (registry is the CollisionLayer set, not just any enum): with NO
	// CollisionLayer-kinded enum declared, the registry is empty, so any Body
	// layer reference is unregistered — a plain `enum Layer { … }` (no role) does
	// not register its variants as collision layers.
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
	// A holed decl's body is empty, but its @stub(T, fallback) approximation is
	// still an expression position the §11 §5 registry gate walks — a Body
	// literal inside a fallback cannot smuggle an unregistered layer past the
	// gate (the hole exempts the body walk, never the fallback).
	err := typecheck_phys(
		"fn make() -> Body @stub(Body, Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Ghost, mask: [Layer::Player] })\n")
	testing.expect_value(t, err, Type_Error.Unregistered_Layer)
}

@(test)
test_registered_layer_in_stub_fallback_typechecks :: proc(t: ^testing.T) {
	// The positive half: a fallback Body literal whose layer/mask stay inside
	// the registered set walks the gate clean and the whole holed decl
	// typechecks (the fallback also unifies with the hole's declared Body).
	err := typecheck_phys(
		"fn make() -> Body @stub(Body, Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Wall, mask: [Layer::Player] })\n")
	testing.expect_value(t, err, Type_Error.None)
}

// -- (C.2) the §11 §4 engine-routed signal-name reservation -------------------

@(test)
test_user_signal_named_trigger_rejected :: proc(t: ^testing.T) {
	// AC (Trigger is engine-reserved): a user `signal Trigger {}` is rejected at
	// declaration even though the source never imports engine.physics — the gap
	// the reservation closes: without the import no Name_Collision fires, yet the
	// runtime's per-instance routing keys on the literal name, so the user signal
	// would silently never broadcast.
	source := "signal Trigger {}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.Reserved_Signal_Name)
}

@(test)
test_user_signal_named_contact_rejected :: proc(t: ^testing.T) {
	// AC (Contact reserved too): the reservation covers the whole engine-routed
	// set, not just Trigger.
	source := "signal Contact {}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.Reserved_Signal_Name)
}

@(test)
test_reserved_signal_diagnostic_wins_over_collision :: proc(t: ^testing.T) {
	// AC (precise diagnostic first): with engine.physics.Trigger imported, a user
	// `signal Trigger {}` surfaces as Reserved_Signal_Name — the reservation runs
	// before the collision claim, so the precise §11 §4 diagnostic wins over the
	// generic Name_Collision (the layer-gate precision-first ordering).
	err := typecheck_phys("signal Trigger {}\n")
	testing.expect_value(t, err, Type_Error.Reserved_Signal_Name)
}

@(test)
test_ordinary_user_signal_passes_reservation :: proc(t: ^testing.T) {
	// AC (reservation is exact-match): an ordinary user signal — including one
	// merely PREFIXED with a routed name — declares clean; only the two literal
	// engine-routed names are reserved.
	source := "signal TriggerHappy {}\nsignal Scored {}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)
}

// -- (D) the bare-battery `physics: solve` stage -----------------------------

@(test)
test_known_battery_solve_passes :: proc(t: ^testing.T) {
	// AC (battery name resolves): a `physics: solve` bare-battery stage names the
	// known engine battery `solve`, so the pipeline's contract check accepts it.
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
	// AC (unknown battery is a compile error): a bare-battery stage naming a
	// battery outside the engine set (`integrate`, not `solve`) is a contract
	// reject (Contract_Failed) — carry-forward seam #2.
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
