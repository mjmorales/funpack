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
  count: 6
  live: 2
  recent:
    - { id: 9, author: "ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7", created_at: "2026-06-06T06:27:47.144Z", body: "Runtime determinism-contract boundary invariants (the durable residue of the\nruntime-pong epic decompositions; story sequencing and state snapshots dropped as\ntask-graph-owned).\n\nThe deterministic action-snapshot is the contract; devices are an interchangeable\nproducer. The Input resource is read-only (value/pressed/released/held/axis over\nPlayerId + role-kinded actions, analog fixed-point in [-1,1]); no Key/Pad/Mouse\nappears in sim code (§04, §23 §5). Raw input enters through a HEADLESS injected\ndevice-event queue — deterministic and testable — never live polling; the live\nvendor:sdl2 backend feeds that same injected-queue seam. Rejected: leading with the\nlive SDL backend, which couples the determinism core to an impure non-testable\nboundary and inverts the dependency (snapshot is the contract, the device is the\nreplaceable producer).\n\nInput AND the recorded tick-0 RNG seed are the determinism inputs — both ride the\ndeterminism record, neither is ambient, so same-inputs+seed → bit-identical holds\n(§01 §50/§60, §04 §1, §25 §60); ground truth is the interpreter (§09.5). The seed\nis RECORDED determinism input exactly as Input is: it is pinned in the replay log's\nv2 header (Replay_Identity.has_seed/seed) and the identity gate refuses a re-fold\nunder a different seed, so a seed change yields a different recorded identity (§01\n§50). A seedless game (pong, hunt — no RNG) carries has_seed=false and is the\nunchanged single-input case; a seeded game (snake — food spawn drawn from the seed)\ncarries the seed as the one additional recorded input. The byte-stable per-tick\nreplay log rides the §23.4 action-snapshot determinism record (now also carrying the\nseed); it is explicitly NOT the §24 persistence layer (§24 = sim-snapshot saves +\nper-machine settings). A deterministic per-tick frame digest (committed fixed-point\nworld state and/or the §20 draw-list, screenshot{include_drawlist}-style per §28) is\nthe comparison surface, independent of the replay path.\n\nRuntime ownership boundary: runtime consumes the executable ARTIFACT format\n(distinct from the funpack Index Contract NDJSON, §29); the artifact format and\ngolden fixtures come from the funpack emission side. Runtime does NOT define the\nartifact format, does NOT record device input as a save, and the replay re-fold\nconsumer is a separate acceptance concern from the recording side. Pong note: score\nis a single-instance thing Scoreboard, NOT a singleton — Goal{side} is emitted by\nscore on Ball and consumed same-tick by tally on Scoreboard and serve on Ball, the\ncanonical forward synchronous in-pipeline-order signal route.\n\nConsolidates runtime lore #2, #4, #5 (boundary/invariant residue; the\nkernel-copy-not-link invariant is promoted separately to the Codex). Supersedes the\nprior #7's \"Input is the SOLE nondeterminism source — no RNG\" clause, reconciled to\nadmit the recorded tick-0 RNG seed as a determinism input alongside Input (decision:\nthe tick-0 RNG seed is RECORDED determinism input, exactly as Input is)." }
    - { id: 8, author: "ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7", created_at: "2026-06-06T02:46:12.371Z", body: "Hunt-epic story decomposition: the runtime execution surface hunt adds over pong, and the build order that keeps the suite green at each merge.\n\nGAP INVENTORY (what runtime must build; everything else hunt needs already exists from pong).\n- engine.math length(v): NOT wired in eval_named_call (only abs/clamp/first/fold). The kernel math (vec2_length = fixed_sqrt(vec2_dot(v,v))) and vec2_normalize/sub/scale ALREADY exist in state.odin over the Q32.32 kernel; the only gap is the builtin dispatch. step_to's `delta * (speed / d)` already works: speed/d is Fixed/Fixed (fixed_div, divide-saturates per the kernel + §10.2), delta * Fixed is Vec2*scalar via apply_vec2_arith \"mul\" → vec2_scale. So ONLY `length` is missing on the call surface; step_to needs no new arithmetic.\n- input.axis(P1, Drive::Move) -> Vec2: NOT wired in eval_method_call (only `value` → eval_input_value). The snapshot reader axis(input,player,action)->Vec2 ALREADY exists in input.odin and the registry already mints Axis-kinded action ids (program.odin Action_Kind.Axis). Gap is one parallel dispatch arm eval_input_axis. drive's body multiplies the 2D axis Vec2 by P_SPEED*time.dt — Vec2*scalar, already supported.\n- visible()/first(view,pred): first already supports a predicate lambda (builtin_first, pong's paddle_bounce). The lambda body `length(p.pos - from) <= SIGHT` needs length (gap #1) + Vec2 sub + a field read off a Record element (p.pos) — all present once length lands. visible returns Option::Some(p.pos) where p is the matched Some payload (a Record_Value boxed by some_value); p.pos reads a Vec2 column. Works.\n- multi-thing population (two Hunters + one Player): tick.odin run_behavior_over_instances ALREADY iterates once per instance in stable Id order, and think reads View[Player] while folding Hunters. Mechanically present; needs a proving test, not new machinery. This is the multi-row surface pong (single Ball/Paddle) did not exercise.\n- countdown search_t - dt, t <= 0.0: plain Fixed sub/compare. Present.\n- render hunter_color match -> Color + Draw::Rect: record_color already maps Green/Red/White; Draw::Rect lowered in render.odin. Present.\n\nHAND-BUILT-FIXTURE STRATEGY (the artifact-before-artifact problem). The hunt ARTIFACT (testdata/hunt.artifact + hunt_golden.replay + hunt_golden.digest) is emitted by the sibling compiler epic (the blocker compile-snake-and-hunt). Runtime must NOT define the artifact format (Lore #7 ownership boundary). So early stories target interp/kernel/input surface with HAND-BUILT node-forest + View.of fixtures (the existing interp_test/state_test pattern builds Views and calls bodies directly), proving the engine arms before the artifact lands. The golden-fixture story is the ONLY one that consumes the emitted artifact, so it alone carries the cross-epic dependency at the leaf — earlier stories ship green on hand-built fixtures.\n\nBUILD ORDER. (1) length builtin — leaf kernel-surface gap, unblocks step_to/visible perception. (2) input.axis 2D method — independent leaf, unblocks player drive. (3) AI transition fold (think dispatch + patrol/chase/search/seek + multi-Hunter population over View[Player]) depends on length (perception). (4) golden hunt fixture extends the replay/digest harness — depends on ALL prior engine arms AND on the compiler-emitted hunt.artifact (the leaf where the cross-epic blocker bites). Render (hunter_color/Draw::Rect) folds into the AI-fold story's render assertion or the golden story since render already works — no standalone render story needed.\n\nDeterminism stays on the existing Input+Time floor (Lore #7): hunt has no RNG, no seed; the AI is a pure replay-stable fold, so the golden-digest story reuses the pong harness shape verbatim (live_capture vs committed-log re-fold, FUNPACK_REGEN_GOLDEN regen + operator gate) with a hunt artifact swapped in." }
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

