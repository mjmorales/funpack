# 14 — Project structure & config (`.fcfg`)

funpack enforces a **single** project layout — there is no alternative arrangement and no override
(an "override the layout" flag is itself the config drift [`01`](01-axioms.md) P3 bans). The compiler
errors on a malformed tree as it errors on a malformed function. The layout splits along the
determinism boundary at the **filename**: `.fun` is the pure `source → artifact` input; **`.fcfg`**
is configuration the *impure* consumers (runtime, build driver) read.

---

## 1. The tree

```
proj/
├── funpack_configs/          authored, committed, formatter-owned
│   ├── project.fcfg          identity: name, version
│   ├── entrypoints.fcfg      root pipeline ↔ tick ↔ bindings ↔ net, per target
│   ├── builds.fcfg           emit targets: platform (presentation) only
│   └── tags.fcfg             the @gtag registry
├── src/       *.fun          gameplay (tests inline)
├── models/    *.fpm          bake-time rigs/models               ([`16`](16-modeling.md))
├── levels/    *.flvl         flat-text levels                    ([`17`](17-levels.md))
├── ui/        *.fui          UI templates                        ([`21`](21-ui.md))
├── assets/    *.manifest + sources (*.atlas, *.tiles, raw)       ([`18`](18-tilemaps.md), [`19`](19-assets.md))
├── gen/       *.gen.fun      compiler-owned, gitignored, rebuilt
└── .funpack/                 index + build products — derived, gitignored
```

Module names derive from file paths — the directory is the namespace, **no `module` declaration**
([`15`](15-modules.md)). The **capability set is derived, never declared** (§4): a subsystem
directory present-but-empty ⇒ the feature is off; present-and-non-empty ⇒ the feature is on and the
matching `gen/` seam is expected. `gen/` and `.funpack/` are derived, gitignored, rebuilt on demand;
`funpack_configs/` is authored and committed.

## 2. Why config is `.fcfg`, not `.fun`

Configuration holds wiring for impure consumers (`tick`/`bindings`/`net` → runtime;
`platform` → build driver; project facts → the index) — none of it is `source → artifact`. `.fcfg`
keeps the pure/impure split visible in the filesystem. Its grammar is deliberately **smaller** than
`.fun`'s: typed `key = value` plus `use mod.{…}` references, a fixed set of declaration kinds, and
**no expressions, no control flow, no behaviors**. The lexical tells — `=` not `:`, `use` not
`import` — signal "config, not logic" on sight. It inherits the **no-free-comment** discipline
(P6): `@doc` describes a declaration, `@stub`/`@todo` anchor an undecided or debt-carrying value.

## 3. `.fcfg` is import-terminal and emits no seam

`.fcfg` names source; source never names it. It feeds the **authored** fields of the index
contract's `project` record (`entrypoints`, `builds`, `tag_registry`); the derived fields
(`capabilities`, `pipeline_flattened`, `gate_results`) project from source. It is the **one** authoring
format that bakes **no** `.gen.fun` seam — and three properties depend on that:

