@doc("Always-in-scope primitives, the two error-free effect carriers, and total comparison. No import needed.")

@doc("Boolean. Operated on with the word logicals and / or / not, never sigils.")
extern type Bool

@doc("Arbitrary-width signed integer. Exact; the counting type.")
extern type Int

@doc("Fixed-point scalar: the default sim number. Eq/Ord/Hash-safe and bit-identical across machines.")
extern type Fixed

@doc("IEEE float. Visual-only: legal only in render stages, never in a blackboard or signal.")
extern type Float

@doc("UTF-8 text. Built by interpolation (\"{x}\"), never by + concatenation.")
extern type String

@doc("The result of a total comparison.")
enum Ordering { Less, Equal, Greater }

@doc("An optional value. The only way to express absence; forces a match, so there is no null.")
enum Option[T] { Some(T), None }

@doc("A fallible result. Errors are values; the compiler forces exhaustive handling of E.")
enum Result[T, E] { Ok(T), Err(E) }

@doc("True when an Option carries a value.")
fn is_some(self: Option[T]) -> Bool {
  return match self {
    Option::Some(_) => true
    Option::None    => false
  }
}

@doc("The contained value, or a supplied default. Total.")
fn or_else(self: Option[T], fallback: T) -> T {
  return match self {
    Option::Some(v) => v
    Option::None    => fallback
  }
}

@doc("Reinterprets an Int as a Fixed (whole-valued). Exact.")
extern fn to_fixed(n: Int) -> Fixed

@doc("Truncates a Fixed toward zero into an Int.")
extern fn to_int(x: Fixed) -> Int

@doc("Total three-way comparison over any Ord type.")
extern fn compare(a: T, b: T) -> Ordering
