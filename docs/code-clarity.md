# Code Clarity — Near-Zero Comments, Hyperdescriptive Code

Comments are debt. They consume the agent's context window, drift out of sync with the code beside them, and seed hallucinations in every downstream agent that reads them. The standard for host/engine source is therefore **near-zero comments**: intent lives in hyperdescriptive names, precise types, small well-named functions, named constants and enums, and tests — never in prose that restates or annotates the code.

Scope: all host/engine source — the Odin under `cli/`, `funpack/`, `runtime/`, `cmd/`, and `eir/`, and any Go CLI code. The `.fun` language has no comments by design (`@doc`/`@gtag`/`@todo` directives carry that load) and is out of scope here.

- **Encode intent in the code, not beside it.** Before writing a comment, rename, split, or restructure until the code reads on its own. A comment is the last resort, used only when no name, type, or test can carry the meaning.
- **Never narrate WHAT the code does** — rename or restructure until the line speaks for itself.
- **Never leave temporal or authorship tells** ("for now", "previously", "in a real impl") — encode durable intent in the code or delete the note; that history belongs in VCS.
- **Never let a cross-reference rot** — drop the stale ref and encode the invariant at the site where it holds.
- **The rare surviving comment** carries something the code genuinely cannot: a WHY behind a non-obvious choice, an invariant a caller must uphold, a non-obvious tradeoff, or an alias to a known pattern. It must survive review as irreducible AND fit within the per-file budget — there is no budget-free exception.

## The two gates that back this

- **`eir comments`** (deterministic) enforces volume: a hard per-file comment-line budget (`./cmd/eir/eir comments --max-comments N`). Every comment line counts — doc/lead blocks included; only `//+` build constraints are exempt. A file over budget fails. This is the blunt instrument that drives the count toward zero.
- **`claude-skills:comment-audit`** (LLM, `phase: llm` validator) judges what the deterministic gate cannot: whether a surviving comment is irreducible WHY or disguised WHAT-narration. It runs before every commit. Write to pass both.

The repository is mid-migration from a previously comment-dense style: most files still exceed the budget, and the `eir comments` gate is run as a directory-by-directory sweep rather than a single blocking trunk gate until each area is clean.
