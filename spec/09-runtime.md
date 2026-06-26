# 09 — Runtime & execution

The runtime is the precompiled native binary that **executes** the artifact `funpack` emits. It is
the **one impure consumer of the pure compiler's output**: it consumes the artifact to run the game.
The governance surface (`funpack warden`, [`29`](29-architecture-governance.md)) is a *pure
projection* of the index inside the compiler, not a second impure binary. `funpack` stays a pure
`source → artifact` function. The runtime owns
**every play-time impurity** — the frame clock, device input, rendering, audio, the asset loader,
and the dev file-watch that drives hot-reload — and never writes source.

The agent-facing surface that observes and controls the runtime (inspection, stepping, time-travel,
screenshots) is [`28`](28-introspection.md).

---

## 1. funpack is interpreted — and that is load-bearing

The runtime **interprets** the artifact; the interpreter is the **canonical operational semantics**.
Two specified mechanisms require it:

- **Verify, don't trust** ([`27`](27-modding.md)) — the runtime re-runs the confinement analysis on
  every mod at load, which is only possible because mods ship as **interpreted funpack, not native
  artifacts**.
- **Logical-step metering** ([`27`](27-modding.md)) — a mod's per-tick budget is metered in
  **interpreter steps and allocations, never wall-clock**, so every machine faults at the same
  logical point and lockstep cannot desync.

Everything else is an accelerator that must *agree* with the interpreter, never replace it. The
on-disk artifact form (checked AST vs. bytecode) is an implementation detail, not a contract; only
the interpreter's observable behavior is.

## 2. Three execution strategies

Orthogonal to the stdlib Tier-1/Tier-2 split ([`26`](26-stdlib.md)): that axis is *native vs.
self-hosted*; this axis is *how a body runs*.

| Strategy | Speed | Hot-reload | Determinism | Metered | Used for |
|---|---|---|---|---|---|
| **Interpreted** | baseline | yes | warranted | yes (steps) | everything by default; the **only** mode for mods |
| **JIT** | fast | yes (re-JIT) | warranted iff bit-identical to interpreter | — | hot **trusted** (non-mod) code |
| **Native `extern`** | fastest | **no** (sealed) | non-warranted unless the native upholds its contract | no | the irreducible native core |

**Mods never JIT** (they must be verified and metered, both needing the interpreter). The JIT is the
*pressure valve that keeps `extern` rare*: it keeps hot-but-evolving trusted code fast **and**
reloadable **and** warranted, so `extern` stays reserved for genuine native-primitive gaps. The JIT
backend is a compiler implementation detail and is **not specified**; the contract is that its
output is warranted **bit-identical to the interpreter** (§5).

Hot trusted (non-mod) code tiers up to JIT at a **fixed compiler constant** — not configurable
(AX6, no knobs).

## 3. Hot-reload

A **dev-time**, tick-boundary, gated atomic swap. It is incompatible with lockstep replay by
construction (the code changed mid-sim), so it never ships in a session.

```
source change → funpack recompiles changed modules (pure)
              → runtime re-runs the gates on the new artifact:
                  typecheck · AX6 budgets · behavior contracts · effect closure · (confinement) · schema-diff
              → all pass ⇒ atomic swap at the next tick boundary
              → any fail ⇒ keep last-good code running + emit fix-criteria diagnostics
```

A failed reload is **non-destructive** (the self-healing loop extended to the live process). The
tick boundary is a clean seam for free: the per-tick bump arena is empty and only the COW
blackboards are live, so the swap is "replace the code/pipeline tables between tick N and N+1" — no
locks, no in-flight gameplay state. A persist outcome signal owed in [`24`](24-persistence.md)'s
one-tick deferral window is **not** such in-flight state — it is a **committed fact** owed
exactly-once delivery, so a reload landing in that window delivers it **unchanged under the new
artifact** (engine-signal shapes are schema-stable across reload; [`24`](24-persistence.md) §1). Granularity is AST-diff driven: a changed **behavior** swaps one
dispatch-table entry; a changed **pipeline** recomputes the flattened order + signal routing and
re-runs effect closure; a changed **`data` schema** migrates the live blackboards (§4).

