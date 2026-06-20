// The §28 control side of the introspection session — perturbing commands, so
// every one of them FORKS (§28 §2): a control command never touches the
// canonical committed chain; it lands on a Session_Branch, a new lineage off a
// committed snapshot, marked non-warranted in every response. COW structural
// sharing makes the fork a root-pointer copy, and the canonical-untouched
// acceptance test (introspect_control_test.odin) digest-pins the trunk across a
// full control battery — the §28 §1 observe/control theorem made mechanical.
//
// Control is §08's CQRS write side exposed as a DEBUG-ONLY path: `set`, `spawn`,
// `despawn`, and `emit` go through the ORDINARY transaction shapes (new_tick_state →
// working-table write / spawn-despawn batch / mailbox route → commit_tick_state at
// the boundary), never an ad-hoc version mutation; `inject_input` feeds the §23
// action-snapshot path through the SAME step_tick fold a live device feeds; and
// `reload` reuses hot_reload_swap — the §09 §3 gated atomic swap — on the BRANCH
// program, keeping last-good code on any refusal. Because these writes happen
// OUTSIDE the normal own-blackboard/signal/command path, the branch lineage is
// non-warranted by construction, which is exactly why it forks.
//
// Command payloads are funpack values as strings, decoded through the §28 DEBUG codec
// (decode_default_value with human=true): the SAME source-literal spelling the observe
// side now renders (`Vec2(x=96.0,y=90.0)`, `110.0` — F17), so an observed value pastes
// back verbatim as a control payload (F18), and an older raw Q32.32 payload still
// decodes (the dot discriminates). A decode failure names the field, its type, and a
// sample literal (value_decode_error) instead of a bare rejection.
package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Session_Branch is one forked control lineage: the canonical tick it forked at,
// its own program (the session's until a `reload` swaps the branch onto a
// recompiled artifact), its committed head, and its forked Rng thread (seeded
// runs). `ticks` counts the branch commits since the fork — the branch's own
// logical time, continuing the canonical tick numbering it forked from.
Session_Branch :: struct {
	base_tick:       int, // the canonical tick the fork snapshotted (-1 = post-startup)
	program_storage: Program, // owned program after a reload swap (unused before one)
	program:         ^Program, // the branch's current program (session program until reload)
	head:            World_Version, // the branch's committed head
	ticks:           int, // branch commits since the fork
	rng:             Rng, // the branch's forked Rng thread (seeded runs)
	has_rng:         bool,
}

// control_request dispatches one control command. The PERTURBING arms
// (branch / inject_input / set / spawn / despawn / emit / reload) fork first (ensure_branch
// — an implicit fork at the canonical head when no branch is live), perturb ONLY
// the branch, and answer with the branch position plus `"warranted":false` (§28
// §2: a control lineage is never warranted). `checkout` is the lone NON-perturbing
// arm: it forks nothing and only switches which already-committed lineage observe
// reads (§28 §2 active-lineage selector). The canonical chain is read-only
// throughout — every arm forks or navigates, none mutates the trunk.
control_request :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	switch cmd {
	case "branch":
		return control_branch(s, id, args, allocator)
	case "checkout":
		return control_checkout(s, id, args, allocator)
	case "inject_input":
		return control_inject_input(s, id, args, allocator)
	case "set":
		return control_set(s, id, args, allocator)
	case "spawn":
		return control_spawn(s, id, args, allocator)
	case "despawn":
		return control_despawn(s, id, args, allocator)
	case "emit":
		return control_emit(s, id, args, allocator)
	case "reload":
		return control_reload(s, id, args, allocator)
	}
	return error_response(id, cmd, "unknown control command", allocator)
}

// fork_branch snapshots the canonical chain at `tick` into a fresh branch: the
// committed version is the COW root (no copy — structural sharing), the Rng
// thread is the retained state ENTERING tick+1 (so the branch's first fold draws
// exactly what the canonical tick+1 would have), and the branch program starts
// as the session program. Re-forking replaces any prior branch.
@(private = "file")
fork_branch :: proc(s: ^Debug_Session, tick: int) -> bool {
	head, ok := session_version_at(s, tick)
	if !ok {
		return false
	}
	branch := Session_Branch {
		base_tick = tick,
		program   = s.program,
		head      = head,
	}
	if s.seed.has_seed {
		branch.rng = s.rngs[tick + 1]
		branch.has_rng = true
	}
	s.branch = branch
	s.has_branch = true
	return true
}

