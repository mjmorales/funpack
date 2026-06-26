@doc("The immutable dictionary Map[K, V]. Keys require Eq/Hash — fixed-point data qualifies, so sim values are usable as keys. Lookups are total (Option). Iteration order is defined and stable (AX1).")

import engine.prelude.{Int, Bool, Option}

@doc("The immutable associative container. Built-in parametric type, like View[T].")
extern type Map[K, V]

@doc("An empty map to build onto.")
extern fn empty() -> Map[K, V]
@doc("The number of entries.")
extern fn len(self: Map[K, V]) -> Int
@doc("The value for a key, or None. Total.")
extern fn get(self: Map[K, V], key: K) -> Option[V]
@doc("Whether a key is present.")
extern fn has(self: Map[K, V], key: K) -> Bool
@doc("A new map with a key set to a value (replacing any prior).")
extern fn set(self: Map[K, V], key: K, value: V) -> Map[K, V]
@doc("A new map with a key removed.")
extern fn remove(self: Map[K, V], key: K) -> Map[K, V]
@doc("The keys, in stable iteration order.")
extern fn keys(self: Map[K, V]) -> [K]
@doc("The values, in stable iteration order.")
extern fn values(self: Map[K, V]) -> [V]
