# warren — chase through a baked maze

A ferret hunts a rabbit through a rabbit-warren maze; the rabbit runs for the one burrow
that is actually open. The point is **navigation** (see
[`spec/12-navigation.md`](../../spec/12-navigation.md)): every nav idea the spec commits to
appears here once, as boring glue.

## What it exercises

- **The graph is baked, never built** (§12 §1). `levels/warren.flvl` is the *only* nav
  authoring in the project: its `tilemap` grid's solid walls (`assets/warren.tiles` marks
  `wall` as `solid: true`) are the source the nav graph derives from at bake. There is no
  `addNode`/`buildGraph` call anywhere, no graph asset to drift out of sync — the ASCII
  picture is the topology. The maze is drawn so the doctrine is testable on sight: real
  corridors, dead ends, an open burrow (`O`), and a **sealed** burrow (`S`, fully walled),
  so `Unreachable` is a route the world genuinely refuses.
- **`Nav` is an injected resource** (§12 §1). Both behaviors take `nav: Nav` like `Time` or
  `Input`; taking it *is* the statement that they consult navigation. The schema module
  (`src/warren_world.fun`) carries `Path` on each animal's blackboard — a route is plain
  serializable data, so a save or replay re-derives the same chase.
- **The whole five-call surface** (§12 §3), each used for its stated purpose in
  `src/warren_game.fun`:
  - `path(nav, from, to) -> Result[Path, NavError]` — the route, an error you must match;
  - `advance(path, pos, arrive) -> (Option[Vec2], Path)` — following is a fold over that
    tuple, matched exhaustively (`follow`, `run_for`);
  - `los(nav, from, to)` — the ferret's shortcut: a clear straight segment skips pathing
    entirely and dashes;
  - `reachable(nav, from, to)` — the rabbit's cheap pre-check: a sealed burrow fails the
    yes/no before any route is materialized;
  - `nearest(nav, point)` — the rabbit snaps a burrow mouth onto walkable space before
    querying, so an off-nav goal is an authored decision, not a guess.
- **Errors are values** (§12 §2). `routed` matches `Result::Ok/Err` and holds the last good
  route on failure — the exemplar shape from §12 §3. No silently-empty path exists to
  ignore.
- **Re-path is the behavior's own logic — there is no engine replan cadence** (§12 §2).
  A hidden timer re-routing agents would be exactly the hidden control flow AX1 forbids, so
  the engine owns no such loop. The ferret re-queries on two authored reasons only: its own
  `Fixed` countdown (`repath_t`, the [`spec/13-ai.md`](../../spec/13-ai.md) §2 idiom — a
  field folded by `time.dt`, never a scheduler) and the rabbit drifting off the cached
  route's end (`drifted`). The rabbit shows the other blessed shape: the **naive
  repath-every-tick**, fast by construction because cost is the engine's contract (per-stage
  query dedup), not the agent's API.
- **AI as a pure fold, tested with `Nav.of(route)`** (§12 §3). Every decision is a
  decomposed pure function (`routed`, `drifted`, `replan_due`, `follow`, `open_burrow`,
  `run_for`) with inline exact-equality tests; the behaviors are tested end-to-end against
  the `Nav.of` fixture, where `path()` returns the supplied route, `los`/`reachable` read
  true, and `nearest` is the identity snap.

## What is deliberately absent

No `gen/` seam is committed: the nav bake does not exist yet, and spec-first examples ship
without baked outputs — `setup()` imports `warren_spawns()` from the seam the level *will*
bake to. No steering library, no flow-field API, no per-query algorithm knobs, no async
search: §12 §4 rejects each by name, and the two behaviors here are the demonstration that
plain folds over the five calls cover a chase, an escape, and a goal check.
