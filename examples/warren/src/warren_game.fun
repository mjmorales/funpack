@doc("The warren's behaviors: a ferret that chases through the baked nav graph — a los() dash when the straight segment is clear, the last good route held across failed queries, a fresh path() only when its own countdown elapses or the rabbit drifts off the cached route — and a rabbit that snaps burrow mouths onto walkable space with nearest(), pre-checks them with reachable(), and re-paths naively every tick. All the glue is pure folds, tested against the Nav.of fixture.")
import engine.prelude.{Option, Result, or_else}
import engine.input.Bindings
import engine.core.Time
import engine.math.{Fixed, Vec2, length}
import engine.nav.{Nav, NavError, Path}
import engine.world.{Spawn, View}
import engine.list.{fold, last}
import warren_world.{Rabbit, Ferret, Burrow}
import warren.{warren_spawns}

@doc("How far the ferret advances each tick.")
let FERRET_SPEED: Fixed = 1.0

@doc("How far the rabbit advances each tick — slower than the ferret, so a chase converges.")
let RABBIT_SPEED: Fixed = 0.8

@doc("How close counts as having reached a waypoint.")
let ARRIVE: Fixed = 1.0

@doc("Seconds between the ferret's own re-path queries — the behavior's clock, not an engine cadence.")
let REPATH_TIME: Fixed = 0.5

@doc("How far the goal may sit from the cached route's end before the route counts as stale.")
let DRIFT: Fixed = 4.0

@doc("The empty route: nothing to follow, so the next plan must come from a fresh query.")
let NO_ROUTE: Path = Path{steps: [], cost: 0.0}

@doc("A position stepped toward a target by at most `speed`, snapping to the target on the last step. Pure motion, no nav.")
@gtag("ai")
fn step_to(from: Vec2, to: Vec2, speed: Fixed) -> Vec2 {
  let delta = to - from
  let d = length(delta)
  if d <= speed { return to }
  return from + delta * speed / d
}

@doc("The scoring step of the quarry fold: a hidden rabbit is skipped, a nearer open one replaces the best so far.")
@gtag("ai")
fn closer(from: Vec2, acc: Option[Vec2], r: Rabbit) -> Option[Vec2] {
  if r.hidden { return acc }
  return match acc {
    Option::None => Option::Some(r.pos)
    Option::Some(b) => if length(r.pos - from) < length(b - from) { Option::Some(r.pos) } else { Option::Some(b) }
  }
}

@doc("The position of the nearest rabbit still in the open, or the point itself when every rabbit is hidden (a ferret with no quarry holds still).")
@gtag("ai")
fn nearest_rabbit(from: Vec2, rabbits: View[Rabbit]) -> Vec2 {
  let best = fold(rabbits, Option::None, fn(acc, r) { return closer(from, acc, r) })
  return or_else(best, from)
}

@doc("The route to keep: the fresh result when the query succeeded, the cached route when it failed. The errors-as-values shape — a failed path() is a matched value, never a silently-empty route.")
@gtag("ai")
fn routed(found: Result[Path, NavError], cached: Path) -> Path {
  return match found {
    Result::Ok(p) => p
    Result::Err(_) => cached
  }
}

@doc("Whether the goal has drifted away from the cached route's end — or there is no route at all. One of the two author-owned reasons to re-path.")
@gtag("ai")
fn drifted(route: Path, goal: Vec2) -> Bool {
  return match last(route.steps) {
    Option::Some(end) => length(goal - end) > DRIFT
    Option::None => true
  }
}

@doc("Whether to issue a fresh path(): the countdown elapsed, or the goal drifted off the cached route. Both reasons are the behavior's own logic — there is no engine replan cadence to lean on.")
@gtag("ai")
fn replan_due(t: Fixed, route: Path, goal: Vec2) -> Bool {
  return t <= 0.0 or drifted(route, goal)
}

@doc("One follow step: the next waypoint and the remaining route from advance(), matched exhaustively; an exhausted route holds position. Following a path is a fold.")
@gtag("ai")
fn follow(self: Ferret, route: Path, timer: Fixed) -> Ferret {
  return match route.advance(self.pos, ARRIVE) {
    (Option::Some(wp), rest) => self with { pos: step_to(self.pos, wp, FERRET_SPEED), path: rest, repath_t: timer }
    (Option::None, _) => self with { path: route, repath_t: timer }
  }
}

@doc("Chases the nearest open rabbit through the baked graph. A clear los() is the shortcut — dash straight and drop the route; otherwise follow the cached path, re-querying only when the countdown elapses or the rabbit drifts off it.")
@gtag("ai")
behavior stalk on Ferret {
  fn step(self: Ferret, nav: Nav, rabbits: View[Rabbit], time: Time) -> Ferret {
    let goal = nearest_rabbit(self.pos, rabbits)
    if nav.los(self.pos, goal) { return self with { pos: step_to(self.pos, goal, FERRET_SPEED), path: NO_ROUTE, repath_t: 0.0 } }
    let t = self.repath_t - time.dt
    if replan_due(t, self.path, goal) {
      let route = routed(nav.path(self.pos, goal), self.path)
      return follow(self, route, REPATH_TIME)
    }
    return follow(self, self.path, t)
  }
}

