// The §08 world-as-database READ surface: the world already IS a deterministic,
// versioned, in-memory database, and this file is its read / reference / query
// layer. It wraps the empty thing tables from the loader substrate
// (program.odin) and exposes the four read primitives §08 names: a stable Id
// from the deterministic spawn counter, the View[T] read-only table iterated in
// stable Id order, the Ref[T] weak typed handle that resolves to an Option, and
// the COW-committed tick version with structural sharing (one committed tick is
// one cheap MVCC version).
//
// CQRS by construction (§08 §1): this is the READ side only. Every proc here is
// a pure, read-only function of a committed version — it never mutates, never
// applies a spawn/despawn, and never runs setup. The write side (a behavior
// writing its own blackboard, the deterministic spawn/despawn batch at the tick
// boundary, the setup [Spawn]) is the tick transaction's contract, not this
// file's. A query cannot mutate, so it can never reintroduce the aliasing the
// flat id-graph rules out.
//
// DESCRIPTOR-DRIVEN, NOT ODIN-GENERIC: a thing type is artifact DATA (a
// Thing_Decl), not an Odin type, so the spec's View[T] / Ref[T] cannot be Odin
// parametric polymorphism over a compile-time T. The phantom type parameter is
// modeled at runtime by the thing-type identity a View and a Ref carry, and a
// row's blackboard is a by-name field map of runtime Field_Values rather than a
// statically-typed struct. The surface (count / at / ref / resolve / View.of)
// matches §08 §2 exactly; T is a runtime descriptor, not a type argument.
package funpack_runtime

// --- Id and the row blackboard -------------------------------------------

// Id is the §08 §1 stable identity from the deterministic spawn counter:
// `data Id { raw: Int }`. ENGINE-INTERNAL — the raw identity a Ref wraps and
// the type-erased target of Despawn; user code never authors a bare Id. It is
// the existing per-table Thing_Id widened to the engine identity the state
// layer reasons about, so View iteration order and Ref resolution key on one
// stable value.
Id :: struct {
	raw: Thing_Id,
}

// Field_Value is one column of a row's blackboard: the runtime value a field
// holds, type-erased to a closed variant because the field's static type lives
// in the Thing_Decl descriptor, not in the Odin type system. The variants mirror
// the loader's decoded Spawn_Value_Kind (Int / Fixed / Variant / Vec2) plus the
// Ref the read side resolves — every concrete value pong's blackboard carries.
// No float ever (spec §10): a numeric column is a Fixed or an Int over the
// kernel's raw bits.
Field_Value :: union {
	i64, // an Int column
	Fixed, // a Fixed column (Q32.32 bits)
	string, // an enum variant token, e.g. "Side::Left"
	Vec2, // a two-Fixed vector column (§10 Num kind)
	Ref, // a weak typed handle to another row (§08 §1)
}

// Row is one thing instance — a database row keyed by Id (§08 table). The whole
// blackboard travels together as one document (§08: not column-shredded, NOT
// ECS), so a Row carries its Id and the by-name field map that is its
// blackboard. The map is keyed by field name because a thing type's schema is
// descriptor data; field access is by name, the descriptor-driven stand-in for
// struct field access.
Row :: struct {
	id:     Id,
	fields: map[string]Field_Value,
}

// --- Ref: the weak, typed reference (§08 §1) -----------------------------

// Ref is the weak, typed, serializable handle §08 §1 makes the only reference
// user code authors — a phantom-typed Id. The phantom type T is carried at
// runtime as the target thing-type name, since a thing type is descriptor data,
// not an Odin type. It resolves through a committed version to an Option (Some
// on a live row, None on a despawned or absent one), so totality FORCES the
// dangling case and a use-after-despawn is unrepresentable (§08 §1: referential
// integrity by construction). A flat id-graph, not a pointer-graph: a Ref is two
// plain values, so the whole world serializes trivially.
Ref :: struct {
	thing: string, // the target thing-type name (the phantom T, descriptor-driven)
	id:    Id, // the stable identity the handle points at
}

// --- COW-committed tick versions (§08 §4) --------------------------------

// Version_Table is one thing type's committed rows at a version: the descriptor
// the table holds rows of, its rows in stable Id order, and the next Id the
// spawn counter would mint. Rows are stored in a slice kept sorted by Id so a
// View iterates in stable Id order without re-sorting on every read (§08 §2).
// It is the committed counterpart of the loader's empty Thing_Table.
Version_Table :: struct {
	thing:     string, // the Thing_Decl.name this table holds rows of
	singleton: bool, // a singleton is the row-count-1 constraint (§08 §3, §06 §2)
	rows:      []Row, // committed rows, ascending by Id (the stable iteration order)
	next_id:   Thing_Id, // the next Id the deterministic spawn counter would mint
}

