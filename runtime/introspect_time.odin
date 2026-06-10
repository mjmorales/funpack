// The §28 §3 time command group — load / run / pause / step / rewind / reset /
// status — riding the introspection session fold (introspect.odin). All seven
// are observe-class: they navigate a CURSOR over the recorded canonical
// timeline and never write the session's retained chain or fork a branch, so a
// time battery leaves the canonical digests bit-identical (the acceptance pin
// in introspect_time_test.odin).
//
// REWIND IS SNAPSHOT + BOUNDED REPLAY (§28 §3): the cursor maintains a
// fixed-cadence ring of COW snapshots — every TIME_SNAPSHOT_CADENCE-th
// committed cursor tick retains its World_Version root (structural sharing
// makes the retention a root pointer, §08 §4) plus the Rng entering the next
// tick. `rewind` restores the nearest snapshot at-or-before the target and
// re-folds the RECORDED inputs forward to the exact tick through the SAME
// step_tick seam every driver runs — bit-exact by determinism, which the tests
// pin against the session's independently retained canonical chain. The ring
// is BOUNDED (TIME_RING_SLOTS — a fixed engine budget, §28 §3: no spec
// numbers, no per-build knob): a push past capacity overwrites the oldest
// insertion. The post-startup version is retained permanently by the session
// (Debug_Session.startup), so a target below the oldest ring entry restores
// from that floor — a longer re-fold, never a refusal.
//
// The reclaim discipline (team Lore #17) is respected by NOT freeing: every
// cursor fold and ring entry lives on the session allocator, and rewound-past
// versions share structure with retained ones — a selective free here would
// have to walk the structural-sharing aliases, so the session keeps its
// allocations for its lifetime (sessions are dev-only and bounded, §28 §3).
//
// In the pure request/response fold the session is at rest between requests, so
// `run` folds synchronously to its target and `pause` is the idempotent
// position ack the async live host gives meaning to (the duplex adapter is the
// deferred seam, introspect.odin header).
package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// TIME_SNAPSHOT_CADENCE is the fixed engine constant (§28 §3: "cadence is a
// fixed engine constant") — the cursor retains a ring snapshot every Nth
// committed tick (ticks 0, N, 2N, …).
TIME_SNAPSHOT_CADENCE :: 16

// TIME_RING_SLOTS is the bounded ring capacity — the fixed engine budget the
// §28 §3 trace/time-travel buffer is bounded by. A push past capacity
// overwrites the oldest insertion.
TIME_RING_SLOTS :: 32

// Time_Snapshot is one ring entry: the committed version OF `tick` plus the
// Rng entering tick+1 (seeded runs; zero-valued and unread when seedless), so
// a re-fold from this base draws exactly what the canonical tick+1 drew.
Time_Snapshot :: struct {
	tick:    int,
	version: World_Version,
	rng:     Rng,
}

// Time_Cursor is the session's time-travel position: the loaded flag (the time
// group refuses until `load` arms it), the current tick (-1 = post-startup),
// the committed head AT that tick, the Rng entering tick+1, and the bounded
// fixed-cadence snapshot ring. Snapshots stay valid across rewinds — they
// snapshot the CANONICAL recorded timeline, which is deterministic, so a
// rewind never invalidates an entry ahead of the cursor.
Time_Cursor :: struct {
	loaded:    bool,
	tick:      int,
	head:      World_Version,
	rng:       Rng,
	ring:      [TIME_RING_SLOTS]Time_Snapshot,
	ring_len:  int, // occupied slots
	ring_next: int, // next write index (wraps — the oldest insertion is overwritten)
}

// time_request dispatches one §28 §3 time command. `load` and `status` work on
// any session; the navigation commands refuse until a timeline is loaded.
time_request :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	if cmd == "load" {
		return time_load(s, id, allocator)
	}
	if cmd == "status" {
		return time_status(s, id, allocator)
	}
	if !s.cursor.loaded {
		return error_response(id, cmd, "no timeline loaded — issue load first", allocator)
	}
	switch cmd {
	case "run":
		return time_run(s, id, args, allocator)
	case "pause":
		return time_position_response(s, id, "pause", allocator)
	case "step":
		return time_step(s, id, allocator)
	case "rewind":
		return time_rewind(s, id, args, allocator)
	case "reset":
		return time_reset(s, id, allocator)
	}
	return error_response(id, cmd, "unknown time command", allocator)
}

