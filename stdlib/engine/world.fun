@doc("Entities and the commands that change their population. A thing owns its colocated blackboard; cross-thing influence is signals (plain data), never aliasing. Spawn/Despawn are returned as data and applied by the engine deterministically, in stable id order. See spec/08-state.md for the read/reference/query surface.")

import engine.prelude.{Int, Option}

@doc("A thing's stable identity, assigned by a deterministic spawn counter. Equal across replays.")
data Id { raw: Int }

@doc("A typed, serializable reference to a thing of type T (a phantom-typed Id). Stored in a blackboard; resolved through the world to Option[T], so a use-after-despawn is unrepresentable. Weak and shareable: many things may hold one, and it resolves to None when the referent despawns. Makes the world a flat id-graph, not a pointer-graph — so it serializes without swizzling or cycle handling.")
data Ref[T] { id: Id }

@doc("An exclusive, owning reference to a thing of type T — the unique_ptr to Ref's weak_ptr. Exactly one owner; despawning the owner cascade-despawns the referent in the same deterministic batch. Resolves to Option[T] like Ref (a child may be despawned directly first). Sharing is always weak Ref; ownership is never shared.")
data Owned[T] { id: Id }

@doc("A command to bring a new thing into the world this tick. Written Spawn( <thing-literal> ); the engine assigns the Id.")
extern type Spawn

@doc("A command to remove a thing at the end of this tick.")
data Despawn { id: Id }

@doc("A read-only view of other things matching a type, for joins and collision. Iterable; never grants mutation.")
extern type View[T]

@doc("How many things the view matched.")
extern fn count(self: View[T]) -> Int

@doc("The matched thing at an index in stable id order, if present.")
extern fn at(self: View[T], i: Int) -> T

@doc("The typed reference to the i-th matched thing, in stable id order. A general accessor (take a Ref while iterating) and what a resolve test needs.")
extern fn ref(self: View[T], i: Int) -> Ref[T]

@doc("Resolve a typed reference to the thing it points at, or None if it has despawned. Totality forces the None arm — referential integrity by construction.")
extern fn resolve(self: View[T], ref: Ref[T]) -> Option[T]

@doc("A view over a literal list, each element assigned an Id in order. The deterministic test fixture for any behavior that reads other things — pair with .ref(i) to resolve. Invoked View.of([...]).")
extern fn of(items: [T]) -> View[T]
