@doc("3D spatial navigation: the Vec3/navmesh twin of engine.nav, identical in shape and contract. A 3D level bakes a walkable navmesh from its geometry; the active mesh arrives as the injected Nav3 resource, and path3() is the same pure, total, replay-safe query. Agent AI code differs from 2D only in the vector type. See spec/12-navigation.md.")

import engine.prelude.{Bool, Fixed, Option, Result, String}
import engine.math.Vec3
import engine.level.LevelHandle

@doc("The active level's baked 3D navmesh, injected by the engine. Presence in a signature is the positive signal that a behavior consults navigation; absence guarantees it does not.")
extern type Nav3

@doc("A specific baked navmesh layer by name, for a game with more than the one layer a level exposes by default. The escape hatch.")
data NavHandle3 { name: String }

@doc("The named navmesh layer of a baked level. An unknown name is a build-time error.")
extern fn layer3(level: LevelHandle, name: String) -> NavHandle3

@doc("A deterministic 3D route: ordered waypoints (navmesh portal corners) from start to goal, plus total fixed-point cost. Plain serializable data; replay re-derives the same one.")
data Path3 { steps: [Vec3], cost: Fixed }

@doc("Why a route could not be produced. A value you must match.")
enum NavError3 { Unreachable, OffNav }

@doc("The 3D path query. Pure, total, deterministic; write the naive repath, the engine dedups. An off-mesh endpoint is an error — snap it with nearest3() first.")
extern fn path3(self: Nav3, from: Vec3, to: Vec3) -> Result[Path3, NavError3]

@doc("Whether a route exists at all, without materializing waypoints.")
extern fn reachable3(self: Nav3, from: Vec3, to: Vec3) -> Bool

@doc("Whether a straight segment is unobstructed on the navmesh.")
extern fn los3(self: Nav3, from: Vec3, to: Vec3) -> Bool

@doc("The nearest on-mesh point to an arbitrary point, or None if the mesh is empty.")
extern fn nearest3(self: Nav3, point: Vec3) -> Option[Vec3]

@doc("The next waypoint to steer toward and the remaining path, given current position and arrival radius. Pure; None means arrived.")
extern fn advance3(self: Path3, pos: Vec3, arrive: Fixed) -> (Option[Vec3], Path3)
