# funpack bake pipelines — full reference

Grammars, generated seams, gates, and worked slices for each authoring pipeline. Distilled from
the spec `spec/{16,17,18,19,21,22}.md`, `grammar/{atlas,flvl,fpm,fui,tiles,manifest}.ebnf`, and
the example projects. **[FLAG]** marks where examples/prose diverge or a detail is spec-only.

## The universal shape

`source → importer → (content-hashed asset + generated .gen.fun seam)`. The hash is
`H(source bytes ⊕ importer version ⊕ dependency hashes)` — identity + cache key. Editing a source
re-bakes only it and its dependents. Game `.fun` imports the **seam**, never the source DSL. A stale
committed seam or an unknown name is a compile error.

---

## 1. Assets (atlas, audio, the manifest)

### `.atlas` source (`grammar/atlas.ebnf`)
```
atlas Pickups {
  image "pickups.png"                  // a hash dependency
  grid  8 8                            // each cell is 8x8 in the sheet
  cell coin at (0, 0)
  cell gem  at (1, 0)
  clip spin cells ["coin", "gem", "key", "gem"] fps 8
}
```
Raw audio (WAV/OGG) and fonts (TTF) have no DSL — a binary importer content-hashes them directly.

### The manifest (generated, committed — the name registry, `grammar/manifest.ebnf`)
INI/TOML shape; `#` comments; the source of truth for resolving a handle.
```
[pickups]
kind = atlas ; source = "pickups.atlas" ; importer = "atlas@2"
deps = ["pickups.png@sha256:02d0…"] ; hash = "sha256:5379…" ; out = ".cache/53/79b6…/pickups.atlas"
[coin_sfx]
kind = audio ; source = "audio/coin.wav" ; importer = "audio@1" ; deps = [] ; hash = "sha256:b8c8…"
```
Names are folder-namespaced and lowercase (`[audio/coin]`).

### The seam (`gen/assets.gen.fun`)
```funpack
import engine.assets.{MeshHandle, AtlasHandle, SoundHandle}
@gtag("assets") let coin: MeshHandle = MeshHandle{name: "coin"}
@gtag("assets") let pickups: AtlasHandle = AtlasHandle{name: "pickups"}
@gtag("assets") let coin_sfx: SoundHandle = SoundHandle{name: "coin_sfx"}
```

### Rules / gates
- **Closed name registry, compile-checked**: a name not in the manifest is a compile error.
- Two addressing forms: the typed constant `assets.coin_sfx` (safe default — rename source ⇒
  constant disappears ⇒ readers stop compiling) and string constructors `mesh("…")`/`atlas("…")`/
  `sound("…")` (dynamic, still manifest-checked). `assert assets.coin_sfx == sound("coin_sfx")`.
- **Dead-asset elimination on release**: release bakes everything, strips any asset no handle
  references, and writes `assets.report.txt` (truncation is never silent). A baked-but-unreferenced
  asset is normal in dev; only release strips it.
- Per-platform texture compression and streaming/residency have **no authoring surface** — folded
  behind the typed handle, which is always valid. There is no load/unload API for assets.

---

## 2. Levels (`.flvl`, `grammar/flvl.ebnf`)

A level is an initial world (placed things + params + references), the same shape `setup()` builds
and a save deserializes to. Lowers one-way to a deterministic spawn list + typed seam.

```
level Arena 2d {                                  // 2d|3d header sets coordinate arity
  bounds (0, 0) (160, 120)
  things arena_world                              // the schema module whose thing types this places
  prefab Turret {
    place Base   base   at origin
    place Cannon cannon { rate: 2.0 } at base.offset(y: 6)
  }
  place Player hero at center
  place Switch plate at center.offset(y: 40)
  place Door   exit  { gate: plate } at center.offset(y: -40)   // gate: Ref[Switch] resolved from name `plate`
  for i in 0..5 { place Pillar at center.offset(x: -48 + i * 24, y: 0) }
  place Turret right_gun { cannon.rate: 4.0 } at right_edge.center.offset(x: -12)   // override nested by path
}
```
- **`place <Type> <name>? { params }? at <where> [facing <rot>]`** — instantiates a `thing`; the
  optional `<name>` is the seam-exposed handle (anonymous → not in the seam).
