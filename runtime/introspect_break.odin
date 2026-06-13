// The §28 §3 break group — the LIVE, dynamically-set break/watch/clear commands,
// the runtime counterpart to the in-code @break/@watch directives (§28 §4). A live
// `break`/`watch` is the SAME honor an in-code @break/@watch is — it pauses on a
// predicate / fires watch_fired on a value change — only session-set over the wire
// instead of compiled into the artifact's [probes] section. So this group reuses the
// §28 §4 honor machinery verbatim (probes.odin): it stores each live probe as a
// Probe_Decl in the session's registry, arms them on the SAME honor seam the in-code
// probes ride (honor_behavior_step folds honor.live alongside honor.program.probes),
// and renders firings through the SAME breakpoint_hit/watch_fired renderers.
//
// OBSERVE-CLASS, NON-PERTURBING (§28 §2/§3: the break group is observe, not
// control). Setting a live break/watch mutates ONLY the session's live-probe
// registry — it never forks a branch and never writes the canonical chain. Honoring
// re-folds the recording through session_honor_probes (which builds its OWN scratch
// chain — the canonical s.versions is untouched), so a session with live probes set
// digests its canonical chain bit-identical to one with none: a live break/watch
// pauses and reports, it does not change the recorded fold (the determinism warranty,
// pinned by introspect_break_test.odin). This is why the break group sits in the
// OBSERVE column of the §28 §3 command table, beside time/inspect — not in control.
//
// NODE-FOREST-ONLY, NEVER SOURCE (§28 §2). A live break{when:<pred>}/watch{<expr>}
// body is supplied OVER THE WIRE as a §2.7 node forest — the SAME flat pre-order
// `node KIND … child_count` line run the artifact's [probes] section carries —
// folded through the EXISTING parse_node_forest. The client (or funpack) compiles the
// predicate/expression to nodes; the runtime only interprets, exactly as it interprets
// an in-code probe's carried body. The runtime owns no funpack compiler and never
// parses a source string here (§29 §1).
package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Live_Probe is one §28 §3 session-set break/watch directive: a stable per-session
// `handle` (minted monotonically so `clear` removes it by id), the `probe` it honors
// (a Probe_Decl of kind Break or Watch — the SAME shape an in-code @break/@watch
// loads as, so the honor seam treats live and in-code probes identically), and, for
// a `break{on_signal}`, the `on_signal` signal-type name it pauses on (empty for a
// predicate break / a watch). A live probe is honored by re-folding the recording
// with it armed — never compiled, never folded into the canonical chain.
Live_Probe :: struct {
	handle:    int,
	probe:     Probe_Decl,
	on_signal: string, // non-empty ⇒ a break{on_signal} (fires on a routed signal, not a behavior step)
}

// break_request dispatches one §28 §3 break-group command. All three are
// OBSERVE-class: `break`/`watch` register a live probe and report the firings it
// produces over the recording; `clear` removes one by handle. None forks a branch or
// writes the canonical chain — the registry is the only mutation, and honoring
// re-folds into scratch (§28 §2 non-perturbing).
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

// break_set registers a live §28 §3 break. Two forms (§28 §3 table):
//   break{when:<pred>}  — pause when the node-forest predicate holds at a behavior
//                         step (the live twin of @break(<pred>)); requires
//                         args.target (the behavior to fold the predicate against)
//                         and args.body (the predicate node forest over the wire).
//   break{on_signal:S}  — pause when a signal of type S is routed during a tick;
//                         requires args.on_signal, carries no predicate body.
// Exactly one form per request — supplying both `when`/`body` and `on_signal`, or
// neither, is refused. The minted handle is returned so the agent can `clear` it, and
// the firings the new break produces over the recording ride back in the same
// response (breakpoint_hit lines).
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
		// break{on_signal}: no predicate body, no behavior target — it fires on a
		// routed signal of the named type. The signal must be a declared signal type
		// (addressing reuses index identity, §28 §2), refused otherwise.
		if program_signal(s.program, signal) == nil {
			return error_response(id, "break", "unknown signal type", allocator)
		}
		handle := register_live_probe(s, Live_Probe{probe = Probe_Decl{kind = .Break}, on_signal = signal})
		return break_set_response(s, id, handle, allocator)
	}

	// break{when:<pred>}: a predicate node forest folded against a behavior's bound
	// env, exactly as an in-code @break. The target names the behavior, the body is
	// the wire node forest.
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

// watch_set registers a live §28 §3 watch: watch{<expr>} on a behavior fires
// watch_fired when the node-forest expression's value CHANGES across steps — the
// live twin of @watch(<expr>). Requires args.target (the behavior) and args.body
// (the watched expression node forest over the wire). The minted handle is returned;
// the firings the watch produces over the recording ride back in the response
// (watch_fired lines).
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

