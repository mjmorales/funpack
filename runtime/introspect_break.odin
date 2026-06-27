package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Live_Probe :: struct {
	handle:    int,
	probe:     Probe_Decl,
	on_signal: string,
}

break_request :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	switch cmd {
	case "break":
		return break_set(s, id, args, allocator)
	case "watch":
		return watch_set(s, id, args, allocator)
	case "clear":
		return break_clear(s, id, args, allocator)
	}
	return error_response(id, cmd, "unknown break-group command", allocator)
}

@(private = "file")
break_set :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	signal, has_signal := json_string_field(args, "on_signal")
	_, has_body := args["body"]
	if has_signal && has_body {
		return error_response(id, "break", "a break is either {on_signal} or {when:<pred>}, never both", allocator)
	}

	if has_signal {
		if program_signal(s.program, signal) == nil {
			return error_response(id, "break", "unknown signal type", allocator)
		}
		handle := register_live_probe(s, Live_Probe{probe = Probe_Decl{kind = .Break}, on_signal = signal})
		return break_set_response(s, id, handle, allocator)
	}

	target, has_target := json_string_field(args, "target")
	if !has_target {
		return error_response(id, "break", "missing args.target (the behavior to break on) or args.on_signal", allocator)
	}
	if program_behavior(s.program, target) == nil {
		return error_response(id, "break", "unknown behavior", allocator)
	}
	body, body_ok := parse_wire_node_forest(args, allocator)
	if !body_ok {
		return error_response(id, "break", "missing or malformed args.body — a one-expression node forest is required for break{when}", allocator)
	}
	handle := register_live_probe(s, Live_Probe{probe = Probe_Decl{kind = .Break, target = strings.clone(target, allocator), body = body}})
	return break_set_response(s, id, handle, allocator)
}

@(private = "file")
watch_set :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	target, has_target := json_string_field(args, "target")
	if !has_target {
		return error_response(id, "watch", "missing args.target (the behavior to watch)", allocator)
	}
	if program_behavior(s.program, target) == nil {
		return error_response(id, "watch", "unknown behavior", allocator)
	}
	body, body_ok := parse_wire_node_forest(args, allocator)
	if !body_ok {
		return error_response(id, "watch", "missing or malformed args.body — a one-expression node forest is required", allocator)
	}
	handle := register_live_probe(s, Live_Probe{probe = Probe_Decl{kind = .Watch, target = strings.clone(target, allocator), body = body}})
	return watch_set_response(s, id, handle, allocator)
}

@(private = "file")
break_clear :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	handle, has_handle := json_int_field(args, "handle")
	if !has_handle {
		return error_response(id, "clear", "missing args.handle", allocator)
	}
	for live, i in s.live_probes {
		if live.handle == int(handle) {
			ordered_remove(&s.live_probes, i)
			b := strings.builder_make(allocator)
			ok_response_open(&b, id, "clear")
			fmt.sbprintf(&b, "{{\"cleared\":%d,\"live\":%d}}}}", handle, len(s.live_probes))
			return strings.to_string(b)
		}
	}
	return error_response(id, "clear", "no live probe with that handle", allocator)
}

@(private = "file")
register_live_probe :: proc(s: ^Debug_Session, live: Live_Probe) -> int {
	if s.live_probes == nil {
		s.live_probes = make([dynamic]Live_Probe, s.allocator)
	}
	probe := live
	probe.handle = s.next_handle
	s.next_handle += 1
	append(&s.live_probes, probe)
	return probe.handle
}

@(private = "file")
parse_wire_node_forest :: proc(args: json.Object, allocator := context.allocator) -> (body: []Node, ok: bool) {
	entries, has_array := json_array_field(args, "body")
	if !has_array {
		return nil, false
	}
	lines := make([dynamic]string, 0, len(entries), allocator)
	for entry in entries {
		text, is_string := entry.(json.String)
		if !is_string {
			return nil, false
		}
		append(&lines, text)
	}
	forest, err := parse_node_forest(lines[:], 1, allocator)
	if err != .None {
		return nil, false
	}
	return forest, true
}

@(private = "file")
break_set_response :: proc(
	s: ^Debug_Session,
	id: i64,
	handle: int,
	allocator := context.allocator,
) -> string {
	hits := honor_live_break_hits(s, allocator)
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "break")
	fmt.sbprintf(&b, "{{\"handle\":%d,\"live\":%d,\"hits\":[", handle, len(s.live_probes))
	for hit, i in hits {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, render_breakpoint_hit_event(hit, allocator))
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

@(private = "file")
watch_set_response :: proc(
	s: ^Debug_Session,
	id: i64,
	handle: int,
	allocator := context.allocator,
) -> string {
	fires := honor_live_watch_fires(s, allocator)
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "watch")
	fmt.sbprintf(&b, "{{\"handle\":%d,\"live\":%d,\"fires\":[", handle, len(s.live_probes))
	for fire, i in fires {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, render_watch_fired_event(fire, allocator))
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

@(private = "file")
honor_live_break_hits :: proc(s: ^Debug_Session, allocator := context.allocator) -> []Break_Hit {
	honor, _ := session_honor_probes(s, allocator)
	hits := make([dynamic]Break_Hit, 0, len(honor.breaks), allocator)
	for hit in honor.breaks {
		append(&hits, hit)
	}
	signal_hits := honor_live_signal_breaks(s, allocator)
	for hit in signal_hits {
		append(&hits, hit)
	}
	return hits[:]
}

@(private = "file")
honor_live_watch_fires :: proc(s: ^Debug_Session, allocator := context.allocator) -> []Watch_Fire {
	honor, _ := session_honor_probes(s, allocator)
	fires := make([dynamic]Watch_Fire, 0, len(honor.watches), allocator)
	for fire in honor.watches {
		append(&fires, fire)
	}
	return fires[:]
}

@(private = "file")
honor_live_signal_breaks :: proc(s: ^Debug_Session, allocator := context.allocator) -> []Break_Hit {
	hits := make([dynamic]Break_Hit, 0, allocator)
	has_signal_break := false
	for live in s.live_probes {
		if live.on_signal != "" {
			has_signal_break = true
			break
		}
	}
	if !has_signal_break {
		return hits[:]
	}
	for tick in 0 ..< len(s.snapshots) {
		obs := new_tick_observe(allocator)
		if _, ok := session_refold_tick(s, tick, &obs, allocator); !ok {
			continue
		}
		for live in s.live_probes {
			if live.on_signal == "" {
				continue
			}
			if signal_routed_in_tick(obs, live.on_signal) {
				append(
					&hits,
					Break_Hit {
						behavior = "",
						target = live.on_signal,
						instance = Id{},
						tick = tick,
						self_enc = live.on_signal,
					},
				)
			}
		}
	}
	return hits[:]
}

@(private = "file")
signal_routed_in_tick :: proc(obs: Tick_Observe, signal_type: string) -> bool {
	for capture in obs.signals {
		if capture.signal == signal_type {
			return true
		}
	}
	return false
}

program_signal :: proc(program: ^Program, name: string) -> ^Signal_Decl {
	for &signal in program.signals {
		if signal.name == name {
			return &signal
		}
	}
	return nil
}