- **Reserved fields**: `at` writes `pos` (must be declared, of the level's arity); `facing` writes
  `facing`. The *name*, not the type, is the contract.
- **Killing raw coordinates**: bounds anchors (`center`, `left_edge`, `right_edge.center`,
  `.offset(x:,y:[,z:])`); instance-relative (`base.top`, `above(table)`); model sockets
  (`table.socket("cup")`); repetition (`for i in 0..N`).
- **References by name → typed `Ref[T]`**, resolved + typechecked at bake; nonexistent/duplicate/
  type-mismatched is a compile error (dangling refs are unrepresentable).
- **Prefabs** nest to any depth; members addressed by dotted path (`right_gun.cannon.rate`);
  overrides apply at any depth (outer over nested default, declaration order).

### The seam (`gen/arena.gen.fun`) — imports the **schema module only**
```funpack
import engine.world.{Spawn, Ref}
import arena_world.{Player, Hunter, Pillar, Switch, Door, Base, Cannon}
data ArenaTurret { base: Ref[Base], cannon: Ref[Cannon] }
data Arena { hero: Ref[Player], stalker: Ref[Hunter], plate: Ref[Switch], exit: Ref[Door], left_gun: ArenaTurret, right_gun: ArenaTurret }
extern fn arena_spawns() -> [Spawn]   // deterministic, declaration order, prefabs/loops expanded
extern fn arena() -> Arena            // the symbol table, valid once the level is loaded
```
**Stable ids by name**: a named instance's `Id` derives from its level-qualified name, so its `Ref`
is constant across loads/saves/replays; anonymous scenery takes declaration-order counter ids.

### Consume it
```funpack
import arena.{arena_spawns, Arena, arena}
fn setup() -> [Spawn] { return arena_spawns() }
behavior gate_logic on Door {
  fn step(self: Door, switches: View[Switch]) -> Door {
    return self with { open: gate_open(switches.resolve(self.gate)) }   // resolve the baked Ref[Switch]
  }
}
```

### The 3-way module split (required whenever a seam names your types)
schema module (things/data/enums only, engine imports only) ← generated seam (imports schema only) ←
behavior module (imports both). A seam importing a behavior module is a compile error. Small games
with no type-referencing seam (Pong) need no split.

### Gates (all compile errors)
unresolved/duplicate names; type-mismatched references; params/overrides not on the schema; an `at`
without a matching `pos`; placement outside `bounds`; a seam importing a behavior module; a prefab
member referenced but not placed. Coordinates are fixed-point ⇒ bit-identical load everywhere.
`include "town/market.flvl"` splits across files; chunks stream via `Load{level, at}`/`Unload{level}`
over a `LevelHandle`. The lowering is one-way — a snapshot dump preserves names, never the sugar.

---

## 3. Tilemaps (`.tiles` + the ASCII grid inside a `.flvl`)

> The grid is the viewport — an ASCII picture the agent reads/edits/diffs; the same grid paints
> environment AND places entities.

### (a) The tileset `.tiles` (`grammar/tiles.ebnf`)
```
tileset Dungeon {
  atlas dungeon_atlas
  tile floor  { cell: (0, 0), solid: false }
  tile wall   { cell: (1, 0), solid: true }
  tile water  { cell: (2, 0), solid: false, tags: ["liquid"] }
  tile rubble { cell: (3, 0), solid: true, tags: ["diggable"] }
}
```
Collision is baked into the tile layer (fixed-point) — behaviors query it with no per-tile things.
**One flat, project-global tile namespace**: a tilemap names no tileset (it uses bare tile names);
two tilesets declaring the same tile name is a bake error — keep tile names unique across all
`.tiles`.

### (b) The tilemap layer (inside a `level`, `grammar/flvl.ebnf` Tilemap rule)
```
tilemap terrain cell 16 {                 // layer `terrain`; each cell is 16 logical units
  legend {
    '#' wall          '.' floor          '~' water          '%' rubble
    'g' spawn Slime                       // anonymous marker — repeats freely
    'P' spawn Player hero                 // named marker — must appear exactly once
    ' ' empty
  }
  grid """
    ################
    #.P....#...g...#
    #..~~..%.......#
    ################
  """
}
place Chest loot { gems: 5 } at cell(13, 4)    // the relational few: explicit place + the cell() anchor
```
Grid handles spatial bulk; `place` handles the relational few, tied to the grid via `cell(col,row)`.
A legend bind is a tile name, `spawn UPPER_IDENT name?`, or `empty`. Common leading indentation is
stripped before the rectangularity check.

### Bakes to
A batched **tile layer** (rendered/collided by the engine — you never emit per-tile `Draw::Sprite`);
a **`[Spawn]`** per marker at its cell center (row-major declaration order ⇒ deterministic ids); the
level seam gains named markers as `Ref`s and the layer as a `TilemapHandle`. The tileset becomes a
`TilesetHandle` in the asset seam.
```funpack
let terrain: TilemapHandle = TilemapHandle{name: "terrain"}
data Dungeon { hero: Ref[Player], loot: Ref[Chest] }
extern fn dungeon_spawns() -> [Spawn]
```

### Consume it
```funpack
import engine.tilemap.{TilemapHandle, SetTile, tile_at, solid_at, cell_of, center_of}
import dungeon.{dungeon_spawns, terrain}
fn walk(self: Player, d: Dir) -> Player {
  let target = step_cell(terrain.cell_of(self.pos), d)
  return self with { pos: enter(terrain, target, self.pos), dir: d }     // gate movement on the baked layer
}
behavior dig on Player {
  fn step(self: Player, input: Input) -> [SetTile] {
    let target = step_cell(terrain.cell_of(self.pos), self.dir)
    if input.pressed(PlayerId::P1, Act::Dig) and diggable(terrain.tile_at(target)) {
      return [SetTile{map: terrain, cell: target, tile: "floor"}]
    }
    return []
  }
}
```
Only actors draw (`Draw::Sprite`); the layer self-renders. Test handle-touching behaviors with
`TilemapHandle.of(cell_size, [(cell, tile, solid), …])`.

### Runtime mutation (committed world state, not bake decoration)
`SetTile{map, cell, tile}` edits one cell; `BuildLayer{map, fill, cells}` atomically replaces a whole
layer (procedural gen — fold a seeded `Rng` in an ordinary behavior; generation never makes the
runtime compile source). Both re-derive render + collision + nav, carry across hot-reload, ride the
save snapshot. The extent + tileset stay declared once by the `.flvl`.

### Gates (compile errors)
a char not in the legend; a non-rectangular grid; a tile name in no tileset; a duplicate named
marker; a marker without a `pos` of the level's arity; an unresolved reference; a `cell()` outside
the grid. A maze's `solid` walls are the single source the nav graph derives from at bake (the
picture IS the topology — see `warren`). **[FLAG]** the exact tileset-handle name-derivation rule is
unspecified — `warren` exposes `tileset Warren` as handle `warren_tiles` (collision-avoidance with
the `warren` atlas), while `dungeon` keeps `Dungeon`→`dungeon`; trust the manifest/seam for the
actual handle name.

