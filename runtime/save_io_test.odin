// engine.save IO boundary acceptance (spec §24, team Lore #9): the command-out /
// outcome-signal-back surface yard's persist+settings glue drives, proven on
// HAND-BUILT fixtures (the yard artifact is the sibling-compiler epic's leaf, team
// Lore #8 — runtime proves the IO arm on a node-forest before the artifact lands).
// These tests assert, end to end against the IN-MEMORY store (hermetic, cwd-free):
//
//   - SAVE ROUND-TRIPS THE COMMITTED VERSION: serialize_snapshot → deserialize_snapshot
//     reproduces a bit-identical World_Version, and the restored version digests
//     identically to the saved one (the snapshot codec is exact over §10 fixed-point);
//   - NEXT-TICK OUTCOME DEFERRAL (§24 §1): a Save/Restore/ApplySettings command emitted
//     at tick N returns its outcome signal (Saved/Restored/SettingsApplied) one tick
//     boundary LATER, at tick N+1 — the menu's on_persist_result/on_settings_applied
//     fold it then, exactly the spawn-batch deferral shape;
//   - RESTORE SWAPS THE WORLD AT THE TICK BOUNDARY: a Restore at tick N makes the
//     restored version the world tick N+1 folds from (the swap presents to the digest
//     as the next committed version);
//   - FORCED IO-ERROR → Result::Err: a Save against an unwritable disk store yields
//     Result::Err the menu fold records (the §24 forced-match error arm, never dropped);
//   - DETERMINISM BOUNDARY (Lore #9): the replay log carries NO Save/ApplySettings
//     entry (Replay_Log is identity + []Input by construction), and a re-fold of a
//     recorded session WITH a mid-session Restore produces the SAME per-tick frame
//     digests as the live capture — §24 persistence is NOT the replay record, yet a
//     restore-bearing run stays bit-identical because the F5/F9 presses ride the
//     RECORDED INPUT stream (the same Save re-serializes the same committed version,
//     the same Restore swaps it back).
//
// No float (spec §10): every assertion is the bit-exact kernel value / digest.
package funpack_runtime

import "core:fmt"
import "core:testing"

// p_aprintf is the test-local string formatter the node builders use to encode
// literal tokens (Int/String/record-field-count) — a thin wrapper over fmt.aprintf
// pinned to the supplied arena, so a built node's token strings outlive the builder
// call (a stack literal cannot escape in Odin).
@(private = "file")
p_aprintf :: proc(a: Runtime_Allocator, format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args, allocator = a)
}

// SAVE_BTN / RESTORE_BTN / APPLY_BTN are the Cmd::* Button ActionIds the registry
// mints from the hand-built program's Cmd enum, in variant order (Save=0, Restore=1,
// Apply=2). The scripted sessions press these to drive the save/restore/apply glue.
@(private = "file")
SAVE_BTN :: ActionId(0)
@(private = "file")
RESTORE_BTN :: ActionId(1)
@(private = "file")
APPLY_BTN :: ActionId(2)

// STEER is the Drive::Step Axis ActionId — minted after the Cmd buttons in the enum
// walk (Cmd is declared first, three buttons, so the lone Drive axis is id 3). The
// player behavior reads it to advance the world each tick so the per-tick digests
// are distinct (a static world would make every tick's digest identical and a swap
// undetectable in the digest stream).
@(private = "file")
STEER :: ActionId(3)

@(private = "file")
PERSIST_SLOT :: "quicksave"

// --- (1) Save round-trips the committed version ---------------------------

// A Save serializes the committed World_Version and a deserialize reproduces it
// bit-for-bit: same tick, same tables (thing/singleton/next_id), same rows down to
// the fixed-point bits. The codec carries next_id + singleton (which the frame
// digest omits), so the restored version is fully spawnable AND digests identically
// to the saved version — the property a Restore swap relies on.
@(test)
test_save_snapshot_round_trips_committed_version :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	committed := persist_startup(&program)

	bytes := serialize_snapshot(committed)
	restored, ok := deserialize_snapshot(bytes)
	if !testing.expect(t, ok) {
		return
	}

	// The deserialized version equals the saved one column-for-column (same Ids, same
	// fixed-point bits) — world_versions_equal is the byte-exact world comparison the
	// singleton-determinism test uses.
	testing.expect(t, world_versions_equal(committed, restored))

	// And it digests identically: a restored world the frame digest reads produces the
	// SAME per-tick digest the saved world would, so a Restore swap is digest-transparent.
	saved_digest := frame_digest(committed, nil)
	restored_digest := frame_digest(restored, nil)
	testing.expect_value(t, restored_digest.digest, saved_digest.digest)
}

