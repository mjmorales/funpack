@doc("Walk a rigged Krognid around a field at a fixed 60hz. Reads twin-stick drive, moves and clamps the creature, advances a pure fixed-point walk-cycle phase, blends idle and walk poses onto the generated rig, and emits a speed-keyed stride loop. Poses are pure fixed-point, so every replay is bit-identical. The rig comes from the krognid.gen.fun seam baked from models/krognid.fpm.")

import engine.math.{Fixed, Vec2, Vec3, sin, abs, length, clamp, tau}
import engine.anim.{Pose, Bone, rot_x, up}
import engine.render3.{Draw3, Color}
import engine.input.{Input, Key, PlayerId, Bindings, keys_axis, stick_x, stick_y, Stick}
import engine.core.Time
import engine.world.Spawn
import engine.audio.{Audio, Bus}
import engine.assets.sound
import krognid.{krognid_skeleton, krognid_parts}

enum Drive: Axis { Strafe, Forward }

@doc("Locomotion tunables. cadence sets how fast the walk cycle advances per unit speed.")
data Stride { cadence: Fixed, top_speed: Fixed }

@doc("The fixed locomotion tuning for a Krognid.")
let STRIDE: Stride = Stride{ cadence: 6.0, top_speed: 4.0 }

@doc("Flat playfield extent on the XZ ground plane, in fixed logical units.")
data Board { size: Vec2 }

@doc("The fixed field. The renderer scales it to the window.")
let BOARD: Board = Board{ size: Vec2{x: 50.0, y: 50.0} }

@doc("A rigged creature: its player, world position, ground-plane intent, and walk-cycle state.")
@gtag("spatial")
thing Krognid {
  player: PlayerId
  pos:    Vec3
  intent: Vec2  = Vec2{x: 0.0, y: 0.0}
  phase:  Fixed = 0.0
  speed:  Fixed = 0.0
}

@doc("The scene singleton: owns the camera, key light, and ground plane.")
@gtag("board")
thing Field {}

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

@doc("Walk pose: legs swing, arms counter-swing, torso bobs at twice the leg rate.")
@gtag("anim")
fn pose_walk(phase: Fixed, speed: Fixed) -> Pose {
  let s = sin(phase) * 0.5
  let bob = abs(sin(phase * 2.0)) * 0.3
  return Pose.empty()
    .set(Bone::LUpperLeg, rot_x(s))
    .set(Bone::RUpperLeg, rot_x(-s))
    .set(Bone::LUpperArm, rot_x(-s * 0.6))
    .set(Bone::RUpperArm, rot_x(s * 0.6))
    .set(Bone::Torso,     up(bob))
}

@doc("Reads the creature's ground-plane intent from its bound Drive axes.")
@gtag("input")
behavior read_drive on Krognid {
  fn step(self: Krognid, input: Input) -> Krognid {
    return self with { intent: Vec2{x: input.value(self.player, Drive::Strafe), y: input.value(self.player, Drive::Forward)} }
  }
}

@doc("Advances the creature along its intent on the ground plane.")
@gtag("spatial")
behavior move_krognid on Krognid {
  fn step(self: Krognid, time: Time) -> Krognid {
    let step = Vec3{x: self.intent.x, y: 0.0, z: self.intent.y} * STRIDE.top_speed * time.dt
    return self with { pos: self.pos + step }
  }
}

@doc("Clamps the creature inside the board on the XZ plane.")
@gtag("spatial")
behavior clamp_to_board on Krognid {
  fn step(self: Krognid) -> Krognid {
    return self with { pos: Vec3{x: clamp(self.pos.x, 0.0, BOARD.size.x), y: self.pos.y, z: clamp(self.pos.z, 0.0, BOARD.size.y)} }
  }
}

@doc("Advances the walk-cycle phase by speed, and records the speed for blending.")
@gtag("gait")
behavior advance_gait on Krognid {
  fn step(self: Krognid, time: Time) -> Krognid {
    let spd = length(self.intent)
    return self with { phase: (self.phase + spd * STRIDE.cadence * time.dt) % tau, speed: spd }
  }
}

@doc("Emits the camera, key light, and ground plane for the scene.")
@gtag("render")
behavior draw_scene on Field {
  fn step(self: Field) -> [Draw3] {
    return [
      Draw3::Camera{ eye: Vec3{x: 25.0, y: 40.0, z: -30.0}, at: Vec3{x: 25.0, y: 0.0, z: 25.0}, fov: 60.0 },
      Draw3::Light{ dir: Vec3{x: -0.3, y: -1.0, z: -0.2}, color: Color::White },
      Draw3::Plane{ at: Vec3{x: 25.0, y: 0.0, z: 25.0}, size: BOARD.size, color: Color::Gray },
    ]
  }
}