@doc("The goal a single burrow offers, if any: its mouth snapped onto walkable space with nearest(), then pre-checked with reachable() — the cheap yes/no — before any route is materialized. The sealed burrow fails the check and offers nothing.")
@gtag("ai")
fn burrow_goal(nav: Nav, from: Vec2, b: Burrow) -> Option[Vec2] {
  return match nav.nearest(b.pos) {
    Option::Some(mouth) => if nav.reachable(from, mouth) { Option::Some(mouth) } else { Option::None }
    Option::None => Option::None
  }
}

@doc("The first burrow that is a real goal — a first-wins fold over each burrow's offered goal, so the sealed burrow is skipped and the open one is taken in declaration order.")
@gtag("ai")
fn open_burrow(nav: Nav, from: Vec2, burrows: View[Burrow]) -> Option[Vec2] {
  return fold(burrows, Option::None, fn(acc, b) { return match acc {
    Option::Some(g) => Option::Some(g)
    Option::None => burrow_goal(nav, from, b)
  } })
}

@doc("One escape step toward a chosen burrow mouth: the naive repath-every-tick the spec blesses (the engine dedups identical queries), holding the cached route when the query fails. An exhausted route means the rabbit is at the mouth, so it hides.")
@gtag("ai")
fn run_for(self: Rabbit, nav: Nav, goal: Vec2) -> Rabbit {
  let route = routed(nav.path(self.pos, goal), self.path)
  return match route.advance(self.pos, ARRIVE) {
    (Option::Some(wp), rest) => self with { pos: step_to(self.pos, wp, RABBIT_SPEED), path: rest }
    (Option::None, _) => self with { path: NO_ROUTE, hidden: true }
  }
}

@doc("Runs for the first reachable burrow and vanishes into it; with every burrow sealed or off-nav the rabbit has nowhere to go and freezes.")
@gtag("ai")
behavior bolt on Rabbit {
  fn step(self: Rabbit, nav: Nav, burrows: View[Burrow]) -> Rabbit {
    if self.hidden { return self }
    return match open_burrow(nav, self.pos, burrows) {
      Option::Some(g) => run_for(self, nav, g)
      Option::None => self
    }
  }
}

@doc("No device-driven input: both animals are level-placed and AI-driven, so the bindings table is empty.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
}

@doc("Loads the Warren level at startup — the generated, deterministic spawn list replaces a hand-written setup().")
@gtag("startup")
fn setup() -> [Spawn] {
  return warren_spawns()
}

@doc("A chase through a baked maze: the graph is derived from the level's tilemap solids, both AIs are pure folds over the injected Nav, and nothing re-paths except on the animals' own logic.")
@gtag("game")
pipeline WarrenGame {
  startup: [setup]
  ai:      [stalk, bolt]
}

@doc("A failed query is a value: the cached route is held on Err, the fresh route taken on Ok — both NavError cases matched.")
test "routed holds the last good route on a failed query" {
  let cached = Path{steps: [Vec2{x: 8.0, y: 8.0}], cost: 8.0}
  let fresh = Path{steps: [Vec2{x: 16.0, y: 8.0}], cost: 16.0}
  assert routed(Result::Ok(fresh), cached) == fresh
  assert routed(Result::Err(NavError::Unreachable), cached) == cached
  assert routed(Result::Err(NavError::OffNav), cached) == cached
}

@doc("Drift detection: a goal near the route's end keeps the route; a goal far from it — or no route at all — forces a fresh query.")
test "drifted fires on a moved goal or an empty route" {
  let route = Path{steps: [Vec2{x: 8.0, y: 8.0}, Vec2{x: 16.0, y: 8.0}], cost: 16.0}
  assert drifted(route, Vec2{x: 16.0, y: 8.0}) == false
  assert drifted(route, Vec2{x: 16.0, y: 40.0}) == true
  assert drifted(NO_ROUTE, Vec2{x: 16.0, y: 8.0}) == true
}

@doc("The re-path decision is the behavior's own: an elapsed countdown or a drifted goal, nothing else.")
test "replan_due is countdown or drift, never an engine cadence" {
  let route = Path{steps: [Vec2{x: 16.0, y: 8.0}], cost: 16.0}
  assert replan_due(0.0, route, Vec2{x: 16.0, y: 8.0}) == true
  assert replan_due(0.5, route, Vec2{x: 16.0, y: 40.0}) == true
  assert replan_due(0.5, route, Vec2{x: 16.0, y: 8.0}) == false
}

