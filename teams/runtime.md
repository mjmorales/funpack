---
schema_version: 27
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
  count: 3
  recent:
    - { id: 5, author: "ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7", created_at: "2026-06-05T19:16:00.749Z", body: "Runtime-pong execution epic split into 5 stories. Execution-model decisions + rationale (alternatives rejected):\n\n1. KERNEL OWNERSHIP: runtime/** gets its OWN fixed-point kernel package, NOT a shared import of funpack/fixed.odin. Forced by the product boundary (spec 29, 09): runtime and funpack are separate products; the artifact file is the only sanctioned coupling and runtime/** must never link compiler internals. The copy carries a bit-identity OBLIGATION to the compiler kernel: fixed_mul shifts the i128 product back to Q32.32 via i128 DIVISION (not arithmetic shift) so it rounds toward zero; fixed_div shifts dividend up first; both round toward zero. sqrt/normalize stay kernel-evaluable-or-fail-closed. Rejected: a shared numerics package both products import — reintroduces the cross-product link the boundary forbids and couples runtime to compiler build order. Kept in agreement by a SHARED GOLDEN (input->exact bits) table asserted in both test suites — the audit root of the determinism thesis (10.5).\n\n2. SEAM ORDER (spec-driven): kernel -> artifact loader + in-memory tables -> world-as-database state read layer -> per-tick transaction fold -> engine.* resources + pure render. Kernel first: loader decodes Fixed literals, state layer compares/orders them, behaviors fold over them; nothing testable without a bit-exact Fixed. Loader second: tables are the substrate the state layer wraps. State layer third: View[T] stable-Id iteration, Ref->Option resolve, COW tick versions, singleton row-count-1. Tick transaction fourth: fold stages top-to-bottom, behavior once-per-instance in stable Id order, blackboard writes fold forward, synchronous in-pipeline-order signal route (Goal), spawn/despawn as one deterministic batch at the tick boundary, startup [Spawn] before tick 0. Resources+render last: Time fixed dt from 60hz, Input read-only resource (recording side is the sibling input epic), pure self->[Draw] producing the 20 draw-list as assertion ground truth.\n\n3. TARGET WORKLOAD: funpack-spec/examples/pong/src/pong.fun. NOTE pong models score as a single-instance thing Scoreboard, NOT a singleton — so singleton row-count-1 is implemented generically but pong exercises the ordinary-thing-single-instance path. Goal{side} is emitted in scoring by score on Ball, consumed downstream same-tick by tally on Scoreboard and serve on Ball — the canonical forward synchronous in-pipeline-order route.\n\n4. ARTIFACT BOUNDARY: runtime consumes the executable ARTIFACT format, distinct from the funpack team Index Contract (NDJSON governance, 29). Artifact format + golden fixtures come from the funpack EMISSION epic which lands first (stated boundary, not new discovery). The loader story surfaces a blocker if no golden artifact fixture exists when it starts. Runtime does NOT define the artifact format, does NOT record device input, does NOT implement replay re-fold." }
    - { id: 4, author: "ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7", created_at: "2026-06-05T19:15:50.493Z", body: "Input-layer story seams (decomposing the §23 input epic into runtime stories): the load-bearing ordering is snapshot-core-first, device-backend-last. (1) The pure device-free action-snapshot core — the Input resource query API (value/pressed/released/held/axis over PlayerId + role-kinded actions, all analog fixed-point in [-1,1]) plus the Input.empty/with_pressed/with_held/with_value/with_axis producer surface — lands FIRST because every other story and the snapshot itself are written in its vocabulary, and it is the seam the tick-fold execution epic resource interface consumes (§04 input-as-resource purity: Input is read-only, no Key/Pad/Mouse in sim code; §23 §5 any producer is interchangeable with the live engine). (2) Bindings resolution + edge/level coalescing over the inter-tick window reads the artifact bindings table and folds a deterministic injected raw-event queue into a snapshot; the settings rebinding-overlay (§23 §3) is stubbed to defaults — pong needs only Steer::Move axis bindings: keys_axis(W,S)/(Up,Down) + stick_y(Left), queried via input.value. Raw input enters via a HEADLESS injected-device-event queue first (deterministic + testable), NOT live polling. (3) Per-tick recording appends each resolved snapshot to a byte-stable replay log — the SOLE recorded nondeterminism source (§23 §4, §09 §5); the replay re-fold consumer is the separate determinism-acceptance epic, not this one. (4) The LIVE device backend (vendor:sdl2 polling) lands LAST and feeds the same injected-event-queue seam, because the deterministic contract is the snapshot. Rejected alternative: leading with the live SDL backend couples the determinism core to an impure non-testable boundary and inverts the dependency (the snapshot is the contract, devices are an interchangeable producer per §23 §5). Sibling boundaries: execution epic owns the tick loop + resource interface and lands first; this epic owns the Input resource + per-tick recording; the acceptance epic consumes the recorded log." }
    - { id: 2, author: "ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7", created_at: "2026-06-05T19:15:27.913Z", body: "Epic 'Replay re-fold and two-machine bit-identical determinism' (runtime-pong) decomposed into 4 stories. Seams: (1) Replay-log serialization — recorded per-tick action-snapshot log (sec23.4) gets a deterministic on-disk format; explicitly NOT the sec24 save/settings persistence layer (sec24 = sim-snapshot saves + per-machine settings; the replay log rides sec23.4's action-snapshot determinism record, not a save). (2) Replay re-fold driver — restart from artifact, re-feed recorded snapshots, re-fold the deterministic pipeline (sec07.4). (3) Deterministic frame digest — capture per-tick frame (committed fixed-point world state and/or sec20 draw-list, screenshot{include_drawlist}-style per sec28) as a byte-stable digest; the comparison surface, independent of the replay path. (4) Acceptance harness — proves live-run vs replay re-fold yield bit-identical frames AND a committed golden log re-folds to identical digest cross-build (mechanical two-machine proxy), with a gate criterion for a genuine second-machine operator run. Order: 1->2, 3 parallel, {2,3}->4. Input is the only nondeterminism source (no RNG); ground truth = the interpreter (sec09.5)." }
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

