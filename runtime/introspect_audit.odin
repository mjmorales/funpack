// The §28 §3 self-heal `audit` command — the DETERMINISM-WARRANTY audit, the
// observe-class verification twin of `capture_test`. Where capture_test extracts
// a regression FROM a recording (introspect_capture.odin), `audit` proves the
// recording itself is still WARRANTED: it re-folds the recording from its
// snapshot + seed and confirms the re-run reproduces the recorded frame digests
// bit-identically (spec §28.5 / §28 §3, ADR 2026-06-13-audit-determinism-warranty).
//
// THE TWO SURFACES IT COMPARES (the load-bearing design):
//   - the RECORDED frame digests — session_capture over the session's RETAINED
//     committed chain (s.versions), the canonical truth the recording loaded
//     (open_debug_session folded it once through the production run_startup /
//     step_tick seam). This is the "recorded frame digests" §28.5 names.
//   - the RE-RUN — a fresh, INDEPENDENT re-fold from the session's own
//     s.snapshots + s.seed into request-scoped scratch (audit_refold_capture
//     below), building its OWN committed chain rather than reading s.versions.
// On a warranted recording the retained chain WAS folded from those snapshots, so
// the re-run reproduces the recorded digests bit-identically — pass, no
// divergence. A nondeterminism bug in the fold (uninitialized state, a
// map-iteration order leaking into committed bytes) makes the re-run diverge from
// the recorded baseline — the failure mode that silently invalidates replay,
// capture_test, and rewind, caught at its FIRST diverging tick.
//
// OBSERVE-CLASS / NON-PERTURBING BY CONSTRUCTION (§28 §2): both the recorded
// capture and the fresh re-fold READ the recording and build only scratch; neither
// writes the canonical chain or the canonical digest. So audit preserves the very
// warranty it checks — auditing a session leaves its committed chain and its frame
// digests byte-unchanged (the non-perturbation pin, audit_test.odin).
//
// THE diverged EVENT (§28 §3 closed async-event set): a live host streams a
// {v, event:"diverged", …} push; the present synchronous fold has no async channel,
// so — exactly as the break/watch group drains breakpoint_hit/watch_fired into its
// response (introspect_break.odin) — audit DRAINS the diverged event into the
// ok:true response: the verdict carries `warranted`, the audited tick count, and on
// a mismatch the diverged event object naming the first diverging tick and the
// recorded-vs-reproduced digest diff. render_diverged_event (probes.odin) is the
// shared renderer, byte-stable for the session log like the other event renderers.
package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// audit_request serves one `audit` command: re-fold the session's recording from
// its own snapshot + seed (audit_refold_capture), compare the re-run's per-tick
// frame digests against the recorded chain's digests (session_capture), and render
// the warranty verdict. Observe-class — the canonical chain is read, never written,
// so a session audited mid-debug is byte-identical afterward. `audit` takes no
// args: it audits the WHOLE recording the session holds (the determinism warranty
// is a whole-run property — a single diverging tick breaks it).
audit_request :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	recorded := session_capture(s, allocator)
	reproduced := audit_refold_capture(s, allocator)

	divergence, diverged := first_frame_divergence(recorded, reproduced)

	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "audit")
	// `warranted` is the one-value verdict; `ticks_audited` is the recorded tick
	// count the re-fold reproduced (the audited extent). The session-digest pair
	// is the whole-run summary the per-tick fold rolls up — equal under a warranted
	// recording, different the moment any tick diverges.
	fmt.sbprintf(
		&b,
		"{{\"warranted\":%t,\"ticks_audited\":%d,\"recorded_session\":%d,\"reproduced_session\":%d",
		!diverged,
		len(recorded.per_tick),
		recorded.session,
		reproduced.session,
	)
	if diverged {
		strings.write_string(&b, ",\"diverged\":")
		strings.write_string(&b, render_diverged_event(divergence, allocator))
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// render_diverged_event renders one Frame_Divergence as the §28 §3 `diverged`
// async-event NDJSON line: `{v, event, …}`, correlated by `event` name (not `id`),
// carrying the FIRST diverging tick and the digest diff (the recorded digest the
// recording warranted vs the digest the fresh re-fold reproduced). The field order
// is fixed (v, event, tick, recorded, reproduced), so the line is byte-stable for
// the session log (§28 §3: a debug session re-runs bit-identically). `diverged` is
// the §28 §3 closed-set event audit pushes when a recording fails its determinism
// warranty; the digests are raw u64 content hashes (xxh64 over the §20 frame bytes),
// so the diff is the exact pair a determinism comparison fails on.
render_diverged_event :: proc(divergence: Frame_Divergence, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"{{\"v\":%d,\"event\":\"diverged\",\"tick\":%d,\"recorded\":%d,\"reproduced\":%d}}",
		INTROSPECT_PROTOCOL_VERSION,
		divergence.tick,
		divergence.recorded,
		divergence.reproduced,
	)
	return strings.to_string(b)
}

