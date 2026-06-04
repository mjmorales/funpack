<!-- prove:managed:start -->
# funpack

<!-- prove:plugin-version:3.1.0 -->
**Prove plugin v3.1.0** — if `claude-prove --version` does not match v3.1.0, run `/prove:update` to sync.


## Validation

Run before committing:

- **build**: `odin check .`
- **lint**: `odin check . -vet -strict-style`
- **test**: `odin test .`
- **llm**: `skill claude-skills:comment-audit`

## References

### claude-prove CLI Reference

@/Users/manuelmorales/.claude-envs/default/plugins/cache/prove/prove/3.1.0/references/claude-prove-reference.md

### Design Principles

@/Users/manuelmorales/.claude-envs/default/plugins/cache/prove/prove/3.1.0/references/design-principles.md

### Agent Routing Map

@/Users/manuelmorales/.claude-envs/default/plugins/cache/prove/prove/3.1.0/references/agent-routing.md

### Creator Conventions

@/Users/manuelmorales/dev/claude-prove/references/creator-conventions.md

### Interaction Patterns

@/Users/manuelmorales/dev/claude-prove/references/interaction-patterns.md

### LLM Coding Standards

@/Users/manuelmorales/dev/claude-prove/references/llm-coding-standards.md

### Prompt Engineering Guide

@/Users/manuelmorales/dev/claude-prove/references/prompt-engineering-guide.md

### Validation Config

@/Users/manuelmorales/dev/claude-prove/references/validation-config.md

## Prove Commands

- `/prove:brainstorm` — Explore options and record decisions
- `/prove:comprehend` — Socratic quiz on recent diffs to build code comprehension
- `/prove:index` — Update the file index (run after significant changes)
- `/prove:intake` — Render a charter/team/decompose HTML intake form, validate the pasted-back payload, and drive the one writer
- `/prove:orchestrator` — Unified entry point for orchestrator, autopilot, and full-auto execution
- `/prove:plan` — Plan a task or a specific step from the active plan.json
- `/prove:review-ui` — Docker-based review UI for inspecting prove runs, ACB intent groups, and verdicts
- `/prove:scrum` — Operate the scrum store backed by `.prove/prove.db` (tasks, milestones, tags, run-links)
- `/prove:workflow` — Run a milestone/task tree as parallel waves via orchestrator full-mode, mirroring status to scrum

<!-- prove:managed:end -->
