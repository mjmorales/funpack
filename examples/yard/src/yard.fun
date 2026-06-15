@doc("A crate-delivery sandbox: defines the player, crates, walls, and delivery pad over the engine physics solver, plus a follow-and-shake camera and a quicksave/restore/settings menu — all as pure behaviors, with the input bindings, setup, and pipeline that schedule them.")
import engine.math.{Fixed, Vec2}
import engine.world.{Spawn, Despawn, View}
import engine.input.{Input, PlayerId, Bindings, Key, Stick, wasd, stick}
import engine.render.{Draw, Color}
import engine.physics.{Body, BodyKind, Shape2, Trigger, solve}
import engine.save.{Save, Restore, ApplySettings, Saved, Restored, SettingsApplied, Settings}
import engine.list.{is_empty, len, first, fold}

@doc("The player's 2D move axis: a unit-ish vector the engine resolves from keys or a stick.")
enum Drive: Axis { Move }

@doc("Collision layers for the yard. A registered closed set (AX8), checked like a @gtag — an unregistered layer is a compile error.")
enum Layer: CollisionLayer { Wall, Player, Crate, Pad }

@doc("Menu actions: quicksave, quickload, toggle the reduce-motion preference, and apply edited settings.")
enum Cmd: Button { Save, Restore, ToggleMotion, Apply }

@doc("The single quicksave slot. Save slots are dynamic String keys — created at runtime by the player, not a compile-time registry (spec/24-persistence.md).")
let SLOT: String = "quicksave"

@doc("Impulse applied per tick at full stick deflection. The solver's friction bleeds it off, so the player coasts to rest.")
let ACCEL: Fixed = 8.0

@doc("Fraction of the gap to the player the camera closes each tick. Binary-exact, so the eased path is bit-identical.")
let FOLLOW: Fixed = 0.25

@doc("Initial shake displacement kicked in on a delivery.")
let SHAKE_KICK: Fixed = 4.0

@doc("Per-tick shake factor: negative, so the offset flips sign and halves each tick — a decaying oscillation, deterministic in fixed-point.")
let SHAKE_DAMP: Fixed = -0.5

@doc("The player avatar: a dynamic circle the player pushes around with impulses. `pos`/`vel` are the reserved fields the solver integrates.")
@gtag("player")
thing Player {
  pos:  Vec2
  vel:  Vec2
  body: Body
}

@doc("A pushable crate: a dynamic box the solver moves and resolves against walls, the player, and other crates.")
@gtag("crate")
thing Crate {
  pos:  Vec2
  vel:  Vec2
  body: Body
}

@doc("A static wall. Infinite mass by its `Static` kind; it never integrates, so it carries no `vel`.")
@gtag("scenery")
thing Wall {
  pos:  Vec2
  body: Body
}

@doc("The delivery pad: a static sensor. It is never resolved — a crate overlapping it gets a Trigger.")
@gtag("delivery")
thing Pad {
  pos:  Vec2
  body: Body
}

@doc("The running tally of crates delivered. A singleton: exactly one row, spawned before tick 0, accessed by type.")
@gtag("score")
singleton Scoreboard {
  delivered: Int = 0
}

@doc("The 2D view: where the camera looks, its zoom, and a transient shake offset. Plain sim state — a singleton spawned before tick 0.")
@gtag("camera")
singleton Camera {
  at:    Vec2  = Vec2{x: 80.0, y: 60.0}
  zoom:  Fixed = 1.0
  shake: Vec2  = Vec2{x: 0.0, y: 0.0}
}

@doc("In-session menu state: the editable preferences, whether they have unapplied edits, and the last save/restore/settings outcome. A singleton, seeded from the factory-default settings — gameplay never reads it back, the whole point of the settings split (spec/24-persistence.md).")
@gtag("menu")
singleton Menu {
  settings: Settings       = Settings.defaults()
  dirty:    Bool           = false
  status:   Option[String] = Option::None
}

@doc("Emitted by a crate the tick it lands on a delivery pad. Consumed by the scoreboard and the camera shake.")
@gtag("delivery", "score")
signal Delivered {}

@doc("Reads the move axis and pushes the player by it. Writes only its own body's accumulated intent — the solver consumes and zeroes it next stage.")
@gtag("player", "input")
behavior drive on Player {
  fn step(self: Player, input: Input) -> Player {
    let push = input.axis(PlayerId::P1, Drive::Move) * ACCEL
    return self with { body: self.body.apply_impulse(push) }
  }
}

