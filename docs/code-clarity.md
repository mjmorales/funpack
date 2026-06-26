# Code Clarity — Comments Are the Exception

Host and engine source must read on its own: future agents should spend context on the code, not on commentary that restates it or rots beside it. A comment earns its place only when it carries signal the code cannot.

Scope: this governs host/engine source — Odin under `cmd/`, the `runtime/` tree, and any Go CLI code. The `.fun` language has no comments by design (`@doc`/`@gtag`/`@todo` directives carry that load) and is out of scope here.

- **Make the code legible first.** Named constants and enums over magic ints/strings; intention-revealing variable and function names; idiomatic, flat structure. For the positive practices, see `references/llm-coding-standards.md` (§1 naming, §3 explicitness, §6 comments) — do not restate them here.
- Never narrate WHAT the code does; instead, rename or restructure until the line reads on its own.
- Never leave temporal or authorship tells ("for now", "previously", "in a real impl"); instead, encode durable intent or delete the note.
- Never let a cross-reference rot; instead, drop the stale ref and state the invariant where it holds.
- **Keep the comment the code cannot speak:** a WHY behind a non-obvious choice, an invariant the caller must uphold, a non-obvious tradeoff, or an alias to a known pattern. These survive; everything else is deleted, not rewritten.
- **The `comment-audit` gate backs this.** `claude-skills:comment-audit` (a `phase: llm` validator) runs before every commit and fails on comment smell — write to pass it.
