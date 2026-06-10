// The per-tick transaction (spec §07 §4, §08): one tick is one deterministic
// fold over the flattened pipeline that reads a committed world version and
// commits the next. The tick is the WRITE side state.odin's read layer is the
// counterpart of — a behavior never mutates the world it observes; it RETURNS a
// blackboard/signal/command, and this file folds those returns into the next COW
// version (commit_version, state.odin).
//
// The fold's determinism rests on a fixed visitation order, restated here so the
// ordering rules live with the code that enforces them:
//   1. startup runs once before tick 0 — setup's [Spawn] batch is the initial
//      population, so tick 0 already sees the spawned things.
//   2. stages run top-to-bottom in the one flattened total order (§11).
//   3. within a stage, a behavior runs ONCE PER INSTANCE of its on-Thing in
//      stable Id order (the View iteration order, §08 §2).
//   4. a blackboard write folds FORWARD within the tick: a later stage reads
//      every earlier stage's writes (the working rows carry them).
//   5. a signal routes FORWARD synchronously in pipeline order: a signal a
//      producer emits is delivered to every later consuming stage the same tick,
//      with no mailbox and no concurrency (the inbound lists accumulate).
//   6. Spawn/Despawn apply as ONE deterministic batch at the tick boundary, so a
//      thing spawned this tick is first queryable NEXT tick and population is
//      fixed within a tick.
//
// Every committed Version_Table keeps its rows ASCENDING by Id — the invariant
// find_row_by_id's binary search (state.odin) and View iteration both depend on.
// The fold sorts each table's working rows by Id before committing, so an
// out-of-order spawn batch still commits an ordered table. No float (spec §10).
package funpack_runtime

import "core:slice"
import "core:strings"

// --- Working state the fold threads ---------------------------------------

// Tick_Table is one thing type's MUTABLE working rows during a tick: the rows a
// behavior's blackboard write folds into, keyed for in-place update by Id, plus
// the next-Id counter the spawn batch mints from. It is the per-tick scratch
// counterpart of the committed Version_Table — committed (sorted, immutable) at
// the tick boundary, never read by the next tick directly.
Tick_Table :: struct {
	thing:     string,
	singleton: bool,
	rows:      [dynamic]Row, // working rows, updated in place; sorted at commit
	next_id:   Thing_Id, // the deterministic spawn counter
}

// Signal_Mailbox accumulates the signals emitted SO FAR this tick. It carries TWO
// routing surfaces, by the signal's delivery shape (§12 forward synchronous):
//   - by_type: BROADCAST user signals (pong's Goal, yard's Delivered). Every
//     consumer of the type reads the same accumulated list — a fan-out signal.
//   - by_instance: PER-INSTANCE engine signals (§11 §4 Contact/Trigger), keyed by
//     type then by the TARGET row's Id. The engine routes each to the specific
//     participating instance, and a consumer `on T` reading `[Trigger]` sees ONLY
//     its own instance's entries (§11 §4: "no self.id to fetch, no list to
//     filter"). A broadcast read of a per-instance signal would deliver one
//     overlapping crate's Trigger to EVERY crate — three deliveries from one
//     overlap — so the split is load-bearing for yard's single-crate delivery.
// Because the fold is forward in pipeline order, a list a consumer reads holds
// exactly the signals every earlier producer emitted this tick. It is reset each
// tick.
Signal_Mailbox :: struct {
	by_type:     map[string][]Value, // BROADCAST signal type → emitted records this tick
	by_instance: map[string]map[Id][]Value, // PER-INSTANCE signal type → target Id → records
}

// Tick_State is all the mutable working state one tick threads: the per-thing
// working tables (blackboard writes fold here), the signal mailbox (forward
// routing), the pending spawn/despawn batch (applied at the boundary), the THREADED
// per-tick Rng resource, and the arena the tick's intermediate values live in. It
// is built fresh each tick from the prior committed version and discarded after the
// commit.
//
// The Rng is threaded the same way the world version is: it enters at tick start
// (the prior tick's advanced state — or the tick-0 seed retained from setup),
// every behavior that draws ADVANCES it in fold-forward order (so the draw order is
// the deterministic flattened-pipeline + stable-Id order this file already
// enforces), and the advanced state is read back out at the tick boundary into the
// run's persistent Rng so the NEXT tick observes it (§04 §1 — never silently
// advanced, threaded forward). Whether a fold threads an Rng at all is the
// nil-gating in step_tick (`rng != nil`): a non-RNG program (pong, hunt) passes
// no Rng and the fold never perturbs one it has no business touching.
Tick_State :: struct {
	tables:          []Tick_Table,
	mailbox:         Signal_Mailbox,
	spawns:          [dynamic]Pending_Spawn,
	despawns:        [dynamic]Ref,
	persist_commands: [dynamic]Record_Value, // the §24 Save/Restore/ApplySettings emits this tick
	rng:             Rng, // the per-tick PRNG state a draw advances, threaded fold-forward
	// superseded collects the blackboard maps this tick ABANDONED — a row's prior
	// map replaced by write_blackboard's fresh one, or a despawned row's map. These
	// are exactly the prior-version (and intermediate same-tick) maps the next
	// committed version no longer aliases, so the live generational reclaimer
	// (reclaim.odin) frees them O(delta) once this tick commits. Empty for a tick
	// that writes/despawns nothing (pure read tick). The live driver consumes it;
	// the bounded test/re-fold drivers ignore it (their wholesale temp-free covers
	// the same maps).
	superseded:      [dynamic]map[string]Field_Value,
	// query_memo is the §08 §3 WITHIN-TICK query memoization: evaluated query
	// results keyed by (query name, canonical argument bytes), living exactly
	// one tick — the cache is part of the tick state, so the tick boundary
	// clears it by construction. A query is pure over its arguments (its body
	// sees only its params plus module consts), so a key hit returns the
	// identical value the first caller paid for; the hit/miss counters are the
	// observable the memoization tests pin (a pure cache has no value-level
	// side effect to assert on).
	query_memo:        map[string]Value,
	query_memo_hits:   int,
	query_memo_misses: int,
	// allocator is the TRANSIENT eval/working allocator: the working tables' Row
	// backing, the mailbox routing, the spawn/despawn/persist batches, and every
	// intermediate value a behavior builds during the fold live here. It is the
	// tick's scratch — discarded after the tick.
	allocator:       Runtime_Allocator,
	// commit_allocator is the PERSISTENT allocator the committed-state allocations
	// target — the blackboard MAPS and the cloned structural COLUMNS that survive
	// into the next version (write_blackboard's fresh map, queue_commands' spawn
	// fields). It is split from `allocator` SOLELY so the live loop can run the
	// transient eval on a per-tick scratch arena (freed each tick) while the
	// committed columns persist on the heap the generational reclaimer manages
	// (reclaim.odin). In every bounded path (step_tick, replay re-fold, tests) the
	// two are the SAME allocator, so the split is a no-op there and the committed
	// bytes are byte-identical regardless of the split — the determinism floor reads
	// values, never addresses.
	commit_allocator: Runtime_Allocator,
	// observe is the §28 OBSERVE-class introspection tap (introspect.odin). When
	// non-nil, the fold COPIES each behavior step's bound env/result and each
	// routed signal into the capture buffers as it folds — a pure read of values
	// the fold already computed, never a write into tick state, so an observed
	// fold commits bit-identical state to an unobserved one (the §28 §2
	// non-perturbation warranty; the introspect digest-pin test holds it). nil
	// (every production driver) costs one pointer compare per tap site.
	observe:          ^Tick_Observe,
}

// Pending_Spawn is one queued Spawn command awaiting the tick-boundary batch: the
// thing type and the fully-evaluated blackboard the new row will carry. It is
// applied (a fresh Id minted, the row appended) only at the boundary, so a thing
// spawned this tick is first queryable next tick.
Pending_Spawn :: struct {
	thing:  string,
	fields: map[string]Field_Value,
}

// --- Startup: the pre-tick-0 spawn batch (§06 setup, §13) -----------------

// run_startup populates the empty initial version tick 0 reads (§06 setup runs
// before tick 0) in two passes, in this fixed order:
//   1. the engine mints each singleton's guaranteed-single row from its
//      defaulted-field schema (§06 §2) — the sole, authoritative minter of a
//      singleton row, run BEFORE setup because a singleton exists before tick 0
//      and is never setup-spawned;
//   2. setup's [Spawn] batch mints the ordinary initial population, each
//      Spawn_Command filling supplied fields from the decoded setup values and
//      every omitted field from the thing's Field_Decl default.
// So the committed base carries a complete blackboard per row. The committed
// tables are sorted ascending by Id (the spawn counters mint densely, so they
// already are; the sort makes the invariant explicit).
run_startup :: proc(
	program: ^Program,
	base: World_Version,
	allocator := context.allocator,
) -> World_Version {
	tables := new_tick_tables(base, allocator)

	// Pass 1: the engine mints each singleton's single row before setup runs.
	spawn_engine_singletons(program, tables, allocator)

	// Pass 2: setup's [Spawn] batch mints the ordinary initial population.
	for command in program.setup {
		table := find_tick_table(tables, command.thing)
		if table == nil {
			continue
		}
		fields := build_spawn_blackboard(program, command, allocator)
		id := Id{raw = table.next_id}
		table.next_id += 1
		append(&table.rows, Row{id = id, fields = fields})
	}

	return commit_tick_tables(base, tables, allocator)
}

