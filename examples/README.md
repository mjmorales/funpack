# Examples

**These lead; the language follows.** We are building top-down: write what a real game
*should* feel like in funpack, then make the compiler match it. Syntax here is provisional
and may contradict `spec/02-language-core.md` (which will be regenerated from these). What matters
is the **semantics** — how a game is structured, scheduled, tested, and kept deterministic.

Each example is a self-contained mini-project laid out in the enforced project tree:
gameplay in `src/*.fun`, the `.fcfg` config layer in `funpack_configs/`
(`project.fcfg`, `entrypoints.fcfg`, `builds.fcfg`, and a `tags.fcfg` registry), any
bake-time authoring sources in their subsystem directories (`models/`, `ui/`, `levels/`,
`assets/`), and generated seams in `gen/*.gen.fun`. No comments anywhere — documentation
is `@doc`, intent is `@gtag`.

Rules every example holds to (the locked axioms):

- **Things, behaviors, pipelines.** A game is a set of `thing`s — entities that own their
  state (a `data` blackboard) — driven by `behavior`s: pure transitions
  `fn(self, inputs) -> (self, signals)` attached to a thing. Cross-thing influence is
  data-only **signals**, delivered synchronously in pipeline order. Rendering is a pure
  `self -> [Draw]`; spawn/despawn are returned as plain commands. Mutation is opt-in and
  declared (`mut data`), never ambient.
- **Determinism.** Simulation state is fixed-point (so it is `Eq`/`Ord`/`Hash`-safe). All
  nondeterminism — player input, RNG seed, clock — is captured by the engine as recorded
  per-tick snapshots and passed in as read-only resources. Input is **device-agnostic**:
  logic queries semantic actions (`Move`, `Steer`), never a key/mouse/pad — devices live in
  one `bindings` function (see [`spec/23-input.md`](../spec/23-input.md)). A tick is a fold over
  the flattened pipeline, so a replay re-folds the same inputs and is bit-identical on
  every machine.
- **State is colocated `data`.** A `thing`'s body is its blackboard — typed, map-backed,
  serializable by construction. A behavior's params are its reads (`self`, resources, inbound
  signals, a read-only `View` of other things); its return is its writes (`self`, emitted
  signals, commands). A behavior writes only its own thing — to affect another, it emits a
  signal. Stage order in the `pipeline` is explicit, top-to-bottom.
- **Testability falls out.** Every behavior is a plain function over plain values — including
  renderers — so its `step` is unit-tested directly, no world or harness required.
- **Stdlib-first.** Everything comes from `engine.*`. No third-party packages.

## Catalog

- [`pong/`](pong/) — two-player Pong. No RNG: fully deterministic, every replay identical.
  Flagship that establishes the core idiom (behaviors on things, signals, pure render). Also the
  reference for the **enforced project layout** (see [`spec/14-project-config.md`](../spec/14-project-config.md)):
  `src/pong.fun` holds the pipeline as a *pure schedule*, and the `funpack_configs/` directory
  carries the `.fcfg` config layer — `entrypoints.fcfg` (the lifted `tick`/`bindings`),
  `builds.fcfg`, and the relocated `tags.fcfg` registry. The capability set is derived from source,
  not declared.
- [`snake/`](snake/) — grid Snake. Exercises **seeded RNG** threaded through a thing,
  **spawn/despawn** as returned commands, a **game-over state machine**, the
  **signal → consumer** path under effect closure, and `map`/`filter` lambdas (`fn(x){…}`,
  not `=>`).
- [`krognid/`](krognid/) — a 3D rigged creature you walk around a field. Exercises the
  **modeling pipeline** (see [`spec/16-modeling.md`](../spec/16-modeling.md)): a `.fpm` rig script
  (`models/krognid.fpm`), the **generated interface** it bakes to (`gen/krognid.gen.fun`), **parts-as-bones**,
  pure **pose generators** blended by speed, fixed-point **3D** state, and `[Draw3]` render
  commands — all deterministic, so the poses are unit-tested by exact equality. Its `audio:`
  stage shows **sustained, diffed audio**: a stride loop keyed `"stride"`, pitched and gained by
  speed, absent (so auto-stopped) at rest.
