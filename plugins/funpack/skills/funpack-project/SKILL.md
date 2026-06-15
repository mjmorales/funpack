---
name: funpack-project
description: How to lay out and configure a funpack game project — the enforced directory tree, the `.fcfg` config layer (project/entrypoints/builds/tags), directory-derived modules, the schema/seam/behavior module split, derived capabilities, and packages/dependencies. Use when scaffolding a new project, fixing a project-structure error, wiring an entrypoint, registering a @gtag, or adding a dependency. Triggers on "funpack project", "funpack_configs", ".fcfg", "entrypoints", "tags.fcfg", "builds.fcfg", "project layout/structure", "funpack module", "funpack package/dependency", "scaffold a funpack game".
---

# funpack project structure & config

funpack enforces **one** project layout — there is no alternative arrangement and no override flag.
The compiler errors on a malformed tree exactly as it errors on a malformed function. The split is
at the filename: **`.fun` = pure `source → artifact`; `.fcfg` = config the impure consumers
(runtime, build driver) read.**

## The enforced tree

```
proj/
├── funpack_configs/          authored, committed, formatter-owned
│   ├── project.fcfg          identity: name, version                      (mandatory)
│   ├── entrypoints.fcfg      root pipeline ↔ tick ↔ bindings ↔ net        (mandatory for a game)
│   ├── builds.fcfg           emit targets: platform only                  (mandatory)
│   ├── tags.fcfg             the @gtag registry                           (mandatory)
│   └── deps.fcfg             dependency declarations                      (optional; stdlib-only games have none)
├── src/       *.fun          gameplay (tests inline)                      (mandatory)
├── models/    *.fpm          bake-time rigs/models                        (capability-gated)
├── levels/    *.flvl         flat-text levels                             (capability-gated)
├── ui/        *.fui          UI templates                                 (capability-gated)
├── assets/    *.manifest + sources (*.atlas, *.tiles, raw)               (capability-gated)
├── gen/       *.gen.fun      compiler-owned, gitignored, rebuilt
└── .funpack/                 index + build products — derived, gitignored
```

**Minimal valid game** (the leanest example — single source file, no subsystem dirs):
```
mygame/
├── funpack_configs/
│   ├── project.fcfg
│   ├── entrypoints.fcfg
│   ├── builds.fcfg
│   └── tags.fcfg
└── src/
    └── mygame.fun
```

`gen/` and `.funpack/` are **gitignored and rebuilt on demand**; `funpack_configs/` is authored and
committed. (The funpack-spec example repo commits `gen/`/`.funpack/` for illustration — a real
project gitignores them.)

## The `.fcfg` config layer

`.fcfg` is deliberately smaller than `.fun`: typed `key = value` plus `use mod.{…}` refs, a fixed
set of block kinds, **no expressions, no control flow, no behaviors**. The tells: `=` not `:`, `use`
not `import`. It inherits the no-comment discipline — only `@doc`/`@stub`/`@todo` annotate values.

### project.fcfg — package identity
```
project mygame {
  version = "0.1.0"
}
```
The block label **is** the project name (and becomes a root namespace across a package edge). No
`deps`/`description`/`author` fields.

### entrypoints.fcfg — root pipeline + lifted runtime wiring
```
use mygame.{MyGame, bindings}

entrypoint main {
  pipeline = MyGame          // the root pipeline (UPPER_IDENT)
  tick     = 60hz            // sim rate (e.g. 60hz, 8hz)
  logical  = 160x120         // fixed logical draw space WxH in integer world units (REQUIRED)
  bindings = bindings        // the bindings table
}
```
This lifts the wiring a `pipeline` carries no config for. `logical` is the extent the engine scales
and letterboxes to the window — declared here because it is runtime wiring. Multiple `entrypoint`
blocks are legal as **distinct sims** (a benchmark, a tutorial), not client/server; selection is
inferred (one = default; several = a named CLI pick — there is no `default =` field). An optional
`net = authoritative | p2p | p2p(rollback)` turns on netcode.

### builds.fcfg — presentation platform targets
```
build native {
  platform = desktop          // or wasm
}
```
Platform only — there is **no `realm` field** (server/client is derived from source realm + `net:`).
A declared platform always targets the client/standalone artifact.

### tags.fcfg — the @gtag registry
```
tags {
  game
  startup
  render
  input
  ball
  paddle
  score
}
```
Bare `LOWER_IDENT`s, no label, no `=`. **Every `@gtag("x")` in your `.fun` must list `x` here, or it
is a compile error** — the registry is closed so the namespace never rots into synonyms. Tag sets
are project-specific.

### deps.fcfg — dependencies (optional)
```
use hexgrid  version "0.4"  hash "sha256:1c77…"     // curated registry
use shared   path    "../studio-shared"             // local path
use steering url "https://…/steering-2.0.tar"  hash "sha256:9f3a…"   // url
```
Present only when you declare a non-stdlib dependency (see Packages below).

## Modules — name = path

**A module's name is its file location; nothing declares it — there is no `module` keyword.**
Directory segments dotted, filename the leaf:

