@doc("Spatial navigation: deterministic pathfinding over a level's baked nav graph. The graph is derived at bake from tilemap solids (grid) or level geometry (navmesh) — never hand-built, exactly as a level is never hand-spawned. The active level's graph arrives as the injected Nav resource; path() is a pure, total, replay-safe query, so AI is unit-testable as a plain fold. Cost is the engine's contract, not the agent's API: identical queries are deduped per stage and may be backed by an incremental flow field. See spec/12-navigation.md.")

import engine.prelude.{Bool, Fixed, Option, Result, String}
import engine.math.Vec2
import engine.level.LevelHandle

@doc("The active level's baked navigation graph, injected by the engine like Input or Time. Presence in a behavior's signature is the positive signal that it consults navigation; absence is the guarantee that it does not.")
extern type Nav

@doc("A specific baked nav layer by name (e.g. \"ground\", \"flying\"), for the rare game that needs more than the one layer a level exposes by default. The escape hatch — most games take the Nav resource and never name a layer.")
data NavHandle { name: String }

@doc("The named nav layer of a baked level. An unknown name is a build-time error, not a runtime failure.")
extern fn layer(level: LevelHandle, name: String) -> NavHandle

@doc("A deterministic route: ordered waypoints from start to goal, plus its total fixed-point cost. Plain serializable data — store it on a blackboard and replay re-derives the same one. Grid nav emits cell centers; a navmesh emits portal corners.")
data Path { steps: [Vec2], cost: Fixed }

@doc("Why a route could not be produced. A value you must match — there is no silently-empty path.")
enum NavError { Unreachable, OffNav }

@doc("The path query. Pure, total, deterministic (fixed tie-break, fixed-point cost), so it replays bit-identically and tests as a plain function. Write the naive repath-every-tick; the engine dedups and caches identical queries. An off-nav endpoint is an error, not a guess — snap it with nearest() first if the target may leave walkable space.")
extern fn path(self: Nav, from: Vec2, to: Vec2) -> Result[Path, NavError]

@doc("Whether a route exists at all, without materializing its waypoints. Cheaper than path() when only the yes/no matters (line-of-fire gating, target selection).")
extern fn reachable(self: Nav, from: Vec2, to: Vec2) -> Bool

@doc("Whether a straight segment is unobstructed on the nav. For string-pulling a path or shortcutting a corner without a full search.")
extern fn los(self: Nav, from: Vec2, to: Vec2) -> Bool

@doc("The nearest on-nav point to an arbitrary point, or None if the nav is empty. Snaps an off-nav target onto walkable space before path().")
extern fn nearest(self: Nav, point: Vec2) -> Option[Vec2]

@doc("The next waypoint to steer toward and the remaining path, given the current position and the arrival radius. Pure, so a path-follower is a fold over ticks; None means the route is exhausted (arrived).")
extern fn advance(self: Path, pos: Vec2, arrive: Fixed) -> (Option[Vec2], Path)

@doc("A fixture Nav for behavior tests: path() returns the supplied route, los/reachable read true, and nearest(p) is the identity snap — Some(p), echoing the point back (the engine's nearest finds the genuinely-closest walkable cell; the fixture's stand-in is the identity, so an off-nav target maps to itself). The deterministic stand-in a test passes where a baked graph would be, mirroring View.of. Invoked Nav.of(route).")
extern fn of(route: Path) -> Nav

@doc("The Err-arm twin of Nav.of: a fixture Nav whose every query fails with the given error — path() yields Result::Err(err), reachable and los read false, and nearest yields None. Pass it where a test exercises the failed-query branch (errors-as-values), so the Err path is a real fixture rather than a hand-built Result. Invoked Nav.fail(err).")
extern fn fail(err: NavError) -> Nav
