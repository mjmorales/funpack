// The engine.save IO boundary (spec §24): the command-out / outcome-signal-back
// surface yard's persist+settings glue drives. Three commands, each returning its
// outcome on the NEXT tick boundary (§24 §1), exactly the way the spawn batch
// defers a mint:
//
//   - Save{slot}        serializes the COMMITTED World_Version to a slot and returns
//                       Saved{slot, result: Result::Ok/Err}.
//   - Restore{slot}     reads a slot, content-hash-verifies it, and SWAPS the world
//                       at the next tick boundary, returning Restored{slot, result}.
//   - ApplySettings{s}  persists Settings per-machine and returns SettingsApplied{result}.
//
// DETERMINISM BOUNDARY (load-bearing, team Lore #9). §24 persistence is EXPLICITLY
// NOT the replay/determinism record. A Save is an output effect; ApplySettings is
// per-machine and never sim state; NEITHER rides the replay log (Replay_Log carries
// only identity + []Input by construction, so "no Save/ApplySettings entry" holds
// structurally — there is no field for one). Restore is the sharp case: it brings
// external bytes in and SWAPS the world at the tick boundary. The re-fold stays
// bit-identical because the F5/F9 presses ride the RECORDED INPUT stream — so on a
// re-fold the SAME Save re-serializes the SAME committed version into the slot, and
// the SAME Restore swaps that exact version back. The slot content is a
// deterministic FUNCTION OF THE RE-FOLD, not ambient disk state; the restored
// version becomes the next committed version the frame digest reads, so a recording
// with a mid-session Restore re-folds to the same per-tick digests as the live
// capture (save_io_test.odin proves this).
//
// SLOT/SETTINGS STORAGE. The store is a tagged union with two backends behind one
// surface: a HERMETIC in-memory map (the default for tests — cwd-free, leaves no
// disk residue, team Lore #8 hand-built-fixture discipline) and a core:os disk
// backend (the real path; Odin-first — os.read_entire_file / os.write_entire_file,
// the same primitive load_artifact_file already uses). A snapshot is
// content-hash-pinned: the slot stores the xxh64 of its canonical bytes alongside
// them, and a Restore that reads back a hash mismatch yields Result::Err the menu
// fold records (the FORCED-MATCH §24 error arm, never silently dropped).
//
// No float anywhere (spec §10): the snapshot codec writes raw little-endian
// fixed-point bits, the same encoding the frame digest pins, so a serialized Fixed
// round-trips bit-for-bit.
package funpack_runtime

import "core:encoding/endian"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strings"

// SAVE_SNAPSHOT_SCHEMA_VERSION stamps the snapshot codec's byte layout. A snapshot
// is only restorable by a build at the SAME version — a deserialize against a
// different version fails closed (Result::Err), the closed-enum / exact-match
// discipline §04 applies to the persisted form too. It is independent of
// FRAME_DIGEST_SCHEMA_VERSION: the snapshot carries next_id + singleton (which the
// digest omits), so the two encodings move for different reasons. Bump this only on
// a deliberate codec change; carrying the version stamp IS the save-schema-migration
// surface this story owns (a migration BEYOND the stamp is OUT, §24).
// v2 adds the Variant_Payload arm: a payload-carrying variant nested in a
// structural column (a body's Shape2::Box{size}/Circle{radius}) serializes its
// boxed payload instead of flattening to the bare token — v1 dropped the payload,
// so a Restore swapped in degenerate collision/render shapes. A v1 slot fails
// closed on restore per the stamp discipline.
// v3 extends both arms to the TOP-LEVEL row blackboard (a payload-carrying
// variant column like yard's `status: Option[String]` and a String column are
// committable Field_Values, no longer flattened/dropped at commit) and gives a
// String the String tag — under v2 a nested String hit the tag-less no-op,
// which would have CORRUPTED the stream once payloads carried text.
// v4 serializes the Field_Tag.Vec3 COLUMN arm (krognid's `pos: Vec3`) — the
// three-Fixed-lane twin of the Vec2 arm, APPENDED at tag ordinal 10 so every
// existing tag keeps its byte. The codec serializes the shared Field_Tag enum, so
// emitting a new arm IS a codec change: a v3 build (no Vec3 arm) and a v4 build
// both stamp their own version, and the exact-match gate fires its diagnosable
// refusal across them instead of silently accepting an incompatible stream. The
// krognid golden harness uses the replay+digest path, not snapshots; this arm keeps
// the save codec TOTAL over the extended Field_Value union (the §24 quicksave path
// would otherwise drop a committed `pos`).
// v5 carries the writing build's name-keyed SCHEMAS in the snapshot — every §3
// data decl and every thing blackboard schema, each field as (name, type
// spelling) — so a Restore under a CHANGED schema can diff the snapshot's
// schemas against the loaded artifact's and fold the §09 §4 migration plan over
// the rows (schema_migrate.odin) instead of refusing or, worse, swapping rows
// the new world mis-reads. The codec-version gate itself stays exact-match (a
// v4 slot fails closed under a v5 build, per the stamp discipline); the carried
// schema is what makes the SCHEMA migration §24 mandates possible at all.
// v6 carries the §18 §4 / §24 §1 dynamic-TILE-layer DELTA: after the tables, the
// snapshot writes the live committed layers' delta from the SAVING build's bake
// (sparse, name-keyed — the same Tile_Carry_Delta hot-reload uses, tile_carry.odin),
// so a Restore re-applies a dug passage onto the restoring bake instead of
// silently re-seeding terrain from the new bake (a defect, not a semantics — ADR
// 2026-06-11-dynamic-tiles-carry-across-hot-reload). The delta is written name-
// keyed (a layer/cell/tile-name fact, never a palette index) so a later build's
// reshuffled palette maps it; new-bake-wins on any unmappable cell, applied at
// restore through the shared kernel. An empty delta (no SetTile ran) writes a
// single `u64(0)` count and round-trips byte-inert — the common save is unchanged
// in shape. A v5 slot fails closed under a v6 build (the exact-match stamp), so an
// older delta-less snapshot is never mis-read as carrying terrain.
SAVE_SNAPSHOT_SCHEMA_VERSION :: u64(6)

// SAVE_SNAPSHOT_MAGIC leads every snapshot so a stray byte stream (a truncated
// file, an unrelated blob) is rejected before the version check rather than parsed
// as garbage. "FPSNAP01" — funpack snapshot, format 01.
SAVE_SNAPSHOT_MAGIC :: u64(0x_31_30_50_41_4e_53_50_46) // "FPSNAP01" little-endian

// --- The persisted snapshot (content-hash-pinned bytes) -------------------

// Save_Snapshot is one persisted World_Version: its canonical bytes and the xxh64
// content hash over them. The hash is what a Restore verifies — a slot whose bytes
// no longer hash to its recorded hash is corrupt and Restore refuses it (§24 error
// arm). Stored together so a slot is self-verifying without an external manifest.
Save_Snapshot :: struct {
	bytes:        []u8, // the canonical little-endian snapshot byte stream
	content_hash: u64, // xxh64 over bytes — the pin a Restore checks
}

// --- The slot / settings store (hermetic in-memory + core:os disk) --------

