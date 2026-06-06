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

// Signal_Mailbox accumulates the signals emitted SO FAR this tick, keyed by
// signal type. A consumer stage reads its inbound list from here when it runs;
// because the fold is forward in pipeline order, a list a consumer reads holds
// exactly the signals every earlier producer emitted this tick (synchronous
// forward delivery, no concurrency). It is reset each tick.
Signal_Mailbox :: struct {
	by_type: map[string][]Value, // signal type name → emitted signal records this tick
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
	tables:    []Tick_Table,
	mailbox:   Signal_Mailbox,
	spawns:    [dynamic]Pending_Spawn,
	despawns:  [dynamic]Ref,
	rng:       Rng, // the per-tick PRNG state a draw advances, threaded fold-forward
	allocator: Runtime_Allocator,
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
			fields[fd.name] = v
		}
	}
	return fields
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
	tables := new_tick_tables(base, allocator)
	state := Tick_State {
		tables    = tables,
		mailbox   = Signal_Mailbox{by_type = make(map[string][]Value, allocator)},
		spawns    = make([dynamic]Pending_Spawn, allocator),
		despawns  = make([dynamic]Ref, allocator),
		rng       = seed,
		allocator = allocator,
	}
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
	if tuple, is_tuple := result.(Tuple_Value); is_tuple {
		fold_tuple_emit(&interp, &state, tuple)
	}
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
		fields[field.name] = spawn_field_to_value(program, decl, field.name, field)
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
					fields[fd.name] = v
				}
			}
		}
	}
	return fields
}

// spawn_field_to_value lowers one decoded Spawn_Field to its blackboard column,
// reading the field's declared type so a numeric value lands as Int when the
// field is an Int column and as Fixed when it is a Fixed column (the loader keeps
// both views of the same raw bits). A Vec2/Variant field carries its decoded
// shape directly.
spawn_field_to_value :: proc(
	program: ^Program,
	decl: ^Thing_Decl,
	name: string,
	field: Spawn_Field,
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
	}
	return field.fixed
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
	if strings.has_prefix(type_name, "[") {
		// A `[T]` list default — the emitter admits only the empty-list `[]` literal.
		if encoded == "[]" {
			return List_Value{elements = make([]Value, 0, allocator)}, true
		}
		return nil, false
	}
	if strings.contains(encoded, "(") {
		// A composite record default `Type(f=enc,…)` — the §6 single-token inline
		// constructor (snake's `head: Cell = Cell(x=10,y=10)`). This is tested
		// BEFORE the enum-token arm because a composite body may itself carry a
		// nested enum token (yard's `Body(layer=CollisionLayer::Solid,…)`): the `::`
		// belongs to a nested field, not to a top-level `Enum::Case` default, and a
		// `Type::Case` enum token is always paren-free (§2.6), so `(` is the sound
		// discriminator for the composite form.
		return decode_record_default(program, type_name, encoded, allocator)
	}
	if strings.contains(encoded, "::") {
		// An enum-variant default (`Enum::Case`) carries verbatim as a token column.
		return strings.clone(encoded, allocator), true
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
// to the SAME Record_Value a runtime `Cell{…}` literal evaluates to. The fields
// are lifted to interpreter Values so the record column round-trips through
// field_value_to_value unchanged.
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

	// Vec2 is the built-in §10 vector — its default collapses to a Vec2 column
	// (its x/y are Fixed components), the same shape a runtime `Vec2{…}` literal
	// evaluates to, not a by-name Record_Value. It has no §3 Data_Decl, so its
	// components decode as Fixed.
	vec2_fields := ctor == "Vec2"
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
			field_type := vec2_fields ? "Fixed" : data_field_type(decl, name)
			fv, fv_ok := decode_default_value(program, field_type, field_enc, allocator)
			if !fv_ok {
				return nil, false
			}
			fields[strings.clone(name, allocator)] = field_value_to_value(fv)
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
	return Record_Value{type_name = strings.clone(ctor, allocator), fields = fields}, true
}