// World_Version is one committed tick: a COW snapshot of every thing table
// (§08 §4 — each committed tick is a COW version with structural sharing, so a
// version is cheap and the database is natively time-indexed). The tables slice
// is the version's immutable view of the world; committing a next tick that
// touches only some tables SHARES the untouched ones by reference (structural
// sharing), so an unchanged table is never copied. A version is read-only: every
// read primitive below is a pure function of one World_Version.
World_Version :: struct {
	tick:   int, // the committed tick ordinal — the MVCC version number
	tables: []Version_Table,
}

// initial_version builds the empty committed version (tick -1, before setup) from
// the loader's empty World: one empty Version_Table per declared thing, in
// declaration order, with no rows and next_id 0. This is the COW base the tick
// transaction commits the first populated version on top of; the read layer can
// already query it (every View is empty, every Ref resolves None). The state
// layer OWNS no spawning — it only lifts the loader substrate into the versioned
// read model.
initial_version :: proc(world: World, allocator := context.allocator) -> World_Version {
	tables := make([]Version_Table, len(world.tables), allocator)
	for table, i in world.tables {
		tables[i] = Version_Table {
			thing     = table.thing,
			singleton = table.singleton,
			rows      = nil,
			next_id   = table.next_id,
		}
	}
	return World_Version{tick = -1, tables = tables}
}

// commit_version produces the next COW tick version with STRUCTURAL SHARING: the
// caller supplies only the tables that changed (keyed by thing name); every
// table not in `changed` is shared from the prior version BY REFERENCE, never
// copied (§08 §4). The result is a new immutable version at tick prior.tick+1.
// This is the COW commit primitive the tick transaction drives to seal each
// tick; the read layer needs it to produce committed populated versions to read
// (the read side reads versions, the write side commits them).
commit_version :: proc(
	prior: World_Version,
	changed: map[string]Version_Table,
	allocator := context.allocator,
) -> World_Version {
	tables := make([]Version_Table, len(prior.tables), allocator)
	for table, i in prior.tables {
		if replacement, ok := changed[table.thing]; ok {
			// A table the tick changed: take the supplied committed rows.
			tables[i] = replacement
		} else {
			// Unchanged: SHARE the prior table's row slice by reference — no copy
			// (structural sharing, §08 §4). The rows are immutable, so sharing is safe.
			tables[i] = table
		}
	}
	return World_Version{tick = prior.tick + 1, tables = tables}
}

// version_find_table returns the committed table holding rows of the named
// thing, or nil when no such thing was declared. The descriptor-driven lookup a
// view-by-type opens with.
version_find_table :: proc(version: ^World_Version, thing: string) -> ^Version_Table {
	for &table in version.tables {
		if table.thing == thing {
			return &table
		}
	}
	return nil
}

// --- View[T]: the read-only table (§08 §2) -------------------------------

// View is the §08 §2 read-only, iterable view of one thing type's instances in
// stable Id ORDER; it never grants mutation. The phantom T is the thing-type
// name (descriptor-driven), and the rows are an immutable slice the version owns,
// kept ascending by Id so iteration order is the stable Id order §08 §2
// mandates. Surface: count / at(i) / ref(i) / resolve(ref), plus the View.of
// test fixture below. Ad-hoc reads are the list combinators over View.rows — a
// View is the table, the combinators are the SELECT (§08 §2).
View :: struct {
	thing: string, // the thing type this view ranges over (the phantom T)
	rows:  []Row, // the version's rows for this type, ascending by Id (immutable)
}

// view_of_type opens a View over one thing type's committed instances at a
// version — the descriptor-driven `all[T]` (§08 §3). An undeclared thing yields
// an empty view rather than a refusal, since a read can never fail-closed: a
// query over a type with no rows is the legitimate empty SELECT.
view_of_type :: proc(version: ^World_Version, thing: string) -> View {
	table := version_find_table(version, thing)
	if table == nil {
		return View{thing = thing, rows = nil}
	}
	return View{thing = thing, rows = table.rows}
}

// view_count is the §08 §2 `count` aggregate: the number of rows in the view.
// The simplest deterministic ordered fold over the View (§08 §3 aggregates).
view_count :: proc(view: View) -> int {
	return len(view.rows)
}

// view_at is the §08 §2 `at(i)` positional read: the i-th row in stable Id
// order. ok is false when i is out of range, so the caller matches the absent
// arm rather than index past the view (the option-shaped result convention the
// kernel's checked ops use).
view_at :: proc(view: View, i: int) -> (row: Row, ok: bool) {
	if i < 0 || i >= len(view.rows) {
		return {}, false
	}
	return view.rows[i], true
}