| File (under the source root) | Module |
|---|---|
| `src/mygame.fun` | `mygame` |
| `src/combat/melee.fun` | `combat.melee` |
| `src/combat.fun` | `combat` |

- A **directory is a namespace**; an optional sibling `<name>.fun` carries that namespace's own
  declarations (there is **no `mod.fun`** index file). A directory with no sibling file is a pure
  namespace.
- **Imports are absolute** (rooted, no `self`/`super`/`../`).
- A `@doc` that is the **first item in a file** documents the module.
- `engine` is the single reserved root namespace; a user `src/engine/` is a compile error.

### The schema / seam / behavior split

Whenever a generated seam (a `.flvl`/`.fui`/`.fpm` `gen/*.gen.fun`) references **your** thing types,
split `src/` into three modules so the import graph stays acyclic:

- **schema** module (`mygame_world.fun`) — only `thing`/`data`/`enum`/`signal`; imports engine types
  only.
- **generated seam** (`gen/mygame.gen.fun` → module `mygame`) — imports schema modules **only**; a
  seam importing a behavior module is a compile error.
- **behavior** module (`mygame_game.fun`) — imports schema + seam; declares `behavior`s + the
  `pipeline`.

```funpack
// in mygame_game.fun
import mygame_world.{Player, Slime, Chest}       // sibling schema module
import mygame.{mygame_spawns, terrain}           // the generated seam (by bare module name)
```
A small game whose seams name no user types (like Pong) needs no split — one `src/mygame.fun`. A
generated seam's module is its **source filename in the root namespace** (`ui/hud.fui` → module
`hud`); `.gen.fun` is a filename marker, not a namespace segment. Two sources producing the same
module name is a compile error.

## Capabilities — derived, never declared

There is no features config. Each engine battery switches on from its backing source: a non-empty
`ui/` ⇒ UI; a non-empty `models/` ⇒ modeling; a non-empty `assets/` ⇒ assets; an `audio:` stage ⇒
audio; a `net:` entrypoint ⇒ netcode; an `@expose` declaration ⇒ modding. Render/input/state are
always on. A non-empty subsystem dir **expects its committed `gen/<source>.gen.fun` seam**.

**You never branch on a capability.** A feature that is off simply has its stage not composed into
the pipeline — you add a stage, you never write `if feature.audio`.

## Packages & dependencies

funpack is batteries-included — most games never leave `engine.*`. Packages are the deliberate
opposite of npm/cargo: no resolver, no version ranges, no transitive sprawl, no install scripts.

- **Star graph, depth-1 always:** `game → { engine, + exactly the packages you declared }`. A
  package may depend only on `engine`; a package importing another package is a compile error. No
  diamonds, no version solving.
- **Content-hash pins, no ranges.** A registry/url dep pins an exact `hash` (the human `version`
  rides alongside for discovery). funpack never auto-upgrades; the pin is the lockfile.
- **Vendored by default.** Dep source is fetched into `packages/<name>/`, committed, and reviewed in
  PRs — no opaque `node_modules`. Builds are hermetic (no network at build time) and deterministic,
  so package builds are bit-identical. The dependency lifecycle is fetch-then-pin: an initial fetch
  vendors the source under `packages/<name>/`, and an update surfaces the source diff against your
  vendored copy for review **before** the pinned `hash` changes.
- **`@expose` is the one visibility primitive.** Within a project everything is importable (no
  `pub`); across a package edge, only `@expose`d declarations are importable, generating a
  `<name>.api.gen.fun` contract that can't drift. A game with no packages/mods writes zero `@expose`.
- **A package is a project without an entrypoint** — a full tree (`src/`, `funpack_configs/{project,
  tags}.fcfg`, the authoring surface) but **no `entrypoints.fcfg`** (a game runs; a package is
  imported). The package name joins `engine` as a reserved root.

## Scaffold recipe (what `/funpack:new` does)

1. `funpack_configs/project.fcfg` → `project <name> { version = "0.1.0" }`.
2. `funpack_configs/entrypoints.fcfg` → `use <name>.{<Pipeline>, bindings}` + an `entrypoint main`
   with `pipeline`/`tick=60hz`/`logical=160x120`/`bindings=bindings`.
3. `funpack_configs/builds.fcfg` → `build native { platform = desktop }`.
4. `funpack_configs/tags.fcfg` → every `@gtag` your `src/` will use.
5. `src/<name>.fun` → the entrypoint module (the pipeline value + `bindings()` + `setup()` +
   behaviors + tests).
6. Add a subsystem dir (`models/`/`levels/`/`ui/`/`assets/`) only when you author content for it (it
   turns on the capability and expects the committed seam). Split `src/` into schema + game modules
   once a seam must import your types. Add `deps.fcfg` only for a non-stdlib dependency. gitignore
   `gen/` and `.funpack/`.

> The CLI verb to scaffold is **not part of the spec** — there is no documented `funpack new`/`init`.
> Create the tree by writing the files above directly (which is what `/funpack:new` does). The exact
> tree and `.fcfg` shapes are taken from the funpack-spec examples; verify against your toolchain.
