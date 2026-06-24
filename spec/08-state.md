# 08 — State: the world is a database

funpack ships **one** opinionated state layer and forbids the alternatives — the entity manager,
save system, spatial hash, and `id → object` map you otherwise hand-maintain are exactly the
most-rewritten, most-bug-prone glue that [`01`](01-axioms.md) P3 says belongs in the engine. The
world already *is* a deterministic, versioned, in-memory database; this component is its **read,
reference, and query surface**.

| Database concept | funpack mechanism |
|---|---|
| Table | a `thing` type (all its instances) |
| Row | a thing instance, keyed by `Id` |
| Document | the whole blackboard travels together (not column-shredded — **not** ECS) |
| Storage engine | the COW-persistent blackboard store (structural sharing) |
| MVCC version | one committed tick |
| Transaction | a tick — a fold over the flattened pipeline ([`07`](07-pipelines.md)) |
| Durability | serialization closure ([`03`](03-data-model.md) §5) |

## CQRS by construction

Writes and reads use different paths; this component specifies the read path.

- **Write side** ([`06`](06-things-behaviors.md)): a behavior writes only its own
  blackboard, influences others only by emitting a signal, and changes the population only by
  returning `Spawn`/`Despawn`.
- **Read side** (this component): references, queries, joins, aggregates, snapshots — all **pure,
  read-only functions of the current version**. A query can never mutate, so it can never
  reintroduce aliasing.

Read consistency: within a tick the **population is fixed** while **blackboard writes fold forward**,
so a mid-tick read sees a stable set of rows with evolving columns — at **instance granularity**: a
later instance in a per-thing stage (higher `Id`) sees earlier same-stage instances' writes through a
direct `View[T]`, which reads the tick's *working* table ([`07`](07-pipelines.md) §2, §4). Model a
behavior step as the `Id`-ordered fold it is, **never** a simultaneous `map` over a step-entry
snapshot — the natural-but-wrong twin that passes a green test suite while diverging from the live
schedule.

**One shared world, no per-pipeline partition.** There is a single thing/blackboard space — this
database — and **every** pipeline and sub-pipeline reads and writes it; pipelines do **not** own
disjoint state slices. Isolation between sub-pipelines is the **signal interface** — the consumed and
emitted signal types ([`06`](06-things-behaviors.md), [`07`](07-pipelines.md)) — never a state
partition.

---

## 1. References

### `Id`
`data Id { raw: Int }` — a stable identity from the deterministic spawn counter. **Engine-internal**:
the raw identity `Ref` wraps and the type-erased target of `Despawn`. User code does not author bare
`Id`s.

### `Ref[T]` — the weak, typed reference (the only one user code authors)
A typed, serializable handle to a thing of type `T` (a phantom-typed `Id`). It lives in a blackboard
and resolves through the world to `Option[T]`:

```funpack
thing Door { pos: Vec2, gate: Ref[Switch], open: Bool = false }
behavior gate_logic on Door {
  fn step(self: Door, switches: View[Switch]) -> Door {
    return self with { open: gate_open(switches.resolve(self.gate)) }   // Ref -> Option, None arm forced
  }
}
```

- **Referential integrity by construction** — `resolve` returns `Option[T]`, so totality *forces*
  the dangling case. A use-after-despawn is unrepresentable.
- **A flat id-graph, not a pointer-graph** — the whole world (cycles, ownership, cross-refs)
  serializes trivially: no swizzling, no cycle handling. This is why save, replay, and network sync
  are total and cheap.

Joins are resolve-then-filter, ordered by the driving side's `Id`. Reverse lookup is an `@index`.

### `Owned[T]` — the exclusive, owning reference
A **distinct type** from weak `Ref[T]`, so the choice is legible at the field. Exactly one owner;
despawning it **cascade-despawns** the referent in the same deterministic structural-change batch
(ordered owner `Id` → field order → referent `Id`; deduped, so cycles terminate). Still resolves to
`Option[T]`. Sharing is always weak `Ref`; ownership is never shared (the `unique_ptr`/`weak_ptr`
prior, as distinct types).

---

## 2. `View[T]` — the read-only table

