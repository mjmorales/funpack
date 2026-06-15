@doc("The arena's behaviors and pipeline: gate logic that resolves a level-baked switch reference, a hunter chase AI that is a pure fold over a nav fixture, and the startup that loads the generated spawn list. Imports the schema and the generated seam.")
import engine.prelude.{Option, Result, Fixed, or_else}
import engine.input.Bindings
import engine.math.{Vec2, length}
import engine.nav.{Nav, Path}
import engine.world.{Spawn, View}
import engine.list.fold
import arena_world.{Switch, Door, Player, Hunter}
import arena.{arena_spawns, Arena, arena}

@doc("How far a hunter advances toward its next waypoint each tick.")
let HUNTER_SPEED: Fixed = 0.8
@doc("How close counts as having reached a waypoint.")
let ARRIVE: Fixed = 1.0

@doc("Whether a gate should be open given its switch, if the switch still exists. A pure decision, testable without a world.")
@gtag("mechanism")
fn gate_open(sw: Option[Switch]) -> Bool {
  return match sw {
    Option::Some(s) => s.on
    Option::None    => false
  }
}

@doc("Opens the door while its bound switch reads on, resolving the typed reference the level baked onto it.")
@gtag("mechanism")
behavior gate_logic on Door {
  fn step(self: Door, switches: View[Switch]) -> Door {
    return self with { open: gate_open(switches.resolve(self.gate)) }
  }
}

@doc("The position of the nearest player to a point, or the point itself when there are none (so a hunter with no target holds still).")
@gtag("ai")
fn nearest_player(from: Vec2, players: View[Player]) -> Vec2 {
  let best = fold(players, Option::None, fn(acc, p) {
    return match acc {
      Option::None    => Option::Some(p.pos)
      Option::Some(b) => if length(p.pos - from) < length(b - from) { Option::Some(p.pos) } else { Option::Some(b) }
    }
  })
  return or_else(best, from)
}

@doc("A position stepped toward a target by at most `speed`, snapping to the target on the last step. Pure motion, no nav.")
@gtag("ai")
fn step_to(from: Vec2, to: Vec2, speed: Fixed) -> Vec2 {
  let delta = to - from
  let d = length(delta)
  if d <= speed { return to }
  return from + delta * speed / d
}

@doc("Paths the hunter to the nearest player and advances one step, holding the last good route when no path exists. The nav query is pure, so this whole AI is a testable fold.")
@gtag("ai")
behavior chase on Hunter {
  fn step(self: Hunter, nav: Nav, players: View[Player]) -> Hunter {
    let goal = nearest_player(self.pos, players)
    let route = match nav.path(self.pos, goal) {
      Result::Ok(p)  => p
      Result::Err(_) => self.path
    }
    return match route.advance(self.pos, ARRIVE) {
      (Option::Some(wp), rest) => self with { pos: step_to(self.pos, wp, HUNTER_SPEED), path: rest }
      (Option::None,     _)    => self
    }
  }
}

@doc("No device-driven input: the arena's actors are level-placed and AI-driven, so the bindings table is empty.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
}

@doc("Loads the Arena level at startup — the generated, deterministic spawn list replaces a hand-written setup().")
@gtag("startup")
fn setup() -> [Spawn] {
  return arena_spawns()
}

@doc("A tiny arena driven entirely by a flat-text level: the world is placed by arena.flvl, referenced through the generated seam.")
@gtag("game")
pipeline ArenaGame {
  startup: [setup]
  ai:      [chase]
  update:  [gate_logic]
}

@doc("A gate opens when its switch is on.")
test "gate opens while the switch is on" {
  assert gate_open(Option::Some(Switch{pos: Vec2{x: 0.0, y: 0.0}, on: true})) == true
}

@doc("A gate stays shut when the switch is off, or has despawned.")
test "gate is shut when off or missing" {
  assert gate_open(Option::Some(Switch{pos: Vec2{x: 0.0, y: 0.0}, on: false})) == false
  assert gate_open(Option::None) == false
}

@doc("End to end: the behavior resolves the level-baked reference through a view fixture and opens the door.")
test "gate_logic resolves its switch and opens" {
  let switches = View.of([Switch{pos: Vec2{x: 0.0, y: 40.0}, on: true}])
  let door = Door{pos: Vec2{x: 0.0, y: -40.0}, gate: switches.ref(0)}
  assert gate_logic.step(door, switches).open == true
}

@doc("Stepping toward a target nearer than one step snaps onto it.")
test "step_to snaps within one step" {
  assert step_to(Vec2{x: 0.0, y: 0.0}, Vec2{x: 0.5, y: 0.0}, HUNTER_SPEED) == Vec2{x: 0.5, y: 0.0}
}

@doc("The nearest player wins; with no players the hunter's own position is returned (it holds still).")
test "nearest_player picks the closest, falls back to self" {
  let from = Vec2{x: 0.0, y: 0.0}
  let players = View.of([Player{pos: Vec2{x: 9.0, y: 0.0}}, Player{pos: Vec2{x: 3.0, y: 0.0}}])
  assert nearest_player(from, players) == Vec2{x: 3.0, y: 0.0}
  assert nearest_player(from, View.of([])) == from
}

@doc("With a pure nav fixture the whole AI is a fold: the hunter advances one step along the route.")
test "chase advances the hunter toward the first waypoint" {
  let nav = Nav.of(Path{steps: [Vec2{x: 10.0, y: 0.0}], cost: 10.0})
  let players = View.of([Player{pos: Vec2{x: 10.0, y: 0.0}}])
  let hunter = Hunter{pos: Vec2{x: 0.0, y: 0.0}, path: Path{steps: [], cost: 0.0}}
  assert chase.step(hunter, nav, players).pos == Vec2{x: 0.8, y: 0.0}
}
