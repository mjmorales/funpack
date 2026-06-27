package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

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

Frame_Divergence :: struct {
	tick:       int,
	recorded:   u64,
	reproduced: u64,
}

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
		if len(reproduced.per_tick) > shared {
			frame := reproduced.per_tick[shared]
			return Frame_Divergence{tick = frame.tick, recorded = 0, reproduced = frame.digest}, true
		}
		frame := recorded.per_tick[shared]
		return Frame_Divergence{tick = frame.tick, recorded = frame.digest, reproduced = 0}, true
	}
	return {}, false
}

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