A read-only, iterable view of things matching a type, in stable `Id` order; it never grants mutation.
Surface: `count`, `at(i)`, `ref(i) -> Ref[T]`, `resolve(ref) -> Option[T]`, and the test fixture
`View.of(items)` (assigns each element an `Id` in order — pair with `.ref(i)` for resolve tests).
Ad-hoc reads are the list combinators over a `View` (`filter`/`map`/`fold`/`first`): a `View` is the
table, the combinators are the `SELECT`.

---

## 3. Indices & queries

- **`@index(Thing.field)`** — engine-maintained reverse/key lookup over instances.
- **`@spatial(Thing.field)`** — built-in deterministic radius/nearest queries; deletes the
  hand-rolled quadtree/spatial hash.
- An index is a **cache**: a pure function of state, **rebuilt on load**, with a defined
  `Id`-tiebroken iteration order — so it can never cause replay divergence.
- **Placement** is query-prefix only: `@index`/`@spatial` prefix a `query` declaration, and the
  indexed `FieldPath` head must be a declared `thing`/`singleton` — the closed placement table and
  its `Index_Wrong_Target`/`Index_Unknown_Thing` errors are in [`05`](05-directives.md) §3.

**`query` is a first-class declaration kind:**

```funpack
@spatial(Enemy.cell)
query enemies_near(origin: Cell, r: Fixed) -> [Enemy] {
  return nearest_first(within(all[Enemy], origin, r), origin)
}
```

A `query` is **read-only and pure over `(version, params)`** — it takes only value parameters, reads
the world via `all[T]` and `Ref` resolution, takes **no resources** and **emits nothing**. A
parameter may be a **`Ref[T]`**: it is a serializable value (§1), a stable instance id that resolves
deterministically through the version, so passing one keeps the query a pure function of
`(version, params)`. It is **within-tick memoized** (the version is immutable, so every later caller
pays once); its **derived read-set composes into callers** (so pipeline read-isolation survives
composition); and its **index requirement is a compiler gate** (a query needing an index must declare
it; an `@index` no query uses is dead code). Its body is the ordinary combinator surface — no
comprehension/SQL spelling.

**The dead-index use relation.** An index counts as *used* when a `query` body reads `all[T]` of the
indexed `thing`. The relation is **conservative — live-by-doubt**: an index whose `thing`'s
collection is read through a path the access-pattern report cannot trace is held **live**, never
dead-eliminated. Only an index no traceable `query` could use is flagged dead code; doubt resolves to
live, so a real-but-untraceable use never silently loses its index.

**Aggregates** over a `View` or query result: `count`, `sum`, `min_by_key`, `max_by_key`, `any`,
`all` — index-backed where possible, always a deterministic ordered fold (`Id` tiebreak).

**The access-pattern report** is derived (not authored): every `query`, the collections it reads, and
the indices it requires — flagging a query missing its index and an unused `@index`. It is the
data-plane peer of the resolved pipeline tree ([`07`](07-pipelines.md)).

**No `@unique`.** A uniqueness directive would need a runtime assertion, and sim code has no panics.
Uniqueness is modeled structurally by making a keyed `Map[K, Ref[T]]` the **source of truth** ("one
piece per cell" is a singleton holding `occupants: Map[Cell, Ref[Piece]]`), so a duplicate is
unrepresentable rather than checked.

---

## 4. Versioning, snapshots, saves

Each committed tick is a COW version with structural sharing ([`09`](09-runtime.md)), so versions are
cheap and the database is natively time-indexed:

- **Save** = serialize a version (total and cycle-free by the flat id-graph).
- **Replay** = re-fold recorded inputs, or restore a version directly.
- **Dev time-travel** = inspect/diff any retained version, driven through the introspection contract
  ([`28`](28-introspection.md)).

Two deliberate boundaries: **no runtime rollback machinery** (versions are exposed for
save/replay/debug; an operator may build rollback atop them, the engine does not ship it); and
**load is migration** — the same operation as hot-reload state migration ([`09`](09-runtime.md)) and
shared with saves ([`24`](24-persistence.md)). **Retention is a fixed constant** — a debug build
keeps a fixed window of recent versions resident (deeper history reconstructed by replay from the
nearest snapshot); a release build retains only a snapshot plus the input log.