// A re-serialize of a deserialized snapshot is byte-identical to the original bytes:
// the codec is a fixed point (serialize ∘ deserialize ∘ serialize == serialize), so
// the content hash is stable and a slot written on one machine restores identically
// on another — the cross-machine reproducibility the content-hash pin guarantees.
@(test)
test_snapshot_codec_is_a_fixed_point :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	committed := persist_startup(&program)

	first := serialize_snapshot(committed)
	restored, ok := deserialize_snapshot(first)
	if !testing.expect(t, ok) {
		return
	}
	second := serialize_snapshot(restored)

	testing.expect_value(t, len(second), len(first))
	for b, i in first {
		if i < len(second) {
			testing.expect_value(t, second[i], b)
		}
	}
}

// --- (2) Save round-trips through the store + next-tick Saved outcome ------

// A Save command emitted at tick N writes the committed snapshot to the slot AND
// queues a Saved{slot, Ok} outcome that arrives at tick N+1 — not the same tick. The
// carrier carries the pending outcome forward, and the menu's on_persist_result folds
// it the NEXT tick (status "saved"), proving the §24 §1 one-tick deferral end to end.
@(test)
test_save_emits_saved_outcome_next_tick :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store()
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	// Tick 0: press Save. The command runs at the boundary; NO Saved outcome is
	// delivered THIS tick (the carrier started empty), so the menu status stays None.
	save_input := with_pressed(empty(), .P1, SAVE_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, save_input, time, carrier)
	testing.expect_value(t, menu_status(&v0), "")

	// The slot now holds the committed snapshot — the Save serialized tick 0's world.
	snapshot, slot_ok := store_read_slot(&store, PERSIST_SLOT)
	testing.expect(t, slot_ok)
	testing.expect(t, len(snapshot.bytes) > 0)

	// Tick 1: no key. The Saved{Ok} outcome queued last tick is delivered into this
	// tick's mailbox, so on_persist_result folds it to status "saved" — the outcome
	// arrived ONE tick after the command (§24 §1).
	v1: World_Version
	v1, carrier = step_tick_persist(&program, v0, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v1), "Saved")
}

// --- (3) Restore swaps the world at the tick boundary, outcome one tick later

// A Restore at tick N swaps the world to the saved snapshot at the tick boundary —
// tick N+1 folds from the RESTORED world — and the Restored{Ok} outcome arrives at
// tick N+1 (one tick after the command). This is the sharp determinism case: the
// restored version IS the next committed version the frame digest reads.
@(test)
test_restore_swaps_world_and_signals_next_tick :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store()
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	// Tick 0: steer (advance the player) AND Save — captures the world at tick 0's
	// player position into the slot.
	t0_input := with_pressed(with_value(empty(), .P1, STEER, to_fixed(1)), .P1, SAVE_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, t0_input, time, carrier)
	saved_pos := player_pos(&v0)

	// Ticks 1..3: keep steering (the Saved outcome lands tick 1; the player keeps
	// advancing PAST the saved position).
	cur := v0
	for _ in 0 ..< 3 {
		steer := with_value(empty(), .P1, STEER, to_fixed(1))
		cur, carrier = step_tick_persist(&program, cur, steer, time, carrier)
	}
	advanced_pos := player_pos(&cur)
	// The player moved past where it was saved — the swap must bring it BACK.
	testing.expect(t, advanced_pos.x != saved_pos.x)

	// Tick 4: press Restore (no steer, so the only change this tick is the restore
	// queued for the boundary). Tick 4 itself folds from the advanced world.
	restore_input := with_pressed(empty(), .P1, RESTORE_BTN)
	v4: World_Version
	v4, carrier = step_tick_persist(&program, cur, restore_input, time, carrier)

	// Tick 5: the swap takes effect — tick 5 folds from the RESTORED world, so the
	// player is back at (near) the saved position, and the Restored{Ok} outcome
	// arrives (status "restored"). No steer, so the position reflects the swap only.
	v5: World_Version
	v5, carrier = step_tick_persist(&program, v4, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v5), "Restored")
	// The restored world's player is back at the saved position (the swap brought the
	// snapshot's row back) — the world was swapped at the tick boundary.
	testing.expect_value(t, player_pos(&v5).x, saved_pos.x)
}

// --- (4) ApplySettings persists and signals next tick ---------------------

