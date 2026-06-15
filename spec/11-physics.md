# 11 — Physics & collision

The engine integrates motion, detects collisions, and resolves contacts; user code writes **intent**
on its own body and **reacts to contacts** as signals. The hard part — a deterministic solver — is a
**Tier-1 native** (Odin, [`09`](09-runtime.md)), audited bit-identical exactly as `extern fn sin`
is. The language stays a fold. `engine.physics` / `engine.physics3` are the canonical surface.

---

## 1. Determinism stance

- **Sim physics is a custom fixed-point solver** — Tier-1 native, contracted bit-identical on every
  machine, with a **fixed timestep**, a **fixed solver-iteration count** (an AX6 runtime constant,
  never a knob), and **deterministic contact ordering**. Lockstep/replay over a physical world is
  bit-identical — the netcode payoff, not a separate problem.
- **The solver is discrete fixed-step — there is no continuous collision detection.** A fast body can
  tunnel through thin geometry within a single step; the solver makes no swept guarantee against it.
  The escape hatch is **raycast-based movement** — a body that must be tunneling-proof advances by
  clamping its motion to the first hit of the engine's ray queries (§2, Tier 1), never relying on the
  integrator alone.
- **Vendored float physics (Box2D/Chipmunk) is visual-only, never sim** — it may drive cosmetic
  debris/cloth/ragdolls in a render stage, behind the fixed-vs-float boundary; reaching the float
  path from synced state is a compile error (the warranty gate, [`25`](25-netcode.md)).

## 2. Three tiers, one surface

Escalate only as needed; the tier is visible in the signature, never a mode flag.

| Tier | You do | Engine provides |
|---|---|---|
| **0 — kinematic** | set `pos` yourself; query by hand (`solid_at`/`pairs`/`@spatial`) | nothing physics-specific |
| **1 — collision queries** | take a `Physics` resource; `raycast`/`shapecast`/`overlap`/`nearest`; decide your own response | pure deterministic detection |
| **2 — dynamics** | declare a `Body`; set velocity / apply impulse on **your own** blackboard; match `Contact` | integration + detection + **resolution** (the native solver) |

### Tier 1 — queries are pure functions

The world arrives as an injected resource `Physics` (`Physics3` in 3D); taking it *is* the statement
"this behavior consults collision". `Physics.of([…])` is the test fixture (the `View.of`/`Nav.of`
pattern).

```funpack
fn raycast(self: Physics, from: Vec2, dir: Vec2, max: Fixed, mask: [Layer]) -> Option[RayHit]
```

| call | shape |
|---|---|
| `raycast(phys, from, dir, max, mask)` | `Option[RayHit]` |
| `shapecast(phys, shape, from, dir, max, mask)` | `Option[RayHit]` |
| `overlap(phys, shape, at, mask)` | `[Ref[Thing]]` |
| `nearest(phys, point, mask)` | `Option[Ref[Thing]]` |

`RayHit` is serializable `data { body: Ref[Thing], point: Vec2, normal: Vec2, t: Fixed }`; absence is
`Option`, forced by a `match`.

### Tier 2 — declare a body, write intent, match a contact

A thing becomes a body by carrying a `body: Body` field; `pos`/`vel` are the reserved fields the
solver integrates.

```funpack
data Body {
  kind:        BodyKind          // Static | Dynamic | Kinematic
  shape:       Shape2            // Circle | Box | Capsule | Polygon | Segment   (Shape3 in 3D)
  mass:        Fixed = 1.0
  restitution: Fixed = 0.0
  friction:    Fixed = 0.5
  layer:       Layer
  mask:        [Layer]
  sensor:      Bool = false      // detects overlaps but is never resolved (triggers)
  impulse:     Vec2 = zero       // accumulated intent; the solver consumes and zeroes it
}
```