@doc("Delivers a crate that reached a pad: the engine routes a Trigger to the overlapping crate, which despawns itself and reports a Delivered. Self-despawn needs no id.")
@gtag("delivery")
behavior deliver on Crate {
  fn step(self: Crate, pads: [Trigger]) -> ([Despawn], [Delivered]) {
    if is_empty(pads) { return ([], []) }
    return ([Despawn()], [Delivered{}])
  }
}

@doc("Folds this tick's deliveries into the running tally. A pure fold over a broadcast signal, like Pong's score.")
@gtag("score")
behavior tally on Scoreboard {
  fn step(self: Scoreboard, done: [Delivered]) -> Scoreboard {
    return self with { delivered: self.delivered + len(done) }
  }
}

@doc("The point the camera tracks: the first player's position, or the camera's own position when there is none (so it holds still).")
@gtag("camera")
fn focus(players: View[Player], fallback: Vec2) -> Vec2 {
  return match first(players) {
    Option::Some(p) => p.pos
    Option::None    => fallback
  }
}

@doc("Eases the camera a fixed fraction toward the player each tick. Pure fixed-point vector math, so the path is deterministic and replay-stable — placed after physics, so it tracks the solved position.")
@gtag("camera")
behavior follow on Camera {
  fn step(self: Camera, players: View[Player]) -> Camera {
    let target = focus(players, self.at)
    return self with { at: self.at + (target - self.at) * FOLLOW }
  }
}

@doc("Kicks the shake offset on a delivery, otherwise lets it flip-and-decay toward rest. The magnitude is deterministic sim state; the engine renders the visual jitter from it.")
@gtag("camera")
behavior shake on Camera {
  fn step(self: Camera, done: [Delivered]) -> Camera {
    if not is_empty(done) { return self with { shake: Vec2{x: SHAKE_KICK, y: 0.0} } }
    return self with { shake: self.shake * SHAKE_DAMP }
  }
}

@doc("Projects the camera state into the frame's view command, offset by the current shake. The engine builds the letterboxed world↔screen transform from it (spec/20-render.md).")
@gtag("render")
behavior view on Camera {
  fn step(self: Camera) -> [Draw] {
    return [Draw::Camera{at: self.at + self.shake, zoom: self.zoom, rotation: 0.0}]
  }
}

@doc("Quicksaves the world on the save key. The engine serializes the committed version; the outcome returns next tick as a Saved signal. A pure behavior — it emits a command, it does not touch the disk.")
@gtag("persist")
behavior save_key on Menu {
  fn step(self: Menu, input: Input) -> [Save] {
    if input.pressed(PlayerId::P1, Cmd::Save) { return [Save{slot: SLOT}] }
    return []
  }
}

@doc("Restores the quicksave on the load key. `Restore` (not `Load`, which is level streaming) replaces the world at the next tick boundary.")
@gtag("persist")
behavior restore_key on Menu {
  fn step(self: Menu, input: Input) -> [Restore] {
    if input.pressed(PlayerId::P1, Cmd::Restore) { return [Restore{slot: SLOT}] }
    return []
  }
}

@doc("Records the outcome of a save or restore. The IoError / LoadError case is a value the match must cover (AX4) — a failed write can never be silently dropped.")
@gtag("persist")
behavior on_persist_result on Menu {
  fn step(self: Menu, saved: [Saved], restored: [Restored]) -> Menu {
    let after_save = fold(saved, self, fn(m, r) {
      return match r.result {
        Result::Ok(_)  => m with { status: Option::Some("saved") }
        Result::Err(_) => m with { status: Option::Some("save failed") }
      }
    })
    return fold(restored, after_save, fn(m, r) {
      return match r.result {
        Result::Ok(_)  => m with { status: Option::Some("restored") }
        Result::Err(_) => m with { status: Option::Some("restore failed") }
      }
    })
  }
}

