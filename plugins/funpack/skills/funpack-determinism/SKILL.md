---
name: funpack-determinism
description: The funpack determinism contract, fixed-point numerics, the compiler's structural quality gates, @stub/@todo typed holes, and which funpack-mcp tool drives each compile/test/index-query op. Use to understand why a build fails (a gate), how to stay deterministic, how Fixed-point math behaves, how to develop incrementally with typed holes, and which MCP tool to call to compile, test, or query the index. Triggers on "fixed-point", "Fixed/Q32.32", "determinism", "why won't it compile", "quality gate", "effect closure", "exhaustive match", "@stub", "@todo", "--release", "build the project", "run the tests", "compile to check", "query the index".
---

# funpack determinism, gates & holes

funpack's compiler is a **quality gate**: structural problems are **errors, not warnings**, with
fixed budgets and no per-site waiver. This is what makes the write → check → fix loop converge. This
skill covers the rules an author lives under. The ops that drive the loop (compile, test, query the
index) are MCP tools — see the **Driving the loop** section below.

## The determinism contract

Two tiers:
- **Build determinism** — same source → bit-identical artifact.
- **Simulation determinism** — same inputs + seed → bit-identical frame *N* on every machine.

It's load-bearing at runtime (lockstep/peer-to-peer multiplayer, shared recordings) and in the dev
loop (exact replay-repro and testing). The three sources of per-tick variance are all fixed or
threaded, so **input is the only nondeterminism in user code**:
- **Input** arrives as the read-only `Input` resource — a per-tick action snapshot recorded for
  replay. Logic queries semantic actions, never devices (see `funpack-engine-api`).
- **RNG** is the `Rng` resource, **threaded**: a function taking an `Rng` must return the advanced
  one (`-> (value, next_rng)`); it is never silently advanced.
- **Time** is the `Time` resource — logical time on a fixed timestep; there is no wall clock in sim.

A tick is a **fold over the flattened pipeline**, so a replay re-folds bit-identically.

### Do not model a per-thing stage as a simultaneous `map`

The fold is **instance-granular**: a per-thing behavior runs over its instances in stable `Id`
order, and a later instance (higher `Id`) observes earlier same-step instances' blackboard writes
through a direct `View` — the columns evolve *within* the step. So a per-thing stage is an
`Id`-ordered fold over instances, **never** a simultaneous `map` over a pre-tick snapshot. Modeling
it as the latter — handing every instance the same frozen snapshot — diverges from the live
schedule, yet a hand-rolled simultaneous twin passes a green suite, giving false confidence on the
replay-fidelity property this contract exists to protect. Drive every assertion through the real
`Id`-ordered fold (per-instance `name.step(...)` with each return folded forward), not a
snapshot-`map`.

**`Id`-order bias is real:** because the lower `Id` acts first, a **reflection-symmetric matchup is
not neutral** — it is decided by spawn `Id` order. Treat a symmetric setup as `Id`-order-biased, and
fix the expected outcome to whichever instance has the lower `Id`.

### What an author must do / avoid

| Do | Avoid |
|---|---|
| Use `Fixed` (`42.5`) for all sim numbers; lift `Int → Fixed` with `to_fixed(n)` | A bare `f`-literal in sim code — a compile error |
| Keep `Float` strictly behind the render/audio seam | Any `Float` on a type that flows into a blackboard or signal — a compile error (the warranty gate) |
| Read time/rng/input only via the injected resources | Ambient IO/clock/RNG — unrepresentable (no such primitives are in scope) |
| Thread `Rng` (return it advanced) | Assuming `+` reorders — `Fixed` `+` is **not** reorder-invariant under saturation |
| Trust `fold` is left-to-right | Reading a setting from a behavior — settings are structurally kept out of the sim, so replays can't diverge |
| Use the engine `Quat` (auto-renormalizing) | Holding a `Mat4` in sim — it is engine-only, not constructible in sim code |

## Fixed-point numerics