// An ApplySettings at tick N persists the settings per-machine AND returns a
// SettingsApplied{Ok} at tick N+1 the menu folds (status "settings applied", dirty
// cleared). The settings land in the store (per-machine, NOT sim state), readable
// back independently of any version.
@(test)
test_apply_settings_persists_and_signals_next_tick :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store()
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	// Tick 0: press Apply. apply_settings emits [ApplySettings{settings}] (the menu's
	// settings, unconditionally in this fixture's apply behavior). The settings are
	// persisted at the boundary.
	apply_input := with_pressed(empty(), .P1, APPLY_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, apply_input, time, carrier)

	// The settings persisted to the store — per-machine, not a versioned snapshot.
	_, settings_ok := store_read_settings(&store)
	testing.expect(t, settings_ok)

	// Tick 1: the SettingsApplied{Ok} outcome arrives; on_settings_applied folds it to
	// status "settings applied".
	v1: World_Version
	v1, carrier = step_tick_persist(&program, v0, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v1), "SettingsApplied")
}

// --- (5) Forced IO-error → Result::Err the menu fold records --------------

// A Save against a disk store rooted at an UNWRITABLE path fails the write, so the
// command yields Saved{Err} the menu records as status "save failed" the next tick
// — the §24 forced-match error arm, never silently dropped. The store is on-disk
// (core:os) rooted under a path that cannot be created, so os.write_entire_file
// returns an error.
@(test)
test_forced_io_error_yields_err_outcome :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	// A disk store rooted at a path under a non-existent, non-creatable parent: the
	// slot write fails (the directory does not exist and is not created here), so the
	// Save outcome is Err. A NUL-containing root is rejected by every OS, the most
	// portable forced failure.
	store := new_on_disk_store("/proc/nonexistent-funpack-save-dir/\x00bad")
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	// Tick 0: press Save. The disk write fails → Saved{Err} queued.
	save_input := with_pressed(empty(), .P1, SAVE_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, save_input, time, carrier)

	// Tick 1: the Err outcome arrives; on_persist_result folds it to "save failed" —
	// the error arm the §24 forced match covers.
	v1: World_Version
	v1, carrier = step_tick_persist(&program, v0, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v1), "SaveFailed")
}

// A Restore of an EMPTY slot (no save was ever taken) yields Restored{Err} the menu
// records — the absent-slot read is the other forced error arm. No swap happens (a
// failed restore never swaps a partial world), so the world keeps advancing from its
// own state.
@(test)
test_restore_missing_slot_yields_err :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store() // empty — nothing was saved
	committed := persist_startup(&program)
	carrier := new_persist_carrier(&store)
	time := persist_time(60)

	restore_input := with_pressed(empty(), .P1, RESTORE_BTN)
	v0: World_Version
	v0, carrier = step_tick_persist(&program, committed, restore_input, time, carrier)
	v1: World_Version
	v1, carrier = step_tick_persist(&program, v0, empty(), time, carrier)
	testing.expect_value(t, menu_status(&v1), "RestoreFailed")
}

// A content-hash MISMATCH (a tampered slot) is refused: store the snapshot, corrupt
// its recorded hash, and a Restore yields ok=false — the pin catches the corruption
// before swapping a tampered world. This is the content-hash-pinned property the
// determinism boundary rests on (the restored snapshot is verified, not trusted).
@(test)
test_restore_rejects_content_hash_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	store := new_in_memory_store()
	committed := persist_startup(&program)

	// Save a real snapshot, then poison its recorded hash so the bytes no longer match.
	testing.expect(t, apply_save(&store, committed, PERSIST_SLOT))
	snapshot, read_ok := store_read_slot(&store, PERSIST_SLOT)
	testing.expect(t, read_ok)
	snapshot.content_hash = snapshot.content_hash ~ 0xDEAD_BEEF
	store_write_slot(&store, PERSIST_SLOT, snapshot)

	// The restore refuses the corrupt slot — the pin failed, so no version is returned.
	_, restore_ok := apply_restore(&store, PERSIST_SLOT)
	testing.expect(t, !restore_ok)
}

// --- (6) Determinism boundary: no replay entry + re-fold across a Restore --

// The replay log carries NO Save/ApplySettings entry: a Replay_Log is its identity
// header plus an ordered []Input — there is NO field for a persist command, so §24
// persistence is structurally absent from the determinism record (team Lore #9, AC4).
// The F5/F9 presses that TRIGGER persistence ride the INPUT stream (a button action),
// so a recording captures the input that caused a save, never the save effect itself.
@(test)
test_replay_log_carries_no_persist_entry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// Record a session through the production recorder: every recorded tick is an Input
	// snapshot. The recorded log's only payload is snapshots — there is no Save entry.
	program := persist_program()
	identity := identity_from_program(program, "persist-fixture-bytes")
	writer := open_replay_writer(identity)
	defer delete_replay_writer(&writer)
	// A tick whose input PRESSES the Save button — the F5 press rides the input stream.
	record_tick(&writer, with_pressed(empty(), .P1, SAVE_BTN))
	record_tick(&writer, empty())
	log_bytes := finish_replay(&writer)

	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	// The parsed log is identity + snapshots — the type has no persist field. The Save
	// press is recoverable as INPUT (pressed Save on tick 0), but no Save effect rode
	// the log: persistence is not the determinism record.
	testing.expect_value(t, len(log.snapshots), 2)
	testing.expect(t, pressed(log.snapshots[0], .P1, SAVE_BTN))
}