// ensure_branch makes a control command's implicit fork: when no branch is
// live, fork at the canonical head (the latest committed tick; -1 when the
// recorded run is empty). A live branch is kept — control commands chain on it.
@(private = "file")
ensure_branch :: proc(s: ^Debug_Session) {
	if s.has_branch {
		return
	}
	fork_branch(s, len(s.versions) - 1)
}

// branch_logical_tick is the tick ordinal the NEXT branch fold represents — the
// canonical numbering continued past the fork point, driving the branch's
// per-tick Time derivation exactly as the canonical fold derives it.
@(private = "file")
branch_logical_tick :: proc(s: ^Debug_Session) -> int {
	return s.branch.base_tick + 1 + s.branch.ticks
}

// control_ok_response renders a control success: the branch position object plus
// the §28 §2 non-warranted mark, then any command-specific extra fields the
// caller appended into `extras` (a pre-rendered `,"k":v` run, possibly empty).
@(private = "file")
control_ok_response :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	extras: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"{{\"v\":%d,\"id\":%d,\"ok\":true,\"cmd\":",
		INTROSPECT_PROTOCOL_VERSION,
		id,
	)
	write_json_string(&b, cmd)
	fmt.sbprintf(
		&b,
		",\"result\":{{\"branch\":{{\"base_tick\":%d,\"ticks\":%d}},\"warranted\":false%s}}}}",
		s.branch.base_tick,
		s.branch.ticks,
		extras,
	)
	return strings.to_string(b)
}

// control_branch is the explicit fork: snapshot the canonical chain at
// args.tick (default: the canonical head) into a fresh branch — the git-like
// "what if?" fork (§28 §2). Re-issuing `branch` re-forks, discarding the prior
// branch lineage.
@(private = "file")
control_branch :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick := i64(len(s.versions) - 1)
	if requested, has_tick := json_int_field(args, "tick"); has_tick {
		tick = requested
	}
	if !fork_branch(s, int(tick)) {
		return error_response(id, "branch", "tick out of range", allocator)
	}
	return control_ok_response(s, id, "branch", "", allocator)
}

// control_checkout switches the session's ACTIVE lineage (§28 §2: observe reads
// the canonical chain by default, or the active branch once checked out). It is
// the git-like `checkout` paired with `branch`'s fork: `branch` creates the
// lineage, `checkout` makes it the one observe/time read WITHOUT a per-call
// `branch` arg. The target is the live branch (default, or `target:"branch"`) or
// `target:"canonical"`. Checking out the branch when NONE is live fails closed —
// there is no such lineage to navigate to ("navigation among already-existing
// lineages"). UNLIKE every other control command, checkout is NON-PERTURBING: it
// forks nothing and mutates no recorded state, it only flips which already-
// committed lineage the resolver reads, so the determinism warranty is untouched.
@(private = "file")
control_checkout :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	target := "branch"
	if requested, has_target := json_string_field(args, "target"); has_target {
		target = requested
	}
	switch target {
	case "canonical":
		s.active_branch = false
		return checkout_ok_response(s, id, allocator)
	case "branch":
		if !s.has_branch {
			return error_response(id, "checkout", "no branch to checkout — branch first", allocator)
		}
		s.active_branch = true
		return checkout_ok_response(s, id, allocator)
	}
	return error_response(id, "checkout", "unknown checkout target (branch|canonical)", allocator)
}

// checkout_ok_response renders the checkout success: the now-active lineage and
// the lineage's warranty (the canonical trunk is warranted; a forked branch is
// not, §28 §2). Field order is fixed — byte-stable for the session log.
@(private = "file")
checkout_ok_response :: proc(
	s: ^Debug_Session,
	id: i64,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "{{\"v\":%d,\"id\":%d,\"ok\":true,\"cmd\":\"checkout\",\"result\":{{\"active\":", INTROSPECT_PROTOCOL_VERSION, id)
	if s.active_branch {
		fmt.sbprintf(&b, "\"branch\",\"warranted\":false,\"branch\":{{\"base_tick\":%d,\"ticks\":%d}}}}}}", s.branch.base_tick, s.branch.ticks)
	} else {
		strings.write_string(&b, "\"canonical\",\"warranted\":true}}")
	}
	return strings.to_string(b)
}

