# funpack `engine.*` — complete module reference

Verbatim-distilled from the in-repo `stdlib/engine/*.fun` signature files, the prose spec
(`spec/26-stdlib.md`, `spec/23-input.md`), and the worked examples. Conventions: `self`-first =
method; no-self return-qualified = associated constructor (`Type.fn()`); no-self bare = free
function. Everything is `Fixed`-point and deterministic; partiality is `Option`/`Result`, never a
panic; `Float` is render-only.

> **Accuracy flags** are inline as **[FLAG]**. Where the signature file and the examples/prose
> diverge, both are given. For a load-bearing call, verify against a real compile — funpack is under
> active design and "the examples lead; a compile is the tie-breaker."

---

## engine.prelude — always in scope

```funpack
extern type Bool   Int   Fixed   Float   String
enum Ordering { Less, Equal, Greater }
enum Option[T] { Some(T), None }          // the only way to express absence; no null
enum Result[T, E] { Ok(T), Err(E) }       // errors are values; exhaustive E handling forced
fn is_some(self: Option[T]) -> Bool
fn or_else(self: Option[T], fallback: T) -> T
extern fn to_fixed(n: Int) -> Fixed
extern fn to_int(x: Fixed) -> Int          // truncates toward zero
extern fn compare(a: T, b: T) -> Ordering
```

## engine.math

```funpack
data Vec2: Num { x: Fixed, y: Fixed }      // + - * (scalar & component-wise)
data Vec3: Num { x: Fixed, y: Fixed, z: Fixed }
data Quat { x: Fixed, y: Fixed, z: Fixed, w: Fixed }
data Aabb { min: Vec3, max: Vec3 }
extern type Mat4
let pi:  Fixed = 3.14159265
let tau: Fixed = 6.28318531

// scalar (Fixed -> Fixed unless noted)
extern fn sin/cos/tan(x) ; atan2(y, x) ; sqrt(x) ; abs(x) ; floor/ceil/round(x) ; min/max(a, b)
fn clamp(x: Fixed, lo: Fixed, hi: Fixed) -> Fixed
fn lerp(a: Fixed, b: Fixed, t: Fixed) -> Fixed        // t in [0,1]
fn length(v: Vec2) -> Fixed                            // 2D
fn length3(v: Vec3) -> Fixed
fn dot(a: Vec3, b: Vec3) -> Fixed                      // 3D
extern fn cross(a: Vec3, b: Vec3) -> Vec3
extern fn normalize(v: Vec3) -> Vec3
extern fn from_axis_angle(axis: Vec3, angle: Fixed) -> Quat
extern fn from_euler(yaw, pitch, roll) -> Quat         // Y, X, Z order
extern fn qmul(a: Quat, b: Quat) -> Quat               // compose: apply b then a
extern fn slerp(a: Quat, b: Quat, t: Fixed) -> Quat
extern fn rotate(q: Quat, v: Vec3) -> Vec3
extern fn mat_identity() -> Mat4 ; mat_trs(t, r, s) -> Mat4 ; mat_mul(a, b) -> Mat4 ; transform_point(m, p) -> Vec3
```
**[FLAG]** `length` is 2D, `length3`/`dot`/`cross` are 3D; there is no 2D `dot`/`normalize` in the
signature file. The numerics spec (`spec/10`) names more (`Fixed.MAX/MIN/EPSILON`, `checked_div`,
`pow/exp/log`, `remap`, `inv_lerp`, `wrap_angle`, `radians/degrees`, `length_sq`, `distance`,
`reflect`, `%`, `Quat.mul`/`Quat.axis_angle`) — real but under-declared in the interface file, and
named differently (file `from_axis_angle`/`qmul` vs prose `Quat.axis_angle`/`Quat.mul`). See the
`funpack-determinism` skill.

## engine.core
```funpack
data Time { dt: Fixed, t: Fixed }
extern type TickRate
fn at(dt: Fixed) -> Time            // Time.at(dt) = Time{dt, t:0.0}
fn tick(dt: Fixed, t: Fixed) -> Time
```