// time_load arms the cursor at the post-startup version (tick -1, the state
// tick 0 folds from) with the Rng entering tick 0. Re-issuing load re-arms,
// clearing the ring — a fresh timeline walk.
@(private = "file")
time_load :: proc(s: ^Debug_Session, id: i64, allocator := context.allocator) -> string {
	cursor := Time_Cursor {
		loaded = true,
		tick   = -1,
		head   = s.startup,
	}
	if s.seed.has_seed {
		cursor.rng = s.rngs[0]
	}
	s.cursor = cursor
	return time_position_response(s, id, "load", allocator)
}

// time_run folds the recorded inputs forward from the cursor to args.until
// (default: the last recorded tick) — the synchronous `run`. A target behind
// the cursor is rewind's job and is refused as such.
@(private = "file")
time_run :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	until := i64(len(s.snapshots) - 1)
	if requested, has_until := json_int_field(args, "until"); has_until {
		until = requested
	}
	if int(until) >= len(s.snapshots) {
		return error_response(id, "run", "tick out of range", allocator)
	}
	if int(until) < s.cursor.tick {
		return error_response(id, "run", "target behind cursor — rewind instead", allocator)
	}
	for s.cursor.tick < int(until) {
		time_advance_cursor(s)
	}
	return time_position_response(s, id, "run", allocator)
}

// time_step single-ticks the cursor — one recorded tick through the production
// fold. The end of the recording is a refusal, never a silent no-op.
@(private = "file")
time_step :: proc(s: ^Debug_Session, id: i64, allocator := context.allocator) -> string {
	if s.cursor.tick >= len(s.snapshots) - 1 {
		return error_response(id, "step", "end of recording", allocator)
	}
	time_advance_cursor(s)
	return time_position_response(s, id, "step", allocator)
}

// time_rewind restores the nearest snapshot at-or-before args.tick and
// re-folds the recorded inputs to the exact target tick (§28 §3: rewind =
// nearest snapshot ≤ target + bounded replay forward). The response names the
// base it restored from and how many ticks it re-folded — the bounded-replay
// shape made observable.
@(private = "file")
time_rewind :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	target, has_target := json_int_field(args, "tick")
	if !has_target {
		return error_response(id, "rewind", "missing args.tick", allocator)
	}
	if int(target) < -1 || int(target) >= len(s.snapshots) {
		return error_response(id, "rewind", "tick out of range", allocator)
	}
	base := time_ring_base(s, int(target))
	s.cursor.tick = base.tick
	s.cursor.head = base.version
	if s.seed.has_seed {
		s.cursor.rng = base.rng
	}
	refolded := 0
	for s.cursor.tick < int(target) {
		time_advance_cursor(s)
		refolded += 1
	}
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "rewind")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"restored_from\":%d,\"refolded\":%d}}}}", s.cursor.tick, base.tick, refolded)
	return strings.to_string(b)
}

// time_reset returns the cursor to tick zero's fold base — the post-startup
// version, Rng entering tick 0. The ring is kept: its entries snapshot the
// deterministic canonical timeline, so they stay valid for the next walk.
@(private = "file")
time_reset :: proc(s: ^Debug_Session, id: i64, allocator := context.allocator) -> string {
	s.cursor.tick = -1
	s.cursor.head = s.startup
	if s.seed.has_seed {
		s.cursor.rng = s.rngs[0]
	}
	return time_position_response(s, id, "reset", allocator)
}

// time_status reports the session shape: load state, cursor position, the
// recording's extent, seededness, the ring's fixed constants and live
// occupancy, and whether a control branch is live. Field order is fixed —
// byte-stable for the session log, like every envelope.
@(private = "file")
time_status :: proc(s: ^Debug_Session, id: i64, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "status")
	strings.write_string(&b, "{\"loaded\":")
	strings.write_string(&b, s.cursor.loaded ? "true" : "false")
	strings.write_string(&b, ",\"tick\":")
	if s.cursor.loaded {
		fmt.sbprintf(&b, "%d", s.cursor.tick)
	} else {
		strings.write_string(&b, "null")
	}
	fmt.sbprintf(
		&b,
		",\"ticks_recorded\":%d,\"seeded\":%s,\"cadence\":%d,\"ring\":{{\"slots\":%d,\"occupied\":%d,",
		len(s.snapshots),
		s.seed.has_seed ? "true" : "false",
		TIME_SNAPSHOT_CADENCE,
		TIME_RING_SLOTS,
		s.cursor.ring_len,
	)
	oldest, newest, occupied := time_ring_extent(&s.cursor)
	strings.write_string(&b, "\"oldest\":")
	if occupied {
		fmt.sbprintf(&b, "%d", oldest)
	} else {
		strings.write_string(&b, "null")
	}
	strings.write_string(&b, ",\"newest\":")
	if occupied {
		fmt.sbprintf(&b, "%d", newest)
	} else {
		strings.write_string(&b, "null")
	}
	fmt.sbprintf(&b, "}},\"branch\":{{\"live\":%s}}}}}}", s.has_branch ? "true" : "false")
	return strings.to_string(b)
}