// control_inject_input feeds the §23 action-snapshot path on the branch: the
// args describe one deterministic snapshot (pressed/held buttons, 1D values, 2D
// axes — actions named by their `Enum::Variant` token, players by P1..P4), and
// the branch folds `ticks` (default 1) full pipeline ticks through the SAME
// step_tick seam a live device-fed run drives, threading the branch Rng. This
// is the injected-device-queue determinism contract: the snapshot is the input,
// the device is irrelevant.
@(private = "file")
control_inject_input :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	snapshot, build_err := build_injected_input(branch.program, args, allocator)
	if build_err != "" {
		return error_response(id, "inject_input", build_err, allocator)
	}
	ticks := i64(1)
	if requested, has_ticks := json_int_field(args, "ticks"); has_ticks {
		ticks = requested
	}
	if ticks < 1 {
		return error_response(id, "inject_input", "ticks must be >= 1", allocator)
	}
	tick_hz := branch.program.entrypoint.tick_hz
	for _ in 0 ..< ticks {
		time := time_resource_at(tick_hz, branch_logical_tick(s), allocator)
		if branch.has_rng {
			branch.head = step_tick(branch.program, branch.head, snapshot, time, allocator, &branch.rng)
		} else {
			branch.head = step_tick(branch.program, branch.head, snapshot, time, allocator)
		}
		branch.ticks += 1
	}
	return control_ok_response(s, id, "inject_input", "", allocator)
}

// build_injected_input assembles one §23 action snapshot from the request args.
// Actions resolve through the program's deterministic action registry (the same
// minting a binding resolves through); analog values are Fixed raw-bit strings
// (§16 §2.3). Returns a non-empty error string on the first unresolvable entry.
@(private = "file")
build_injected_input :: proc(
	program: ^Program,
	args: json.Object,
	allocator := context.allocator,
) -> (
	snapshot: Input,
	err: string,
) {
	registry := build_action_registry(program^, allocator)
	snapshot = empty()

	if entries, has := json_array_field(args, "pressed"); has {
		for entry in entries {
			player, action, _, _, entry_err := injected_entry(registry, entry)
			if entry_err != "" {
				return snapshot, entry_err
			}
			snapshot = with_pressed(snapshot, player, action)
		}
	}
	if entries, has := json_array_field(args, "held"); has {
		for entry in entries {
			player, action, _, _, entry_err := injected_entry(registry, entry)
			if entry_err != "" {
				return snapshot, entry_err
			}
			snapshot = with_held(snapshot, player, action)
		}
	}
	if entries, has := json_array_field(args, "values"); has {
		for entry in entries {
			player, action, value, _, entry_err := injected_entry(registry, entry, "value")
			if entry_err != "" {
				return snapshot, entry_err
			}
			snapshot = with_value(snapshot, player, action, value)
		}
	}
	if entries, has := json_array_field(args, "axes"); has {
		for entry in entries {
			player, action, x, y, entry_err := injected_entry(registry, entry, "x", "y")
			if entry_err != "" {
				return snapshot, entry_err
			}
			snapshot = with_axis(snapshot, player, action, Vec2{x = x, y = y})
		}
	}
	return snapshot, ""
}

// injected_entry resolves one input-record object: `player` (P1..P4), `action`
// (the registry's `Enum::Variant` token), and up to two Fixed raw-bit string
// fields named by the callers (a 1D `value`, a 2D `x`/`y`). Unrequested analog
// slots return Fixed(0).
@(private = "file")
injected_entry :: proc(
	registry: Action_Registry,
	entry: json.Value,
	analog_keys: ..string,
) -> (
	player: PlayerId,
	action: ActionId,
	first: Fixed,
	second: Fixed,
	err: string,
) {
	object, is_object := entry.(json.Object)
	if !is_object {
		return .P1, ActionId(0), 0, 0, "input record must be an object"
	}
	player_name, has_player := json_string_field(object, "player")
	if !has_player {
		return .P1, ActionId(0), 0, 0, "input record missing player"
	}
	resolved_player, player_ok := parse_player(player_name)
	if !player_ok {
		return .P1, ActionId(0), 0, 0, "unknown player (P1..P4)"
	}
	action_name, has_action := json_string_field(object, "action")
	if !has_action {
		return resolved_player, ActionId(0), 0, 0, "input record missing action"
	}
	def, has_def := registry.by_name[action_name]
	if !has_def {
		return resolved_player, ActionId(0), 0, 0, "unknown action"
	}
	analog := [2]Fixed{0, 0}
	for key, i in analog_keys {
		encoded, has_value := json_string_field(object, key)
		if !has_value {
			return resolved_player, def.id, 0, 0, "input record missing analog field"
		}
		decoded, decode_ok := decode_fixed(encoded)
		if !decode_ok {
			return resolved_player, def.id, 0, 0, "analog value must be Fixed raw bits"
		}
		analog[i] = decoded
	}
	return resolved_player, def.id, analog[0], analog[1], ""
}

