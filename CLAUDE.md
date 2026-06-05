<!-- prove:managed:start -->
# funpack

<!-- prove:plugin-version:3.8.0 -->
**Prove plugin v3.8.0** — if `claude-prove --version` does not match v3.8.0, run `/prove:update` to sync.


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
