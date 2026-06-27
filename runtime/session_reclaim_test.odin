package funpack_runtime

import "core:mem"
import "core:mem/virtual"
import "core:testing"

@(private = "file")
RECLAIM_PROBE_TICKS :: 10_000

@(private = "file")
RECLAIM_SAMPLE_AT :: 200

@(private = "file")
drive_live_seam_tick :: proc(
	program: ^Program,
	version: World_Version,
	input: Input,
	time: Record_Value,
	carrier: Persist_Carrier,
	persistent: mem.Allocator,
	scratch: mem.Allocator,
) -> (
	next: World_Version,
	next_carrier: Persist_Carrier,
) {
	next, next_carrier = step_tick_persist(program, version, input, time, carrier, scratch, nil, persistent, true)
	draw := render_version(program, next, input, time, scratch)
	_ = draw
	scene := audio_version(program, next, input, time, scratch)
	_ = scene
	return next, next_carrier
}

@(test)
test_live_seam_persistent_memory_is_bounded :: proc(t: ^testing.T) {
	program, ok := load_yard(t)
	if !ok {
		return
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	persistent := mem.tracking_allocator(&track)

	scratch: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&scratch) == nil) {
		return
	}
	defer virtual.arena_destroy(&scratch)
	scratch_alloc := virtual.arena_allocator(&scratch)

	world := new_world(program, persistent)
	version := run_startup(&program, initial_version(world, persistent), persistent)
	carrier := new_persist_carrier(nil)

	saved_ctx := context
	context.allocator = scratch_alloc
	defer context = saved_ctx

	sample_at: i64 = 0
	for i in 0 ..< RECLAIM_PROBE_TICKS {
		time := yard_time(program.entrypoint.tick_hz, scratch_alloc)
		input := with_axis(empty(), .P1, ActionId(0), Vec2{Fixed(0), to_fixed(1)})
		version, carrier = drive_live_seam_tick(&program, version, input, time, carrier, persistent, scratch_alloc)
		free_all(scratch_alloc)
		if i + 1 == RECLAIM_SAMPLE_AT {
			sample_at = track.current_memory_allocated
		}
	}
	sample_final := track.current_memory_allocated
	peak := track.peak_memory_allocated

	if !testing.expectf(
		t,
		sample_at > 0,
		"baseline persistent footprint at tick %d must be non-zero (sanity), got %d",
		RECLAIM_SAMPLE_AT,
		sample_at,
	) {
		return
	}
	bound := sample_at * 4
	testing.expectf(
		t,
		sample_final <= bound,
		"persistent footprint must stay O(1) in M: final %d bytes at tick %d must be <= %d (4x the tick-%d baseline %d); growth past this is the unbounded-leak regression",
		sample_final,
		RECLAIM_PROBE_TICKS,
		bound,
		RECLAIM_SAMPLE_AT,
		sample_at,
	)
	testing.expectf(
		t,
		peak <= bound,
		"persistent PEAK must stay O(1) in M: %d bytes must be <= %d (4x the tick-%d baseline)",
		peak,
		bound,
		RECLAIM_SAMPLE_AT,
	)
}

@(test)
test_reclaimed_run_equals_temp_reference :: proc(t: ^testing.T) {
	REF_TICKS :: 120

	reclaim_prog, ok1 := load_yard(t)
	if !ok1 {
		return
	}
	ref_prog, ok2 := load_yard(t)
	if !ok2 {
		return
	}

	reclaim_persistent := context.allocator
	reclaim_scratch: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&reclaim_scratch) == nil) {
		return
	}
	defer virtual.arena_destroy(&reclaim_scratch)
	reclaim_alloc := virtual.arena_allocator(&reclaim_scratch)

	rworld := new_world(reclaim_prog, reclaim_persistent)
	rversion := run_startup(&reclaim_prog, initial_version(rworld, reclaim_persistent), reclaim_persistent)
	rcarrier := new_persist_carrier(nil)
	{
		saved_ctx := context
		context.allocator = reclaim_alloc
		for _ in 0 ..< REF_TICKS {
			rtime := yard_time(reclaim_prog.entrypoint.tick_hz, reclaim_alloc)
			rinput := with_axis(empty(), .P1, ActionId(0), Vec2{Fixed(0), to_fixed(1)})
			rversion, rcarrier = drive_live_seam_tick(&reclaim_prog, rversion, rinput, rtime, rcarrier, reclaim_persistent, reclaim_alloc)
			free_all(reclaim_alloc)
		}
		context = saved_ctx
	}

	ref_world := new_world(ref_prog, context.temp_allocator)
	ref_version := run_startup(&ref_prog, initial_version(ref_world, context.temp_allocator), context.temp_allocator)
	ref_time := yard_time(ref_prog.entrypoint.tick_hz, context.temp_allocator)
	for _ in 0 ..< REF_TICKS {
		ref_input := with_axis(empty(), .P1, ActionId(0), Vec2{Fixed(0), to_fixed(1)})
		ref_version = step_tick(&ref_prog, ref_version, ref_input, ref_time, context.temp_allocator)
	}

	testing.expectf(
		t,
		world_versions_equal(rversion, ref_version),
		"reclaimed run must commit a bit-identical version to the non-reclaiming reference at tick %d",
		REF_TICKS,
	)
	testing.expect_value(t, rversion.tick, ref_version.tick)
}
