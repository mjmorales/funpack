---
name: funpack-content
description: Add content to a funpack game through the bake pipelines — sprites & atlases, levels (.flvl), tilemaps (.tiles + ASCII grids), rigged 3D models (.fpm), UI screens (.fui), and audio. Use when adding art, a level, a tile map, a character model, a menu/HUD, or sound to a game. Covers the authoring source formats, the generated gen/*.gen.fun seams, the typed handles/Refs, and the bake gates. Triggers on "add a sprite/atlas", "Draw::Sprite", ".flvl/level", ".tiles/tilemap", ".fpm/model/rig", ".fui/UI/HUD/menu", "funpack audio/sound/music", "asset manifest", "gen seam".
---

# funpack content — the bake pipelines

Every authored asset follows one shape:

> **`source → importer → (content-hashed asset + generated `.gen.fun` seam)`**

The importer is a deterministic pure function inside `funpack`; the content hash is identity +
cache key; the `.gen.fun` **seam** is the committed, typed, diffable contract your game imports. Game
`.fun` code **never sees the source DSL** — only the seam. A stale committed seam, or a name not in
the manifest, is a **compile error**.

| Source | Authored as | Seam exposes |
|---|---|---|
| `.atlas` sprite sheet | image + slice spec | `AtlasHandle` (+ named cells/clips) |
| audio (WAV/OGG) | raw | `SoundHandle` |
| `.flvl` level | DSL | a `Ref` table, `*_spawns()`, `TilemapHandle` |
| `.tiles` tileset | DSL | `TilesetHandle` |
| `.fpm` model/rig | DSL | params `data`, anchors, `MeshHandle` / skeleton + parts |
| `.fui` screen | DSL | a view-model `data`, a `Msg` enum, a view fn |

This SKILL.md is the **how-to per pipeline**; for the full grammars, gates, and worked seam slices,
read `references/pipelines.md` in this skill directory. The runtime types you call (`engine.assets`,
`engine.level`, `engine.tilemap`, `engine.anim`, `engine.ui`, `engine.audio`) are in the
`funpack-engine-api` skill; the schema/seam/behavior module split is in `funpack-project`.

## Add a sprite (atlas)

1. Write `assets/<name>.atlas` beside its PNG:
   ```
   atlas Pickups {
     image "pickups.png"
     grid  8 8
     cell coin at (0, 0)
     cell gem  at (1, 0)
     clip spin cells ["coin", "gem", "key", "gem"] fps 8
   }
   ```
2. The bake generates `gen/assets.gen.fun` with a typed constant: `let pickups: AtlasHandle = …`.
3. Draw it from a render behavior:
   ```funpack
   import assets
   behavior draw_coin on Coin {
     fn step(self: Coin) -> [Draw] {
       return [Draw::Sprite{ atlas: assets.pickups, cell: assets.pickups.frame("spin", self.spin_t),
                             at: self.pos, size: Vec2{x: 8.0, y: 8.0}, tint: Color::White, flip: Flip::None, layer: 5 }]
     }
   }
   ```
A static cell is `"coin"` or `atlas.cell(col, row)`; an animation frame is `atlas.frame(clip, t)`
(total, deterministic). Prefer the typed constant `assets.coin_sfx` over `sound("coin_sfx")` —
renaming the source then makes readers stop compiling. Release strips any asset no handle references
(and writes a report — never silent).

## Add a level (`.flvl`)

A level is an **initial world** — placed things + params + references — the same shape `setup()`
builds by hand. Write `levels/<name>.flvl`:
```
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world                          // the SCHEMA module whose thing types this places
  place Player hero at center
  place Switch plate at center.offset(y: 40)
  place Door   exit  { gate: plate } at center.offset(y: -40)   // gate: Ref[Switch] resolved from the name `plate`
  for i in 0..5 { place Pillar at center.offset(x: -48 + i * 24, y: 0) }
}
```
`setup()` becomes `return arena_spawns()`; resolve named instances via the generated `Arena` symbol
table / `Ref`s through a `View`. Coordinates are killed by anchors (`center`, `left_edge`,
`.offset(...)`), instance-relative refs, and `for` loops. **References are by name → typed `Ref[T]`**,
resolved at bake; a dangling/duplicate/type-mismatched name is a compile error. Put your `thing`/
`enum`/`signal` in a **schema module** the seam can import without a cycle (see `funpack-project`).

## Add a tilemap (`.tiles` + an ASCII grid)

The grid is the viewport — an ASCII picture you read, edit, and diff. Two parts:

1. A tileset `assets/<name>.tiles` (atlas cell + collision per tile):
   ```
   tileset Dungeon {
     atlas dungeon_atlas
     tile floor { cell: (0, 0), solid: false }
     tile wall  { cell: (1, 0), solid: true }
   }
   ```
2. A `tilemap` layer **inside** a `.flvl` — a legend (chars → tile or spawn) and a grid:
   ```
   tilemap terrain cell 16 {
     legend { '#' wall   '.' floor   'P' spawn Player hero   ' ' empty }
     grid """
       ########
       #.P....#
       ########
     """
   }
   ```
It bakes to a batched tile layer (you never emit per-tile sprites) + a `[Spawn]` per marker + a
`TilemapHandle` in the level seam. Query it: `terrain.solid_at(cell)`, `terrain.tile_at(cell)`,
`terrain.cell_of(pos)`, `terrain.center_of(cell)`. Mutate at runtime with `[SetTile{map, cell, tile}]`
or `[BuildLayer{...}]` (procedural gen folds a seeded `Rng`). Tile names are **project-global** —
keep them unique across all `.tiles`. A wall's `solid` is what the nav graph derives from at bake.

## Add a rigged 3D model (`.fpm`)

funpack has two languages: the `.fpm` modeling DSL (imperative, float-tolerant, **bake-time only**)
and `.fun` (pure, fixed-point) which sees only the seam. Write `models/<name>.fpm`:
```
rig Krognid {
  skeleton: humanoid
  param torso_h: Length = 24
  fn torso_mesh() -> Solid { return capsule(torso_r, torso_h).up(0) }
  part torso at TORSO = torso_mesh()
  mirror L -> R            // model the left side; the right is generated
  material body = pbr(color: teal, rough: 0.7)
}
```
It bakes to a skeleton fn + a part→slot mesh binding. Drive it with **pure pose generators** and
render `Draw3::Rigged`:
```funpack
import krognid.{krognid_skeleton, krognid_parts}
fn pose_walk(phase: Fixed) -> Pose {
  return Pose.empty().set(Bone::LUpperLeg, rot_x(sin(phase) * 0.5)).set(Bone::RUpperLeg, rot_x(-sin(phase) * 0.5))
}
behavior draw_krognid on Krognid {
  fn step(self: Krognid, time: Time) -> [Draw3] {
    let pose = Pose.blend(pose_idle(time.t), pose_walk(self.phase), walk_weight(self.speed))
    return [Draw3::Rigged{ skeleton: krognid_skeleton(), parts: krognid_parts(), pose: pose, at: self.pos }]
  }
}
```
A part's origin must equal its bone pivot. A gameplay-observable bone must be fixed-point (sim
stage); purely cosmetic motion may run float in render. Pose composition: `Pose.blend(a, b, w)`,
`Pose.layer(base, overlay)` — and layering IS pipeline order (`pose: [pose_idle, pose_walk]`).

## Add a UI screen (`.fui`)

A funpack UI is the Elm/React architecture: Model = a view-model `data`, View = `fn(model) -> View[Msg]`,
Messages = signals, Update = ordinary behaviors. Write `ui/<name>.fui`:
```
screen Hud {
  row class="top-bar p-3 gap-4 bg-panel" {
    text { "Score: {score}" }
    button class="btn" @click=Coin { "+1" }
  }
  if game_over { text class="text-2xl" { "Game Over" } }
}
```
The bake **infers both ends as types** from usage — `gen/hud.gen.fun` gets `data HudView { score: Int,
game_over: Bool }`, `enum HudMsg { Coin }`, and `fn hud(model: HudView) -> View[HudMsg]`. You write a
pure **projection** (`fn hud_view(self) -> HudView`), an exhaustive **update** (`fn on_hud(self,
HudMsg) -> App`), and **mount** it: `hud(self.hud_view()).map(AppMsg::Hud)`. Widgets are a closed set
(`panel row col grid stack scroll spacer text image icon button field slider toggle select`); style
is semantic theme tokens (`bg-panel`, `text-2xl`), not raw values. Adding a `@click=Mute` makes
`HudMsg` gain `Mute` → your update's `match` stops compiling, naming exactly where to handle it. The
`ui:` stage runs after `render:`; each `Msg` is delivered as a deferred signal next tick (consume it
in an early interior stage to satisfy effect closure).

## Add audio (two regimes)

Sound is an **effect returned as data** — there is no `play_sound()`.

- **One-shot SFX** (an event happened) → return `[Sound]` from the handling Update behavior, edge-
  triggered, alongside other commands:
  ```funpack
  fn step(self: Coin, taken: [Taken]) -> (Coin, [Sound]) {
    if is_empty(taken) { return (self, []) }
    return (self, [Sound.sfx(assets.coin_sfx).bus(Bus::Sfx)])
  }
  ```
- **Sustained audio** (music, a speed-modulated loop) → an `audio:` behavior returns the keyed set
  that **should be playing now**; the engine diffs by key (appear→start, disappear→stop, same key new
  gain/pitch→bend the live voice, same key new clip→crossfade):
  ```funpack
  behavior locomotion on Krognid {
    fn step(self: Krognid) -> [Audio] {
      if self.speed == 0.0 { return [] }                  // absent ⇒ engine auto-stops the "stride" voice
      return [Audio.track("stride", sound("step")).pitch(0.6 + self.speed * 0.2).gain(clamp(self.speed, 0.0, 1.0)).bus(Bus::Sfx)]
    }
  }
  ```
A settings slider drives volume by feeding its value into the `.gain` of the projection — there is no
mutable global mixer. Buses: `Master / Music / Sfx / Ui / Voice`.

> All grammars, the full gate lists, and complete seam slices are in `references/pipelines.md`. The
> normative examples: `assets` (atlas), `arena` (levels), `dungeon`/`warren` (tilemaps), `krognid`
> (model), `hud` (UI + audio). funpack is under active design — verify edge cases against a compile.
