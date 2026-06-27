@doc("The over-the-top overworld: a top-down hero the player walks around a fixed-point plane, with a seeded scatter of rupees. The walking-skeleton seed of the comprehensive golden example — a hero thing, a bound 2D walk, a seeded startup, renders, the input bindings, and the pipeline that schedules them. Camera, tilemap, combat, items, and persistence land as later behaviors.")
import engine.math.{Fixed, Vec2}
import engine.world.Spawn
import engine.input.{Input, Key, PlayerId, Bindings, keys_axis, stick_x, stick_y, Stick}
import engine.render.{Draw, Color}
import engine.core.Time
import engine.rand.{Rng, next, seed}

@doc("The hero's two analog walk axes: X is left-negative, Y is up-negative in screen space.")
enum Walk: Axis { X, Y }

@doc("The player avatar: which player drives it, its top-left position in fixed logical units, and its walk speed in units per second.")
@gtag("hero")
thing Hero {
  player: PlayerId
  pos:    Vec2
  speed:  Fixed
}

@doc("A collectible gem, scattered at a seeded position. Picking it up arrives in the items feature.")
@gtag("rupee")
thing Rupee {
  pos: Vec2
}

@doc("Advances a position by a unit direction scaled by speed over one fixed step. Pure fixed-point vector math, so every walk is replay-stable.")
fn walk_to(pos: Vec2, dir: Vec2, speed: Fixed, dt: Fixed) -> Vec2 {
  return pos + dir * speed * dt
}

@doc("Draws a position inside the screen margins from the threaded Rng: two uniform [0,1) draws scaled across the 256x240 logical screen. Returns the position and the advanced Rng, so the scatter is bit-identical for a given seed.")
fn rand_pos(rng: Rng) -> (Vec2, Rng) {
  let (fx, r1) = rng.next()
  let (fy, r2) = r1.next()
  return (Vec2{x: fx * 240.0 + 8.0, y: fy * 216.0 + 8.0}, r2)
}

@doc("Moves the hero by its bound walk axes each tick.")
@gtag("hero")
behavior walk on Hero {
  fn step(self: Hero, input: Input, time: Time) -> Hero {
    let dir = Vec2{x: input.value(self.player, Walk::X), y: input.value(self.player, Walk::Y)}
    return self with { pos: walk_to(self.pos, dir, self.speed, time.dt) }
  }
}

@doc("Draws the hero as a small green square. A sprite atlas replaces this in the assets feature.")
@gtag("render")
behavior draw_hero on Hero {
  fn step(self: Hero) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: Vec2{x: 12.0, y: 12.0}, color: Color::Green}]
  }
}

@doc("Draws a rupee as a small yellow gem.")
@gtag("render")
behavior draw_rupee on Rupee {
  fn step(self: Rupee) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: Vec2{x: 6.0, y: 8.0}, color: Color::Yellow}]
  }
}

@doc("Maps the hero's walk axes to WASD and the left stick. The only device-aware code.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
    .axis(PlayerId::P1, Walk::X, keys_axis(Key::A, Key::D))
    .axis(PlayerId::P1, Walk::Y, keys_axis(Key::W, Key::S))
    .axis(PlayerId::P1, Walk::X, stick_x(Stick::Left))
    .axis(PlayerId::P1, Walk::Y, stick_y(Stick::Left))
}

@doc("Seeded startup: spawns the hero near center and scatters three rupees at RNG-chosen positions, threading the advanced Rng forward. Same root seed produces the same layout on every machine.")
@gtag("startup")
fn setup(rng: Rng) -> (Rng, [Spawn]) {
  let (a, r1) = rand_pos(rng)
  let (b, r2) = rand_pos(r1)
  let (c, r3) = rand_pos(r2)
  return (r3, [
    Spawn( Hero{player: PlayerId::P1, pos: Vec2{x: 122.0, y: 114.0}, speed: 80.0} ),
    Spawn( Rupee{pos: a} ),
    Spawn( Rupee{pos: b} ),
    Spawn( Rupee{pos: c} )
  ])
}

@doc("The overworld at a fixed 60hz. Pure behaviors over a seeded scatter, so every replay is bit-identical.")
@gtag("game")
pipeline Overworld {
  startup: [setup]
  control: [walk]
  render:  [draw_hero, draw_rupee]
}

@doc("Walking advances the hero by direction*speed*dt, exactly, in fixed-point.")
test "walk_to advances a position by direction over speed and dt" {
  assert walk_to(Vec2{x: 0.0, y: 0.0}, Vec2{x: 1.0, y: 0.0}, 80.0, 0.5) == Vec2{x: 40.0, y: 0.0}
}

@doc("Rendering is a pure function of the hero blackboard, so the draw list is assertable.")
test "draw_hero emits one green rect at the hero position" {
  assert draw_hero.step(Hero{player: PlayerId::P1, pos: Vec2{x: 10.0, y: 20.0}, speed: 80.0}) == [Draw::Rect{at: Vec2{x: 10.0, y: 20.0}, size: Vec2{x: 12.0, y: 12.0}, color: Color::Green}]
}

@doc("The seed contract: a fixed seed draws the same scatter position and advances to the same Rng every time.")
test "rand_pos is deterministic for a fixed seed" {
  let (a, ra) = rand_pos(seed(7))
  let (b, rb) = rand_pos(seed(7))
  assert a == b
  assert ra == rb
}