---

## 4. Modeling (`.fpm`, `grammar/fpm.ebnf` — NOT LL(1); named args; `//` comments allowed)

Two languages: the `.fpm` DSL (imperative, float-tolerant, **bake-time only**) and `.fun` (pure,
fixed-point) which sees only the seam. The vocabulary:

| Keyword | Generates |
|---|---|
| `param` | a field on the params `data` |
| `emit` | render geometry (`Solid`) → a content-hashed `MeshHandle` |
| `anchor` / `socket` | an `Anchors` entry / attach point (usable by `.flvl` as `model.socket("…")`) |
| `material` | a material binding (engine PBR; no user shaders) |
| `collide` | a fixed-point `Shape3` sim proxy |

```
model Coin {
  param radius: Length = 4 ; param thickness: Length = 1
  emit cyl(radius, thickness)
  material body = pbr(color: gold, rough: 0.3)
}
rig Krognid {
  skeleton: humanoid                       // a stdlib topology: humanoid|quadruped|robot (or an inline tree)
  param torso_h: Length = 24
  fn torso_mesh() -> Solid { return capsule(torso_r, torso_h).up(0) }
  part torso     at TORSO       = torso_mesh()      // part origin == the bone pivot (checked)
  part upper_arm at L_UPPER_ARM = upper_arm()
  mirror L -> R                             // model the left; the right is generated
  clearance 1.5                             // min joint gap; bake warns below it
  material body = pbr(color: teal, rough: 0.7)
}
```
Geometry algebra: primitives `box`/`sphere`/`cyl`/`capsule`; booleans `union`/`difference`/
`intersect`; transforms `.at`/`.rotate`/`.scale`/`.up`/`.down`; 2D↔3D `extrude`/`revolve`/`loft`
over a `Sketch`.

