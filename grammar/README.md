# funpack — grammars

The formal grammar of the funpack family, as **EBNF over a shared lexical core**,
with the `.fun` LL(1) property mechanically demonstrated. A *definition*, not an
implementation: EBNF + FIRST/FOLLOW tables, tool-agnostic. Every production is
validated against the live `examples/` and `stdlib/` — the grammar includes only
what funpack can run (01-axioms §5).

## Why a family, not one grammar

The file types do not share a lexer, and some hold constructs others forbid (`..`
and `for` exist in `.flvl`, are banned in `.fun`; `=` vs `:`, `//` vs `#` vs none).
A single union grammar would be LL(1) nowhere. They share a **lexical core**
(identifier classes, literals, the directive token, module paths, separators) and
split at the syntactic layer — one grammar per extension.

| Grammar | Covers | Comments | LL(1)? |
|---|---|---|---|
| [`lexical-core.ebnf`](lexical-core.ebnf) | tokens shared by all | — | — |
| [`fun.ebnf`](fun.ebnf) + [`fun.ll1.md`](fun.ll1.md) | `.fun`, `.gen.fun` | none | **yes** — proved |
| [`fcfg.ebnf`](fcfg.ebnf) | `.fcfg` (project/entrypoints/builds/tags/deps) | none | yes (trivial) |
| [`fpm.ebnf`](fpm.ebnf) | `.fpm` (modeling) | `//` | no (imperative DSL, 16) |
| [`flvl.ebnf`](flvl.ebnf) | `.flvl` (levels + tilemap layers) | `//` | no |
| [`fui.ebnf`](fui.ebnf) | `.fui` (UI) | `//` | yes (in practice) |
| [`atlas.ebnf`](atlas.ebnf) | `.atlas` (sprite sheets) | `//` | yes |
| [`tiles.ebnf`](tiles.ebnf) | `.tiles` (tilesets) | `//` | yes |
| [`manifest.ebnf`](manifest.ebnf) | `.manifest` (asset index) | `#` | yes |

`.gen.fun` is `.fun` (a filename marker, not a dialect; 15 §6). `assets.report.txt`
is a derived human report with no grammar (19 §5).

## The LL(1) property

The spec scopes its strict-LL(1) claim to `.fun`'s statement layer and parses
expressions with Pratt (02 §1). This grammar makes the whole `.fun` language
checkably LL(1) by giving expressions as an equivalent precedence cascade. The
property rests on two lexical decisions — two identifier classes and no record
literal in a control-flow head ([`fun.ll1.md`](fun.ll1.md) §1).

> `.fun` is LL(1) — strict at the statement layer, and via the cascade for
> expressions. No backtracking; max one token of lookahead. (Command-wrap is call
> syntax — `Spawn(thing)`, `Despawn()` — so a brace is always a record literal.)

Conflict analysis, predict tables, and discrepancies: [`fun.ll1.md`](fun.ll1.md).

## Notation

W3C-EBNF, identical across files; the legend is atop [`lexical-core.ebnf`](lexical-core.ebnf).
`(* … *)` are meta-comments, not funpack.

## Validation

Each grammar accepts its live sources: `fun` against every `.fun` in `examples/` +
`stdlib/engine/*.fun` (incl. `.gen.fun` seams); `fcfg` against `funpack_configs/*`
(deps from 30 §3); `fpm` against `krognid.fpm`/`coin.fpm`; `flvl` against
`arena.flvl` (tilemap from 18 §3); `fui` against `hud`/`pause`/`settings.fui`;
`atlas` against `pickups.atlas`; `manifest` against `assets.manifest`. `tiles` is
spec-only (18 §2; no example file yet).

## Maintenance contract

The live `.fun` examples and stdlib **lead**; this grammar **follows**. When sources
disagree, the spec is the tie-breaker and the resolution is recorded (01 §5).

## Decisions

Full options/trade-offs in [`fun.ll1.md`](fun.ll1.md) §5.

Resolved:

- **Braced initializer (A).** Command-wrap is call syntax (`Spawn(thing)`,
  `Despawn()`), so a brace is always a record literal and `.fun` is strictly LL(1).
  Applied across `fun.ebnf`, spec `02 §2`, `stdlib`, and 28 example sites.
- **`@todo` window (D).** The four forms (relative duration / absolute date /
  build count / task ref `T-NNNN`) — spec `05 §2`, reconciled with `29 §4`, grammar
  [`lexical-core.ebnf`](lexical-core.ebnf) §6.
- **Directive arguments.** `@migrate(from:/with:)` (spec `05 §6`) and the debug
  family `@break`/`@log`/`@watch(expr)` / `@trace` (spec `05 §5`, `28 §4`).
- **`.fpm` mutation/loop.** `name = expr` and `for x in <iterable> { … }` (spec `16 §1`).

Still open:

- **`.tiles`** has a spec (`18 §2`) but no example file — confirm the grammar when
  a real tileset lands. (An example gap, not a spec gap.)
