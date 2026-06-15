@doc("A patrol/chase/search enemy AI: the state machine is a blackboard enum + an exhaustive match, the search timeout is a Fixed countdown folded by Time, and the whole AI is a pure, replay-stable fold (spec/13-ai.md). No async, no behavior-tree, no scheduler.")
import engine.math.{Fixed, Vec2, length}
import engine.world.{Spawn, View}
import engine.input.{Input, PlayerId, Bindings, Stick, wasd, stick}
import engine.core.Time
import engine.render.{Draw, Color}
import engine.list.first

@doc("The player's 2D move axis, resolved from keys or a stick.")
enum Drive: Axis { Move }

@doc("The hunter's AI state. The enum IS the state set; the match in `think` is the transition function; exhaustiveness is the totality guarantee — an unhandled state is a compile error (spec/13-ai.md).")
enum Hunt { Patrol, Chase, Search }

@doc("How close the hunter must be to notice the player.")
let SIGHT: Fixed = 30.0
@doc("Hunter move speed, fixed units per tick.")
let H_SPEED: Fixed = 1.0
@doc("Player move speed, fixed units per second.")
let P_SPEED: Fixed = 80.0
@doc("How long the hunter searches the last-seen point before giving up, in seconds.")
let SEARCH_TIME: Fixed = 2.0

@doc("The player avatar, moved directly by input.")
@gtag("player")
thing Player { pos: Vec2 }

@doc("A hunter. `ai` is its state, `home` its patrol anchor, `last_seen` the chase memory, and `search_t` the give-up countdown — all plain blackboard state, so the whole AI saves, replays, and tests as a fold.")
@gtag("ai")
thing Hunter {
  pos:       Vec2
  home:      Vec2
  ai:        Hunt  = Hunt::Patrol
  last_seen: Vec2  = Vec2{x: 0.0, y: 0.0}
  search_t:  Fixed = 0.0
}

@doc("A position stepped toward a target by at most `speed`, snapping on the last step. Pure motion.")
@gtag("ai")
fn step_to(from: Vec2, to: Vec2, speed: Fixed) -> Vec2 {
  let delta = to - from
  let d = length(delta)
  if d <= speed { return to }
  return from + delta * speed / d
}

@doc("The nearest visible player's position, or None — a pure perception predicate over a View. Taking the View is the statement that this code senses; nothing else does.")
@gtag("ai")
fn visible(from: Vec2, players: View[Player]) -> Option[Vec2] {
  return match first(players, fn(p) { return length(p.pos - from) <= SIGHT }) {
    Option::Some(p) => Option::Some(p.pos)
    Option::None    => Option::None
  }
}

@doc("Patrol: walk back toward home; flip to Chase the moment the player is seen.")
@gtag("ai")
fn patrol(self: Hunter, seen: Option[Vec2]) -> Hunter {
  return match seen {
    Option::Some(p) => self with { ai: Hunt::Chase, last_seen: p }
    Option::None    => self with { pos: step_to(self.pos, self.home, H_SPEED) }
  }
}

@doc("Chase: move toward the player and remember where it is; on losing sight, drop to Search with a full timer.")
@gtag("ai")
fn chase(self: Hunter, seen: Option[Vec2]) -> Hunter {
  return match seen {
    Option::Some(p) => self with { pos: step_to(self.pos, p, H_SPEED), last_seen: p }
    Option::None    => self with { ai: Hunt::Search, search_t: SEARCH_TIME }
  }
}

@doc("Search: re-acquire straight back to Chase if the player reappears; otherwise walk the last-seen point, counting down — and give up to Patrol when the timer elapses.")
@gtag("ai")
fn search(self: Hunter, seen: Option[Vec2], dt: Fixed) -> Hunter {
  return match seen {
    Option::Some(p) => self with { ai: Hunt::Chase, last_seen: p }
    Option::None    => seek(self, dt)
  }
}

@doc("The Search timer step: decrement the countdown, give up at zero, otherwise walk the last-seen point. The 'wait' is a field folded by the tick, never an async delay (spec/13-ai.md).")
@gtag("ai")
fn seek(self: Hunter, dt: Fixed) -> Hunter {
  let t = self.search_t - dt
  if t <= 0.0 { return self with { ai: Hunt::Patrol, search_t: 0.0 } }
  return self with { pos: step_to(self.pos, self.last_seen, H_SPEED), search_t: t }
}

@doc("The state machine: sense once, then dispatch on the current state. The behavior is just the match; each state's logic is a decomposed pure function (AX6).")
@gtag("ai")
behavior think on Hunter {
  fn step(self: Hunter, players: View[Player], time: Time) -> Hunter {
    let seen = visible(self.pos, players)
    return match self.ai {
      Hunt::Patrol => patrol(self, seen)
      Hunt::Chase  => chase(self, seen)
      Hunt::Search => search(self, seen, time.dt)
    }
  }
}

@doc("Moves the player by its bound 2D axis. Kinematic — it just sets pos.")
@gtag("player")
behavior drive on Player {
  fn step(self: Player, input: Input, time: Time) -> Player {
    return self with { pos: self.pos + input.axis(PlayerId::P1, Drive::Move) * P_SPEED * time.dt }
  }
}