// Save_Store is the §24 persistence backend behind one surface. The In_Memory arm
// is a hermetic map from slot key → snapshot plus a single persisted Settings
// record — the default for tests, so a save/restore round-trip touches no disk and
// needs no cwd (team Lore #8). The On_Disk arm roots slots and the settings file
// under a directory and reads/writes through core:os (Odin-first), the real
// runtime path. Both arms implement the same four operations (write_slot /
// read_slot / write_settings / read_settings) so the command processor is backend-
// agnostic.
Save_Store :: struct {
	backend: Save_Backend,
}

// Save_Backend is the closed set of storage backends. A new backend (a cloud arm,
// say — OUT for this story, §24 operator/platform owns sync) would be a new union
// arm and a deliberate addition, never an ambient mode switch.
Save_Backend :: union {
	In_Memory_Store,
	On_Disk_Store,
}

// In_Memory_Store is the hermetic test backend: slots keyed by name and a single
// optional persisted Settings record. It owns its maps in the supplied allocator;
// a round-trip mutates only this struct, never the filesystem.
In_Memory_Store :: struct {
	slots:    map[string]Save_Snapshot,
	settings: Maybe(Record_Value),
}

// On_Disk_Store is the real backend: a root directory under which a slot lands at
// `<root>/<slot>.snap` and the per-machine settings at `<root>/settings.snap`. The
// IO is core:os (Odin-first) — the same os.read_entire_file/os.write_entire_file
// family load_artifact_file uses.
On_Disk_Store :: struct {
	root: string,
}

// new_in_memory_store builds an empty hermetic store — the default a test drives.
new_in_memory_store :: proc(allocator := context.allocator) -> Save_Store {
	return Save_Store {
		backend = In_Memory_Store {
			slots = make(map[string]Save_Snapshot, allocator),
			settings = nil,
		},
	}
}

// new_on_disk_store roots a disk-backed store at `root` — the real runtime path. It
// does NOT create the directory; the caller (the live driver) ensures the save
// directory exists, since directory creation is a one-time setup concern, not a
// per-command effect.
new_on_disk_store :: proc(root: string) -> Save_Store {
	return Save_Store{backend = On_Disk_Store{root = root}}
}

// store_write_slot persists a snapshot under a slot key, returning false on an IO
// failure (a disk write error) so the command processor yields Result::Err. The
// in-memory arm always succeeds; the disk arm fails closed on os.write_entire_file
// returning an error.
store_write_slot :: proc(
	store: ^Save_Store,
	slot: string,
	snapshot: Save_Snapshot,
	allocator := context.allocator,
) -> bool {
	switch &backend in store.backend {
	case In_Memory_Store:
		backend.slots[strings.clone(slot, allocator)] = snapshot
		return true
	case On_Disk_Store:
		path := slot_path(backend.root, slot, allocator)
		// core:os write goes through write_entire_file_from_string (the Odin-first
		// primitive write_replay_file uses); the snapshot bytes are raw, so they cast
		// to a string view without copying. A non-nil Error is the IO-failure arm.
		return os.write_entire_file_from_string(path, string(snapshot.bytes)) == nil
	}
	return false
}

// store_read_slot reads a snapshot back from a slot, returning ok=false when the
// slot is absent or unreadable. The bytes are NOT hash-verified here — that is the
// caller's check (apply_restore), so a corrupt-on-read slot is one explicit refusal
// arm rather than two.
store_read_slot :: proc(
	store: ^Save_Store,
	slot: string,
	allocator := context.allocator,
) -> (
	snapshot: Save_Snapshot,
	ok: bool,
) {
	switch backend in store.backend {
	case In_Memory_Store:
		snapshot, ok = backend.slots[slot]
		return snapshot, ok
	case On_Disk_Store:
		path := slot_path(backend.root, slot, allocator)
		bytes, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil {
			return {}, false
		}
		return Save_Snapshot{bytes = bytes, content_hash = u64(xxhash.XXH64(bytes))}, true
	}
	return {}, false
}

// store_write_settings persists the per-machine Settings record, returning false on
// an IO failure. Settings are NOT sim state and NOT versioned — they are a single
// per-machine record overwritten in place (§24), so the disk arm serializes the one
// record to `settings.snap`.
store_write_settings :: proc(
	store: ^Save_Store,
	settings: Record_Value,
	allocator := context.allocator,
) -> bool {
	switch &backend in store.backend {
	case In_Memory_Store:
		backend.settings = clone_record_value(settings, allocator)
		return true
	case On_Disk_Store:
		bytes := serialize_settings(settings, allocator)
		path := settings_path(backend.root, allocator)
		return os.write_entire_file_from_string(path, string(bytes)) == nil
	}
	return false
}

// store_read_settings reads the persisted Settings record back, ok=false when none
// was ever written. The disk arm deserializes `settings.snap`; a malformed file
// fails closed.
store_read_settings :: proc(
	store: ^Save_Store,
	allocator := context.allocator,
) -> (
	settings: Record_Value,
	ok: bool,
) {
	switch backend in store.backend {
	case In_Memory_Store:
		rec, present := backend.settings.?
		return rec, present
	case On_Disk_Store:
		path := settings_path(backend.root, allocator)
		bytes, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil {
			return {}, false
		}
		return deserialize_settings(bytes, allocator)
	}
	return {}, false
}

// slot_path joins a slot key under the store root as `<root>/<slot>.snap` — the
// disk layout a save/restore round-trips through. The `.snap` extension marks a
// snapshot file so it never collides with the artifact or replay log sitting
// alongside it.
slot_path :: proc(root, slot: string, allocator := context.allocator) -> string {
	return strings.concatenate({root, "/", slot, ".snap"}, allocator)
}

// settings_path is the per-machine settings file under the store root. Settings are
// a single record, so they land at one fixed path rather than a keyed slot.
settings_path :: proc(root: string, allocator := context.allocator) -> string {
	return strings.concatenate({root, "/settings.snap"}, allocator)
}

// --- The pending outcome batch (next-tick deferral, §24 §1) ----------------

// Persist_Outcome is one queued outcome signal awaiting the NEXT tick: its signal
// type (Saved / Restored / SettingsApplied), the slot it carries (empty for
// SettingsApplied), and the Result outcome the menu fold matches. It is the
// persistence analog of Pending_Spawn — produced when a command runs THIS tick,
// delivered into the signal mailbox at the START of the NEXT tick, so the outcome
// arrives one tick boundary after the command (§24 §1).
Persist_Outcome :: struct {
	signal: string, // "Saved" / "Restored" / "SettingsApplied"
	slot:   string, // the slot key (empty for SettingsApplied)
	ok:     bool, // true → Result::Ok, false → Result::Err
}

// Persist_Effects is the result of processing one tick's emitted persist commands:
// the outcome signals to deliver NEXT tick and, when a Restore succeeded, the
// version to SWAP in as the next committed version. A nil swap means no restore
// happened this tick (the common case); a present swap is the restored world the
// frame digest will read next tick.
Persist_Effects :: struct {
	outcomes: []Persist_Outcome, // deferred one tick
	swap:     Maybe(World_Version), // the restored version to commit next tick
}

