---
description: Build and launch the funpack game in the current directory.
argument-hint: "[entrypoint-name]"
---

Run the funpack game in the current directory.

1. `funpack run [name]` builds the project and launches it in one step — it compiles the artifact
   (same as `funpack build`, writing `.funpack/artifact`), then runs it **in-process** in the live
   session. There is one binary: `funpack` contains both the compiler and the runtime, so no separate
   runner is located or spawned. The optional `[name]` (`$1`) selects among committed entrypoints in
   `funpack_configs/entrypoints.fcfg` — needed only when there is more than one (a single entrypoint is
   the inferred default; multi-entrypoint selection is not yet wired, so a named pick against a
   single-entrypoint project is refused rather than silently ignored).
2. To play an **already-built** artifact without recompiling, use `funpack live .funpack/artifact
   [replay-out-path]`. To open a §28 introspection session over a built artifact, use
   `funpack attach <artifact> [recorded.replay] [--port N]`. (`funpack live --help` / `funpack --help`
   for usage.)
3. Exit codes: a build/tree refusal is exit 2; a missing entrypoint (a package-only project) is exit 2;
   otherwise `funpack run` relays the runtime's own exit code (0 on a clean session, non-zero on a load
   or device-open failure — e.g. exit 1 when no display is available).
4. Report what launched (which entrypoint, tick rate, logical resolution from the entrypoint) and any
   runtime error.

There is no `serve` verb. If asked to serve or run headless, say it is not available and offer `funpack run`.

If no funpack toolchain is on PATH, say so — do not simulate a game window. Offer instead to review the
entrypoint wiring or run `/funpack:test`.