@doc("The hunter's colour reads its state at a glance: green patrolling, red chasing, white searching.")
@gtag("render")
fn hunter_color(ai: Hunt) -> Color {
  return match ai {
    Hunt::Patrol => Color::Green
    Hunt::Chase  => Color::Red
    Hunt::Search => Color::White
  }
}

@doc("Draws a hunter, coloured by its AI state.")
@gtag("render")
behavior draw_hunter on Hunter {
  fn step(self: Hunter) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: Vec2{x: 8.0, y: 8.0}, color: hunter_color(self.ai)}]
  }
}

@doc("Draws the player as a small blue-ish rect (white here, given the palette).")
@gtag("render")
behavior draw_player on Player {
  fn step(self: Player) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: Vec2{x: 6.0, y: 6.0}, color: Color::White}]
  }
}

@doc("Binds the player's 2D move axis to WASD and the left stick. The only device-aware code.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
    .axis(PlayerId::P1, Drive::Move, wasd())
    .axis(PlayerId::P1, Drive::Move, stick(Stick::Left))
}

@doc("Spawns the player and two hunters at their patrol anchors. No RNG — fully deterministic, so every replay re-derives the identical AI decisions.")
@gtag("startup")
fn setup() -> [Spawn] {
  return [
    Spawn( Player{pos: Vec2{x: 80.0, y: 100.0}} )
    Spawn( Hunter{pos: Vec2{x: 40.0,  y: 40.0}, home: Vec2{x: 40.0,  y: 40.0}} )
    Spawn( Hunter{pos: Vec2{x: 120.0, y: 40.0}, home: Vec2{x: 120.0, y: 40.0}} )
  ]
}

@doc("Sneak past the hunters. The AI is a pure fold over blackboard state, so every decision is deterministic and replay-stable. A pure schedule — tick and bindings live in the entrypoint.")
@gtag("game")
pipeline Hunt {
  startup: [setup]
  control: [drive]
  ai:      [think]
  render:  [draw_player, draw_hunter]
}

@doc("Perception is a pure predicate: a player within sight is visible, one far away is not.")
test "a player in range is visible, out of range is not" {
  let eye = Vec2{x: 0.0, y: 0.0}
  assert visible(eye, View.of([Player{pos: Vec2{x: 3.0, y: 0.0}}])) == Option::Some(Vec2{x: 3.0, y: 0.0})
  assert visible(eye, View.of([Player{pos: Vec2{x: 100.0, y: 0.0}}])) == Option::None
}

@doc("Patrol flips to Chase and records the sighting the moment the player is seen.")
test "patrol switches to chase on sight" {
  let h = Hunter{pos: Vec2{x: 0.0, y: 0.0}, home: Vec2{x: 0.0, y: 0.0}}
  let after = patrol(h, Option::Some(Vec2{x: 5.0, y: 0.0}))
  assert after.ai == Hunt::Chase
  assert after.last_seen == Vec2{x: 5.0, y: 0.0}
}

@doc("Losing the player in Chase drops to Search with a full give-up timer.")
test "chase drops to search with a full timer when sight is lost" {
  let h = Hunter{pos: Vec2{x: 0.0, y: 0.0}, home: Vec2{x: 0.0, y: 0.0}, ai: Hunt::Chase, last_seen: Vec2{x: 9.0, y: 0.0}, search_t: 0.0}
  let after = chase(h, Option::None)
  assert after.ai == Hunt::Search
  assert after.search_t == SEARCH_TIME
}

@doc("Re-acquiring the player in Search flips straight back to Chase.")
test "search re-acquires to chase" {
  let h = Hunter{pos: Vec2{x: 0.0, y: 0.0}, home: Vec2{x: 0.0, y: 0.0}, ai: Hunt::Search, last_seen: Vec2{x: 9.0, y: 0.0}, search_t: 1.0}
  assert search(h, Option::Some(Vec2{x: 2.0, y: 0.0}), 0.5).ai == Hunt::Chase
}

@doc("The search countdown is folded by dt: it gives up to Patrol at zero, and keeps searching while time remains.")
test "search gives up to patrol when the timer elapses" {
  let h = Hunter{pos: Vec2{x: 0.0, y: 0.0}, home: Vec2{x: 0.0, y: 0.0}, ai: Hunt::Search, last_seen: Vec2{x: 9.0, y: 0.0}, search_t: 0.5}
  assert search(h, Option::None, 0.5).ai == Hunt::Patrol
  assert search(h with { search_t: 2.0 }, Option::None, 0.5).ai == Hunt::Search
}

@doc("think dispatches on the current state: a patrolling hunter that sees the player ends the tick in Chase.")
test "think dispatches on the current state" {
  let h = Hunter{pos: Vec2{x: 0.0, y: 0.0}, home: Vec2{x: 50.0, y: 0.0}}
  let players = View.of([Player{pos: Vec2{x: 5.0, y: 0.0}}])
  assert think.step(h, players, Time.at(0.016)).ai == Hunt::Chase
}