// view_ref is the §08 §2 `ref(i) -> Ref[T]`: a weak typed handle to the i-th row
// in stable Id order. Pair with resolve for the round-trip the fixture tests
// assert. ok is false when i is out of range (no row to reference).
view_ref :: proc(view: View, i: int) -> (ref: Ref, ok: bool) {
	row, in_range := view_at(view, i)
	if !in_range {
		return {}, false
	}
	return Ref{thing = view.thing, id = row.id}, true
}

// view_resolve is the §08 §2 `resolve(ref) -> Option[T]` over a View's rows: it
// returns the live row a Ref points at, or the None arm when no row carries that
// Id (a despawned or never-spawned referent). Totality FORCES the dangling case
// — a use-after-despawn is unrepresentable (§08 §1). The lookup binary-searches
// the Id-sorted rows, so resolve is logarithmic and order-stable.
view_resolve :: proc(view: View, ref: Ref) -> (row: Row, some: bool) {
	if ref.thing != view.thing {
		// A Ref into a different table never resolves here — referential
		// integrity by type (§08 §1: a Ref[T] is phantom-typed).
		return {}, false
	}
	idx, found := find_row_by_id(view.rows, ref.id)
	if !found {
		return {}, false
	}
	return view.rows[idx], true
}

// resolve_ref is the §08 §1 world-level `Ref -> Option[T]`: resolve a handle
// against a whole committed version, dispatching to the table the Ref's phantom
// type names. The None arm is forced for a dangling Ref (despawned or absent)
// OR a Ref into an undeclared thing type — referential integrity by
// construction, the dangling case unrepresentable as a live row.
resolve_ref :: proc(version: ^World_Version, ref: Ref) -> (row: Row, some: bool) {
	table := version_find_table(version, ref.thing)
	if table == nil {
		return {}, false
	}
	idx, found := find_row_by_id(table.rows, ref.id)
	if !found {
		return {}, false
	}
	return table.rows[idx], true
}

// --- Singleton: the row-count-1 slot (§08 §3, §06 §2) --------------------

// singleton_row reads the single row of a singleton thing accessed BY TYPE
// (§08 §3, §06 §2: a singleton is the row-count-1 constraint, spawned once by
// the engine and accessed by type, never iterated). ok is false unless the
// thing is a declared singleton holding exactly one committed row — so a
// singleton that has not yet been spawned, or a thing that is not a singleton,
// takes the absent arm. Pong does NOT exercise this path: it models the score as
// an ordinary single-instance Scoreboard thing (a plain View over one row), so
// the singleton slot is implemented generically here while the ordinary-thing
// single-instance path (view_of_type over a one-row table) carries pong.
singleton_row :: proc(version: ^World_Version, thing: string) -> (row: Row, ok: bool) {
	table := version_find_table(version, thing)
	if table == nil || !table.singleton {
		return {}, false
	}
	if len(table.rows) != 1 {
		// The row-count-1 constraint is not yet satisfied (un-spawned) — the
		// engine spawns the singleton exactly once, but the read side reports the
		// absent arm rather than assume a row (sim code has no panics, §08 §3).
		return {}, false
	}
	return table.rows[0], true
}

// --- Field access (descriptor-driven column read) ------------------------

// row_field reads one column of a row's blackboard by field name — the
// descriptor-driven stand-in for struct field access (the schema is Thing_Decl
// data, not an Odin type). ok is false when the field is absent from the row's
// blackboard, so a missing column matches an arm rather than reading a zero
// value silently.
row_field :: proc(row: Row, name: string) -> (value: Field_Value, ok: bool) {
	value, ok = row.fields[name]
	return
}

// row_ref reads a Ref-typed column of a row's blackboard (the common
// resolve-then-read join: a Door's `gate: Ref[Switch]`, §08 §1). ok is false
// when the field is absent OR holds a non-Ref value, so a typed read can never
// silently coerce a column.
row_ref :: proc(row: Row, name: string) -> (ref: Ref, ok: bool) {
	value, present := row.fields[name]
	if !present {
		return {}, false
	}
	ref, ok = value.(Ref)
	return
}

// --- Internal helpers -----------------------------------------------------

