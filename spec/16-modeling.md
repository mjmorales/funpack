# 16 — Modeling DSL (`.fpm`)

funpack deliberately has **two languages**: the **modeling DSL** (`.fpm`) — imperative, float-tolerant,
scripty (OpenSCAD/Python feel), running **at bake time only** — and the **`.fun` core** — pure,
fixed-point, gated, which never sees a `.fpm` and consumes only the generated typed seam. The seam is
the load-bearing idea: **script → model → generated references + wiring**, stable enough that a
procedural prototype is **replaced incrementally** by hand-authored assets without touching game code.

## 1. Why a second language doesn't break the axioms

- **P3** — modeling *is* an asset-pipeline stage; its expressiveness is a property of engine
  batteries (CSG, sweeps, materials), not user abstraction.
- **R1** — the **file type is the disambiguating token**: `.fpm` is unambiguously bake-time/float/
  imperative, `.fun` unambiguously sim-time/fixed-point/pure. No single source mixes the regimes.
- **P4** — modeling needs only **build** determinism (same script + inputs → identical hashed asset;
  seeded noise, no wall-clock); it is exempt from **simulation** determinism because its output is
  baked and content-hashed, never re-evaluated in the hot path.

`.fpm` reuses the core token priors (`fn`, `let`, `for x in`, `{ … }`, `return`) and **allows
`//` comments**; it diverges only where bake-time freedom earns it — **local mutation, accumulating
loops, and float arithmetic are legal**, because none survives into the sim. Concretely: a local
**reassignment** is `name = expr` (the l-value is a bound local or a dotted path into one), and an
**accumulating loop** is `for x in <iterable> { … }` over a list or an integer range `a..b`. Both are
bake-time only and have no `.fun` counterpart — the sim has neither mutation nor loops
([`02`](02-language-core.md) §6).

## 2. The `model` / `rig` vocabulary

```
model Table {
  param width: Length = 120
  fn leg() -> Solid { return box(6, 6, height) }
  emit     union(slab, legs)                  // render geometry
  anchor   seat_top = slab.face("top").center // a named point
  socket   cup      = seat_top.offset(z: 2)   // an attach point
  material body     = pbr(color: oak, rough: 0.6)
  collide  proxy    = box(width, depth, height) // a sim-side hull
}
```

| Keyword | Purpose | Generates |
|---|---|---|
| `param` | a tunable knob + default | a field on the params `data` |
| `emit` | the render geometry (`Solid`) | a content-hashed `MeshHandle` |
| `anchor` | a named point/plane | an `Anchors` entry, queried semantically |
| `socket` | an anchor intended as an attach point | an `Anchors` socket entry |
| `material` | an appearance slot (engine PBR; no user shaders) | a material binding |
| `collide` | a sim-side collision proxy | a fixed-point `Shape3` ([`11`](11-physics.md)) |

The geometry algebra is engine-provided and **boring on purpose**: primitives (`box`, `sphere`,
`cyl`, `capsule`), booleans (`union`, `difference`, `intersect`), transforms (`.at`, `.rotate`,
`.scale`, `.up`/`.down`), and the 2D↔3D bridge (`extrude`, `revolve`, `loft` over a `Sketch`). CSG
booleans ride the OpenSCAD prior. Half-edge editing, SDF authoring, and node graphs are rejected.

A **`rig`** block adds character authoring: `skeleton: <topology>` (a stdlib topology or inline
tree), `part <name> at BONE = <mesh>` (the part's modeled origin **is** that bone's joint — a checked
pivot, not a comment), `mirror L -> R` (model one side, generate the other), `clearance N` (a
warn-level minimum joint gap).

## 3. Gates

`.fpm` carries **soft** structural guidance (a model past a size threshold *should* decompose into
sub-`model`s / helper `fn`s — the bake **warns**) and **hard** geometry-invariant gates (non-manifold,
self-intersecting, zero-volume, or over-budget meshes **fail** the bake — the modeling analogue of
the P5 quality gate).

## 4. The generated interface (`*.gen.fun`)

The bake emits **committed, formatter-canonical, diffable** funpack — **functions over a params
`data`**, no marker type:

```funpack
data TableParams { width: Fixed = 120.0, depth: Fixed = 80.0, height: Fixed = 70.0 }
fn table_anchors(p: TableParams) -> Anchors { return Anchors.empty().at("seat_top", …).socket("cup", …) }
fn table_mesh(p: TableParams) -> MeshHandle { return engine.assets.mesh("Table") }
fn table_collider(p: TableParams) -> Shape3 { return Shape3::Box{size: …} }
```