- Entries: 6 (2 live)
- [9] ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7: Runtime determinism-contract boundary invariants (the durable residue of the
runtime-pong epic decompositions; story sequencing and state snapshots dropped as
task-graph-owned).

The deterministic action-snapshot is the contract; devices are an interchangeable
producer. The Input resource is read-only (value/pressed/released/held/axis over
PlayerId + role-kinded actions, analog fixed-point in [-1,1]); no Key/Pad/Mouse
appears in sim code (§04, §23 §5). Raw input enters through a HEADLESS injected
device-event queue — deterministic and testable — never live polling; the live
vendor:sdl2 backend feeds that same injected-queue seam. Rejected: leading with the
live SDL backend, which couples the determinism core to an impure non-testable
boundary and inverts the dependency (snapshot is the contract, the device is the
replaceable producer).

Input AND the recorded tick-0 RNG seed are the determinism inputs — both ride the
determinism record, neither is ambient, so same-inputs+seed → bit-identical holds
(§01 §50/§60, §04 §1, §25 §60); ground truth is the interpreter (§09.5). The seed
is RECORDED determinism input exactly as Input is: it is pinned in the replay log's
v2 header (Replay_Identity.has_seed/seed) and the identity gate refuses a re-fold
under a different seed, so a seed change yields a different recorded identity (§01
§50). A seedless game (pong, hunt — no RNG) carries has_seed=false and is the
unchanged single-input case; a seeded game (snake — food spawn drawn from the seed)
carries the seed as the one additional recorded input. The byte-stable per-tick
replay log rides the §23.4 action-snapshot determinism record (now also carrying the
seed); it is explicitly NOT the §24 persistence layer (§24 = sim-snapshot saves +
per-machine settings). A deterministic per-tick frame digest (committed fixed-point
world state and/or the §20 draw-list, screenshot{include_drawlist}-style per §28) is
the comparison surface, independent of the replay path.

