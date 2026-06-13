# funpack artifact format — v18

This document is the **process-boundary data contract** between `funpack` (the
pure `source → artifact` compiler) and the **runtime** (the impure native
executor, Odin, `runtime/**`). It is the spec-§29 Unix seam: a versioned byte
format plus a written layout, **not** a library link. A runtime parses the bytes
from *this document alone*, with **zero `funpack` imports** — nothing in
`funpack/**` is on the runtime's include path.

The artifact is the **serialized checked AST** of one game. Spec §09 §1 makes the
on-disk spelling (checked-AST vs. bytecode) an implementation detail of the
interpreter's canonical semantics; the checked AST is the cheapest loadable form,
so that is what this format carries. The runtime interprets it; this format does
not encode evaluation order beyond the pipeline's total order.

A golden fixture conforming to this v1 layout lives at
[`../testdata/pong.artifact`](../testdata/pong.artifact). The production emitter
(a later story) must reproduce that fixture **byte-for-byte** from
`examples/pong/`.

---

## 1. Versioning rule — exact match, no best-effort

The first line of every artifact is the schema stamp:

```
funpack-artifact 18
```

- `schema_version` is the integer after the space (here `18`).
- **Any** change to a section, field, ordering, or encoding **bumps the version**
  — there are no optional fields and no minor/compatible tier.