@doc("Toggles the reduce-motion preference from input, editing the in-session settings and marking them unapplied. Note what is absent: gameplay never reads this preference — the engine, not the sim, dampens the camera shake when it is applied (spec/24-persistence.md). The `shake` behavior above is untouched.")
@gtag("settings")
behavior toggle_motion on Menu {
  fn step(self: Menu, input: Input) -> Menu {
    if not input.pressed(PlayerId::P1, Cmd::ToggleMotion) { return self }
    let access = self.settings.access with { reduce_motion: not self.settings.access.reduce_motion }
    return self with { settings: self.settings with { access: access }, dirty: true }
  }
}

@doc("Applies edited settings on the apply key, only when there are unapplied edits. The engine persists them and pushes them to the mixer, binding resolver, and renderer; the outcome returns next tick.")
@gtag("settings")
behavior apply_settings on Menu {
  fn step(self: Menu, input: Input) -> [ApplySettings] {
    if self.dirty and input.pressed(PlayerId::P1, Cmd::Apply) { return [ApplySettings{settings: self.settings}] }
    return []
  }
}

@doc("Records the settings-apply outcome and clears the unapplied flag once the engine has persisted them.")
@gtag("settings")
behavior on_settings_applied on Menu {
  fn step(self: Menu, applied: [SettingsApplied]) -> Menu {
    return fold(applied, self, fn(m, r) {
      return match r.result {
        Result::Ok(_)  => m with { dirty: false, status: Option::Some("settings applied") }
        Result::Err(_) => m with { status: Option::Some("settings save failed") }
      }
    })
  }
}

@doc("Draws a wall as a white rect.")
@gtag("render")
behavior draw_wall on Wall {
  fn step(self: Wall) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: box_size(self.body.shape), color: Color::White}]
  }
}

@doc("Draws the delivery pad as a green rect, under the crates.")
@gtag("render")
behavior draw_pad on Pad {
  fn step(self: Pad) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: box_size(self.body.shape), color: Color::Green}]
  }
}

@doc("Draws a crate as a white rect at its solved position.")
@gtag("render")
behavior draw_crate on Crate {
  fn step(self: Crate) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: Vec2{x: 12.0, y: 12.0}, color: Color::White}]
  }
}

@doc("Draws the player as a small red rect at its solved position.")
@gtag("render")
behavior draw_player on Player {
  fn step(self: Player) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: Vec2{x: 10.0, y: 10.0}, color: Color::Red}]
  }
}

@doc("Draws the delivered count.")
@gtag("render")
behavior draw_score on Scoreboard {
  fn step(self: Scoreboard) -> [Draw] {
    return [Draw::Text{at: Vec2{x: 80.0, y: 8.0}, text: "delivered: {self.delivered}", color: Color::White}]
  }
}

@doc("The draw size of a box shape; non-boxes fall back to a small square. Render-only — never touches the sim.")
fn box_size(shape: Shape2) -> Vec2 {
  return match shape {
    Shape2::Box{size} => size
    _                 => Vec2{x: 8.0, y: 8.0}
  }
}

@doc("A static wall body of a given size on the Wall layer, stopping the player and crates.")
fn wall_body(size: Vec2) -> Body {
  return Body{ kind: BodyKind::Static, shape: Shape2::Box{size: size}, layer: Layer::Wall, mask: [Layer::Player, Layer::Crate] }
}

@doc("A pushable crate's body: a dynamic box that collides with everything, including the pad sensor.")
fn crate_body() -> Body {
  return Body{
    kind:     BodyKind::Dynamic,
    shape:    Shape2::Box{size: Vec2{x: 12.0, y: 12.0}},
    mass:     2.0,
    friction: 0.9,
    layer:    Layer::Crate,
    mask:     [Layer::Wall, Layer::Player, Layer::Crate, Layer::Pad],
  }
}

@doc("A pushable crate at a position.")
fn crate_at(at: Vec2) -> Crate {
  return Crate{ pos: at, vel: Vec2{x: 0.0, y: 0.0}, body: crate_body() }
}

@doc("The player's body: a dynamic circle that collides with walls and crates, but not the pad sensor (its mask omits Pad), so the player walks over the pad freely.")
fn player_body() -> Body {
  return Body{
    kind:     BodyKind::Dynamic,
    shape:    Shape2::Circle{radius: 5.0},
    friction: 0.9,
    layer:    Layer::Player,
    mask:     [Layer::Wall, Layer::Crate],
  }
}

