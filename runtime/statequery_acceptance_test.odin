// The §08 §3 state-query END-TO-END acceptance: the committed statequery
// artifact — the live pong tree amended with @index/@spatial query
// declarations, compiled by the real funpack emitter (provenance and the
// missing-acceptance-example gap stated in funpack/golden_statequery_test.odin:
// no committed spec example exercises this surface yet) — runs through the
// per-tick transaction with the engine indices maintained, and BOTH the
// maintenance and the query results are GOLDEN-PINNED per tick against the
// committed testdata/statequery_golden.txt, byte-exact.
//
// Each tick line carries: the index-state digest plus each maintained table's
// digest (the @index over Paddle.side and the @spatial over Ball.pos — the
// ball moves every tick, so the spatial postings change tick to tick and the
// goal/serve reset shows up as a digest step), the four declared queries'
// results evaluated through the carried v10 bodies — every query a VALUE-
// parameter read whose world access is the `all[T]` node and the spatial
// combinators (the §08 §3 spec-true shape; the View-parameter interim form is
// retired) — the @index reverse lookup's answer, and the spatial kernel's
// nearest-first hits over the maintained structure. The run also asserts,
// every tick, that the transaction-folded index state is value-equal to a
// from-scratch rebuild of the committed version — maintenance is never a
// semantic input — AND that the carried balls_within body's count equals the
// maintained-structure kernel's hit count: the query body now measures
// through the SAME kernel composition (within ≤ r over the declared field),
// so compiler-emitted evaluation and the engine structure must agree exactly,
// tick by tick.
//
// GOLDEN REGENERATION: FUNPACK_REGEN_GOLDEN=1 task -d runtime test rewrites
// testdata/statequery_golden.txt from the run, then a normal (recompiled) run
// must reproduce it byte-for-byte. Regenerate only when a deliberate artifact,
// kernel, or encoding change moves the pinned values — a move without such a
// change is a determinism regression, not a stale fixture.
package funpack_runtime

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// STATEQUERY_ARTIFACT is the committed fixture artifact, embedded at compile
// time so the acceptance runs hermetically — no funpack source, no cwd, only
// the runtime package and its committed testdata.
STATEQUERY_ARTIFACT := #load("testdata/statequery.artifact", string)

// STATEQUERY_EXPECTED is the committed per-tick golden text this run must
// reproduce byte-for-byte.
STATEQUERY_EXPECTED := #load("testdata/statequery_golden.txt", string)

// STATEQUERY_TICKS spans the ball's first wall bounces AND the right-edge goal
// + center serve (≈ tick 69 at 60hz from the §197 setup), so the pinned window
// shows the spatial postings moving, leaving the probe radius, and snapping
// back to center — never a static index.
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
	// Two full runs over the same embedded artifact must render byte-identical
	// capture text — the maintained indices, the query results, and the kernel
	// answers carry no field that depends on when or where the run happened.
	first, first_ok := statequery_capture(t)
	second, second_ok := statequery_capture(t)
	testing.expect(t, first_ok && second_ok)
	testing.expect(t, first == second)
}

// statequery_capture loads the embedded artifact, builds the maintained index
// state ("rebuilt on load"), folds STATEQUERY_TICKS empty-input ticks through
// step_tick with the indices threaded, and renders the canonical per-tick
// capture text — asserting at every tick that the folded state equals a
// from-scratch rebuild of the committed version.
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

// statequery_capture_tick renders one committed tick's canonical lines: the
// maintenance digests, the three query results, the reverse lookup, and the
// spatial kernel's nearest-first answer. Every numeric value renders as its
// exact decimal (a Fixed as its raw Q32.32 bits), so the golden pins bits,
// never a rounded display.
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

	// balls_within(center, 30.0) — the @spatial-declaring query; its body
	// reads all[Ball] and measures through `within`, the carried v10 form.
	within_args := make([]Value, 2, context.temp_allocator)
	within_args[0] = origin
	within_args[1] = radius
	within, within_ok := eval_query_values(&interp, program_query(program, "balls_within"), within_args)
	testing.expect_value(t, within_ok, true)
	fmt.sbprintf(b, "query balls_within %d\n", within.(i64))

	// nearest_ball_x(center, 30.0) — the nearest-first pin: the nearest
	// in-radius ball's pos.x (exact bits), or -1.0 when none is in radius.
	nearest_args := make([]Value, 2, context.temp_allocator)
	nearest_args[0] = origin
	nearest_args[1] = radius
	nearest, nearest_ok := eval_query_values(&interp, program_query(program, "nearest_ball_x"), nearest_args)
	testing.expect_value(t, nearest_ok, true)
	fmt.sbprintf(b, "query nearest_ball_x %d\n", i64(nearest.(Fixed)))

	// paddles_on(Side::Left) — the @index-declaring query; its body reads
	// all[Paddle], the keyed fold over the world.
	on_args := make([]Value, 1, context.temp_allocator)
	on_args[0] = Variant_Value{enum_type = "Side", case_name = "Left"}
	on_left, on_ok := eval_query_values(&interp, program_query(program, "paddles_on"), on_args)
	testing.expect_value(t, on_ok, true)
	fmt.sbprintf(b, "query paddles_on %d\n", on_left.(i64))

	// corridor_half(12.0) — the pure value-parameter form, bits-exact.
	half_args := make([]Value, 1, context.temp_allocator)
	half_args[0] = to_fixed(12)
	half, half_ok := eval_query_values(&interp, program_query(program, "corridor_half"), half_args)
	testing.expect_value(t, half_ok, true)
	fmt.sbprintf(b, "query corridor_half %d\n", i64(half.(Fixed)))

	// The @index reverse lookup over the maintained structure: ascending Ids.
	ids, lookup_ok := index_lookup(indices, "Paddle", "side", Field_Value(string("Side::Left")), context.temp_allocator)
	testing.expect_value(t, lookup_ok, true)
	strings.write_string(b, "lookup Paddle.side=Side::Left")
	for id in ids {
		fmt.sbprintf(b, " %d", u32(id.raw))
	}
	strings.write_string(b, "\n")

	// The spatial kernel's nearest-first radius answer over the maintained
	// structure: (Id, exact distance bits) pairs — and the agreement floor:
	// the carried balls_within body measured the SAME kernel distance over
	// the same rows, so its count must equal the structure's hit count.
	hits, hits_ok := spatial_within(indices, "Ball", "pos", Field_Value(origin), radius, context.temp_allocator)
	testing.expect_value(t, hits_ok, true)
	testing.expect_value(t, within.(i64), i64(len(hits)))
	strings.write_string(b, "spatial Ball.pos<=r30")
	for hit in hits {
		fmt.sbprintf(b, " %d:%d", u32(hit.id.raw), i64(hit.distance))
	}
	strings.write_string(b, "\n")
}
