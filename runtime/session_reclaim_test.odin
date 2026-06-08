// Bounded-memory acceptance for the live session's generational version
// reclamation (design-generational-version-re-mq1lys2c, Option B — O(delta)
// selective reclaim, NO copy-forward, NO type wrapping). The live driver
// (session_live.odin run_live_session) loops forever, so a per-tick allocation
// that is never freed grows the heap without bound. These tests drive the
// HEADLESS live seam — the same step_tick_persist + render_version + audio_version
// sequence the SDL driver runs, with the SAME allocator split (persistent commit
// allocator + per-tick scratch arena reset each tick) and the SAME reclaim_live
// retirement — and assert two properties:
//
//   1. BOUNDED MEMORY (test_live_seam_persistent_memory_is_bounded): the PERSISTENT
//      allocator's peak and final tracked bytes are O(1) in the tick count M, not
//      O(M). Driven under a core:mem.Tracking_Allocator over thousands of ticks,
//      the committed-version chain stays at a small constant (one prior + one
//      current version's worth of structure + columns) because the live reclaimer
//      retires each now-dead prior version once the next commits, freeing its
//      tables/rows structure + the maps the tick abandoned while preserving the
//      maps the new version still aliases (the structural-sharing invariant).
//
//   2. RECLAIMED == REFERENCE (test_reclaimed_run_equals_temp_reference): a short
//      reclaimed run (persistent commit allocator + scratch arena + reclaim_live)
//      and a temp-allocator reference run (the bounded path that never reclaims)
//      commit world_versions_equal at the same tick — reclamation frees memory and
//      changes NO committed value. This is the determinism-floor correctness
//      companion to the memory bound.
//
// The seam is headless: it omits only the SDL present_frame / audio_live_apply
// sinks (the draw-list and audio scene are still PROJECTED onto the scratch arena
// each tick, exactly as the live driver projects them before presenting, so the
// arena reset reclaims them). Yard is the artifact under test — a non-trivial
// evolving world (physics solve, composite Body columns, a crate despawn on
// delivery) so the reclaim path exercises rewritten maps AND a despawn, not a
// static world. Yard is SEEDLESS, so no Rng is threaded.
package funpack_runtime

import "core:mem"
import "core:mem/virtual"
import "core:testing"

// RECLAIM_PROBE_TICKS is the long-run tick count the bounded-memory assertion
// drives — large enough that an O(M) leak (the unbounded bug) would be obvious
// against an O(1) bound (per-tick persistent allocation was ~hundreds of KB before
// reclamation, so 10k ticks would be ~GBs without the bound; with it the
// persistent footprint stays a small constant).
@(private = "file")
RECLAIM_PROBE_TICKS :: 10_000

// RECLAIM_SAMPLE_AT is the early checkpoint the bound is measured against: the
// persistent footprint at this tick is the O(1) baseline (warmed past startup
// transients), and the footprint at the full count must not have grown beyond a
// small constant FACTOR of it. Keyed off a tick count well past warmup so the
// baseline is the steady-state two-version working set, not a cold-start sample.
@(private = "file")
RECLAIM_SAMPLE_AT :: 200

// drive_live_seam_tick runs ONE headless live-seam tick with the live driver's
// allocator split and reclamation: the fold's transient eval on `scratch` (reset
// by the caller after the tick), the committed version on `persistent` (retired
// generationally by reclaim_live), and the draw-list + audio scene PROJECTED onto
// `scratch` (consumed in-seam exactly as present_frame / audio_live_apply consume
// them live). It returns the next committed version and carrier. Yard is seedless,
// so rng is nil. This is the exact seam run_live_session runs, minus the SDL sinks.
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
	// Project draw + audio onto the scratch arena (consumed same-tick, like present).
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

	// Track the PERSISTENT allocator — the committed-version chain the reclaimer
	// must bound. The scratch arena is separate (reset each tick), so it never
	// appears in this measurement; growth here is solely the version chain.
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

	// Startup commits the initial version on the persistent allocator (it becomes
	// tick 0's prior and is retired by the first reclaim_live tick).
	world := new_world(program, persistent)
	version := run_startup(&program, initial_version(world, persistent), persistent)
	carrier := new_persist_carrier(nil)

	// Run the loop body with context.allocator = scratch so the per-tick transients
	// the helpers default-allocate (the input snapshot via empty()/with_axis, the
	// time record, the fold eval, the draw/audio projections) all land on the scratch
	// arena and are reclaimed by free_all each tick — the persistent allocator sees
	// ONLY the committed-version chain. The committed version is forced onto
	// `persistent` explicitly inside drive_live_seam_tick (step_tick_persist's
	// commit_allocator), independent of context.allocator.
	saved_ctx := context
	context.allocator = scratch_alloc
	defer context = saved_ctx

	// A fixed injected input drives every tick: P1 holding DOWN (the maneuver does
	// not matter for the memory bound — only that the world commits a real version
	// each tick).
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

	// The persistent footprint must be O(1) in M: the steady-state two-version
	// working set, NOT growing with the tick count. The bound is the baseline (the
	// warmed footprint at RECLAIM_SAMPLE_AT) plus generous slack for allocator
	// fragmentation — an O(M) leak over RECLAIM_PROBE_TICKS would be orders of
	// magnitude past this, so the constant-factor bound cleanly separates O(1) from
	// O(M). The peak is bounded the same way (no unbounded high-water mark).
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
	// CORRECTNESS companion to the memory bound: a reclaimed run and a non-reclaiming
	// temp-allocator reference run commit world_versions_equal at the SAME tick.
	// Reclamation frees memory; it changes no committed value. A divergence here
	// would be a use-after-free or a wrongly-freed live map corrupting committed
	// state — a determinism-floor break, not a memory regression.
	REF_TICKS :: 120

	reclaim_prog, ok1 := load_yard(t)
	if !ok1 {
		return
	}
	ref_prog, ok2 := load_yard(t)
	if !ok2 {
		return
	}

	// RECLAIMED run: the live seam (persistent commit allocator + scratch arena +
	// reclaim_live). The final committed version lives on the persistent allocator,
	// retired up to the prior — the LAST version survives (it is the current). The
	// committed version is forced onto `reclaim_persistent` by step_tick_persist's
	// commit_allocator; the transients run with context.allocator = the scratch arena.
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

	// REFERENCE run: the bounded path on the temp allocator that NEVER reclaims — the
	// committed-version chain accumulates wholesale (the test temp-free at teardown
	// covers it). It is the ground-truth committed state the reclaimed run must match.
	ref_world := new_world(ref_prog, context.temp_allocator)
	ref_version := run_startup(&ref_prog, initial_version(ref_world, context.temp_allocator), context.temp_allocator)
	ref_time := yard_time(ref_prog.entrypoint.tick_hz, context.temp_allocator)
	for _ in 0 ..< REF_TICKS {
		ref_input := with_axis(empty(), .P1, ActionId(0), Vec2{Fixed(0), to_fixed(1)})
		ref_version = step_tick(&ref_prog, ref_version, ref_input, ref_time, context.temp_allocator)
	}

	// The reclaimed run's surviving final version equals the reference's at the same
	// tick — bit-for-bit, blackboard columns down to the fixed-point bits.
	testing.expectf(
		t,
		world_versions_equal(rversion, ref_version),
		"reclaimed run must commit a bit-identical version to the non-reclaiming reference at tick %d",
		REF_TICKS,
	)
	testing.expect_value(t, rversion.tick, ref_version.tick)
}