- Entries: 3
- [5] ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7: Runtime-pong execution epic split into 5 stories. Execution-model decisions + rationale (alternatives rejected):

1. KERNEL OWNERSHIP: runtime/** gets its OWN fixed-point kernel package, NOT a shared import of funpack/fixed.odin. Forced by the product boundary (spec 29, 09): runtime and funpack are separate products; the artifact file is the only sanctioned coupling and runtime/** must never link compiler internals. The copy carries a bit-identity OBLIGATION to the compiler kernel: fixed_mul shifts the i128 product back to Q32.32 via i128 DIVISION (not arithmetic shift) so it rounds toward zero; fixed_div shifts dividend up first; both round toward zero. sqrt/normalize stay kernel-evaluable-or-fail-closed. Rejected: a shared numerics package both products import — reintroduces the cross-product link the boundary forbids and couples runtime to compiler build order. Kept in agreement by a SHARED GOLDEN (input->exact bits) table asserted in both test suites — the audit root of the determinism thesis (10.5).

2. SEAM ORDER (spec-driven): kernel -> artifact loader + in-memory tables -> world-as-database state read layer -> per-tick transaction fold -> engine.* resources + pure render. Kernel first: loader decodes Fixed literals, state layer compares/orders them, behaviors fold over them; nothing testable without a bit-exact Fixed. Loader second: tables are the substrate the state layer wraps. State layer third: View[T] stable-Id iteration, Ref->Option resolve, COW tick versions, singleton row-count-1. Tick transaction fourth: fold stages top-to-bottom, behavior once-per-instance in stable Id order, blackboard writes fold forward, synchronous in-pipeline-order signal route (Goal), spawn/despawn as one deterministic batch at the tick boundary, startup [Spawn] before tick 0. Resources+render last: Time fixed dt from 60hz, Input read-only resource (recording side is the sibling input epic), pure self->[Draw] producing the 20 draw-list as assertion ground truth.

3. TARGET WORKLOAD: funpack-spec/examples/pong/src/pong.fun. NOTE pong models score as a single-instance thing Scoreboard, NOT a singleton — so singleton row-count-1 is implemented generically but pong exercises the ordinary-thing-single-instance path. Goal{side} is emitted in scoring by score on Ball, consumed downstream same-tick by tally on Scoreboard and serve on Ball — the canonical forward synchronous in-pipeline-order route.

4. ARTIFACT BOUNDARY: runtime consumes the executable ARTIFACT format, distinct from the funpack team Index Contract (NDJSON governance, 29). Artifact format + golden fixtures come from the funpack EMISSION epic which lands first (stated boundary, not new discovery). The loader story surfaces a blocker if no golden artifact fixture exists when it starts. Runtime does NOT define the artifact format, does NOT record device input, does NOT implement replay re-fold.
- [4] ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7: Input-layer story seams (decomposing the §23 input epic into runtime stories): the load-bearing ordering is snapshot-core-first, device-backend-last. (1) The pure device-free action-snapshot core — the Input resource query API (value/pressed/released/held/axis over PlayerId + role-kinded actions, all analog fixed-point in [-1,1]) plus the Input.empty/with_pressed/with_held/with_value/with_axis producer surface — lands FIRST because every other story and the snapshot itself are written in its vocabulary, and it is the seam the tick-fold execution epic resource interface consumes (§04 input-as-resource purity: Input is read-only, no Key/Pad/Mouse in sim code; §23 §5 any producer is interchangeable with the live engine). (2) Bindings resolution + edge/level coalescing over the inter-tick window reads the artifact bindings table and folds a deterministic injected raw-event queue into a snapshot; the settings rebinding-overlay (§23 §3) is stubbed to defaults — pong needs only Steer::Move axis bindings: keys_axis(W,S)/(Up,Down) + stick_y(Left), queried via input.value. Raw input enters via a HEADLESS injected-device-event queue first (deterministic + testable), NOT live polling. (3) Per-tick recording appends each resolved snapshot to a byte-stable replay log — the SOLE recorded nondeterminism source (§23 §4, §09 §5); the replay re-fold consumer is the separate determinism-acceptance epic, not this one. (4) The LIVE device backend (vendor:sdl2 polling) lands LAST and feeds the same injected-event-queue seam, because the deterministic contract is the snapshot. Rejected alternative: leading with the live SDL backend couples the determinism core to an impure non-testable boundary and inverts the dependency (the snapshot is the contract, devices are an interchangeable producer per §23 §5). Sibling boundaries: execution epic owns the tick loop + resource interface and lands first; this epic owns the Input resource + per-tick recording; the acceptance epic consumes the recorded log.
- [2] ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7: Epic 'Replay re-fold and two-machine bit-identical determinism' (runtime-pong) decomposed into 4 stories. Seams: (1) Replay-log serialization — recorded per-tick action-snapshot log (sec23.4) gets a deterministic on-disk format; explicitly NOT the sec24 save/settings persistence layer (sec24 = sim-snapshot saves + per-machine settings; the replay log rides sec23.4's action-snapshot determinism record, not a save). (2) Replay re-fold driver — restart from artifact, re-feed recorded snapshots, re-fold the deterministic pipeline (sec07.4). (3) Deterministic frame digest — capture per-tick frame (committed fixed-point world state and/or sec20 draw-list, screenshot{include_drawlist}-style per sec28) as a byte-stable digest; the comparison surface, independent of the replay path. (4) Acceptance harness — proves live-run vs replay re-fold yield bit-identical frames AND a committed golden log re-folds to identical digest cross-build (mechanical two-machine proxy), with a gate criterion for a genuine second-machine operator run. Order: 1->2, 3 parallel, {2,3}->4. Input is the only nondeterminism source (no RNG); ground truth = the interpreter (sec09.5).