## engine.world
```funpack
data Id { raw: Int }
data Ref[T] { id: Id }              // weak, serializable, shareable; resolves to Option[T]
data Owned[T] { id: Id }            // exclusive owning ref; despawn cascades to referent
extern type Spawn                   // command; written Spawn(<thing-literal>)
data Despawn { id: Id }             // command; Despawn() self-despawns
extern type View[T]                 // read-only iterable view; never mutates
extern fn count(self: View[T]) -> Int
extern fn at(self: View[T], i: Int) -> T
extern fn ref(self: View[T], i: Int) -> Ref[T]
extern fn resolve(self: View[T], ref: Ref[T]) -> Option[T]
extern fn of(items: [T]) -> View[T]    // TEST FIXTURE: View.of([...])
```

## engine.input
Importable surface (`import engine.input.{…}`):
```funpack
// types
Input  Bindings                      // the read resource and the binding builder
PlayerId                             // enum { P1, P2, P3, P4 }
Key                                  // enum { A..Z, Up, Down, Left, Right, Space, Enter, M, F5, F9 } — bindings-only
PadButton                            // enum { A, B, X, Y, Start, Back, LeftShoulder, RightShoulder, DpadUp, DpadDown, DpadLeft, DpadRight }
MouseButton                          // enum { Left, Middle, Right }
Stick                                // enum { Left, Right }
// source-helper funcs
keys_axis  stick_x  stick_y          // 1D axis sources
wasd  arrows  dpad  stick            // 2D axis sources
pad  mouse                           // digital button sources
```
**Not importable** — `Axis`/`Button` are role-kind ascriptions (by-text, written after the action
enum name); `pressed`/`released`/`held`/`value`/`axis` (on `Input`) and `axis`/`button` (on
`Bindings`) are receiver-resolved methods:
```funpack
enum Drive: Axis   { Move }          // an Axis action → read via value (1D) / axis (2D)
enum Act:   Button { Jump, Fire }    // a Button action → read via pressed / released / held
```

```funpack
// query surface — receiver methods on the Input resource (not imports)
input.pressed(PlayerId, Button)  -> Bool    // down-edge this tick
input.released(PlayerId, Button) -> Bool    // up-edge this tick
input.held(PlayerId, Button)     -> Bool    // level: down now
input.value(PlayerId, Axis)      -> Fixed   // 1D axis [-1,+1]
input.axis(PlayerId, Axis)       -> Vec2    // 2D axis, each comp [-1,+1]

// binding sources fed to .button(…) / .axis(…)
[Key::W, Key::Up]                           // BUTTON: the key-list literal (a single key is [Key::W])
pad(PadButton::A)                           // BUTTON: a gamepad button
mouse(MouseButton::Left)                    // BUTTON: a mouse button
keys_axis(Key::A, Key::D)                   // AXIS 1D
stick_x(Stick::Left)  stick_y(Stick::Left)  // AXIS 1D
wasd()  arrows()  dpad()                    // AXIS 2D — WASD / arrow keys / gamepad d-pad into a Vec2
stick(Stick::Left)                          // AXIS 2D — a gamepad stick into a Vec2

// builder + test doubles
Bindings.empty().axis(PlayerId, Axis, <axis-source>).button(PlayerId, Button, <button-source>)
Input.empty().with_pressed/with_released/with_held(PlayerId, Button)
Input.empty().with_value(PlayerId, Axis, Fixed) ; with_axis(PlayerId, Axis, Vec2)
```
Sources for one action **stack** — a key-list may mix devices (`[Key::W, PadButton::DpadUp]`).
2D orientation is y-down: `W` and stick-up read **negative y**. Bindings live in
`fn bindings() -> Bindings` lifted into the entrypoint, not a pipeline block. There is **no `key(…)`
helper** (use the `[Key::W]` one-element list). `dpad()` binds the d-pad as a single 2D `Vec2` (the
only d-pad 2D path — a direction is otherwise only a digital `pad(PadButton::DpadUp)` button); it
lowers to the runtime `pad_quad` source, the d-pad twin of `keys_quad` (spec §23 §3; ADR
`2026-06-15-engine-input-source-helpers-split`).