// parse_player maps the wire token onto the §23 PlayerId enum.
@(private = "file")
parse_player :: proc(name: string) -> (player: PlayerId, ok: bool) {
	switch name {
	case "P1":
		return .P1, true
	case "P2":
		return .P2, true
	case "P3":
		return .P3, true
	case "P4":
		return .P4, true
	}
	return .P1, false
}

// control_value_matches_type guards the control decode against the §6 bare-token
// fallback silently accepting a TYPE-MISMATCHED value (F21). decode_default_value never
// FAILS for a known-concrete declared type — an undecodable token drops to a bare string
// column (the fallback the §6 artifact loader needs for unit-enum tokens against unknown
// data decls) — so `set Ball.pos not-a-vec` would store a string into a Vec2 column and
// report success. The control surface verifies the decoded arm matches the DECLARED type
// and refuses on mismatch. It tightens ONLY the known-concrete types (Int/Fixed/Bool/
// Vec2/Vec3/String/[T]/§3-data-record), where the footgun bites; an enum or §3-less
// type keeps the loader's bare-token leniency (validating an enum case is the loader's
// job, not this guard's), so no legitimate control payload regresses.
@(private = "file")
control_value_matches_type :: proc(program: ^Program, type_name: string, value: Field_Value) -> bool {
	switch type_name {
	case "Int":
		_, ok := value.(i64)
		return ok
	case "Fixed":
		_, ok := value.(Fixed)
		return ok
	case "Bool":
		_, ok := value.(bool)
		return ok
	case "Vec2":
		_, ok := value.(Vec2)
		return ok
	case "Vec3":
		_, ok := value.(Vec3)
		return ok
	case "String":
		_, ok := value.(String_Value)
		return ok
	}
	if strings.has_prefix(type_name, "[") {
		_, ok := value.(List_Value)
		return ok
	}
	if program_data(program, type_name) != nil {
		record, ok := value.(Record_Value)
		return ok && record.type_name == type_name
	}
	// An enum type or a type with no §3 Data_Decl: the legitimate column forms are a
	// bare unit-variant token, a payload Variant_Value, or a Ref — the loader's
	// bare-token domain, left untightened.
	return true
}

// value_decode_error builds the §28 set/spawn decode-failure message — F18's "state
// the expected encoding." A bare "does not decode" left the agent guessing the wire
// form; this names the field, its declared type, and a SAMPLE LITERAL in the exact
// source-literal spelling the surface now accepts (the inverse of the observe
// projection), so the remedy is shown, not just the failure.
@(private = "file")
value_decode_error :: proc(field: string, field_type: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"value does not decode for field %s (declared type %s) — expected a source literal like %s",
		field,
		field_type,
		field_type_sample_literal(field_type),
		allocator = allocator,
	)
}

// field_type_sample_literal returns a representative source-literal for a declared type
// — the remedy half of value_decode_error. The scalar types get their canonical
// spelling; the §10 vectors show the decimal-component constructor; an unknown type
// falls back to the Fixed sample (the numeric reading control inputs most often carry).
@(private = "file")
field_type_sample_literal :: proc(field_type: string) -> string {
	switch field_type {
	case "Int":
		return "42"
	case "Fixed":
		return "110.0"
	case "Bool":
		return "true"
	case "Vec2":
		return "Vec2(x=2.0,y=104.0)"
	case "Vec3":
		return "Vec3(x=2.0,y=104.0,z=0.0)"
	}
	if strings.has_prefix(field_type, "[") {
		return "[] (an empty list, or comma-joined element literals)"
	}
	return "110.0"
}