// A recorded session WITH a mid-session Restore re-folds bit-identically: driving the
// SAME scripted input session (steer, save, steer, restore) through step_tick_persist
// twice — a "live" capture and a "re-fold" — produces identical per-tick frame
// digests. The persist IO is a deterministic FUNCTION of the committed versions
// (themselves deterministic functions of the input), so the same input re-serializes
// the same Save and swaps back the same Restore: the restored swap is digest-stable
// across re-folds (team Lore #9, AC4). This is the §24-on-the-determinism-target proof.
@(test)
test_refold_across_restore_is_bit_identical :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := persist_program()
	inputs := persist_restore_session()

	live := persist_capture(&program, inputs)
	refold := persist_capture(&program, inputs)

	if !testing.expect_value(t, len(refold), len(live)) {
		return
	}
	for frame, i in live {
		testing.expect_value(t, refold[i].tick, frame.tick)
		testing.expect_value(t, refold[i].digest, frame.digest)
	}

	// Guard the bit-identity above against a no-op restore: the restore MUST be
	// observable in the digest stream, else two identical no-op runs would pass
	// vacuously. A control session that STEERS every tick (never restores) diverges
	// from the restore session at the swap tick — the restore brought the player back,
	// so the post-swap digest differs from the steered-through one. A non-divergence
	// would mean the restore did nothing.
	steered := persist_capture(&program, persist_steer_only_session())
	if !testing.expect_value(t, len(steered), len(live)) {
		return
	}
	// Tick 5 is the first tick that folds from the RESTORED world (the Restore pressed
	// at tick 4 swaps at the boundary). The restore session's tick-5 digest must differ
	// from the steer-only session's tick-5 digest — the swap is observable.
	testing.expect(t, live[5].digest != steered[5].digest)
}

// persist_steer_only_session is the control session for the re-fold guard: it steers
// every tick and NEVER saves or restores, so its world advances monotonically. Its
// late-tick digests differ from the restore session's, proving the restore swap is
// observable in the digest (not a silent no-op the bit-identity check would miss).
@(private = "file")
persist_steer_only_session :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, 8, allocator)
	for i in 0 ..< 8 {
		inputs[i] = with_value(empty(), .P1, STEER, to_fixed(1))
	}
	return inputs
}

// persist_restore_session is the scripted input session the re-fold determinism test
// drives: steer for a few ticks, press Save, steer more (so the world moves past the
// save), then press Restore — a mid-session save AND restore over an evolving world.
// The SAME slice drives both captures, so the re-fold re-feeds identical input.
@(private = "file")
persist_restore_session :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, 8, allocator)
	inputs[0] = with_value(empty(), .P1, STEER, to_fixed(1))
	inputs[1] = with_pressed(with_value(empty(), .P1, STEER, to_fixed(1)), .P1, SAVE_BTN) // save tick
	inputs[2] = with_value(empty(), .P1, STEER, to_fixed(1))
	inputs[3] = with_value(empty(), .P1, STEER, to_fixed(1))
	inputs[4] = with_pressed(empty(), .P1, RESTORE_BTN) // restore tick — swaps next tick
	inputs[5] = empty()
	inputs[6] = empty()
	inputs[7] = empty()
	return inputs
}

