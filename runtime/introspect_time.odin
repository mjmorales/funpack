package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

TIME_SNAPSHOT_CADENCE :: 16

TIME_RING_SLOTS :: 32

Time_Snapshot :: struct {
	tick:    int,
	version: World_Version,
	rng:     Rng,
}

Time_Cursor :: struct {
	loaded:    bool,
	tick:      int,
	head:      World_Version,
	rng:       Rng,
	ring:      [TIME_RING_SLOTS]Time_Snapshot,
	ring_len:  int,
	ring_next: int,
}

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
		return time_step(s, id, args, allocator)
	case "rewind":
		return time_rewind(s, id, args, allocator)
	case "reset":
		return time_reset(s, id, allocator)
	}
	return error_response(id, cmd, "unknown time command", allocator)
}

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

@(private = "file")
time_run :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	if refusal, refuse := time_advance_lineage_refusal(s, id, "run", args, allocator); refuse {
		return refusal
	}
	if time_on_writable_branch(s) {
		until := i64(branch_tip_tick(s) + 1)
		if requested, has_until := json_int_field(args, "until"); has_until {
			until = requested
		}
		if int(until) < branch_tip_tick(s) {
			return error_response(id, "run", "target behind branch tip — rewind instead", allocator)
		}
		for branch_tip_tick(s) < int(until) {
			branch_advance_tick(s)
		}
		return time_position_response(s, id, "run", allocator)
	}
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

@(private = "file")
time_step :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	if refusal, refuse := time_advance_lineage_refusal(s, id, "step", args, allocator); refuse {
		return refusal
	}
	if time_on_writable_branch(s) {
		branch_advance_tick(s)
		return time_position_response(s, id, "step", allocator)
	}
	if s.cursor.tick >= len(s.snapshots) - 1 {
		return error_response(id, "step", "end of recording", allocator)
	}
	time_advance_cursor(s)
	return time_position_response(s, id, "step", allocator)
}

@(private = "file")
time_on_writable_branch :: proc(s: ^Debug_Session) -> bool {
	return s.active_branch && s.has_branch
}

@(private = "file")
time_advance_lineage_active :: proc(s: ^Debug_Session) -> string {
	if s.active_branch && s.has_branch {
		return "branch"
	}
	return "canonical"
}

@(private = "file")
time_advance_lineage_refusal :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	args: json.Object,
	allocator := context.allocator,
) -> (
	refusal: string,
	refuse: bool,
) {
	name, has := json_string_field(args, "branch")
	if !has {
		return "", false
	}
	active := time_advance_lineage_active(s)
	if name == active {
		return "", false
	}
	switch name {
	case "canonical":
		return error_response(
			id,
			cmd,
			"branch \"canonical\" is not the active lineage — checkout it first (control_checkout{target:\"canonical\"})",
			allocator,
		), true
	case "branch":
		return error_response(
			id,
			cmd,
			"branch \"branch\" is not checked out — advancing it requires control_checkout{target:\"branch\"} first",
			allocator,
		), true
	}
	return error_response(
		id,
		cmd,
		fmt.tprintf(
			"unknown branch selector %q — advancing requires the named lineage be the active one (control_checkout first)",
			name,
		),
		allocator,
	), true
}

@(private = "file")
branch_advance_tick :: proc(s: ^Debug_Session) {
	branch := &s.branch
	logical := branch_tip_tick(s) + 1
	time := time_resource_at(s.program.entrypoint.tick_hz, logical, s.allocator)
	if branch.has_rng {
		branch.head = step_tick(branch.program, branch.head, empty(), time, s.allocator, &branch.rng)
	} else {
		branch.head = step_tick(branch.program, branch.head, empty(), time, s.allocator)
	}
	branch.ticks += 1
}

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

@(private = "file")
time_reset :: proc(s: ^Debug_Session, id: i64, allocator := context.allocator) -> string {
	s.cursor.tick = -1
	s.cursor.head = s.startup
	if s.seed.has_seed {
		s.cursor.rng = s.rngs[0]
	}
	return time_position_response(s, id, "reset", allocator)
}

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
		",\"ticks_recorded\":%d,\"seeded\":%s,\"uses_rng\":%s,\"cadence\":%d,\"ring\":{{\"slots\":%d,\"occupied\":%d,",
		len(s.snapshots),
		s.seed.has_seed ? "true" : "false",
		program_uses_rng(s.program) ? "true" : "false",
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
	fmt.sbprintf(
		&b,
		"}},\"branch\":{{\"live\":%s,\"active\":\"%s\"}}}}}}",
		s.has_branch ? "true" : "false",
		s.active_branch && s.has_branch ? "branch" : "canonical",
	)
	return strings.to_string(b)
}

@(private = "file")
time_position_response :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	allocator := context.allocator,
) -> string {
	tick := time_on_writable_branch(s) ? branch_tip_tick(s) : s.cursor.tick
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, cmd)
	fmt.sbprintf(&b, "{{\"tick\":%d}}}}", tick)
	return strings.to_string(b)
}

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