`Fixed` is a signed 64-bit **Q32.32** (32 integer, 32 fractional bits) — the single non-configurable
format. Range ≈ ±2.1×10⁹, precision ≈ 2.3×10⁻¹⁰. Multiply uses a 128-bit intermediate; both
multiply and divide **round toward zero** — one rule, every machine.

**Literals are type-directed:** `42` is `Int`; `42.5` is `Fixed` (the sim default); `42.5f` is
`Float` (render/audio only — a bare `f` in sim is a compile error). A `Fixed` literal not exactly
representable (`0.1`) is rounded to the nearest `Fixed` at compile time, deterministically.

**Arithmetic is total — saturate, never wrap, never trap:**
- Overflow past `Fixed.MAX`/`Fixed.MIN` saturates to the rail (same for `Int`).
- `x / 0` is **defined**: saturates by the sign of `x` (`+x → MAX`, `−x → MIN`, `0/0 → 0`); `x % 0 → 0`.
- When detecting a zero divisor *is* the point, use `checked_div`/`checked_rem` → `Option`, forcing a
  `match`.
- **No implicit `Int → Fixed`** — mixing goes through explicit `to_fixed`.

**Transcendentals are computed in integer arithmetic** — polynomial/lookup/CORDIC over the `Fixed`
representation, no float/libm in the path, so `sin`/`cos`/etc. are bit-identical everywhere.

**Vectors:** `Vec2`/`Vec3` are `Fixed data: Num`; the `Num` kind confers `+ - *` and equality **and
nothing more** — it does **not** confer `/`. `dot`/`cross`/`length`/`normalize`/`distance` are named
functions, never operators. Rotation is a unit `Quat` (`Quat.mul` renormalizes).

**`fold` is strictly left-to-right** — never tree-reduced or parallelized; a right-fold of the same
list can differ at the rails.

**Golden values you can rely on** (from the `numerics` example):
```
0.5 * 0.5 == 0.25          1.0 / 4.0 == 0.25          to_fixed(2) == 2.0
1.0 / 0.0 == Fixed.MAX     -1.0 / 0.0 == Fixed.MIN    0.0 / 0.0 == 0.0    5.0 % 0.0 == 0.0
checked_div(6.0, 2.0) == Option::Some(3.0)            checked_div(1.0, 0.0) == Option::None
trunc(1.5)==1   trunc(-1.5)==-1   floor(-1.5)==-2   round(1.5)==2
clamp(5.0,0.0,3.0)==3.0    lerp(0.0,10.0,0.5)==5.0    length(Vec2{x:3.0,y:4.0})==5.0
sin(0.0)==0.0   cos(0.0)==1.0   a.slerp(b,0.0)==a   a.slerp(b,1.0)==b
fold([1.0,-1.0], Fixed.MAX, +) == Fixed.MAX - 1.0    # left-to-right under saturation
```

## The structural quality gates (errors, not warnings)

A build fails on any of these — they drive the write → check → fix loop. They also run on hot-reload
(last-good code keeps running; you get fix-criteria diagnostics).

| Gate | Triggers when | Fix |
|---|---|---|
| Cyclomatic complexity ≤ 10 | a too-branchy function | decompose |
| Nesting depth ≤ 3 | deep `if`/`match` pyramids | extract / flatten |
| Function size ≤ 40 statements | one giant function | split |
| Parameters ≤ 5 | a wide signature | group into a `data` |
| **Duplication** | re-implementing an existing helper | reuse it (pre-empt with the `warden_find` MCP tool) |
| **Exhaustive `match`** | an `Option`/`Result`/`enum` not fully covered | cover every arm |
| **Effect closure** | emitting a signal nothing consumes (or dropping an IO result) | add the consuming stage downstream |
| Behavior node check | a `step` whose params/return are illegal for its slot | conform the signature (see `funpack-game-model`) |
| **`--release` hole-ban** | any `@stub` / debug directive in a release build | fill the hole before shipping |
| No ambient mutation | mutating outside `mut data` | route through `mut data` |
| `@gtag` registry | an unregistered tag | add it to `tags.fcfg` |
| `@doc` temporal-token ban | "now"/"was"/"todo"/"fix" inside `@doc` | state what it *is* |
| No free comments | a `//` comment in `.fun`/`.fcfg` | use `@doc`/`@todo`/`@stub` |
| No ambient IO | hidden IO | return a command / take a resource |
| `@todo` expiry | a `@todo` past its window | resolve the debt or close the task |
| Malformed project tree | a layout violation | conform to `funpack_configs/` + `src/` |

