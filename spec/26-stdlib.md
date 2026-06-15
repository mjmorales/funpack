# 26 — The stdlib surface

The stdlib **is** the engine ([`01`](01-axioms.md) P3); user code is boring glue over it, and the
vast majority of games never leave it. These are **interface files** — they declare the contract, not
the implementation ("assume it works"; the bodies live in the runtime). The whole surface is shaped
by one question: *can an agent predict the right call, and reason about its effect, without running
it?*

## 1. Design-for-reasoning rules

1. **One name, one meaning, one module** — any free identifier resolves to exactly one import.
2. **Strongest-prior names, always** — `map`/`filter`/`fold`/`len`/`abs`/`clamp`/`dot`, never a cute
   synonym.
3. **Total by construction** — no stdlib function panics; partiality is in the *return type*
   (`Option`/`Result`).
4. **The type is the effect** — no annotation to track (§ below).
5. **Resources in, commands out** — the outside world arrives as a read-only resource parameter,
   effects leave as returned data; no ambient IO is in scope.
6. **Fluent builders for config, immutable data for state** — an `empty()` constructor plus
   `self`-first adders (`Bindings.empty().axis(…)`, `Pose.empty().set(…)`).
7. **Generics only on stdlib containers** — `Option`/`Result`/`[T]`/`Map`/`View`/`Ref`; users author
   none.
8. **Closed capability set via `Name: Kind` ascription** — the kind (`Axis`/`Button`/`CollisionLayer`/`Num`)
   follows the type name after a colon; value batteries are unconditional, the few opt-in capabilities
   are ascribed this way; no `derives`, no typeclass search.
9. **Self-indexed** — every declaration carries `@doc` and, where it aids discovery, `@gtag`.
10. **Every resource has a deterministic constructor** — so every behavior is unit-testable as a plain
    function (`Time.at`, `Input.empty`, `Rng.seed`, `View.of`, `Nav.of`, `Physics.of`).

Reading `extern fn value(self: Input, player: PlayerId, axis: Axis) -> Fixed`, an agent knows with no
body: takes a resource ⇒ observes the world; returns `Fixed` ⇒ deterministic and sim-safe; total ⇒ no
failure case; `self`-first ⇒ called `input.value(p, a)`.

## 2. The `extern` boundary — Tier-1 natives

`extern fn name(params) -> T` links a funpack declaration to its native runtime symbol (no body);
`extern type T` is an opaque handle — its representation and ABI are compiler/runtime-internal, never
observable in `.fun` and outside doctrine; it carries no funpack-visible fields, used **sparingly** —
transparent serializable `data` is preferred so values stay replayable/inspectable; most "engine
types" like `Rng`/`MeshHandle`/`Input` are plain `data`.

- **Gated off by default** — in an ordinary project `extern` is a **compile error**; only the stdlib,
  compiled in the privileged engine context, may declare it.
- **Opt-in: custom-runtime mode** — authoring your own `extern` requires rebuilding the native runtime
  with the matching symbols; conspicuous, per-project, a build capability (not a tuning knob). The
  friction *is* the feature.
- **Trust boundary** — the type still states the effect surface, so signature-level reasoning holds;
  the stdlib's externs are **audited** to honor their type's contract (`extern fn sin(x: Fixed) ->
  Fixed` is contracted bit-identical). A user `extern` **voids the determinism warranty** unless it
  upholds the same contract, and the compiler flags any pipeline transitively reaching one
  (non-warranted diagnostic, never silent).
- **Tier-1 vs Tier-2 is invisible at the call site** — only the irreducible core is `extern` (Tier-1,
  native); the rest is Tier-2 (ordinary funpack over that core). The exact partition is not enumerated
  doctrine: the invariant is that the native surface is as small as possible and the tier never shows
  through the call — a caller reasons from the signature alone, identically across tiers.

## 3. Module map

