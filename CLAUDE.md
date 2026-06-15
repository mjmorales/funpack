<!-- prove:managed:start -->
# funpack

<!-- prove:plugin-version:4.2.1 -->
**Prove plugin v4.2.1** — if `claude-prove --version` does not match v4.2.1, run `/prove:update` to sync.


## Structure

- `docs/` — Documentation

## Validation

Run before committing:

- **build**: `task build`
- **lint**: `task lint`
- **test**: `task test`
- **llm**: `skill claude-skills:comment-audit`

## Discovery Protocol

Before broad Glob/Grep searches, check the file index first:

- `claude-prove cafi context` — full index with routing hints
- `claude-prove cafi lookup <keyword>` — search by keyword

Only fall back to Glob/Grep when the index doesn't cover what you need.
## Team Agents

Role-bound team agents registered in `.claude/agents/`:

- **funpack**: `team-funpack-tech_lead`, `team-funpack-engineer`, `team-funpack-implementer`
- **runtime**: `team-runtime-tech_lead`, `team-runtime-engineer`, `team-runtime-implementer`

Dispatch and memory protocol:

- For subagent work that falls inside a team's scope, dispatch that team's role agent — never a general-purpose agent. Resolve scope from each team's bundle `teams/<slug>.md`; use a general-purpose agent only when no team's bundle scope covers the task.
- Every dispatched team agent must honor its memory protocol: read its team bundle `teams/<slug>.md` (scope, roster, recent Lore) before acting, and record what it learns:
  - seat notes with `claude-prove scrum annotation add --target-kind team`
  - team Lore with `claude-prove scrum lore record` (tech_lead seat; non-lead seats route journal-worthy findings to a seat annotation instead)
  - durable decisions with `claude-prove scrum decision record`

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