// time_position_response is the shared success envelope for the position-only
// time commands: the cursor tick is the whole result.
@(private = "file")
time_position_response :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, cmd)
	fmt.sbprintf(&b, "{{\"tick\":%d}}}}", s.cursor.tick)
	return strings.to_string(b)
}

// time_advance_cursor folds ONE recorded tick onto the cursor through the
// production seam — the identical step_tick the canonical fold ran, the same
// per-tick Time derivation, the cursor's threaded Rng for a seeded run — and
// retains a ring snapshot on the fixed cadence. The caller guards the
// recording bound. Cursor state outlives requests, so the fold allocates on
// the session allocator.
@(private = "file")
time_advance_cursor :: proc(s: ^Debug_Session) {
	next := s.cursor.tick + 1
	time := time_resource_at(s.program.entrypoint.tick_hz, next, s.allocator)
	if s.seed.has_seed {
		s.cursor.head = step_tick(s.program, s.cursor.head, s.snapshots[next], time, s.allocator, &s.cursor.rng)
	} else {
		s.cursor.head = step_tick(s.program, s.cursor.head, s.snapshots[next], time, s.allocator)
	}
	s.cursor.tick = next
	if next % TIME_SNAPSHOT_CADENCE == 0 {
		time_ring_push(&s.cursor, Time_Snapshot{tick = next, version = s.cursor.head, rng = s.cursor.rng})
	}
}

// time_ring_push retains one snapshot: an entry for the same tick is replaced
// in place (a rewind's re-fold re-reaches cadence ticks — the re-committed
// version is bit-identical, so the replace is a no-op by value); otherwise the
// entry lands at the write index, overwriting the oldest insertion once the
// ring is full.
@(private = "file")
time_ring_push :: proc(c: ^Time_Cursor, snapshot: Time_Snapshot) {
	for i in 0 ..< c.ring_len {
		if c.ring[i].tick == snapshot.tick {
			c.ring[i] = snapshot
			return
		}
	}
	c.ring[c.ring_next] = snapshot
	c.ring_next = (c.ring_next + 1) % TIME_RING_SLOTS
	if c.ring_len < TIME_RING_SLOTS {
		c.ring_len += 1
	}
}

// time_ring_base resolves rewind's restore base: the occupied ring entry with
// the greatest tick at-or-before the target, or the permanently retained
// post-startup floor (tick -1, Rng entering tick 0) when no entry qualifies.
@(private = "file")
time_ring_base :: proc(s: ^Debug_Session, target: int) -> Time_Snapshot {
	base := Time_Snapshot {
		tick    = -1,
		version = s.startup,
	}
	if s.seed.has_seed {
		base.rng = s.rngs[0]
	}
	for i in 0 ..< s.cursor.ring_len {
		entry := s.cursor.ring[i]
		if entry.tick <= target && entry.tick > base.tick {
			base = entry
		}
	}
	return base
}

// time_ring_extent reports the occupied ring's tick span (oldest, newest) —
// the status surface's ring shape. occupied=false for an empty ring.
@(private = "file")
time_ring_extent :: proc(c: ^Time_Cursor) -> (oldest: int, newest: int, occupied: bool) {
	if c.ring_len == 0 {
		return 0, 0, false
	}
	oldest = c.ring[0].tick
	newest = c.ring[0].tick
	for i in 1 ..< c.ring_len {
		tick := c.ring[i].tick
		if tick < oldest {
			oldest = tick
		}
		if tick > newest {
			newest = tick
		}
	}
	return oldest, newest, true
}