@doc("Following is a fold over the (next waypoint, remaining route) tuple: the ferret steps toward the waypoint; an exhausted route holds position and keeps the timer.")
test "follow advances along the route and holds at its end" {
  let f = Ferret{pos: Vec2{x: 0.0, y: 0.0}}
  let route = Path{steps: [Vec2{x: 10.0, y: 0.0}], cost: 10.0}
  let after = follow(f, route, REPATH_TIME)
  assert after.pos == Vec2{x: 1.0, y: 0.0}
  assert after.repath_t == REPATH_TIME
  assert follow(f, NO_ROUTE, REPATH_TIME).pos == Vec2{x: 0.0, y: 0.0}
}

@doc("Stepping toward a target nearer than one step snaps onto it.")
test "step_to snaps within one step" {
  assert step_to(Vec2{x: 0.0, y: 0.0}, Vec2{x: 0.5, y: 0.0}, FERRET_SPEED) == Vec2{x: 0.5, y: 0.0}
}

@doc("A hidden rabbit is no quarry: targeting skips it; with nothing in the open the ferret's own position comes back (it holds still).")
test "nearest_rabbit picks the closest open rabbit, falls back to self" {
  let from = Vec2{x: 0.0, y: 0.0}
  let rabbits = View.of([Rabbit{pos: Vec2{x: 9.0, y: 0.0}}, Rabbit{pos: Vec2{x: 3.0, y: 0.0}, hidden: true}, Rabbit{pos: Vec2{x: 5.0, y: 0.0}}])
  assert nearest_rabbit(from, rabbits) == Vec2{x: 5.0, y: 0.0}
  assert nearest_rabbit(from, View.of([])) == from
}

@doc("On the fixture los() reads clear, so the ferret takes the straight dash — the shortcut that skips pathing entirely — and drops its route.")
test "stalk dashes straight when los is clear" {
  let nav = Nav.of(Path{steps: [Vec2{x: 10.0, y: 0.0}], cost: 10.0})
  let rabbits = View.of([Rabbit{pos: Vec2{x: 10.0, y: 0.0}}])
  let f = Ferret{pos: Vec2{x: 0.0, y: 0.0}}
  let after = stalk.step(f, nav, rabbits, Time.at(0.016))
  assert after.pos == Vec2{x: 1.0, y: 0.0}
  assert after.path == NO_ROUTE
}

@doc("Goal selection through the fixture: nearest() snaps the mouth (the fixture snap is the identity) and reachable() passes, so the first burrow wins.")
test "open_burrow snaps and pre-checks the first burrow" {
  let nav = Nav.of(NO_ROUTE)
  let burrows = View.of([Burrow{pos: Vec2{x: 20.0, y: 4.0}}])
  assert open_burrow(nav, Vec2{x: 4.0, y: 4.0}, burrows) == Option::Some(Vec2{x: 20.0, y: 4.0})
}

@doc("With a pure nav fixture the escape is a fold: the rabbit advances one step along the route toward the burrow, and a hidden rabbit no longer moves.")
test "bolt runs the rabbit along the fixture route" {
  let nav = Nav.of(Path{steps: [Vec2{x: 8.0, y: 0.0}], cost: 8.0})
  let burrows = View.of([Burrow{pos: Vec2{x: 8.0, y: 0.0}}])
  let r = Rabbit{pos: Vec2{x: 0.0, y: 0.0}}
  assert bolt.step(r, nav, burrows).pos == Vec2{x: 0.8, y: 0.0}
  assert bolt.step(r with { hidden: true }, nav, burrows).pos == Vec2{x: 0.0, y: 0.0}
}

@doc("An exhausted route means arrival: the rabbit hides and the chase loses its quarry.")
test "an arrived rabbit hides in the burrow" {
  let r = Rabbit{pos: Vec2{x: 8.0, y: 0.0}}
  let after = run_for(r, Nav.of(NO_ROUTE), Vec2{x: 8.0, y: 0.0})
  assert after.hidden == true
}

@doc("The Err-arm twin of Nav.of: Nav.fail(err) makes every query fail coherently, so the errors-as-values path is a real fixture — path() is a genuine Result::Err, reachable/los read false, nearest reads None — not a hand-built Result fed to routed().")
test "Nav.fail fails every query coherently" {
  let nav = Nav.fail(NavError::Unreachable)
  assert nav.path(Vec2{x: 0.0, y: 0.0}, Vec2{x: 8.0, y: 8.0}) == Result::Err(NavError::Unreachable)
  assert nav.reachable(Vec2{x: 0.0, y: 0.0}, Vec2{x: 8.0, y: 8.0}) == false
  assert nav.los(Vec2{x: 0.0, y: 0.0}, Vec2{x: 8.0, y: 8.0}) == false
  assert nav.nearest(Vec2{x: 4.0, y: 4.0}) == Option::None
}