// persist_capture drives a persist session through step_tick_persist from a FRESH
// store and startup, capturing each committed tick's frame digest over the world
// state. It is the ground-truth capture the re-fold must reproduce: two runs of this
// over the same inputs must agree, since the persist IO is deterministic over the
// committed versions (themselves deterministic over the input). The store is fresh
// per call so the two captures never share ambient disk state — the slot content is a
// pure function of THIS run's fold.
@(private = "file")
persist_capture :: proc(program: ^Program, inputs: []Input, allocator := context.allocator) -> []Frame_Digest {
	store := new_in_memory_store(allocator)
	committed := persist_startup(program, allocator)
	carrier := new_persist_carrier(&store)
	time := persist_time(60, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	cur := committed
	for input in inputs {
		cur, carrier = step_tick_persist(program, cur, input, time, carrier, allocator)
		append(&per_tick, capture_frame(cur, nil, allocator))
	}
	return per_tick[:]
}

// ==========================================================================
// The hand-built persist program: a Menu singleton + a Player singleton, the
// save/restore/apply behaviors, and the outcome folds.
// ==========================================================================

// persist_program builds the IO-boundary test substrate: a Cmd (Button) enum minting
// Save/Restore/Apply actions, a Drive (Axis) enum minting the Step axis, the Menu and
// Player singletons, and six behaviors — the player advance (control), save_key /
// restore_key / apply_settings (the command emits, control), and on_persist_result /
// on_settings_applied (the outcome folds, scoring). The pipeline orders the folds
// AFTER the emits so a same-tick outcome would be seen, but outcomes are deferred a
// tick so the fold reads the PRIOR tick's outcomes. All in the temp arena (Lore #8).
@(private = "file")
persist_program :: proc(allocator := context.allocator) -> Program {
	a := allocator

	enums := make([]Enum_Decl, 2, a)
	enums[0] = Enum_Decl{name = "Cmd", kind = .Button, variants = persist_cmd_variants(a)}
	enums[1] = Enum_Decl{name = "Drive", kind = .Axis, variants = persist_axis_variants(a)}

	// Player { pos: Vec2 = {0,0} } — the advancing thing whose evolving pos makes each
	// tick's digest distinct.
	player_fields := make([]Field_Decl, 1, a)
	player_fields[0] = Field_Decl {
		name            = "pos",
		type            = "Vec2",
		has_default     = true,
		default_encoded = pos_default(a),
	}

	// Menu { status: Option = Option::None } — the singleton the persist folds write
	// their status onto. dirty is unused by this fixture's unconditional apply, so the
	// menu carries only status.
	menu_fields := make([]Field_Decl, 1, a)
	menu_fields[0] = Field_Decl {
		name            = "status",
		type            = "Option",
		has_default     = true,
		default_encoded = "Option::None",
	}

	things := make([]Thing_Decl, 2, a)
	things[0] = Thing_Decl{name = "Player", singleton = true, fields = player_fields}
	things[1] = Thing_Decl{name = "Menu", singleton = true, fields = menu_fields}

	behaviors := make([]Behavior_Decl, 6, a)
	behaviors[0] = persist_player_step_behavior(a)
	behaviors[1] = persist_save_key_behavior(a)
	behaviors[2] = persist_restore_key_behavior(a)
	behaviors[3] = persist_apply_settings_behavior(a)
	behaviors[4] = persist_on_persist_result_behavior(a)
	behaviors[5] = persist_on_settings_applied_behavior(a)

	pipeline := make([]Pipeline_Step, 6, a)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "control", behavior = "player_step"}
	pipeline[1] = Pipeline_Step{ordinal = 1, stage = "control", behavior = "save_key"}
	pipeline[2] = Pipeline_Step{ordinal = 2, stage = "control", behavior = "restore_key"}
	pipeline[3] = Pipeline_Step{ordinal = 3, stage = "control", behavior = "apply_settings"}
	pipeline[4] = Pipeline_Step{ordinal = 4, stage = "scoring", behavior = "on_persist_result"}
	pipeline[5] = Pipeline_Step{ordinal = 5, stage = "scoring", behavior = "on_settings_applied"}

	program := Program{}
	program.enums = enums
	program.things = things
	program.behaviors = behaviors
	program.pipeline = pipeline
	program.entrypoint = Entrypoint{tick_hz = 60, logical_w = 160, logical_h = 120}
	return program
}

// persist_startup runs the engine singleton-spawn pass — the Player and Menu rows
// land before tick 0, so the persist behaviors read a populated world the first tick.
@(private = "file")
persist_startup :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	return run_startup(program, initial_version(world, allocator), allocator)
}

// persist_time is the Time resource the persist ticks step at — one dt at the fixed
// tick rate (kernel-derived, no float).
@(private = "file")
persist_time :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	return Record_Value{type_name = "Time", fields = fields}
}

// pos_default encodes the Player's `pos: Vec2 = {0,0}` default as the kernel's raw
// Q32.32 bits (the Vec2(x=…,y=…) decode form the singleton pass reads), bit-exact.
@(private = "file")
pos_default :: proc(a := context.allocator) -> string {
	return p_aprintf(a, "Vec2(x=%d,y=%d)", i64(to_fixed(0)), i64(to_fixed(0)))
}

// persist_cmd_variants is the Cmd:Button enum's three menu actions (Save/Restore/
// Apply) — the buttons the persist behaviors gate on, minting ActionId 0/1/2.
@(private = "file")
persist_cmd_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 3, a)
	v[0] = Enum_Variant{name = "Save", payload = "unit"}
	v[1] = Enum_Variant{name = "Restore", payload = "unit"}
	v[2] = Enum_Variant{name = "Apply", payload = "unit"}
	return v
}