## engine.list
```funpack
extern fn len/is_empty(self: [T])
extern fn get(self, i: Int) -> Option[T]
extern fn first(self) -> Option[T] ; last(self) -> Option[T]
extern fn prepend/append(self, item: T) -> [T]
extern fn concat(self, other: [T]) -> [T] ; reverse(self) -> [T]
extern fn contains(self, item: T) -> Bool                 // requires Eq
extern fn find(self, pred: fn(T) -> Bool) -> Option[T]
extern fn map(self, f: fn(T) -> U) -> [U]
extern fn filter(self, pred: fn(T) -> Bool) -> [T]
extern fn fold(self, init: A, step: fn(A, T) -> A) -> A   // THE deterministic loop primitive, left-to-right
```
**[FLAG]** Predicate "find one" is `find(xs, pred)` in the file; some examples write `first(xs, pred)`
— prefer `find`. `init(xs)` (all-but-last) is used in snake but not declared. `within(list, origin,
r)` / `nearest_first(list, origin)` are named in the spec module map but have no signature (inferred:
spatial filter / distance sort).

## engine.render
```funpack
enum Flip { None, X, Y, XY }
enum Color { White, Black, Red, Green, Blue, Yellow, Cyan, Magenta, Gray, Rgb{ r: Fixed, g: Fixed, b: Fixed } }
enum Align { Left, Center, Right }
extern type Font
enum Draw {
  Rect{ at: Vec2, size: Vec2, color: Color }          // at = TOP-LEFT corner
  Line{ a: Vec2, b: Vec2, color: Color }
  Text{ at: Vec2, text: String, color: Color }
  Fill{ path: Sketch, color: Color }
  Stroke{ path: Sketch, width: Fixed, color: Color }
  Sprite{ atlas: AtlasHandle, cell: String, at: Vec2, size: Vec2, tint: Color, flip: Flip, layer: Int }
}
```
**[FLAG]** `Draw::Camera` (2D) is named in the spec module map but is **not** in `render.fun`'s `Draw`
enum; `Camera` is really only in `render3.Draw3`. `Rect.at` is top-left (confirmed by pong's
collision math).

## engine.map
```funpack
extern fn empty() -> Map[K, V]              // Map.empty()
extern fn len(self) -> Int ; get(self, key: K) -> Option[V] ; has(self, key: K) -> Bool
extern fn set(self, key: K, value: V) -> Map[K, V] ; remove(self, key: K) -> Map[K, V]
extern fn keys(self) -> [K] ; values(self) -> [V]      // stable order
```

## engine.grid
```funpack
data Cell { x: Int, y: Int }
extern fn grid_cells(size: Cell) -> [Cell]                                 // all cells, row-major (canonical)
extern fn grid_cells(w: Int, h: Int, builder: fn(Int, Int) -> Cell) -> [Cell]   // mapper form
extern fn neighbors(cell: Cell) -> [Cell]                                  // four orthogonal
extern fn in_bounds(cell: Cell, size: Cell) -> Bool
```

## engine.rand
The only nondeterminism, made explicit — every draw returns `(value, nextRng)`.
```funpack
data Rng { state: Int }
extern fn seed(n: Int) -> Rng                            // Rng.seed(n)
extern fn next(self) -> (Fixed, Rng)                     // uniform [0,1)
extern fn range(self, lo: Int, hi: Int) -> (Int, Rng)
extern fn pick(self, items: [T]) -> (Option[T], Rng)
extern fn chance(self, p: Fixed) -> (Bool, Rng)
extern fn split(self) -> (Rng, Rng)
```
**[FLAG]** File is `self`-first (`rng.pick(items)`); snake calls `pick(free, rng)` (list-first).
Verify arg order against a compile. Always thread the returned `Rng`.

## engine.string
Build text by interpolation `"{a}{b}"`, never `+`.
```funpack
extern fn len(self) -> Int ; fn is_empty(self) -> Bool
extern fn concat(self, other) -> String ; chars(self) -> [String] ; slice(self, start, end) -> String
extern fn split(self, sep) -> [String] ; join(parts: [String], sep) -> String   // String.join(parts, sep)
extern fn contains/starts_with/ends_with(self, s) -> Bool ; index_of(self, needle) -> Option[Int]
extern fn trim/to_upper/to_lower(self) -> String ; repeat(self, n) -> String
extern fn from_int(n) -> String ; from_fixed(x) -> String                          // String.from_int / from_fixed
extern fn parse_int(self) -> Option[Int] ; parse_fixed(self) -> Option[Fixed]
```