@doc("Spawns the bordered yard, the player, a row of crates, and the delivery pad. No RNG — fully deterministic, so every replay is bit-identical. The Scoreboard singleton is spawned by the engine, not here.")
@gtag("startup")
fn setup() -> [Spawn] {
  return [
    Spawn( Wall{pos: Vec2{x: 80.0,  y: 2.0},   body: wall_body(Vec2{x: 160.0, y: 4.0})} )
    Spawn( Wall{pos: Vec2{x: 80.0,  y: 118.0}, body: wall_body(Vec2{x: 160.0, y: 4.0})} )
    Spawn( Wall{pos: Vec2{x: 2.0,   y: 60.0},  body: wall_body(Vec2{x: 4.0,   y: 120.0})} )
    Spawn( Wall{pos: Vec2{x: 158.0, y: 60.0},  body: wall_body(Vec2{x: 4.0,   y: 120.0})} )

    Spawn( Pad{pos: Vec2{x: 80.0, y: 100.0}, body: Body{
      kind:   BodyKind::Static,
      shape:  Shape2::Box{size: Vec2{x: 24.0, y: 24.0}},
      sensor: true,
      layer:  Layer::Pad,
      mask:   [Layer::Crate],
    }} )

    Spawn( Player{pos: Vec2{x: 80.0, y: 60.0}, vel: Vec2{x: 0.0, y: 0.0}, body: player_body()} )

    Spawn( crate_at(Vec2{x: 50.0,  y: 40.0}) )
    Spawn( crate_at(Vec2{x: 80.0,  y: 40.0}) )
    Spawn( crate_at(Vec2{x: 110.0, y: 40.0}) )
  ]
}

@doc("Binds the player's 2D move axis to WASD and the left stick, and the menu actions to keys. The only device-aware code — and the factory default the player's persisted keybinds override (spec/24-persistence.md).")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
    .axis(PlayerId::P1, Drive::Move, wasd())
    .axis(PlayerId::P1, Drive::Move, stick(Stick::Left))
    .button(PlayerId::P1, Cmd::Save,         [Key::F5])
    .button(PlayerId::P1, Cmd::Restore,      [Key::F9])
    .button(PlayerId::P1, Cmd::ToggleMotion, [Key::M])
    .button(PlayerId::P1, Cmd::Apply,        [Key::Enter])
}

@doc("Push crates onto the pad. The engine-owned `physics:` stage integrates and resolves; behaviors only set intent (drive) and react to engine signals (deliver). A pure schedule — tick and bindings live in the entrypoint.")
@gtag("game")
pipeline Yard {
  startup:  [setup]
  control:  [drive]
  physics:  solve
  delivery: [deliver, tally]
  menu:     [on_persist_result, on_settings_applied, save_key, restore_key, toggle_motion, apply_settings]
  camera:   [follow, shake]
  render:   [view, draw_wall, draw_pad, draw_crate, draw_player, draw_score]
}

@doc("apply_impulse accumulates intent on the body; two pushes sum.")
test "apply_impulse accumulates intent on the body" {
  let b = Body{ kind: BodyKind::Dynamic, shape: Shape2::Circle{radius: 5.0}, layer: Layer::Player, mask: [Layer::Wall] }
  let pushed = b.apply_impulse(Vec2{x: 1.0, y: 0.0}).apply_impulse(Vec2{x: 0.0, y: 2.0})
  assert pushed.impulse == Vec2{x: 1.0, y: 2.0}
}

@doc("The move axis becomes an impulse on the player's own body, scaled by ACCEL. Drive is a pure function over a constructed Input — no world.")
test "drive converts the move axis into a body impulse" {
  let p = Player{pos: Vec2{x: 80.0, y: 60.0}, vel: Vec2{x: 0.0, y: 0.0}, body: Body{ kind: BodyKind::Dynamic, shape: Shape2::Circle{radius: 5.0}, layer: Layer::Player, mask: [Layer::Wall] }}
  let driven = drive.step(p, Input.empty().with_axis(PlayerId::P1, Drive::Move, Vec2{x: 1.0, y: 0.0}))
  assert driven.body.impulse == Vec2{x: ACCEL, y: 0.0}
}

@doc("A crate the engine routed a Trigger to delivers: it despawns itself and reports a Delivered.")
test "a crate on the pad delivers and despawns" {
  assert deliver.step(crate_at(Vec2{x: 80.0, y: 100.0}), [Trigger{}]) == ([Despawn()], [Delivered{}])
}

