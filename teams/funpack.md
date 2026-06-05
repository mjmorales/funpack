---
schema_version: 27
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
  count: 2
  recent:
    - { id: 3, author: "ct-language-lead-seat-f56cc7d6-d603-42e9-832b-6ce8313132c8", created_at: "2026-06-05T19:15:42.630Z", body: "Artifact format seam (epic: define artifact format + emit pong + Index Contract project record, milestone runtime-pong). DECISION: artifact spelling = serialized checked-AST as a schema-versioned byte format, decoupled from runtime via a written format-spec doc in funpack/** + golden artifact fixtures — runtime (Odin, runtime/**) loads the documented bytes with ZERO funpack imports (spec 29 process-boundary data contract, not a library link). 09.1 makes checked-AST-vs-bytecode an impl detail; checked-AST is the cheapest loadable form and the interpreter stays canonical semantics. The format-spec story lands FIRST so runtime starts in parallel against bytes+fixtures, not funpack internals. Artifact carries: thing/singleton schemas+field defaults (08), behaviors keyed to stages with reserved step signatures, depth-first flattened pipeline as one total order + signal-producer-consumer routing map (07), 03 enums/signals/data, setup [Spawn] program, 23 bindings table, entrypoint wiring pipeline-tick-60hz-bindings from entrypoints.fcfg (14). No clock/machine-paths; bit-identical by construction. Index Contract project record is a SEPARATE story/surface (NDJSON, exact-match, schema-versioned, all fields mandatory): authored entrypoints/builds/tag_registry + derived capabilities/pipeline_flattened/gate_results (14.3, 29.2) — the team's one exposed interface. REJECTED: bytecode artifact (premature, 09.1 defers it); shared Odin loader pkg imported by runtime (violates 29 zero-imports); folding project record into artifact (distinct consumers runtime-vs-warden + transports). BOUNDARY: defines format + writes emitter in funpack/**; does NOT execute (runtime execution epic consumes+depends). Sibling epic 'Parse, typecheck, gate the pong surface' lands first producing the checked AST this serializes — none of thing/behavior/pipeline/signal/data/entrypoint AST nodes exist in funpack/ yet (tree only handles the numeric kernel)." }
    - { id: 1, author: "ct-language-lead-seat-f56cc7d6-d603-42e9-832b-6ce8313132c8", created_at: "2026-06-05T19:15:22.719Z", body: "# Pong surface epic decomposition — story seams\n\nThe \"Parse, typecheck, and gate the pong game surface\" epic extends the\nfrontend from the test-only numerics surface to the full §06/§07 gameplay\nsurface. The decomposition follows the established frontend seam order\n(lexer/parser -> resolve/type -> contract/gate -> golden integration), with\nstory boundaries chosen so each is independently shippable behind the existing\ntest harness.\n\n## The load-bearing fact that shapes the split\n\nThe current parser (parser.odin) parses ONLY: module @doc, import (3 forms),\nand `test` blocks (let/assert). The `Ast` struct carries `imports` and `tests`\nonly. NONE of the §06 declaration kinds (thing/singleton/behavior/signal),\nthe §07 pipeline, user `data`/`enum`/`fn`/module-`let`, or the §03 enum-as-role\nform (`enum Steer: Axis`) are parsed yet. The expr cascade lacks `with` and `if`\nexpressions, struct-payload variants (`Draw::Rect{...}`), tuple-payload variants\n(`Spawn(...)`), string interpolation, and multi-statement fn bodies. So the\nfirst story is necessarily a grammar-and-AST story: grow the declaration layer\nand the missing expression forms, parse-only, no typing.\n\n## Node vs edge — the two pong-specific checks are distinct stages\n\nSpec §06 §6 frames the behavior-contract check as a per-behavior NODE check\n(\"well-formed for its slot: Update/Render/Startup?\") and effect closure\n(§04 §4, §07 §2) as the cross-behavior EDGE check (\"does every emitted signal\nhave a downstream consuming stage?\"). These are two stages, not one, and the\nedge check requires the depth-first flattened pipeline as the total order.\nThat makes pipeline flattening a prerequisite seam for effect closure, so they\nland as one story (flatten + edge-check) downstream of the node-check story.\n\n## Read-side and bindings/setup are typing concerns, not new grammar\n\n§08 View[T]/first/fold and §23 bindings()/setup() ride the existing expr\ngrammar (calls, members, lambdas, lists) once the surface table (surface.odin)\nadmits the new engine.* modules (engine.world, engine.input, engine.render,\nengine.core, engine.list additions). The blackboard reads-as-params /\nwrites-as-return typing (§06 §3), closed command/signal return types (§04 §1:\nSpawn/Draw/[Goal]), and resource params (Input/Time) are all the same\ntyping story, keyed off the user-declared type environment the resolve story\nbuilds. Kept separate from contract checks because typing a behavior body is\nthe node-check's precondition, not the node-check itself.\n\n## Boundary held\n\nThis epic stops at a checked, contract-validated AST + flattened pipeline. It\ndoes NOT serialize (the Index Contract / artifact-emission sibling epic owns\nthat) and does NOT execute (runtime team epics own that). The numerics\nsaturating kernel and test evaluator already cover the numerics half and are\nreused unchanged.\n\n## Alternatives rejected\n\n- One mega \"parse + type + check pong\" story: rejected — not independently\n  shippable, and the parser-vs-typer seam is exactly the existing frontend\n  boundary, so splitting on it keeps each story verifiable in isolation.\n- Folding node-check and edge-check into one \"contracts\" story: rejected — the\n  spec explicitly separates them, the edge check needs the flattened pipeline\n  the node check does not, and a node-check-only story ships value (slot\n  well-formedness) without yet owning flattening." }
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