### Seam (`gen/krognid.gen.fun`) — functions over a params `data`, no marker type
```funpack
import engine.anim.{Skeleton, PartSet, Slot, Side}
import engine.assets.mesh
fn krognid_skeleton() -> Skeleton { return Skeleton.humanoid() }
fn krognid_parts() -> PartSet {
  return PartSet.empty().bind(Slot::Torso, mesh("krognid_torso")).bind(Slot::Head, mesh("krognid_head"))
    .bind(Slot::LUpperArm, mesh("krognid_upper_arm")).mirror(Side::L, Side::R)
}
```
A plain model seam emits `fn <name>_anchors(p) -> Anchors`, `fn <name>_mesh(p) -> MeshHandle`,
`fn <name>_collider(p) -> Shape3`.

### Consume it (pure pose generators → `Draw3::Rigged`)
```funpack
fn pose_walk(phase: Fixed, speed: Fixed) -> Pose {
  let s = sin(phase) * 0.5
  return Pose.empty().set(Bone::LUpperLeg, rot_x(s)).set(Bone::RUpperLeg, rot_x(-s)).set(Bone::Torso, up(bob))
}
```
Pose composition: `Pose.blend(a, b, w)` (per-bone lerp/slerp), `Pose.layer(base, overlay)` (overlay
wins per bone) — both over the union of driven bones, an absent bone blending against rest.
**Layering IS pipeline order** — a `pose: [pose_idle, pose_walk, pose_carry]` sub-pipeline lists
generators top-to-bottom, no magic-number layers.

### Rules / gates
- Strictly bake-time: no runtime re-bake, no `fn(state) -> Solid` per tick. The seam is hashed once.
- Geometry gates (hard): non-manifold / self-intersecting / zero-volume / over-budget mesh. Soft
  (warn): a too-large model should decompose into sub-`model`s/`fn`s.
- Rig gates: part origin == declared bone pivot (error); every bound slot has a mesh (error);
  mirrored side declared not duplicated (error); joint clearance ≥ `clearance` (warn); rest-pose
  manifold/bounds (digest).
- **Per-bone determinism boundary**: a gameplay-observable bone (a hand with a hitbox, a foot
  driving sim IK) must be fixed-point in a sim stage; purely cosmetic secondary motion may run float
  in render.
- Tests assert on the digest + anchors, never coordinates (`d.anchors.find("seat_top").z == 74.0`).
- **[FLAG]** the `backing: procedural("table.fpm") | asset("…") | template("…")` incremental-swap
  line (the "@stub for assets") is spec-described but does not appear in any example manifest — the
  concrete file/syntax is unconfirmed.