// process_persist_commands runs one tick's emitted Save/Restore/ApplySettings
// commands against the store over the CURRENT committed version, returning the
// deferred outcomes and any restore swap. The committed version is what a Save
// serializes (the snapshot is of the world AS COMMITTED, not the mid-tick working
// state — §24: a save captures a committed checkpoint). Each command's outcome is
// queued for next-tick delivery; a Restore that reads and verifies a slot also
// supplies the swap version.
//
// A command list with no persist command (the common pong/snake/hunt tick) yields
// empty effects — this path is engaged only by a program that emits §24 commands.
// `program` is the running build's schema authority: a Save records its schemas
// into the snapshot (codec v5) and a Restore migrates the slot's rows against it.
process_persist_commands :: proc(
	store: ^Save_Store,
	program: ^Program,
	committed: World_Version,
	commands: []Record_Value,
	allocator := context.allocator,
) -> Persist_Effects {
	outcomes := make([dynamic]Persist_Outcome, allocator)
	swap: Maybe(World_Version) = nil
	for command in commands {
		switch command.type_name {
		case "Save":
			ok := apply_save(store, program, committed, persist_slot(command), allocator)
			// CLONE the slot onto `allocator`: the outcome is delivered NEXT tick, but
			// persist_slot returns a slice into THIS command's String_Value, which lives
			// on the eval scratch the live loop frees at tick end. The clone keeps the
			// slot valid across the boundary (a no-op-cost copy in bounded paths).
			append(&outcomes, Persist_Outcome{signal = "Saved", slot = strings.clone(persist_slot(command), allocator), ok = ok})
		case "Restore":
			version, ok := apply_restore(store, program, persist_slot(command), allocator)
			if ok {
				swap = version
			}
			append(&outcomes, Persist_Outcome{signal = "Restored", slot = strings.clone(persist_slot(command), allocator), ok = ok})
		case "ApplySettings":
			ok := apply_settings_command(store, command, allocator)
			append(&outcomes, Persist_Outcome{signal = "SettingsApplied", slot = "", ok = ok})
		}
	}
	return Persist_Effects{outcomes = outcomes[:], swap = swap}
}

// persist_slot reads a command's `slot` String column as the slot key, or "" when
// absent (an ApplySettings carries no slot). The slot is the dynamic String the
// save/restore glue carries (yard's SLOT = "quicksave").
persist_slot :: proc(command: Record_Value) -> string {
	slot, present := command.fields["slot"]
	if !present {
		return ""
	}
	if str, is_str := slot.(String_Value); is_str {
		return str.text
	}
	return ""
}

// apply_save serializes the committed version into a content-hash-pinned snapshot
// — stamped with the program's schemas (codec v5) — and writes it to the slot.
// Returns the store-write outcome (false → Result::Err), so a disk write failure
// is the forced error arm the menu fold records (§24).
apply_save :: proc(
	store: ^Save_Store,
	program: ^Program,
	committed: World_Version,
	slot: string,
	allocator := context.allocator,
) -> bool {
	bytes := serialize_snapshot(program, committed, allocator)
	snapshot := Save_Snapshot{bytes = bytes, content_hash = u64(xxhash.XXH64(bytes))}
	return store_write_slot(store, slot, snapshot, allocator)
}

// apply_restore reads a slot, verifies its content hash, deserializes it, and
// MIGRATES it to the loaded program's schemas — restoring under a changed schema
// is the same operation as hot-reload state migration (§24 §1, §09 §4): the
// snapshot's recorded schemas diff against the program's, and the kernel's plan
// folds over the rows (schema_migrate.odin). ok is false on any of: an absent/
// unreadable slot, a content-hash mismatch, a deserialize failure (a snapshot
// from a different codec version), or a MIGRATION REFUSAL (a kernel verdict like
// Unknown_Source, an unsettled decl-set delta, a failed conversion) — each fails
// closed to Result::Err so a bad read is never swapped in as a silent partial
// world (§24 forced-match). An unchanged schema folds the all-Carry identity
// plan, so the common same-build restore is value-identical to the saved world.
apply_restore :: proc(
	store: ^Save_Store,
	program: ^Program,
	slot: string,
	allocator := context.allocator,
) -> (
	version: World_Version,
	ok: bool,
) {
	snapshot, read_ok := store_read_slot(store, slot, allocator)
	if !read_ok {
		return {}, false
	}
	// Content-hash pin: the bytes must hash to the recorded hash, else the slot is
	// corrupt and the restore refuses it rather than swapping a tampered world.
	if u64(xxhash.XXH64(snapshot.bytes)) != snapshot.content_hash {
		return {}, false
	}
	saved, old_schemas, saved_delta, parse_ok := deserialize_snapshot(snapshot.bytes, allocator)
	if !parse_ok {
		return {}, false
	}
	set, compile_refusal := compile_migration(old_schemas, program, allocator)
	if compile_refusal.kind != .None {
		return {}, false
	}
	// §18 §4 / §24 §1: the snapshot recorded the live tile DELTA from the saving
	// build's bake (codec v6), and restore RE-APPLIES it — re-based onto THIS
	// build's bake through the shared carry kernel — so a dug passage survives
	// save/restore exactly as it survives a reload (ADR 2026-06-11). New-bake-wins
	// on any cell the restoring bake can no longer hold (out of grid, dropped
	// layer, tile name gone from the palette). An empty delta (no SetTile ran in
	// the saved session) re-applies to the bake verbatim — the common restore.
	migrated, migrate_refusal := migrate_world_version(set, saved, program, saved_delta, allocator)
	if migrate_refusal.kind != .None {
		return {}, false
	}
	return migrated, true
}

// apply_settings_command persists a command's `settings` record per-machine. Returns
// the store-write outcome (false → Result::Err), the forced error arm
// on_settings_applied records (§24). A command with no settings record is a malformed
// emit and yields false.
apply_settings_command :: proc(
	store: ^Save_Store,
	command: Record_Value,
	allocator := context.allocator,
) -> bool {
	settings, present := command.fields["settings"]
	if !present {
		return false
	}
	rec, is_rec := settings.(Record_Value)
	if !is_rec {
		return false
	}
	return store_write_settings(store, rec, allocator)
}

// outcome_to_signal lifts one queued Persist_Outcome into the signal Record_Value
// the menu fold matches: a Saved/Restored/SettingsApplied record carrying a
// `result: Result::Ok/Err` (and, for save/restore, the `slot` String). The shape
// MUST mirror glue_result_signal in glue_behaviors_test.odin — a Result variant
// boxing a unit payload — so on_persist_result / on_settings_applied fold the
// engine-produced signal identically to the hand-built fixture.
outcome_to_signal :: proc(outcome: Persist_Outcome, allocator := context.allocator) -> Value {
	payload := new(Value, allocator)
	payload^ = Record_Value{type_name = "", fields = make(map[string]Value, allocator)}
	result := Variant_Value {
		enum_type = "Result",
		case_name = outcome.ok ? "Ok" : "Err",
		payload   = payload,
	}
	fields := make(map[string]Value, allocator)
	fields["result"] = result
	if outcome.slot != "" {
		fields["slot"] = String_Value{text = strings.clone(outcome.slot, allocator)}
	}
	return Record_Value{type_name = outcome.signal, fields = fields}
}

// --- The cross-tick persist driver (next-tick outcome delivery + swap) -----

