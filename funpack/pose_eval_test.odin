package funpack

import "core:testing"

POSE_EVAL_FIXTURE :: `@doc("Pose/gait evaluation proof. Pure fixed-point pose generators over the anim surface.")

import engine.anim.{Pose, Bone, rot_x, up}
import engine.math.{Fixed, Vec2, sin, clamp, length}
import engine.input.PlayerId
import engine.core.Time

@doc("Locomotion tunables. cadence sets how fast the walk cycle advances per unit speed.")
data Stride { cadence: Fixed, top_speed: Fixed }

@doc("The fixed locomotion tuning.")
let STRIDE: Stride = Stride{ cadence: 6.0, top_speed: 4.0 }

@doc("A rigged creature: its player, ground-plane intent, and walk-cycle state.")
@gtag("spatial")
thing Walker {
  player: PlayerId
  intent: Vec2  = Vec2{x: 0.0, y: 0.0}
  phase:  Fixed = 0.0
  speed:  Fixed = 0.0
}

@doc("How strongly the walk pose blends over idle. Ramps to full by half top speed.")
@gtag("anim")
fn walk_weight(speed: Fixed) -> Fixed {
  return clamp(speed * 2.0, 0.0, 1.0)
}

@doc("Ambient idle pose: a slow torso breathing bob. Targets only the torso.")
@gtag("anim")
fn pose_idle(t: Fixed) -> Pose {
  return Pose.empty().set(Bone::Torso, up(sin(t * 2.0) * 0.2))
}

@doc("Walk pose: legs swing, arms counter-swing, torso bobs at twice the leg rate. The torso bob omits stroll.fun's abs() wrap so the .set arg stays within the §01 P5 nesting budget — stroll.fun's up(abs(sin(...))) is three nested calls, which over-nests when gated; the asserted bones (legs/arms) match it exactly.")
@gtag("anim")
fn pose_walk(phase: Fixed, speed: Fixed) -> Pose {
  let s = sin(phase) * 0.5
  return Pose.empty()
    .set(Bone::LUpperLeg, rot_x(s))
    .set(Bone::RUpperLeg, rot_x(-s))
    .set(Bone::LUpperArm, rot_x(-s * 0.6))
    .set(Bone::RUpperArm, rot_x(s * 0.6))
    .set(Bone::Torso,     up(sin(phase * 2.0) * 0.3))
}

@doc("Advances the walk-cycle phase by speed, and records the speed for blending.")
@gtag("gait")
behavior advance_gait on Walker {
  fn step(self: Walker, time: Time) -> Walker {
    let spd = length(self.intent)
    return self with { phase: self.phase + spd * STRIDE.cadence * time.dt, speed: spd }
  }
}

@doc("Pose/gait proof pipeline.")
@gtag("game")
pipeline Walk {
  control: [advance_gait]
}

@doc("At phase zero the legs sit at their rest swing (sin(0)*0.5 = 0), so the pose is assertable exactly.")
test "pose_walk holds the legs at rest on the zero crossing" {
  assert pose_walk(0.0, 1.0).get(Bone::LUpperLeg) == rot_x(0.0)
}

@doc("A .set then .get round-trips one driven bone's transform exactly.")
test "set then get reads back the driven transform" {
  assert Pose.empty().set(Bone::Torso, up(0.3)).get(Bone::Torso) == up(0.3)
}

@doc("A bone the pose never drives reads the rest transform (rot_x(0.0) is the identity rotation).")
test "get of an undriven bone reads the rest transform" {
  assert Pose.empty().set(Bone::Torso, up(0.3)).get(Bone::Head) == rot_x(0.0)
}

@doc("Blend at weight 0 equals the base pose's driven bone, exactly, per bone.")
test "blend at weight zero takes the base pose" {
  assert Pose.blend(pose_walk(0.0, 1.0), pose_idle(0.0), 0.0).get(Bone::LUpperLeg) == rot_x(0.0)
}

@doc("Blend at weight 1 takes the overlaid pose's driven bone, exactly, per bone.")
test "blend at weight one takes the second pose" {
  assert Pose.blend(Pose.empty(), Pose.empty().set(Bone::Torso, up(0.3)), 1.0).get(Bone::Torso) == up(0.3)
}

@doc("A blend of disjoint bone sets keeps every bone: at weight 0 the second pose's torso-only bone reads its blend toward rest.")
test "blend of disjoint bone sets keeps both bones per bone" {
  assert Pose.blend(Pose.empty().set(Bone::LUpperLeg, rot_x(0.0)), Pose.empty().set(Bone::Torso, up(0.5)), 0.0).get(Bone::LUpperLeg) == rot_x(0.0)
}

@doc("A bone the base drives but the overlay omits rests at an INTERIOR weight (§16 §7): the absent-bone fallback is the rest transform, identical to blending against an explicitly rest-driven bone — not the degenerate zero transform. Only an interior weight exercises the fallback; the 0/1 endpoints shortcut to an endpoint pose.")
test "blend rests an absent bone at interior weight" {
  assert Pose.blend(Pose.empty().set(Bone::LUpperLeg, up(0.4)), Pose.empty().set(Bone::Torso, up(0.5)), 0.5).get(Bone::LUpperLeg) == Pose.blend(Pose.empty().set(Bone::LUpperLeg, up(0.4)), Pose.empty().set(Bone::LUpperLeg, rot_x(0.0)), 0.5).get(Bone::LUpperLeg)
}

@doc("Layer overlay wins per bone: the overlay's torso replaces the base's torso.")
test "layer overlay wins on a shared bone" {
  assert Pose.layer(Pose.empty().set(Bone::Torso, up(0.1)), Pose.empty().set(Bone::Torso, up(0.5))).get(Bone::Torso) == up(0.5)
}

@doc("Layer shows the base through on a bone the overlay does not drive.")
test "layer shows the base through on an undriven bone" {
  assert Pose.layer(Pose.empty().set(Bone::LUpperLeg, rot_x(0.0)), Pose.empty().set(Bone::Torso, up(0.5))).get(Bone::LUpperLeg) == rot_x(0.0)
}

@doc("walk_weight ramps to full by half top speed and clamps at one.")
test "walk_weight clamps the blend factor" {
  assert walk_weight(1.0) == 1.0
}

@doc("walk_weight is zero at rest.")
test "walk_weight is zero at rest" {
  assert walk_weight(0.0) == 0.0
}

@doc("Walking accumulates phase by speed*cadence*dt in fixed-point.")
test "advance_gait accumulates walk phase" {
  assert advance_gait.step(Walker{player: PlayerId::P1, intent: Vec2{x: 0.0, y: 1.0}}, Time.at(0.5)).phase == 3.0
}

@doc("advance_gait records the ground speed for blending.")
test "advance_gait records the speed" {
  assert advance_gait.step(Walker{player: PlayerId::P1, intent: Vec2{x: 0.0, y: 1.0}}, Time.at(0.5)).speed == 1.0
}
`

@(test)
test_pose_eval_fixture_all_pass :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(POSE_EVAL_FIXTURE)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 13)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}