## engine.audio
Two regimes, both plain data (no playback fn). See the `funpack-content` skill for the audio
pipeline.
```funpack
enum Bus { Master, Music, Sfx, Ui, Voice }
data Sound { clip: SoundHandle, gain: Fixed, pitch: Fixed, bus: Bus, at: Option[Vec3] }   // one-shot command
data Audio { key: String, clip: SoundHandle, gain: Fixed, pitch: Fixed, bus: Bus, at: Option[Vec3] }  // sustained, keyed
fn sfx(clip) -> Sound ; sfx_at(clip, pos) -> Sound       // Sound.sfx(...)
fn track(key: String, clip) -> Audio                      // Audio.track(key, clip)
fn gain(self, g) ; pitch(self, p) ; bus(self, b) ; at(self, pos)    // fluent setters on both Sound and Audio
```

## engine.ui
A screen is a pure `fn(viewmodel) -> View[Msg]`. Normally authored as a `.fui` template
(`funpack-content` skill); these builders are the hand-authored escape hatch.
```funpack
extern type View[Msg]
data Choice[T] { label: String, value: T }
enum UiAction: Button { NavUp, NavDown, NavLeft, NavRight, Confirm, Cancel }
extern type Theme
// leaves
extern fn text(content) -> View[Msg] ; button(label, on_click: Msg) -> View[Msg]
extern fn image(handle: TextureHandle) -> View[Msg] ; spacer() -> View[Msg] ; icon(name) -> View[Msg]
// containers
extern fn panel/row/col/grid/stack(children: [View[Msg]]) -> View[Msg] ; scroll(child) -> View[Msg]
// inputs (each maps the new value to a Msg)
extern fn field(value: String, on_input: fn(String) -> Msg) -> View[Msg]
extern fn slider(value: Int, min: Int, max: Int, on_change: fn(Int) -> Msg) -> View[Msg]
extern fn toggle(on: Bool, on_change: fn(Bool) -> Msg) -> View[Msg]
extern fn select(options: [Choice[T]], chosen: T, on_pick: fn(T) -> Msg) -> View[Msg]
// modifiers
extern fn class(self, tokens: String) -> View[Msg]       // semantic theme tokens, validated at bake
extern fn when(self, cond: Bool) -> View[Msg]
extern fn map(self, into: fn(Msg) -> Other) -> View[Other]   // re-tag; mounts child screens into a router
```

## engine.geom — vector shapes (the 2D↔3D bridge)
```funpack
enum PathOp { MoveTo(Vec2), LineTo(Vec2), CubicTo{ c1: Vec2, c2: Vec2, to: Vec2 }, Arc{ to: Vec2, radius: Fixed }, Close }
data Path { ops: [PathOp] }
extern type Sketch
extern fn rect(size: Vec2) -> Sketch ; circle(radius) -> Sketch ; poly(points: [Vec2]) -> Sketch ; from_path(path) -> Sketch
extern fn round(self, radius) ; shift(self, by: Vec2) ; turn(self, angle) ; scale(self, factor)   // -> Sketch
```

## engine.assets — content handles (see funpack-content)
```funpack
data MeshHandle { name } ; TextureHandle { name } ; SoundHandle { name } ; AtlasHandle { name }
extern fn mesh(name) -> MeshHandle ; texture(name) -> TextureHandle ; sound(name) -> SoundHandle ; atlas(name) -> AtlasHandle
extern fn cell(self: AtlasHandle, col: Int, row: Int) -> String          // region id of a grid cell
extern fn frame(self: AtlasHandle, clip: String, t: Fixed) -> String     // region id of an animation clip at time t
```
Unknown name = compile error (closed registry). Prefer the typed constant `assets.coin_sfx` over the
string form `sound("coin_sfx")`.

## engine.nav — 2D pathfinding
```funpack
extern type Nav                            // active level's baked nav graph, engine-injected
data NavHandle { name } ; Path { steps: [Vec2], cost: Fixed }
enum NavError { Unreachable, OffNav }
extern fn layer(level: LevelHandle, name) -> NavHandle
extern fn path(self: Nav, from: Vec2, to: Vec2) -> Result[Path, NavError]
extern fn reachable(self, from, to) -> Bool ; los(self, from, to) -> Bool ; nearest(self, point) -> Option[Vec2]
extern fn advance(self: Path, pos: Vec2, arrive: Fixed) -> (Option[Vec2], Path)   // next waypoint + remaining
extern fn of(route: Path) -> Nav ; fail(err: NavError) -> Nav                      // TEST FIXTURES
```
Write the naive repath-every-tick; the engine dedups/caches.

