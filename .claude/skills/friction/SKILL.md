---
name: friction
description: Triage and resolve the funpack friction log. Use to process ./friction — the dogfood findings (bugs, crashes, missing features, DX-friction) captured while building games. Reconciles each report into the scrum store (find-or-create a tracked task, route it to the owning team) and then drives the durable root-cause fix to done. Triggers on "process the friction", "triage friction", "work the friction log", "fix the friction reports", "reconcile friction with scrum", "bubble up the friction", "friction skill", "go through ./friction".
---

# friction — triage and resolve the funpack friction log

`./friction/NNNN-*.md` is the dogfood friction log: findings an agent or operator hit while
building real games, each captured *with* the workaround they took to keep moving. This skill
closes the loop the workaround left open — it bubbles every finding into a tracked scrum task
and then ships the durable fix at the source. It is the operational arm of the project's
**Surface Friction, Never Work Around It** and **No Workarounds** doctrines: a friction report
is a recorded workaround awaiting its root-cause fix.

Run the three phases in order. Phase 2 is mechanical and safe (it only writes scrum + the
report's own bookkeeping fields). Phase 3 changes engine source — gate it on the operator.

## The report contract

Each `friction/NNNN-<slug>.md` is YAML frontmatter + prose sections. Read both.

| Field | Meaning | This skill writes |
|---|---|---|
| `id` | zero-padded ordinal (sparse — gaps are normal) | never |
| `title` | one-line summary | never |
| `funpack_version` | toolchain when encountered | never |
| `game` | dogfood game that surfaced it (may be empty) | never |
| `category` | `bug` · `crash` · `missing-feature` · `dx-friction` | never |
| `severity` | `high` · `medium` · `low` | never |
| `component` | subsystem path (`compiler/check`, `stdlib/engine.rand`, `mcp:inspect_state`) | never |
| `upstream` | **link-of-record** — tracking state (see lifecycle) | Phase 2 + 3 |
| `sovereign` | repro confidence (`unverified` → resolved) | Phase 3 |
| `encountered` | date | never |

Prose sections: **What I was doing**, **Minimal repro**, **Expected**, **Actual**,
**Workaround**, **Notes**. The **Expected** section is the acceptance criterion; the **Minimal
repro** is the reproduction harness and the regression test's seed; the **Workaround** is the
debt this skill retires. `[[NNNN]]` links cross-reference sibling reports — some targets won't
exist as files yet; treat a dangling link as a note, never an error.

### `upstream` lifecycle (append-only, idempotent)

```
not-bubbled  ──Phase 2──▶  tracked:<task-id>  ──Phase 3──▶  fixed:<task-id>@<sha>
                                   │
                                   └──Phase 3 gate──▶  escalated:<task-id>   (awaiting operator decision)
                                   └──operator says──▶  wontfix:<task-id>     (not a defect / by design)
```

Never blank a populated `upstream`. Each transition resolves the prior placeholder into a more
concrete pointer; re-running the skill reads this field to skip already-tracked work.

### `sovereign` lifecycle

`unverified` is the dogfood author's claim, untested by this skill. Phase 3's reproduce-first
step resolves it: `reproduced` (confirmed at HEAD), `reproduced-across-rebuilds` (deterministic,
binary-independent), or `not-reproduced` (cannot reproduce → do not fix blindly; route to the
operator). Trust a report's claim only after you have re-run its repro yourself.

## Phase 1 — Inventory

Read every `friction/*.md`. Parse the frontmatter and the prose sections into a working list,
ordered for Phase 3 by: `crash`/`severity: high` first, then `sovereign: reproduced-across-rebuilds`
(engine bugs independent of any game) ahead of game-specific findings. Do not skip reports whose
`upstream` is already `tracked:`/`fixed:` — list them so reconciliation stays idempotent, but they
need no new task.

## Phase 2 — Reconcile with scrum (find-or-create, never duplicate)

For each report, resolve it to exactly one scrum task in this precedence order — stop at the
first hit:

1. **Already linked.** `upstream: tracked:<id>` / `fixed:<id>` → load that task, confirm it
   still exists, reconcile its fields. No new task.
2. **Tag match.** A task carries tag `friction-<id>` → that is the task. Backfill the
   `upstream` link if missing.
3. **Semantic match (judgment — confirm, don't guess).** Run `claude-prove scrum task list`
   and `claude-prove scrum status --human`; search by `component` keyword and title. Several
   backlog tasks already cover friction-adjacent surface (the `f10-*` surface-parity line, the
   `funpack-check-*` diagnostics line, the `full-stdlib-surface-parity` post-friction task). If
   a candidate plausibly *is* this finding, do **not** auto-link a near-miss — present the
   candidate(s) and the report through `AskUserQuestion` (link to existing vs. create new). A
   wrong link buries the finding; a wrong duplicate fragments the work.
4. **No match → create.** Mint the task with an explicit `friction-<id>` id (clean
   `upstream:` link, idempotent re-runs) and bind it to the owning team and milestone in the
   one create call; tags are a separate verb (`--tag` is not a create flag):

```sh
claude-prove scrum task create --id "friction-<id>" \
  --title "<report title>" \
  --description "Friction <id> (friction/NNNN-<slug>.md). <Actual> in one line, plus the durable fix direction. Root-cause fix, not the report's workaround." \
  --milestone <owning milestone> --team <owning team>
claude-prove scrum task tag "friction-<id>" friction
claude-prove scrum task tag "friction-<id>" "<category>"
```

Capture **Expected** as the task description's fix-direction line now. Do **not** synthesize an
acceptance criterion here: `task acceptance add` requires a runnable `--check`, and the repro
needs a fixture (probe `.fun`, a `games/` tree, an MCP session) that does not yet exist as
committed state — a fabricated check is the record-keeping artifact the project forbids. The
real criterion (`--check "<regression-test invocation>"`) is added in **Phase 3**, once the
test that folds in the repro exists. `--bounds` is an agent write-scope
(`{read?,write?,tools?,budgets?}`), not a metadata bag — set it in Phase 3 only to confine the
fixing agent to the team's tree; never to stash the repro path.

Then **flip the report**: edit its frontmatter `upstream: not-bubbled` →
`upstream: tracked:<task-id>`. Editing `friction/*.md` is safe — `friction/` is **not** in the
docs-corpus embed scope (`plugins/funpack/`, `spec/`, `stdlib/engine/`), so no `docs-regen` is
owed. Confirm with `task cmd:docs-check` only if you are unsure.

Mechanical scrum writes go through the CLI directly. Route judgment writes — a status
transition with tradeoffs, linking to a near-miss task, reopening a `done` task — through the
`scrum-master` agent.

### Routing: `component` → owning team

Dispatch the **team role agent**, never a general-purpose agent (project CLAUDE.md). Resolve
scope from `teams/<slug>.md`.

| `component:` prefix | Team | Writes | Dispatch |
|---|---|---|---|
| `compiler/*` (check, build, frontend, surface, eval) | **funpack** | `funpack/**` | `team-funpack-*` |
| `stdlib/engine.*`, runtime exec, fixed-point sim | **runtime** | `runtime/**` | `team-runtime-*` |
| `mcp:*`, `plugin*`, docs index, dev tooling | **devtools** | `mcp/**`, `plugins/funpack/**`, `cmd/funpack/mcp*` | `team-devtools-*` |

A finding spanning two surfaces (e.g. a stdlib symbol *declared* in the compiler surface but
*absent* from runtime) gets one task with a dep edge between the two teams' sub-tasks — encode
the build order with `claude-prove scrum task add-dep <blocker> <blocked>`, never leave
sequencing in prose.

## Phase 3 — Systematically correct (root cause, gated)

Drive the ordered list to done. Per report, dispatch the owning team agent to run this loop;
the agent records its work through the prove CLI under its `PROVE_AGENT` seat.

1. **Reproduce first.** Run the **Minimal repro** at HEAD. Confirm the failure before touching
   code, then write the result back to `sovereign:` — `reproduced` for a single confirmed run,
   `reproduced-across-rebuilds` once it holds deterministically across a rebuild,
   `not-reproduced` if it never fires. On `not-reproduced`, stop — surface that to the operator;
   never invent a fix for a finding you cannot trigger.
2. **Fix the root cause.** Implement the durable fix the design calls for — never the report's
   workaround, never a symptom patch, never a gate-loosen to force the case through. For any new
   engine utility, honor the Odin-first policy: exhaust Odin built-ins / `core:` / `vendor:`
   before writing anything custom.
3. **STOP-and-escalate on contradiction.** If the fix requires resolving a spec/contract
   contradiction — the finding asks a normative question the code can't settle (e.g. friction
   0001: *is `(Self, Rng)` a legal update shape, or is the diagnostic merely wrong?*) — do not
   codify a guess into engine semantics. Set `upstream: escalated:<task-id>`, mark the task
   `blocked` with the blocker noted, and put the resolved options to the operator through
   `AskUserQuestion` (recommendation first, each option stating its consequence). Resume only on
   the operator's call.
4. **Add the deliberate test, then pin it as the acceptance criterion.** Fold the **Minimal
   repro** into the test that covers its foundational junction — a living spec entry, not a
   bug-specific scratch test or a record-keeping file. Now that a runnable check exists, record
   it: `claude-prove scrum task acceptance add <task-id> --text "<Expected>" --check "<the
   regression-test invocation>"` (this is the criterion Phase 2 deferred).
5. **Run the full validator gate.** `task build` · `task lint` · `task test` ·
   `skill claude-skills:comment-audit`. The gate you run is the gate CI runs. If the change
   touched `plugins/funpack/`, `spec/`, or `stdlib/engine/`, run `task cmd:docs-regen` and
   commit the regenerated shards (labeled `chore`) per the corpus-pin rule.
6. **Verify the acceptance criterion.** Re-run the repro: it must now satisfy **Expected**.
   Record the verdict: `claude-prove scrum task acceptance verify <task-id> --verdict verified`.
7. **Close the loop.** Move the task `done`, write a `synthesis` reasoning-log entry on its run
   (story-close floor), and set `upstream: fixed:<task-id>@<sha>`. Commit via the `commit`
   skill (conventional commit, correct scope). Land on `main` per the
   `trunk-based-development` skill — small commits, green before merge.

Capture anything discovered mid-fix (a second defect, a spec gap, a follow-up) as its own scrum
task immediately — a clean break means the store alone must carry the context forward.

## Idempotency & re-runs

Safe to re-run at any time. Phase 1 re-reads the log; Phase 2 skips reports already `tracked:`/
`fixed:` and only reconciles drifted fields; Phase 3 skips `fixed:` reports and resumes
`escalated:` ones once the operator has decided. A new dogfood report (`upstream: not-bubbled`)
dropped into `friction/` is picked up on the next run with no extra wiring.