// persist_axis_variants is the Drive:Axis enum's one action (Step) — the player's
// drive axis, minting ActionId 3 (after the three Cmd buttons).
@(private = "file")
persist_axis_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 1, a)
	v[0] = Enum_Variant{name = "Step", payload = "unit"}
	return v
}

// --- behavior bodies (node forests) ---------------------------------------

// persist_player_step_behavior builds player_step on Player: `return self with {
// pos: self.pos + input.axis(P1, Drive::Step) }` — advances the player's position by
// the steer axis each tick. A +1 steer moves pos by {1,1} per tick, so the world (and
// hence the per-tick digest) evolves distinctly tick to tick.
@(private = "file")
persist_player_step_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 1, a)
	axis := p_method_call(p_name("input", a), "axis", a, p_variant_unit("PlayerId", "P1", a), p_variant_unit("Drive", "Step", a))
	advanced := p_binary("add", p_field(p_name("self", a), "pos", a), axis, a)
	body[0] = p_return(p_with(p_name("self", a), a, p_recfield("pos", advanced)), a)
	return p_behavior("player_step", "Player", "control", p_two_params("self", "Player", "input", "Input", a), p_emit_self("Player", a), body, a)
}

// persist_save_key_behavior builds save_key on Menu: `if input.pressed(P1, Cmd::Save)
// { return [Save{slot: SLOT}] }; return []` — the key-gated Save command emit, emit
// type [Save] (the §24 persist command list).
@(private = "file")
persist_save_key_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	return persist_command_key_behavior("save_key", "Save", "Save", a)
}

// persist_restore_key_behavior builds restore_key on Menu — the key-gated Restore
// command emit, emit type [Restore].
@(private = "file")
persist_restore_key_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	return persist_command_key_behavior("restore_key", "Restore", "Restore", a)
}

// persist_command_key_behavior is the shared body of save_key/restore_key: gate a
// `[Command{slot: SLOT}]` emit on `input.pressed(P1, Cmd::Button)`, else []. The emit
// type is `[Command]` so fold_behavior_result routes it to the persist batch.
@(private = "file")
persist_command_key_behavior :: proc(name, button, command: string, a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	pressed := p_method_call(p_name("input", a), "pressed", a, p_variant_unit("PlayerId", "P1", a), p_variant_unit("Cmd", button, a))
	cmd := p_record_fields(command, a, p_recfield("slot", p_string(PERSIST_SLOT, a)))
	body[0] = p_if_return(pressed, p_list(a, cmd), a)
	body[1] = p_return(p_list(a), a)
	emit := make([]string, 1, a)
	emit[0] = p_aprintf(a, "[%s]", command)
	return Behavior_Decl{name = name, on_thing = "Menu", stage = "control", params = p_two_params("self", "Menu", "input", "Input", a), emits = emit, body = body}
}

// persist_apply_settings_behavior builds apply_settings on Menu: `if input.pressed(
// P1, Cmd::Apply) { return [ApplySettings{settings: self.settings}] }; return []` —
// the Apply-gated ApplySettings emit. This fixture's menu carries a bare settings
// record built inline (the per-machine payload), since the fixture asserts the
// persist+signal round-trip, not the dirty-gate (which the glue test covers).
@(private = "file")
persist_apply_settings_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	pressed := p_method_call(p_name("input", a), "pressed", a, p_variant_unit("PlayerId", "P1", a), p_variant_unit("Cmd", "Apply", a))
	// ApplySettings{settings: Settings{volume: 1}} — a bare per-machine settings record.
	settings := p_record_fields("Settings", a, p_recfield("volume", p_int(1, a)))
	cmd := p_record_fields("ApplySettings", a, p_recfield("settings", settings))
	body[0] = p_if_return(pressed, p_list(a, cmd), a)
	body[1] = p_return(p_list(a), a)
	emit := make([]string, 1, a)
	emit[0] = "[ApplySettings]"
	return Behavior_Decl{name = "apply_settings", on_thing = "Menu", stage = "control", params = p_two_params("self", "Menu", "input", "Input", a), emits = emit, body = body}
}

// persist_on_persist_result_behavior builds on_persist_result on Menu: a fold over
// [Saved] then [Restored], each lambda matching `r.result { Ok => "saved"/"restored",
// Err => "save failed"/"restore failed" }` — the outcome-recording fold (§24 forced
// match). It mirrors the glue test's on_persist_result so the engine-delivered
// outcome folds identically to the hand-built signal.
@(private = "file")
persist_on_persist_result_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 2, a)
	body[0] = p_let("after_save", p_call(a, "fold", p_name("saved", a), p_name("self", a), persist_result_lambda("Saved", "SaveFailed", a)), a)
	body[1] = p_return(p_call(a, "fold", p_name("restored", a), p_name("after_save", a), persist_result_lambda("Restored", "RestoreFailed", a)), a)
	params := make([]Param_Decl, 3, a)
	params[0] = Param_Decl{name = "self", type = "Menu"}
	params[1] = Param_Decl{name = "saved", type = "[Saved]"}
	params[2] = Param_Decl{name = "restored", type = "[Restored]"}
	return Behavior_Decl{name = "on_persist_result", on_thing = "Menu", stage = "scoring", params = params, emits = p_emit_self("Menu", a), body = body}
}