- **Version history.** v1 was the initial gameplay-golden format (the pong
  surface). v2 ratifies two §2.7 body-node arm KINDs the snake/hunt goldens
  introduce: `bare_binder` (a tuple position binding the whole element) and
  `tuple` (a positional tuple pattern). The `tuple` arm is the one arm kind that
  carries children — its positional sub-pattern arms — so it ends in a trailing
  `child_count`, unlike every other arm whose child count is fixed at 0 by kind.
  A new arm kind and an arm-with-children are both layout changes, so the version
  bumped 1 → 2. v3 ratifies the closed §14 binding SOURCE-form set: the emitter
  lowers every §23 §3 builder helper into it (a key-list button source spreads
  to one `key(…)` bind per key; `wasd()` lowers to the 2D
  `keys_quad(neg_x,pos_x,neg_y,pos_y)` form; `stick(Stick)` is a first-class 2D
  source). The source vocabulary is a closed taxonomy, so growing it bumped
  2 → 3. v4 adds the required `logical:WxH` field to the §15 entrypoint record
  — the fixed logical draw space (§20 §3) in integer world units, declared in
  the entrypoint block (§14 §4) — so the present pass letterboxes from the
  artifact instead of a hardcoded board constant. A required field on an
  existing record is a layout change: 3 → 4. v5 is the **yard cross-epic
  format** the §11 physics, §20 camera, and §24 persistence surfaces first
  reach. Four layout changes ride it: (a) the **§06 §2 singleton tick-0 spawn
  marker** — a `singleton`'s [things] row carries `SINGLETON true` plus its
  COMPLETE defaulted field schema, so the runtime spawns the singleton
  population (yard's Scoreboard/Camera/Menu) once before tick 0 from the artifact
  alone, accessed by type (§8); (b) the **§11 §3 physics-stage encoding** — the
  engine-closed `physics: solve` battery occupies a [pipeline_flattened] step
  (`stage:physics behavior:solve`), a battery step distinct from a behavior step,
  recording the engine boundary in the total order (§11); (c) the **§03 §4
  CollisionLayer enum KIND tag** — an `enum Layer: CollisionLayer` [enums] record
  stamps the `CollisionLayer` role kind (§5); (d) the **§6 engine-type field
  defaults** — an `Option[String]` singleton default (`status: Option[String] =
  Option::None`, an enum-variant token) and engine-type composite defaults (a
  Settings static-builder default `Settings.defaults()` lowered to its evaluated
  `Settings(volume=128,fullscreen=false)` record inline, decoded against a
  synthesized §8 Settings data projection, and a Body's inline composite default
  with its `impulse: Vec2 = zero` / `mass: Fixed = 1.0` field defaults applied).
  A marker row, a new flattened-step occupant kind, an enum KIND value, and
  widened §6/§8 default forms are each a layout change: 4 → 5. v6 is the **krognid
  multi-module format** — the first artifact the runtime executes whose
  [functions] section carries fn records from more than the entrypoint module. The
  single layout change is the **§17 cross-module seam-fn carry**: when the
  entrypoint module imports a fn from a sibling USER module (krognid's `stroll`
  imports `krognid_skeleton` / `krognid_parts` from the baked rig seam), the
  emitter appends that imported fn's full record — signature, body node run, and a
  span keyed to the SEAM module (`span:krognid:8`) — into [functions] after the
  entrypoint module's own records, so the Rigged draw body's `krognid_skeleton()` /
  `krognid_parts()` calls resolve to a self-contained record the runtime finds by
  bare name (the seam bodies would otherwise be absent and the call would return
  nil). The carried records keep their BARE names — the artifact disambiguates by
  the span's module, not a §15 qualifier, because the runtime resolves functions by
  bare name (the §15-qualification rule governs the SEPARATE Index Contract decl
  surface, not the artifact [functions] name token). NO new §2.7 node KIND rides
  this bump: the seam bodies and the entrypoint's first anim/Draw3 forms serialize
  through the existing call/field/variant/record/list/string node arms. A widened
  [functions] population is a layout change: 5 → 6. v7 carries the **§05 §2 typed
  hole** through to the runtime. A dev artifact of a holed declaration was
  hole-blind before this: a `@stub(T, fallback)` fn or behavior emitted an empty
  body and ticked as a no-op live, silently dropping the fallback approximation
  the compiler's test interpreter already runs (P8 — "the game stays playable").
  The single layout change is one new §2.7 node KIND, `stub`, standing as a holed
  body's **sole statement subtree** (`body_count` 1), exactly where the grammar
  puts the hole (`FnBody ::= Block | StubExpr`): `node stub fallback 1` carries
  the fallback approximation expression as its one child, and `node stub bare 0`
  is the typecheck-only `@stub(T)` the runtime **fails closed** on (the spec's
  defined no-value outcome — never undefined behavior). The hole's `T` is not
  carried: the typechecker proves it identical to the record's declared
  `return:TYPE`. The node-kind set is closed, so the new kind is a deliberate
  bump: 6 → 7. A **release** artifact never carries a `stub` node — the §29 §4
  hole-ban refuses the tree before emission, so the node is a dev-artifact form
  only. v8 carries the **§05 §6 `@migrate` schema-evolution channel** through to
  the loader — the rename/retype metadata the name-keyed schema-diff (§09 §4,
  §24) cannot derive on its own (rename and retype are the two structural breaks
  it cannot auto-resolve, so without the carry a restore or hot-reload under a
  renamed/retyped field could only refuse). The single layout change is one new
  **sub-record keyword**, `migrate` — a fixed three-token line `migrate FROM
  WITH` appearing in `[data]` records only (§6): following a `field` line it
  migrates that field (`FROM` the prior key or `-`, `WITH` the pure conversion
  fn's name or `-`, never both `-`), and between the `data` lead line and the
  first `field` line it carries a renamed **type** declaration's prior name
  (rename form only, so `WITH` is always `-` there). The line is emitted only
  where the source carries the directive, so an artifact of a migration-free
  source changes by the version stamp alone (the v7 stamp-only restamp
  precedent). The conversion fn is an ordinary `[functions]` record the loader
  resolves by name. The sub-record keyword set is closed (§2.1), so the new
  keyword is a deliberate bump: 7 → 8. v9 carries the **§08 §3 state-query
  declarations** through to the runtime — the first-class `query` declarations
  and their §05 §3 `@index`/`@spatial` index requirements, which the runtime
  needs to **maintain** the declared engine indices over the world database and
  to evaluate a query call from the artifact alone. Two layout changes ride it:
  (a) one new section, `[queries Q]` (§16), appended after `[entrypoint]` — one
  record per entrypoint-module `query` declaration in source order, the
  `[functions]` record mold extended with the declared requirement lines; (b)
  one new **sub-record keyword**, `index` — a fixed four-token line `index KIND
  THING FIELD` (`KIND` ∈ `index` | `spatial`) carrying one declared §05 §3
  requirement. A query body is a Block by grammar (no body-position hole), so
  its body run is the plain §2.7 statement forest. A new section and a new
  sub-record keyword are layout changes: 8 → 9. v10 ratifies the **§08 §3 world
  read `all[T]`** as a §2.7 node KIND: `node all THING 0` — a leaf carrying the
  read table's thing type name, evaluating to that thing's instance rows in
  stable `Id` order (the runtime reads its current version; the compiler's test
  interpreter the setup-seeded startup population). It is the form a spec-true
  query body reads the world through — a query takes **only value parameters**
  (the View-parameter interim shape is retired by the same bump), so the
  `[queries]` carry (§16) is unchanged in layout while every world read moves
  inside the body. A new node KIND is a layout change: 9 → 10. v11 carries the
  **§18 §3 tile layers** through to the runtime — the static environment a
  tilemap's ASCII grid bakes to, which the runtime renders **batched** and
  collides against (never per-tile `Draw::Sprite`) and which an artifact-blind
  runtime could neither draw nor collide. Two layout changes ride it: (a) one
  new section, `[tilemaps T]` (§17), appended after `[queries]` — one record
  per baked layer in level declaration order: a lead line `tilemap NAME
  CELL_SIZE COLS ROWS PALETTE_COUNT`, then `PALETTE_COUNT` `tile NAME SOLID`
  palette lines (the layer's legend-declared tile types in legend order, each
  carrying its §18 §2 baked collision verdict), then `ROWS` `row …` lines of
  `COLS` space-separated cells — a decimal palette index or `-` for a tile-less
  cell (an `empty` legend bind or a marker cell; markers lower to the spawn
  machinery, never this section); (b) two new **sub-record keywords**, `tile`
  and `row`. A new section and new sub-record keywords are layout changes:
  10 → 11. v12 makes the tile-layer record **self-describing for any level
  bounds**: the `[tilemaps]` lead line gains the **grid→world anchor** — the
  world point of the grid's top-left corner, two raw Q32.32 `Fixed` fields
  (§2.3) between `ROWS` and `PALETTE_COUNT` (`tilemap NAME CELL_SIZE COLS ROWS
  ANCHOR_X ANCHOR_Y PALETTE_COUNT`). The bake emits it from the level bounds
  (`bounds_min.x`, `bounds_max.y`) — the same corner the marker/`cell()`
  lowering anchors on — and the runtime loader **reads** it instead of deriving
  `(0, rows*CELL_SIZE)` (the v11 derivation, exact only for a grid spanning its
  bounds from the origin), so §17's documented mapping is reproducible from the
  record alone. A lead-line field is a layout change: 11 → 12. A level-less
  artifact moves by the version stamp alone (the v7 stamp-only restamp
  precedent). v13 carries the **§12 §1 nav graphs** through to the runtime —
  the walkable-cell topology a tilemap's solids imply, baked once so the runtime
  path-finds over a graph it never authored (the picture **is** the topology,
  §12 §1). Two layout changes ride it: (a) one new section, `[nav N]` (§18),
  appended after `[tilemaps]` as the fixed §3 section tail — one record per baked
  tile layer in the **same slice order** `[tilemaps]` emits, so a nav record keys
  1:1 to its tilemap: a lead line `nav NAME NODE_COUNT EDGE_COUNT` carrying **no**
  grid metadata (§12 §5 forbids exposing the raw Cell index, so the artifact leaks
  no col/row), then `NODE_COUNT` `navnode FIXED_X FIXED_Y` sub-records — one per
  walkable cell, each the cell's world-space **center** as two raw Q32.32 `Fixed`
  (§2.3), in **row-major** order so the line position **is** the node index (the
  raw Cell index is never the wire token, §12 §5) — then `EDGE_COUNT` `navedge A
  B` sub-records, the **4-neighbor orthogonal** adjacencies as two decimal node
  indices, **canonical `A < B`** and in ascending `(A, B)` order. The §12 §1
  hierarchical decomposition stays **invisible**: one **flat** graph per layer, no
  tiers in the wire format. (b) two new **sub-record keywords**, `navnode` and
  `navedge`. A new section and new sub-record keywords are layout changes:
  12 → 13. A level-less artifact moves by the version stamp plus the constant
  `[nav 0]` tail (the §3 fixed-tail precedent the level-less `[tilemaps 0]` set).
  v14 closes the **guard-block gap**: §02's grammar allows a multi-statement
  early-return guard (`if cond { let x = …; return y }`) but the v13 `if_return`
  carried exactly (condition, returned value), so the emitter silently dropped
  every statement before the `return` (surfaced by the emitted-warren golden).
  v14 adds **one node kind, `block`** (§2.7): `node block N` over `N` statement
  subtrees, allowed in `if_return`'s **outcome position** — a single-bare-return
  guard keeps the bare value encoding, any other guard block rides as a `block`
  whose statements evaluate with early-return semantics (block-scoped `let`s; a
  block that completes without returning falls through to the enclosing body).
  `block` is the general mechanism for every grammar position holding a
  `(Block | Expr)` disposition; v14 ratifies it for `if_return` only. A node
  kind is a ratification change: 13 → 14. Every artifact without a
  multi-statement guard moves by the version stamp alone (the v7 stamp-only
  restamp precedent). v15 is the **runtime-level-load format** — it makes a
  multi-module game's artifact self-contained for live level execution. Three
  layout changes ride it, all widened **populations** (the v6
  widened-[functions] precedent); no new section, no new sub-record keyword, no
  new node kind. (a) The **cross-module declaration carry**: the enum/data/
  signal/thing declarations the entrypoint module imports from sibling USER
  modules append into `[enums]`/`[data]`/`[signals]`/`[things]` **after** the
  entrypoint module's own records, in import-declaration order then brace-group
  member order (dungeon_game's `import dungeon_world.{Player, Slime, Chest,
  Dir, Looted}` carries the three things with their complete defaulted field
  schemas, the `Dir` enum, and the `Looted` signal) — the schemas the `[setup]`
  batch spawns against and the carried defaults (`dir Dir =Dir::Down`) resolve
  through ride in the artifact. Only the **import closure** is carried: a
  sibling declaration the entrypoint never imports (the level seam's `data
  Dungeon` symbol table) stays absent — its consumer is the deferred
  level-accessor surface, a later bump. The synthesized engine-type projections
  (§8) still land **last** in `[data]`, after own and imported records — and
  the carry widens the §8 trigger population with it: a `Path`-typed field on
  any own **or carried** thing/data/signal now synthesizes the §8 `Path`
  projection (`steps [Vec2]`, `cost Fixed`), so the carried Rabbit/Ferret
  `=Path(steps=[],cost=0)` defaults decode typed — the v5 Settings precedent
  applied inside the same closed synthesis mechanism, a [data] population
  widening like the rest of this bump, not a new mechanism. (b) The
  **imported-const carry**: an imported module-level `let` (the level seam's
  `terrain: TilemapHandle = TilemapHandle{name: "terrain"}`) appends to
  `[functions]` as the **existing** `function NAME const` record form — no
  params, the initializer as a single `return` subtree through the existing
  record/string nodes, the SEAM module's span (`span:dungeon:7`) — riding the
  same appended-after-own-records rule as the v6 seam-fn carry, so a behavior
  body's bare-name `terrain` read resolves to a self-contained record. (c) The
  **level-backed `[setup]` fold**: a `setup()` whose body is a lone call to a
  baked level's `<level>_spawns` extern (`return dungeon_spawns()`) emits the
  §17 bake's deterministic spawn list as concrete §13 rows — the extern has no
  body to inline, but the batch it stands for is a pure function of the tree,
  so §13's no-expressions contract holds where the prior emitter left
  `[setup 0]` (an empty initial world). Spawn order is the **bake order**
  (tilemap markers row-major where their layer is declared, then explicit
  `place` lines, declaration order); each spawn's `set` rows ride in the fixed
  order `pos` (the §13 `vec2` spread of the bake's cell-center/anchor fold) →
  `facing` (raw Q32.32 bits, only when authored) → params in source order, each
  param encoded by its **declared schema field type** (`gems: 5` on an `Int`
  field emits `set gems =5`, never raw bits). A field the level omits is not
  emitted — the runtime applies the §6 default off the carried `[things]`
  schema. A **Ref-valued param** has no ratified §13 encoding and is not
  emitted; it rides the deferred level-accessor bump. Widened populations are
  layout changes: 14 → 15. A single-module, level-less artifact moves by the
  version stamp alone (the v7 stamp-only restamp precedent). v16 carries the
  **§19 asset pixels** through to the runtime — the decoded atlas/image art a
  textured render (`Draw_Sprite{atlas, cell}`) needs and which an artifact-blind
  runtime could not draw (v11's `[tilemaps]` carried the tile **grid** but no
  pixels; the sprite art never reached the runtime). One layout change rides it:
  one new section, `[assets A]` (§19), appended after `[nav]` as the new fixed §3
  section **tail** (the `[nav]` tail precedent). Its records are two top-level
  kinds plus one sub-record: (a) `image HASH W H b64:RGBA` — one per **distinct**
  decoded image, **content-addressed** by its §2 image hash, the canonical RGBA8
  buffer base64-encoded (`core:encoding/base64`, std-alphabet RFC-4648) as one
  ASCII token so the committed text golden stays diffable and the runtime decodes
  with the same core pkg; two atlases sharing one image carry the blob **once**
  (the §2 hash dedup); (b) `atlas NAME IMAGE_HASH CELL_COUNT` — one per registered
  atlas, referencing its image by hash; (c) the new **sub-record keyword**
  `region NAME PX_X PX_Y PX_W PX_H` — one per atlas cell, the pixel rect into the
  image (the grid-coord×cell-size lowering), so `(atlas-name, cell-name) →
  (image pixels, pixel rect)` is resolvable from the artifact alone. The pixels are
  **not** a §29 purity break: `import_image` decodes deterministically and base64
  is a pure byte→ASCII map, so two emissions are byte-identical (the walk is
  slice-order over the baked model, never map order). A new section and one new
  sub-record keyword are layout changes: 15 → 16. An asset-less game writes the
  constant `[assets 0]` tail and moves by the version stamp alone (the v7
  stamp-only restamp / `[nav 0]` tail precedent). v17 carries the **§19
  textured-render cross-boundary links** the runtime needs to actually **texture**
  the dungeon — v16's pixel pipeline carried the sprite art, but the artifact held
  no bridge from a sprite/tile **reference** to those pixels, so every real dungeon
  sprite and tile fail-closed to no texture. Three coupled layout changes ride it:
  (a) the `[assets]` `atlas` record is keyed by the manifest **HANDLE name** —
  `atlas dungeon_atlas IMAGE_HASH CELL_COUNT`, the same name a `Draw_Sprite{atlas:
  assets.dungeon_atlas, cell}` references through its `AtlasHandle` const, **not**
  the `.atlas`-file-declared name (`DungeonAtlas`) v16 emitted, which no reference
  names — so `asset_region(handle, cell)` resolves from the artifact alone. (b) the
  **whole-module const carry + bare-name lowering** — the entrypoint reaches its
  handle const through a whole-module import (`import assets`, then
  `assets.dungeon_atlas`), which binds no bare name, so the v6/v15 brace-group carry
  missed it and the handle const never reached `[functions]`. The emitter now
  carries each whole-module-referenced handle const into `[functions]` as a
  `function NAME const` record (the v15 imported-const form, the seam module's span,
  the source's §26 typed handle value — `AtlasHandle`/`SoundHandle`/`MeshHandle`/
  `TextureHandle`, the kind **read** from the declared type, never hardcoded) **and**
  lowers every `assets.NAME` body member-expr to a bare `node name NAME` (the v6
  qualified→bare lowering), so the runtime resolves it by bare name with no
  special-case; a bare-name collision with an own-module declaration refuses the
  build. (c) the `[tilemaps]` **per-layer atlas + per-tile atlas-cell** — the lead
  line gains the layer's tileset atlas handle name between `ANCHOR_Y` and
  `PALETTE_COUNT` (`tilemap NAME CELL_SIZE COLS ROWS ANCHOR_X ANCHOR_Y ATLAS
  PALETTE_COUNT`, `-` for a degenerate palette-less layer), and each palette `tile`
  sub-record gains the atlas-cell coordinate (`tile NAME SOLID CELL_X CELL_Y`, the
  §18 §2 tileset cell v16 read but dropped), so the runtime resolves a tile's texture
  through `asset_region(atlas, cell)` exactly as a sprite does; a layer whose palette
  mixes tilesets with different atlases is refused (one atlas per layer). No new
  section and no new sub-record **keyword** (the `atlas` lead keyword and the
  `tile`/`row` sub-record keywords already exist — only their token shapes and the
  atlas record's NAME token change, plus a widened `[functions]` population); the
  three are field/keying/population layout changes: 16 → 17. A single-module,
  asset-less, level-less artifact (pong) moves by the version stamp alone (the v7
  stamp-only restamp precedent). v18 carries the **§28 §4 probe section** through to
  the runtime — the in-code `@break`/`@watch`/`@log`/`@trace` directives a **live**
  debug session honors. The §29 §2 Index Contract is the funpack-side record of every
  probe (for operator review) and does **not** reach the runtime; for a live session
  to honor an in-code probe the directive must ride the thing the runtime executes
  (§28 §4 "Probes ride the executable artifact"). One layout change rides it: one new
  section, `[probes P]` (§21), appended after `[assets]` as the new fixed §3 section
  **tail** (the `[assets]`/`[nav]` tail precedent). Each record is one top-level kind
  plus the existing §2.7 `node` body run: `probe KIND TARGET body_count` — `KIND` is
  the closed §05 §5 directive family lowercased (`break`/`log`/`watch`/`trace`, the
  **same** token the index `debug` field carries); `TARGET` is the probed
  declaration's name (the §28 §2 "addressing reuses index identity" the runtime
  resolves the probe against); `body_count` is `1` for a `@break`/`@log`/`@watch`
  (whose predicate/expression rides as the single §2.7 node-forest subtree that
  follows — **never** funpack source, §28 §2: the body is compiled funpack-side to a
  node forest the runtime's interpreter folds when the probe is honored) and `0` for a
  `@trace` (which carries no argument). `probe` is a new **top-level** record keyword,
  **not** a sub-record keyword, so the §2.1 sub-record keyword set is unchanged: the
  body `node` lines are the existing sub-records, so a probe-with-body is a
  variable-length top-level record read by the **same** lead-line discipline as a
  `[functions]` record. The section is **dev-only by construction**: the §29 §3
  release debug-directive ban refuses the **whole** build before emission whenever any
  declaration carries a probe under `--release` — exactly the v7 hole-ban / `stub`-node
  precedent (a release artifact never carries a `stub` because the hole-ban refuses the
  holed tree first), so a `--release` artifact's AST is probe-free and the emitter —
  which stays mode-blind — writes the constant `[probes 0]` tail for it, the same
  stamp-only move the `[assets 0]`/`[nav 0]` tails make. "Release artifacts hold no
  introspection machinery" (§28) is therefore satisfied: a release artifact's `[probes]`
  section is always empty. A new section is a layout change: 17 → 18. Every probe-free
  artifact (every release artifact, plus a probe-free dev build) moves to v18 by the
  version stamp plus this constant tail (the v7 stamp-only restamp / `[nav 0]` tail
  precedent).
- A runtime reads the stamp and **refuses a mismatch**: it loads only the exact
  version it was built for and rejects every other with a fix-it diagnostic,
  never a best-effort parse. An under- or over-shaped artifact is an error. This
  mirrors the Index Contract's exact-match discipline (§29 §2): the schema
  version is the single compatibility gate.

The version stamp is line 1 so a parser can reject a wrong version before reading
any payload.

---

## 2. Purity — bit-identical by construction

The artifact carries **no host nondeterminism** (§09, §29):

- **No clock** — no timestamps, build dates, or wall-clock anywhere.
- **No machine paths** — source spans are recorded as the **path-derived module
  name** (§15) plus a 1-based line, never an absolute or cwd-relative filesystem
  path.
- **No float** — every `Fixed` is stored as its **raw signed Q32.32 `i64` bits**
  in decimal (§2.3). There is no decimal-string round-trip, so emission and load
  are exact and identical on every machine.
- **No map iteration** — every list in this format is in a **defined total
  order** (declaration order, or the depth-first flattened pipeline order),
  never hash order.

Two emissions from the same source are therefore byte-identical: the format has
no field whose value depends on when, where, or on which machine it was emitted.

### 2.1 Lexical frame

- Encoding is **UTF-8**. Every line ends with a single `\n` (LF, `0x0A`); there
  is no `\r`, no trailing whitespace, and the file ends with a final `\n`.
- The format is **line-oriented**: one record per line. A record is a
  **kind tag** followed by space-separated fields:
  `KIND field1 field2 …`.
- Fields never contain a raw space, `\n`, or `\t` except inside a **string field**
  (§2.4), which is length-prefixed so a parser never scans for a delimiter inside
  it.
- A **section** is a `[section_name N]` header line stating the section name and
  its exact **top-level record count** `N`, followed by `N` top-level records.
- A top-level record may be **variable-length**: it is followed by a run of
  **sub-records** (e.g. `enum Side - 2` is followed by 2 `variant` lines; `thing
  Paddle false 1 5` is followed by 1 `gtag` and 5 `field` lines; a `function`/
  `behavior` record is followed by its `param`/`emit`/… lines **and** its body
  `node` run, §2.7). A **section body runs to the next `[` header** — header lines
  are the only line class that opens with `[`, so a parser reads a section's body
  unambiguously, then re-derives `N` by counting the **lead** lines (those whose
  keyword is *not* a sub-record keyword). The closed sub-record keyword set is:
  `variant`, `field`, `gtag`, `param`, `emit`, `producer`, `consumer`, `set`,
  `node`, `migrate` (v8, §6), `index` (v9, §16), `tile` and `row` (v11, §17),
  `navnode` and `navedge` (v13, §18), `region` (v16, §19). A
  declared `N` that disagrees with the lead-line count is an error (an under-
  or over-shaped section, §29-style exact-match).

  This **lead-line reader is the single parse discipline** for top-level record
  boundaries: a top-level record runs from its lead line up to the next lead line
  (or the next `[` header). Per-record scalar count fields (`param_count`,
  `emits_count`, `body_count`, an enum's `variant_count`) tell a reader how to
  shape each sub-record run *within* a record — but the **record count `N`** is
  always the lead-line count, never a sum of declared sub-counts. The format does
  **not** offer a second, grammar-only reader that derives `N` from declared
  sub-counts: a `const`'s body `node` run and a record's mixed `param`/`emit`/
  `node` sub-records are not all reachable from a single declared sub-count on the
  lead line, so only the lead-line discipline is sound. `node` being a sub-record
  keyword keeps every body line a sub-record, so the lead-line count is exact.

### 2.2 Integer encoding (`Int`)

A funpack `Int` is a 64-bit signed saturating integer (§10). It is written in
**decimal**, with a leading `-` for negatives, no leading zeros (except the value
`0`), no `+`, no thousands separators. Range is `[-9223372036854775808,
9223372036854775807]`.

### 2.3 Fixed encoding (`Fixed`)

A funpack `Fixed` is signed Q32.32 (`i64` raw, §10). It is written as its **raw
`i64` bits in decimal** — i.e. `value * 2^32`, truncated to the integer that the
compiler's fixed-point lowering produced. Examples (these are the exact bits the
golden fixture carries):

| Source literal | Raw Q32.32 bits |
|---|---|
| `0.0` | `0` |
| `0.5` | `2147483648` |
| `1.0` | `4294967296` |
| `2.0` | `8589934592` |
| `3.0` | `12884901888` |
| `4.0` | `17179869184` |
| `8.0` | `34359738368` |
| `16.0` | `68719476736` |
| `40.0` | `171798691840` |
| `60.0` | `257698037760` |
| `70.0` | `300647710720` |
| `80.0` | `343597383680` |
| `90.0` | `386547056640` |
| `120.0` | `515396075520` |
| `152.0` | `652835028992` |
| `160.0` | `687194767360` |
| `-70.0` | `-300647710720` |

To recover the logical value, a runtime divides the raw bits by `2^32` in its own
fixed-point representation; it never parses a decimal point. A `Fixed` field is a
plain decimal integer, lexically indistinguishable from an `Int` field — the
field's **position** (per the record's documented signature) tells the parser
which it is.

### 2.4 String encoding (`String`)

A string field is **length-prefixed**: `Lbyte_count:raw_bytes`. `byte_count` is
the decimal UTF-8 byte length; the bytes follow the `:` verbatim, including any
space or `\n` they contain. A parser reads `byte_count` then consumes exactly that
many bytes — it never interprets the contents. The empty string is `L0:`.

Example: the doc string `Move the paddle` (15 bytes) is `L15:Move the paddle`.

### 2.5 Bool encoding

`true` or `false`, lowercase, as bare tokens.

### 2.6 Identifier / name fields

A name (module, type, field, behavior, stage, enum, variant, signal, function) is
a bare UTF-8 token with no spaces. Qualified names use `.` as the segment
separator (`engine.math`, `Side::Left` uses `::` for an enum variant).

### 2.7 Body encoding — the serialized checked-AST node line

Every executable body the runtime must interpret — each `fn` body, each behavior
`step` body, each `const` initializer, the `bindings()` body, and the `setup()`
body — is serialized **into** the artifact as a tree of checked-AST nodes. The
runtime parses pong from this document with **zero `funpack` imports** and **no
`funpack` source on disk**, so a body cannot be a span reference into source the
runtime can never read: the artifact carries the whole node graph and the runtime
interprets it directly (§09 §1 — the interpreter is the canonical semantics).

A body is a flat, **pre-order** (depth-first, node-then-children) run of `node`
lines. Each node is exactly one line:

```
node KIND field… child_count
```

- `node` is the line's sub-record keyword (it is in the closed
  `SUB_RECORD_KEYWORDS` set, §2.1), so a body run is read by the same lead-line
  discipline as every other sub-record.
- `KIND` is a closed node-kind tag (the table below).
- `field…` are that kind's **scalar** fields in the documented order, each a
  primitive (`Int` §2.2, `Fixed` §2.3, `String` §2.4, name §2.6) — never a nested
  node.
- `child_count` is the **last** field on every node line: the count of immediately
  following `node` lines that are this node's children, in their documented order.
  A reader consumes the node, reads its scalar fields, then recursively consumes
  exactly `child_count` child subtrees. The encoding is therefore total and
  count-driven — a reader never looks ahead past a node's own declared children.
  The **one exception** is the `arm` node (below): an `arm` always has 0 children
  and its trailing field is a variable-length `binders` list (sized by its
  `binder_count` scalar), so `arm`'s child count is fixed at 0 by its kind rather
  than read as a trailing token. Every other node ends in `child_count`.

The node-kind set is closed (a new kind is a schema-version bump, §1) and mirrors
the checked surface AST (spec §02 §5–§6). Children are listed **in evaluation /
source order**; a node's `child_count` plus the kinds below fully determine the
subtree shape:

| KIND | Scalar fields | Children (in order) | Surface form |
|---|---|---|---|
| `int` | `value:Int` | 0 | integer literal `0` |
| `fixed` | `bits:Fixed` | 0 | fixed literal `4.0` (raw Q32.32, §2.3) |
| `name` | `ident:name` | 0 | a bare name `self`, `BOARD`, `add_goal` |
| `string` | `value:String` | 0 | string literal `"…"` (length-prefixed, §2.4; interpolation holes retained verbatim) |
| `field` | `member:name` | 1 = receiver | field access `a.b` |
| `call` | (none) | 1 + N = callee then N args | `f(a, b)` |
| `variant` | `type:name` `case:name` `has_payload:Bool` | N = payload args | `Side::Left`, `Option::Some(x)` |
| `record` | `type:name` `field_count:Int` `child_count:Int` | `child_count` = `field_count` `recfield` nodes (one per field) | `Vec2{x: …, y: …}` |
| `recfield` | `name:name` | 1 = the field's value subtree | one `name: value` pair inside a `record`/`with` |
| `with` | `field_count:Int` `child_count:Int` | `child_count` = `1 + field_count`: the base value, then `field_count` `recfield` nodes | `value with { f: v }` |
| `list` | `len:Int` | `len` element subtrees | `[a, b]`, `[]` |
| `lambda` | `param_count:Int` `params:name…` | 1 = the single-`return` body expr | `fn(p) { return e }` |
| `unary` | `op:name` | 1 = operand | `-x`, `not x` (`op` ∈ `neg`,`not`) |
| `binary` | `op:name` | 2 = lhs, rhs | `a + b` (`op` table below) |
| `match` | `arm_count:Int` `child_count:Int` | `child_count` = 1 scrutinee + (per arm: an `arm` subtree then its body) = `1 + 2*arm_count` | `match e { … }` |
| `arm` (scalar) | `pat:name` `type:name` `case:name` `binder_count:Int` `binders:name…` | 0 (fixed by kind; no trailing `child_count`) | a `wildcard`/`bare_variant`/`variant_binds`/`bare_binder` pattern (its body is the following sibling) |
| `arm` (tuple, v2) | `tuple` `child_count:Int` | `child_count` = the positional sub-pattern `arm` subtrees | a `(p, q, …)` tuple pattern, e.g. `(Option::Some(cell), next)` |
| `let` | `name:name` | 1 = the bound value expr | `let n = e` |
| `if_return` | (none) | 2 = condition, then the **outcome**: the returned value expr (single-bare-return guard) or a `block` (v14) | early-return `if cond { return v }` / `if cond { let x = …; return y }` |
| `if_expr` | (none) | 3 = condition, then arm, else arm | a value-producing `if c { a } else { b }` in expression position |
| `block` (v14) | (none) | `child_count` = the guard block's statement subtrees (`let`/`if_return`/`return`) | a multi-statement guard block in `if_return`'s outcome position; `let`s are block-scoped, completing without `return` falls through |
| `return` | (none) | 1 = the returned value expr | `return e` |
| `stub` (v7) | `form:name` (`bare` or `fallback`) | `fallback`: 1 = the approximation expr; `bare`: 0 | a §05 §2 typed hole standing for the whole body: `@stub(T, fallback)` / `@stub(T)` |
| `all` (v10) | `thing:name` | 0 | the §08 §3 world read `all[Ball]` — the thing's instance rows in stable `Id` order |

- `binary` `op` is the closed glyph set, by name: `add` `sub` `mul` `div` `mod`
  `eq` `ne` `lt` `le` `gt` `ge` `and` `or`. `unary` `op` is `neg` or `not`.
- `arm` `pat` is the pattern kind. The **scalar** patterns carry no child of
  their own (their body is the next sibling under the `match`): `wildcard`
  (`type`/`case` are `-`, `binder_count` 0), `bare_variant` (`type::case`,
  `binder_count` 0), `variant_binds` (`type::case` with `binder_count` payload
  binder names following on the same line — a binder of `_` is the discard
  binder), and `bare_binder` (v2 — a single binder name binding the whole tuple
  position, e.g. snake's `next` Rng position; its body is likewise the next
  sibling and it carries 0 children). The **tuple** pattern (v2) is the one arm
  with children: `arm tuple child_count` is followed by `child_count` positional
  sub-pattern `arm` subtrees, each a nested arm of any pattern kind (a variant, a
  wildcard, a bare binder, or a nested tuple). A reader reads a scalar arm's
  child count as 0 by kind, and a `tuple` arm's as the trailing `child_count`
  token. A `match` declares a `child_count` of `1 + 2*arm_count`: the scrutinee
  subtree, then for each arm an `arm` SUBTREE (a scalar arm is one line; a tuple
  arm is its head plus its sub-pattern arms) immediately followed by its body
  subtree. (For pong every match is two-armed with scalar arms, so `arm_count`
  is `2` and `child_count` is `5`; snake's `match pick(free, rng)` is two-armed
  with tuple arms, still `arm_count` `2` and `child_count` `5` because each
  tuple arm and its sub-arms count as one subtree.)
- A body's **top** is a single statement subtree per body line of the source: a
  `fn`/`step`/`const` body is a sequence of statements (`let`, `if_return`,
  `return`), so the owning record declares a `body_count` of top-level statement
  subtrees and the run is those subtrees back-to-back (§9, §10). A `const`
  initializer and the `setup`/`bindings` bodies are a single top-level statement.
- A **holed** declaration (v7) has no statement sequence at all — the `stub`
  node IS its body, the single top-level subtree (`body_count` 1). A runtime
  evaluating `stub fallback` evaluates the child expression in the record's
  param-bound scope (the same environment an intact body's statements read), so
  the approximation is bit-identical to the compiler interpreter's dev
  evaluation; evaluating `stub bare` is the **defined fail-closed no-value
  outcome** — the behavior instance folds nothing this tick, a calling
  expression fails closed — never a trap or undefined behavior.

Example — `goal_side`'s body (`if at.x < 0.0 { return Option::Some(Side::Right) }`
then `if at.x > BOARD.w { … }` then `return Option::None`) serializes to three
top-level statement subtrees, the first being:

```
node if_return 2
node binary lt 2
node field x 1
node name at 0
node fixed 0 0
node variant Option Some true 1
node variant Side Right false 0
```

The `if_return` declares 2 children (condition, value); the `binary lt` declares 2
(`at.x`, `0.0`); the `field x` declares 1 (its receiver `at`); the literals and
the leaf `variant Side Right` declare 0. A reader rebuilds the tree by consuming
exactly each node's declared child count, with no source and no lookahead.

---

## 3. Top-level layout

The artifact is the version stamp, then these sections **in this fixed order**.
Each is a `[name N]` header followed by `N` records. A runtime reads them
sequentially; the order is part of the contract.

```
funpack-artifact 18
[meta 2]
…
[enums N]
…
[data N]
…
[signals N]
…
[things N]
…
[functions N]
…
[behaviors N]
…
[pipeline_flattened N]
…
[signal_routing N]
…
[setup N]
…
[bindings N]
…
[entrypoint 1]
…
[queries N]
…
[tilemaps N]
…
[nav N]
…
[assets N]
…
[probes N]
…
```

Sections with no records still emit their header with `N = 0` and no body lines,
so a parser always reads a fixed sequence of headers. `[probes]` (§21) is the new
fixed tail; it is **dev-only** content (§28 §4) but always emits its header — a
release artifact and a probe-free dev build both write the constant `[probes 0]`
tail, so the header sequence stays fixed and a reader never needs the build mode.

---

## 4. `[meta]` — project identity

Two records, in order:

```
project NAME           # the §14 project.fcfg block label (package identity)
version L5:0.1.0       # the project.fcfg `version` value, as a String field
```

This is `(project.fcfg)` identity only (§14 §4): name + version. It carries no
build clock and no platform — platform is a build-driver concern (§14 §6), not an
artifact field.

---

## 5. `[enums]` — sum types and role kinds (§03 §2, §03 §4)

One record per declared enum, in source-declaration order. **v15:** the enums
the entrypoint module imports from sibling USER modules (dungeon's `Dir`)
follow the module's own records, in import-declaration order then brace-group
member order — the cross-module declaration carry (§1 v15). Each enum record is
followed by one `variant` record per variant, in declaration order:

```
enum NAME KIND variant_count
variant NAME PAYLOAD
…
```

- `KIND` is the §03 §4 role kind ascribed after the type name, or `-` for none:
  one of `Axis`, `Button`, `CollisionLayer`, `Num`, `-`. A `Steer: Axis` enum
  records `Axis`; a plain `Side` enum records `-`. The kind is type-constitutive
  (only an `Axis`-kinded enum binds to an analog input, §23), so it travels with
  the enum.
- `PAYLOAD` is the variant shape: `unit` (no payload, e.g. `Side::Left`),
  `tuple K` (K positional types — the type names follow on the same line), or
  `struct K` (K named fields `name:Type` follow). Pong's enums are all `unit`.

---

## 6. `[data]` — value records with field defaults (§03 §1, §08)

One `data` record per `data` declaration, in source order, each followed by its
fields. **v15:** imported sibling-module data declarations follow the module's
own records (the §1 v15 declaration carry); the synthesized engine-type
projections (§8) land last either way. Every field carries its declared type
and its default-presence flag:

```
data NAME field_count mut
migrate FROM -                  # v8, only for a renamed TYPE declaration
field NAME TYPE DEFAULT
migrate FROM WITH               # v8, only after a @migrate-prefixed field
…
```

- `mut` is `true` when the type was declared `mut data` (§03 §7), else `false`.
- `field` records carry: the field `NAME`, its `TYPE` (a name; a generic is
  written `Ctor[Arg]`, e.g. `Ref[Switch]`, `[Goal]` for a list; a §02 §3
  function type is space-free with a tight arrow, `fn(Int)->Bool`), and
  `DEFAULT`.
- `DEFAULT` is `-` when the field has no default (it must be supplied at every
  literal), or `=ENCODED` where `ENCODED` is the default value in this format's
  primitive encoding. A defaulted field may be omitted from a literal (§03 §1), so
  the runtime applies `DEFAULT` when a `setup` Spawn omits it.
- `ENCODED` is **one space-free token** — a `field` line is whitespace-delimited
  (`field NAME TYPE DEFAULT`) and §2.1 forbids a raw space in a non-string field,
  so the default is the line's fourth token, never a multi-token run. The §13
  `set FIELD =vec2 x y` setup form (a 3-token spread) is a `[setup]`-only spelling
  a reader shapes by the `set` record; it is **not** the field-default form. The
  default-token forms, by `TYPE`:
  - a `Fixed`, `Int`, `Bool`, or `String` scalar in its §2 primitive encoding
    (`=0`, `=4294967296`, `=true`, `=L0:`) — the original scalar form, unchanged;
  - an **enum-variant** default as its `Type::Case` token (§2.6), e.g.
    `=Hunt::Patrol`, `=Dir::Right`. Already space-free; a reader carries it as the
    enum token verbatim (the same shape an enum column holds);
  - an **empty-list** default `[]` as `=[]` (the only list literal a default
    admits — a defaulted list seeds empty, e.g. snake's `body: [Cell] = []`);
  - a **composite record** default (`Vec2`, `Cell`, any constructor) as its
    inline constructor token `Type(field=enc,…)`: the type name, then a
    parenthesized, comma-joined `field=ENCODED` list with **no interior spaces**
    (each `ENCODED` itself a space-free scalar/enum/record token, so the form
    nests). A `Vec2{x: 0.0, y: 0.0}` default is `=Vec2(x=0,y=0)`; a
    `Cell{x: 10, y: 10}` default is `=Cell(x=10,y=10)`. This is the §6 single-token
    realization of "its constructor record inline" — the parens-and-no-spaces
    spelling (cf. the §14 builder-call `keys_axis(Key::W,Key::S)` form) keeps a
    composite default in the one token a `field` line allows, where the §13
    space-spread `vec2` form cannot fit.
  - an **engine-type composite** default (v5) — a §11/§24 engine record used as a
    default — reuses the same inline-constructor token `Type(field=enc,…)`, with
    two v5 wrinkles. (i) A `Settings.defaults()` **static-builder** default is a
    CALL, not a value the §29-pure artifact can carry verbatim, so the emitter
    **evaluates** it to its canonical factory record and inlines that:
    `=Settings(volume=128,fullscreen=false)` — `volume` the default gain (Int),
    `fullscreen` off (Bool). The Settings the artifact carries is the runtime's
    representable two-field projection (`{ volume: Int, fullscreen: Bool }`),
    **synthesized into [data] as a `Settings` data record** (§8) so a reader
    resolves the default's nested field types by declared type. (ii) A `Body`
    default inlines with its **§11 §2 field defaults applied** — an omitted
    `impulse: Vec2` seeds `Vec2(x=0,y=0)` (`zero`), an omitted `mass: Fixed` seeds
    `1.0` (`4294967296`) — so the emitted Body token carries the complete resolved
    field set, never a half-built record the runtime would have to default. An
    `Option[String]` default is the enum-variant token `=Option::None` (the bare
    `Type::Case` form above; the `[String]` element only shapes the field's
    declared TYPE column, not the default token). **v15:** the §08 nav `Path`
    record rides the same form — warren_world's `path: Path = Path{steps: [],
    cost: 0.0}` emits `=Path(steps=[],cost=0)` against a synthesized §8 `Path`
    data record (`steps [Vec2]`, `cost Fixed`), the Settings synthesis precedent
    triggered over own **and v15-carried** declarations.

This is a **value-encoding addition within the field-default token**, not a new
section or node kind: a `field` line still carries exactly `NAME TYPE DEFAULT`, and
`DEFAULT` is still the one `=ENCODED` token a reader reads at `sf[3]`. The v5 bump
(§1) is driven by the singleton marker (§8), the physics-stage step (§11), the
CollisionLayer KIND value (§5), and — for §6 — the **synthesized engine-type data
projection** the Settings default decode requires (a [data] record the source's
defaults add, a record-layout change). The gameplay (pong) surface emits only the
scalar forms, so every pong default is byte-identical to v1's scalar encoding; the
composite forms are reached by the snake (`Cell`, `Dir`, `[]`) and hunt
(`Hunt::Patrol`, `Vec2`) goldens, and the engine-type composite/static-builder
forms by the yard (`Settings.defaults()`, `Option::None`, `Body`) surface.

**Migration carry (v8, §05 §6).** A `migrate` line is the fixed three-token
sub-record `migrate FROM WITH` carrying a `@migrate` directive's rename/retype
metadata — the two structural breaks the §09 §4 name-keyed schema-diff cannot
auto-resolve. `FROM` is the prior key as a bare name token (§2.6) or `-`; `WITH`
is the pure `fn(Old) -> New` conversion's name or `-`; at least one is present
(the compiler rejects an empty form upstream). Its **position** selects the
target: a `migrate` line **immediately following a `field` line** migrates that
field (`@migrate(from: "old_pos") pos: Vec2` emits `migrate old_pos -`); a
`migrate` line **between the `data` lead line and the first `field` line** is
the renamed type declaration's prior name (`@migrate(from: "OldName") data
NewName` emits `migrate OldName -`) — rename form only, so `WITH` is always `-`
there. The line is emitted only where the source carries the directive: a
migration-free `data` record is byte-identical to the v7 shape, and `[signals]`
/ `[things]` records never carry one (the `data` schema is the evolution
channel). The conversion fn named by `WITH` is an ordinary `[functions]` record
(§9) the loader resolves by name and runs the old value through at
restore/hot-reload migration time (§09 §4, §24).

`Board` is the one pong `data` type; `BOARD` is a module-level `let`, recorded in
`[functions]` as a `const` (§9) since it is a named value, not a type.

---

## 7. `[signals]` — the cross-thing message values (§03 §6)

A `signal` is a `data` value declared with the `signal` keyword — the sole
cross-thing channel (§06 §5). One record per signal, same field grammar as
`[data]` (§6), but `mut` is always `false` (a signal is per-tick, never
mutated). **v15:** imported sibling-module signals (dungeon_world's `Looted`)
follow the module's own records (the §1 v15 declaration carry):

```
signal NAME field_count
field NAME TYPE DEFAULT
…
```

Pong's one signal is `Goal { side: Side }`.

---

## 8. `[things]` — stateful entities with their blackboard schema (§06, §08)

One record per `thing` / `singleton`, in source order, each followed by its
blackboard schema (its `data` fields) and its `@gtag` set. **v15:** the things
the entrypoint module imports from sibling USER schema modules (dungeon_world's
`Player`/`Slime`/`Chest`, warren_world's `Rabbit`/`Ferret`/`Burrow`) follow the
module's own records with their complete defaulted field schemas — the schemas
the level-backed `[setup]` batch (§13) spawns and defaults against:

```
thing NAME SINGLETON gtag_count field_count
gtag L4:ball
field NAME TYPE DEFAULT
…
```

- `SINGLETON` is `true` for a `singleton` (§06 §2, a guaranteed-single-row thing
  spawned once before tick 0, accessed by type), `false` for a `thing`.
- `gtag` records (§05 registry, §14 §4) carry one registered tag each, as a
  String field, in source order. An unregistered tag never reaches the artifact —
  it is a compile error upstream.
- `field` records are the §6 field grammar: name, type, default. A defaulted
  field (`Scoreboard.left = 0`) records its default so a Spawn may omit it.

**Singleton tick-0 spawn marker (v5).** A `SINGLETON true` row IS the §06 §2
tick-0 spawn marker: a singleton is spawned **once before tick 0, accessed by
type**, and no `[setup]` Spawn supplies it (the §13 batch carries only `thing`
spawns). So the singleton's [things] row must carry its **complete defaulted
field schema** — every field with a §6 `=ENCODED` default — because that schema is
the *only* source the runtime has to fill the row's columns. A reader spawns one
row per `SINGLETON true` thing before tick 0, every column the field's decoded
default. yard's three singletons exercise the full §6 default vocabulary:
`Scoreboard { delivered: Int = 0 }` (a bare scalar), `Camera { at: Vec2 =
Vec2(x=…,y=…), zoom: Fixed = …, shake: Vec2 = … }` (composite Vec2 + Fixed), and
`Menu { settings: Settings = Settings(volume=128,fullscreen=false), dirty: Bool =
false, status: Option[String] = Option::None }` (an engine-type composite default,
a Bool, and an enum-variant Option default). A singleton field with no default
would leave a column the runtime cannot fill, so every singleton field carries one.

Pong's things: `Paddle`, `Ball`, `Scoreboard` (all `thing`; pong models the
score as a once-spawned `thing` in `setup`, not a `singleton`). yard's things:
`Player`, `Crate`, `Wall`, `Pad` (`thing`), and `Scoreboard`, `Camera`, `Menu`
(`singleton` — the tick-0 marker case).

---

## 9. `[functions]` — pure helpers, module constants, and bindings/setup heads (§02)

One record per module-level `fn`, `let`, the `bindings()` function, and the
`setup()` function, KIND-grouped in the fixed order fn-helpers → `const` →
`bindings` → `startup`, each group in source-declaration order (the golden
fixture and the emitter both embody this rule; readers locate records by
name, never by position). The §17 cross-module carry — imported sibling-module
fns (v6) and imported module-level consts (v15, the level seam's `terrain:
TilemapHandle`) — appends **after** the entrypoint module's own records, in
import-declaration order then brace-group member order, each record keyed to
its own SEAM module's span; the carried records are outside the KIND grouping
(the v6 appended-after rule). The v17 **whole-module const carry** extends this to
the whole-module import form: a const reached through `import assets` then
`assets.dungeon_atlas` (which binds no bare name, so the brace-group carry misses
it) is carried as the same `function NAME const` record with the §26 typed handle
value read from the seam's declared type (`AtlasHandle`/`SoundHandle`/`MeshHandle`/
`TextureHandle`), appended after the brace-group carries; the entrypoint's
`assets.NAME` body refs are **lowered to bare `node name NAME`** so the runtime
resolves them against this record by bare name (no qualified member-expr survives
to the artifact). The function **body** is the serialized
checked AST, carried **in** the record as a run of `node` lines (§2.7) — never a
span reference into source the runtime can never read. The record opens with the
signature and a body statement count; the `param` lines and the `node` body run
follow:

```
function NAME KIND param_count return:TYPE body_count span:MODULE:LINE
param NAME TYPE
…
node …
…
```

- `KIND` is one of: `fn` (a pure helper, e.g. `advance`, `goal_side`), `const`
  (a module-level `let`, e.g. `BOARD` — `param_count` is 0 and `return` is the
  value's type), `bindings` (the one §23 `fn() -> Bindings`), `startup` (the one
  §06 Startup head, `setup() -> [Spawn]`).
- `return:TYPE` is the declared return type (a name or generic per §2.6; `[Goal]`
  for a signal list, `[Spawn]` for the setup command list, `Bindings` for the
  binding head, `Option[Side]` for an option).
- `body_count` is the number of **top-level statement subtrees** in the body
  (§2.7): one per source statement line (`let`/`if_return`/`return`). A `const`
  initializer and the `bindings`/`setup` bodies are a single top-level `return`
  subtree, so their `body_count` is `1`. The body `node` run follows the `param`
  lines and is exactly those statement subtrees back-to-back, in source order.
  A §05 §2 **holed** fn (v7, dev artifact only) carries the single `stub`
  subtree as its body — `node stub fallback 1` plus the approximation expression
  for `@stub(T, fallback)`, `node stub bare 0` for the typecheck-only
  `@stub(T)` — so its `body_count` is `1` (§2.7).
- `span:MODULE:LINE` is the §15 module name and 1-based source line, kept as
  **diagnostic provenance** — never a filesystem path (§2 purity) and never the
  sole body representation. A runtime executes the carried `node` tree; the span
  only locates the construct in a diagnostic.
- `param` records carry each parameter's name and type, in declaration order.

The `const` record for `BOARD` carries its initializer as the body `node` run
(here a single `return` of a `Board{ w: 160.0, h: 120.0 }` record), so the runtime
evaluates the constant from the artifact alone — a default or a Spawn that reads
`BOARD.w` / `BOARD.h` resolves against the interpreted constant, no source needed:

```
function BOARD const 0 return:Board 1 span:pong:19
node return 1
node record Board 2 2
node recfield w 1
node fixed 687194767360 0
node recfield h 1
node fixed 515396075520 0
```

---

## 10. `[behaviors]` — transitions keyed to their pipeline stage (§06 §3, §06 §6)

One record per `behavior`, in **source-declaration order** (the stable order the
node-check ran in). Each carries the stage slot it occupies, its reserved-step
signature, and its `@gtag` set:

```
behavior NAME on:THING stage:STAGE contract:CONTRACT gtag_count param_count emits_count body_count
gtag L4:ball
param NAME TYPE
…
emit TYPE
…
node …
…
```

- `on:THING` is the §06 §3 owning thing whose blackboard this behavior writes.
- `stage:STAGE` is the pipeline stage slot the behavior is listed in
  (`control`, `collision`, `scoring`, `render`, `startup`) — the slot **confers**
  the contract (§06 §6).
- `contract:CONTRACT` is the engine-closed §06 §6 contract conferred by that slot:
  one of `Update`, `Render`, `Ui`, `Audio`, `Startup`. `paddle_move` is `Update`;
  `draw_ball` is `Render`.
- The **reserved step signature**: every behavior's per-tick entry point is the
  built-in `step` (§06 §3) — not a user-chosen name — so the artifact records the
  signature of `step`, not a name. `param` records are `step`'s parameters **in
  order**: `self` (the blackboard, type = `on:THING`), then resources (`Input`,
  `Time`), inbound signal lists (`[Goal]`), and read-only views (`View[Paddle]`).
  Its parameters are its reads (§06 §3).
- `emit` records are `step`'s return-side emissions: the blackboard type it writes
  (always its own `on:THING`, or absent for a pure Render that returns only
  `[Draw]`), the signal lists `[S]` it emits, and the command lists (`[Draw]`,
  `[Spawn]`) it returns. Its return is its writes (§06 §3). `emits_count` is the
  count of `emit` records.
- `body_count` is the number of **top-level statement subtrees** in `step`'s body
  (§2.7), one per source statement line. The body `node` run (§2.7) follows the
  `emit` lines and is exactly those statement subtrees back-to-back, in source
  order — the runtime interprets it as the behavior's per-tick transition, with no
  `funpack` source on its path. `wall_bounce`'s body, for instance, is two
  statements (`if self.pos.y <= 0.0 or … { return self with { vel: … } }`, then
  `return self`), so its `body_count` is `2`. A §05 §2 **holed** step (v7, dev
  artifact only) carries the single `stub` subtree as its body (`body_count` 1):
  a `stub fallback` step ticks its approximation expression live (the P8
  playability surface), a `stub bare` step fails closed — the instance folds
  nothing that tick, a defined no-value outcome, never a trap.

A behavior with no `param` beyond `self` and no `emit` beyond its blackboard is
dead code (§06 §6 Update "must write or emit *something*") — that is an upstream
gate, never an artifact state.

---

## 11. `[pipeline_flattened]` — the one total order (§07 §2, §07 §3)

The pipeline is funpack's schedule: an explicit, ordered plan for a tick where
**stage order is its meaning** (§07). A pipeline tree is flattened **depth-first**
into one total order (§07 §3). This section records that flattened order as a flat
sequence — pong's `Pong` pipeline has no sub-pipelines, so the flattening is the
five named stages in order, each expanded to its behaviors in listed order:

```
step ORDINAL stage:STAGE behavior:NAME
```

- `ORDINAL` is the 0-based position in the **total order** — the index a tick's
  fold (§07 §4) visits this step at. It is contiguous and gap-free.
- `stage:STAGE` is the owning stage name (documentary; its position is the
  contract, §07 §1).
- `behavior:NAME` is the **occupant** run at this step — a user behavior, or (v5)
  an engine **battery**. A behavior occupant must have a `[behaviors]` record
  (§10); a battery occupant has none.

**Physics-stage encoding (v5, §11 §3).** The §11 §3 `physics:` stage is an
**engine-closed** stage whose single member is the `solve` battery — collision
resolution writes BOTH bodies, which a behavior may never do, so it is the engine's,
not a behavior. It still occupies a real pipeline **position**: stage position is
the ordering — intent is written by the stages **before** `solve`, reactions are
consumed by the stages **after** (§11 §3). So a `physics: solve` stage flattens to
one **battery step** in the total order, the same line shape as a behavior step:

```
step 2 stage:physics behavior:solve
```

A battery step is **distinct from a behavior step**: its `behavior:NAME` is the
battery name (`solve`), not a `[behaviors]` record, so a reader keeps the step
position but binds **no** user behavior — it dispatches the step to the native
solver by the `(stage, behavior) = (physics, solve)` pair, never a behavior lookup.
The battery name was validated against the engine battery set upstream (only `solve`
exists, §11 §3). Because a battery step holds no signature, it produces **no**
[signal_routing] endpoint (§12): the engine's `Contact`/`Trigger` outputs are an
optional inbound edge, not a user-emitted signal subject to effect closure.

This is the derived, never-drifting flattened tree (§07 §3): effect closure
(§12's routing) runs on the same order, so the order recorded here **is** the
order the runtime folds. `startup:` steps (run once before tick 0, §07 §1) are
recorded first with `stage:startup`; the interior Update stages (yard's `control`,
then the `physics:solve` battery step, then `delivery`/`menu`/`camera`) follow;
the terminal `render:` projection stage is last.

---

## 12. `[signal_routing]` — producer(s) → consumer(s) map (§07 §2, §07 §3)

The derived `signal → producer(s) → consumer(s)` routing map (§07 §3). One record
per signal type that is emitted or consumed anywhere, in signal-declaration order.
Producers and consumers are listed by **flattened-order ordinal** (§11) so the
runtime can verify forward flow without re-deriving it:

```
route SIGNAL producer_count consumer_count
producer ORDINAL behavior:NAME
…
consumer ORDINAL behavior:NAME
…
```

**Effect closure** (§07 §2) holds iff every signal has ≥1 consumer at an ordinal
**strictly greater** than at least one producer's ordinal (the consumer is
downstream in the flattened order). The artifact records the routing; the runtime
may re-check closure against it, but the upstream gate already guaranteed it. For
pong, `Goal` is produced by `score` (in `scoring`) and consumed by `tally` and
`serve` (also `scoring`, but later in the listed order, so downstream).

---

## 13. `[setup]` — the Startup `[Spawn]` program (§06 §6, §07 §4)

The Startup behavior's `[Spawn]` command list, fully evaluated to concrete
encoded values — the deterministic batch applied at the tick boundary before tick
0 (§07 §4). The setup program carries **no expressions**; every field is a
primitive-encoded value (§2), so the runtime spawns the initial population without
interpreting an initializer:

```
spawn THING field_count
set FIELD =ENCODED
…
```

- `spawn THING` names the thing type being spawned, in the **source list order**
  of the `setup()` body (Paddle P1, Paddle P2, Ball, Scoreboard; yard's 4 Walls, 1
  Pad, 1 Player, 3 Crates).
- `set FIELD =ENCODED` carries each supplied field's value in this format's
  encoding: an enum variant as `Side::Left` (a name field, §2.6), a `Fixed` as its
  raw bits (§2.3), an `Int` in decimal (§2.2), a `Vec2` as a nested
  `vec2 x_bits y_bits` record. A field omitted in the source (relying on a
  default, §6) is **not** emitted here — the runtime applies the type's default.
- **A composite engine record** (a §11 §2 `Body`) takes the **§6 single-token inline
  form** `Type(field=enc,…)`: a parenthesized, comma-joined `field=ENCODED` list with
  **no interior spaces**, each nested value itself a space-free token (a nested `Vec2`
  collapses to `Vec2(x=,y=)`, NOT the `vec2 x y` spread, since a token carries no
  interior space). **A list** field (a `mask: [Layer]`) takes the `[enc,…]` form — a
  bracketed comma-joined run of space-free element tokens. yard's setup is the first
  surface to reach these: its `setup()` spawns through user helper fns
  (`crate_at(…)`, `wall_body(size)`) and constructs `Body` records, so the emitter
  **constant-folds** the batch at compile time (inlines the calls, resolves the
  nested records) and **applies the §11 §2 Body defaults the source omits** —
  `mass=1.0` (`4294967296`), `restitution=0.0` (`0`), `friction=0.5` (`2147483648`),
  `sensor=false`, `impulse=zero` (`Vec2(x=0,y=0)`) — so the emitted Body token carries
  the complete resolved column set, never a half-built record the runtime would have
  to default. This is the **same single-token composite spelling §6 already defines**
  for a field default, reused in the `set` slot (a `set` line carries `ENCODED` at one
  position, so a composite there is one token exactly as a §6 default is); it is
  **not** a new node kind. A reader discriminates the forms by the leading byte of
  `ENCODED`: `vec2` opens the §13 Vec2 spread, `[` a list, `(`-after-a-name a
  composite record, `::` a bare enum token, a digit a scalar.

**Level-backed setup (v15).** A `setup()` whose body is a lone call to a baked
level's `<level>_spawns` seam extern (`return dungeon_spawns()`) folds at emit
time against the §17 bake instead of the source list: one `spawn THING
field_count` per `Baked_Spawn` in **bake order** — tilemap markers row-major
where their layer is declared, then explicit `place` lines, declaration order —
with the `set` rows in the fixed order `pos` (the `vec2` spread of the bake's
cell-center/anchor fold) → `facing` (raw Q32.32 bits, only when the placement
authored one) → params in source order. A param encodes by its **declared**
schema field type (the bake folds scalars to Fixed; an `Int` field re-truncates
to decimal — dungeon's `Chest { gems: 5 }` emits `set gems =5` — a `Bool` field
its bare token, a `Fixed` field its raw bits). A field the level omits is not
emitted; the runtime applies the §6 default off the carried `[things]` schema
(the same omission rule as a source-listed spawn). A **Ref-valued param** is
not emitted — its encoding rides the deferred level-accessor bump (§1 v15).
`field_count` counts exactly the `set` rows that follow.

This is the §07 §4 fixed-population batch: population is fixed within a tick, and a
thing spawned this tick is first queryable next tick.

---

## 14. `[bindings]` — the §23 axis/button source map

The `bindings()` function's resolved binding table (§23 §3) — the **only**
device-aware data in the artifact. One record per `.axis(…)` / `.button(…)` call,
in **source-call order** (bindings stack, §23 §3, so order is preserved):

```
bind axis PLAYER ACTION source:SOURCE
bind button PLAYER ACTION source:SOURCE
```

- `axis` / `button` is the binding's analog/digital kind, matching the action's
  §03 §4 role kind (`Axis` → `axis`, `Button` → `button`).
- `PLAYER` is the `PlayerId` (`P1`..`P4`), a name field.
- `ACTION` is the enum variant the binding targets (`Steer::Move`), a name field.
- `source:SOURCE` is the device source, one of the **closed v3 source-form set**
  below, rendered as a builder call — the device names (§23 §3) appear **only
  here**, never in sim logic. Multiple bindings for one action stack (§23 §3);
  each is its own record.

The v3 SOURCE forms (a closed taxonomy — a new form bumps the version, §1):

| Form | Arity | Contribution |
|------|-------|--------------|
| `key(Key::X)` | 1 | digital button edge/level |
| `pad(PadButton::X)` | 1 | digital button edge/level |
| `keys_axis(neg,pos)` | 2 | 1D axis: neg key −1, pos key +1 |
| `stick_x(Stick::S)` / `stick_y(Stick::S)` | 1 | 1D axis: that stick component's deadzoned sample |
| `keys_quad(neg_x,pos_x,neg_y,pos_y)` | 4 | 2D axis: digital ±1 per component |
| `stick(Stick::S)` | 1 | 2D axis: both deadzoned stick components |

A 1D form contributes to the action's single 1D value (the slot `input.value`
reads); a 2D form (`keys_quad`, `stick`) contributes both components (the Vec2
`input.axis` reads). The emitter **lowers** the §23 §3 builder helpers into this
set: a key-list button source (`.button(P1, Move::Up, [Key::W, Key::Up])`)
spreads into one `key(…)` record per listed key (stacking, §23 §3); `wasd()`
lowers to `keys_quad(Key::A,Key::D,Key::W,Key::S)` — argument order
(neg_x, pos_x, neg_y, pos_y), where **up is `neg_y`** in the y-down draw space
(§20), matching stick polarity (stick-up samples negative) so keyboard and stick
contributions agree; `stick(Stick)` is recorded verbatim as a first-class 2D
source, **never** spread into the 1D `stick_x`/`stick_y` halves.

Pong binds P1 `Steer::Move` to `keys_axis(Key::W,Key::S)` and
`stick_y(Stick::Left)`, and P2 `Steer::Move` to `keys_axis(Key::Up,Key::Down)` and
`stick_y(Stick::Left)` — four binding records. Snake spreads its four key-list
button bindings into eight `key(…)` records; hunt binds P1 `Drive::Move` to
`keys_quad(Key::A,Key::D,Key::W,Key::S)` and `stick(Stick::Left)` — two 2D
records.

---

## 15. `[entrypoint]` — the runtime wiring (§07 §1, §14 §4)

Exactly one record for the selected entrypoint, lifting
`funpack_configs/entrypoints.fcfg` (§14 §4): the pipeline ↔ tick ↔ bindings
wiring that a pipeline carries **no** configuration for (§07 §1 — wiring lives in
the entrypoint, never the pipeline):

```
entrypoint NAME pipeline:PIPELINE tick_hz:HZ logical:WxH bindings:BINDINGS
```

- `NAME` is the entrypoint block label (`main`).
- `pipeline:PIPELINE` is the root pipeline (`Pong`) whose flattened order is
  §11.
- `tick_hz:HZ` is the fixed tick rate as an integer Hz (`60` for `60hz`). There
  are no multi-rate ticks (§07 §1); this is the single top-level tick.
- `logical:WxH` is the fixed logical draw space (§20 §3) in integer world units
  (`160x120` for pong, `160x160` for snake), lifted from the entrypoint block's
  required `logical = WxH` (§14 §4). The present pass scales and letterboxes
  this extent to the window; both dimensions are positive integers — a
  zero/negative or malformed extent is refused at fcfg parse and at load.
- `bindings:BINDINGS` names the `bindings` function (§14, §23) whose resolved
  table is §14's `[bindings]`.

`net:` topology (§25) is absent for pong; when present it would add a
`net:TOPOLOGY` field — its absence is the no-netcode capability (§14 §4 derives
the capability set; no `net:` ⇒ netcode off), and adding the field bumps the
schema version (§1).

---

## 16. `[queries]` — state-query declarations with their index requirements (§08 §3, §05 §3)

One record per entrypoint-module `query` declaration, in **source-declaration
order** (v9). A `query` is the §08 §3 read-only declaration form — pure over
`(version, params)`, within-tick memoized — and its prefixed `@index`/`@spatial`
directives are the engine-maintained index structures the runtime must build
and keep current over the world database. The record is the `[functions]` mold
(§9) extended with the requirement lines:

```
query NAME param_count return:TYPE index_count body_count span:MODULE:LINE
param NAME TYPE
…
index KIND THING FIELD
…
node …
…
```

- `param_count`, `return:TYPE`, `body_count`, and `span:MODULE:LINE` read
  exactly as a `[functions]` record's (§9); the body `node` run follows the
  `param` and `index` lines. A query body is a Block by grammar
  (`QueryDecl` admits no body-position `@stub`), so the run is always the plain
  §2.7 statement forest — never a `stub` subtree.
- `index_count` is the number of `index` lines — the §05 §3 requirements the
  query declared. Zero is legal (an index-free query).
- `index KIND THING FIELD` is one declared requirement: `KIND` is the closed
  two-value directive set `index` (engine-maintained reverse/key lookup) or
  `spatial` (deterministic radius/nearest structure); `THING` is the declared
  thing the index ranges over; `FIELD` is the indexed field on that thing. The
  typechecker proved the path (`check_index_paths`), so a reader takes the
  tokens as resolved names.
- Several queries may declare the same `(KIND, THING, FIELD)` requirement; the
  runtime maintains ONE structure per distinct requirement (§08 §3: an index is
  a cache — a pure function of state).
- Cross-module query carry is deliberately absent (the §17-levels seam carries
  fns only); widening it is a schema bump.

---

## 17. `[tilemaps]` — baked tile layers (§18 §3, schema v12; atlas+cell v17)

One record per baked tilemap layer, in **level declaration order** (a
multi-level tree contributes its levels in sorted authoring-filename order,
the §14.4 deterministic walk, each level's layers in declaration order). A
layer is the static environment a `.flvl` tilemap's ASCII grid bakes to: the
runtime renders it **batched** and collides against it — never per-tile
`Draw::Sprite` (§18 §3). Spawn **markers are not here**: a marker lowers to the
spawn machinery like every placement, so this section carries terrain only.

```
tilemap NAME CELL_SIZE COLS ROWS ANCHOR_X ANCHOR_Y ATLAS PALETTE_COUNT
tile NAME SOLID CELL_X CELL_Y
…
row C0 C1 … C{COLS-1}
…
```

- The lead line: `NAME` is the layer's authored name (also the level seam's
  `TilemapHandle` constant name); `CELL_SIZE` is the per-cell logical size in
  integer world units; `COLS`/`ROWS` are the grid dimensions;
  `ANCHOR_X`/`ANCHOR_Y` are the **grid→world anchor** — the world point of the
  grid's top-left corner as two raw Q32.32 `Fixed` fields (§2.3), emitted by
  the bake from the level bounds (`bounds_min.x`, `bounds_max.y`) and
  **authoritative**: a reader takes the anchor as final, never re-derives it
  from the grid's extent (v12); `ATLAS` is the layer's tileset **atlas handle
  name** (v17) — the same name the `[assets]` `atlas` record is keyed by, so the
  runtime resolves a tile's texture through `asset_region(ATLAS, cell)` exactly
  as a textured `Draw_Sprite` does (`-` for a degenerate palette-less layer, which
  paints no terrain); `PALETTE_COUNT` is the number of `tile` lines that follow.
  Every palette tile in a layer shares one atlas — a layer mixing tilesets with
  different atlases is a bake error (one atlas per layer), so `ATLAS` is always
  well-defined.
- `tile NAME SOLID CELL_X CELL_Y` is one palette entry: the project-global tile
  name, its §18 §2 **baked collision verdict** (`true`/`false`, §2.5), and its
  **atlas-cell coordinate** (`CELL_X CELL_Y`, decimal §2.2 — the §18 §2 tileset
  cell the tile draws from, v17) — the bake already resolved the name through the
  tileset table, so a reader takes all four tokens as final. The runtime resolves
  the tile's pixels through `asset_region(ATLAS, (CELL_X, CELL_Y))` the way a sprite
  resolves through its atlas. Entries follow the legend's declaration order.
- Exactly `ROWS` `row` lines follow the palette, top row first (the grid is
  read as a picture: row 0 is the level's TOP edge). Each carries exactly
  `COLS` space-separated cells: a decimal **palette index** (0-based into this
  record's `tile` lines) or `-` for a tile-less cell (an `empty` legend bind or
  a marker cell).
- The grid→world mapping reads the carried anchor: cell `(col, row)`'s center
  is `(ANCHOR_X + col*CELL_SIZE + CELL_SIZE/2,
  ANCHOR_Y - row*CELL_SIZE - CELL_SIZE/2)` — the same point the bake gave the
  cell's markers and `cell()` anchors (the anchor IS `(bounds_min.x,
  bounds_max.y)`), so render, collision, and spawns share one mapping, and the
  record is self-describing for any level bounds.

---

## 18. `[nav]` — baked nav graphs (§12 §1, schema v13)

One record per baked tile layer, in the **same slice order** `[tilemaps]`
emits (§17), so a `[nav]` record keys **1:1** to its `[tilemaps]` record by
position — the same level-declaration / §14.4 deterministic-walk order. A nav
graph is the §12 §1 **walkable-cell topology** a tilemap's solids imply, baked
once so the runtime path-finds over a graph it never authored (the picture **is**
the topology). `[nav]` is the fixed final section of the §3 order (§3).

```
nav NAME NODE_COUNT EDGE_COUNT
navnode FIXED_X FIXED_Y
…
navedge A B
…
```

- The lead line `nav NAME NODE_COUNT EDGE_COUNT`: `NAME` is the layer's authored
  name (the same token its `[tilemaps]` record carries); `NODE_COUNT` is the
  number of `navnode` lines that follow; `EDGE_COUNT` is the number of `navedge`
  lines after them. The lead line carries **no** grid metadata — no `COLS`/`ROWS`,
  no `CELL_SIZE`, no anchor. This is the **deliberate §12 §5 asymmetry** vs
  `[tilemaps]` (§17), which carries `COLS`/`ROWS` because its grid is rendered and
  collided **batched** by cell. The nav graph exposes only walkable **centers** and
  their adjacency: the raw **Cell index is never exposed** in the wire format
  (§12 §5), so no col/row leaks through `[nav]`.
- `navnode FIXED_X FIXED_Y` is one walkable cell's world-space **center**, two raw
  Q32.32 `Fixed` fields (§2.3) — the **same anchor encoding** the v12 `[tilemaps]`
  lead line uses, reconstructed from the layer's anchor + `CELL_SIZE` alone. One
  `navnode` per walkable cell, in **row-major** order (the grid read as a picture,
  row 0 = the level's top edge — the §17 row order), so a node's **line position
  is its node index** (0-based). Centers, not indices, are the token precisely
  because §12 §5 forbids exposing the Cell index.
- `navedge A B` is one **4-neighbor orthogonal** adjacency: `A` and `B` are two
  decimal **node indices** into the row-major `navnode` list (each `0 ≤ idx <
  NODE_COUNT`). The right/down neighbor pair of every walkable cell is deduped to
  **one undirected edge**, written **canonical `A < B`**, and the `navedge` lines
  are in **ascending `(A, B)`** order. §12 §4 makes diagonal/cost a bake-time
  stance, so the conservative single-algorithm **4-neighbor** bake is the default
  — never an 8-neighbor diagonal toggle without a spec decision.
- **Walkable = non-solid.** A cell is a `navnode` iff it is **not solid** — the
  walkability verdict is derived from the tilemap palette's `solid` flag (the
  `tile NAME SOLID CELL_X CELL_Y` line, §17), the §12 §1 **single source of
  truth**. A solid
  cell contributes no node and no incident edge; the nav graph never re-decides
  collision.
- The §12 §1 **hierarchical decomposition is invisible** in the wire format: one
  **flat** graph per layer, no tiers — the runtime path-finds the flat node/edge
  list directly.
- The section carries **no occupancy** — `los` is deliberately *not* computable
  from `[nav]`. Line-of-sight is an occupancy query, not a connectivity query:
  the engine answers it over the layer's **live committed tile state** (the 1:1
  `[tilemaps]` record this section keys to — same `NAME` token, same slice
  position), never over a baked solids copy that could drift from the §12 §1
  single source of truth (ADR
  `2026-06-11-engine-los-reads-live-tilemap-occupancy`). Centers + adjacency
  stay the section's whole surface.
- A **level-less** artifact has no tile layers, so this section is the constant
  empty tail `[nav 0]` — the §3 fixed-tail precedent the level-less `[tilemaps 0]`
  set. Every level-less artifact moves to v13 by the version stamp plus this
  constant tail (the v12→v13 stamp-and-empty-tail restamp, §1).

---

## 19. `[assets]` — baked sprite pixels + atlas slice rects (§19, schema v16; handle-keyed atlas v17)

The decoded atlas/image art a textured render needs — the pixels a
`Draw_Sprite{atlas, cell}` blits and which an artifact-blind runtime could not
draw. `[tilemaps]` (§17) carries the tile **grid**; this section carries the
sprite **pixels**. `[assets]` is the fixed final section of the §3 order (the
new tail, after `[nav]`). Records are two top-level kinds — `image` and `atlas`
— plus the `region` sub-record:

```
image HASH W H b64:RGBA
atlas NAME IMAGE_HASH CELL_COUNT
region NAME PX_X PX_Y PX_W PX_H
…
```

- `image HASH W H b64:RGBA` is one **distinct** decoded image, **content-addressed**
  by its §2 content hash: `HASH` is the canonical hash (`sha256:…`, the same value
  the asset manifest keys the image by); `W`/`H` are the decoded pixel dimensions
  (`Int` §2.2); `b64:RGBA` is the canonical RGBA8 buffer (`W·H·4` bytes, row-major
  top-to-bottom — the `import_image` `.alpha_add_if_missing` output) base64-encoded
  (`core:encoding/base64`, the std-alphabet RFC-4648 encoding) as **one ASCII
  token** on the line. The base64 keeps the committed text golden diffable and the
  runtime decodes with the same `core` package. Two atlases sharing one image hold
  the blob **once** (the content-hash dedup) — each references it by `HASH`, never
  by repeating the pixels.
- `atlas NAME IMAGE_HASH CELL_COUNT` is one registered atlas, in committed-registry
  order: `NAME` is the atlas's registered **HANDLE name** (v17) — the manifest
  `[name]` block the asset is registered under (`dungeon_atlas`), the **same** token
  a `Draw_Sprite{atlas: assets.dungeon_atlas, cell}` carries through its
  `AtlasHandle` const, **not** the `.atlas`-file-declared name (`DungeonAtlas`),
  which no sprite reference names; keying by the handle name is what lets
  `asset_region(NAME, cell)` resolve a sprite or tile to its pixels. `IMAGE_HASH` is
  the `image` record it slices (the dedup key); `CELL_COUNT` is the number of
  `region` sub-records that follow. The handle const itself rides `[functions]` as a
  `function NAME const` record (the v15/v17 const carry), so the runtime resolves the
  sprite's `atlas` field to this `NAME` and then this record by it.
- `region NAME PX_X PX_Y PX_W PX_H` is one atlas cell's **pixel rectangle** into
  its image, in atlas source-declaration order: `NAME` is the cell name a sprite
  draw addresses; the rect is the §19 grid-coord×cell-size lowering —
  `PX_X = cell.x·grid_w`, `PX_Y = cell.y·grid_h`, `PX_W = grid_w`, `PX_H = grid_h`
  (all decimal `Int` §2.2). So `(atlas-name, cell-name) → (image pixels, pixel
  rect)` is resolvable from the artifact alone: find the atlas by `NAME`, its image
  by `IMAGE_HASH`, the cell's rect by `region NAME`.
- **Purity (§29).** The pixels are not a host-nondeterminism break: `import_image`
  decodes deterministically (the §4 deterministic importer) and base64 is a pure
  byte→ASCII map, so two emissions are byte-identical. The image and atlas walks
  are slice-order over the baked model, never map order.
- An **asset-less** game has no sprite assets, so this section is the constant empty
  tail `[assets 0]` — the §3 fixed-tail precedent the `[nav 0]`/`[tilemaps 0]` tails
  set. Every asset-less artifact moves to v16 by the version stamp plus this constant
  tail (the v7 stamp-only restamp precedent).

---

## 21. `[probes]` — in-code debug directives (§28 §4, §05 §5, schema v18)

The in-code `@break`/`@watch`/`@log`/`@trace` directives a **live** debug session
honors. The §29 §2 Index Contract is the **funpack-side** record of every probe
(for operator review) and does not reach the runtime; for a live session to honor
an in-code probe the directive must ride the thing the runtime executes (§28 §4
"Probes ride the executable artifact"). `[probes]` is the fixed final section of
the §3 order (the new tail, after `[assets]`). One top-level record kind plus the
existing §2.7 `node` body run:

```
probe KIND TARGET body_count
node …
…
```

- `probe KIND TARGET body_count` is one in-code directive, in **source-declaration
  order** (the same `ast.decls` walk the §29 §2 index emits and the §29 §3 release
  ban scans, then directive order within one declaration): `KIND` is the closed §05
  §5 directive family lowercased — `break` (`@break(<pred>)`, pause when the
  predicate holds), `log` (`@log(<expr>)`, emit the structured value each step),
  `watch` (`@watch(<expr>)`, fire `watch_fired` on change), `trace` (`@trace`, record
  the per-step transition) — the **same** token the index `debug` field carries, so
  the two probe surfaces name a probe identically. `TARGET` is the probed
  **site** (a name field, §2.6) — the §28 §2 index identity static structure and
  live state share. It takes two shapes, both that one addressing namespace
  (`Snake`, `Snake.eat`). A **declaration-prefix** probe (a behavior
  `@break`/`@log`/`@watch`/`@trace`) carries the **bare declaration name**
  (`debug_serve_threshold`). A **sub-declaration** probe carries the **qualified
  `Owner.member` site**: a `@watch` on a `data` field is `<data>.<field>`
  (`DriftLog.bias`), a `@trace` on a pipeline stage is `<pipeline>.<stage>`
  (`Loop.mark`). The owner prefix disambiguates a field from a stage of the same
  bare name (top-level declaration names share one namespace), so the runtime
  resolves the prefix to a declaration, then the member within it. The qualifier is
  one space-free token, so it rides this same name-field slot with no record-grammar
  change. `body_count` is the number of body `node` subtrees that follow: `1` for
  `@break`/`@log`/`@watch` and `0` for `@trace`.
- The body (when `body_count` is `1`) is the directive's predicate/expression as a
  single §2.7 **node-forest** subtree — `@break`'s predicate over `self`/signals/
  resources, `@log`/`@watch`'s value expression — encoded through the **same** `node`
  run a `[functions]` body uses (§2.7), **never** as funpack source (§28 §2: the
  runtime owns no funpack compiler; the body is compiled funpack-side to a node
  forest the runtime's interpreter folds when the probe is honored). `@trace` carries
  no argument, so its `body_count` is `0` and no body follows.
- `probe` is a **top-level** record keyword, not a sub-record keyword (§2.1), so the
  closed sub-record keyword set is unchanged; the body `node` lines are the existing
  `node` sub-records, so a probe-with-body is a variable-length top-level record read
  by the **single lead-line discipline** (§2.1) exactly like a `[functions]` record.
- **Dev-only by construction.** A probe is **release-forbidden** (§28 §4: a
  `@break`/`@log` in a `--release` build is a compile error), so the §29 §3 release
  debug-directive ban refuses the **whole** build before any emission whenever a
  declaration carries a probe under `--release` — exactly the v7 hole-ban / `stub`-node
  precedent (a release artifact never carries a `stub` because the hole-ban refuses the
  holed tree first). A `--release` artifact's checked AST is therefore probe-free, and
  the emitter — which stays **mode-blind** — writes the constant empty tail `[probes
  0]` for it. A probe-free **dev** build likewise writes `[probes 0]`. So "release
  artifacts hold no introspection machinery" (§28) holds: a release artifact's
  `[probes]` section is always empty, yet the header always emits, so a reader reads a
  fixed §3 header sequence and never needs the build mode (which it cannot learn from
  the artifact — §4 carries no build/platform field).
- **funpack emits** the probe section into a dev-build artifact (this section); **the
  runtime loads it and honors every probe** in a live session — that load+honor half
  is a downstream task, not this format-side emission.
- **Purity (§29).** The walk is source-declaration order over `ast.decls` (never map
  order) and the body is the deterministic §2.7 node serialization, so two emissions
  are byte-identical.

---

## 20. Parsing recipe (runtime, zero funpack imports)

A runtime parses an artifact thus, reading top-to-bottom, never seeking:

1. Read line 1; split on space; assert literal `funpack-artifact` and the integer
   version equals the runtime's built-for version, else **refuse** (§1).
2. For each section in the §3 fixed order: read the `[name N]` header, parse `N`,
   read the section body up to the next `[` header, and split it into `N`
   top-level records using the **single lead-line discipline** (§2.1) — a record
   spans its lead line up to the next lead line. Lead lines are those whose
   leading keyword is *not* in the closed sub-record keyword set (`variant`,
   `field`, `gtag`, `param`, `emit`, `producer`, `consumer`, `set`, `node`,
   `migrate`, `index`, `tile`, `row`, `navnode`, `navedge`, `region`). This
   is the **only** parse discipline; the format does not promise a
   second grammar-only reader that derives `N` from declared sub-counts (it cannot
   be sound where a record carries an uncounted run, e.g. a `const`'s body `node`
   lines). Assert the lead-line count equals `N` or **refuse** (§29-style
   exact-match).
3. Within each record, decode each field by its **position** in the record's
   documented signature: a `Fixed` is the raw decimal `i64` (§2.3), an `Int` is
   decimal (§2.2), a `String` is `Lk:bytes` (§2.4), a name is a bare token (§2.6).
   Shape the record's sub-records using its declared scalar counts (`variant_count`,
   `param_count`, `emits_count`, `body_count`); read each body `node` run (§2.7) as
   a pre-order tree, consuming exactly each node's declared `child_count`.
4. Build the in-memory game model (enums, data/signal/thing schemas, function
   bodies, behaviors with their step bodies, the flattened pipeline, the routing
   map, the spawn batch, the binding table, the entrypoint, the query
   declarations with their index requirements, the tile layers, the nav graphs,
   the sprite assets, the debug probes) and interpret the carried checked-AST nodes
   per the §09 canonical semantics.

Because every section's `N` is the lead-line count, every record shapes its
sub-records by declared scalar counts, every body `node` declares its `child_count`,
and every field is positionally typed and length-explicit, the parse is total and
the byte layout is unambiguous. No `funpack` source is needed — this document is
the whole contract, bodies included.
