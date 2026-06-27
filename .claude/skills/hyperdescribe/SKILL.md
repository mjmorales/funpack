---
name: hyperdescribe
description: Prune comments to near-zero and rewrite the code to be hyperdescriptive instead — names, types, and tests carry the intent so comments stop poisoning agents. Use to strip comments from a file or directory, drive a tree under the `eir comments` budget, run the comment-removal sweep, or make over-commented host/engine code self-documenting. Triggers on "prune comments", "strip comments", "remove the comments", "make this hyperdescriptive", "comment sweep", "near-zero comments", "decomment", "reduce comments", "sweep this dir for comments".
---

# hyperdescribe — prune comments, make the code speak for itself

Comments are debt: they consume the agent's context window, drift out of sync with the code beside them, and seed hallucinations downstream. The standard for host/engine source is **near-zero comments** (`docs/code-clarity.md`). This skill drives a file or directory to that standard WITHOUT changing behavior — it deletes the prose and re-invests its intent into better code (names, types, structure, tests), then proves nothing moved by keeping the build and tests exactly as green as before.

This is the operational arm of **Code Clarity — Near-Zero Comments**. The deterministic budget gate (`eir comments --max-comments N`) measures the debt; this skill pays it down.

## The invariant that makes this safe

Removing comments and renaming identifiers cannot change behavior. So a behavior change during a sweep means a bug was introduced. The skill turns that into a hard check:

> **green-after == green-before.** Capture a passing build + test BEFORE touching anything; after the sweep, the same build + test must pass identically. That equality is the proof that only comments and names moved. A red result means revert and redo — never ship a red sweep.

## Workflow (autonomous)

1. **Resolve scope.** A file, a directory, or "the next unswept directory." For the tree-wide sweep, consult `task comments-sweep -- <dir>` output (over-budget files, heaviest-first) and the comment-removal sweep scrum task for what remains. State the scope before acting; never widen it silently.
2. **Baseline-measure.** `./cmd/eir/eir comments <scope> --max-comments <N>` (default 5). The over-budget files are the work, heaviest first.
3. **Capture green.** Run the project's build and the scoped tests (`task build`; `task <pkg>:test`). Confirm they pass. If the tree is already red, STOP and fix that first — a dirty baseline makes a later failure unattributable.
4. **Strip mechanically.** `python3 .claude/skills/hyperdescribe/scripts/strip-comments.py <files...>`. The stripper is string-literal-aware: it preserves `//` inside `"..."`, backtick raw strings, and `'..'` (test fixtures embed comment-looking content), handles nested `/* */`, drops comment-only lines, trims trailing comments, and collapses blank runs. Never hand-strip with sed/regex — fixture `//` and nested block comments get mangled.
5. **Hyperdescriptive pass — the judgment core.** Re-read every function the strip touched. Where the code is now less than self-evident, FIX THE CODE, not the comment: rename to intention-revealing names, extract named constants/enums for magic values, split a long proc into named steps, make types explicit. The deleted comment's intent must survive in the code's shape — never as a re-added WHAT-narration line.
6. **Keep only irreducible WHY.** A note encoding a non-obvious invariant, a caller contract, a gotcha, or an alias to a known pattern that no name can carry — keep ONE terse line, within budget. Default to deleting; keep only after trying and failing to encode it in the code. The large rationales belong in ADRs/decision records, not inline.
7. **Prove no logic changed.** Re-run the build + tests from step 3. They MUST match the green baseline. On any failure, the rewrite broke something — `git checkout <file>` (or undo) and redo that file more carefully, one at a time. Never proceed red.
8. **Verify the budget.** `./cmd/eir/eir comments <scope> --max-comments <N>` → "no findings".
9. **Lock it in.** When a whole directory clears, add `./cmd/eir/eir comments <dir> --max-comments <N>` to the `eir-gate` task in `Taskfile.yml` so it stays clean, and annotate the sweep scrum task with what landed.

## Constraints

- Never delete an irreducible-WHY comment without first encoding it in a name, type, or test; instead, rewrite the code to carry it and keep a terse one-liner only if that fails.
- Never re-add WHAT-narration ("// loop over the items"); instead, rename and restructure until the line reads on its own.
- Never strip with sed/regex; instead, use the string-literal-aware stripper so fixture `//` and nested `/* */` survive.
- Never ship a sweep with red build/tests; instead, treat green-after == green-before as the proof of behavior-preservation, and revert+redo on any failure.
- Never touch generated files (`*.gen.odin`) or `.fun` source — `.fun` has no comments by design (`@doc`/`@gtag`/`@todo` carry that load).
- Never let formatting drift; instead, confirm `-strict-style` still passes (the stripper rstrips and collapses blanks, but verify).

## Failure handling

If tests cannot be made green after a careful, file-at-a-time redo, the removed comment marked behavior the code silently depended on (rare, e.g. a documented ordering or platform guard) — stop, restore the file, and surface the specific case rather than forcing it.

## References

- `docs/code-clarity.md` — the near-zero doctrine this skill enforces.
- `~/.claude-prove/latest/references/llm-coding-standards.md` — §1 naming, §3 explicitness: the positive practices the hyperdescriptive pass applies.
- ADR `2026-06-26-eir-comments-hard-budget-near-zero` — why a hard budget, why near-zero.