// control_set forces one blackboard column on the branch — the debug-only write
// outside the own-blackboard path (§28 §2), executed through the ORDINARY
// transaction shape: a working tick state off the branch head, the row's map
// replaced wholesale (the same replace-never-mutate discipline write_blackboard
// keeps, so the prior version's aliased map is untouched), committed at the
// boundary. The value decodes against the field's DECLARED type through the §28
// debug codec (human=true: source-literal Fixed accepted, F18).
@(private = "file")
control_set :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	thing, has_thing := json_string_field(args, "thing")
	field, has_field := json_string_field(args, "field")
	encoded, has_value := json_string_field(args, "value")
	if !has_thing || !has_field || !has_value {
		return error_response(id, "set", "missing args.thing, args.field, or args.value", allocator)
	}
	instance, _ := json_int_field(args, "instance")

	decl := program_thing(branch.program, thing)
	if decl == nil {
		return error_response(id, "set", "unknown thing", allocator)
	}
	field_type := thing_field_type(decl, field)
	if field_type == "" {
		return error_response(id, "set", "unknown field", allocator)
	}
	decoded, decode_ok := decode_default_value(branch.program, field_type, encoded, allocator, true)
	if !decode_ok || !control_value_matches_type(branch.program, field_type, decoded) {
		return error_response(id, "set", value_decode_error(field, field_type, allocator), allocator)
	}

	state := new_tick_state(branch.head, allocator, allocator)
	table := find_tick_table(state.tables, thing)
	if table == nil {
		return error_response(id, "set", "unknown thing", allocator)
	}
	row_idx, found := find_row_by_id(table.rows[:], Id{raw = Thing_Id(instance)})
	if !found {
		return error_response(id, "set", "no instance with that id", allocator)
	}
	next := make(map[string]Field_Value, allocator)
	for name, value in table.rows[row_idx].fields {
		next[name] = value
	}
	next[field] = decoded
	table.rows[row_idx].fields = next
	branch.head = commit_tick_state(branch.head, &state, allocator)
	branch.ticks += 1
	return control_ok_response(s, id, "set", "", allocator)
}

// control_spawn mints one new instance on the branch through the ordinary
// tick-boundary spawn batch: the blackboard is the thing's declared defaults
// with the supplied field overrides (each decoded against its declared type),
// queued and applied exactly as a behavior's [Spawn] emit lands. The minted Id
// is answered so the agent can address the new row.
@(private = "file")
control_spawn :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	thing, has_thing := json_string_field(args, "thing")
	if !has_thing {
		return error_response(id, "spawn", "missing args.thing", allocator)
	}
	decl := program_thing(branch.program, thing)
	if decl == nil {
		return error_response(id, "spawn", "unknown thing", allocator)
	}

	overrides: json.Object
	if nested, has_fields := args["fields"]; has_fields {
		if object, fields_ok := nested.(json.Object); fields_ok {
			overrides = object
		}
	}
	fields := make(map[string]Field_Value, allocator)
	for fd in decl.fields {
		if supplied, has_override := overrides[fd.name]; has_override {
			encoded, is_string := supplied.(json.String)
			if !is_string {
				return error_response(id, "spawn", "field overrides must be encoded strings", allocator)
			}
			decoded, decode_ok := decode_default_value(branch.program, fd.type, encoded, allocator, true)
			if !decode_ok || !control_value_matches_type(branch.program, fd.type, decoded) {
				return error_response(id, "spawn", value_decode_error(fd.name, fd.type, allocator), allocator)
			}
			fields[fd.name] = decoded
			continue
		}
		if decoded, decode_ok := decode_default(branch.program, fd, allocator); decode_ok {
			fields[fd.name] = decoded
		}
	}

	state := new_tick_state(branch.head, allocator, allocator)
	table := find_tick_table(state.tables, thing)
	if table == nil {
		return error_response(id, "spawn", "unknown thing", allocator)
	}
	minted := table.next_id
	queue_spawn(&state, thing, fields)
	apply_spawn_batch(&state)
	branch.head = commit_tick_state(branch.head, &state, allocator)
	branch.ticks += 1
	extras := fmt.aprintf(",\"instance\":%d", minted, allocator = allocator)
	return control_ok_response(s, id, "spawn", extras, allocator)
}

// control_despawn removes one EXISTING instance on the branch — the inverse of
// control_spawn — through the SAME tick-boundary batch (queue_despawn +
// apply_spawn_batch, exactly as a behavior's [Despawn] emit lands at the
// boundary, so no parallel removal path exists). It addresses a live row the way
// `set` does — args.thing + args.instance, the Id observe rendered — and answers
// that Id so the agent confirms which row left. The instance is pre-checked
// against the working table because apply_spawn_batch treats an absent Id as a
// silent no-op (population is fixed within a tick), so an unknown/already-absent
// Id must refuse here rather than commit an empty batch.
@(private = "file")
control_despawn :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	thing, has_thing := json_string_field(args, "thing")
	if !has_thing {
		return error_response(id, "despawn", "missing args.thing", allocator)
	}
	instance, has_instance := json_int_field(args, "instance")
	if !has_instance {
		return error_response(id, "despawn", "missing args.instance", allocator)
	}
	if program_thing(branch.program, thing) == nil {
		return error_response(id, "despawn", "unknown thing", allocator)
	}

	target := Id{raw = Thing_Id(instance)}
	state := new_tick_state(branch.head, allocator, allocator)
	table := find_tick_table(state.tables, thing)
	if table == nil {
		return error_response(id, "despawn", "unknown thing", allocator)
	}
	if _, found := find_row_by_id(table.rows[:], target); !found {
		return error_response(id, "despawn", "no instance with that id", allocator)
	}

	queue_despawn(&state, Ref{thing = thing, id = target})
	apply_spawn_batch(&state)
	branch.head = commit_tick_state(branch.head, &state, allocator)
	branch.ticks += 1
	extras := fmt.aprintf(",\"instance\":%d", instance, allocator = allocator)
	return control_ok_response(s, id, "despawn", extras, allocator)
}

