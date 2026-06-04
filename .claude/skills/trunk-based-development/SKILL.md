---
name: trunk-based-development
description: Trunk-based development discipline for funpack. Use before any branch create/merge, commit to main, or release tag; for risky/multi-day work (refactor, subsystem swap, Index Contract reshape); and whenever GitFlow, develop/release/hotfix branches, code freezes, unmerges, cherry-picks, or long-lived branches arise. Hybrid TBD, release-from-trunk fix-forward, stop-and-confirm tripwires.
---

# Trunk-Based Development

One trunk: `main`. It is always releasable. Everything below keeps those two sentences true.

## Repo policy — hybrid style

| Change | Path to main |
|---|---|
| Small, low-risk, validators green locally | Commit directly to `main` |
| Orchestrator/autopilot run | Run-machinery task branch + worktree, merged at run end |
| Risky, multi-step, or review-worthy | Short-lived branch: ≤2 days, single owner, deleted at merge |

## Rules (every path)

1. **Keep the build green.** Run all four validators locally and see them pass before any commit to main or merge into main: `odin check .`, `odin check . -vet -strict-style`, `odin test .`, comment-audit. The gate you run is the gate the orchestrator runs — verify the commit yourself, never push and let CI find out.
2. **A red main outranks everything.** If main breaks: revert the offending commit, or fix forward immediately when trivial. Until it is green, sync to the last green commit rather than HEAD, and start/stack/merge no new work onto it.
3. **Small commits.** Each commit is an incremental step that could go live alone; keep refactoring commits separate from functional commits. Delegate message crafting to the `commit` skill.
4. **Branch caps.** Lifetime ≤2 days; exactly one owner (one agent / one run); deleted at merge. Branch only off main, merge only back to main — never off or into another task branch, never land branch content anywhere but main.
5. **Freshen before merge.** Bring the branch up to date from main (merge or rebase), revalidate, merge to main, delete the branch. On multi-day runs, freshen from main at least daily.
6. **Incomplete work ships dark.** Gate it behind a flag (see Flags below) or an abstraction rather than parking it on a branch. funpack grammar-includes only what it can run: unfinished surfaces stay out of the emitted artifact.
7. **Releases are tags on main.** Fix forward on trunk. Cut no release branch until a concrete old-version support need exists; if one is ever cut, fix on main first, cherry-pick main→branch only, and delete the branch after its release leaves production (tag first — git GCs dangling commits).
8. **Immutable main; no freeze, no unmerge.** Every day is the same: no slowdown near releases, no backing commits out for scheduling (reorder with flags instead), no history rewrites of landed commits.

## Decision table

| Situation | Do this | Doctrine |
|---|---|---|
| Work won't finish today | Land what's green; gate the rest behind a flag | references/techniques.md |
| Refactor too big for one sitting | Branch by abstraction on main, not a long branch | references/techniques.md |
| Replace a subsystem | BbA (same process/language) or strangler routing at a seam | references/techniques.md |
| Index Contract / schema reshape | Expand → migrate → contract; every step green and shippable | references/techniques.md |
| Big rename/move plus rework | Rename-only commit first; rework in following commits | references/techniques.md |
| Story too big for a ≤2-day branch | Split it (INVEST, thin vertical slices); several branches may share one story | references/core-practices.md |
| Bug in a tagged release | Reproduce + fix on main, tag a new release; retroactive branch from the old tag only if a back-port is unavoidable | references/releases.md |
| Flag fully on and stable | Delete the flag, dead path, and abstraction; close its removal task | references/techniques.md |
| GitFlow / develop / env branches / second trunk requested | Tripwire — stop | references/anti-patterns.md |

## Tripwires — stop, state the conforming alternative, get explicit operator confirmation

Refuse by default; proceed only on explicit operator override. For each, the conforming move follows the dash:

1. Branch intended or likely to outlive 2 days → split the work, or BbA/flags on main.
2. Second concurrent owner on a branch → second branch off main, or pair on one workstation.
3. Commit/merge to main with any validator red or skipped → fix first; the build is the contract.
4. Bulk merge from a release branch (or anything) into main → only freshen-from-main and close-out merges exist.
5. Cherry-pick into main → fixes are born on main and flow outward; the rare cannot-reproduce-on-main case needs the operator to accept regression risk explicitly.
6. develop / release-train / environment branches, or a second trunk → rejected with rationale in references/anti-patterns.md.
7. Code freeze or unmerge → reorder releases with flags; a freeze signals the model is broken.
8. Tag or release from anything but green main → release-from-trunk is the policy.
9. Rewrite of main history (force-push, rebase of landed commits) → revert instead; history is append-only.

## How prove machinery maps onto TBD

| TBD concept | funpack incarnation |
|---|---|
| Short-lived feature branch | Orchestrator task branch + worktree (single agent owner) |
| Pre-integration verification (CI gate) | `.claude/.prove.json` validators — build/lint/test/llm phases |
| Continuous review | principal-architect review gate in full-mode runs |
| Patch review / merge queue | Orchestrator sequential merge of parallel wave branches |
| Run the build locally first | Validators inside the worktree before merge |

If hosted CI is ever added, it runs the same validator commands — the local gate and the bot gate never diverge.

## Flags in Odin

- **Build-time (preferred):** `ENABLE_X :: #config(ENABLE_X, false)` plus `when ENABLE_X { … }`. Gated code stays compiled and type-checked but is excluded from the artifact; determinism holds per artifact+config pair.
- **Runtime:** config consumed at boot, behind an abstraction chosen at the boot seam — not `if` checks scattered through call sites. Simulation-affecting flags are determinism inputs: same source + seed + flags ⇒ bit-identical.
- **Birth condition:** every flag gets a removal condition at birth (e.g. "delete when `pong` passes") and a scrum task to carry it — `claude-prove scrum task create --title "Remove flag ENABLE_X" --milestone <m>`. Validators stay green for every flag permutation the repo claims to support.

## References

Load on demand. Each is self-contained doctrine distilled from trunkbaseddevelopment.com (paul-hammant/tbd):

- `references/core-practices.md` — what TBD is; the three styles and their committer-count ranges; integration/review discipline; CI vs daemon; CD/Continuous Deployment; observed habits; deciding factors (story size, build speed, VCS speed, cadence).
- `references/releases.md` — release-from-trunk; branch-for-release cut late; cherry-pick directionality; merge meister; concurrent vs consecutive release development.
- `references/techniques.md` — feature flags (granularity, runtime persistence, CI fan-out, debt); branch by abstraction; strangulation; expand→migrate→contract; facilitating commits; story splitting.
- `references/scale-and-vcs.md` — monorepos and source-level dependency at HEAD; expanding/contracting checkouts; VCS comparison; 40 years of game changers; further reading.
- `references/anti-patterns.md` — the full "you're doing it wrong" catalog; the five broken-contract moves; why GitHub flow (near miss), GitFlow, mainline, cascade, and multi-trunk are rejected.
