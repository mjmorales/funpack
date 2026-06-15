# 27 — Modding

A mod is an **ordinary `.fun` module**. There is no mod language, no mod file type, and no modding
SDK to maintain. Two mechanisms carry the whole feature, both existing funpack patterns pointed
*outward*:

1. **What the game offers** — the operator marks declarations `@expose`, and the compiler emits a
   generated **`<game>.modapi.gen.fun`** interface a mod imports (the contract *is* the SDK, a build
   artifact of the directives).
2. **What a mod may do** — a **confinement analysis** over the mod's AST, triggered by its importing a
   modapi contract, makes rogue behavior *unrepresentable*, not merely policed.

This is the **contract spine, third instance** (compiler→index contract; engine↔game stdlib
interface; **game↔mod modapi**). `extern` exposes natives *downward* to the game; `@expose` exposes a
contract *upward* to mods — same machinery, opposite direction.

`@expose` is funpack's one visibility primitive, shared with packages ([`30`](30-packages.md) §6): it
declares an external contract, and the **importer's role** decides confinement. A **package consumer**
imports the exposed surface as a *peer* — full capability ceiling, calling into the code. A **mod**
imports the same surface but is *confined and sandboxed* — less trusted than the host, bounded to the
contract. One marker, two importer modes.

## 1. The thing-isolation rule *is* the sandbox

The single line that makes every behavior testable — *write only your own thing's blackboard; to
touch anything else, emit a signal* ([`06`](06-things-behaviors.md)) — is already the mod sandbox. A
mod is untrusted code that owns some `thing`s; the language **already** forbids cross-thing writes for
everyone, so a mod cannot corrupt game state by construction. It interacts only through signals, and
the operator chooses which cross via `@expose`. The genuinely new surface is small: the `@expose`
contract, exposure closure, and per-mod resource bounds.

## 2. `@expose` & exposure closure

`@expose` is inert (like `@doc`); the compiler collects every `@expose` and emits the modapi contract
(declarations only). The taxonomy is closed and maps onto both gRPC and existing funpack primitives:

| `@expose` on | The mod may | gRPC analogue |
|---|---|---|
| `data` (transparent) | construct & read its fields | message |
| `data` (opaque) | hold and pass back, never inspect | handle |
| `signal (out)` / `signal (in)` | observe the game's events / emit into the game | stream / message |
| `fn` (pure, read-only) | query game state; returns **projected** views | unary RPC |
| pipeline `slot` | register a behavior into a named stage | service method |

**Exposure closure** (a theorem dual to serialization/effect closure): an exposed declaration may
reference only exposed, primitive, or stdlib types. The generated contract is the **transitive
closure** of `@expose`; everything not reachable is **absent from the generated file** — internal
blackboards, signals, and the real pipeline are *unnameable*, not redacted. Visibility is a property
of the generation algorithm. **Contract evolution is a build gate**: the compiler diffs the previous
contract against the new (add = minor, remove/change = major); a breaking change without a major bump
is a compile error, and a mod pins the contract version on its import.

## 3. What a mod is, and the confinement analysis

A mod is a `.fun` module that **imports a `*.modapi` contract** — that import is the role marker, the
capability manifest, and the version pin, in one place:

```funpack
import krognid.modapi@2 .{ WorldView, SpawnRequest, on_tick }
thing Familiar { pos: Vec2, cooldown: Fixed }              // the mod's OWN thing — private, serialized
behavior follow on Familiar { fn step(self, world: WorldView, time: Time) -> (Familiar, [SpawnRequest]) { … } }
```

**Imports are capabilities** — a mod may import only the modapi contract and a pure stdlib subset
(`prelude`, `math`, `list`, `map`, `grid`, `rand` — seeded/threaded; **no** `assets`, no `render`
submit, no native). If it cannot import a symbol, it cannot name it, so it cannot touch it. A mod's
capabilities are **exactly the `@expose` contract surface** — there is no separate permission system,
no grant table, no manifest of rights; the contract *is* the capability boundary. The threat
model is **clean: everything except resource exhaustion is statically decidable or unrepresentable** —
access-memory-it-doesn't-own, OS commands, forging internal signals, reaching another mod's state,
file/socket IO, reflection, and lockstep desync are all *unrepresentable by construction*; a
contract-version exploit is caught at load.

The same analysis runs **twice**: a **compiler gate** (modder DX — structured fix-criteria
diagnostics, the self-healing loop for mod authoring) and a **runtime verifier** (the security
boundary — the operator's runtime *re-runs* the analysis on load and refuses a failing mod; possible
because mods ship as **interpreted funpack**, so the runtime inspects the actual code — verify, don't
trust). The engine boundary is exactly this pair — the import-triggered analysis plus the
session-handshake contract-version match; **mod signing and distribution are operator/platform
infrastructure, outside engine doctrine**.

## 4. Resource bounds — the only runtime check

A mod gets a **fixed per-tick budget** metered in **logical units** (interpreter steps and
allocations, **never wall-clock**), so every machine faults at the *same logical point* and lockstep
cannot desync. It is **aggregate per mod per tick** (not per-instance — a mod cannot multiply its
budget by spawning). On overrun the behavior **faults as a value** (its contribution is dropped, the
tick continues), so one greedy mod cannot stall or desync the host.

## 5. Determinism, manifest & assets

A mod filling a **sim slot** is pure funpack with no `extern`, fixed-point, threaded `Rng` ⇒
replay-safe by the same construction as game code; a **render slot** may use `Float` (visual-only).
Multiple mods in one slot run in deterministic order from the load manifest (`(mod-id,
behavior-order)`, the within-stage rule). The **load manifest is session state pinned with the seed**
(mod set + order + contract versions in the session header, not in any external governor), so a recording fully
determines the mod set and replay/lockstep stay bit-identical; a networked session agrees it at
handshake. There is **no mod-of-a-mod** (`@expose` is forbidden in a mod; cross-mod is always
game-mediated). A **save embeds its mod manifest**; a removed mod is a typed load error and *load-with-
discard* is safe by construction (cross-thing access is signal-only, so no game thing references a mod
thing's blackboard). A mod **hot-reloads through the same tick-boundary hot-reload + migration
mechanism as the base game** ([`09`](09-runtime.md)) — there is no special mod-reload path; a mod's
own `thing` schema migrates by the same name-keyed rules as any sim state. Asset modding splits on the `data`-vs-opaque-handle line — visual/audio assets
become opaque handles; sim-affecting geometry ships as content-hashed fixed-point `data`.