One responsibility per module; the owning module is the only exporter of each type. **One
documented exception**: `engine.math` re-exports the prelude's `Fixed` — the same type, one
meaning — so a numerics import line reads complete (`import engine.math.{Fixed, Vec2, …}`, the
golden idiom across the worked examples). A re-export is legal only when it names the owner's
type unchanged; two modules exporting **different** meanings under one name remain a compile
error, and a new re-export is a deliberate spec amendment here, never a quiet table row.

| Module | Owns |
|---|---|
| `engine.prelude` | `Bool Int Fixed Float String`, `Option Result Ordering` (always in scope) |
| `engine.math` | `Vec2 Vec3 Quat Mat4 Aabb`; trig, `sqrt clamp lerp dot cross normalize`; `pi tau`; re-exports `Fixed` |
| `engine.list` / `engine.map` | `[T]` combinators (incl. `within`, `nearest_first`) / `Map[K,V]` |
| `engine.core` | `Time TickRate` |
| `engine.world` | `Id Ref Owned Spawn Despawn View[T]` ([`08`](08-state.md)) |
| `engine.input` | `Input Bindings Key Stick PlayerId PadButton MouseButton`; ascription-only kinds `Axis Button` (never imported) ([`23`](23-input.md)) |
| `engine.geom` | `Sketch Path PathOp` (the 2D↔3D bridge) |
| `engine.render` / `engine.render3` | `Draw` (incl. `Sprite`, `Camera`) / `Draw3 Material` ([`20`](20-render.md)) |
| `engine.anim` | `Bone Slot Side Skeleton Pose Transform PartSet` ([`16`](16-modeling.md)) |
| `engine.model` | `Length Solid Anchors Shape3` (the `.gen.fun` surface) |
| `engine.assets` | `MeshHandle TextureHandle SoundHandle AtlasHandle`; `mesh sound atlas cell frame` |
| `engine.rand` | `Rng`; `seed next pick range chance split` |
| `engine.save` | `Save Restore DeleteSave` + result signals + `Saves` resource + `Settings` ([`24`](24-persistence.md)) |
| `engine.seq` | `Timeline[A] Step[A]`; `advance` ([`13`](13-ai.md)) |
| `engine.grid` | `Cell`, `grid_cells neighbors in_bounds` |
| `engine.physics` / `engine.physics3` | `Body Shape2 RayHit Contact Trigger`; `solve raycast overlap` ([`11`](11-physics.md)) |
| `engine.string` | text ops |
| `engine.ui` | `View[Msg]`, the closed widget set, `UiAction Theme` ([`21`](21-ui.md)) |
| `engine.audio` | `Sound Audio Bus` ([`22`](22-audio.md)) |
| `engine.level` | `LevelHandle Load Unload Volume` ([`17`](17-levels.md)) |
| `engine.tilemap` | `TilesetHandle TilemapHandle SetTile`; `tile_at solid_at cell_of` ([`18`](18-tilemaps.md)) |

**Call conventions** (each unambiguous to read): **method** (first param `self`, called on the
receiver — `input.value(p, a)`); **associated constructor/factory** (no `self`, qualified by its
return type — `Pose.empty()`, `Time.at(0.5)`); **free function** (no `self`, imported and called bare
— `sin(x)`, `lerp(a, b, t)`).

## 4. Module surfaces

The canonical surface each module exports:

- **`engine.math`** — the [`10`](10-numerics.md) surface (`checked_div`, `Fixed.MAX/MIN/EPSILON`,
  `trunc`/`fract`/`sign`/`rsqrt`/`pow`/`exp`/`log`/`remap`/`inv_lerp`/`wrap_angle`/`radians`/`degrees`/
  `length_sq`/`distance`/`reflect`/`%`; `Quat.axis_angle`/`Quat.mul`).
- **`engine.input`** — the [`23`](23-input.md) surface (`pressed`(edge)/`released`/`held`/`value`/
  `axis`; the 2D source helpers; `Input.empty()`/`with_pressed`/`with_held`/`with_value`/`with_axis`).
- **`engine.render`** — the 2D `Draw::Camera` variant ([`20`](20-render.md)).