**Behavior identity is by name, and behaviors carry no state.** A `behavior` is a **pure
transition function** ([`06`](06-things-behaviors.md) §3) — all sim state lives on the `thing` it
runs on, never on the behavior — so a behavior has nothing to migrate across a reload. Dispatch
resolves behaviors **by name** each tick: a **renamed** behavior is therefore **remove + add** —
the old name stops dispatching and the new name begins, with **zero state loss**, because the
state the renamed behavior reads and writes is the unchanged `thing` blackboard, not the behavior.
There is **no behavior-level `@migrate` channel**: `@migrate` exists for state with continuity to
preserve (§4), and a behavior has none. (Emitting an info-level diagnostic naming the
removed/added behaviors is a permitted dev-ergonomics affordance, never a requirement.)

## 4. State migration (shared with saves)

Hot-reload uses the **same schema-migration rules as save/load** ([`24`](24-persistence.md)) — one
mechanism shared with persistence. Because `data` is name-keyed (map-backed) with `Option` for
absence and serializable by construction ([`03`](03-data-model.md)), the schema-diff classifies
every change: field **reorder is a non-event**, **additive fields take defaults**, **removed fields
are dropped** — all automatic; **rename or retype is the only structural break**, requiring
`@migrate` or rejected with a diagnostic.

| Schema change | Verdict |
|---|---|
| add optional / defaulted field | **safe, automatic** (absent key → `None`/default) |
| remove field | **safe, automatic** |
| reorder fields | **no-op** (map-backed) |
| rename field | **breaking** — rejected with a diagnostic |
| change field type | **breaking** — rejected |
| add non-optional field, no default | **breaking** — "make it `Option` or give a default" |

This is the **same operation as save-file migration** ([`24`](24-persistence.md), [`08`](08-state.md)).
The dedicated breaking-change channel is `@migrate`.

**Thing-set evolution migrates by the same name-keyed doctrine, one level up.** The
schema-diff above classifies field-level deltas on a thing whose **name is unchanged**; the
**thing-set** — which `thing`/`singleton` declarations exist — can itself change across a reload,
and migrates by the same name-keyed rules lifted from the field to the declaration:

| Thing-set change | Verdict |
|---|---|
| add an ordinary `thing` | **safe, automatic** — its table starts **empty** (the additive-default analog: an absent name → no rows) |
| remove a `thing`/`singleton` | **safe, automatic** — its rows **discard** (generalizing the mod-scope *load-with-discard* of [`27`](27-modding.md) to migration scope; cross-thing access is signal-only, so no surviving thing references the dropped blackboard) |
| add a `singleton`, or flip the singleton flag on an existing name | **breaking** — **rejected with a diagnostic** |

A **singleton-ness change is a structural redefinition, not a migration**, and fails closed: a
singleton's invariant is **exactly one row** ([`06`](06-things-behaviors.md) §2), an **added**
singleton would have to start with that row and there is **no mid-session reseed** to supply it
(its single row is spawned by the engine **before tick 0**), and flipping the flag on an existing
name reinterprets every existing row against a changed row-count constraint. Both are rejected
rather than guessed, exactly as a field rename/retype is (the additive-default doctrine extends to
the thing-set, but the singleton-reseed ambiguity stays fail-closed). A renamed `thing` is **not**
a thing-set migration — like a renamed field it is the breaking case, requiring `@migrate` or
rejected; absent `@migrate` it reads as a remove + add, discarding the old rows and starting the
new name empty.

