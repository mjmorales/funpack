---
description: Query your own funpack project index — find / holes / debt / probes / graph / tags / pipeline.
argument-hint: "[find <name> | holes | debt | probes | graph | tags | pipeline]"
---

Query the funpack project's index with `funpack warden`. `warden` is a **pure projection** over the
index `funpack build` emits — it **reports, never writes source** (you edit source; recompilation
re-derives the projection). See `funpack-determinism`.

Run the query in `$ARGUMENTS` (default `holes`):

- `funpack warden find <name>` — **reuse-before-write**: does a helper already exist? Run this
  *before* writing a function, so the duplication gate doesn't reject it later.
- `funpack warden holes` — every open `@stub` typed hole (what's left to fill before `--release`).
- `funpack warden debt` — every `@todo` with its message and window (and what's near expiry).
- `funpack warden probes` — every outstanding debug probe (`@break`/`@log`/`@watch`/`@trace`).
- `funpack warden graph` — the dependency / call graph projection.
- `funpack warden tags` — declarations by `@gtag` (e.g. all behaviors tagged `combat`); useful to
  prove a surface's cardinality.
- `funpack warden pipeline` — the flattened tick schedule.

Steps:
1. Run the requested `warden` query from the project root.
2. Summarize the projection plainly, then suggest the next action: fill a hole, resolve expiring
   debt, reuse a found helper instead of writing a new one, or check that a `@gtag` cardinality
   matches what a task expected (acceptance is proven by the index, not self-attested).

If no funpack toolchain is on PATH, say so and instead derive the same answer by reading the source
(grep for `@stub`/`@todo`/`@gtag`, trace the `pipeline` stages) — note it's a manual stand-in for the
real index projection.
