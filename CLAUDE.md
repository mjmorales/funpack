<!-- prove:managed:start -->
# funpack

<!-- prove:plugin-version:4.3.2 -->
**Prove plugin v4.3.2** — if `claude-prove --version` does not match v4.3.2, run `/prove:update` to sync.


## Structure

- `cmd/` — Go CLI entry points
- `docs/` — Documentation
- `spec/` — Test specifications

## Validation

Run before committing:

- **build**: `task build`
- **lint**: `task lint`
- **test**: `task test`
- **llm**: `skill claude-skills:comment-audit`
- **llm**: `prompt ci/prompts/engine-api-doc-parity.md`

## Discovery Protocol

Before broad Glob/Grep searches, check the file index first:

- `claude-prove cafi context` — full index with routing hints
- `claude-prove cafi lookup <keyword>` — search by keyword

Only fall back to Glob/Grep when the index doesn't cover what you need.
## Team Agents

Role-bound team agents registered in `.claude/agents/`:

- **devtools**: `team-devtools-tech_lead`, `team-devtools-engineer`, `team-devtools-implementer`
- **funpack**: `team-funpack-tech_lead`, `team-funpack-engineer`, `team-funpack-implementer`
- **runtime**: `team-runtime-tech_lead`, `team-runtime-engineer`, `team-runtime-implementer`

Dispatch and memory protocol:

- For subagent work that falls inside a team's scope, dispatch that team's role agent — never a general-purpose agent. Resolve scope from each team's bundle `teams/<slug>.md`; use a general-purpose agent only when no team's bundle scope covers the task.
- Every dispatched team agent must honor its memory protocol: read its team bundle `teams/<slug>.md` (scope, roster, recent Lore) before acting, and record what it learns:
  - seat notes with `claude-prove scrum annotation add --target-kind team --target <team-slug> --body <text> --author <CT-UUID>`
  - team Lore with `claude-prove scrum lore record <team-slug> --body <text> --author <CT-UUID>` (tech_lead seat; non-lead seats route journal-worthy findings to a seat annotation instead)
  - durable decisions with `claude-prove scrum decision record <path> --kind adr`

## References

### claude-prove CLI Reference

@.claude/prove-plugin/references/claude-prove-reference.md

### Design Principles

@.claude/prove-plugin/references/design-principles.md

### Agent Routing Map

@.claude/prove-plugin/references/agent-routing.md

### Creator Conventions

@~/.claude-prove/latest/references/creator-conventions.md

### Interaction Patterns

@~/.claude-prove/latest/references/interaction-patterns.md

### LLM Coding Standards

@~/.claude-prove/latest/references/llm-coding-standards.md

### Prompt Engineering Guide

@~/.claude-prove/latest/references/prompt-engineering-guide.md

### Validation Config

@~/.claude-prove/latest/references/validation-config.md

### Passive Triggers

@~/.claude-prove/latest/references/passive-triggers.md

## Prove Commands

- `/prove:brainstorm` — Explore options and record decisions
- `/prove:compact` — Anchor session context into prove primitives pre-compact and rehydrate post-compact
- `/prove:comprehend` — Socratic quiz on recent diffs to build code comprehension
- `/prove:index` — Update the file index (run after significant changes)
- `/prove:intake` — Render a charter/team/decompose HTML intake form, validate the pasted-back payload, and drive the one writer
- `/prove:orchestrator` — Unified entry point for orchestrator, autopilot, and full-auto execution
- `/prove:plan` — Plan a task or a specific step from the active plan.json
- `/prove:review-ui` — Loopback review UI for inspecting prove runs, ACB intent groups, and verdicts
- `/prove:scrum` — Operate the scrum store backed by `.prove/prove.db` (tasks, milestones, tags, run-links)
- `/prove:workflow` — Run a milestone/task tree as parallel waves via orchestrator full-mode, mirroring status to scrum

<!-- prove:managed:end -->

## Odin-First Dependency Policy

For backend engine work, exhaust what Odin ships before writing anything new:

- Before implementing any engine subsystem or utility (allocators, containers, math, serialization, platform/IO, asset loading, windowing, input), check Odin built-ins, `core:` stdlib packages, and `vendor:` libraries — in that order — and use the existing solution when one covers the need.
- Never reimplement functionality Odin already provides; instead, wrap or extend the existing `core:`/`vendor:` package and document the gap that forced the extension.
- When no built-in, `core:`, or `vendor:` option fits, state that verification in one line before writing the custom implementation or adding an external dependency.

## CAFI Index Description Dispatch

Dispatch `/prove:index` describe-batch subagents on the **haiku** model at **medium** effort — routing-hint descriptions are short formulaic read-and-summarize work haiku covers fully. Use the Agent tool, or the Workflow tool for batches over 50 files.

- Keep these batches on haiku/medium; instead of escalating to a larger model or higher effort, split an oversized batch into more sub-batches.
- Scope: `/prove:index` describe fan-outs only. Dispatch every other agent in this project at its normal model and effort.

## Surface Friction, Never Work Around It

When the engine's contracts, the language's semantics, or the spec's normative text resist your implementation, that resistance is a stop-and-escalate signal — not an obstacle to route around. Before writing any code, bubble it up for a first-principles review with the operator. Three named instances, each a `never`/`instead`:

