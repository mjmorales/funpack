@doc("The runtime surface for levels. A .flvl level bakes to a per-level generated module (a deterministic spawn list + a typed Ref table of its named instances; see spec/17-levels.md) plus a content-hashed LevelHandle for streaming. This module holds what the running game touches: the handle, the Load/Unload streaming commands, and Volume for regions and triggers. A level loads to a bit-identical world (named instances get name-derived ids), so it is also the canonical snapshot/save shape (spec/08-state.md).")

import engine.prelude.{String, Bool, Fixed}
import engine.math.{Vec2, Vec3}

@doc("A baked level or sub-level, referenced by stable name. Resolved by the engine; cheap to store.")
data LevelHandle { name: String }

@doc("The level handle for a baked level name. An unknown name is a build-time error, not a runtime failure.")
extern fn level(name: String) -> LevelHandle

@doc("A command to stream a level/chunk into the world at an origin offset (2D levels ignore z). Its named instances keep their name-derived ids, so references stay valid.")
data Load { level: LevelHandle, at: Vec3 }

@doc("A command to stream a loaded level/chunk back out.")
data Unload { level: LevelHandle }

@doc("A spatial volume for a region or trigger. Rect for 2D, Box/Sphere for 3D.")
enum Volume {
  Rect{ min: Vec2, max: Vec2 },
  Box{ min: Vec3, max: Vec3 },
  Sphere{ center: Vec3, radius: Fixed }
}

@doc("Whether a 3D point lies inside the volume (a 2D point uses z = 0).")
extern fn contains(self: Volume, point: Vec3) -> Bool