Game code touches **only** this seam and references geometry **semantically** — by named anchor, never
raw coordinate (P7). It is committed (the protobuf-`.pb.go` discipline): the strict world typechecks
**before any bake has run**, the gen diff is the **review record**, and a stale committed seam is a
build error.

## 5. Incremental replacement = `@stub` for assets

The generated interface is a **stable typed seam** — the asset-world analogue of a typed hole. The
procedural script is merely the *first* implementation behind it; a hand-authored mesh is the second.
The backing is a one-line manifest swap, game code untouched:

```
backing: procedural("table.fpm")                                 // prototype
// backing: asset("assets/table.glb", anchors: "table.anchors")  // later, hand-made
```

Swapping rebinds the same anchors/sockets/params onto the imported mesh (the importer requires the
named anchors to be placed). The same flow serves 2D drawings (a `Sketch`/sprite behind the seam).

## 6. Self-review

Two layers, neither asking an agent to read triangle soup: the **script** (small, high-prior, named
intermediates, timeless `@doc`) and the **generated seam** carrying a **digest** — a compact
deterministic fingerprint diffed in place of geometry:

```funpack
data Digest { bbox: Aabb, tris: Int, watertight: Bool, components: Int, symmetry: [Plane], anchors: [Anchor] }
```

Tests assert on the digest and anchors, not coordinates (`d.components == 1`, `d.anchors.find("seat_top").z == 74.0`).
**Golden snapshots** are legal because a fixed camera + lights render deterministically — a stored
silhouette/perceptual hash is a stable, reviewable signal feeding the same write→check→fix loop.

## 7. Rigs, parts & animation

A skeleton is three things funpack already has, composed: **parts** (the `.fpm` DSL), a **skeleton**
(engine value), and **pose generators** (pure `fn`s — the functional core applied to bones).

- **`Skeleton`** is engine-provided (`stdlib/engine/anim.fun` — an opaque `extern type`; modeling.md's
  `{bones, parents, rest, slots}` is its conceptual shape), built via `Skeleton.humanoid()` /
  `quadruped()` / `robot()` or an inline `rig` tree whose node grammar is the engine `Skeleton`
  builder surface (engine-defined). The authored form in `skeleton:` is a **named topology**
  (`skeleton: humanoid`); the inline tree is the rarely-needed engine-defined escape.
- **`Pose`** is a sparse `bone -> Transform` map; a **pose generator** is a pure `fn` returning only
  the bones it drives: `Pose.empty().set(Bone::LUpperLeg, rot_x(s))…`. Composition is two engine
  primitives — `Pose.blend(a, b, w)` (per-bone lerp/slerp) and `Pose.layer(base, overlay)` (overlay
  wins per bone). Both compose over the **union** of the two poses' driven bones; a bone one pose
  drives and the other omits blends (or layers) against the other pose's **rest (identity) transform**
  — the same absent-bone default `Pose.get` returns for an undriven bone, in **both directions**.
- **Layering *is* pipeline order** — a pose sub-pipeline lists generators top-to-bottom and *position
  is the layer* (`pose: [pose_idle, pose_walk, pose_carry]`); no magic-number layers. The render stage
  consumes the composed pose via `Draw3::Rigged{ skeleton, parts, pose, at }` ([`20`](20-render.md)).
- **Determinism boundary, per bone:** a **gameplay-observable** bone (a hand carrying a weapon
  hitbox, a foot driving sim-read IK) **must** be fixed-point in a sim stage and replay-safe (needs
  fixed-point `sin`/`slerp`, [`10`](10-numerics.md)); **purely cosmetic** secondary motion (breathing,
  jiggle) may run float in the render stage.

Validation gates (extending P5 to rigs): part origin == declared bone pivot (error); every bound slot
has a mesh (error); mirrored side declared not duplicated (error); joint clearance ≥ `clearance`
(warning); rest-pose manifold/bounds (digest).

## 8. Where it runs

Bake time (`.fpm` eval, CSG/meshing, hashing, `.gen.fun` emission — float here); sim time (only the
generated seam — fixed-point params, `Shape3`, anchor math); render time (`[Draw3]`). Modeling is
**strictly bake-time**: there is **no runtime re-bake** and **no runtime-procedural geometry**
(`fn(state) -> Solid` per tick is **excluded**) — either would pull meshing into the deterministic sim,
and the generated seam is content-hashed once and never re-evaluated in the hot path (§4).

**Level of detail is an invisible engine/bake concern, not an authoring surface.** LOD generation —
decimated rungs feeding distance-selected rendering — is an implementation detail behind the same
content-hashed `MeshHandle` the seam already exposes; a model declares one `emit` and the bake/engine
produce and select LODs transparently. There is no LOD authoring keyword, no per-rung script, and the
sim never observes which rung renders ([`20`](20-render.md)).