@doc("A crate with no Trigger this tick is inert — no despawn, no signal.")
test "a crate off the pad is inert" {
  assert deliver.step(crate_at(Vec2{x: 50.0, y: 40.0}), []) == ([], [])
}

@doc("The scoreboard counts the crates delivered this tick. A broadcast signal folded once on the singleton.")
test "tally counts deliveries this tick" {
  assert tally.step(Scoreboard{delivered: 1}, [Delivered{}, Delivered{}]) == Scoreboard{delivered: 3}
}

@doc("The camera eases a quarter of the way toward the player each tick — a pure, exact fixed-point step.")
test "follow eases the camera toward the player" {
  let cam = Camera{at: Vec2{x: 0.0, y: 0.0}, zoom: 1.0, shake: Vec2{x: 0.0, y: 0.0}}
  let players = View.of([Player{pos: Vec2{x: 8.0, y: 0.0}, vel: Vec2{x: 0.0, y: 0.0}, body: player_body()}])
  assert follow.step(cam, players).at == Vec2{x: 2.0, y: 0.0}
}

@doc("With no player the camera holds its position (it tracks its own `at` as the fallback).")
test "follow holds when there is no player" {
  let cam = Camera{at: Vec2{x: 5.0, y: 5.0}, zoom: 1.0, shake: Vec2{x: 0.0, y: 0.0}}
  assert follow.step(cam, View.of([])).at == Vec2{x: 5.0, y: 5.0}
}

@doc("A delivery kicks the shake offset; the magnitude is deterministic sim state.")
test "a delivery kicks the camera shake" {
  let cam = Camera{at: Vec2{x: 0.0, y: 0.0}, zoom: 1.0, shake: Vec2{x: 0.0, y: 0.0}}
  assert shake.step(cam, [Delivered{}]).shake == Vec2{x: SHAKE_KICK, y: 0.0}
}

@doc("Idle, the shake flips sign and halves toward rest — a decaying oscillation, exact in fixed-point.")
test "shake decays and oscillates when idle" {
  let cam = Camera{at: Vec2{x: 0.0, y: 0.0}, zoom: 1.0, shake: Vec2{x: 4.0, y: 0.0}}
  assert shake.step(cam, []).shake == Vec2{x: -2.0, y: 0.0}
}

@doc("The view command carries the camera offset by its shake — a pure projection asserted by exact equality, the deterministic draw-list the engine interpolates and projects.")
test "view emits the camera at its shaken position" {
  let cam = Camera{at: Vec2{x: 80.0, y: 60.0}, zoom: 1.0, shake: Vec2{x: 2.0, y: 0.0}}
  assert view.step(cam) == [Draw::Camera{at: Vec2{x: 82.0, y: 60.0}, zoom: 1.0, rotation: 0.0}]
}

@doc("The save key emits a Save command for the quicksave slot; with no key, nothing. The disk write is the engine's — this behavior only decides to ask.")
test "the save key emits a Save command" {
  assert save_key.step(Menu{}, Input.empty().with_pressed(PlayerId::P1, Cmd::Save)) == [Save{slot: SLOT}]
  assert save_key.step(Menu{}, Input.empty()) == []
}

@doc("The load key emits a Restore for the same slot.")
test "the load key emits a Restore command" {
  assert restore_key.step(Menu{}, Input.empty().with_pressed(PlayerId::P1, Cmd::Restore)) == [Restore{slot: SLOT}]
}

@doc("Toggling reduce-motion edits the in-session settings and marks them unapplied — a pure edit, no setting is read back into gameplay.")
test "toggle_motion edits settings and marks them dirty" {
  let m = toggle_motion.step(Menu{}, Input.empty().with_pressed(PlayerId::P1, Cmd::ToggleMotion))
  assert m.settings.access.reduce_motion == true
  assert m.dirty == true
}

@doc("Apply emits ApplySettings only when there are unapplied edits; a clean menu emits nothing.")
test "apply emits ApplySettings only when dirty" {
  let edited = Menu{} with { dirty: true }
  assert apply_settings.step(edited, Input.empty().with_pressed(PlayerId::P1, Cmd::Apply)) == [ApplySettings{settings: edited.settings}]
  assert apply_settings.step(Menu{}, Input.empty().with_pressed(PlayerId::P1, Cmd::Apply)) == []
}
