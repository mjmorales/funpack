// Carry-forward seam #1: the struct-payload variant VALUE round-trip. A
// struct-payload variant used as an EXPRESSION (`Shape2::Box{size: Vec2{…}}`, the
// shape yard's wall_body/box_size build) is serialized by the funpack emitter as a
// `record Type::Case` node (emit_struct_variant), but the runtime represents an
// enum value as a Variant_Value so a §2.5 struct-pun `match` can read its case and
// pun its payload columns (struct_arm_matches at interp_call.odin expects a
// Variant_Value of the named case whose payload is the struct Record_Value).
//
// This test pins the reconciliation END TO END through the node reader: it builds
// the EXACT node text the emitter produces for a `match shape { Shape2::Box{size}
// => size  _ => Vec2{8,8} }` over a `Shape2::Box{size}` value scrutinee, parses it
// through the runtime's zero-import node reader (parse_node_forest), and evaluates
// it — so a `record Shape2::Box` value flowing through eval_record becomes a
// Variant_Value the struct-pun arm matches and the `{size}` pun binds. Before the
// eval_record `::` arm, the value was a plain Record_Value the arm could never
// match, so this is the seam's regression guard.
package funpack_runtime

import "core:strings"
import "core:testing"

// STRUCT_VARIANT_MATCH_BODY is the §2.7 node run the funpack emitter produces for
// a single `return match Shape2::Box{size: Vec2{24,24}} { Shape2::Box{size} =>
// size  _ => Vec2{8,8} }` statement. The scrutinee is a struct-payload variant
// VALUE (`record Shape2::Box`), the first arm is the struct-pun `struct_binds`
// pattern, the second a wildcard fallback — exactly the box_size shape, but with a
// LITERAL Box value as the scrutinee so the round-trip exercises eval_record's
// `::` variant arm, not a hand-built Variant_Value.
//
// Layout (one node per line, pre-order, each ending in its child_count except the
// scalar `arm` whose count is fixed by kind, §2.7):
//   return(1)
//     match arm_count=2 child_count=5
//       record Shape2::Box 1 1            ← the struct-variant VALUE scrutinee
//         recfield size 1
//           record Vec2 2 2
//             recfield x 1 / fixed 24<<32 / recfield y 1 / fixed 24<<32
//       arm struct_binds Shape2 Box 1 size   ← the §2.5 struct-pun arm (0 children)
//       name size 0                          ← that arm's body: the punned binder
//       arm wildcard - - 0                   ← the fallback arm (0 children)
//       record Vec2 2 2 …                    ← that arm's body: Vec2{8,8}
struct_variant_match_body :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	twenty_four := i64(to_fixed(24))
	eight := i64(to_fixed(8))
	strings.write_string(&b, "node return 1\n")
	strings.write_string(&b, "node match 2 5\n")
	// scrutinee: Shape2::Box{size: Vec2{24,24}} — a struct-payload variant value
	strings.write_string(&b, "node record Shape2::Box 1 1\n")
	strings.write_string(&b, "node recfield size 1\n")
	write_vec2_record(&b, twenty_four, twenty_four)
	// arm 1: struct_binds Shape2 Box {size}, body = the punned `size`
	strings.write_string(&b, "node arm struct_binds Shape2 Box 1 size\n")
	strings.write_string(&b, "node name size 0\n")
	// arm 2: wildcard, body = Vec2{8,8}
	strings.write_string(&b, "node arm wildcard - - 0\n")
	write_vec2_record(&b, eight, eight)
	return strings.to_string(b)
}

// write_vec2_record appends the §2.7 node run for a `Vec2{x: <xbits>, y: <ybits>}`
// record literal — the `record Vec2 2 2` head with its two `recfield`/`fixed`
// children, the raw Q32.32 bits inline. It is the shape eval_record collapses to a
// Vec2 column.
write_vec2_record :: proc(b: ^strings.Builder, x_bits: i64, y_bits: i64) {
	strings.write_string(b, "node record Vec2 2 2\n")
	strings.write_string(b, "node recfield x 1\n")
	strings.write_string(b, "node fixed ")
	strings.write_i64(b, x_bits)
	strings.write_string(b, " 0\n")
	strings.write_string(b, "node recfield y 1\n")
	strings.write_string(b, "node fixed ")
	strings.write_i64(b, y_bits)
	strings.write_string(b, " 0\n")
}

// test_struct_variant_value_round_trips_through_struct_pun is the seam-#1 proof: a
// struct-payload variant VALUE emitted as a `record Type::Case` node, read back
// through the runtime node reader and evaluated, matches the §2.5 struct-pun arm
// and the `{size}` pun binds the payload's `size` column. The Box arm wins (the
// value IS a Box), so the result is the punned `{24, 24}`, never the `{8, 8}`
// fallback — proving eval_record lifts a `::`-named record to a Variant_Value the
// struct_arm_matches can match.
@(test)
test_struct_variant_value_round_trips_through_struct_pun :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	body := struct_variant_match_body(context.temp_allocator)
	lines := split_artifact_lines(body, context.temp_allocator)
	statements, parse_err := parse_node_forest(lines, 1, context.temp_allocator)
	if !testing.expectf(t, parse_err == .None, "node forest must parse, got %v", parse_err) {
		return
	}
	if !testing.expect_value(t, len(statements), 1) {
		return
	}

	program := Program{}
	version := World_Version{}
	interp := rt_struct_interp(&program, &version)

	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	// The single `return` statement's child is the match expression.
	result, ok := eval(&interp, &statements[0].children[0], &env)
	if !testing.expect(t, ok) {
		return
	}

	// The Box arm matched and `{size}` punned the payload's size column: the result
	// is Vec2{24, 24}, the punned value — not the Vec2{8, 8} wildcard fallback.
	got, is_vec := result.(Vec2)
	if !testing.expect(t, is_vec) {
		return
	}
	testing.expect_value(t, got.x, to_fixed(24))
	testing.expect_value(t, got.y, to_fixed(24))
}

// rt_struct_interp builds a minimal read-only interpreter for the round-trip: an
// empty program/version, the empty input snapshot, and the fixed 60hz Time. The
// body reads no rows and no resources beyond the literals it carries, so the empty
// context suffices.
@(private = "file")
rt_struct_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	time := Record_Value{type_name = "Time", fields = dt_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}