---

## 5. UI (`.fui`, `grammar/fui.ebnf` — LL(1); `bind:` one token; `@` the event token)

Elm/React: Model = view-model `data`, View = `fn(model) -> View[Msg]`, Messages = signals, Update =
ordinary behaviors. **The binding name IS the wire** — a `.fui` declares what it reads/emits and the
bake materializes both ends as types; the logic side must match.

```
screen Settings {
  col class="panel p-4 gap-3" {
    text class="text-2xl" { "Settings" }
    field placeholder="name" bind:value=player_name
    slider min=0 max=100 bind:value=volume
    row class="gap-2" {
      for p in volume_presets { button class="btn" @click=SetVolume(p.value) { "{p.value}" } }
    }
    button class="btn" @click=Back { "Back" }
  }
}
```
- **Widgets**: a closed ~14 set — layout `panel row col grid stack scroll spacer`; content `text
  image icon`; input `button field slider toggle select`. No `div`, no user components, no HTML.
- **Style**: space-separated **semantic theme tokens** (`bg-panel`, `text-2xl`, `gap-4`) checked
  like a `@gtag`; an unknown token is a compile error. Theme is `data`, swappable.
- **Directives, each a typed edge**: `:attr=path` (value in), `@event=Msg` (message out),
  `bind:value=field` (both — lowers to a read AND a `Set`-message). Shapes are **inferred from
  usage — the template IS the schema**; you never hand-declare the view-model.
- **Expression sublanguage = paths + literals + interpolation only** — no operators/calls/ternaries;
  anything computed is a *named* view-model field set in the projection.

### Seam (`gen/settings.gen.fun`) — inferred read + write contract + screen fn
```funpack
import engine.ui.View
data SettingsPresetRow { value: Int }                          // inferred from `p.value` alone
data SettingsView { player_name: String, volume: Int, volume_presets: [SettingsPresetRow] }
enum SettingsMsg { SetPlayerName(String), SetVolume(Int), Back }   // SetVolume reused by preset buttons
extern fn settings(model: SettingsView) -> View[SettingsMsg]
```
A screen that binds nothing has an empty view-model (`data PauseView {}`).

### Routing — the screens ARE the route table (`gen/screens.gen.fun`)
```funpack
enum Screen { Hud, Pause, Settings }
enum AppMsg { Hud(HudMsg), Pause(PauseMsg), Settings(SettingsMsg) }
```
Adding a `.fui` extends both enums — the mount AND the update `match` stop compiling until the screen
is mounted and handled. No route config, no string URLs.

### Consume it (projection + update + mount)
```funpack
fn hud_view(self: App) -> HudView { return HudView{ score: self.score, time_left: self.clock, game_over: self.game_over } }
fn on_hud(self: App, msg: HudMsg) -> App {
  return match msg {
    HudMsg::Coin  => self with { score: self.score + 1 }
    HudMsg::Pause => self with { screen: Screen::Pause, paused: true }
    HudMsg::Retry => App{}
  }
}
behavior view on App {
  fn step(self: App) -> View[AppMsg] {
    return match self.screen {
      Screen::Hud      => hud(self.hud_view()).map(AppMsg::Hud)        // .map lifts each screen into AppMsg
      Screen::Pause    => pause(self.pause_view()).map(AppMsg::Pause)
      Screen::Settings => settings(self.settings_view()).map(AppMsg::Settings)
    }
  }
}
pipeline Arcade { startup: [setup]   input: [on_msg]   update: [tick_clock]   ui: [view]   audio: [music] }
```

### The `ui:` stage & rules
- A distinct **engine-closed stage**, not a flavor of `render:`: a render behavior is output-only
  (`[Draw]`), but `View[Msg]` declares an inbound edge. `fn(self) -> View[Msg]` with Render's input
  rules plus the power to mount an interactive tree.