These budgets are **fixed compiler constants** — there is no `holes = allow` or per-site waiver. The
only sanctioned escape for *incomplete* (never *complex*) code is the typed hole.

## `@stub` / `@todo` — incremental development

```funpack
fn drag() -> Fixed @stub(Fixed)                                  // typecheck-only hole
fn launch_speed(boost: Fixed) -> Fixed @stub(Fixed, boost + 6.0) // hole with a dev fallback that runs
@todo("rebalance drops", T-0042)                                 // dated debt; window mandatory
```

- **`@stub(T)`** — a typed hole in body/expression position. Callers typecheck against `T`, so you
  build **top-down**: write a signature, let consumers compile, fill the body later. Compiles in dev;
  reaching a bare hole in dev **fails closed** (a defined no-value outcome). A **compile error under
  `--release`** — you cannot ship a hole.
- **`@stub(T, fallback)`** — the fallback is a funpack expression that typechecks against `T` in the
  declaration's own parameter scope and **runs in dev**, so the game stays playable while the hole
  stands. Index-tracked and release-banned exactly like the bare form.
- **`@todo("msg", window)`** — the only legal temporal note. Windows: a task ref `T-0042`
  (recommended), an ISO date `2026-09-01`, a relative duration `30d`, or a build count `50builds`.
  **Past the window it's a compile error.**
- Debug directives `@break`/`@log`/`@watch`/`@trace` are dev-only, release-forbidden, and
  task-registered like `@stub`. `@log(self.head)` is the typed replacement for `print` (queryable
  NDJSON).

The workflow: stub the signature → callers compile → add a `fallback` to keep playing → mark deferred
work with `@todo(…, T-NNNN)` → query open holes/debt with the `warden_holes` / `warden_debt` MCP
tools → fill every hole before a release build (the ban is the forcing function).

## Driving the loop — the MCP tools

The compile / test / query ops are **MCP tools** the funpack MCP server (`funpack mcp`) provides, not
CLI invocations you shell out. The intent → tool map is in `../../references/mcp-tools.md`; the verbs you
reach for here:

- **Compile**: `build` (emit the artifact + `.funpack/index.ndjson`), `check` (the same verdict, no
  product written), `export` (the optimized release build, hole-banned), `fmt` (format / check
  formatting). A release build is the hole-ban mode — it rejects any `@stub` or debug directive.
- **Test**: `test` runs every `test "…" { assert … }` block and returns a structured pass/fail
  summary (counts + each failing test's name and detail).
- **Look up the spec / engine API**: search the funpack docs with the `docs_search` MCP tool (then
  `docs_get` on a hit's anchor) rather than relying on memorized prose.

### `warden_*` — query your own project index

Warden is **not a separate binary, process, or clock** — the `warden_*` MCP tools are pure
projections over the `.funpack/index.ndjson` the `build` tool emits, and they **never write source**
(the agent edits source; a recompile re-derives the projection). Use them for **reuse-before-write**
and acceptance checks:

| Tool | Reports |
|---|---|
| `warden_find` | a pre-hoc reuse check — does a helper already exist? (run before writing one) |
| `warden_holes` | every open `@stub` declaration |
| `warden_debt` | every `@todo` with its message + window |
| `warden_probes` | every outstanding debug probe (`@break`/`@log`/…) |
| `warden_graph` | the dependency/call graph projection |
| `warden_tags` | declarations by `@gtag` (e.g. all behaviors tagged `combat`) |
| `warden_pipeline` | the flattened pipeline projection |

A task's completion is **proven by recompile** — a named `test` passes, a `@gtag` query returns the
expected cardinality, a structural gate clears — not self-attested.

> funpack is under active design — a real compile (the `build` / `test` tools) is the tie-breaker.