- Never codify a contradiction into engine semantics to make a fixture pass; instead, surface the contradiction and resolve it at the source.
- Never loosen a gate to force a case through; instead, escalate the gate conflict and review whether the case or the gate is wrong.
- Never special-case around a spec clause; instead, raise the clause for review and align the implementation with its corrected normative intent.


## Triaged Decisions — Route Through AskUserQuestion

When you have analyzed a decision point and narrowed it to discrete options, present it through the `AskUserQuestion` tool, never as free-form prose.

- **Tool, not prose**: For any pre-analyzed decision with discrete options, call `AskUserQuestion`; instead of narrating the choices in text, surface them as selectable options.
- **Recommendation first**: List your recommended option first and mark it `(Recommended)`; instead of presenting a neutral menu, lead with the choice your analysis favors.
- **Every description states why**: Each option's description must give the tradeoff or consequence of choosing it; instead of restating what the option does, explain why one would pick it.

## Tests and Fixes Are Foundational — No Workarounds, No Record-Keeping Tests

Ship the durable fix and the deliberate test, never the stop-gap or the note-to-self.

- When a decision, ADR, or bug touches a real seam that will cause user friction, fix it at the source; never ship an incomplete workaround that leaves the seam broken.
- Write tests that exercise foundational junctions of real code as a living, evolving spec of the language; never write narrowly bug-specific or record-keeping tests (e.g. a "fixes" scratch file), and instead fold the case into the deliberate test that covers its junction.
- Treat tests as load-bearing spec, not lesser notes; never use a test to log a fix or stand in for a record, and instead capture record-keeping in a scrum task, decision, or ADR.

## Corpus-Pin Gate — Markdown Edits Have Odin-Test Consequences

`funpack mcp gen-corpus` embeds the `plugins/funpack/`, `spec/`, and `stdlib/engine/` trees into committed docs-corpus shards (`cmd/funpack/mcp/corpus/{spec,engine,plugin}.json` + `manifest.json`). A drift test (`test_corpus_pin_*`, run by `task test` / `task cmd:docs-check`) byte/hash-compares a fresh regeneration against the committed shards, so any edit to those trees — including non-Odin files like `SKILL.md` or other markdown — fails `task test` until the shards are regenerated.

- Before committing any change touching `plugins/funpack/`, `spec/`, or `stdlib/engine/`, run `task test` (or at minimum the focused `task cmd:docs-check`).
- Never skip the test validator assuming a markdown/non-Odin diff is inert; instead, treat the test validator as in-scope for every change to those three trees.
- When the gate flags drift, run `task docs-regen` and recommit the regenerated shards.
- Shard regen has two triggers, kept distinct (ADR `2026-06-19-corpus-regen-rides-version-bump`):
  - **Content regen** — you edited a `SKILL.md`/spec/engine doc and the byte/hash pin flagged drift. Run `task docs-regen` and land the regenerated shards WITH the edit that caused them, labeled `chore` (the shards live under `cmd/funpack/`, the binary release line, so a `feat`/`fix` label would spuriously bump the binary). Never a deferred trailing commit.
  - **Version regen** — the corpus stamps the funpack version, so when `VERSION` bumps the corpus must restamp. This rides the release pipeline's own `chore(release): vX [skip ci]` commit, which regenerates/restamps `cmd/funpack/mcp/corpus/*` alongside the new `VERSION` so a tagged binary never embeds an older corpus. The parity gate `test_corpus_pin_version_matches_compiler` enforces it: a `VERSION`↔`corpus_version` skew fails `task test`.

## Defend Against Stale-funpack Priors — Maintain the Prior-Defense Layer

A capable model has trained on the public (old) funpack and on Lua/GDScript/Rust/JS/Python/ECS/OOP, so it reaches for deprecated or foreign forms. The agent-facing docs carry a standing defense; its maintenance compounds — every breaking form change widens the stale prior, so the table must grow with the language.

- On any breaking funpack syntax/form change, add a `plugins/funpack/skills/funpack-language/references/anti-priors.md` row pairing old-or-foreign form → current form → Origin in the same change. Never ship the form change without the row; instead treat the row as part of the change's definition of done — the table is corpus-embedded, so regenerate the shards (`task cmd:docs-regen`) and land them with the edit.
- When the language or runtime model changes, re-align the three prior-defense surfaces to match it — never let them drift from the canonical skills; instead update in lockstep: the `funpack-author` translate-from-known-language on-ramp and its structural-budget escape hatches, the `funpack-game-model` effect-closure worked example (rejected vs closed pair), and the `funpack-reviewer` static-reach scoping (Grep the project before asserting an unclosed signal; downgrade an unconfirmable finding to a Risk, not a Blocker).
- Two further levers — prompt-caching the invariant MCP docs prefix (anti-priors + grammar + prelude) and GBNF grammar-constrained decoding off the LL(1) grammar for a local-model phase — are tracked-but-unimplemented per decision `frontier-first-agent-prior-defense`. Do not rediscover or re-propose them; instead read that decision for the rationale before touching either.
