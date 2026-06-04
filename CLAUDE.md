<!-- prove:managed:start -->
# funpack

<!-- prove:plugin-version:3.3.2 -->
**Prove plugin v3.3.2** — if `claude-prove --version` does not match v3.3.2, run `/prove:update` to sync.


## Validation

Run before committing:

- **build**: `odin check .`
- **lint**: `odin check . -vet -strict-style`
- **test**: `odin test .`
- **llm**: `skill claude-skills:comment-audit`

## References

### claude-prove CLI Reference

@~/.claude-envs/pool/plugins/marketplaces/prove/references/claude-prove-reference.md

### Design Principles

@~/.claude-envs/pool/plugins/marketplaces/prove/references/design-principles.md

### Agent Routing Map

@~/.claude-envs/pool/plugins/marketplaces/prove/references/agent-routing.md

### Creator Conventions

@~/dev/claude-prove/references/creator-conventions.md

### Interaction Patterns

@~/dev/claude-prove/references/interaction-patterns.md

### LLM Coding Standards

@~/dev/claude-prove/references/llm-coding-standards.md

### Prompt Engineering Guide

@~/dev/claude-prove/references/prompt-engineering-guide.md

### Validation Config

@~/dev/claude-prove/references/validation-config.md

### Passive Triggers

@~/.claude-envs/pool/plugins/marketplaces/prove/references/passive-triggers.md

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