// persist_on_settings_applied_behavior builds on_settings_applied on Menu: `return
// fold(applied, self, fn(m, r) { match r.result { Ok => "settings applied", Err =>
// "settings save failed" } })` — the apply-outcome fold.
@(private = "file")
persist_on_settings_applied_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	body := make([]Node, 1, a)
	body[0] = p_return(p_call(a, "fold", p_name("applied", a), p_name("self", a), persist_result_lambda("SettingsApplied", "SettingsSaveFailed", a)), a)
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "self", type = "Menu"}
	params[1] = Param_Decl{name = "applied", type = "[SettingsApplied]"}
	return Behavior_Decl{name = "on_settings_applied", on_thing = "Menu", stage = "scoring", params = params, emits = p_emit_self("Menu", a), body = body}
}

// persist_result_lambda builds an `fn(m, r) { match r.result { Ok(_) => m with {
// status: Status::OK_CASE }, Err(_) => m with { status: Status::ERR_CASE } } }`
// combiner — the per-signal Result match the persist/apply folds thread (sets only
// status, so the prior menu carries forward). The status is a UNIT enum variant
// (Status::Saved, Status::SaveFailed, …) — the column shape that round-trips a
// blackboard commit (a unit variant lowers to its "Status::Case" token, which is a
// storable string column the digest reads). (The glue test folds `Option::Some(text)`
// and asserts the IN-MEMORY fold result; this fixture COMMITS the menu through a tick,
// so it uses a unit-variant status — a payload-carrying variant or a bare String drops
// on commit, only a unit-variant token survives the round-trip the digest covers.)
@(private = "file")
persist_result_lambda :: proc(ok_case, err_case: string, a := context.allocator) -> Node {
	ok_arm := p_variant_binds_arm("Result", "Ok", "_", a)
	ok_body := p_with(p_name("m", a), a, p_recfield("status", p_variant_unit("Status", ok_case, a)))
	err_arm := p_variant_binds_arm("Result", "Err", "_", a)
	err_body := p_with(p_name("m", a), a, p_recfield("status", p_variant_unit("Status", err_case, a)))
	match := p_match(p_field(p_name("r", a), "result", a), a, ok_arm, ok_body, err_arm, err_body)
	return p_lambda(a, match, "m", "r")
}

// ==========================================================================
// Read helpers + assertions.
// ==========================================================================

// menu_status reads the Menu singleton's status as its Status::Case name, or "" when
// status is the default Option::None — the outcome the persist folds set. The status
// is a unit enum variant column ("Status::Saved" etc.), so its committed token lifts
// back to a Variant_Value whose case_name is the outcome the test asserts.
@(private = "file")
menu_status :: proc(version: ^World_Version) -> string {
	menu, ok := singleton_row(version, "Menu")
	if !ok {
		return ""
	}
	status, present := menu.fields["status"]
	if !present {
		return ""
	}
	lifted := field_value_to_value(status)
	variant, is_variant := lifted.(Variant_Value)
	if !is_variant || variant.enum_type != "Status" {
		return ""
	}
	return variant.case_name
}

// player_pos reads the Player singleton's pos Vec2 — the advancing position the
// digest covers and the restore swaps back.
@(private = "file")
player_pos :: proc(version: ^World_Version) -> Vec2 {
	player, ok := singleton_row(version, "Player")
	if !ok {
		return VEC2_ZERO
	}
	pos, present := player.fields["pos"]
	if !present {
		return VEC2_ZERO
	}
	if v, is_vec2 := pos.(Vec2); is_vec2 {
		return v
	}
	return VEC2_ZERO
}

// ==========================================================================
// Node-forest constructors (file-private; sibling test files keep their own).
// These mirror the §2.7 subtree builders the glue/hunt fixtures define; every
// node constructor there is @(private="file"), so this file carries its own copies
// under a `p_`/`persist_` prefix — the file-private scope means they never collide.
// ==========================================================================

@(private = "file")
p_name :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
p_field :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

@(private = "file")
p_binary :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