// control_emit injects one signal on the branch and folds a full pipeline tick
// over it: the decoded signal record is pre-routed into the tick's mailbox (the
// ordinary forward-routing shape), so every consumer of the type reads it THIS
// tick exactly as it would read a producer's emission — then the tick commits at
// the boundary. The injected snapshot is empty input; the branch Rng threads
// through as ever.
@(private = "file")
control_emit :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	signal, has_signal := json_string_field(args, "signal")
	encoded, has_value := json_string_field(args, "value")
	if !has_signal || !has_value {
		return error_response(id, "emit", "missing args.signal or args.value", allocator)
	}
	decoded, decode_ok := decode_default_value(branch.program, signal, encoded, allocator, true)
	if !decode_ok {
		return error_response(id, "emit", value_decode_error(signal, signal, allocator), allocator)
	}
	record, is_record := decoded.(Record_Value)
	if !is_record || record.type_name != signal {
		return error_response(id, "emit", "signal value must be a record of the signal type", allocator)
	}

	// The ordinary transaction shape, with the mailbox pre-seeded: the injected
	// record enters through route_signals — the same accumulator a producer's
	// fold lands in — then the full pipeline folds over it and commits.
	prior := branch.head
	state := new_tick_state(prior, allocator, allocator)
	if branch.has_rng {
		state.rng = branch.rng
	}
	elements := make([]Value, 1, allocator)
	elements[0] = decoded_record_as_value(record)
	route_signals(&state, signal, List_Value{elements = elements})

	time := time_resource_at(branch.program.entrypoint.tick_hz, branch_logical_tick(s), allocator)
	interp := new_interp(branch.program, &prior, &state, empty(), time, allocator)
	run_pipeline_fold(&interp, &state, branch.program)
	apply_spawn_batch(&state)
	if branch.has_rng {
		branch.rng = state.rng
	}
	branch.head = commit_tick_state(branch.head, &state, allocator)
	branch.ticks += 1
	return control_ok_response(s, id, "emit", "", allocator)
}

// decoded_record_as_value lifts a decoded signal record column into the
// interpreter Value a mailbox carries — the same lift a consumer's signal-list
// element takes.
@(private = "file")
decoded_record_as_value :: proc(record: Record_Value) -> Value {
	return field_value_to_value(record)
}

// control_reload swaps the BRANCH onto a recompiled artifact through the §09 §3
// gated atomic hot_reload_swap: the branch head migrates through the schema-diff
// kernel and the branch program re-resolves behaviors against the new tables. A
// refusal (load or migration) is answered as an error and the branch keeps its
// last-good program and head untouched — never a partial swap. The canonical
// chain and the session program are NEVER touched: a reload is a perturbation,
// so it lives on the fork (§28 §2; hot-reload never ships in a warranted
// session, §09 §3).
@(private = "file")
control_reload :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	artifact, has_artifact := json_string_field(args, "artifact")
	if !has_artifact {
		return error_response(id, "reload", "missing args.artifact", allocator)
	}
	new_program, migrated, result := hot_reload_swap(branch.program, branch.head, artifact, allocator)
	if !result.ok {
		b := strings.builder_make(allocator)
		if result.load_err != .None {
			fmt.sbprintf(&b, "reload refused: artifact load error %v", result.load_err)
		} else {
			fmt.sbprintf(&b, "reload refused: migration refusal %v", result.refusal.kind)
		}
		return error_response(id, "reload", strings.to_string(b), allocator)
	}
	branch.program_storage = new_program
	branch.program = &branch.program_storage
	branch.head = migrated
	branch.ticks += 1
	return control_ok_response(s, id, "reload", ",\"swapped\":true", allocator)
}