// spawn_engine_singletons mints ONE row per `Thing_Decl.singleton == true` thing
// from its Field_Decl defaults (§06 §2: a singleton is engine-spawned, accessed by
// type, never iterated). It is the SOLE, authoritative minter of a singleton row —
// run before the setup batch, since a singleton exists before tick 0 and is never
// setup-spawned (§13). It walks program.things in declaration order — the same
// stable order new_world builds the tables in — so the spawn sequence is a pure
// function of the schema, identical every run (no RNG, no input). Each singleton's
// row fills every field from its decoded Field_Decl default via decode_default (the
// SAME composite Body/Settings/Option decode the setup-batch path uses), so a
// singleton row carries a complete blackboard exactly as a setup spawn does. The
// row lands at the table's next minted Id (Id 0 in the otherwise-empty singleton
// table this pass runs against); the commit's sort keeps it ascending.
//
// A field with no default is left absent — the loader's §6 gate already proved a
// singleton's fields all carry defaults, so this never drops a required column for a
// well-formed artifact.
spawn_engine_singletons :: proc(
	program: ^Program,
	tables: []Tick_Table,
	allocator := context.allocator,
) {
	for thing in program.things {
		if !thing.singleton {
			continue
		}
		table := find_tick_table(tables, thing.name)
		if table == nil {
			continue
		}
		fields := build_singleton_blackboard(program, thing, allocator)
		id := Id{raw = table.next_id}
		table.next_id += 1
		append(&table.rows, Row{id = id, fields = fields})
	}
}

// build_singleton_blackboard decodes a singleton thing's complete blackboard from
// its Field_Decl defaults — every field filled from its `=ENCODED` default through
// decode_default (the bare-scalar Int/Fixed/Bool/Vec2 forms AND the composite
// Body/Settings/Option forms the v5 decode story landed). Unlike a setup spawn,
// a singleton supplies NO fields (it has no Spawn_Command), so every column comes
// from the schema default — the singleton's row is the pure schema-default image.
// A field without a default is omitted (a malformed artifact the §6 gate refuses);
// `allocator` owns the structural columns (the commit arena).
build_singleton_blackboard :: proc(
	program: ^Program,
	thing: Thing_Decl,
	allocator := context.allocator,
) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, allocator)
	for fd in thing.fields {
		if !fd.has_default {
			continue
		}
		if v, ok := decode_default(program, fd, allocator); ok {
			fields[fd.name] = own_committed_column(v, allocator)
		}
	}
	return fields
}

// own_committed_column re-clones a freshly-DECODED startup column into a fully-owned
// tree on `allocator` (deep_clone_field_value, reclaim.odin), so the committed
// initial version has the SAME uniform ownership a tick-written column has — the
// precondition the live generational reclaimer rests on (a committed column is
// always a freeable owned tree, never a borrowed slice into the artifact bytes).
// The decode procs otherwise leave nested enum tags as sub-slices of the stored
// token; without this re-clone a despawn or rewrite of a startup row would bad-free
// those borrowed slices. The clone is value-identical, so committed bytes and the
// frame digest are unchanged. A non-column value (none expected from a decode)
// passes through unchanged.
own_committed_column :: proc(fv: Field_Value, allocator := context.allocator) -> Field_Value {
	if owned, ok := deep_clone_field_value(fv, allocator); ok {
		return owned
	}
	return fv
}

// run_startup_seeded runs an RNG-THREADED setup: it evaluates setup's BODY (the
// `setup(rng: Rng) -> (Rng, [Spawn])` startup function) with the tick-0 seed Rng
// bound, splits the returned `(Rng, [Spawn])` tuple, applies the [Spawn] half as
// the initial population, and RETAINS the advanced Rng as tick-0's starting state
// (§04 §1, §06 setup, §13). This is the seeded-population path snake takes: the
// first food cell is drawn from the seed, so a fixed seed reproduces the same
// initial world and the SAME tick-0 Rng — the determinism warranty starts at
// setup, not at tick 0. The returned Rng is what the first tick threads.
//
// A program with no setup BODY (pong — setup is the pre-evaluated [Spawn] batch in
// program.setup) is handled by the bare run_startup; this seeded path is only taken
// when the run carries an RNG seed and an interpretable setup body. When the body
// is missing or yields no tuple, it falls back to applying program.setup with the
// seed unadvanced, so a malformed/absent setup body never faults the run.
run_startup_seeded :: proc(
	program: ^Program,
	base: World_Version,
	seed: Rng,
	allocator := context.allocator,
) -> (
	populated: World_Version,
	advanced: Rng,
) {
	setup_fn := program_startup(program)
	if setup_fn == nil || len(setup_fn.body) == 0 {
		// No interpretable setup body — apply the pre-evaluated batch, seed unchanged.
		return run_startup(program, base, allocator), seed
	}

	// Evaluate the setup body against the populated-so-far tick tables, threading the
	// seed Rng. Setup binds only `rng: Rng` (its sole param), draws from it, and
	// returns `(Rng, [Spawn])`. The tuple split queues the spawns and advances the Rng.
	// Build the working state through new_tick_state so every field (incl. the
	// superseded list and the commit_allocator) is initialized — a bare struct
	// literal would leave commit_allocator nil and value_to_field_value would clone
	// the seeded spawn columns onto a nil allocator (corruption). Startup is a
	// single bounded fold, so eval and commit share one allocator (no live split).
	state := new_tick_state(base, allocator, allocator)
	state.rng = seed
	base_version := base
	interp := new_interp(program, &base_version, &state, empty(), Record_Value{}, allocator)

	env := Env{names = make(map[string]Value, allocator)}
	for param in setup_fn.params {
		if param.type == "Rng" {
			env.names[param.name] = state.rng
		}
	}
	result, result_ok := eval_behavior_body(&interp, setup_fn.body, &env)
	if !result_ok {
		// A setup body that does not return is malformed — fall back to the batch.
		return run_startup(program, base, allocator), seed
	}
	tuple, is_tuple := result.(Tuple_Value)
	if !is_tuple {
		// A body that returns anything but the `(Rng, [Spawn])` tuple is outside the
		// seeded contract — a seedless `setup() -> [Spawn]` (yard, pong) whose batch
		// the compiler already pre-evaluated into program.setup. Fall back to that
		// batch with the seed unadvanced rather than dropping the spawns and
		// committing an empty world.
		return run_startup(program, base, allocator), seed
	}
	// setup has no on-Thing self row; its return type (`(Rng, [Spawn])`) names the
	// halves so the split is type-driven, with no behavior context.
	fold_tuple_emit(&interp, &state, nil, Row{}, setup_fn.return_type, tuple)
	// Engine singletons mint BEFORE setup's seeded [Spawn] batch applies (§06 §2,
	// §13): the engine pass is the sole, authoritative minter of a singleton row and
	// a singleton exists before tick 0, so it runs first; setup's queued [Spawn]
	// batch then mints the ordinary seeded population on top. The spawn is a pure
	// function of the schema defaults, unaffected by the seed.
	spawn_engine_singletons(program, state.tables, allocator)
	apply_spawn_batch(&state)
	return commit_tick_tables(base, state.tables, allocator), state.rng
}

// program_startup finds the §06 setup function (the one Startup-kind §9 function),
// or nil — the body run_startup_seeded evaluates to draw the seeded initial
// population. A program with no startup body (pong) returns nil and the caller
// falls back to the pre-evaluated program.setup batch.
program_startup :: proc(program: ^Program) -> ^Function_Decl {
	for &fn in program.functions {
		if fn.kind == .Startup {
			return &fn
		}
	}
	return nil
}

// program_is_seeded reports whether the program's setup draws from a run seed:
// true only when the §06 setup function binds an `Rng` param (snake's
// `setup(rng: Rng) -> (Rng, [Spawn])`). A Startup function ALONE does not make a
// run seeded — a seedless `setup() -> [Spawn]` (yard, pong) is compile-time
// folded into program.setup and takes the bare run_startup batch — so the live
// seed pick (§25 §60) applies only to a program that actually consumes a seed.
program_is_seeded :: proc(program: ^Program) -> bool {
	setup_fn := program_startup(program)
	if setup_fn == nil {
		return false
	}
	for param in setup_fn.params {
		if param.type == "Rng" {
			return true
		}
	}
	return false
}

// build_spawn_blackboard evaluates one Spawn_Command into a complete row
// blackboard: every supplied setup field decoded to its column value, then every
// thing field the command omitted filled from its Field_Decl default. A Fixed
// numeric setup value reads as Fixed or Int by the field's declared type; a Vec2
// field becomes a Vec2 column; an enum variant becomes its stored token.
build_spawn_blackboard :: proc(
	program: ^Program,
	command: Spawn_Command,
	allocator := context.allocator,
) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, allocator)
	decl := program_thing(program, command.thing)

	for field in command.fields {
		fields[field.name] = own_committed_column(
			spawn_field_to_value(program, decl, field.name, field, allocator),
			allocator,
		)
	}
	// Fill omitted fields from the thing's declared defaults (§06, §13: an omitted
	// field is not carried in setup; the runtime applies the default).
	if decl != nil {
		for fd in decl.fields {
			if _, present := fields[fd.name]; present {
				continue
			}
			if fd.has_default {
				if v, ok := decode_default(program, fd, allocator); ok {
					fields[fd.name] = own_committed_column(v, allocator)
				}
			}
		}
	}
	return fields
}