// Persist_Carrier is the state the §24 persist boundary threads ACROSS ticks,
// exactly the way the run threads its persistent Rng: the store, the outcome
// signals a PRIOR tick's commands produced (delivered into THIS tick's mailbox so
// on_persist_result/on_settings_applied read them — the one-tick deferral §24 §1),
// and a pending restore swap (the version a prior Restore read, which THIS tick
// folds from instead of the normal prior commit). It is carried in/out of
// step_tick_persist by value: the returned carrier holds the NEXT tick's pending
// outcomes and swap.
Persist_Carrier :: struct {
	store:   ^Save_Store,
	pending: []Persist_Outcome, // a prior tick's outcomes, to deliver THIS tick
	swap:    Maybe(World_Version), // a prior Restore's version, to fold THIS tick from
}

// new_persist_carrier opens an empty carrier over a store — the seed the first
// persist tick threads from (no pending outcomes, no swap).
new_persist_carrier :: proc(store: ^Save_Store) -> Persist_Carrier {
	return Persist_Carrier{store = store, pending = nil, swap = nil}
}

// step_tick_persist folds one tick with the §24 persist boundary engaged, the
// driver that closes the command-out / outcome-back loop ACROSS ticks. It:
//
//   1. folds from the carrier's pending SWAP version when a prior Restore supplied
//      one (the restored world is the version this tick reads — "the swap presents
//      at the tick boundary"), else from `prior`;
//   2. SEEDS this tick's mailbox with the carrier's pending outcomes BEFORE the
//      behaviors run, so on_persist_result/on_settings_applied (which read [Saved]/
//      [Restored]/[SettingsApplied] from the mailbox) see a PRIOR tick's outcomes —
//      the one-tick deferral that makes an outcome arrive a tick boundary after its
//      command (§24 §1);
//   3. runs the SAME pipeline fold a plain tick runs (run_pipeline_fold), collecting
//      this tick's emitted Save/Restore/ApplySettings commands;
//   4. processes those commands against the store over the COMMITTED version (a Save
//      serializes the committed checkpoint), producing the NEXT tick's pending
//      outcomes and, on a successful Restore, the swap version the next tick folds
//      from.
//
// It returns the committed version for THIS tick (what the frame digest reads now)
// and the next carrier. The persistence IO never touches a committed table, so the
// determinism record is unchanged: a digest of this tick is a pure function of the
// folded sim state + the restored swap (team Lore #9 — §24 is NOT the replay record).
step_tick_persist :: proc(
	program: ^Program,
	prior: World_Version,
	input: Input,
	time: Record_Value,
	carrier: Persist_Carrier,
	allocator := context.allocator,
	rng: ^Rng = nil,
	commit_allocator := context.allocator,
	reclaim_live := false,
) -> (
	version: World_Version,
	next_carrier: Persist_Carrier,
) {
	// ALLOCATOR SPLIT (live-loop memory reclamation). `allocator` is the TRANSIENT
	// eval/working scratch — the live driver passes a per-tick scratch arena it frees
	// each tick. `commit_allocator` is the PERSISTENT allocator the committed version
	// (its tables/rows slices, the cloned blackboard maps/columns), the swap version,
	// and the next-tick outcome signals target — these must survive the scratch reset.
	// A test/bounded caller leaves commit_allocator == allocator (the default), so the
	// split is a no-op and the committed bytes are byte-identical (the determinism floor
	// reads values, not addresses). yard's quicksave/quickload exercises the persist
	// path under the split.
	//
	// A pending swap from a prior Restore is the version this tick folds from — the
	// restored world becomes the base the next tick reads, "swapped at the boundary".
	// The swap was deserialized onto `commit_allocator` by the PRIOR tick's
	// process_persist_commands (see below), so it is an INDEPENDENT version with no
	// alias into any retired version — the live reclaimer retires `prior` fully on the
	// swap tick (no surviving alias) and retires the swap version one tick later, like
	// any base.
	base := prior
	if swap, has_swap := carrier.swap.?; has_swap {
		base = swap
	}

	state := new_tick_state(base, allocator, commit_allocator)
	if rng != nil {
		state.rng = rng^
	}
	// Deliver a prior tick's outcomes into THIS tick's mailbox before the fold, so the
	// menu's on_persist_result/on_settings_applied consume them this tick (the §24 §1
	// one-tick deferral: the command ran last tick, the outcome arrives now). The
	// outcomes were built on commit_allocator last tick (they cross the tick boundary),
	// but seeding lifts them into the mailbox on the eval scratch — a same-tick read.
	seed_outcome_signals(&state, carrier.pending, allocator)

	base_version := base
	interp := new_interp(program, &base_version, &state, input, time, allocator)
	run_pipeline_fold(&interp, &state, program)
	apply_spawn_batch(&state)
	if rng != nil {
		rng^ = state.rng
	}
	// The committed version's tables/rows slices land on the PERSISTENT commit
	// allocator (its blackboard maps already do, via write_blackboard/queue_commands),
	// so the whole committed version survives the eval-scratch reset.
	committed := commit_tick_state(base, &state, commit_allocator)

	// Process this tick's persist commands over the COMMITTED version. The outcomes and
	// any restore-swap CROSS the tick boundary (delivered next tick), so they target the
	// PERSISTENT commit allocator — a swap deserialized onto the eval scratch would be
	// freed before the next tick reads it. The persist_commands records themselves live
	// on the eval scratch (read here, same tick, pre-reset).
	effects := process_persist_commands(carrier.store, program, committed, state.persist_commands[:], commit_allocator)

	// §18 §4 / §24 GAP (deliberate): the save stream serializes thing tables
	// only — dynamic tile-layer state is NOT in the §24 byte format — so a
	// restored swap INHERITS the pre-restore committed version's terrain by
	// reference (tile state survives a restore unchanged). Persisting tile state
	// requires a save-format bump (serializer + saved-hash + schema_migrate);
	// inheriting here keeps the swap version total (a swap with nil tilemaps
	// would erase the terrain from every later render).
	if swap, has_swap := effects.swap.?; has_swap {
		swap.tilemaps = committed.tilemaps
		effects.swap = swap
	}

	// LIVE GENERATIONAL RECLAMATION (reclaim_live; the unbounded-loop bound). Retire the
	// now-dead BASE version on the persistent commit allocator, before the live driver
	// frees the eval scratch. This is the ONLY safe moment and place: `committed` (N+1)
	// has just sealed, nothing reads `base` (N) afterward (render/audio project N+1), and
	// state.superseded — the prior maps the commit ABANDONED — is still live (it is freed
	// here, then its [dynamic] backing dies with the scratch). Bounded callers leave
	// reclaim_live=false and rely on their wholesale temp-free, so the determinism floor
	// path is byte-untouched.
	if reclaim_live {
		// The prior tick's outcomes were consumed by seed_outcome_signals above; their
		// array + cloned slot strings (on commit_allocator) are now stale — free them so a
		// quicksave/quickload session does not leak one outcome set per persist tick.
		free_persist_outcomes(carrier.pending, commit_allocator)

		// Retire `base` (N or the restored swap): its tables/rows structure plus the maps
		// the commit abandoned (superseded). Its UNWRITTEN rows' maps are NOT freed here —
		// they are now aliased solely by `committed` (N+1) and travel forward with it.
		// Tile-layer state retires alias-guarded (free_version_tilemaps skips every
		// slice `committed` or the program's pristine bake still reads).
		free_superseded_maps(state.superseded, commit_allocator)
		free_version_structure(base, commit_allocator)
		free_version_tilemaps(base, committed, program, commit_allocator)

		// On a RESTORE tick the fold bypassed `prior` (it folded from the swap base), so
		// `prior` (the committed N) is referenced by nothing now — N+1 aliases the SWAP's
		// maps, never N's. Free it WHOLLY (structure + every map). A normal tick has
		// base == prior and already retired it above; the pointer compare distinguishes.
		// Its tile state needs no retire here: free_version_fully frees tables and
		// row maps only and never touches tilemaps — `prior`'s tile slice was
		// inherited by the swap (the §24 inherit above) and travels forward with
		// the committed version.
		if !world_versions_same_identity(base, prior) {
			free_version_fully(prior, commit_allocator)
		}
	}

	return committed, Persist_Carrier {
			store = carrier.store,
			pending = effects.outcomes,
			swap = effects.swap,
		}
}

