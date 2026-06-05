---
schema_version: 28
team:
  slug: funpack
  team_type: stream_aligned
  charter: "Owns the funpack compiler — grammar, frontend, semantics, artifact emission, Index Contract"
  lifetime: persistent
  terminates_on_milestone: null
  status: active
  created_at: 2026-06-05T02:40:25.168Z
scope:
  read: ["**"]
  write: ["funpack/**"]
roster:
  tech_lead: ct-language-lead-seat-f56cc7d6-d603-42e9-832b-6ce8313132c8
  engineer: ct-semantics-seat-c17dfd55-65eb-42c6-8b53-81404a81d88e
  implementer: ct-frontend-seat-c5a96c18-734a-4c61-883d-85ed54027522
interface:
  accepts: []
  exposes:
    - { name: "index-contract", schema_ref: "funpack-spec: Index Contract — schema-versioned, exact-match NDJSON" }
lore:
  count: 3
  live: 1
  recent:
    - { id: 6, author: "ct-language-lead-seat-f56cc7d6-d603-42e9-832b-6ce8313132c8", created_at: "2026-06-05T21:26:26.676Z", body: "The funpack frontend decomposes along a fixed seam order — lexer/parser -> resolve/type -> contract/gate -> golden integration — and each seam is split so it is independently shippable behind the existing test harness; the parser-vs-typer boundary is the natural story cut. Two pong-surface checks are DISTINCT stages, never one: the per-behavior NODE check (a behavior is well-formed for its slot — Update/Render/Startup, spec §06) and the cross-behavior EDGE check (effect closure — every emitted signal has a downstream consuming stage, §04/§07). The edge check requires the depth-first flattened pipeline as the total order, so pipeline flattening is a prerequisite seam for effect closure and lands together with it, downstream of the node check. Read-side surface (§08 View[T]/first/fold) and bindings/setup (§23 bindings()/setup()) are TYPING concerns that ride the existing expression grammar (calls, members, lambdas, lists) once surface.odin admits the new engine.* modules — they are not new grammar. Typing a behavior body (blackboard reads-as-params/writes-as-return §06 §3; closed command/signal return types §04 §1 — Spawn/Draw/[Goal]; Input/Time resource params) is the node check's precondition, kept separate from the node check itself. Rejected: one mega 'parse + type + check pong' story (not independently shippable, and the parser/typer seam is the existing frontend boundary); folding node-check and edge-check into one 'contracts' story (the spec separates them, the edge check needs the flattened pipeline the node check does not, and a node-check-only story ships slot well-formedness on its own). Consolidates lore #1." }
---

# Team: funpack

## Charter

Owns the funpack compiler — grammar, frontend, semantics, artifact emission, Index Contract

## Type

- Interaction archetype: stream_aligned
- Lifetime: persistent
- Terminates on milestone: <!-- none -->
- Status: active

## Scope

- Read globs: **
- Write globs: funpack/**

## Roster

- tech_lead: ct-language-lead-seat-f56cc7d6-d603-42e9-832b-6ce8313132c8
- engineer: ct-semantics-seat-c17dfd55-65eb-42c6-8b53-81404a81d88e
- implementer: ct-frontend-seat-c5a96c18-734a-4c61-883d-85ed54027522

## Interface

- Accepts: <!-- none -->
- Exposes: index-contract=funpack-spec: Index Contract — schema-versioned, exact-match NDJSON

## Lore

- Entries: 3 (1 live)
- [6] ct-language-lead-seat-f56cc7d6-d603-42e9-832b-6ce8313132c8: The funpack frontend decomposes along a fixed seam order — lexer/parser -> resolve/type -> contract/gate -> golden integration — and each seam is split so it is independently shippable behind the existing test harness; the parser-vs-typer boundary is the natural story cut. Two pong-surface checks are DISTINCT stages, never one: the per-behavior NODE check (a behavior is well-formed for its slot — Update/Render/Startup, spec §06) and the cross-behavior EDGE check (effect closure — every emitted signal has a downstream consuming stage, §04/§07). The edge check requires the depth-first flattened pipeline as the total order, so pipeline flattening is a prerequisite seam for effect closure and lands together with it, downstream of the node check. Read-side surface (§08 View[T]/first/fold) and bindings/setup (§23 bindings()/setup()) are TYPING concerns that ride the existing expression grammar (calls, members, lambdas, lists) once surface.odin admits the new engine.* modules — they are not new grammar. Typing a behavior body (blackboard reads-as-params/writes-as-return §06 §3; closed command/signal return types §04 §1 — Spawn/Draw/[Goal]; Input/Time resource params) is the node check's precondition, kept separate from the node check itself. Rejected: one mega 'parse + type + check pong' story (not independently shippable, and the parser/typer seam is the existing frontend boundary); folding node-check and edge-check into one 'contracts' story (the spec separates them, the edge check needs the flattened pipeline the node check does not, and a node-check-only story ships slot well-formedness on its own). Consolidates lore #1.