Runtime ownership boundary: runtime consumes the executable ARTIFACT format
(distinct from the funpack Index Contract NDJSON, §29); the artifact format and
golden fixtures come from the funpack emission side. Runtime does NOT define the
artifact format, does NOT record device input as a save, and the replay re-fold
consumer is a separate acceptance concern from the recording side. Pong note: score
is a single-instance thing Scoreboard, NOT a singleton — Goal{side} is emitted by
score on Ball and consumed same-tick by tally on Scoreboard and serve on Ball, the
canonical forward synchronous in-pipeline-order signal route.

Consolidates runtime lore #2, #4, #5 (boundary/invariant residue; the
kernel-copy-not-link invariant is promoted separately to the Codex). Supersedes the
prior #7's "Input is the SOLE nondeterminism source — no RNG" clause, reconciled to
admit the recorded tick-0 RNG seed as a determinism input alongside Input (decision:
the tick-0 RNG seed is RECORDED determinism input, exactly as Input is).
- [8] ct-runtime-seat-b73afa5e-3001-4ee2-a941-e0a16a8f66b7: Hunt-epic story decomposition: the runtime execution surface hunt adds over pong, and the build order that keeps the suite green at each merge.

GAP INVENTORY (what runtime must build; everything else hunt needs already exists from pong).
- engine.math length(v): NOT wired in eval_named_call (only abs/clamp/first/fold). The kernel math (vec2_length = fixed_sqrt(vec2_dot(v,v))) and vec2_normalize/sub/scale ALREADY exist in state.odin over the Q32.32 kernel; the only gap is the builtin dispatch. step_to's `delta * (speed / d)` already works: speed/d is Fixed/Fixed (fixed_div, divide-saturates per the kernel + §10.2), delta * Fixed is Vec2*scalar via apply_vec2_arith "mul" → vec2_scale. So ONLY `length` is missing on the call surface; step_to needs no new arithmetic.
- input.axis(P1, Drive::Move) -> Vec2: NOT wired in eval_method_call (only `value` → eval_input_value). The snapshot reader axis(input,player,action)->Vec2 ALREADY exists in input.odin and the registry already mints Axis-kinded action ids (program.odin Action_Kind.Axis). Gap is one parallel dispatch arm eval_input_axis. drive's body multiplies the 2D axis Vec2 by P_SPEED*time.dt — Vec2*scalar, already supported.
- visible()/first(view,pred): first already supports a predicate lambda (builtin_first, pong's paddle_bounce). The lambda body `length(p.pos - from) <= SIGHT` needs length (gap #1) + Vec2 sub + a field read off a Record element (p.pos) — all present once length lands. visible returns Option::Some(p.pos) where p is the matched Some payload (a Record_Value boxed by some_value); p.pos reads a Vec2 column. Works.
- multi-thing population (two Hunters + one Player): tick.odin run_behavior_over_instances ALREADY iterates once per instance in stable Id order, and think reads View[Player] while folding Hunters. Mechanically present; needs a proving test, not new machinery. This is the multi-row surface pong (single Ball/Paddle) did not exercise.
- countdown search_t - dt, t <= 0.0: plain Fixed sub/compare. Present.
- render hunter_color match -> Color + Draw::Rect: record_color already maps Green/Red/White; Draw::Rect lowered in render.odin. Present.

HAND-BUILT-FIXTURE STRATEGY (the artifact-before-artifact problem). The hunt ARTIFACT (testdata/hunt.artifact + hunt_golden.replay + hunt_golden.digest) is emitted by the sibling compiler epic (the blocker compile-snake-and-hunt). Runtime must NOT define the artifact format (Lore #7 ownership boundary). So early stories target interp/kernel/input surface with HAND-BUILT node-forest + View.of fixtures (the existing interp_test/state_test pattern builds Views and calls bodies directly), proving the engine arms before the artifact lands. The golden-fixture story is the ONLY one that consumes the emitted artifact, so it alone carries the cross-epic dependency at the leaf — earlier stories ship green on hand-built fixtures.

BUILD ORDER. (1) length builtin — leaf kernel-surface gap, unblocks step_to/visible perception. (2) input.axis 2D method — independent leaf, unblocks player drive. (3) AI transition fold (think dispatch + patrol/chase/search/seek + multi-Hunter population over View[Player]) depends on length (perception). (4) golden hunt fixture extends the replay/digest harness — depends on ALL prior engine arms AND on the compiler-emitted hunt.artifact (the leaf where the cross-epic blocker bites). Render (hunter_color/Draw::Rect) folds into the AI-fold story's render assertion or the golden story since render already works — no standalone render story needed.

Determinism stays on the existing Input+Time floor (Lore #7): hunt has no RNG, no seed; the AI is a pure replay-stable fold, so the golden-digest story reuses the pong harness shape verbatim (live_capture vs committed-log re-fold, FUNPACK_REGEN_GOLDEN regen + operator gate) with a hunt artifact swapped in.
