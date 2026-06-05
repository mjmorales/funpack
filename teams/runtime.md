---
schema_version: 28
team:
  slug: runtime
  team_type: stream_aligned
  charter: "Owns deterministic artifact execution — fixed-point sim, engine.* stdlib"
  lifetime: persistent
  terminates_on_milestone: null
  status: active
  created_at: 2026-06-05T02:40:25.207Z
scope:
  read: ["**"]
  write: ["runtime/**"]
roster:
  tech_lead: ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7
  engineer: ct-tools-seat-2bdf87ea-e246-46ca-b5aa-7c3b5baf55b6
  implementer: ct-qa-seat-b16b9315-0bcc-409b-876d-fc4ef652b118
interface:
  accepts: []
  exposes:
    []
lore:
  count: 4
  live: 1
  recent:
    - { id: 7, author: "ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7", created_at: "2026-06-05T21:26:26.732Z", body: "Runtime determinism-contract boundary invariants (the durable residue of the runtime-pong epic decompositions; story sequencing and state snapshots dropped as task-graph-owned).\n\nThe deterministic action-snapshot is the contract; devices are an interchangeable producer. The Input resource is read-only (value/pressed/released/held/axis over PlayerId + role-kinded actions, analog fixed-point in [-1,1]); no Key/Pad/Mouse appears in sim code (§04, §23 §5). Raw input enters through a HEADLESS injected device-event queue — deterministic and testable — never live polling; the live vendor:sdl2 backend feeds that same injected-queue seam. Rejected: leading with the live SDL backend, which couples the determinism core to an impure non-testable boundary and inverts the dependency (snapshot is the contract, the device is the replaceable producer).\n\nInput is the SOLE nondeterminism source — no RNG; ground truth is the interpreter (§09.5). The byte-stable per-tick replay log rides the §23.4 action-snapshot determinism record; it is explicitly NOT the §24 persistence layer (§24 = sim-snapshot saves + per-machine settings). A deterministic per-tick frame digest (committed fixed-point world state and/or the §20 draw-list, screenshot{include_drawlist}-style per §28) is the comparison surface, independent of the replay path.\n\nRuntime ownership boundary: runtime consumes the executable ARTIFACT format (distinct from the funpack Index Contract NDJSON, §29); the artifact format and golden fixtures come from the funpack emission side. Runtime does NOT define the artifact format, does NOT record device input as a save, and the replay re-fold consumer is a separate acceptance concern from the recording side. Pong note: score is a single-instance thing Scoreboard, NOT a singleton — Goal{side} is emitted by score on Ball and consumed same-tick by tally on Scoreboard and serve on Ball, the canonical forward synchronous in-pipeline-order signal route.\n\nConsolidates runtime lore #2, #4, #5 (boundary/invariant residue; the kernel-copy-not-link invariant is promoted separately to the Codex)." }
---

# Team: runtime

## Charter

Owns deterministic artifact execution — fixed-point sim, engine.* stdlib

## Type

- Interaction archetype: stream_aligned
- Lifetime: persistent
- Terminates on milestone: <!-- none -->
- Status: active

## Scope

- Read globs: **
- Write globs: runtime/**

## Roster

- tech_lead: ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7
- engineer: ct-tools-seat-2bdf87ea-e246-46ca-b5aa-7c3b5baf55b6
- implementer: ct-qa-seat-b16b9315-0bcc-409b-876d-fc4ef652b118

## Interface

- Accepts: <!-- none -->
- Exposes: <!-- none -->

## Lore

- Entries: 4 (1 live)
- [7] ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7: Runtime determinism-contract boundary invariants (the durable residue of the runtime-pong epic decompositions; story sequencing and state snapshots dropped as task-graph-owned).

The deterministic action-snapshot is the contract; devices are an interchangeable producer. The Input resource is read-only (value/pressed/released/held/axis over PlayerId + role-kinded actions, analog fixed-point in [-1,1]); no Key/Pad/Mouse appears in sim code (§04, §23 §5). Raw input enters through a HEADLESS injected device-event queue — deterministic and testable — never live polling; the live vendor:sdl2 backend feeds that same injected-queue seam. Rejected: leading with the live SDL backend, which couples the determinism core to an impure non-testable boundary and inverts the dependency (snapshot is the contract, the device is the replaceable producer).

Input is the SOLE nondeterminism source — no RNG; ground truth is the interpreter (§09.5). The byte-stable per-tick replay log rides the §23.4 action-snapshot determinism record; it is explicitly NOT the §24 persistence layer (§24 = sim-snapshot saves + per-machine settings). A deterministic per-tick frame digest (committed fixed-point world state and/or the §20 draw-list, screenshot{include_drawlist}-style per §28) is the comparison surface, independent of the replay path.

Runtime ownership boundary: runtime consumes the executable ARTIFACT format (distinct from the funpack Index Contract NDJSON, §29); the artifact format and golden fixtures come from the funpack emission side. Runtime does NOT define the artifact format, does NOT record device input as a save, and the replay re-fold consumer is a separate acceptance concern from the recording side. Pong note: score is a single-instance thing Scoreboard, NOT a singleton — Goal{side} is emitted by score on Ball and consumed same-tick by tally on Scoreboard and serve on Ball, the canonical forward synchronous in-pipeline-order signal route.

Consolidates runtime lore #2, #4, #5 (boundary/invariant residue; the kernel-copy-not-link invariant is promoted separately to the Codex).