// spawn_field_to_value lowers one decoded Spawn_Field to its blackboard column,
// reading the field's declared type so a numeric value lands as Int when the
// field is an Int column and as Fixed when it is a Fixed column (the loader keeps
// both views of the same raw bits). A Vec2/Variant field carries its decoded shape
// directly; a composite Record/List field decodes its kept raw §6 token LAZILY
// through decode_default_value against the field's declared type — the SAME machinery
// the §6 field-default path uses, so a setup `set body =Body(…)` and a field default
// `body: Body = Body(…)` lift to the IDENTICAL column shape (the cross-product
// contract the solver's gather reads). `allocator` owns the decoded structural column.
spawn_field_to_value :: proc(
	program: ^Program,
	decl: ^Thing_Decl,
	name: string,
	field: Spawn_Field,
	allocator := context.allocator,
) -> Field_Value {
	switch field.kind {
	case .Vec2:
		return Vec2{field.vec2_x, field.vec2_y}
	case .Variant:
		return field.variant
	case .Int:
		return field.int_val
	case .Fixed:
		// A numeric setup value: pick Int vs Fixed by the field's declared type.
		if field_is_int(decl, name) {
			return field.int_val
		}
		return field.fixed
	case .Record, .List:
		// A composite §6 token decoded against the field's declared type from the thing
		// decl. A decode miss (a malformed token the loader would have refused) leaves
		// the column unset by returning nil — never a half-built record.
		if v, ok := decode_default_value(
			program,
			thing_field_type(decl, name),
			field.encoded,
			allocator,
		); ok {
			return v
		}
		return nil
	}
	return field.fixed
}

// thing_field_type returns a thing's named field's declared type, or "" when the
// decl or field is unknown — the lookup spawn_field_to_value reads to decode a
// composite setup field against its declared type (a `body` field's `Body`, a `mask`
// field's `[Layer]`). The twin of data_field_type, over a Thing_Decl.
thing_field_type :: proc(decl: ^Thing_Decl, name: string) -> string {
	if decl == nil {
		return ""
	}
	for fd in decl.fields {
		if fd.name == name {
			return fd.type
		}
	}
	return ""
}

// decode_default decodes a Field_Decl's `=ENCODED` default into a column value,
// dispatching on the field's declared TYPE — the inverse of the emitter's
// field-default token (funpack emit.odin encode_field_default, docs/artifact-
// format.md §6). The forms, by declared type:
//
//   - Int          → `0`            → an i64 column (decode_int)
//   - Fixed        → raw Q32.32 bits → a Fixed column (decode_fixed)
//   - Bool         → `true`/`false` → a bool column
//   - `[T]`        → `[]`           → an empty List_Value column (snake's `body: [Cell]`)
//   - a data type  → `Type(f=enc,…)` → a Record_Value column (snake's `head: Cell`)
//   - an enum type → `Enum::Case`   → the enum token, verbatim (snake's `dir`/`state`)
//
// Pong's Scoreboard `Int = 0` pair still decodes through the Int arm. ok is false
// for an undecodable default (a malformed artifact the loader would have refused).
// `program` resolves a nested record field's declared type so a `Cell(x=10,y=10)`
// default decodes `x`/`y` as Int columns; `allocator` owns the structural column
// (the commit arena), independent of the transient default arena.
decode_default :: proc(
	program: ^Program,
	fd: Field_Decl,
	allocator := context.allocator,
) -> (
	value: Field_Value,
	ok: bool,
) {
	return decode_default_value(program, fd.type, fd.default_encoded, allocator)
}

// decode_default_value decodes one `=ENCODED` token against a declared type into a
// blackboard column. It is the recursive core decode_default and the record-field
// decoder both call: a nested `Cell(x=10,y=10)` field decodes its `x`/`y` through
// this same proc against the data-decl's field types, so the composite form nests
// to any depth the emitter produces.
decode_default_value :: proc(
	program: ^Program,
	type_name: string,
	encoded: string,
	allocator := context.allocator,
) -> (
	value: Field_Value,
	ok: bool,
) {
	switch type_name {
	case "Int":
		return decode_int(encoded)
	case "Fixed":
		return decode_fixed(encoded)
	case "Bool":
		return decode_bool(encoded)
	}
	// A `[T]` list value — the §6/§13 `[enc,…]` bracketed run (empty `[]` or a
	// comma-joined run of space-free element tokens, each decoded against the inner
	// element type `T`). The empty literal is the §6 default snake reaches; the
	// non-empty run is the §13 setup form yard reaches first (a `mask: [Layer] =
	// [Layer::Wall,Layer::Crate]`). The list is detected on EITHER the declared `[T]`
	// type OR the ENCODED leading `[` (§13: a reader discriminates on the leading byte
	// of ENCODED) — the latter is load-bearing for yard's Body, an ENGINE type with no
	// §3 Data_Decl, whose `mask` field type is unknown to data_field_type. Each element
	// lifts through field_value_to_value so a `[Layer]` column carries Variant_Values —
	// the shape the solver's mask read (value_to_layer_token) and the universal-Eq
	// surface expect.
	if strings.has_prefix(type_name, "[") || strings.has_prefix(encoded, "[") {
		return decode_list_default(program, type_name, encoded, allocator)
	}
	if strings.contains(encoded, "(") {
		// A composite record default `Type(f=enc,…)` — the §6 single-token inline
		// constructor (snake's `head: Cell = Cell(x=10,y=10)`, yard's `Body(kind=…,…)`).
		// This is tested BEFORE the enum-token arm because a composite body may itself
		// carry a nested enum token (yard's `Body(layer=Layer::Wall,…)`): the `::`
		// belongs to a nested field, not to a top-level `Enum::Case` default, and a
		// `Type::Case` enum token is always paren-free (§2.6), so `(` is the sound
		// discriminator for the composite form. A STRUCT-PAYLOAD variant
		// (`Shape2::Box(size=…)`) never reaches a top-level COLUMN (Field_Value carries
		// no Variant_Value arm — a struct variant lives only NESTED, as a record field
		// `Value`); it is decoded by decode_default_to_value off the record-field path.
		return decode_record_default(program, type_name, encoded, allocator)
	}
	if strings.contains(encoded, "::") {
		// An enum-variant default (`Enum::Case`) carries verbatim as a token column.
		return strings.clone(encoded, allocator), true
	}
	if encoded == "true" || encoded == "false" {
		// A bare boolean token whose declared type is not the literal `Bool` (a nested
		// field decoded against an unknown data decl — yard's `Body.sensor`, an ENGINE
		// record with no §3 Data_Decl). §13 discriminates on the ENCODED form, so a bare
		// `true`/`false` decodes to a Bool column regardless of declared type; without
		// this, `sensor=true` would fall to the bare-token arm and lift to a bogus
		// `Variant_Value{case_name="true"}` the solver's bool read rejects (the Pad would
		// never sense, no Trigger would route).
		return decode_bool(encoded)
	}
	if is_signed_decimal(encoded) {
		// A numeric default whose declared type is not the literal `Int`/`Fixed` (a
		// nested field decoded against an unknown data decl): decode as Fixed, the
		// numeric reading the loader's setup-field path also defaults to.
		return decode_fixed(encoded)
	}
	// A bare token with no `::` and no `(` — keep it as a token column so the field
	// stays loadable (the gate stage already proved defaults are concrete §6 forms).
	return strings.clone(encoded, allocator), true
}

// decode_record_default decodes a composite record default `Type(f=enc,g=enc,…)`
// into a Record_Value column — the inverse of the emitter's encode_record_default
// (funpack emit.odin). The body between the outer parens is split at TOP-LEVEL
// commas (so a nested `Vec2(x=0,y=0)` inside the body is not split mid-record),
// each `name=enc` pair decoded against that field's declared type from the data
// decl, so a `Cell(x=10,y=10)` decodes `x`/`y` as Int columns and a value lifts
// to the SAME Record_Value a runtime `Cell{…}` literal evaluates to. Each field
// decodes through decode_default_to_value (the Value-returning path), so a nested
// STRUCT-PAYLOAD variant field — yard's `Body(shape=Shape2::Box(size=…),…)` — lands
// as a Variant_Value the solver's parse_body_shape reads, not a flat Record_Value.
decode_record_default :: proc(
	program: ^Program,
	type_name: string,
	encoded: string,
	allocator := context.allocator,
) -> (
	value: Field_Value,
	ok: bool,
) {
	open := strings.index_byte(encoded, '(')
	if open < 0 || !strings.has_suffix(encoded, ")") {
		return nil, false
	}
	ctor := encoded[:open] // the constructor type name, e.g. "Cell"
	body := encoded[open + 1:len(encoded) - 1] // the interior "x=10,y=10"

	// Vec2/Vec3 are the built-in §10 vectors — a default collapses to a Vec2/Vec3
	// COLUMN (its x/y[/z] are Fixed components), the same shape a runtime `Vec2{…}` /
	// `Vec3{…}` literal evaluates to, not a by-name Record_Value. Neither has a §3
	// Data_Decl, so its components decode as Fixed. krognid's setup spawns
	// `pos =Vec3(x=…,y=…,z=…)` (the committed artifact's [setup] batch), so the Vec3
	// arm is the spawn-column decode that lands `pos` as a first-class Vec3 column —
	// the SAME collapse path yard's Vec2 pos column took (mirror, third-lane delta).
	vec2_fields := ctor == "Vec2"
	vec3_fields := ctor == "Vec3"
	decl := program_data(program, ctor)
	fields := make(map[string]Value, allocator)
	if len(body) > 0 {
		for pair in split_top_level(body, ',', allocator) {
			eq := strings.index_byte(pair, '=')
			if eq < 0 {
				return nil, false
			}
			name := pair[:eq]
			field_enc := pair[eq + 1:]
			field_type := (vec2_fields || vec3_fields) ? "Fixed" : data_field_type(decl, name)
			fv, fv_ok := decode_default_to_value(program, field_type, field_enc, allocator)
			if !fv_ok {
				return nil, false
			}
			fields[strings.clone(name, allocator)] = fv
		}
	}
	if vec2_fields {
		if v, vec_ok := record_to_vec2(fields); vec_ok {
			if vec, is_vec := v.(Vec2); is_vec {
				return vec, true
			}
		}
		return nil, false
	}
	if vec3_fields {
		if v, vec_ok := record_to_vec3(fields); vec_ok {
			if vec, is_vec := v.(Vec3); is_vec {
				return vec, true
			}
		}
		return nil, false
	}
	return Record_Value{type_name = strings.clone(ctor, allocator), fields = fields}, true
}

