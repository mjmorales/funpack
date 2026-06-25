# funpack plugin

Author deterministic, agent-first games in **funpack**. This plugin gives Claude the language
priors — syntax, the engine surface, the runtime model, project layout, the bake pipelines, and the
determinism contract — plus the `/funpack:new` scaffolding command, the **funpack MCP server**
(`funpack mcp`) for the ops loop, and author/reviewer agents.

## The 60-second model

A funpack game is **things, behaviors, and pipelines**:

- A **`thing`** is an entity that owns its state (a typed `data` blackboard).
- A **`behavior on Thing`** is a pure transition `fn step(self, …reads) -> …writes`. Its
  **parameters are its reads** (`self`, resources like `Input`/`Time`, inbound `[Signal]` lists, a
  read-only `View[Other]`); its **return is its writes** (a new `self`, emitted `[Signal]`s, and/or
  command lists like `[Spawn]`/`[Draw]`). A behavior writes **only its own thing** — to affect
  another, it emits a **`signal`** (the sole cross-thing channel).
- A **`pipeline`** is an explicit ordered schedule of stages. A tick is a deterministic **fold**
  over the flattened pipeline; a replay re-folds the same recorded inputs to a bit-identical frame.

Effects are **data** (`[Draw]`, `[Spawn]`, `[Goal]`) returned from behaviors, never performed as
IO — so every behavior, including renderers, is a plain function you unit-test by calling
`name.step(...)`.

```funpack
@doc("Advances the ball along its velocity.")
@gtag("ball")
behavior ball_move on Ball {
  fn step(self: Ball, time: Time) -> Ball {
    return self with { pos: self.pos + self.vel * time.dt }
  }
}
```

## Non-negotiables (the things that trip up a newcomer)

- **Fixed-point, never float.** Simulation numbers are `Fixed` (`42.5`). `42.5f` is `Float`, legal
  only in render/audio; a bare `f`-literal in sim code is a compile error. No implicit `Int→Fixed`
  — lift with `to_fixed(n)`.
- **`Spawn(x)` uses parentheses, not braces.** Command-wrap is call syntax: `Spawn( Ball{...} )`,
  `Despawn()`. (This is what keeps the grammar LL(1).)
- **Lambdas are `fn(x){ return … }`, never `=>`.** `=>` is the `match`-arm separator only.
- **No comments.** `@doc("…")` documents, `@gtag("…")` tags intent (must be registered in
  `tags.fcfg`), `@todo("…", window)` carries dated debt, `@stub(T[, fallback])` is a typed hole.
- **State updates are immutable:** `self with { field: newValue }`.

See the bundled skills for depth; they auto-trigger by topic. The `funpack-author` agent writes
code to these rules; `funpack-reviewer` audits against them.

## The ops loop — MCP tools, not CLI

The plugin wires the **funpack MCP server** — the `funpack mcp` verb of the funpack binary, declared
in `.mcp.json` and run off `PATH` (funpack ships on `PATH` via Homebrew). The ops that drive the loop
are its tools, not CLI invocations: `build` / `check` / `export` / `fmt`, `test`, the `warden_*` index
projections, `docs_search` / `docs_get` for the spec and engine API, and the session-scoped
`session_*` / `time_*` / `inspect_*` / `control_*` / self-heal tools that drive a live `funpack
attach`. The intent → tool map is in `references/mcp-tools.md`. `/funpack:new` (scaffolding the
enforced project tree) is the one remaining slash command — it has no MCP equivalent.

**Runtime prerequisite — SDL2.** The MCP server *is* the funpack binary, which links SDL2 at load
time, so a missing SDL2 provider stops the server from starting (and every CLI verb, including
`build`/`check`/`test`). Install it once: `brew install sdl2-compat` (macOS — the maintained
SDL2-ABI-over-SDL3 provider `sdl2` now aliases to) / `apt install libsdl2-dev` (Linux). The loader
fails before `main`, so the symptom is the server simply not coming up.

## Source

Distilled from the in-repo funpack spec (`spec/`). The examples
(`pong`, `snake`, `hunt`, `yard`, `arena`, `dungeon`, `warren`, `krognid`, `hud`, `assets`,
`numerics`, `drift`) are the normative idiom; a real compile is the tie-breaker.