// find_row_by_id binary-searches an Id-ascending row slice for the row carrying
// `id`, returning its index and whether it was found. The View keeps rows sorted
// by Id (stable iteration order, §08 §2), so resolve is a logarithmic lookup,
// not a linear scan — and the order it relies on is the same order iteration
// exposes.
find_row_by_id :: proc(rows: []Row, id: Id) -> (idx: int, found: bool) {
	lo, hi := 0, len(rows)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if rows[mid].id.raw < id.raw {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(rows) && rows[lo].id.raw == id.raw {
		return lo, true
	}
	return 0, false
}

// --- View.of test fixture (§08 §2) ---------------------------------------

// view_of is the §08 §2 `View.of(items)` test fixture: it assigns each element a
// stable Id in order (0, 1, 2, …) and returns a View over them — pair with
// view_ref(i) for resolve tests, exactly as §08 §2 directs. It mints Ids
// densely and monotonically, the same shape the deterministic spawn counter
// produces, so a fixture View is iteration- and resolve-identical to a committed
// one. The blackboards passed in are taken as given; the fixture only stamps the
// Ids and the iteration order.
view_of :: proc(thing: string, blackboards: []map[string]Field_Value, allocator := context.allocator) -> View {
	rows := make([]Row, len(blackboards), allocator)
	for fields, i in blackboards {
		rows[i] = Row{id = Id{raw = Thing_Id(i)}, fields = fields}
	}
	return View{thing = thing, rows = rows}
}

// --- Vec2 math surface (consolidated per input.odin's seam, §10 Tier-2) ---
// The input snapshot landed the minimal Vec2{x, y: Fixed} with a TODO to
// consolidate the full math surface onto that one definition when the state
// layer arrived (a second Vec2 declaration would be a compile error). The
// blackboard's Vec2 columns are the same type, so the length / dot / normalize
// surface a behavior folds over lives here, over the kernel — no float (§10).

// vec2_add / vec2_sub are component-wise over the saturating kernel.
vec2_add :: proc(a, b: Vec2) -> Vec2 {
	return Vec2{fixed_add(a.x, b.x), fixed_add(a.y, b.y)}
}

vec2_sub :: proc(a, b: Vec2) -> Vec2 {
	return Vec2{fixed_sub(a.x, b.x), fixed_sub(a.y, b.y)}
}

// vec2_scale multiplies both components by a scalar Fixed (§10 Tier-2).
vec2_scale :: proc(v: Vec2, s: Fixed) -> Vec2 {
	return Vec2{fixed_mul(v.x, s), fixed_mul(v.y, s)}
}

// vec2_dot is the §10 dot product over the kernel: ax*bx + ay*by.
vec2_dot :: proc(a, b: Vec2) -> Fixed {
	return fixed_add(fixed_mul(a.x, b.x), fixed_mul(a.y, b.y))
}

// vec2_length is sqrt(dot(v, v)) through the kernel's integer sqrt — bit-exact
// on perfect squares, floor-rounded otherwise, kernel-evaluable-or-fail-closed
// (§10.5: no libm, no float in the determinism path).
vec2_length :: proc(v: Vec2) -> Fixed {
	return fixed_sqrt(vec2_dot(v, v))
}

// vec2_normalize returns v scaled to unit length, or VEC2_ZERO for the zero
// vector (the kernel's sqrt and checked-div fold the degenerate case to a
// defined value — no panic, no NaN, §10.5). ok is false exactly for the zero
// vector, so the caller can match the degenerate arm rather than read VEC2_ZERO
// as a unit vector.
vec2_normalize :: proc(v: Vec2) -> (unit: Vec2, ok: bool) {
	length := vec2_length(v)
	if length == 0 {
		return VEC2_ZERO, false
	}
	return Vec2{fixed_div(v.x, length), fixed_div(v.y, length)}, true
}

// --- Bit-identity comparison of two committed versions --------------------

// world_versions_equal reports whether two committed versions are BIT-IDENTICAL:
// same tick, same table set, same rows in the same stable Id order, same
// blackboard columns down to the fixed-point bits. It is the determinism
// comparison surface — a fold run twice over the same inputs, and a replay
// re-fold against the original run, must each compare equal here. A pure
// read-only function of two World_Versions, so it lives with the read layer.
world_versions_equal :: proc(a, b: World_Version) -> bool {
	if a.tick != b.tick || len(a.tables) != len(b.tables) {
		return false
	}
	for table_a, i in a.tables {
		table_b := b.tables[i]
		if table_a.thing != table_b.thing || len(table_a.rows) != len(table_b.rows) {
			return false
		}
		for row_a, j in table_a.rows {
			row_b := table_b.rows[j]
			if row_a.id != row_b.id || !blackboards_equal(row_a.fields, row_b.fields) {
				return false
			}
		}
	}
	return true
}

// blackboards_equal compares two row blackboards column-for-column: same field
// set, same Field_Value per field (the union compares structurally, so a Fixed
// column compares by its raw bits). A column present in one but not the other is
// a mismatch.
blackboards_equal :: proc(a, b: map[string]Field_Value) -> bool {
	if len(a) != len(b) {
		return false
	}
	for key, value_a in a {
		value_b, present := b[key]
		if !present || value_a != value_b {
			return false
		}
	}
	return true
}
