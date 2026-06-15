@doc("Text operations over String. Building text is interpolation syntax (\"{a}{b}\"), never + — these functions cover the dynamic cases interpolation can't: splitting, slicing, searching, parsing. All total: slicing clamps, parsing returns Option, nothing panics.")

import engine.prelude.{String, Int, Bool, Fixed, Option}

@doc("The number of Unicode codepoints.")
extern fn len(self: String) -> Int

@doc("True when the string has no codepoints. Tier-2 over len.")
fn is_empty(self: String) -> Bool {
  return len(self) == 0
}

@doc("Joins two strings. Prefer interpolation (\"{a}{b}\") for literals; use this for dynamic joins.")
extern fn concat(self: String, other: String) -> String
@doc("Each codepoint as a one-character string, in order.")
extern fn chars(self: String) -> [String]
@doc("The substring over the codepoint range [start, end), clamped to bounds. Total.")
extern fn slice(self: String, start: Int, end: Int) -> String
@doc("Splits on every occurrence of a separator. An empty separator yields the codepoints.")
extern fn split(self: String, sep: String) -> [String]
@doc("Joins parts with a separator between them. Invoked String.join(parts, sep).")
extern fn join(parts: [String], sep: String) -> String

@doc("True when the needle occurs anywhere.")
extern fn contains(self: String, needle: String) -> Bool
@doc("True when the string begins with the prefix.")
extern fn starts_with(self: String, prefix: String) -> Bool
@doc("True when the string ends with the suffix.")
extern fn ends_with(self: String, suffix: String) -> Bool
@doc("The codepoint index of the first occurrence of the needle, or None.")
extern fn index_of(self: String, needle: String) -> Option[Int]

@doc("A copy with leading and trailing whitespace removed.")
extern fn trim(self: String) -> String
@doc("An uppercased copy.")
extern fn to_upper(self: String) -> String
@doc("A lowercased copy.")
extern fn to_lower(self: String) -> String
@doc("The string repeated n times (empty when n <= 0).")
extern fn repeat(self: String, n: Int) -> String

@doc("The decimal rendering of an integer. Invoked String.from_int(n).")
extern fn from_int(n: Int) -> String
@doc("The decimal rendering of a fixed-point value. Invoked String.from_fixed(x).")
extern fn from_fixed(x: Fixed) -> String
@doc("Parses a decimal integer, or None if the whole string is not one.")
extern fn parse_int(self: String) -> Option[Int]
@doc("Parses a decimal fixed-point value, or None if the whole string is not one.")
extern fn parse_fixed(self: String) -> Option[Fixed]