@doc("Renders the posed creature: blend the idle and walk poses by current speed.")
@gtag("render")
behavior draw_krognid on Krognid {
  fn step(self: Krognid, time: Time) -> [Draw3] {
    let pose = Pose.blend(pose_idle(time.t), pose_walk(self.phase, self.speed), walk_weight(self.speed))
    return [Draw3::Rigged{ skeleton: krognid_skeleton(), parts: krognid_parts(), pose: pose, at: self.pos }]
  }
}

@doc("A sustained stride loop whose rate and volume track ground speed. Absent (so the engine stops it) when idle; one keyed voice the engine bends as speed changes.")
@gtag("audio")
behavior locomotion on Krognid {
  fn step(self: Krognid) -> [Audio] {
    if self.speed == 0.0 { return [] }
    return [Audio.track("stride", sound("krognid_step")).pitch(0.6 + self.speed * 0.2).gain(clamp(self.speed, 0.0, 1.0)).bus(Bus::Sfx)]
  }
}

@doc("Maps the player's ground-plane drive axes to WASD and the left stick. The only device-aware code.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
    .axis(PlayerId::P1, Drive::Strafe,  keys_axis(Key::A, Key::D))
    .axis(PlayerId::P1, Drive::Forward, keys_axis(Key::S, Key::W))
    .axis(PlayerId::P1, Drive::Strafe,  stick_x(Stick::Left))
    .axis(PlayerId::P1, Drive::Forward, stick_y(Stick::Left))
}

@doc("Spawns one Krognid at the center of the board, at rest, and the scene.")
@gtag("startup")
fn setup() -> [Spawn] {
  return [
    Spawn( Krognid{player: PlayerId::P1, pos: Vec3{x: 25.0, y: 0.0, z: 25.0}} )
    Spawn( Field{} )
  ]
}

@doc("Walk a rigged Krognid around a field at a fixed 60hz. Poses are pure fixed-point, so every replay is bit-identical.")
@gtag("game")
pipeline Stroll {
  startup: [setup]
  control: [read_drive, move_krognid, clamp_to_board, advance_gait]
  render:  [draw_scene, draw_krognid]
  audio:   [locomotion]
}

@doc("Intent maps strafe to x and forward to y on the ground plane.")
test "read_drive maps drive axes onto the ground plane" {
  assert read_drive.step(Krognid{player: PlayerId::P1, pos: Vec3{x: 0.0, y: 0.0, z: 0.0}}, Input.empty().with_value(PlayerId::P1, Drive::Strafe, 0.0).with_value(PlayerId::P1, Drive::Forward, 1.0)).intent == Vec2{x: 0.0, y: 1.0}
}

@doc("Forward intent advances the creature along +Z by top_speed * dt, exactly, in fixed-point.")
test "move_krognid steps forward deterministically" {
  assert move_krognid.step(Krognid{player: PlayerId::P1, pos: Vec3{x: 0.0, y: 0.0, z: 0.0}, intent: Vec2{x: 0.0, y: 1.0}}, Time.at(0.5)).pos == Vec3{x: 0.0, y: 0.0, z: 2.0}
}

@doc("Walking accumulates phase by speed*cadence*dt, wrapped into one turn.")
test "advance_gait accumulates walk phase" {
  assert advance_gait.step(Krognid{player: PlayerId::P1, pos: Vec3{x: 0.0, y: 0.0, z: 0.0}, intent: Vec2{x: 0.0, y: 1.0}}, Time.at(0.5)).phase == 3.0
}

@doc("At phase zero the legs sit at their rest swing, so the pose is assertable exactly.")
test "pose_walk holds the legs at rest on the zero crossing" {
  assert pose_walk(0.0, 1.0).get(Bone::LUpperLeg) == rot_x(0.0)
}

@doc("A standing creature emits no stride loop, so the engine stops it.")
test "locomotion is silent at rest" {
  assert locomotion.step(Krognid{player: PlayerId::P1, pos: Vec3{x: 0.0, y: 0.0, z: 0.0}}) == []
}

@doc("A moving creature emits one keyed stride loop on the Sfx bus, pitched and gained by speed.")
test "locomotion loops while moving" {
  assert locomotion.step(Krognid{player: PlayerId::P1, pos: Vec3{x: 0.0, y: 0.0, z: 0.0}, speed: 1.0}) == [Audio.track("stride", sound("krognid_step")).pitch(0.8).gain(1.0).bus(Bus::Sfx)]
}