- Entries: 2
- [3] ct-language-lead-seat-f56cc7d6-d603-42e9-832b-6ce8313132c8: Artifact format seam (epic: define artifact format + emit pong + Index Contract project record, milestone runtime-pong). DECISION: artifact spelling = serialized checked-AST as a schema-versioned byte format, decoupled from runtime via a written format-spec doc in funpack/** + golden artifact fixtures — runtime (Odin, runtime/**) loads the documented bytes with ZERO funpack imports (spec 29 process-boundary data contract, not a library link). 09.1 makes checked-AST-vs-bytecode an impl detail; checked-AST is the cheapest loadable form and the interpreter stays canonical semantics. The format-spec story lands FIRST so runtime starts in parallel against bytes+fixtures, not funpack internals. Artifact carries: thing/singleton schemas+field defaults (08), behaviors keyed to stages with reserved step signatures, depth-first flattened pipeline as one total order + signal-producer-consumer routing map (07), 03 enums/signals/data, setup [Spawn] program, 23 bindings table, entrypoint wiring pipeline-tick-60hz-bindings from entrypoints.fcfg (14). No clock/machine-paths; bit-identical by construction. Index Contract project record is a SEPARATE story/surface (NDJSON, exact-match, schema-versioned, all fields mandatory): authored entrypoints/builds/tag_registry + derived capabilities/pipeline_flattened/gate_results (14.3, 29.2) — the team's one exposed interface. REJECTED: bytecode artifact (premature, 09.1 defers it); shared Odin loader pkg imported by runtime (violates 29 zero-imports); folding project record into artifact (distinct consumers runtime-vs-warden + transports). BOUNDARY: defines format + writes emitter in funpack/**; does NOT execute (runtime execution epic consumes+depends). Sibling epic 'Parse, typecheck, gate the pong surface' lands first producing the checked AST this serializes — none of thing/behavior/pipeline/signal/data/entrypoint AST nodes exist in funpack/ yet (tree only handles the numeric kernel).
- [1] ct-language-lead-seat-f56cc7d6-d603-42e9-832b-6ce8313132c8: # Pong surface epic decomposition — story seams

The "Parse, typecheck, and gate the pong game surface" epic extends the
frontend from the test-only numerics surface to the full §06/§07 gameplay
surface. The decomposition follows the established frontend seam order
(lexer/parser -> resolve/type -> contract/gate -> golden integration), with
story boundaries chosen so each is independently shippable behind the existing
test harness.

## The load-bearing fact that shapes the split

The current parser (parser.odin) parses ONLY: module @doc, import (3 forms),
and `test` blocks (let/assert). The `Ast` struct carries `imports` and `tests`
only. NONE of the §06 declaration kinds (thing/singleton/behavior/signal),
the §07 pipeline, user `data`/`enum`/`fn`/module-`let`, or the §03 enum-as-role
form (`enum Steer: Axis`) are parsed yet. The expr cascade lacks `with` and `if`
expressions, struct-payload variants (`Draw::Rect{...}`), tuple-payload variants
(`Spawn(...)`), string interpolation, and multi-statement fn bodies. So the
first story is necessarily a grammar-and-AST story: grow the declaration layer
and the missing expression forms, parse-only, no typing.

## Node vs edge — the two pong-specific checks are distinct stages

Spec §06 §6 frames the behavior-contract check as a per-behavior NODE check
("well-formed for its slot: Update/Render/Startup?") and effect closure
(§04 §4, §07 §2) as the cross-behavior EDGE check ("does every emitted signal
have a downstream consuming stage?"). These are two stages, not one, and the
edge check requires the depth-first flattened pipeline as the total order.
That makes pipeline flattening a prerequisite seam for effect closure, so they
land as one story (flatten + edge-check) downstream of the node-check story.

## Read-side and bindings/setup are typing concerns, not new grammar

§08 View[T]/first/fold and §23 bindings()/setup() ride the existing expr
grammar (calls, members, lambdas, lists) once the surface table (surface.odin)
admits the new engine.* modules (engine.world, engine.input, engine.render,
engine.core, engine.list additions). The blackboard reads-as-params /
writes-as-return typing (§06 §3), closed command/signal return types (§04 §1:
Spawn/Draw/[Goal]), and resource params (Input/Time) are all the same
typing story, keyed off the user-declared type environment the resolve story
builds. Kept separate from contract checks because typing a behavior body is
the node-check's precondition, not the node-check itself.

## Boundary held

This epic stops at a checked, contract-validated AST + flattened pipeline. It
does NOT serialize (the Index Contract / artifact-emission sibling epic owns
that) and does NOT execute (runtime team epics own that). The numerics
saturating kernel and test evaluator already cover the numerics half and are
reused unchanged.

## Alternatives rejected

- One mega "parse + type + check pong" story: rejected — not independently
  shippable, and the parser-vs-typer seam is exactly the existing frontend
  boundary, so splitting on it keeps each story verifiable in isolation.
- Folding node-check and edge-check into one "contracts" story: rejected — the
  spec explicitly separates them, the edge check needs the flattened pipeline
  the node check does not, and a node-check-only story ships value (slot
  well-formedness) without yet owning flattening.
