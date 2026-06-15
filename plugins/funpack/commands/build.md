---
description: Build (or check) the funpack game and interpret the compiler's diagnostics.
argument-hint: "[--check] [--release] [extra funpack args]"
---

Build the funpack project in the current directory and interpret the result. Use the
`funpack-determinism` skill for the gate semantics and exit codes, and the other `funpack-*` skills
for the fix.

1. Pick the verb:
   - default → `funpack build` (full pipeline + emits the artifact and `.funpack/index.ndjson`).
   - if `$ARGUMENTS` contains `--check` → `funpack check` (recompiles, writes nothing — the fastest
     way to ask "does it compile?").
   - pass `--release` through if present (gates `@stub` holes and debug directives).
2. Run it from the project root and read the **exit code** as the machine contract:
   - **0** = clean.
   - **2** = a compile / gate / write failure (this is *not* a test failure).
   - (`build`/`check` have no exit-1 tier; exit 1 is `funpack test`'s "asserts failed".)
3. On failure, the diagnostics are **fix-criteria** — they name the gate. Map it to the fix:
   - effect closure (a signal nothing consumes) → add the consuming stage downstream, or stop
     emitting it. See `funpack-game-model`.
   - non-exhaustive `match` → cover every variant. A bare `f`-literal in sim → use `Fixed` (`8.0`).
   - a structural budget (complexity/nesting/size/params/duplication) → decompose; check
     `funpack warden find` before re-adding a helper.
   - an unregistered `@gtag` → add it to `funpack_configs/tags.fcfg`.
   - a `@stub` under `--release` → fill the hole.
4. Apply the smallest correct fix, re-run, and repeat until exit 0. Report what failed and what you
   changed.

If no funpack toolchain is on PATH, say so and instead **statically review** the source against the
skills (the gates above), rather than inventing compiler output.
