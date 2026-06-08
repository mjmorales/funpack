# funpack — Vision

## The bet
Game development becomes agent-first: LLM agents author, verify, and ship game code
as first-class participants, and doing so is *fun* — because the language is
unambiguous, builds are bit-identical by construction, and the compiler is a quality
gate whose diagnostics make an agent's write → check → fix loop converge.

It traces to three irreducible roots (spec §01):
- **R1 — agents fail where meaning is ambiguous or behavior is nondeterministic.**
  funpack removes both at the source: an LL(1) grammar with one reading per construct,
  and determinism as law.
- **R2 — agents are stateless across runs and build top-down.** They lose context
  between runs and re-derive what they cannot recall. funpack gives them sanctioned
  anchors that leave no rot, and a persistent surface to resume from. R2 is the source
  of the entire governance layer.
- **R3 — optimize for the next editor, not the author.** Most edits are made by an
  agent that did not write the code. "Clever" is a defect; one obvious way per thing.

## The architecture: two binaries over one contract
- **funpack** — the pure engine. Source → bit-identical artifact + a versioned Index
  Contract (NDJSON). It owns the language, the structural quality gates, and the
  deterministic runtime that executes the artifact. No clock, no IO-as-state.
- **warden** — the impure governance binary. It owns the task DB, leases, swarm
  dispatch, and the operator surface. It invokes funpack as a subprocess and depends
  ONLY on the structured contract — never a library link.
The process boundary is the engine boundary made physical: it preserves funpack's
pure-function determinism and lets warden govern any toolchain that emits the contract.

## Determinism is the substrate (P1, both tiers mandatory)
- **Build determinism:** same source → bit-identical artifact.
- **Simulation determinism:** same inputs + seed → bit-identical frame N on every machine.
Fixed-point is the default for simulation state (float is visual-only, flagged as an
effect); RNG is engine-abstracted and seeded, never ambient; time is logical.
Determinism is load-bearing at runtime (lockstep, P2P, shared recordings), not a
dev-time convenience. Every committed value, frame digest, and replay byte is sacred —
moving them without cause is a defect.

## Governance is the product
The language is the showcase; the governance layer is the more broadly valuable
artifact, and the opinionated contract is its moat (spec §29 §5). Keeping an agent
swarm on track is a general problem: every swarm failure mode is bound to a mechanical
backstop — @todo expiry, @stub-under-release ban, leases, the duplication/find reuse
surface, criterion adjudication — no advisory warnings, no knobs. Because warden
depends only on the contract, it is toolchain-agnostic.

## The contract spine
The Index Contract is the first of five structured contracts; the others are
stdlib-interface, modapi, introspection, and netcode (spec §29 §2, §27). Each is the
same motif pointed at a new seam: closed, versioned, exact-match, generated-not-
authored, refused on mismatch with a fix-it. Completing the five is the
architecturally-complete statement of the contract-spine thesis.

## The realization arc
Realized in sequence, each stage a floor the next builds on:
1. **The toolchain runs the reference surface.** All nine golden examples (pong, snake,
   hunt, yard, arena, krognid, hud, assets, numerics) compile and run bit-identically —
   the founding outcome bet and the determinism floor every later stage inherits.
   funpack does not grammar-include what it cannot run.
2. **The governance substrate becomes operable.** warden is the front door an operator
   and a swarm live in — the task DB as a deterministic @evt fold, leases, dispatch,
   the query surface — making the Index Contract's purpose real.
3. **The contract spine completes.** The four remaining structured contracts land, each
   in producer/consumer lockstep behind a schema-version bump.

## Standing invariants
- **The engine boundary.** The engine owns state, scheduling, and hard floors; the
  model owns judgment.
- **Long-term-correct, no stopgaps.** Every change is the durable fix the design calls
  for — never a band-aid that defers the real work.
- **Surface friction, escalate.** When the engine's contracts, the language's
  semantics, or the spec's normative text resist an implementation, that resistance is
  a stop-and-escalate signal resolved at the source — never codified into a
  contradiction to make a case pass.
- **The spec is doctrine.** funpack-spec is the source of truth; this repo is the
  machine that satisfies it, measured against the spec, the golden examples, and the
  stdlib engine surface.