// break_clear removes one live probe by handle (§28 §3 `clear`) — the live break
// evaporates, exactly as a live command's persistence model intends (§28 §4: "a live
// break evaporates with the session"). An unknown handle is refused, never a silent
// no-op, so a stale clear surfaces. The response reports the remaining live-probe
// count so the agent sees the registry shrink.
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

// register_live_probe appends a live probe under a freshly minted monotonic handle
// and returns it. The registry lives on the session allocator (it outlives the
// request), so the wire-parsed body the probe carries stays valid for the session's
// lifetime — every later honor re-fold reads it.
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

// parse_wire_node_forest reads a break/watch body off the request: args.body is a
// JSON array of the SAME flat pre-order `node KIND … child_count` lines the
// artifact's [probes] section carries (§28 §2: the body is a node forest the client
// supplies, never funpack source). The lines fold through the EXISTING
// parse_node_forest into exactly ONE statement subtree (a break predicate / a watched
// expression is one expression body, body_count 1 — the same shape an in-code
// @break/@watch carries). ok=false for a missing/non-array body, a non-string
// element, or a forest that does not fold to exactly one subtree.
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
	// A break predicate / watched expression is exactly one expression subtree
	// (body_count 1) — the SAME shape load_probes parses for an in-code @break/@watch.
	forest, err := parse_node_forest(lines[:], 1, allocator)
	if err != .None {
		return nil, false
	}
	return forest, true
}

// break_set_response answers a `break` registration: the minted handle, the live
// flag, and the breakpoint_hit firings the new break produces over the recording —
// the honor re-fold drained into the response, so the agent sees the break's effect
// in the same round-trip (the synchronous fold's stand-in for the async pushes a live
// host would stream, introspect.odin header). Field order is fixed — byte-stable for
// the session log (§28 §3).
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

// watch_set_response answers a `watch` registration: the minted handle, the live
// flag, and the watch_fired firings the new watch produces over the recording (the
// value-change stream). Same drained-re-fold shape break_set_response uses, with the
// watch_fired event payload.
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

// honor_live_break_hits re-folds the WHOLE recording with the session's live probes
// armed and returns the breakpoint_hit firings — both the behavior-step predicate
// breaks (honored at the behavior-step seam by session_honor_probes) and the
// on_signal breaks (honored over the signal routes by honor_live_signal_breaks). The
// re-fold is OBSERVE-class: session_honor_probes builds its own scratch chain, so the
// canonical chain is untouched (§28 §2). Returns hits in fold order (predicate hits
// across ticks, then signal hits across ticks).
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

// honor_live_watch_fires re-folds the WHOLE recording with the session's live probes
// armed and returns the watch_fired firings the live @watch group produced. The
// re-fold is observe-class (session_honor_probes builds its own scratch chain), so a
// live watch reports value changes without touching the canonical chain.
@(private = "file")
honor_live_watch_fires :: proc(s: ^Debug_Session, allocator := context.allocator) -> []Watch_Fire {
	honor, _ := session_honor_probes(s, allocator)
	fires := make([dynamic]Watch_Fire, 0, len(honor.watches), allocator)
	for fire in honor.watches {
		append(&fires, fire)
	}
	return fires[:]
}

// honor_live_signal_breaks honors every live break{on_signal} over the recording: a
// signal break fires once per tick a signal of its named type is ROUTED. Routing is
// observed through the SAME observe tap the `signals` command reads (Tick_Observe's
// Signal_Capture), re-folding each tick into scratch (session_refold_tick) — a pure
// read of the recorded fold, so this is observe-class like every other break-group
// path. A breakpoint_hit is stamped with the routing tick and the signal as the
// target (addressing reuses index identity, §28 §2); the self payload is the signal
// type (a signal break is not bound to one instance's blackboard).
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

// signal_routed_in_tick reports whether a signal of `signal_type` was routed during
// the re-folded tick — a pure read of the observe tap's captured routes (broadcast or
// engine per-instance, both carry the signal type). The §28 §3 break{on_signal}
// trigger: a signal break pauses on the FIRST route of its type in a tick.
@(private = "file")
signal_routed_in_tick :: proc(obs: Tick_Observe, signal_type: string) -> bool {
	for capture in obs.signals {
		if capture.signal == signal_type {
			return true
		}
	}
	return false
}

// program_signal resolves a §11 signal declaration by name, or nil — the addressing
// check a break{on_signal} runs (the named signal must be a declared type; §28 §2
// addressing reuses index identity). Mirrors program_behavior's bare-name lookup.
program_signal :: proc(program: ^Program, name: string) -> ^Signal_Decl {
	for &signal in program.signals {
		if signal.name == name {
			return &signal
		}
	}
	return nil
}