## engine.nav3 — 3D pathfinding
Same shape with `Vec3`/`Path3`/`NavError3`/`Nav3`: `layer3`, `path3`, `reachable3`, `los3`,
`nearest3`, `advance3`. **[FLAG]** no `of`/`fail` fixtures (unlike `nav`).

## engine.render3 — 3D draw commands (floats permitted only here)
```funpack
data Material { color: Color, metallic: Fixed, rough: Fixed }
enum Draw3 {
  Mesh{ handle: MeshHandle, at: Vec3, material: Material }
  Rigged{ skeleton: Skeleton, parts: PartSet, pose: Pose, at: Vec3 }
  Plane{ at: Vec3, size: Vec2, color: Color }
  Camera{ eye: Vec3, at: Vec3, fov: Fixed }            // fov in DEGREES
  Light{ dir: Vec3, color: Color }
}
fn matte(color) -> Material ; pbr(color, rough, metallic) -> Material
```

## engine.anim — skeletons, parts, poses
```funpack
enum Bone { Hips, Torso, Neck, Head, LUpperArm..RHand, LUpperLeg..RFoot, Joint0..Joint7 }   // 16 humanoid + generic
enum Slot { Torso, Head, LUpperArm..RHand, LUpperLeg..RFoot, Slot0..Slot3 }
enum Side { L, R }
data Transform { pos: Vec3, rot: Quat, scale: Vec3 }
extern type Skeleton   Pose   PartSet
extern fn identity() ; rot_x/rot_y/rot_z(angle) ; up(d) ; translate(offset)   // -> Transform
extern fn humanoid() / quadruped() / robot() -> Skeleton
extern fn empty() -> Pose ; set(self, bone, transform) -> Pose ; get(self, bone) -> Transform ; has(self, bone) -> Bool
extern fn blend(a: Pose, b: Pose, weight: Fixed) -> Pose      // per-bone lerp/slerp
extern fn layer(base: Pose, overlay: Pose) -> Pose            // overlay's bones replace base's
extern fn empty() -> PartSet ; bind(self, slot, handle: MeshHandle) -> PartSet ; mirror(self, from: Side, to: Side) -> PartSet
```

## engine.model — the `.gen.fun` model surface
```funpack
data Length { value: Fixed }
extern type Anchors   Solid
enum Shape3 { Box{ size: Vec3 }, Sphere{ radius: Fixed }, Capsule{ radius: Fixed, height: Fixed }, Hull{ points: [Vec3] } }
extern fn empty() -> Anchors ; at(self, name, point: Vec3) -> Anchors ; socket(self, name, point) -> Anchors
extern fn point(self, name) -> Option[Vec3] ; handle(self: Solid) -> MeshHandle
```
The geometry-builder vocabulary (`box`, `union`, `extrude`, …) is the bake-time `.fpm` DSL, not this
surface — see `funpack-content`.

## engine.level
```funpack
data LevelHandle { name }
extern fn level(name) -> LevelHandle
data Load { level: LevelHandle, at: Vec3 } ; Unload { level: LevelHandle }   // streaming commands
enum Volume { Rect{ min: Vec2, max: Vec2 }, Box{ min: Vec3, max: Vec3 }, Sphere{ center: Vec3, radius: Fixed } }
extern fn contains(self: Volume, point: Vec3) -> Bool
```

## engine.tilemap
```funpack
data TilesetHandle { name } ; TilemapHandle { name }
extern fn tileset(name) -> TilesetHandle
extern fn tile_at(self: TilemapHandle, cell: Cell) -> Option[String]   // tile name, or None if empty
extern fn solid_at(self, cell) -> Bool                                  // collision query
extern fn cell_of(self, pos: Vec2) -> Cell ; center_of(self, cell) -> Vec2
extern fn of(cell_size: Int, cells: [(Cell, String, Bool)]) -> TilemapHandle   // TEST FIXTURE
data SetTile { map: TilemapHandle, cell: Cell, tile: String }                   // runtime: change one tile
data BuildLayer { map: TilemapHandle, fill: String, cells: [(Cell, String)] }   // runtime: replace whole layer
```

## Modules listed in the spec map but with no signature file
`engine.save`, `engine.seq`, `engine.physics`/`physics3` — referenced in `spec/26-stdlib.md` but no
`.fun` surface exists to quote. The `physics:` engine stage is driven via the pipeline (see
`funpack-game-model`), not a called API.