- [`hud/`](hud/) — a three-screen UI (HUD, pause, settings) over a tiny arcade loop. Exercises
  the **UI pipeline** (see [`spec/21-ui.md`](../spec/21-ui.md)): `.fui` templates (`ui/hud.fui`,
  `ui/pause.fui`, `ui/settings.fui`) baking to generated **view-model + message** seams (`gen/*.gen.fun`),
  driven from `src/hud_demo.fun`, every binding
  kind (reads, events, payload events, two-way `bind:`, a `for`-list, conditionals, an empty
  view-model), and **routing** as plain state via `View.map` into a generated `AppMsg` union —
  with the projections and the message router unit-tested through the seam alone. It also shows
  both **audio regimes**: one-shot `[Sound]` SFX emitted from `on_msg`, and a screen-keyed music
  bed (`audio:` stage) whose clip crossfades on navigation and whose gain follows the volume slider.
- [`arena/`](arena/) — a 2D arena authored as a flat-text level. Exercises the **level pipeline**
  (see [`spec/17-levels.md`](../spec/17-levels.md)): a `levels/arena.flvl` placing things by **name** against
  **bounds anchors**, a `for`-loop of pillars, a **prefab** (`Turret`) with a nested-field
  override, and **references-by-name** (`Door { gate: plate }`) that bake into the generated
  `Arena` seam as typed `Ref`s — `gen/arena.gen.fun` exposes the `Ref` table + spawn list, and
  `startup` loads it in place of a hand-written `setup()`. Thing schemas live in their own module
  (`src/arena_world.fun`) so the generated seam can import them without a cycle; the gameplay
  systems are in `src/arena_game.fun`.
- [`numerics/`](numerics/) — a test-only module (no game loop; run with `funpack test`) that pins the
  **fixed-point numeric contract** (see [`spec/10-numerics.md`](../spec/10-numerics.md)) as golden
  assertions: type-directed literals, **total saturating** arithmetic (`Fixed.MAX + 1.0 == Fixed.MAX`),
  **defined division by zero** (`1.0 / 0.0 == Fixed.MAX`, with `checked_div` for the detecting case),
  exactness on representable values, **integer-kernel trig** exact at the cardinal angles, quaternion
  identity and `slerp`-endpoint laws, and the **left-to-right `fold`** order that makes a saturating
  sum bit-identical. Every assertion is a plain function over plain values — the determinism contract,
  unit-tested.
- [`yard/`](yard/) — push crates onto a delivery pad. Exercises the **physics pipeline** (see
  [`spec/11-physics.md`](../spec/11-physics.md)): bodies declared on things (`Static` walls, a `Dynamic`
  player and crates, a `Static` **sensor** pad), the engine-owned **`physics: solve`** stage that
  integrates and resolves, **intent written as data** (`drive` accumulates an impulse on its *own*
  body via `apply_impulse` — no cross-thing write), and a **`Trigger`** the engine routes to the
  crate that reaches the pad, which despawns itself and emits a `Delivered` the `Scoreboard`
  singleton folds. Collision filtering is a registered `Layer` enum + per-body mask. The native
  fixed-point solver is contracted (like `nav.path`), so only the glue behaviors are unit-tested —
  `drive`, `deliver`, `tally`, and `apply_impulse` — all pure functions over plain values. Uses the
  modern project layout (a pure-schedule pipeline + `funpack_configs/`, like `pong/`).
  It also exercises the **render pipeline** (see [`spec/20-render.md`](../spec/20-render.md)):
  a `singleton Camera` is **sim state** driven by ordinary behaviors — `follow` eases toward the
  solved player position (placed after `physics:`), `shake` kicks on a `Delivered` and flip-decays
  toward rest — and a `view` render behavior emits a **`Draw::Camera`** command the engine turns into
  the letterboxed world↔screen transform. The camera behaviors are deterministic fixed-point, so they
  unit-test by exact equality; the engine's frame-rate interpolation of the draw-list is visual-only
  and untested, like the solver.
  Finally it exercises **persistence** (see [`spec/24-persistence.md`](../spec/24-persistence.md)) across its
  two categories: a `Menu` singleton emits **`Save`/`Restore`** commands (quicksave/quickload to a
  `String` slot) and handles the deferred `Saved`/`Restored` results — the `IoError`/`LoadError` case
  is a forced `match`; and a **settings** flow edits an in-session `Settings` (a reduce-motion toggle),
  emits **`ApplySettings`**, and handles `SettingsApplied`. The teaching point is what is *absent*:
  nothing in the sim reads the reduce-motion preference — the engine, not the sim, dampens the camera
  shake when it is applied, so the deterministic `shake` behavior is untouched. The disk IO is the
  engine's (untested, like the solver); only the pure command-emitting and edit behaviors are tested.