// split_top_level splits a record-body string at TOP-LEVEL `sep` bytes only —
// commas inside a nested `Type(…)` constructor are skipped by tracking paren depth
// — so `x=10,y=10` splits into two pairs while `inner=Vec2(x=0,y=0),z=1` splits
// into two, not three. The pieces are sub-slices of `s` (no per-piece allocation);
// the result slice lives in the supplied allocator.
split_top_level :: proc(s: string, sep: byte, allocator := context.allocator) -> []string {
	pieces := make([dynamic]string, allocator)
	depth := 0
	start := 0
	for i in 0 ..< len(s) {
		switch s[i] {
		case '(':
			depth += 1
		case ')':
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
step_tick :: proc(
	program: ^Program,
	prior: World_Version,
	input: Input,
	time: Record_Value,
	allocator := context.allocator,
	rng: ^Rng = nil,
) -> World_Version {
	state := new_tick_state(prior, allocator)
	if rng != nil {
		state.rng = rng^
	}
	prior_version := prior
	interp := new_interp(program, &prior_version, &state, input, time, allocator)

	for step in program.pipeline {
		// Startup ran pre-tick-0; render's [Draw] projection is not produced by this
		// fold — the executed interior stages are control/collision/scoring.
		if step.stage == "startup" || step.stage == "render" {
			continue
		}
		behavior := program_behavior(program, step.behavior)
		if behavior == nil {
			continue
		}
		run_behavior_over_instances(&interp, &state, step, behavior)
	}

	apply_spawn_batch(&state)
	// Read the advanced Rng back into the run's persistent state so the next tick
	// observes every draw this tick made — threaded forward, never silently dropped.
	if rng != nil {
		rng^ = state.rng
	}
	return commit_tick_state(prior, &state, allocator)
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
		return inbound_signal_list(interp, state, signal_type_of(type))
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
// A `(Rng, [Spawn])` tuple emit (snake's replenish) is split here: the Rng half
// writes the ADVANCED Rng back into the threaded tick Rng (so the next behavior /
// tick observes the advance — §04 §1, never silently dropped), and the [Spawn]
// half queues the spawn batch through the existing command path. The returned value
// being a Tuple_Value is the tuple emit's signature, so the split is driven off the
// runtime shape; each half is located by its arm (the Rng arm vs the command list),
// which is unambiguous since the two halves are distinct value arms.
fold_behavior_result :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	step: Pipeline_Step,
	behavior: ^Behavior_Decl,
	self_row: Row,
	result: Value,
) {
	if tuple, is_tuple := result.(Tuple_Value); is_tuple {
		fold_tuple_emit(interp, state, tuple)
		return
	}
	emit := primary_emit(behavior)
	switch {
	case is_signal_list_type(emit):
		route_signals(state, signal_type_of(emit), result)
	case emit == "[Draw]":
		// The render projection is not committed to the world — a Draw list is a
		// pure read-side projection of committed state, not a state write.
	case emit == "[Despawn]":
		// A `[Despawn]` emit despawns the SELF row when the returned list is non-empty
		// (snake's despawn_eaten emits `[Despawn()]` to remove the eaten Food). The
		// command targets self_row — the no-arg `Despawn()` carries no Ref, so the tick
		// fold (which knows the bound self row) supplies the target. An empty list is
		// the no-despawn path (no command queued).
		fold_despawn_emit(state, behavior.on_thing, self_row, result)
	case is_command_list_type(emit):
		queue_commands(interp, state, result)
	case:
		// A blackboard write: fold the returned record into the working row.
		write_blackboard(interp, state, behavior.on_thing, self_row.id, result)
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

// fold_tuple_emit splits a `(Rng, [Spawn])` behavior return into its halves: the
// Rng element is written back into the threaded tick Rng so the advance carries
// FORWARD to the next behavior/tick (§04 §1 — the draw's next_rng IS what the next
// draw observes, in fold-forward order), and the `[Spawn]` element queues the
// spawn batch through queue_commands (the same tick-boundary path a bare command
// emit uses). The Rng half is located by its arm rather than its position, so the
// split is total over any `(Rng, [Spawn])` / `([Spawn], Rng)` ordering — there is
// no path that consumes a draw without writing its advanced Rng back.
fold_tuple_emit :: proc(interp: ^Interp, state: ^Tick_State, tuple: Tuple_Value) {
	for elem in tuple.elements {
		switch v in elem {
		case Rng:
			// Write the advanced Rng back into the threaded tick state — the next
			// behavior's `rng: Rng` bind (and the next tick) reads exactly this.
			state.rng = v
		case List_Value:
			// The [Spawn] half — queue the spawn batch for the tick boundary.
			queue_commands(interp, state, elem)
		case i64, Fixed, bool, Vec2, Ref, Record_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value:
			// A tuple half that is neither the Rng nor the command list is outside the
			// `(Rng, [Spawn])` shape this fold splits — ignored, no state write.
		}
	}
}

// --- Signal routing (§12 forward synchronous) -----------------------------

// route_signals appends a behavior's emitted signal list to the mailbox's
// per-type accumulator — the forward delivery that makes a signal a later
// consumer reads hold every earlier producer's emissions this tick. The result
// is a List_Value of signal records; a non-list emit (the empty no-goal path
// returns an empty list) appends nothing.
route_signals :: proc(state: ^Tick_State, signal_type: string, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list || len(list.elements) == 0 {
		return
	}
	existing := state.mailbox.by_type[signal_type]
	combined := make([]Value, len(existing) + len(list.elements), state.allocator)
	copy(combined, existing)
	copy(combined[len(existing):], list.elements)
	state.mailbox.by_type[signal_type] = combined
}

// inbound_signal_list reads the signals accumulated for a type so far this tick
// as a List_Value param — what a consumer's `[Signal]` param sees. Because the
// fold is forward in pipeline order, this holds exactly the earlier producers'
// emissions (synchronous forward routing, §12).
inbound_signal_list :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	signal_type: string,
) -> Value {
	existing := state.mailbox.by_type[signal_type]
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
		next := make(map[string]Field_Value, interp.allocator)
		for k, v in record.fields {
			if fv, ok := value_to_field_value(v, interp.allocator); ok {
				next[k] = fv
			}
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
		fields := make(map[string]Field_Value, interp.allocator)
		for k, v in record.fields {
			if fv, ok := value_to_field_value(v, interp.allocator); ok {
				fields[k] = fv
			}
		}
		append(&state.spawns, Pending_Spawn{thing = record.type_name, fields = fields})
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
		remove_row_by_id(table, ref.id)
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
// re-sort). A despawn of an absent Id is a no-op (already gone).
remove_row_by_id :: proc(table: ^Tick_Table, id: Id) {
	for i in 0 ..< len(table.rows) {
		if table.rows[i].id == id {
			ordered_remove(&table.rows, i)
			return
		}
	}
}

// --- Working-table lifecycle ----------------------------------------------

// new_tick_state builds the mutable working state for one tick from the prior
// committed version: a working table per declared thing seeded with the prior
// rows (copied so an in-place write never mutates the prior version), an empty
// signal mailbox, and empty spawn/despawn batches.
new_tick_state :: proc(prior: World_Version, allocator := context.allocator) -> Tick_State {
	return Tick_State {
		tables = new_tick_tables(prior, allocator),
		mailbox = Signal_Mailbox{by_type = make(map[string][]Value, allocator)},
		spawns = make([dynamic]Pending_Spawn, allocator),
		despawns = make([dynamic]Ref, allocator),
		allocator = allocator,
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
	return commit_version(prior, changed, allocator)
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
	inner := signal_type_of(type)
	return inner != "Draw" && inner != "Spawn" && inner != "Despawn"
}

// is_command_list_type reports whether an emit type is a `[Spawn]` command list —
// the tick-boundary mint batch. (`[Draw]` is the render projection and `[Despawn]`
// the self-remove batch, each handled by its own arm in fold_behavior_result.)
is_command_list_type :: proc(type: string) -> bool {
	return type == "[Spawn]"
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