**Dynamic tile state carries the same way.** Tile state is committed world state
([`18`](18-tilemaps.md) §4), so a reload swap never silently re-seeds it: the runtime diffs the
live committed layers against the **prior** artifact's bake — exactly the cells `SetTile` has
rewritten — and re-applies that delta onto the **new** bake, keyed by cell coordinate and tile
**name** (the same name-keyed philosophy as the schema-diff; palette indices may reshuffle
freely). A delta cell that falls outside the new grid, or whose tile name the new layer's palette
no longer carries, is dropped — the new bake wins; a layer absent from the new artifact drops its
delta with it. A reload that does not touch the level therefore preserves every live terrain edit,
and render, collision, and the nav graph update from the carried state as from any other tile
write ([`18`](18-tilemaps.md) §4, [`12`](12-navigation.md)).

## 5. Determinism across reload, JIT, custom runtimes

- **The interpreter is the determinism ground truth** — its semantics are identical on every
  machine, so bit-identity over fixed-point falls out with no host-codegen variance to audit (why
  lockstep is cheaper than flite's same-IEEE guarantee).
- **The JIT carries a bit-identity obligation** — a continuous differential-determinism (fuzz)
  invariant; trivial for fixed-point integer ops. Trusted code is unmetered, so only result-identity
  matters.
- **Custom runtimes are detectable, not silent** — a user `extern` makes a build non-warranted and
  changes the runtime binary; its **content-hash is pinned in the session header** and lockstep peers
  agree it at handshake and refuse a mismatch, exactly as they refuse a mod-manifest mismatch.

## 6. The root RNG seed

A run that **draws randomness anywhere** — its `setup` or any per-tick behavior binds the engine
`Rng` ([`26`](26-stdlib.md)) — is a `uses_rng` run, and the engine supplies it a **root seed**. The
seed is a run-time determinism input the artifact does not carry, recorded **symmetric to `Input`**
([`23`](23-input.md)): `Input` is the per-tick recorded source of nondeterminism, the root seed is the
**run-scoped** one. It is recorded **once** in the replay-log header (the `Rng` then evolves
deterministically by folding), so a re-fold re-feeds the exact seed and reproduces every RNG-driven
spawn/despawn/grow bit-identically ([`28`](28-introspection.md)).

- **Seed-source precedence**, highest first: an explicit `--seed N` flag on `funpack run`/`live`/`attach`
  (or the equivalent seed argument on a `28`-introspection session); the `entrypoints.fcfg` `seed = N`
  config seed ([`14`](14-project-config.md) §3); a **fixed engine default constant**. The default is
  fixed, never a wall-clock draw, so a bare `funpack run` of a `uses_rng` game is **reproducible out of
  the box** — a project opts into per-launch variation explicitly by passing `--seed`, and that value is
  recorded like any other. The **same precedence governs an introspection session opened over a live
  (not recorded) artifact** ([`28`](28-introspection.md)), so the debug surface of a `uses_rng` game
  folds the real seeded run rather than a seedless empty one.
- **The gate is `uses_rng`, not "does setup draw"**: a game whose `setup` is seedless (`setup() ->
  [Spawn]`) but whose per-tick behaviors draw is still a seeded run. The engine delivers the root
  `Rng` to behaviors through the existing slot contract ([`06`](06-things-behaviors.md)) — advanced
  past `setup` when `setup` itself draws, the bare seed otherwise — so its behaviors fold and it
  renders. A game that draws **no** RNG (Input is its sole nondeterminism) carries **no** seed: the
  header records its absence (`has_seed = false`), distinct from a seed that happens to be `0`.

## 7. Implementation

The native runtime is implemented in **Odin**, chosen for its vendored output/IO/asset/transport
batteries (Vulkan/Metal/wgpu/SDL, miniaudio, stb + cgltf, ENet). The deterministic sim core
(physics + math feeding `thing` state) is **custom fixed-point regardless of language**; vendored
float physics is visual-only, never sim. This is a contract-level fact: the spec describes the
native *contract* (`extern`, the sealed runtime, custom-runtime mode), not the implementation.