// decode_default_to_value decodes a `=ENCODED` token into a record-field / list-
// element Value (NOT a top-level Field_Value column). It is the value-path twin of
// decode_default_value, adding the one arm a column cannot carry: a STRUCT-PAYLOAD
// variant `Enum::Case(field=enc,…)` (yard's `Shape2::Box(size=…)`), which lives only
// NESTED inside a record (Field_Value has no Variant_Value arm — a top-level enum
// column is a string token). The discriminator is the ctor name (everything before
// the first `(`): a `::` in it means a struct-payload variant, decoded here; every
// other form defers to decode_default_value and lifts through field_value_to_value
// (which maps an enum-token string to a bare Variant_Value). So `Body(…)` records,
// `[Layer::…]` lists, scalars, and `Vec2(…)` collapses all route through the column
// path unchanged, and only the struct-variant case takes this proc's own arm.
decode_default_to_value :: proc(
	program: ^Program,
	type_name: string,
	encoded: string,
	allocator := context.allocator,
) -> (
	value: Value,
	ok: bool,
) {
	if open := strings.index_byte(encoded, '('); open > 0 {
		ctor := encoded[:open]
		if strings.contains(ctor, "::") && strings.has_suffix(encoded, ")") {
			return decode_struct_variant_value(program, encoded, allocator)
		}
	}
	fv, fv_ok := decode_default_value(program, type_name, encoded, allocator)
	if !fv_ok {
		return nil, false
	}
	return field_value_to_value(fv), true
}

// decode_struct_variant_value decodes a struct-payload variant token
// `Enum::Case(field=enc,…)` into a Variant_Value whose boxed payload is a
// Record_Value of the parenthesized fields — the inverse of the emitter's
// struct-variant token and the SAME shape eval produces for a `Shape2::Box{size}`
// literal (interp.odin eval_variant), which parse_body_shape reads off the committed
// `shape` column. The ctor name splits at `::` into the enum type and case; the body
// decodes field-by-field through decode_default_to_value (each payload field's type is
// unknown at this layer, so a `size=Vec2(…)` collapses via the record arm and a
// `radius=<bits>` decodes as Fixed via the numeric arm — the §11 §2 Shape2 payloads
// yard reaches). The payload Record_Value carries an empty type_name, matching the
// boxed-payload shape the solver's variant_payload_* readers expect.
decode_struct_variant_value :: proc(
	program: ^Program,
	encoded: string,
	allocator := context.allocator,
) -> (
	value: Value,
	ok: bool,
) {
	open := strings.index_byte(encoded, '(')
	if open < 0 || !strings.has_suffix(encoded, ")") {
		return nil, false
	}
	ctor := encoded[:open] // "Shape2::Box"
	sep := strings.index(ctor, "::")
	if sep < 0 {
		return nil, false
	}
	enum_type := strings.clone(ctor[:sep], allocator)
	case_name := strings.clone(ctor[sep + 2:], allocator)
	body := encoded[open + 1:len(encoded) - 1] // "size=Vec2(x=…,y=…)" / "radius=…"

	payload_fields := make(map[string]Value, allocator)
	if len(body) > 0 {
		for pair in split_top_level(body, ',', allocator) {
			eq := strings.index_byte(pair, '=')
			if eq < 0 {
				return nil, false
			}
			name := pair[:eq]
			pv, pv_ok := decode_default_to_value(program, "", pair[eq + 1:], allocator)
			if !pv_ok {
				return nil, false
			}
			payload_fields[strings.clone(name, allocator)] = pv
		}
	}
	boxed := new(Value, allocator)
	boxed^ = Record_Value{type_name = "", fields = payload_fields}
	return Variant_Value{enum_type = enum_type, case_name = case_name, payload = boxed}, true
}

// decode_list_default decodes a `[T]` list value `[enc,enc,…]` into a List_Value
// column — the inverse of the emitter's `[`-bracketed comma run (§6/§13). The inner
// element type `T` is the declared `[T]` type with the brackets stripped, so each
// element decodes by the SAME decode_default_value the record-field path uses (a
// `[Layer]` decodes each `Layer::X` element as an enum token lifting to a Variant_
// Value, a `[Cell]` would decode each `Cell(…)` element to a Record_Value). The
// elements split at TOP-LEVEL commas only (a nested `Cell(x=0,y=0)` element is not
// split mid-record), and each lifts through field_value_to_value so the list column
// carries Values — the shape the solver's mask read and the §03 universal-Eq surface
// expect. An empty `[]` yields a length-0 list, never a nil column.
decode_list_default :: proc(
	program: ^Program,
	type_name: string,
	encoded: string,
	allocator := context.allocator,
) -> (
	value: Field_Value,
	ok: bool,
) {
	if !strings.has_prefix(encoded, "[") || !strings.has_suffix(encoded, "]") {
		return nil, false
	}
	// The element type is the `[T]` declared type with its brackets stripped.
	elem_type := strings.trim_suffix(strings.trim_prefix(type_name, "["), "]")
	body := encoded[1:len(encoded) - 1] // the interior, "Layer::Wall,Layer::Crate"
	if len(body) == 0 {
		return List_Value{elements = make([]Value, 0, allocator)}, true
	}
	pieces := split_top_level(body, ',', allocator)
	elements := make([]Value, len(pieces), allocator)
	for piece, i in pieces {
		ev, ev_ok := decode_default_to_value(program, elem_type, piece, allocator)
		if !ev_ok {
			return nil, false
		}
		elements[i] = ev
	}
	return List_Value{elements = elements}, true
}

// split_top_level splits a record-body string at TOP-LEVEL `sep` bytes only —
// commas inside a nested `Type(…)` constructor OR a `[…]` list are skipped by
// tracking BOTH paren and bracket depth — so `x=10,y=10` splits into two pairs,
// `inner=Vec2(x=0,y=0),z=1` into two not three, and yard's
// `…,mask=[Layer::Wall,Layer::Crate],…` keeps the mask's interior comma joined (the
// list is one field, not two). The pieces are sub-slices of `s` (no per-piece
// allocation); the result slice lives in the supplied allocator.
split_top_level :: proc(s: string, sep: byte, allocator := context.allocator) -> []string {
	pieces := make([dynamic]string, allocator)
	depth := 0
	start := 0
	for i in 0 ..< len(s) {
		switch s[i] {
		case '(', '[':
			depth += 1
		case ')', ']':
			depth -= 1
		case:
			if s[i] == sep && depth == 0 {
				append(&pieces, s[start:i])
				start = i + 1
			}
		}
	}
	append(&pieces, s[start:])
	return pieces[:]
}

// program_data finds a §3 data descriptor by name, or nil — the field-type lookup
// decode_record_default reads to decode a composite default's nested fields by
// their declared type (Int vs Fixed vs Bool).
program_data :: proc(program: ^Program, name: string) -> ^Data_Decl {
	for &decl in program.data {
		if decl.name == name {
			return &decl
		}
	}
	return nil
}

// data_field_type returns a data decl's named field's declared type, or "" when
// the decl or field is unknown. An unknown field type falls through to the bare-
// token / numeric decode arms, so a record default stays loadable even without a
// matching data decl (e.g. the built-in Vec2, which has no §3 Data_Decl).
data_field_type :: proc(decl: ^Data_Decl, name: string) -> string {
	if decl == nil {
		return ""
	}
	for fd in decl.fields {
		if fd.name == name {
			return fd.type
		}
	}
	return ""
}

// field_is_int reports whether a thing's named field is declared Int (vs Fixed),
// so a numeric setup value lands on the right column type. An unknown field
// defaults to Fixed (the numeric reading the loader's Spawn_Field carries).
field_is_int :: proc(decl: ^Thing_Decl, name: string) -> bool {
	if decl == nil {
		return false
	}
	for fd in decl.fields {
		if fd.name == name {
			return fd.type == "Int"
		}
	}
	return false
}

// --- The per-tick fold ----------------------------------------------------