- [`hunt/`](hunt/) — sneak past patrolling enemies. Exercises **AI, timing & sequencing** (see
  [`spec/13-ai.md`](../spec/13-ai.md)): a hunter's AI is a **state machine = a blackboard `enum` + an
  exhaustive `match`** (`Patrol`/`Chase`/`Search`), each state a decomposed pure function; the
  search give-up is a **`Fixed` countdown folded by `Time`** — a "wait" expressed as blackboard state
  on the fixed tick, never an async delay; perception is a **pure predicate over a `View`**. The
  whole AI is a deterministic fold, so every transition is a one-line exact-equality test (patrol→chase
  on sight, chase→search on loss with a full timer, search→patrol on timeout, re-acquire→chase) and a
  replay re-derives identical decisions with no AI-specific network messages. Movement is direct
  `step_to` (the FSM is the point; pathing is covered in [`spec/12-navigation.md`](../spec/12-navigation.md)). The
  `Timeline` sequencing battery is shown inline in the doc.
- [`assets/`](assets/) — the asset-pipeline example. Exercises the **asset bake**: two authoring
  sources (`assets/coin.fpm`, `assets/pickups.atlas`) and the three things the bake produces — the committed
  `assets/assets.manifest` (name → content-hash → output, with a raw-image dependency), the generated
  `gen/assets.gen.fun` of **typed handle constants**, and an `assets/assets.report.txt` showing dead-asset
  elimination. `src/pickups.fun` draws and sounds entirely through the typed constants
  (`assets.pickups`, `assets.coin_sfx`), with a test proving the constant equals the
  manifest-checked `sound("coin_sfx")` string form.
- [`drift/`](drift/) — the **typed-holes governance** example (see
  [`spec/05-directives.md`](../spec/05-directives.md) §2). A hole-first module built top-down:
  `drag` is a bare `@stub(Fixed)` — its caller `damped` typechecks against the declared type by
  construction, and a dev execution that reaches it fails closed — and `launch_speed` is a
  `@stub(Fixed, boost + 6.0)` whose **fallback approximation** typechecks against the hole's type
  in the declaration's own parameter scope and evaluates in dev, so the loop stays playable (its
  inline test observes the fallback's value). Both holes are index-tracked (`stub: true` in the
  Index Contract), the dev build and tests run green, and `funpack build --release` refuses the
  tree (P8: you cannot ship a hole).
- [`dungeon/`](dungeon/) — a one-room dungeon crawl. Exercises **tilesets & tilemaps** (see
  [`spec/18-tilemaps.md`](../spec/18-tilemaps.md)): the corpus's first real `.tiles` file
  (`assets/dungeon.tiles` — atlas cells, sim-side `solid` collision, `tags`), an **ASCII
  tilemap layer** in `levels/dungeon.flvl` (a legend of tiles + spawn markers and a grid the
  agent reads as a picture, with the relational `place … at cell(col, row)` split), behaviors
  querying the baked layer through the `TilemapHandle` (`tile_at`/`solid_at`/`cell_of`/
  `center_of` — movement gated by collision, no per-tile things), and **destructible terrain**
  as data: `dig` returns a `SetTile` command, applied deterministically at tick end. The grid
  helpers are the canonical `neighbors`/`in_bounds`; every decision is a pure fn unit-tested
  by exact equality.
- [`warren/`](warren/) — a ferret hunts a rabbit through a maze. Exercises **navigation** (see
  [`spec/12-navigation.md`](../spec/12-navigation.md)): the nav graph **derives at bake** from
  the maze tilemap's solids (no `addNode` — the level is the one truth), behaviors take the
  injected **`Nav`** resource and use the whole five-call surface — pure `path()` with
  `Result[Path, NavError]` and the **hold-the-last-good-route** `Err` arm, `advance` as a
  tuple-returning fold, `los` to dash when the straight segment is clear, `reachable` as the
  cheap pre-check, `nearest` to snap an off-nav goal — and **re-path only on their own logic**
  (a `Fixed` countdown and route drift; no engine replan cadence exists, by doctrine). The
  glue is tested with the `Nav.of(route)` fixture by exact equality, including a sealed burrow
  that makes `Unreachable` a real, reachable arm.