// world_versions_same_identity reports whether two version handles refer to the
// SAME underlying tables slice — the cheap pointer-identity check the live
// reclaimer uses to tell a normal tick (base IS prior) from a restore tick (base
// is the swap, prior is the bypassed committed version). It compares the slice
// data pointers, NOT the contents (world_versions_equal is the value comparison);
// an empty/nil tables slice on both is treated as the same identity.
world_versions_same_identity :: proc(a, b: World_Version) -> bool {
	return raw_data(a.tables) == raw_data(b.tables)
}

// free_persist_outcomes frees a consumed outcome set: each outcome's cloned slot
// string and the outcomes slice backing. The slot was cloned onto `allocator` by
// process_persist_commands so it would survive the producing tick's scratch reset;
// once delivered (seed_outcome_signals) it is dead. A "Saved"/"Restored"/
// "SettingsApplied" signal tag is a static literal and is never freed.
free_persist_outcomes :: proc(outcomes: []Persist_Outcome, allocator := context.allocator) {
	for outcome in outcomes {
		if outcome.slot != "" {
			delete(outcome.slot, allocator)
		}
	}
	delete(outcomes, allocator)
}

// seed_outcome_signals injects a prior tick's persist outcomes into the tick
// mailbox as their signal records, so a consumer behavior reads them as its inbound
// [Saved]/[Restored]/[SettingsApplied] list this tick. Each outcome lifts to the
// signal record outcome_to_signal builds (the same shape the hand-built fixture
// uses), keyed by its signal type — the exact channel route_signals would have used
// had the signal been emitted by a behavior, so the consumer cannot tell an
// engine-delivered outcome from a behavior-emitted one.
seed_outcome_signals :: proc(
	state: ^Tick_State,
	outcomes: []Persist_Outcome,
	allocator := context.allocator,
) {
	for outcome in outcomes {
		signal := outcome_to_signal(outcome, allocator)
		existing := state.mailbox.by_type[outcome.signal]
		combined := make([]Value, len(existing) + 1, allocator)
		copy(combined, existing)
		combined[len(existing)] = signal
		state.mailbox.by_type[outcome.signal] = combined
	}
}

// --- The snapshot codec (full World_Version, deterministic bytes) ----------

// serialize_snapshot writes a World_Version into its canonical byte stream: a magic
// + version header, the tick ordinal, the writing program's SCHEMAS (v5 — every
// data decl and thing blackboard schema as name + per-field name/type-spelling
// pairs, in declaration order), every table (thing name, singleton flag, next_id,
// rows), then the §18 §4 dynamic-tile DELTA (v6 — the live committed layers' diff
// from the SAVING build's bake, sparse and name-keyed). It carries next_id +
// singleton — which the frame digest's frame_bytes deliberately OMITS — so a
// deserialized version is fully SPAWNABLE (a restored world that spawns a thing
// mints the next correct Id, no collision); the schema carry is what lets a LATER
// build's Restore diff and migrate the rows (§24 §1, §09 §4); the tile delta is
// what lets restore re-apply a dug passage onto the restoring bake. The encoding is
// raw little-endian fixed-point throughout (no float, no map-iteration order:
// schemas write in declaration order, row fields in sorted name order, the delta in
// the kernel's stable layer-decl-then-row-major order), so a serialize → deserialize
// → re-serialize round-trips bit-for-bit and a restored version digests identically
// to the version that was saved.
serialize_snapshot :: proc(program: ^Program, version: World_Version, allocator := context.allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	snap_put_u64(&buf, SAVE_SNAPSHOT_MAGIC)
	snap_put_u64(&buf, SAVE_SNAPSHOT_SCHEMA_VERSION)
	snap_put_u64(&buf, u64(i64(version.tick)))
	snap_put_u64(&buf, u64(len(program.data)))
	for &decl in program.data {
		snap_put_string(&buf, decl.name)
		snap_write_field_schema(&buf, decl.fields)
	}
	snap_put_u64(&buf, u64(len(program.things)))
	for &decl in program.things {
		snap_put_string(&buf, decl.name)
		snap_write_field_schema(&buf, decl.fields)
	}
	snap_put_u64(&buf, u64(len(version.tables)))
	for table in version.tables {
		snap_put_string(&buf, table.thing)
		append(&buf, table.singleton ? u8(1) : u8(0))
		snap_put_u64(&buf, u64(table.next_id))
		snap_put_u64(&buf, u64(len(table.rows)))
		for row in table.rows {
			snap_write_row(&buf, row)
		}
	}
	// v6 §18 §4 / §24 §1: the dynamic-tile delta — the live committed layers
	// (`version.tilemaps`) diffed against the SAVING build's bake (`program.tilemaps`),
	// exactly the cells SetTile rewrote. The same kernel hot-reload sources from live
	// memory; here the saving build records it into the bytes so restore can
	// reconstruct it against the restoring build's bake (the saving and restoring
	// bakes may differ). Empty delta ⇒ a lone `u64(0)` count, byte-inert.
	snap_write_tile_carry(&buf, tile_carry_delta(program.tilemaps, version.tilemaps, allocator))
	return buf[:]
}

// snap_write_tile_carry writes the §18 §4 dynamic-tile delta in the kernel's
// DETERMINISTIC order (the slice is already old-bake layer-decl then row-major, no
// map iteration): the edit count, then each edit as (layer name, col, row, tile
// name). Coordinates are signed ints written through the u64 lane (two's-complement
// bits, the same cast snap_write_field_value uses for an i64 column), so the codec
// stays raw little-endian with no float.
snap_write_tile_carry :: proc(buf: ^[dynamic]u8, delta: Tile_Carry_Delta) {
	snap_put_u64(buf, u64(len(delta.edits)))
	for edit in delta.edits {
		snap_put_string(buf, edit.layer_name)
		snap_put_u64(buf, u64(i64(edit.col)))
		snap_put_u64(buf, u64(i64(edit.row)))
		snap_put_string(buf, edit.tile_name)
	}
}

// snap_write_row writes one row: its raw Id then its blackboard columns in SORTED
// field-name order (the same map-invariance discipline the frame digest applies),
// so the snapshot bytes depend on the row CONTENT, never on how the field map was
// built.
snap_write_row :: proc(buf: ^[dynamic]u8, row: Row) {
	snap_put_u64(buf, u64(row.id.raw))
	names := snap_sorted_field_names(row.fields)
	snap_put_u64(buf, u64(len(names)))
	for name in names {
		snap_put_string(buf, name)
		snap_write_field_value(buf, row.fields[name])
	}
}