// step_tick folds one tick over the flattened pipeline against the prior
// committed version, returning the next committed version. A behavior reads the
// tick's WORKING tables (a mid-tick View/Ref sees earlier stages' SAME-TICK
// writes — evolving columns, §08 / §07 §4 — while the row set stays the one the
// tick fixed, since spawns/despawns land at the boundary) and the supplied
// input/time resources; their returns fold into working rows (blackboard), the
// signal mailbox (forward-routed signals), and the spawn/despawn batch (applied
// at the boundary). The next version commits with every table sorted ascending by
// Id.
//
// Rng threading (§04 §1): `rng` is the run's PERSISTENT Rng, carried in/out by
// pointer. When non-nil this fold is RNG-active — the tick seeds its working Rng
// from `rng^`, every drawing behavior advances it in fold-forward order, and the
// advanced state is written back into `rng^` at the boundary so the NEXT tick reads
// it. A nil `rng` (pong, hunt — no RNG) folds exactly as before, threading nothing.
//
// PERSIST-DROP INVARIANT (§24): this is the PLAIN driver — a pipeline that emits
// Save/Restore/ApplySettings accumulates them in state.persist_commands via the
// shared fold, and this proc DROPS them at commit: no store write, no outcome
// signal, no restore swap. A §24-emitting program must run through the opt-in
// step_tick_persist driver (save_io.odin); routing it here makes every persist
// key a silent no-op. The deliberate plain-path consumer is replay.odin's
// capture, whose record carries inputs only.
// Index maintenance (§08 §3): `indices` is the run's maintained engine-index
// state, carried in/out by pointer exactly as the Rng is. When non-nil, the
// fold runs against the structures as they stood at tick start (an update is
// never observable mid-stage — the tick reads the prior version's indices),
// and the declared structures fold forward at the COMMIT boundary, COW-sharing
// every table the tick never replaced (index.odin fold_index_state). A nil
// `indices` (a program declaring no query) folds exactly as before.
step_tick :: proc(
	program: ^Program,
	prior: World_Version,
	input: Input,
	time: Record_Value,
	allocator := context.allocator,
	rng: ^Rng = nil,
	indices: ^Index_State = nil,
	observe: ^Tick_Observe = nil,
) -> World_Version {
	// The plain (bounded) driver runs eval and commit on ONE allocator — the caller's
	// wholesale temp-free at the end reclaims everything, so there is no scratch/persist
	// split here (that split exists only in the live loop's step_tick_persist path).
	state := new_tick_state(prior, allocator, allocator)
	if rng != nil {
		state.rng = rng^
	}
	// The §28 observe tap rides the SAME fold every driver runs — set here, read at
	// the capture sites (behavior step / signal route), never written by the fold.
	state.observe = observe
	prior_version := prior
	interp := new_interp(program, &prior_version, &state, input, time, allocator)

	run_pipeline_fold(&interp, &state, program)

	apply_spawn_batch(&state)
	// Read the advanced Rng back into the run's persistent state so the next tick
	// observes every draw this tick made — threaded forward, never silently dropped.
	if rng != nil {
		rng^ = state.rng
	}
	next := commit_tick_state(prior, &state, allocator)
	// Fold the maintained indices forward at the commit boundary — once, after
	// every write landed, never mid-stage (§08 §3).
	if indices != nil {
		indices^ = fold_index_state(indices^, &prior_version, &next, allocator)
	}
	return next
}

// run_pipeline_fold runs the executed pipeline over the working state: every
// interior stage (control / collision / scoring) folds its behavior's returns into
// the tick state, the engine-closed `physics:` stage runs the native solver, and
// startup/render are skipped (startup ran pre-tick-0; render's [Draw] projection is
// a read-side concern, not a state write). It is the shared fold body step_tick and
// the §24 persist driver (step_tick_persist) both run, so a persist tick folds the
// IDENTICAL pipeline a plain tick does — the only difference is the driver's
// pre-seeded outcome signals and post-fold persist-command processing, never the
// fold itself.
run_pipeline_fold :: proc(interp: ^Interp, state: ^Tick_State, program: ^Program) {
	for step in program.pipeline {
		// Startup ran pre-tick-0; render's [Draw] projection and audio's [Audio]
		// keyed-track scene are TERMINAL projections produced post-commit (render.odin
		// / audio.odin), not interior writes — the executed interior stages are
		// control/collision/scoring. The level-triggered keyed Audio is the deferred
		// twin of the one-shot Sound: it is the audio: slot's return, never folded into
		// tick state here (§22 §2; the is_any_command_list exclusion the funpack side
		// keys on routes audio: to its own deferred slot).
		if step.stage == "startup" || step.stage == "render" || step.stage == "audio" {
			continue
		}
		// The §11 §3 `physics:` stage is ENGINE-CLOSED: instead of a user
		// Behavior_Decl, it runs the native `solve` battery over every body in stable
		// order (solver.odin). A collision writes BOTH bodies, which a behavior may
		// never do, so resolution is the engine's — `solve` integrates intent (written
		// by the control stage before this), detects/resolves contacts, routes Triggers
		// for sensor overlaps, and consumes each body's impulse. The detector is the
		// stage kind (`physics`), not a behavior lookup, since no Behavior_Decl is bound
		// to an engine-closed stage (artifact_load.odin load_pipeline keeps the
		// behavior name unresolved). Stage position is the ordering: intent before,
		// reactions after.
		if is_physics_solve_step(step) {
			run_solve(interp, state)
			continue
		}
		behavior := program_behavior(program, step.behavior)
		if behavior == nil {
			continue
		}
		run_behavior_over_instances(interp, state, step, behavior)
	}
}

// run_behavior_over_instances runs one behavior step once per instance of its
// on-Thing in stable Id order (§08 §2), folding each instance's return. A
// singleton or single-instance thing runs once; an empty table runs zero times
// (no instances, no work). The instances are read from the WORKING table so a
// later stage sees earlier stages' blackboard writes (forward fold within tick),
// but population is the count the prior version fixed (no spawn appears mid-tick).
run_behavior_over_instances :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	step: Pipeline_Step,
	behavior: ^Behavior_Decl,
) {
	table := find_tick_table(state.tables, behavior.on_thing)
	if table == nil {
		return
	}
	// Iterate by index over the working rows in stable Id order. The working rows
	// stay Id-ordered through the tick (built sorted, updated in place, never
	// reordered until commit), so index order IS stable Id order.
	for i in 0 ..< len(table.rows) {
		self_row := table.rows[i]
		env := bind_behavior_env(interp, state, step, behavior, self_row)
		result, ok := eval_behavior_body(interp, behavior.body, &env)
		// The §28 observe tap captures the step's (in → out) BEFORE the fold lands
		// the result: self_row.fields still aliases the pre-eval working map (a
		// blackboard write REPLACES the map, never mutates it), and the bound env
		// is the behavior's declared reads. A pure copy-out — the fold below is
		// unchanged whether the tap fired or not.
		if state.observe != nil {
			observe_behavior_step(state.observe, step, behavior, self_row, env, result, ok)
		}
		if !ok {
			continue
		}
		fold_behavior_result(interp, state, step, behavior, self_row, result)
	}
}

// bind_behavior_env binds a behavior step's declared params into a fresh scope:
// `self` is the instance's blackboard, an Input/Time param the resource, a
// [Signal] param the inbound signal list accumulated so far this tick, a View[T]
// param the tick's WORKING rows of T as a list (so a later stage's View sees
// earlier stages' same-tick writes, §08 / §07 §4), and a plain Thing param an
// other-instance read (unused by pong). The binding is by param TYPE so the step
// body reads its declared reads (§06 §3).
bind_behavior_env :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	step: Pipeline_Step,
	behavior: ^Behavior_Decl,
	self_row: Row,
) -> Env {
	env := Env{names = make(map[string]Value, interp.allocator)}
	for param in behavior.params {
		env.names[param.name] = bind_param(interp, state, param, self_row)
	}
	return env
}

// bind_param resolves one param's value from its declared type. `self` (the
// on-Thing type) is the instance blackboard as a record; Input/Time are the
// resources; a `[Signal]` type is the inbound accumulated signal list; a
// `View[T]` is the tick's WORKING T rows as a list of record values (evolving
// columns mid-tick, §08 / §07 §4); any other thing-typed param reads as an empty
// record (no other-instance binding pong needs). The match is on the type string
// the artifact carries (§06 §3).
bind_param :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	param: Param_Decl,
	self_row: Row,
) -> Value {
	type := param.type
	switch {
	case type == "Input":
		return input_marker(interp)
	case type == "Time":
		return interp.time
	case type == "Rng":
		// The threaded per-tick Rng: a drawing behavior binds `rng: Rng` to the
		// CURRENT fold-forward state, draws from it (pick advances it), and returns
		// the advanced Rng in its (Rng, [Spawn]) tuple — which fold_behavior_result
		// writes back into state.rng so the next behavior/tick reads the advance
		// (§04 §1). The value bound here is state.rng at this point in the fold.
		return state.rng
	case is_signal_list_type(type):
		return inbound_signal_list(interp, state, signal_type_of(type), self_row)
	case is_view_type(type):
		return view_rows_as_list(interp, view_thing_of(type))
	case param.name == "self":
		return row_to_record(interp, self_row)
	}
	// A plain thing-typed param with no instance to bind — an empty record (pong's
	// behaviors bind only self/resources/signals/Views).
	return row_to_record(interp, self_row)
}

// fold_behavior_result folds one instance's return into the tick state by the
// behavior's emit shape: a `[Signal]` emit routes the returned signal list
// forward into the mailbox (delivered to downstream consumers same-tick); a
// `[Draw]` emit is the render projection, which this fold does not commit; a
// Spawn/Despawn command list queues the tick-boundary batch; a bare-thing emit is
// a blackboard write folded into the instance's working row.
//
// A TUPLE emit (snake's replenish `(Rng, [Spawn])`, yard's deliver
// `([Despawn], [Delivered])`) is split into its components by the DECLARED tuple
// emit type, not by runtime value arm: deliver's two halves are both `List_Value`
// at runtime, so a value-arm split cannot tell the `[Despawn]` self-remove from the
// `[Delivered]` signal route — only the declared component type disambiguates them.
// Each component dispatches through dispatch_emit_component, the SAME per-shape fold
// the single-emit path takes.
fold_behavior_result :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	step: Pipeline_Step,
	behavior: ^Behavior_Decl,
	self_row: Row,
	result: Value,
) {
	emit := primary_emit(behavior)
	if tuple, is_tuple := result.(Tuple_Value); is_tuple {
		fold_tuple_emit(interp, state, behavior, self_row, emit, tuple)
		return
	}
	dispatch_emit_component(interp, state, behavior, self_row, emit, result)
}

