# funpack — Language & Engine Specification

The authoritative, formalized definition of the funpack language, engine, and toolchain.

Reading order: foundations → runtime model → numerics/sim → authoring → presentation/IO →
systems → toolchain.

| # | Component | File |
|---|---|---|
| 01 | Axioms & design principles | [`01-axioms.md`](01-axioms.md) |
| 02 | Language core — lexis, grammar, expressions | [`02-language-core.md`](02-language-core.md) |
| 03 | Data model — `data`, `enum`, `thing`, `signal`, `Option`/`Result` | [`03-data-model.md`](03-data-model.md) |
| 04 | Effects, purity & errors | [`04-effects.md`](04-effects.md) |
| 05 | Directives | [`05-directives.md`](05-directives.md) |
| 06 | Things, behaviors & signals | [`06-things-behaviors.md`](06-things-behaviors.md) |
| 07 | Pipelines & scheduling | [`07-pipelines.md`](07-pipelines.md) |
| 08 | State — world-as-database, `Id`/`Ref`/`Owned`, `View` | [`08-state.md`](08-state.md) |
| 09 | Runtime & execution | [`09-runtime.md`](09-runtime.md) |
| 10 | Numerics — `Fixed`, `Vec`/`Quat`/`Mat4`, RNG | [`10-numerics.md`](10-numerics.md) |
| 11 | Physics | [`11-physics.md`](11-physics.md) |
| 12 | Navigation | [`12-navigation.md`](12-navigation.md) |
| 13 | AI, timing & sequencing | [`13-ai.md`](13-ai.md) |
| 14 | Project structure & config (`.fcfg`) | [`14-project-config.md`](14-project-config.md) |
| 15 | Modules & visibility | [`15-modules.md`](15-modules.md) |
| 16 | Modeling DSL (`.fpm`) | [`16-modeling.md`](16-modeling.md) |
| 17 | Levels (`.flvl`) | [`17-levels.md`](17-levels.md) |
| 18 | Tilemaps | [`18-tilemaps.md`](18-tilemaps.md) |
| 19 | Assets pipeline | [`19-assets.md`](19-assets.md) |
| 20 | Render pipeline — 2D/3D, animation | [`20-render.md`](20-render.md) |
| 21 | UI (`.fui`) | [`21-ui.md`](21-ui.md) |
| 22 | Audio | [`22-audio.md`](22-audio.md) |
| 23 | Input | [`23-input.md`](23-input.md) |
| 24 | Persistence — saves & settings | [`24-persistence.md`](24-persistence.md) |
| 25 | Netcode & multiplayer | [`25-netcode.md`](25-netcode.md) |
| 26 | Stdlib surface | [`26-stdlib.md`](26-stdlib.md) |
| 27 | Modding | [`27-modding.md`](27-modding.md) |
| 28 | Introspection & debugging | [`28-introspection.md`](28-introspection.md) |
| 29 | Architecture & governance | [`29-architecture-governance.md`](29-architecture-governance.md) |
| 30 | Packages & dependencies | [`30-packages.md`](30-packages.md) |