// snap_write_field_value writes one blackboard column tagged by its Field_Tag arm —
// the SAME closed tag set the frame digest uses, so a column serializes one way for
// both surfaces. Numbers are raw little-endian bits (§10), a Record/List recurses,
// a Ref is its target name + raw Id, a payload-carrying variant column writes its
// boxed payload after the token, a String column writes its text. The Field_Value
// union is total over these arms.
snap_write_field_value :: proc(buf: ^[dynamic]u8, value: Field_Value) {
	switch v in value {
	case i64:
		append(buf, u8(Field_Tag.Int))
		snap_put_u64(buf, u64(v))
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		snap_put_u64(buf, u64(i64(v)))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, v ? u8(1) : u8(0))
	case string:
		append(buf, u8(Field_Tag.Variant))
		snap_put_string(buf, v)
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		snap_put_u64(buf, u64(i64(v.x)))
		snap_put_u64(buf, u64(i64(v.y)))
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		snap_put_u64(buf, u64(i64(v.x)))
		snap_put_u64(buf, u64(i64(v.y)))
		snap_put_u64(buf, u64(i64(v.z)))
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		snap_put_string(buf, v.thing)
		snap_put_u64(buf, u64(v.id.raw))
	case Record_Value:
		append(buf, u8(Field_Tag.Record))
		snap_write_record(buf, v)
	case List_Value:
		append(buf, u8(Field_Tag.List))
		snap_write_list(buf, v)
	case Variant_Value:
		// A Field_Value variant column is payload-carrying by construction (a unit
		// variant commits as the bare-token string arm) — but a hand-built row can
		// violate that, so a nil payload degrades to the token-only form rather
		// than dereferencing nil (the codec stays total, §10 discipline).
		if v.payload == nil {
			append(buf, u8(Field_Tag.Variant))
			snap_put_string(buf, variant_to_token(v, context.temp_allocator))
		} else {
			append(buf, u8(Field_Tag.Variant_Payload))
			snap_put_string(buf, variant_to_token(v, context.temp_allocator))
			snap_write_column_value(buf, v.payload^)
		}
	case String_Value:
		append(buf, u8(Field_Tag.String))
		snap_put_string(buf, v.text)
	}
}

// snap_write_record writes a composite record column (snake's `head: Cell`): the
// type name, the field count, then each field in SORTED name order — map-invariant
// the same way the row blackboard is.
snap_write_record :: proc(buf: ^[dynamic]u8, rec: Record_Value) {
	snap_put_string(buf, rec.type_name)
	names := snap_sorted_value_field_names(rec.fields)
	snap_put_u64(buf, u64(len(names)))
	for name in names {
		snap_put_string(buf, name)
		snap_write_column_value(buf, rec.fields[name])
	}
}

// snap_write_list writes a `[T]` list column (snake's `body: [Cell]`): the element
// count then each element in LIST order — order is the list's canonical sequence,
// written verbatim, never sorted.
snap_write_list :: proc(buf: ^[dynamic]u8, list: List_Value) {
	snap_put_u64(buf, u64(len(list.elements)))
	for elem in list.elements {
		snap_write_column_value(buf, elem)
	}
}

// snap_write_column_value writes one Value nested in a structural column, tagged by
// the same Field_Tag set the top-level columns use, so a Cell column and a Cell
// nested in a list serialize identically. A transient (lambda / render String /
// tuple / Rng) cannot appear in a committed column and is written tag-less, a
// defensive no-op (value_to_field_value already excluded it before commit).
snap_write_column_value :: proc(buf: ^[dynamic]u8, v: Value) {
	switch x in v {
	case i64:
		append(buf, u8(Field_Tag.Int))
		snap_put_u64(buf, u64(x))
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		snap_put_u64(buf, u64(i64(x)))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, x ? u8(1) : u8(0))
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		snap_put_u64(buf, u64(i64(x.x)))
		snap_put_u64(buf, u64(i64(x.y)))
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		snap_put_u64(buf, u64(i64(x.x)))
		snap_put_u64(buf, u64(i64(x.y)))
		snap_put_u64(buf, u64(i64(x.z)))
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		snap_put_string(buf, x.thing)
		snap_put_u64(buf, u64(x.id.raw))
	case Variant_Value:
		// A payload-carrying variant (a body's Shape2::Box{size}) writes its boxed
		// payload after the token under the v2 Variant_Payload tag — flattening to
		// the bare token here is exactly the v1 lossiness that degraded restored
		// collision/render shapes. A unit variant stays on the plain Variant tag.
		if x.payload != nil {
			append(buf, u8(Field_Tag.Variant_Payload))
			snap_put_string(buf, variant_to_token(x, context.temp_allocator))
			snap_write_column_value(buf, x.payload^)
		} else {
			append(buf, u8(Field_Tag.Variant))
			snap_put_string(buf, variant_to_token(x, context.temp_allocator))
		}
	case Record_Value:
		append(buf, u8(Field_Tag.Record))
		snap_write_record(buf, x)
	case List_Value:
		append(buf, u8(Field_Tag.List))
		snap_write_list(buf, x)
	case String_Value:
		// A String nested in a payload/record/list serializes its text — lumping it
		// into the transients' tag-less no-op would CORRUPT the stream (field
		// framing with no value bytes).
		append(buf, u8(Field_Tag.String))
		snap_put_string(buf, x.text)
	case Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value:
	// A transient never lands in a committed structural column — the §16 §7 anim
	// VALUES (Transform/Pose/handle) are render-time, composed into a [Draw3] list,
	// never persisted. A Vec3 is NOT here: a committed Vec3 column (a thing's `pos`,
	// or a Vec3 nested in a record column) serializes through the Vec3 arm above.
	}
}

// deserialize_snapshot parses a snapshot byte stream back into a World_Version,
// the SCHEMAS the writing build recorded (v5) — the OLD side of the §09 §4 schema
// diff a Restore under a changed schema feeds to compile_migration — and the §18 §4
// dynamic-TILE DELTA the writing build recorded (v6). The delta comes back as a
// SEPARATE out-value, NOT folded into version.tilemaps: deserialize has only bytes,
// so it cannot re-base the delta onto a bake (that needs the RESTORING program's
// tilemaps, which the caller holds). apply_restore re-applies it through
// migrate_world_version; version.tilemaps stays unset out of here. ok is false on a
// wrong magic, a version this build was not built for, or any truncation/malformed
// record that runs the cursor past the buffer — so a Restore of a corrupt or foreign
// snapshot fails closed (Result::Err) rather than swapping a partial world. The
// reconstructed version carries next_id + singleton, so it is fully spawnable and
// digests identically to the saved version.
deserialize_snapshot :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (
	version: World_Version,
	schemas: Schema_Set,
	carry: Tile_Carry_Delta,
	ok: bool,
) {
	cur := Snap_Cursor{data = bytes, pos = 0}
	magic := snap_get_u64(&cur) or_return
	if magic != SAVE_SNAPSHOT_MAGIC {
		return {}, {}, {}, false
	}
	ver := snap_get_u64(&cur) or_return
	if ver != SAVE_SNAPSHOT_SCHEMA_VERSION {
		return {}, {}, {}, false
	}
	tick := i64(snap_get_u64(&cur) or_return)
	schemas.data = snap_read_schema_block(&cur, allocator) or_return
	schemas.things = snap_read_schema_block(&cur, allocator) or_return
	table_count := snap_get_u64(&cur) or_return
	tables := make([]Version_Table, int(table_count), allocator)
	for ti in 0 ..< int(table_count) {
		thing := snap_get_string(&cur, allocator) or_return
		singleton_byte := snap_get_u8(&cur) or_return
		next_id := Thing_Id(snap_get_u64(&cur) or_return)
		row_count := snap_get_u64(&cur) or_return
		rows := make([]Row, int(row_count), allocator)
		for ri in 0 ..< int(row_count) {
			rows[ri] = snap_read_row(&cur, allocator) or_return
		}
		tables[ti] = Version_Table {
			thing     = thing,
			singleton = singleton_byte != 0,
			rows      = rows,
			next_id   = next_id,
		}
	}
	carry = snap_read_tile_carry(&cur, allocator) or_return
	return World_Version{tick = int(tick), tables = tables}, schemas, carry, true
}