// dispatch_emit_component folds ONE emit value (a whole single emit, or one
// component of a tuple emit) into the tick state by its DECLARED emit type. It is
// the per-shape fold both the single-emit path and each tuple component route
// through, so a `[Despawn]`/`[Delivered]`/`[Spawn]` half of a tuple lands in
// exactly the batch its standalone counterpart would. The Rng arm is value-driven
// (the declared `Rng` component carries no `[ ]`): a returned Rng writes the
// advance back into the threaded tick Rng (§04 §1, never silently dropped). A
// component with no behavior context (the startup setup tuple, behavior == nil)
// skips the blackboard write — startup emits only `Rng`/`[Spawn]`, never a
// self-row write.
dispatch_emit_component :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	behavior: ^Behavior_Decl,
	self_row: Row,
	emit: string,
	value: Value,
) {
	switch {
	case emit == "Rng":
		// The Rng half of a `(Rng, [Spawn])` tuple — write the advance back into the
		// threaded tick state so the next behavior's `rng: Rng` bind (and the next tick)
		// reads exactly this.
		if rng, is_rng := value.(Rng); is_rng {
			state.rng = rng
		}
	case is_signal_list_type(emit):
		route_signals(state, signal_type_of(emit), value)
	case emit == "[Draw]":
		// The render projection is not committed to the world — a Draw list is a
		// pure read-side projection of committed state, not a state write.
	case emit == "[Despawn]":
		// A `[Despawn]` emit despawns the SELF row when the returned list is non-empty
		// (snake's despawn_eaten, yard's deliver). The command targets self_row — the
		// no-arg `Despawn()` carries no Ref, so the tick fold (which knows the bound self
		// row) supplies the target. An empty list is the no-despawn path.
		if behavior != nil {
			fold_despawn_emit(state, behavior.on_thing, self_row, value)
		}
	case is_persist_command_list_type(emit):
		// A §24 persist command emit (yard's save_key/restore_key/apply_settings) —
		// collect it into the tick's persist batch. The IO runs at the tick boundary
		// (the persist driver), never as a committed-state write, so the determinism
		// record never sees it (team Lore #9). The outcome signal arrives NEXT tick.
		queue_persist_commands(interp, state, value)
	case is_command_list_type(emit):
		queue_commands(interp, state, value)
	case behavior != nil:
		// A blackboard write: fold the returned record into the working row.
		write_blackboard(interp, state, behavior.on_thing, self_row.id, value)
	}
}

// fold_despawn_emit queues a tick-boundary despawn of the SELF row when a
// `[Despawn]` behavior return is non-empty — the self-despawn the §02 `Despawn()`
// command marks. A despawn references the on-Thing type plus the self row's Id, so
// apply_spawn_batch removes exactly the bound instance at the boundary (population
// stays fixed for the rest of the tick, §08). An empty `[Despawn]` list is the
// no-op path (the food was not eaten this tick).
fold_despawn_emit :: proc(state: ^Tick_State, on_thing: string, self_row: Row, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list || len(list.elements) == 0 {
		return
	}
	queue_despawn(state, Ref{thing = on_thing, id = self_row.id})
}

// fold_tuple_emit splits a tuple behavior/setup return into its components by the
// DECLARED tuple emit type, zipping each component type with its returned element
// and folding each through dispatch_emit_component. The type-driven split is the
// load-bearing distinction: yard's deliver returns `([Despawn], [Delivered])` —
// two `List_Value` halves a runtime value-arm split cannot tell apart, so the
// `[Despawn]` would never self-remove and the `[Delivered]` would never route. The
// declared type names each half (`[Despawn]` → despawn batch, `[Delivered]` →
// signal mailbox, `Rng` → threaded Rng, `[Spawn]` → spawn batch), so each lands in
// exactly its standalone counterpart's path. When the declared type does not split
// into a tuple (an empty `emit_type`, the startup fallback), it falls back to the
// value-arm split so snake's `(Rng, [Spawn])` setup tuple still threads its Rng and
// queues its spawns.
fold_tuple_emit :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	behavior: ^Behavior_Decl,
	self_row: Row,
	emit_type: string,
	tuple: Tuple_Value,
) {
	component_types := split_tuple_type(emit_type, state.allocator)
	if len(component_types) == len(tuple.elements) {
		for elem, i in tuple.elements {
			dispatch_emit_component(interp, state, behavior, self_row, component_types[i], elem)
		}
		return
	}
	// No declared component types (or an arity mismatch) — fall back to the value-arm
	// split. snake's setup `(Rng, [Spawn])` is unambiguous by value (Rng vs the [Spawn]
	// list), so the Rng threads and the spawns queue without a declared type.
	for elem in tuple.elements {
		switch v in elem {
		case Rng:
			state.rng = v
		case List_Value:
			queue_commands(interp, state, elem)
		case i64, Fixed, bool, Vec2, Ref, Record_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Vec3, Transform_Value, Pose_Value, Handle_Value:
		// A half that is neither the Rng nor a command list is outside the value-arm
		// `(Rng, [Spawn])` shape — ignored, no state write.
		}
	}
}

// split_tuple_type splits a `(A,B,…)` tuple type string into its top-level
// component type names (`([Despawn],[Delivered])` → `["[Despawn]", "[Delivered]"]`,
// `(Rng,[Spawn])` → `["Rng", "[Spawn]"]`). A non-tuple type (no leading `(`) yields
// an empty slice, the signal the caller reads to fall back to the value-arm split.
// The split is at TOP-LEVEL commas only — a nested `[T]` or `(…)` component keeps
// its interior commas joined (reusing split_top_level's paren/bracket depth track),
// so a `(View[A,B],…)` component is one piece, not two. Each piece is space-trimmed,
// so a `(Rng, [Spawn])` written with a comma-space (the spaced form a spec/test
// declaration may carry) yields `"[Spawn]"`, not `" [Spawn]"` — the trimmed token
// the dispatch predicates match against.
split_tuple_type :: proc(type: string, allocator := context.allocator) -> []string {
	if len(type) < 2 || type[0] != '(' || type[len(type) - 1] != ')' {
		return nil
	}
	pieces := split_top_level(type[1:len(type) - 1], ',', allocator)
	for piece, i in pieces {
		pieces[i] = strings.trim_space(piece)
	}
	return pieces
}

// --- Signal routing (§12 forward synchronous) -----------------------------

// new_signal_mailbox builds an empty per-tick mailbox with both routing surfaces
// allocated (the broadcast by_type map and the per-instance by_instance map).
new_signal_mailbox :: proc(allocator := context.allocator) -> Signal_Mailbox {
	return Signal_Mailbox {
		by_type = make(map[string][]Value, allocator),
		by_instance = make(map[string]map[Id][]Value, allocator),
	}
}

// is_per_instance_signal reports whether a signal type is an engine PER-INSTANCE
// signal (§11 §4 Contact/Trigger) — routed by the engine to the specific
// participating instance and read by a consumer as ONLY its own. The two engine
// physics signals are the closed set; every user-declared signal is broadcast.
is_per_instance_signal :: proc(signal_type: string) -> bool {
	return signal_type == SOLVER_TRIGGER_SIGNAL || signal_type == "Contact"
}

// route_signals appends a behavior's emitted signal list to the mailbox's
// per-type BROADCAST accumulator — the forward delivery that makes a signal a
// later consumer reads hold every earlier producer's emissions this tick. The
// result is a List_Value of signal records; a non-list emit (the empty no-goal
// path returns an empty list) appends nothing.
route_signals :: proc(state: ^Tick_State, signal_type: string, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list || len(list.elements) == 0 {
		return
	}
	// §28 observe tap: capture the routed broadcast AFTER the empty-list filter, so
	// the capture records exactly the signals consumers will read this tick.
	if state.observe != nil {
		observe_broadcast_signals(state.observe, signal_type, list.elements)
	}
	existing := state.mailbox.by_type[signal_type]
	combined := make([]Value, len(existing) + len(list.elements), state.allocator)
	copy(combined, existing)
	copy(combined[len(existing):], list.elements)
	state.mailbox.by_type[signal_type] = combined
}

// route_instance_signal appends one engine PER-INSTANCE signal (§11 §4) to the
// mailbox keyed by type then by the TARGET row's Id, so the consumer instance
// reads ONLY its own. The solver calls this once per overlapping body of a sensor
// pair, with that body's Id — the engine doing the routing the spec says it does
// ("routed by the engine to each participating instance"), so the consumer needs
// no self.id filter.
route_instance_signal :: proc(state: ^Tick_State, signal_type: string, target: Id, signal: Value) {
	// §28 observe tap: capture the per-instance route with its target Id, so a
	// signals query sees the engine-routed Contact/Trigger deliveries too.
	if state.observe != nil {
		observe_instance_signal(state.observe, signal_type, target, signal)
	}
	per_type, has := state.mailbox.by_instance[signal_type]
	if !has {
		per_type = make(map[Id][]Value, state.allocator)
	}
	existing := per_type[target]
	combined := make([]Value, len(existing) + 1, state.allocator)
	copy(combined, existing)
	combined[len(existing)] = signal
	per_type[target] = combined
	state.mailbox.by_instance[signal_type] = per_type
}

// inbound_signal_list reads the signals accumulated for a type so far this tick
// as a List_Value param — what a consumer's `[Signal]` param sees. A BROADCAST
// signal reads the whole by_type accumulator (every producer's emissions, §12); a
// PER-INSTANCE engine signal reads only the entries routed to THIS instance's Id
// (§11 §4 — its own contacts/triggers, already in its frame). Because the fold is
// forward in pipeline order, either read holds exactly the earlier producers'
// emissions.
inbound_signal_list :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	signal_type: string,
	self_row: Row,
) -> Value {
	existing: []Value
	if is_per_instance_signal(signal_type) {
		if per_type, has := state.mailbox.by_instance[signal_type]; has {
			existing = per_type[self_row.id]
		}
	} else {
		existing = state.mailbox.by_type[signal_type]
	}
	elements := make([]Value, len(existing), interp.allocator)
	copy(elements, existing)
	return List_Value{elements = elements}
}

