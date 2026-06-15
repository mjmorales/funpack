@doc("The immutable sequence [T]. Every operation returns a new list; nothing mutates. Lookups are total (they return Option), so indexing never panics. The generic container is engine-provided; users author no generics.")

import engine.prelude.{Int, Bool, Option}

@doc("The number of elements.")
extern fn len(self: [T]) -> Int
@doc("True when the list has no elements.")
extern fn is_empty(self: [T]) -> Bool
@doc("The element at an index, or None if out of range. Total.")
extern fn get(self: [T], i: Int) -> Option[T]
@doc("The first element, if any.")
extern fn first(self: [T]) -> Option[T]
@doc("The last element, if any.")
extern fn last(self: [T]) -> Option[T]

@doc("A new list with an element added to the front.")
extern fn prepend(self: [T], item: T) -> [T]
@doc("A new list with an element added to the back.")
extern fn append(self: [T], item: T) -> [T]
@doc("A new list joining two lists.")
extern fn concat(self: [T], other: [T]) -> [T]
@doc("A new list in reverse order.")
extern fn reverse(self: [T]) -> [T]

@doc("True when any element equals the target (requires Eq).")
extern fn contains(self: [T], item: T) -> Bool
@doc("The first element satisfying the predicate, if any.")
extern fn find(self: [T], pred: fn(T) -> Bool) -> Option[T]

@doc("A new list applying f to each element.")
extern fn map(self: [T], f: fn(T) -> U) -> [U]
@doc("A new list of the elements satisfying the predicate.")
extern fn filter(self: [T], pred: fn(T) -> Bool) -> [T]
@doc("Reduces the list to a single value, left to right, from an initial accumulator. The deterministic loop primitive.")
extern fn fold(self: [T], init: A, step: fn(A, T) -> A) -> A