// snap_read_tile_carry parses the v6 dynamic-tile delta back into a Tile_Carry_Delta
// — the inverse of snap_write_tile_carry, in the recorded slice order. The
// coordinates read through the u64 lane and cast back to int (the same two's-
// complement bits snap_read_field_value's Int arm uses). ok=false on a count or
// string that runs the cursor past the buffer, so a truncated delta fails the whole
// restore closed.
snap_read_tile_carry :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	delta: Tile_Carry_Delta,
	ok: bool,
) {
	count := snap_get_u64(cur) or_return
	edits := make([]Tile_Carry_Edit, int(count), allocator)
	for i in 0 ..< int(count) {
		layer_name := snap_get_string(cur, allocator) or_return
		col := int(i64(snap_get_u64(cur) or_return))
		row := int(i64(snap_get_u64(cur) or_return))
		tile_name := snap_get_string(cur, allocator) or_return
		edits[i] = Tile_Carry_Edit {
			layer_name = layer_name,
			col        = col,
			row        = row,
			tile_name  = tile_name,
		}
	}
	return Tile_Carry_Delta{edits = edits}, true
}

// snap_write_field_schema writes one decl's field schema: the field count, then
// each field's (name, type spelling) in DECLARATION order — the only two facts
// the diff kernel reads from the old side (defaults and migrate metadata are
// new-side facts, so the snapshot never carries them).
snap_write_field_schema :: proc(buf: ^[dynamic]u8, fields: []Field_Decl) {
	snap_put_u64(buf, u64(len(fields)))
	for fd in fields {
		snap_put_string(buf, fd.name)
		snap_put_string(buf, fd.type)
	}
}

// snap_read_schema_block parses one v5 schema block (data decls or thing
// schemas) back into Old_Schema records — the inverse of the serialize side's
// decl walk, in the recorded declaration order.
snap_read_schema_block :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	schemas: []Old_Schema,
	ok: bool,
) {
	count := snap_get_u64(cur) or_return
	out := make([]Old_Schema, int(count), allocator)
	for i in 0 ..< int(count) {
		name := snap_get_string(cur, allocator) or_return
		field_count := snap_get_u64(cur) or_return
		fields := make([]Schema_Field, int(field_count), allocator)
		for j in 0 ..< int(field_count) {
			field_name := snap_get_string(cur, allocator) or_return
			field_type := snap_get_string(cur, allocator) or_return
			fields[j] = Schema_Field{name = field_name, type_spelling = field_type}
		}
		out[i] = Old_Schema{name = name, fields = fields}
	}
	return out, true
}

// snap_read_row parses one row: its Id then its sorted-name blackboard columns. The
// fields land in a fresh map; map order is irrelevant since the digest/codec both
// re-sort, so the parsed row is value-identical to the serialized one.
snap_read_row :: proc(cur: ^Snap_Cursor, allocator := context.allocator) -> (row: Row, ok: bool) {
	id_raw := snap_get_u64(cur) or_return
	field_count := snap_get_u64(cur) or_return
	fields := make(map[string]Field_Value, int(field_count), allocator)
	for _ in 0 ..< int(field_count) {
		name := snap_get_string(cur, allocator) or_return
		value := snap_read_field_value(cur, allocator) or_return
		fields[name] = value
	}
	return Row{id = Id{raw = Thing_Id(id_raw)}, fields = fields}, true
}

// snap_read_field_value parses one tagged column back into its Field_Value arm — the
// inverse of snap_write_field_value. An unknown tag is a malformed snapshot and
// fails closed.
snap_read_field_value :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	fv: Field_Value,
	ok: bool,
) {
	tag := snap_get_u8(cur) or_return
	switch Field_Tag(tag) {
	case .Int:
		return i64(snap_get_u64(cur) or_return), true
	case .Fixed:
		return Fixed(i64(snap_get_u64(cur) or_return)), true
	case .Bool:
		return (snap_get_u8(cur) or_return) != 0, true
	case .Variant:
		return snap_get_string(cur, allocator) or_return, true
	case .Vec2:
		x := Fixed(i64(snap_get_u64(cur) or_return))
		y := Fixed(i64(snap_get_u64(cur) or_return))
		return Vec2{x = x, y = y}, true
	case .Vec3:
		x := Fixed(i64(snap_get_u64(cur) or_return))
		y := Fixed(i64(snap_get_u64(cur) or_return))
		z := Fixed(i64(snap_get_u64(cur) or_return))
		return Vec3{x = x, y = y, z = z}, true
	case .Ref:
		thing := snap_get_string(cur, allocator) or_return
		raw := snap_get_u64(cur) or_return
		return Ref{thing = thing, id = Id{raw = Thing_Id(raw)}}, true
	case .Record:
		rec := snap_read_record(cur, allocator) or_return
		return rec, true
	case .List:
		list := snap_read_list(cur, allocator) or_return
		return list, true
	case .Variant_Payload:
		// A payload-carrying variant COLUMN (yard's `status: Option[String]`
		// holding Some("saved")): the token splits back into its tag pair and the
		// boxed payload parses recursively — the same reconstruction the nested
		// reader does, lifted onto the Field_Value variant arm.
		token := snap_get_string(cur, allocator) or_return
		inner := snap_read_column_value(cur, allocator) or_return
		payload := new(Value, allocator)
		payload^ = inner
		variant := variant_from_token(token)
		variant.payload = payload
		return variant, true
	case .String:
		text := snap_get_string(cur, allocator) or_return
		return String_Value{text = text}, true
	}
	return nil, false
}

// snap_read_record parses a composite record column back: its type name and its
// sorted-name fields. The inverse of snap_write_record.
snap_read_record :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	rec: Record_Value,
	ok: bool,
) {
	type_name := snap_get_string(cur, allocator) or_return
	field_count := snap_get_u64(cur) or_return
	fields := make(map[string]Value, int(field_count), allocator)
	for _ in 0 ..< int(field_count) {
		name := snap_get_string(cur, allocator) or_return
		value := snap_read_column_value(cur, allocator) or_return
		fields[name] = value
	}
	return Record_Value{type_name = type_name, fields = fields}, true
}