// Frame_Divergence is the localized result of comparing a recorded capture against
// its re-run: the FIRST tick whose digest differs and both digests at that tick —
// the §28 §3 diverged payload. `tick` is the committed tick ordinal; `recorded` is
// the digest the recording carried, `reproduced` the digest the fresh re-fold
// produced. A length mismatch (the re-run reached a different tick count) is also a
// divergence, reported at the first absent/extra tick (see first_frame_divergence).
Frame_Divergence :: struct {
	tick:       int,
	recorded:   u64,
	reproduced: u64,
}

// first_frame_divergence walks two per-tick digest sequences in tick order and
// returns the FIRST tick at which they differ — the §28.5 "first diverging tick".
// It compares position-by-position: a differing digest at a shared index is the
// divergence; if one sequence is shorter (the re-run committed fewer/more ticks —
// itself a determinism break), the first index past the shorter sequence is the
// divergence, with the missing side reported as 0 so the diff still localizes the
// tick. ok=false (no divergence) only when both sequences have identical length AND
// every per-tick digest matches — the warranted recording.
first_frame_divergence :: proc(
	recorded, reproduced: Frame_Capture,
) -> (
	divergence: Frame_Divergence,
	diverged: bool,
) {
	shared := min(len(recorded.per_tick), len(reproduced.per_tick))
	for i in 0 ..< shared {
		if recorded.per_tick[i].digest != reproduced.per_tick[i].digest {
			return Frame_Divergence {
					tick = recorded.per_tick[i].tick,
					recorded = recorded.per_tick[i].digest,
					reproduced = reproduced.per_tick[i].digest,
				},
				true
		}
	}
	if len(recorded.per_tick) != len(reproduced.per_tick) {
		// The re-run reached a different tick count — a divergence at the first
		// tick only one sequence has. The present side carries its digest; the
		// absent side is 0 (no committed tick there), so the diff names the tick
		// the run lengths first disagree at.
		if len(reproduced.per_tick) > shared {
			frame := reproduced.per_tick[shared]
			return Frame_Divergence{tick = frame.tick, recorded = 0, reproduced = frame.digest}, true
		}
		frame := recorded.per_tick[shared]
		return Frame_Divergence{tick = frame.tick, recorded = frame.digest, reproduced = 0}, true
	}
	return {}, false
}

// audit_refold_capture re-folds the session's recording INDEPENDENTLY of its
// retained chain and captures the per-tick frame digests — the "re-run" half of the
// warranty audit. It composes the SAME public production primitives session_capture
// and reference_unobserved_capture compose (run_startup_rooted / run_startup +
// step_tick + render_version + time_resource_at + capture_frame + finish_capture),
// driven from the session's OWN s.snapshots + s.seed, building a fresh committed
// chain into request scratch. It never reads s.versions, so the comparison is a
// genuine reproduction from inputs — not a re-digest of the same retained state —
// and it never writes the canonical chain, so it is observe-class (§28 §2). The
// seeded arm restarts from the recorded tick-0 seed (run_startup_rooted) and threads
// the root Rng through step_tick, exactly as the live run and the replay re-fold
// do, so every RNG-driven spawn reproduces; the seedless arm threads no Rng.
@(private = "file")
audit_refold_capture :: proc(s: ^Debug_Session, allocator := context.allocator) -> Frame_Capture {
	world := new_world(s.program^, allocator)
	base := initial_version(world, allocator)
	tick_hz := s.program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(s.snapshots), allocator)

	if s.seed.has_seed {
		version, rng := run_startup_rooted(s.program, base, s.seed.seed, allocator)
		current := rng
		for snapshot, i in s.snapshots {
			time := time_resource_at(tick_hz, i, allocator)
			version = step_tick(s.program, version, snapshot, time, allocator, &current)
			draw := render_version(s.program, version, snapshot, time, allocator)
			append(&per_tick, capture_frame(version, draw, allocator))
		}
		return finish_capture(per_tick[:], allocator)
	}

	version := run_startup(s.program, base, allocator)
	for snapshot, i in s.snapshots {
		time := time_resource_at(tick_hz, i, allocator)
		version = step_tick(s.program, version, snapshot, time, allocator)
		draw := render_version(s.program, version, snapshot, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}