@(private = "file")
p_call :: proc(a: Runtime_Allocator, callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = p_name(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
p_method_call :: proc(recv: Node, method: string, a: Runtime_Allocator, args: ..Node) -> Node {
	field := p_field(recv, method, a)
	children := make([]Node, len(args) + 1, a)
	children[0] = field
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
p_match :: proc(scrutinee: Node, a: Runtime_Allocator, arms_bodies: ..Node) -> Node {
	children := make([]Node, len(arms_bodies) + 1, a)
	children[0] = scrutinee
	for n, i in arms_bodies {
		children[i + 1] = n
	}
	return Node{kind = .Match, children = children}
}

@(private = "file")
P_Recfield :: struct {
	name:  string,
	value: Node,
}

@(private = "file")
p_recfield :: proc(name: string, value: Node) -> P_Recfield {
	return P_Recfield{name = name, value = value}
}

@(private = "file")
p_recfield_node :: proc(spec: P_Recfield, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = spec.name
	children := make([]Node, 1, a)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

@(private = "file")
p_with :: proc(base: Node, a: Runtime_Allocator, specs: ..P_Recfield) -> Node {
	children := make([]Node, len(specs) + 1, a)
	children[0] = base
	for spec, i in specs {
		children[i + 1] = p_recfield_node(spec, a)
	}
	return Node{kind = .With, children = children}
}

@(private = "file")
p_variant_unit :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "false"
	return Node{kind = .Variant, fields = fields}
}

@(private = "file")
p_variant_payload :: proc(enum_type, case_name: string, payload: Node, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "true"
	children := make([]Node, 1, a)
	children[0] = payload
	return Node{kind = .Variant, fields = fields, children = children}
}

@(private = "file")
p_variant_binds_arm :: proc(enum_type, case_name, binder: string, a := context.allocator) -> Node {
	fields := make([]string, 5, a)
	fields[0] = "variant_binds"
	fields[1] = enum_type
	fields[2] = case_name
	fields[3] = "1"
	fields[4] = binder
	return Node{kind = .Arm, fields = fields}
}

@(private = "file")
p_let :: proc(name: string, value: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Let, fields = fields, children = children}
}

@(private = "file")
p_if_return :: proc(guard, value: Node, a := context.allocator) -> Node {
	children := make([]Node, 2, a)
	children[0] = guard
	children[1] = value
	return Node{kind = .If_Return, children = children}
}

@(private = "file")
p_return :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}

@(private = "file")
p_int :: proc(n: i64, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = p_aprintf(a, "%d", n)
	return Node{kind = .Int, fields = fields}
}

@(private = "file")
p_string :: proc(s: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = p_aprintf(a, "L%d:%s", i64(len(s)), s)
	return Node{kind = .String, fields = fields}
}

@(private = "file")
p_some_string :: proc(text: string, a := context.allocator) -> Node {
	return p_variant_payload("Option", "Some", p_string(text, a), a)
}

@(private = "file")
p_record_fields :: proc(type_name: string, a: Runtime_Allocator, specs: ..P_Recfield) -> Node {
	fields := make([]string, 2, a)
	fields[0] = type_name
	fields[1] = p_aprintf(a, "%d", i64(len(specs)))
	children := make([]Node, len(specs), a)
	for spec, i in specs {
		children[i] = p_recfield_node(spec, a)
	}
	return Node{kind = .Record, fields = fields, children = children}
}

@(private = "file")
p_list :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	copy(children, elements)
	return Node{kind = .List, children = children}
}

@(private = "file")
p_lambda :: proc(a: Runtime_Allocator, body: Node, params: ..string) -> Node {
	fields := make([]string, len(params) + 1, a)
	fields[0] = p_aprintf(a, "%d", i64(len(params)))
	for p, i in params {
		fields[i + 1] = p
	}
	children := make([]Node, 1, a)
	children[0] = body
	return Node{kind = .Lambda, fields = fields, children = children}
}

@(private = "file")
p_two_params :: proc(n0, t0, n1, t1: string, a := context.allocator) -> []Param_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = n0, type = t0}
	params[1] = Param_Decl{name = n1, type = t1}
	return params
}

// p_emit_self builds a one-emit blackboard-write list `[on_thing]` (the behavior
// returns its own thing record — a blackboard fold).
@(private = "file")
p_emit_self :: proc(on_thing: string, a := context.allocator) -> []string {
	emit := make([]string, 1, a)
	emit[0] = on_thing
	return emit
}

// p_behavior builds a Behavior_Decl with the supplied stage/params/emit/body.
@(private = "file")
p_behavior :: proc(name, on_thing, stage: string, params: []Param_Decl, emits: []string, body: []Node, a := context.allocator) -> Behavior_Decl {
	return Behavior_Decl{name = name, on_thing = on_thing, stage = stage, params = params, emits = emits, body = body}
}
