# stdlib

The engine surface, as funpack **interface files** (signatures, not implementations). The
contract an agent reasons against; bodies live in the native runtime behind the `extern` boundary.
Design principles, the `extern` rules, and the module map are in
[`../spec/26-stdlib.md`](../spec/26-stdlib.md).

These declare the surface — "assume it works." A bare `fn … { … }` here is a Tier-2 (funpack)
shape shown for illustration; `extern fn` / `extern type` is the Tier-1 native boundary.

## Modules (`engine/`)

| File | Module | Owns |
|---|---|---|
| `prelude.fun` | `engine.prelude` | `Bool Int Fixed Float String`, `Option Result Ordering` |
| `math.fun`    | `engine.math`    | `Vec2 Vec3 Quat Mat4 Aabb`; trig, `clamp lerp length dot`; `pi tau` |
| `list.fun`    | `engine.list`    | `[T]`: `map filter fold get len …` |
| `map.fun`     | `engine.map`     | `Map[K,V]`: `get set has keys values` |
| `core.fun`    | `engine.core`    | `Time TickRate` |
| `world.fun`   | `engine.world`   | `Spawn Despawn View[T] Id` |
| `input.fun`   | `engine.input`   | `Input Key Stick PlayerId Bindings`, `Axis Button` |
| `geom.fun`    | `engine.geom`    | `Sketch Path PathOp` (2D↔3D bridge) |
| `render.fun`  | `engine.render`  | `Draw` (incl. `Sprite`) `Color Align Flip` |
| `render3.fun` | `engine.render3` | `Draw3 Material` |
| `anim.fun`    | `engine.anim`    | `Bone Slot Side Skeleton Pose Transform PartSet` |
| `model.fun`   | `engine.model`   | `Length Solid Anchors Shape3` (the `.gen.fun` surface) |
| `assets.fun`  | `engine.assets`  | `MeshHandle TextureHandle SoundHandle AtlasHandle`; `atlas cell frame` |
| `rand.fun`    | `engine.rand`    | `Rng`: `seed next pick range chance split` |
| `grid.fun`    | `engine.grid`    | `Cell`, `grid_cells` |
| `string.fun`  | `engine.string`  | `String`: `split slice join contains parse_int from_fixed …` |
| `ui.fun`      | `engine.ui`      | `View[Msg]`; `panel row col text button field slider class when` (see [`../spec/21-ui.md`](../spec/21-ui.md)) |
| `audio.fun`   | `engine.audio`   | `Sound` (one-shot), `Audio` (keyed/diffed), `Bus`; `sfx track gain pitch` (see [`../spec/22-audio.md`](../spec/22-audio.md)) |
| `level.fun`   | `engine.level`   | `LevelHandle`, `Load`/`Unload`, `Volume`; per-level seam is generated (see [`../spec/17-levels.md`](../spec/17-levels.md)) |
| `tilemap.fun` | `engine.tilemap` | `TilesetHandle TilemapHandle`, `tile_at solid_at cell_of`, `SetTile` (see [`../spec/18-tilemaps.md`](../spec/18-tilemaps.md)) |