// snap_read_list parses a `[T]` list column back: its element count then each
// element in list order. The inverse of snap_write_list.
snap_read_list :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	list: List_Value,
	ok: bool,
) {
	count := snap_get_u64(cur) or_return
	elements := make([]Value, int(count), allocator)
	for i in 0 ..< int(count) {
		elements[i] = snap_read_column_value(cur, allocator) or_return
	}
	return List_Value{elements = elements}, true
}

// snap_read_column_value parses one nested column Value back — the inverse of
// snap_write_column_value over the same Field_Tag set. An enum Variant lifts its
// token back to a Variant_Value (variant_from_token), the form a committed
// structural column holds.
snap_read_column_value :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	v: Value,
	ok: bool,
) {
	tag := snap_get_u8(cur) or_return
	switch Field_Tag(tag) {
	case .Int:
		return i64(snap_get_u64(cur) or_return), true
	case .Fixed:
		return Fixed(i64(snap_get_u64(cur) or_return)), true
	case .Bool:
		return (snap_get_u8(cur) or_return) != 0, true
	case .Vec2:
		x := Fixed(i64(snap_get_u64(cur) or_return))
		y := Fixed(i64(snap_get_u64(cur) or_return))
		return Vec2{x = x, y = y}, true
	case .Vec3:
		x := Fixed(i64(snap_get_u64(cur) or_return))
		y := Fixed(i64(snap_get_u64(cur) or_return))
		z := Fixed(i64(snap_get_u64(cur) or_return))
		return Vec3{x = x, y = y, z = z}, true
	case .Ref:
		thing := snap_get_string(cur, allocator) or_return
		raw := snap_get_u64(cur) or_return
		return Ref{thing = thing, id = Id{raw = Thing_Id(raw)}}, true
	case .Variant:
		token := snap_get_string(cur, allocator) or_return
		return variant_from_token(token), true
	case .Variant_Payload:
		// The inverse of the write side's payload arm: the token splits back into
		// its tag pair and the boxed payload value parses recursively, so the
		// restored variant compares payload-equal to the committed one (§03
		// universal Eq) — the round-trip a Restore's shape read relies on.
		token := snap_get_string(cur, allocator) or_return
		inner := snap_read_column_value(cur, allocator) or_return
		payload := new(Value, allocator)
		payload^ = inner
		variant := variant_from_token(token)
		variant.payload = payload
		return variant, true
	case .String:
		text := snap_get_string(cur, allocator) or_return
		return String_Value{text = text}, true
	case .Record:
		rec := snap_read_record(cur, allocator) or_return
		return rec, true
	case .List:
		list := snap_read_list(cur, allocator) or_return
		return list, true
	}
	return nil, false
}

// --- Settings serialization (a single per-machine record) ------------------

// serialize_settings writes the per-machine Settings record as a magic + version
// header followed by the one record (the SAME column codec the snapshot uses). It
// is the single record overwritten in place, not a versioned snapshot, so it leads
// with the magic but carries no tick/table framing — just one record.
serialize_settings :: proc(settings: Record_Value, allocator := context.allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	snap_put_u64(&buf, SAVE_SNAPSHOT_MAGIC)
	snap_put_u64(&buf, SAVE_SNAPSHOT_SCHEMA_VERSION)
	snap_write_record(&buf, settings)
	return buf[:]
}

// deserialize_settings parses the per-machine Settings record back, ok=false on a
// wrong magic/version or a malformed record so a corrupt settings file fails closed
// rather than restoring a partial record.
deserialize_settings :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (
	settings: Record_Value,
	ok: bool,
) {
	cur := Snap_Cursor{data = bytes, pos = 0}
	magic := snap_get_u64(&cur) or_return
	if magic != SAVE_SNAPSHOT_MAGIC {
		return {}, false
	}
	ver := snap_get_u64(&cur) or_return
	if ver != SAVE_SNAPSHOT_SCHEMA_VERSION {
		return {}, false
	}
	return snap_read_record(&cur, allocator)
}

// --- Byte cursor (read side) + writers (write side) ------------------------

// Snap_Cursor is a bounds-checked read cursor over a snapshot byte stream: the
// backing bytes and the current read position. Every read advances pos and returns
// ok=false past the end, so a truncated stream fails closed instead of reading off
// the buffer.
Snap_Cursor :: struct {
	data: []u8,
	pos:  int,
}

// snap_get_u8 reads one byte, ok=false past the end.
snap_get_u8 :: proc(cur: ^Snap_Cursor) -> (b: u8, ok: bool) {
	if cur.pos + 1 > len(cur.data) {
		return 0, false
	}
	b = cur.data[cur.pos]
	cur.pos += 1
	return b, true
}

// snap_get_u64 reads 8 little-endian bytes via core:encoding/endian (Odin-first,
// the same primitive the writer uses), ok=false past the end.
snap_get_u64 :: proc(cur: ^Snap_Cursor) -> (v: u64, ok: bool) {
	if cur.pos + 8 > len(cur.data) {
		return 0, false
	}
	v, ok = endian.get_u64(cur.data[cur.pos:cur.pos + 8], .Little)
	if !ok {
		return 0, false
	}
	cur.pos += 8
	return v, true
}

// snap_get_string reads a length-prefixed string (u64 length then the raw bytes),
// cloning into the supplied allocator so the parsed value outlives the source
// buffer. ok=false on a length that runs past the end.
snap_get_string :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	s: string,
	ok: bool,
) {
	length := int(snap_get_u64(cur) or_return)
	if cur.pos + length > len(cur.data) {
		return "", false
	}
	s = strings.clone(string(cur.data[cur.pos:cur.pos + length]), allocator)
	cur.pos += length
	return s, true
}

// snap_put_u64 appends a value's 8 little-endian bytes via core:encoding/endian —
// the SAME byte-order primitive the frame digest's put_u64_le uses, so a Fixed/Int
// serializes to the identical bits the digest folds. A signed value is cast to u64
// by the caller (same two's-complement bits).
snap_put_u64 :: proc(buf: ^[dynamic]u8, v: u64) {
	scratch: [8]u8
	_ = endian.put_u64(scratch[:], .Little, v)
	append(buf, ..scratch[:])
}

// snap_put_string appends a length-prefixed string (u64 length then raw bytes) — so
// a name carrying any byte never collides with the framing and an empty string is
// distinguishable from an absent one.
snap_put_string :: proc(buf: ^[dynamic]u8, s: string) {
	snap_put_u64(buf, u64(len(s)))
	append(buf, ..transmute([]u8)s)
}

// snap_sorted_field_names returns a row blackboard's field names in ascending byte
// order — the defined total order that makes the snapshot bytes map-invariant, the
// same discipline the frame digest applies. Allocated on the temp allocator (short,
// few names; freed with the tick arena).
snap_sorted_field_names :: proc(fields: map[string]Field_Value) -> []string {
	names := make([dynamic]string, 0, len(fields), context.temp_allocator)
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names[:]
}

// snap_sorted_value_field_names is the Record_Value variant of the above — the same
// ascending byte order over a `map[string]Value` so a nested record column is
// map-invariant.
snap_sorted_value_field_names :: proc(fields: map[string]Value) -> []string {
	names := make([dynamic]string, 0, len(fields), context.temp_allocator)
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names[:]
}
