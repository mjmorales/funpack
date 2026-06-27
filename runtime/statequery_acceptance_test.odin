package funpack_runtime

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

STATEQUERY_ARTIFACT := #load("testdata/statequery.artifact", string)

STATEQUERY_EXPECTED := #load("testdata/statequery_golden.txt", string)

@(private = "file")
STATEQUERY_TICKS :: 72

@(test)
test_statequery_end_to_end_golden :: proc(t: ^testing.T) {
	produced, ok := statequery_capture(t)
	if !ok {
		return
	}
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) != "" {
		golden_path, _ := filepath.join({"testdata", "statequery_golden.txt"})
		testing.expect(t, os.write_entire_file_from_string(golden_path, produced) == nil)
		return
	}
	testing.expect_value(t, len(produced), len(STATEQUERY_EXPECTED))
	testing.expect(t, produced == STATEQUERY_EXPECTED)
}

@(test)
test_statequery_capture_is_deterministic :: proc(t: ^testing.T) {
	first, first_ok := statequery_capture(t)
	second, second_ok := statequery_capture(t)
	testing.expect(t, first_ok && second_ok)
	testing.expect(t, first == second)
}

@(private = "file")
statequery_capture :: proc(t: ^testing.T) -> (text: string, ok: bool) {
	program, load_err := load_program(STATEQUERY_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, load_err, Artifact_Error.None)
	if load_err != .None {
		return "", false
	}
	testing.expect_value(t, len(program.queries), 4)

	world := new_world(program, context.temp_allocator)
	base := initial_version(world, context.temp_allocator)
	version := run_startup(&program, base, context.temp_allocator)
	indices := build_index_state(&program, &version, context.temp_allocator)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "statequery-golden 1\n")
	time := time_resource(program.entrypoint.tick_hz, context.temp_allocator)
	for tick in 0 ..< STATEQUERY_TICKS {
		statequery_capture_tick(t, &b, &program, &version, &indices, tick)
		version = step_tick(&program, version, empty(), time, context.temp_allocator, nil, &indices)
		rebuilt := build_index_state(&program, &version, context.temp_allocator)
		testing.expect_value(t, index_states_equal(indices, rebuilt), true)
	}
	return strings.to_string(b), true
}

@(private = "file")
statequery_capture_tick :: proc(
	t: ^testing.T,
	b: ^strings.Builder,
	program: ^Program,
	version: ^World_Version,
	indices: ^Index_State,
	tick: int,
) {
	fmt.sbprintf(b, "tick %d indices %d", tick, index_state_digest(indices^))
	for table in indices.tables {
		kind := table.req.kind == .Index ? "index" : "spatial"
		fmt.sbprintf(b, " %s:%s.%s=%d", kind, table.req.thing, table.req.field, index_table_digest(table))
	}
	strings.write_string(b, "\n")

	interp := new_interp(program, version, nil, empty(), time_resource(program.entrypoint.tick_hz, context.temp_allocator), context.temp_allocator)
	origin := Vec2{to_fixed(80), to_fixed(60)}
	radius := to_fixed(30)

	within_args := make([]Value, 2, context.temp_allocator)
	within_args[0] = origin
	within_args[1] = radius
	within, within_ok := eval_query_values(&interp, program_query(program, "balls_within"), within_args)
	testing.expect_value(t, within_ok, true)
	fmt.sbprintf(b, "query balls_within %d\n", within.(i64))

	nearest_args := make([]Value, 2, context.temp_allocator)
	nearest_args[0] = origin
	nearest_args[1] = radius
	nearest, nearest_ok := eval_query_values(&interp, program_query(program, "nearest_ball_x"), nearest_args)
	testing.expect_value(t, nearest_ok, true)
	fmt.sbprintf(b, "query nearest_ball_x %d\n", i64(nearest.(Fixed)))

	on_args := make([]Value, 1, context.temp_allocator)
	on_args[0] = Variant_Value{enum_type = "Side", case_name = "Left"}
	on_left, on_ok := eval_query_values(&interp, program_query(program, "paddles_on"), on_args)
	testing.expect_value(t, on_ok, true)
	fmt.sbprintf(b, "query paddles_on %d\n", on_left.(i64))

	half_args := make([]Value, 1, context.temp_allocator)
	half_args[0] = to_fixed(12)
	half, half_ok := eval_query_values(&interp, program_query(program, "corridor_half"), half_args)
	testing.expect_value(t, half_ok, true)
	fmt.sbprintf(b, "query corridor_half %d\n", i64(half.(Fixed)))

	ids, lookup_ok := index_lookup(indices, "Paddle", "side", Field_Value(string("Side::Left")), context.temp_allocator)
	testing.expect_value(t, lookup_ok, true)
	strings.write_string(b, "lookup Paddle.side=Side::Left")
	for id in ids {
		fmt.sbprintf(b, " %d", u32(id.raw))
	}
	strings.write_string(b, "\n")

	hits, hits_ok := spatial_within(indices, "Ball", "pos", Field_Value(origin), radius, context.temp_allocator)
	testing.expect_value(t, hits_ok, true)
	testing.expect_value(t, within.(i64), i64(len(hits)))
	strings.write_string(b, "spatial Ball.pos<=r30")
	for hit in hits {
		fmt.sbprintf(b, " %d:%d", u32(hit.id.raw), i64(hit.distance))
	}
	strings.write_string(b, "\n")
}