// --- Blackboard write -----------------------------------------------------

// write_blackboard folds a behavior's returned record into the instance's
// working row IN PLACE, so a later stage in the same tick reads the write. The
// returned record's fields lower to blackboard columns; a field that does not
// lower (a structural value) is skipped, leaving the prior column. The row is
// found by Id in the working table (stable Id order is preserved).
write_blackboard :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	thing: string,
	id: Id,
	result: Value,
) {
	record, is_record := result.(Record_Value)
	if !is_record {
		return
	}
	table := find_tick_table(state.tables, thing)
	if table == nil {
		return
	}
	for i in 0 ..< len(table.rows) {
		if table.rows[i].id != id {
			continue
		}
		// The fresh map AND its cloned columns target the PERSISTENT commit allocator
		// (not the eval scratch), so the committed row survives the per-tick scratch
		// reset in the live loop — the determinism floor is unchanged (same bytes,
		// different heap). In bounded paths commit_allocator == the eval allocator.
		next := make(map[string]Field_Value, state.commit_allocator)
		for k, v in record.fields {
			if fv, ok := value_to_field_value(v, state.commit_allocator); ok {
				next[k] = fv
			}
		}
		// The map this write REPLACES is no longer reachable from the next committed
		// version (the row now carries `next`): on the FIRST write of a row this tick
		// it is the PRIOR version's aliased map, on a later write it is this tick's
		// earlier intermediate map — both freeable once the tick commits. Collect it
		// for the live generational reclaimer (reclaim.odin); the bounded drivers
		// ignore the list. A nil map (a row with no prior blackboard) is skipped.
		if table.rows[i].fields != nil {
			append(&state.superseded, table.rows[i].fields)
		}
		table.rows[i].fields = next
		return
	}
}

// --- Spawn / Despawn batch (§07 §4 tick boundary) -------------------------

// queue_commands queues a behavior's Spawn/Despawn command list for the
// tick-boundary batch. A Spawn command carries a thing record to populate; a
// Despawn carries the Ref to remove. Pong's executed stages emit no commands
// (its only command-shaped emit is render's [Draw]), so this path is exercised by
// the spawn-batch test, not by the pong fold — it is the generic boundary the
// determinism criterion requires.
queue_commands :: proc(interp: ^Interp, state: ^Tick_State, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list {
		return
	}
	for elem in list.elements {
		record, is_record := elem.(Record_Value)
		if !is_record {
			continue
		}
		// A spawned row's blackboard becomes committed state next tick, so its map +
		// cloned columns target the PERSISTENT commit allocator, surviving the live
		// loop's per-tick scratch reset (commit_allocator == eval allocator in bounded
		// paths, so the committed bytes are identical there).
		fields := make(map[string]Field_Value, state.commit_allocator)
		for k, v in record.fields {
			if fv, ok := value_to_field_value(v, state.commit_allocator); ok {
				fields[k] = fv
			}
		}
		append(&state.spawns, Pending_Spawn{thing = record.type_name, fields = fields})
	}
}

// queue_persist_commands collects a behavior's §24 command list (the Save/Restore/
// ApplySettings records save_key/restore_key/apply_settings emit) into the tick's
// persist batch. Unlike queue_commands, it keeps the records AS Record_Values — the
// persist driver reads their `slot`/`settings` columns directly to run IO and never
// lowers them into a blackboard row (a persist command is an output effect, not a
// thing to commit). A non-record element (none expected) is skipped.
queue_persist_commands :: proc(interp: ^Interp, state: ^Tick_State, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list {
		return
	}
	for elem in list.elements {
		if record, is_record := elem.(Record_Value); is_record {
			append(&state.persist_commands, record)
		}
	}
}

// queue_spawn queues a directly-built spawn (a thing name + blackboard) for the
// tick-boundary batch — the seam a test or a future command-emitting behavior
// drives without routing through a [Draw]-shaped emit. The row is NOT visible
// until the batch applies, so a thing spawned this tick is first queryable next
// tick.
queue_spawn :: proc(state: ^Tick_State, thing: string, fields: map[string]Field_Value) {
	append(&state.spawns, Pending_Spawn{thing = thing, fields = fields})
}

// queue_despawn queues a Ref for removal at the tick boundary. The referenced row
// stays live for the rest of the current tick (population fixed within a tick)
// and is gone next tick.
queue_despawn :: proc(state: ^Tick_State, ref: Ref) {
	append(&state.despawns, ref)
}

// apply_spawn_batch applies the queued Spawn/Despawn commands as ONE
// deterministic batch at the tick boundary: every despawn removes its row, then
// every spawn mints a fresh Id and appends its row. Applying spawns AFTER
// despawns and in queue order makes the batch a pure function of the tick's
// command sequence. The new rows land at the end of the working table; the
// commit's sort restores ascending-Id order.
apply_spawn_batch :: proc(state: ^Tick_State) {
	for ref in state.despawns {
		table := find_tick_table(state.tables, ref.thing)
		if table == nil {
			continue
		}
		// A despawned row's blackboard map leaves the next committed version entirely,
		// so collect it for the live reclaimer the same way a rewritten map is
		// (reclaim.odin frees it O(delta) once the tick commits). remove_row_by_id
		// returns the dropped map (nil if the Id was already gone).
		if dropped, removed := remove_row_by_id(table, ref.id); removed && dropped != nil {
			append(&state.superseded, dropped)
		}
	}
	for spawn in state.spawns {
		table := find_tick_table(state.tables, spawn.thing)
		if table == nil {
			continue
		}
		id := Id{raw = table.next_id}
		table.next_id += 1
		append(&table.rows, Row{id = id, fields = spawn.fields})
	}
}

// remove_row_by_id drops the row carrying `id` from a working table, preserving
// the relative order of the rest (so the table stays Id-ordered without a
// re-sort). It returns the dropped row's blackboard map (and removed=true) so the
// caller can hand it to the live reclaimer — the despawned map leaves the next
// committed version, so it is freeable once the tick commits. A despawn of an
// absent Id is a no-op (already gone): removed=false, dropped=nil.
remove_row_by_id :: proc(table: ^Tick_Table, id: Id) -> (dropped: map[string]Field_Value, removed: bool) {
	for i in 0 ..< len(table.rows) {
		if table.rows[i].id == id {
			dropped = table.rows[i].fields
			ordered_remove(&table.rows, i)
			return dropped, true
		}
	}
	return nil, false
}

// --- Working-table lifecycle ----------------------------------------------

// new_tick_state builds the mutable working state for one tick from the prior
// committed version: a working table per declared thing seeded with the prior
// rows (copied so an in-place write never mutates the prior version), an empty
// signal mailbox, and empty spawn/despawn batches. `allocator` is the transient
// eval/working scratch; `commit_allocator` is the persistent allocator the
// committed blackboard maps/columns target — they are the SAME in every bounded
// path (only the live loop splits them so it can free the eval scratch each tick
// while the committed version persists). new_tick_tables seeds the working tables
// on the eval scratch; the prior rows it copies still carry their committed maps
// (on the persistent allocator), and commit_tick_tables re-packs the row structs
// onto the persistent allocator at the boundary — so a committed map is always on
// `commit_allocator`, never on the freed scratch.
new_tick_state :: proc(
	prior: World_Version,
	allocator := context.allocator,
	commit_allocator := context.allocator,
) -> Tick_State {
	return Tick_State {
		tables = new_tick_tables(prior, allocator),
		mailbox = new_signal_mailbox(allocator),
		spawns = make([dynamic]Pending_Spawn, allocator),
		despawns = make([dynamic]Ref, allocator),
		persist_commands = make([dynamic]Record_Value, allocator),
		superseded = make([dynamic]map[string]Field_Value, allocator),
		query_memo = make(map[string]Value, allocator),
		allocator = allocator,
		commit_allocator = commit_allocator,
	}
}

// new_tick_tables seeds one working table per committed table, copying the prior
// rows into a fresh dynamic array so the tick mutates a COPY and the prior
// version stays immutable (COW at the version level, in-place at the working
// level). The next_id counter carries forward so spawn Ids never collide with a
// prior tick's.
new_tick_tables :: proc(prior: World_Version, allocator := context.allocator) -> []Tick_Table {
	tables := make([]Tick_Table, len(prior.tables), allocator)
	for table, i in prior.tables {
		rows := make([dynamic]Row, allocator)
		for row in table.rows {
			append(&rows, row)
		}
		tables[i] = Tick_Table {
			thing     = table.thing,
			singleton = table.singleton,
			rows      = rows,
			next_id   = table.next_id,
		}
	}
	return tables
}

// commit_tick_state seals the tick into the next COW version: sort every working
// table's rows ascending by Id (the find_row_by_id / View iteration invariant),
// pack them into committed Version_Tables, and commit_version onto the prior. A
// table the tick did not touch still commits its (sorted-identical) rows — the
// version-level structural sharing is commit_version's job once the changed-set
// is supplied; here every table is supplied so the next version is fully
// materialized, which the determinism comparison reads as a stable snapshot.
commit_tick_state :: proc(
	prior: World_Version,
	state: ^Tick_State,
	allocator := context.allocator,
) -> World_Version {
	return commit_tick_tables(prior, state.tables, allocator)
}

