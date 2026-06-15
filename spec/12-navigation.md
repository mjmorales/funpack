# 12 — Navigation

Spatial navigation — a *thing* finding its way through a level. (UI navigation, the menu focus
cursor, is unrelated and lives in [`21`](21-ui.md).) The thesis applied: **the engine does the
pathfinding; the agent writes boring glue that follows a path.** Search is rich and native; the
language stays a fold. `stdlib/engine/{nav,nav3}.fun` match this component.

---

## 1. The graph is baked — you never build it

There is no `addNode`/`addEdge`/`buildGraph`. A nav graph is **derived at bake** from the level —
tilemap solids in 2D ([`18`](18-tilemaps.md)), a walkable navmesh from geometry in 3D — and carried
in the world like the spawn list and tile layer. The worst nav bug, a graph drifted out of sync with
its geometry, is **unrepresentable** because there is no second source of truth. Dynamic terrain
follows for free: `SetTile` re-derives the affected nav incrementally, so a `path()` issued the tick
after a wall falls routes through the gap.

The active graph arrives as an injected resource **`Nav`** (`Nav3` in 3D), like `Input`/`Time`/`Rng`;
taking `nav: Nav` *is* the statement "this behavior consults navigation". A `NavHandle` names a baked
layer (ground vs. flying) — the escape hatch; the default is the one resource and no name.

The authored surface is the single-level graph plus the pure `path()` query — one flat graph, one
query contract, nothing else. **Hierarchical decomposition** — clustering a large map into a coarse
graph over fine sub-graphs to bound search cost — is an *invisible engine implementation detail*
behind that same contract, never a language surface: the author writes `path()` against one graph
whether the engine searches it directly or through tiers, the decomposition never appears in authored
data, never changes a route's purity, and adds no level for behaviors to address.

## 2. Path search is a pure function, not a job

Path search is a **pure, total, deterministic extern**, never an async job — an async job's completion
tick is frame-time dependent (kills replay/lockstep), it is not testable as a fold, and a request-
command-plus-result-signal is two pipeline edges to close:

```funpack
fn path(self: Nav, from: Vec2, to: Vec2) -> Result[Path, NavError]
```

Same inputs ⇒ bit-identical `Path` on every machine (fixed tie-break: lowest `f`, then stable cell
order; fixed-point costs). `Path` is serializable `data` (`{ steps: [Vec2], cost: Fixed }`) — store
it on a blackboard and replay re-derives it. Errors are values you must match: `Unreachable`,
`OffNav` — no silently-empty path.

An endpoint resolves to the walkable cell **containing** it — the grid's half-open cell partition,
exact and deterministic — so a thing paths from where it *stands*, not from a center it must first
teleport onto; the route's steps are still given in cell centers ([§5](#5-scope)). `OffNav` means
the containing cell is not walkable space at all: inside a solid, or off the grid. Snapping such a
point onto walkable space is `nearest()`'s job — an explicit authored move, never an implicit
`path()` courtesy — which is exactly why both error values and the snap tool exist side by side.

There is **no engine-driven replan cadence** — a hidden timer re-routing agents around moving
obstacles is exactly the hidden control flow AX1 forbids, and the engine owns no such loop.
Adaptation to a changed world is two explicit, authored moves: a nav-affecting `SetTile` re-derives
the graph so the *next* query reflects the new topology ([§1](#1-the-graph-is-baked--you-never-build-it)),
and a behavior re-issues `path()` on *its own* logic — a `Fixed` countdown reaching zero ([`13`](13-ai.md)),
a `[Damaged]`-style signal, or a target drifting off the cached route. An agent chasing a moving
obstacle re-paths because its own `match` arm calls `path()` again, never because the engine decided
the tick for it.

> **"But pathfinding is expensive."** That is the engine's problem, stated as a *contract* (pure
> deterministic function), not the agent's, stated as an API. The implementation dedups identical
> queries per stage and backs them with an incremental flow field, so the naive **repath-every-tick**
> is fast by construction, and many-things-one-goal (RTS/tower-defense) is a shared flow field the
> engine infers — not a second API.

## 3. The surface

Global route, then local follow. Nothing else.

| call | shape | use |
|---|---|---|
| `path(nav, from, to)` | `Result[Path, NavError]` | the route |
| `advance(path, pos, arrive)` | `(Option[Vec2], Path)` | next waypoint + remaining route — a fold |
| `los(nav, from, to)` | `Bool` | straight segment clear? (string-pull / shortcut) |
| `reachable(nav, from, to)` | `Bool` | route exists? (cheaper than `path`) |
| `nearest(nav, point)` | `Option[Vec2]` | snap an off-nav target onto walkable space |

**`los` reads occupancy, not the graph.** Line-of-sight is a geometric visibility test — *does the
straight segment cross a solid?* — and solidity lives in the level's occupancy (the tilemap's solids
in 2D ([`18`](18-tilemaps.md)), the baked solid geometry in 3D), the **same single source the nav
graph derives from** ([§1](#1-the-graph-is-baked--you-never-build-it)). The graph is connectivity,
not visibility: a straight segment between two connected centers can cross a solid that is simply a
non-edge, and two unconnected centers can see each other across a chasm. So `los` answers over the
**current** occupancy — like `path()` after a wall falls (§1), a `SetTile` wall blocks sight from
the next tick — and the baked nav carries **no second copy of the solids** to drift against.

The test is conservative and exact: the segment's **supercover** — every cell whose closed cell box
the closed segment `from → to` intersects — must contain no solid cell. A segment through a lattice
corner therefore checks both diagonal neighbors (no line-of-fire through a kissing-corner seam), a
segment grazing a wall's face reads blocked, and `from == to` is `true` iff the containing cell is
clear. Tile-less cells and the out-of-grid void block nothing — solidity is a property of a tile,
and you can *see* across a chasm you cannot *walk*: `los` is sight, `reachable` is feet.

`nav3` is the `Vec3`/navmesh twin — identical names with a `3` suffix. The agent's glue is a pure
fold, tested with `Nav.of(route)`:

```funpack
behavior chase on Hunter {
  fn step(self: Hunter, nav: Nav, players: View[Player]) -> Hunter {
    let goal = nearest_player(self.pos, players)
    let route = match nav.path(self.pos, goal) {
      Result::Ok(p)  => p
      Result::Err(_) => self.path        // hold the last good route
    }
    return match route.advance(self.pos, ARRIVE) {
      (Option::Some(wp), rest) => self with { pos: step_to(self.pos, wp, SPEED), path: rest }
      (Option::None,     _)    => self
    }
  }
}
```

## 4. Opinionated stances & non-features

- **One algorithm, zero runtime knobs** — exactly one `path()`; no A*-vs-Dijkstra, no heuristic
  weight, no diagonal toggle. Movement/diagonal/cost rules are a **bake-time** property of the level's
  nav, not a runtime argument.
- **Errors are values you must handle**; **two tiers one surface** (route + follow), with **no
  steering zoo** (seek/flee/wander/separation are boring glue over the `View[T]` neighbor join, not an
  engine library); **cost is a contract, not an API**.
- **No flow-field surface** — the pure `path()` query is the *one* pathing model; a flow field is an
  engine implementation detail behind that contract (the shared structure §2 infers for
  many-things-one-goal), never a second authored pathing primitive an author requests. **No
  per-faction filter argument** (a baked nav layer selected by a `NavHandle`, not a runtime `mask:`);
  **no async/streaming search**.

## 5. Scope

A grid `Path` is given in cell centers; the raw `Cell` index is not exposed. Pathing is single-level;
routes do not cross streamed-chunk portals.