- the pipeline stays a **pure schedule** (wiring isn't read back into source);
- behaviors stay **harness-free testable** (no behavior reads a feature handle);
- **one-way data flow** (no `source → config` arrow, no cycle).

The asymmetry with assets is the line: **assets get a typed seam because gameplay consumes them
every tick**; **config is deployment shape consumed by tools**, never per-tick content.

## 4. The files

- **`project.fcfg`** — minimal project identity; the block label **is** the project name and it
  carries `version`: `project pong { version = "0.1.0" }`. It is the **package identity at the
  package boundary** ([`15`](15-modules.md)) — that is what the `name` earns its keep as.
- **`entrypoints.fcfg`** — each root pipeline with its lifted wiring. Multiple entrypoints are legal
  as **distinct sims** (a benchmark, a tutorial), **not** client/server (one entrypoint projected by
  realm). Selection is inferred (§6).
  ```
  use pong.{Pong, bindings}
  entrypoint main { pipeline = Pong, tick = 60hz, logical = 160x120, bindings = bindings }
  ```
  `logical = WxH` is the **required** fixed logical draw space ([`20`](20-render.md) §3) in positive
  integer world units — the extent the engine scales and letterboxes to the window. It is declared
  here, beside `tick`, because it is runtime wiring the pipeline carries no configuration for
  ([`07`](07-pipelines.md) §1); the sim's own constants (Pong's `BOARD`) remain ordinary game code,
  and the engine letterboxes to the *declared* extent.
  `seed = N` is an **optional** baked root RNG seed ([`09`](09-runtime.md) §6) — the integer a
  `uses_rng` run starts from when no `--seed` override is passed. It is the middle tier of the
  seed-source precedence (`--seed` flag › this config seed › the fixed engine default); a game that
  bakes none is reproducible from the engine default. Omit it for the common case; bake it only to pin
  a specific layout into the build.
- **`builds.fcfg`** — the **presentation** platform targets (`desktop`, `wasm`) and nothing else.
  **No `realm` field**: the server/client split is derived from source realm + switched on by `net:`
  in the entrypoint ([`25`](25-netcode.md)).
- **`tags.fcfg`** — the `@gtag` registry ([`05`](05-directives.md)); an unregistered tag is a
  compile error.

**The capability set is derived, never declared** — there is no features config file. Each engine
battery switches on from its backing source:

- a non-empty `ui/` ⇒ **UI**;
- a non-empty `models/` ⇒ **modeling**;
- a `net:` in an entrypoint ⇒ **netcode** ([`25`](25-netcode.md));
- an `@expose` declaration ⇒ **modding** ([`27`](27-modding.md));
- an `audio:` stage ⇒ **audio** ([`22`](22-audio.md)).

Core subsystems (render/input/state) are always on. A declared import without its backing directory
is a normal resolution error, so a stray capability cannot be wired without its source present.

## 5. Capability variation is structural, never a config read

A behavior that branches on an active feature is the anti-pattern. Variation is by **composition**:
a feature that is off has its stage simply **not composed** into the entrypoint's pipeline (you add
a stage; you never write `if feature.audio`); server/client variation is realm projection making the
wrong-realm code **unnameable** ([`25`](25-netcode.md)) — a closure, not a conditional.

## 6. Platforms, realms, and the CLI

Platforms **factor** with realm rather than multiplying: a declared platform always targets the
**client/standalone** artifact; the **server** is never a declared platform — under `net:
authoritative` it is emitted **once, headless, by construction** (it has no `Draw` consumer). The
emitted set is `|platforms|` clients + (`authoritative` ? 1 server : 0). OS/arch triples and
server-only builds are downstream build-driver / CLI concerns, not config.

The invocation **selects among committed declarations** and supplies **runtime-only deploy params**;
it never **synthesizes** a value that enters the artifact (`funpack run [name]`, `funpack build
--target wasm`, `funpack serve --port 7777`). Entrypoint selection is **inferred** — one entrypoint
is the implicit default; multiple force a named pick (no `default =` field, no first-wins).
`funpack check` adjudicates this same tree — the full checked pipeline with **no product written**
([`29`](29-architecture-governance.md) §3) — so a malformed tree refuses under `check` exactly as it
refuses under `build`.

## 7. Project facts, not knobs

`funpack_configs` holds **project facts** (which pipeline is the root, the tick rate, which platforms
ship) — irreducibly per-game, with no universal default — categorically distinct from P5's banned
**knobs** (gate budgets, per-site waivers, `holes = allow`). The active battery set is **not** a
project fact: it is derived from source (§4). `dev↔release` stays the compiler-owned `--release`
**mode**, never a config field.

## 8. File minimalism

`name` is retained in `project.fcfg` as the package identity ([`15`](15-modules.md)).