- Compositing is stage order: `ui:` after `render:`; multiple `ui:` behaviors composite back-to-front.
- The `Msg` round-trip is a **deferred signal** — the engine hit-tests recorded pointer input next
  tick. Effect closure requires every mounted `Msg` to be consumed (convention: an early `input:`/
  `on_msg` stage).
- Deterministic but **not sim-readable**: layout/hit-testing are fixed-point (replay-stable), but
  layout metrics are never sim-readable (no `width-of`). UI state is `data` (saved).
- No imperative UI-animation API (transitions are engine-derived from view diffs), no accessibility
  authoring surface (falls out of the closed widgets + tokens). Focus & gamepad are engine-managed
  via the closed `UiAction` set, bound in the same `bindings()` as gameplay; `Confirm` on a focused
  widget emits its `@click` Msg.
- List identity is positional by default; `for item in items key=item.id` for stable identity (a
  `Ref[T]` is the natural key).
- Incremental replacement: a `.fui` can be swapped for a hand-authored `engine.ui`-builder view
  behind the same seam, no change to projection/update.

---

## 6. Audio (two regimes, `spec/22-audio.md`)

Sound is an effect — data returned to the engine. **No `play_sound()`.**

| Regime | Surface | Trigger | Returned from |
|---|---|---|---|
| One-shot SFX | `[Sound]` command | edge (an event happened) | an Update behavior, alongside other commands |
| Sustained audio | `[Audio]` scene | level (this should be playing now) | the `audio:` stage, diffed by the engine |

### Regime A — one-shot `[Sound]`
`Sound{ clip: SoundHandle, gain, pitch, bus, at: Option[Vec3] }`, built `Sound.sfx(clip)` /
`Sound.sfx_at(clip, pos)` + `.gain`/`.pitch`/`.bus`/`.at`. No key, no lifetime — played once.
```funpack
behavior on_msg on App {
  fn step(self: App, msg: AppMsg) -> (App, [Sound]) { return (route(self, msg), click_sfx(msg)) }
}
fn click_sfx(msg: AppMsg) -> [Sound] {
  return match msg {
    AppMsg::Hud(HudMsg::Coin) => [Sound.sfx(sound("coin")).bus(Bus::Ui)]
    _                         => [Sound.sfx(sound("click")).bus(Bus::Ui)]
  }
}
```

### Regime B — sustained keyed `[Audio]`
`Audio{ key: String, clip, gain, pitch, bus, at }`, built `Audio.track(key, clip)` + the setters. The
engine diffs the keyed set: appear→start, disappear→stop (with the bus fade), same key new gain/pitch
→bend the live voice, same key new clip→crossfade.
```funpack
behavior music on App {
  fn step(self: App) -> [Audio] {
    let clip = match self.screen { Screen::Hud => "bgm_play"   Screen::Pause => "bgm_menu"   Screen::Settings => "bgm_menu" }
    return [Audio.track("music", sound(clip)).gain(to_fixed(self.volume) / 100.0).bus(Bus::Music)]
  }
}
```
The settings volume drives gain because desired gain is part of the projection — there is no mutable
global mixer.

### The `audio:` stage & rules
- An engine-closed stage like Render/Ui: pure `fn(self) -> [Audio]` with Render's input rules
  (blackboard/resources/`View`; no signal lists, no `Rng`, no writes). Output-only.
- Buses: `Master / Music / Sfx / Ui / Voice` — a slider drives a bus by feeding its value into the
  gain of the sounds on it.
- Deterministic: triggers are data (a replay re-emits the identical sequence); output never feeds
  back. `gain`/`pitch` are `Fixed` (often from sim, e.g. pitch from speed); the sim never reads back.
- Positional audio: optional world `at`, attenuated relative to the listener (defaults to the active
  `Draw3::Camera`). No DSP-effect-chain authoring — reverb/filtering are engine bus settings.
