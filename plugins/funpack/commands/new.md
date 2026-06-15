---
description: Scaffold a new funpack game project in the enforced tree (funpack_configs/ + src/).
argument-hint: "[game-name] [2d|3d]"
---

Scaffold a new funpack game project named **$1** (default `mygame`) in the current directory. Use the
`funpack-project` skill for the exact tree and `.fcfg` shapes, and `funpack-language` /
`funpack-game-model` for the starter `.fun`.

There is **no `funpack new` CLI verb** — create the project by **writing the files** of the enforced
tree directly:

1. `funpack_configs/project.fcfg` → `project <name> { version = "0.1.0" }`
2. `funpack_configs/entrypoints.fcfg` → `use <name>.{<Pipeline>, bindings}` and an `entrypoint main`
   with `pipeline = <Pipeline>`, `tick = 60hz`, `logical = 160x120` (or a sensible size), and
   `bindings = bindings`.
3. `funpack_configs/builds.fcfg` → `build native { platform = desktop }`
4. `funpack_configs/tags.fcfg` → a `tags { … }` block listing **every** `@gtag` your starter `.fun`
   uses (`game`, `startup`, `render`, `input`, plus any thing tags).
5. `src/<name>.fun` → a minimal but **complete, compiling** entrypoint module: at least one `thing`,
   one `behavior` that moves it, a render behavior, `fn bindings() -> Bindings`, `fn setup() -> [Spawn]`,
   a `pipeline` wiring them (`startup`/`control`/`render`), and one `test` block.
6. Add a `.gitignore` ignoring `gen/` and `.funpack/`.

Honor the non-negotiables: **fixed-point not float** (`Fixed` literals like `8.0`; no `f` in sim),
**`Spawn( Thing{...} )` with parentheses**, **lambdas `fn(x){ … }` never `=>`**, **`@doc`/`@gtag`
instead of comments**, **immutable `self with { … }` updates**, and **every emitted signal consumed**
(effect closure). Model the starter on the funpack-spec `pong` example.

If `$2` is `3d`, set `logical` appropriately and use `engine.render3` (`Draw3`) + a `Draw3::Camera`
in the render stage instead of 2D `Draw`.

After writing, summarize the tree, point out where to add gameplay, and note that the funpack-mcp
`build` then session tools (or the `test` tool) compile and run it — but do **not** invoke any
compile/run tool unless the user has a funpack toolchain installed and asks.