// commit_tick_tables commits a set of working tables onto a prior version: each
// working table's rows are sorted ascending by Id, packed into a Version_Table,
// and supplied to commit_version as the changed set. Sorting here is what
// guarantees a committed table is ascending by Id even when the spawn batch
// appended rows out of order — the binary-search invariant holds for every
// committed version.
commit_tick_tables :: proc(
	prior: World_Version,
	tables: []Tick_Table,
	allocator := context.allocator,
) -> World_Version {
	changed := make(map[string]Version_Table, allocator)
	for &table in tables {
		rows := make([]Row, len(table.rows), allocator)
		copy(rows, table.rows[:])
		slice.sort_by(rows, proc(a, b: Row) -> bool {
			return a.id.raw < b.id.raw
		})
		changed[table.thing] = Version_Table {
			thing     = table.thing,
			singleton = table.singleton,
			rows      = rows,
			next_id   = table.next_id,
		}
	}
	version := commit_version(prior, changed, allocator)
	// The `changed` map is a TRANSIENT keyed view consumed by commit_version (it copies
	// the retained Version_Tables — including their committed `rows` slices — into the
	// result's tables slice); the map backing itself is dead now. Free it so the live
	// loop does not leak one keyed map per tick on the persistent commit allocator (the
	// retained rows/tables slices are reclaimed via free_version_structure when the
	// version retires; this map is not part of the version).
	delete(changed)
	return version
}

// find_tick_table returns the working table holding rows of the named thing, or
// nil — the descriptor-driven lookup the fold opens every per-instance run with.
find_tick_table :: proc(tables: []Tick_Table, thing: string) -> ^Tick_Table {
	for &table in tables {
		if table.thing == thing {
			return &table
		}
	}
	return nil
}

// --- Param-binding helpers -------------------------------------------------

// row_to_record lifts a committed/working Row's blackboard into the interpreter's
// Record_Value so a `self` param (or a View element) reads its fields. Each
// stored column lifts to its Value arm (an enum token becomes a Variant_Value),
// and the record carries the thing type so a `with` reconstructs it.
row_to_record :: proc(interp: ^Interp, row: Row) -> Value {
	fields := make(map[string]Value, interp.allocator)
	for k, v in row.fields {
		fields[k] = field_value_to_value(v)
	}
	return Record_Value{type_name = "", fields = fields}
}

// view_rows_as_list reads a thing's rows as a List_Value of record values — the
// binding for a `View[T]` param (paddle_bounce's `paddles: View[Paddle]`). The
// rows come from the tick's WORKING table when a fold is in flight, so a later
// stage's View observes every earlier stage's SAME-TICK blackboard writes
// (evolving columns, §08 / §07 §4); off a fold it falls back to the committed
// version. Either way the rows are in stable Id order (the working set is
// materialized Id-ordered at tick start and only columns evolve mid-tick;
// spawns/despawns land at the boundary, so population stays fixed), so first/fold
// over the view are deterministic.
view_rows_as_list :: proc(interp: ^Interp, thing: string) -> Value {
	view := interp_view_of_type(interp, thing)
	elements := make([]Value, view_count(view), interp.allocator)
	for i in 0 ..< view_count(view) {
		row, _ := view_at(view, i)
		elements[i] = row_to_record(interp, row)
	}
	return List_Value{elements = elements}
}

// interp_view_of_type opens a View over a thing's rows for a mid-tick read: the
// tick's WORKING rows when a fold is in flight (so a later stage sees earlier
// stages' SAME-TICK writes — evolving columns, §08 / §07 §4), else the committed
// version (off a fold). The working rows stay ascending by Id through the tick
// (built sorted at tick start, updated in place, never reordered until commit),
// so the View iterates and resolves in the same stable Id order a committed View
// does — population fixity preserved because spawns/despawns land at the boundary.
interp_view_of_type :: proc(interp: ^Interp, thing: string) -> View {
	if interp.tick != nil {
		if table := find_tick_table(interp.tick.tables, thing); table != nil {
			return View{thing = thing, rows = table.rows[:]}
		}
	}
	return view_of_type(interp.version, thing)
}

// interp_resolve_ref resolves a Ref against the tick's WORKING rows when a fold
// is in flight — a mid-tick `recv.ref_field.column` join reads the referent's
// SAME-TICK writes (evolving columns, §08 / §07 §4) over its tick-start value;
// off a fold it resolves against the committed version. The working rows are
// Id-ascending, so the binary search find_row_by_id rests on holds.
interp_resolve_ref :: proc(interp: ^Interp, ref: Ref) -> (row: Row, some: bool) {
	if interp.tick != nil {
		if table := find_tick_table(interp.tick.tables, ref.thing); table != nil {
			idx, found := find_row_by_id(table.rows[:], ref.id)
			if !found {
				return {}, false
			}
			return table.rows[idx], true
		}
	}
	return resolve_ref(interp.version, ref)
}

// input_marker returns the value a behavior's `input` param binds to. The Input
// snapshot is read through the resource queries (eval_input_value reads
// interp.input directly), so the param itself only needs to BE the receiver a
// `input.value(...)` call dispatches on; an empty record marks it as that
// receiver without widening the Value union with an Input arm.
input_marker :: proc(interp: ^Interp) -> Value {
	fields := make(map[string]Value, interp.allocator)
	return Record_Value{type_name = "Input", fields = fields}
}

// is_physics_solve_step reports whether a pipeline step is the §11 §3 engine-
// closed `physics:` stage running the native `solve` battery — a real pipeline
// position with NO user Behavior_Decl. The detector is the (stage, behavior) pair
// the artifact carries: the `physics:` stage's single member is the `solve`
// battery (yard's `physics: solve`), so the step's stage is "physics" and its
// behavior name is "solve". This is the one stage the fold dispatches to the
// native solver instead of running a user behavior body.
is_physics_solve_step :: proc(step: Pipeline_Step) -> bool {
	return step.stage == "physics" && step.behavior == "solve"
}

// --- Type-string predicates (§06 §3 param/emit type forms) ----------------

// is_signal_list_type reports whether a param/emit type is a `[Signal]` list of a
// declared signal — the shape a producer emits and a consumer reads. The three
// engine command/render lists `[Draw]`, `[Spawn]`, and `[Despawn]` are NOT signal
// lists, so they are excluded here and routed by their own predicates (a `[Draw]`
// projection, a `[Spawn]` mint, a `[Despawn]` self-remove) — otherwise a
// `[Despawn]` emit would mis-route into the signal mailbox instead of the despawn
// batch.
is_signal_list_type :: proc(type: string) -> bool {
	if !is_bracket_list(type) {
		return false
	}
	if is_persist_command_list_type(type) {
		// `[Save]`/`[Restore]`/`[ApplySettings]` are §24 OUTPUT-EFFECT command lists, not
		// signals — they route to the persist batch, not the mailbox. Excluded here so a
		// persist emit is never mis-delivered as a forward signal (the same disjointness
		// Draw/Spawn/Despawn below get).
		return false
	}
	inner := signal_type_of(type)
	return inner != "Draw" && inner != "Spawn" && inner != "Despawn"
}

// is_command_list_type reports whether an emit type is a `[Spawn]` command list —
// the tick-boundary mint batch. (`[Draw]` is the render projection and `[Despawn]`
// the self-remove batch, each handled by its own arm in fold_behavior_result.)
is_command_list_type :: proc(type: string) -> bool {
	return type == "[Spawn]"
}

// is_persist_command_list_type reports whether an emit type is one of the §24
// engine.save command lists `[Save]` / `[Restore]` / `[ApplySettings]`. These are
// NOT sim state and NOT the spawn batch: they are OUTPUT EFFECTS the persist driver
// runs against the store (save_io.odin), each returning its outcome signal one tick
// LATER. A persist command emit collects into the tick's persist_commands batch
// rather than the spawn batch or the signal mailbox, so the IO boundary stays off
// the determinism record (it never touches a committed table; team Lore #9).
is_persist_command_list_type :: proc(type: string) -> bool {
	return type == "[Save]" || type == "[Restore]" || type == "[ApplySettings]"
}

// is_view_type reports whether a param type is a `View[T]` read — the stable-Id
// iterable of another thing's instances a behavior reads.
is_view_type :: proc(type: string) -> bool {
	return len(type) > 6 && type[:5] == "View[" && type[len(type) - 1] == ']'
}

// is_bracket_list reports whether a type is the `[X]` list form.
is_bracket_list :: proc(type: string) -> bool {
	return len(type) >= 3 && type[0] == '[' && type[len(type) - 1] == ']'
}

// signal_type_of strips the `[ ]` from a `[Signal]` list type, yielding the inner
// signal/element type name.
signal_type_of :: proc(type: string) -> string {
	if is_bracket_list(type) {
		return type[1:len(type) - 1]
	}
	return type
}

// view_thing_of strips the `View[ ]` wrapper from a `View[T]` type, yielding the
// inner thing-type name a View ranges over.
view_thing_of :: proc(type: string) -> string {
	if is_view_type(type) {
		return type[5:len(type) - 1]
	}
	return type
}

// primary_emit returns a behavior's first emit type — the return shape its step
// body produces (§06 §3: a behavior step returns exactly its declared emit). A
// behavior with no declared emit returns "" (a no-write step).
primary_emit :: proc(behavior: ^Behavior_Decl) -> string {
	if len(behavior.emits) == 0 {
		return ""
	}
	return behavior.emits[0]
}

// program_thing finds a §8 thing descriptor by name, or nil — the field-type and
// default lookups the spawn blackboard build reads.
program_thing :: proc(program: ^Program, name: string) -> ^Thing_Decl {
	for &thing in program.things {
		if thing.name == name {
			return &thing
		}
	}
	return nil
}

// program_behavior finds a §10 behavior descriptor by name, or nil — the
// pipeline step → behavior body lookup the fold opens each step with.
program_behavior :: proc(program: ^Program, name: string) -> ^Behavior_Decl {
	for &behavior in program.behaviors {
		if behavior.name == name {
			return &behavior
		}
	}
	return nil
}
