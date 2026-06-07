// Pong paddle-bounce probe (the pong counterpart of yard's
// test_yard_scripted_session_delivers_at_exact_tick): it pins the EXACT tick the
// scripted golden session's first paddle bounce fires and the committed state it
// produces, so the golden digest provably folds a real §65 contact event rather
// than a static advance. Without this, the cross-build digest pinned ball_move /
// wall_bounce / score / tally / serve but NOT paddle_bounce — the ball crossed the
// static P2 paddle column at |dy|≈40, outside the ±9.5 y contact rail, so no contact
// tick ever occurred. The reworked golden_session_inputs steers the right paddle (P2)
// down into the ball's return path; this probe is the proof the contact now happens.
//
// THE CONTACT EVENT THE DIGEST FOLDS (the non-trivial evolving shape that makes the
// per-tick digests distinct): golden_session_inputs holds P2's Steer::Move at +1 for
// GOLDEN_STEER_TICKS, parking the right paddle near y≈99 — the §50 ball's return
// height at the P2 column (x=152). At PONG_FIRST_BOUNCE_TICK the §04 paddle_bounce
// collision behavior reads the first overlapping paddle (overlaps: |dx|≤3.5 AND
// |dy|≤9.5) and reflect_x's the ball's velocity, flipping Ball.vel.x from +70 to −70
// — the ball is hit back toward the left wall instead of scoring through it. Every
// value here is stable Q32.32 arithmetic (pong is SEEDLESS — no RNG), so a
// shifted bounce tick or a changed reflected velocity is a DETERMINISM regression,
// not flaky timing. The shared session definition (golden_session_inputs) lives in
// replay_acceptance_test.odin so the probe and the golden harness drive the exact
// same run.
package funpack_runtime

import "core:testing"

// PONG_FIRST_BOUNCE_TICK is the exact tick the §50 ball first lands inside the §65
// overlaps contact rail of the parked right paddle under golden_session_inputs: the
// paddle_bounce behavior reflect_x's the ball, flipping Ball.vel.x from +BALL_VX0 to
// −BALL_VX0. It is stable arithmetic over the Q32.32 kernel; a change is a
// determinism regression unless a deliberate artifact/session/encoding change moved
// it (in which case the golden fixtures regenerate under FUNPACK_REGEN_GOLDEN and
// this constant moves with them).
@(private = "file")
PONG_FIRST_BOUNCE_TICK :: 58

// PONG_BALL_VX0 is the ball's serve-velocity x magnitude (Q32.32 bits for 70.0 —
// pong's serve_velocity x and the §197 setup spawn vel.x). The ball advances right
// at +PONG_BALL_VX0 until paddle_bounce reflects it to −PONG_BALL_VX0; the sign flip
// at PONG_FIRST_BOUNCE_TICK is the contact signature this probe pins.
@(private = "file")
PONG_BALL_VX0 :: Fixed(300647710720)

// pong_ball_vel_x reads the Ball singleton's `vel` Vec2 x component at a committed
// version — +PONG_BALL_VX0 while the ball travels right, −PONG_BALL_VX0 after a
// paddle bounce reflects it. An absent table/row or a non-Vec2 column yields the
// FIXED_MIN sentinel so the assertion fails closed rather than reading a coincidental
// zero.
@(private = "file")
pong_ball_vel_x :: proc(version: ^World_Version) -> Fixed {
	table := version_find_table(version, "Ball")
	if table == nil || len(table.rows) == 0 {
		return FIXED_MIN
	}
	vel, ok := table.rows[0].fields["vel"].(Vec2)
	if !ok {
		return FIXED_MIN
	}
	return vel.x
}

@(test)
test_pong_scripted_session_bounces_off_paddle_at_exact_tick :: proc(t: ^testing.T) {
	// The scripted golden session lands the ball on the right paddle at exactly
	// PONG_FIRST_BOUNCE_TICK: Ball.vel.x flips from +PONG_BALL_VX0 (advancing right)
	// to −PONG_BALL_VX0 (reflected left), the committed signature of a §65 contact.
	// All stable Q32.32 arithmetic (pong is SEEDLESS — no RNG/seed), so a shifted
	// index or a changed reflected velocity is a determinism regression. This is the
	// proof the golden digest folds a REAL paddle_bounce: the session steers the right
	// paddle into the §65 ±9.5 contact rail so the ball reflects off it — an idle
	// paddle the ball crosses at |dy|≈40 (outside the rail) never contacts — so the
	// digest provably covers paddle_bounce, not just ball_move / wall_bounce / score /
	// tally / serve.
	context.allocator = context.temp_allocator

	program, ok := load_golden(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := time_resource(program.entrypoint.tick_hz, context.temp_allocator)
	inputs := golden_session_inputs()

	vel_x := make([]Fixed, len(inputs), context.temp_allocator)
	bounce_ticks := make([dynamic]int, context.temp_allocator)
	prev := pong_ball_vel_x(&version)
	for input, i in inputs {
		version = step_tick(&program, version, input, time)
		vel_x[i] = pong_ball_vel_x(&version)
		// A paddle_bounce is the only behavior that flips vel.x WITHOUT moving the
		// ball to center: a serve also flips/sets vel.x, but it simultaneously resets
		// the ball to spawn — paddle_bounce reflects in place. Detecting the sign flip
		// across consecutive committed ticks counts every reflection; we then assert
		// the FIRST is the in-rail paddle contact at the pinned tick.
		if (prev > 0) != (vel_x[i] > 0) {
			append(&bounce_ticks, i)
		}
		prev = vel_x[i]
	}

	// The tick BEFORE the bounce: the ball is still advancing right at +PONG_BALL_VX0.
	testing.expect_value(t, vel_x[PONG_FIRST_BOUNCE_TICK - 1], PONG_BALL_VX0)

	// The bounce tick: paddle_bounce reflect_x flips vel.x to −PONG_BALL_VX0 — the
	// committed proof a §65 contact fired this tick (the new paddle_bounce coverage).
	testing.expect_value(t, vel_x[PONG_FIRST_BOUNCE_TICK], fixed_neg(PONG_BALL_VX0))

	// At least one paddle bounce occurs in the session, and the first vel.x sign flip
	// is the pinned contact tick — provable coverage, not assumed. (The full session
	// produces several reflections off both paddles plus one serve; this asserts the
	// floor the digest acceptance rests on: ≥1 paddle_bounce, located.)
	if !testing.expect(t, len(bounce_ticks) >= 1) {
		return
	}
	testing.expect_value(t, bounce_ticks[0], PONG_FIRST_BOUNCE_TICK)
}
