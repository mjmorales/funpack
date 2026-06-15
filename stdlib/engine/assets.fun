@doc("Content handles. A handle is a small serializable reference to a baked, content-hashed asset — resolved by the engine, cheap to store in a blackboard, stable across replays. Loading is by stable name, checked against the build manifest (an unknown name is a compile error), and the bake also generates typed handle constants per asset; the string constructors here are the dynamic, manifest-checked form. See spec/19-assets.md for the pipeline.")

import engine.prelude.{Int, Fixed}

@doc("A reference to a baked mesh, by stable name. Produced by the .fpm bake; resolved at render time.")
data MeshHandle { name: String }

@doc("A reference to a texture, by stable name.")
data TextureHandle { name: String }

@doc("A reference to a sound, by stable name.")
data SoundHandle { name: String }

@doc("A reference to a baked sprite atlas (a sheet of named cells and named animation clips), by stable name.")
data AtlasHandle { name: String }

@doc("The mesh handle for a baked model name. Total: an unknown name is a build-time error, not a runtime failure.")
extern fn mesh(name: String) -> MeshHandle
@doc("The texture handle for a name.")
extern fn texture(name: String) -> TextureHandle
@doc("The sound handle for a name.")
extern fn sound(name: String) -> SoundHandle
@doc("The atlas handle for a baked sprite-sheet name.")
extern fn atlas(name: String) -> AtlasHandle

@doc("The region id of a grid cell (column, row) in an atlas, for Draw::Sprite.cell.")
extern fn cell(self: AtlasHandle, col: Int, row: Int) -> String
@doc("The region id of a named animation clip at time t — deterministic (fixed-point clock), so animated sprites replay identically.")
extern fn frame(self: AtlasHandle, clip: String, t: Fixed) -> String