`Static` never moves (infinite mass); `Dynamic` is fully solved (the solver owns its `pos`/`vel`);
`Kinematic` is moved by your code (push dynamics, never pushed back). `Shape3` is the same shape a
`.fpm` `collide` proxy bakes ([`16`](16-modeling.md)) — a model's collision hull *is* its body shape.

A behavior influences physics only by writing **its own** body: `body.apply_impulse(j)` /
`body.apply_force(f)` return a new `Body` with intent accumulated; direct control is `self with {
vel: … }`. No hidden accumulator, no call into the solver.

## 3. The `physics:` stage — resolution is the engine's

A collision writes **both** bodies, which a behavior may never do. So resolution is **not a
behavior**: it is an **engine-closed stage**, `physics:`, the **sixth** stage kind alongside
Startup/Update/Render/Ui/Audio ([`06`](06-things-behaviors.md), [`07`](07-pipelines.md)). Its single
member is the engine battery `solve`:

```funpack
pipeline Platformer {
  control: [read_input, run, jump]   // behaviors write their own body's intent
  physics: solve                     // ENGINE: integrate · detect · resolve · emit Contact
  hits:    [on_contact, on_trigger]  // behaviors consume the Contact / Trigger signals
  render:  [draw_world]
}
```

`solve` reads every thing carrying a `Body`, integrates the dynamic ones, detects collisions
(broad-phase via the `@spatial` index, narrow-phase per shape pair), resolves contacts, and writes
back `pos`/`vel` — the engine acting as the **sole effectful boundary**. **Stage position is the
ordering**: intent before `solve`, reactions after.

## 4. Contacts & triggers — signals routed per participant

`solve` publishes collisions as engine signals, **routed by the engine to each participating
instance and oriented so the receiver is the subject** (the normal points away from `self`). A
behavior `on T` consuming `[Contact]` sees only its own instance's contacts, already in its frame —
**no `self.id` to fetch, no list to filter**.

```funpack
signal Contact { normal: Vec2, point: Vec2, impulse: Fixed }   // normal points away from self
signal Trigger {}                                              // overlapping a sensor; no resolution
```

A solid pair yields one `Contact` to each body; a sensor pair yields one `Trigger` to each
overlapping body. Because the **engine** emits them, they are an **optional inbound edge** (like
reading `Time`): leaving one unconsumed is *not* an effect-closure violation (that rule binds
*user*-emitted signals). A contact behavior is a pure, testable fold over plain values.

## 5. Collision filtering — a registry, not a knob

A body carries a `layer` and a `mask`. Two bodies collide **iff each mask contains the other's
layer** (symmetric AND — stated, no hidden matrix). `Layer` is a project-declared closed set, checked
like a `@gtag`; an unregistered layer is a compile error.

```funpack
enum Layer: CollisionLayer { World, Player, Enemy, Pickup, Projectile }
```

## 6. No joints or constraints — constraints are behaviors

The engine ships **bodies, collision, and triggers** — there are **no joint or constraint types**. A
constraint is an ordinary **behavior over bodies** ([`06`](06-things-behaviors.md)): a behavior reads
body state and writes its own body's intent each step (the §2 `apply_impulse`/`apply_force`/`vel`
surface), feeding the `physics:` stage like any other intent. Hinges, springs, distance constraints,
and the rest are gameplay folds, not engine primitives — keeping the effectful boundary the single
`solve` battery (§3).

## 7. Scope

A dynamic body whose motion falls below an **engine-fixed rest threshold sleeps deterministically** —
dropped from integration and the active set until a contact or applied force wakes it. The threshold
is a **fixed engine constant**, identical on every machine and run, **not configurable** from sim
code — a tunable threshold would let two runs diverge on the sleep/wake boundary. Sleeping/islands
are engine-internal and unobservable, so they stay bit-identical. Collision filtering is the per-body
`layer`/`mask` registry of §5. The 3D solver covers primitive shapes; concave-mesh bodies are out of
scope.
