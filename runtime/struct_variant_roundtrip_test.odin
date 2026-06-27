package funpack_runtime

import "core:strings"
import "core:testing"

struct_variant_match_body :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	twenty_four := i64(to_fixed(24))
	eight := i64(to_fixed(8))
	strings.write_string(&b, "node return 1\n")
	strings.write_string(&b, "node match 2 5\n")
	strings.write_string(&b, "node record Shape2::Box 1 1\n")
	strings.write_string(&b, "node recfield size 1\n")
	write_vec2_record(&b, twenty_four, twenty_four)
	strings.write_string(&b, "node arm struct_binds Shape2 Box 1 size\n")
	strings.write_string(&b, "node name size 0\n")
	strings.write_string(&b, "node arm wildcard - - 0\n")
	write_vec2_record(&b, eight, eight)
	return strings.to_string(b)
}

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
	result, ok := eval(&interp, &statements[0].children[0], &env)
	if !testing.expect(t, ok) {
		return
	}

	got, is_vec := result.(Vec2)
	if !testing.expect(t, is_vec) {
		return
	}
	testing.expect_value(t, got.x, to_fixed(24))
	testing.expect_value(t, got.y, to_fixed(24))
}

@(private = "file")
rt_struct_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	time := Record_Value{type_name = "Time", fields = dt_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}
