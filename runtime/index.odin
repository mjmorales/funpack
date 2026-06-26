// The §08 §3 engine-maintained index layer: the @index reverse/key lookups and
// @spatial structures the artifact's [queries] section declares, kept current
// over the committed world database. An index is a CACHE — a pure function of
// one committed version, rebuilt on load — with a DEFINED, Id-tiebroken
// iteration order, so it can never cause replay divergence (§08 §3).
//
// Maintenance rides the per-tick transaction's COMMIT boundary: the tick fold
// runs against the prior version's structures untouched (an update is never
// observable mid-stage), and when the next version commits, the fold recomputes
// ONLY the structures whose backing table the tick actually replaced — a table
// the COW commit shared by reference keeps its entry slice shared by reference
// too (structural sharing respected, §08 §4). The folded result is value-equal
// to a from-scratch rebuild of the committed version; the incremental path is
// an allocation saving, never a semantic input.
//
// ITERATION ORDER (the DEFINED order §08 §3 mandates): entries sort ascending
// by (key, Id) — the key under a total, machine-invariant ORDER-PRESERVING byte
// encoding (index_key_bytes below: numeric arms as sign-biased big-endian raw
// bits so byte order IS numeric order; strings as raw bytes; vectors
// lane-by-lane; structural columns by their canonical recursive encoding), with
// the stable Id as the tiebreak. The same bytes feed the index digest, so the
// order and the digest can never disagree.
package funpack_runtime

import "core:hash/xxhash"
import "core:slice"

// Index_Entry is one maintained index posting: the committed key column's
// value, its order-preserving canonical encoding (the comparator and the digest
// both read these exact bytes), and the row's stable Id.
Index_Entry :: struct {
	key:       Field_Value, // the committed column value the posting indexes
	key_bytes: []u8, // index_key_bytes(key) — the DEFINED order's comparison key
	id:        Id, // the posting's row, the (key, Id) tiebreak
}

// Index_Table_State is one declared requirement's maintained structure: its
// (kind, thing, field) identity and the postings in the DEFINED ascending
// (key, Id) order. `supported` is false when the indexed column holds a value
// the closed key encoding does not admit (a transient arm can never be a
// committed column, so in practice this is unreachable off a committed
// version); an unsupported table carries no postings and every lookup over it
// takes the absent arm — fail closed, never a partial index (§08 §3: an index
// can never cause replay divergence, so a half-built one is worse than none).
Index_Table_State :: struct {
	req:       Index_Req,
	entries:   []Index_Entry,
	supported: bool,
}

// Index_State is every declared requirement's maintained structure — one
// Index_Table_State per DISTINCT (kind, thing, field) across the program's
// queries, in first-declaration order (several queries may declare the same
// requirement; an index is a cache, so one structure serves them all).
Index_State :: struct {
	tables: []Index_Table_State,
}

// program_index_reqs collects the program's distinct declared requirements in
// first-declaration order: walk the queries in artifact order, each query's
// requirement lines in authored order, and keep the first occurrence of each
// (kind, thing, field). The order is a pure function of the artifact, so the
// maintained state's table order — and its digest stream — is deterministic.
program_index_reqs :: proc(program: ^Program, allocator := context.allocator) -> []Index_Req {
	reqs := make([dynamic]Index_Req, 0, 4, allocator)
	for query in program.queries {
		for req in query.indexes {
			if !index_reqs_contain(reqs[:], req) {
				append(&reqs, req)
			}
		}
	}
	return reqs[:]
}

// index_reqs_contain reports whether a requirement identity is already
// collected — the (kind, thing, field) dedupe program_index_reqs applies.
index_reqs_contain :: proc(reqs: []Index_Req, req: Index_Req) -> bool {
	for have in reqs {
		if have.kind == req.kind && have.thing == req.thing && have.field == req.field {
			return true
		}
	}
	return false
}

// build_index_state builds every declared structure from scratch over one
// committed version — the §08 §3 "rebuilt on load" path, and the reference
// semantics the incremental fold must reproduce exactly. It is a pure function
// of (program declarations, version).
build_index_state :: proc(
	program: ^Program,
	version: ^World_Version,
	allocator := context.allocator,
) -> Index_State {
	reqs := program_index_reqs(program, allocator)
	tables := make([]Index_Table_State, len(reqs), allocator)
	for req, i in reqs {
		tables[i] = build_index_table(req, version, allocator)
	}
	return Index_State{tables = tables}
}

// build_index_table builds one requirement's postings over a committed version:
// walk the thing's rows (already ascending by Id), encode each row's key column,
// then sort ascending by (key_bytes, Id) — the DEFINED iteration order. A
// missing column or an unencodable key marks the whole table unsupported (fail
// closed: no partial postings). An undeclared thing yields the legitimate empty
// index, exactly as a View over it is the legitimate empty SELECT (§08 §2).
build_index_table :: proc(
	req: Index_Req,
	version: ^World_Version,
	allocator := context.allocator,
) -> Index_Table_State {
	table := version_find_table(version, req.thing)
	if table == nil {
		return Index_Table_State{req = req, entries = nil, supported = true}
	}
	entries := make([]Index_Entry, len(table.rows), allocator)
	for row, i in table.rows {
		key, present := row.fields[req.field]
		if !present {
			return Index_Table_State{req = req, entries = nil, supported = false}
		}
		key_bytes, encodable := index_key_bytes(key, allocator)
		if !encodable {
			return Index_Table_State{req = req, entries = nil, supported = false}
		}
		entries[i] = Index_Entry{key = key, key_bytes = key_bytes, id = row.id}
	}
	slice.sort_by(entries, index_entry_less)
	return Index_Table_State{req = req, entries = entries, supported = true}
}

// index_entry_less is the DEFINED iteration order's comparator: ascending by
// the order-preserving key bytes, the stable Id as the tiebreak. Ids are unique
// within a table, so the order is strict — no two entries compare equal — and
// any correct sort yields the same sequence.
index_entry_less :: proc(a, b: Index_Entry) -> bool {
	switch key_order := index_bytes_compare(a.key_bytes, b.key_bytes); key_order {
	case -1:
		return true
	case +1:
		return false
	}
	return a.id.raw < b.id.raw
}

// index_bytes_compare is byte-lexicographic three-way comparison — the total
// order over encoded keys. A shared prefix defers to length (the shorter key
// sorts first), so the order is total over any two encodings.
index_bytes_compare :: proc(a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return a[i] < b[i] ? -1 : +1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return len(a) < len(b) ? -1 : +1
}

// fold_index_state folds the maintained structures forward across one committed
// tick — the per-tick maintenance path. For each declared requirement it
// compares the prior and next versions' backing tables: a table the COW commit
// SHARED by reference (the tick never replaced it) keeps its posting slice
// shared by reference too, and a replaced table is rebuilt from the committed
// rows. The result is value-equal to build_index_state over `next` —
// maintenance is an allocation saving, never a semantic input — and it never
// runs mid-stage: the caller folds it exactly once, at the commit boundary.
fold_index_state :: proc(
	prior_state: Index_State,
	prior: ^World_Version,
	next: ^World_Version,
	allocator := context.allocator,
) -> Index_State {
	tables := make([]Index_Table_State, len(prior_state.tables), allocator)
	for prior_table, i in prior_state.tables {
		req := prior_table.req
		prior_rows := version_table_rows(prior, req.thing)
		next_rows := version_table_rows(next, req.thing)
		if prior_table.supported && rows_shared(prior_rows, next_rows) {
			// The COW commit shared this thing's rows by reference, so the
			// committed content is identical — share the postings, no rebuild.
			tables[i] = prior_table
			continue
		}
		tables[i] = build_index_table(req, next, allocator)
	}
	return Index_State{tables = tables}
}

// version_table_rows reads one thing's committed row slice at a version, or nil
// when the thing is undeclared — the identity the COW-sharing check compares.
version_table_rows :: proc(version: ^World_Version, thing: string) -> []Row {
	table := version_find_table(version, thing)
	if table == nil {
		return nil
	}
	return table.rows
}

// rows_shared reports whether two committed row slices are the SAME slice —
// pointer-and-length identity, the structural-sharing signature commit_version
// leaves on a table the tick never replaced. Committed rows are immutable, so
// slice identity proves content identity; a fresh slice (even with equal
// content) just falls back to a rebuild, which is always correct.
rows_shared :: proc(a, b: []Row) -> bool {
	return raw_data(a) == raw_data(b) && len(a) == len(b)
}

// index_find_table finds the maintained structure for one (kind, thing, field)
// requirement, or nil when the program declared none.
index_find_table :: proc(state: ^Index_State, kind: Query_Index_Kind, thing: string, field: string) -> ^Index_Table_State {
	for &table in state.tables {
		if table.req.kind == kind && table.req.thing == thing && table.req.field == field {
			return &table
		}
	}
	return nil
}

// index_lookup is the §08 §3 reverse/key lookup over a maintained @index
// structure: every row Id whose indexed column equals `key`, ascending by Id
// (the DEFINED order's tiebreak IS the result order). The absent arm covers an
// undeclared requirement, an unsupported table, and an unencodable probe key —
// fail closed, never a partial answer.
index_lookup :: proc(
	state: ^Index_State,
	thing: string,
	field: string,
	key: Field_Value,
	allocator := context.allocator,
) -> (
	ids: []Id,
	ok: bool,
) {
	table := index_find_table(state, .Index, thing, field)
	if table == nil || !table.supported {
		return nil, false
	}
	key_bytes, encodable := index_key_bytes(key, context.temp_allocator)
	if !encodable {
		return nil, false
	}
	out := make([dynamic]Id, 0, 4, allocator)
	for entry in table.entries {
		if index_bytes_compare(entry.key_bytes, key_bytes) == 0 {
			append(&out, entry.id)
		}
	}
	return out[:], true
}

// --- Spatial queries over a maintained @spatial structure (§08 §3) ---------

// Spatial_Hit is one radius-query answer: the row and its kernel-exact distance
// from the probe origin — the (distance, Id) pair the nearest-first order sorts
// by.
Spatial_Hit :: struct {
	id:       Id,
	distance: Fixed,
}

// spatial_within is the §08 §3 deterministic radius query over a maintained
// @spatial structure: every posting whose vector key lies within `radius` of
// `origin` (fixed-point bounds — distance through the kernel's vec2_length/
// vec3_length, compared `<= radius`, no float ever), returned NEAREST-FIRST
// with the stable Id as the tiebreak — the `within` + `nearest_first` composed
// read the spec's exemplar query body folds. The probe origin's arm picks the
// dimension: a Vec2 origin reads Vec2 keys, a Vec3 origin Vec3 keys. The
// absent arm covers an undeclared requirement, an unsupported table, a
// non-vector origin, and a posting whose key arm mismatches the origin — a
// distance the kernel does not define is a refusal, never a coerced 0.
spatial_within :: proc(
	state: ^Index_State,
	thing: string,
	field: string,
	origin: Field_Value,
	radius: Fixed,
	allocator := context.allocator,
) -> (
	hits: []Spatial_Hit,
	ok: bool,
) {
	table := index_find_table(state, .Spatial, thing, field)
	if table == nil || !table.supported {
		return nil, false
	}
	out := make([dynamic]Spatial_Hit, 0, len(table.entries), allocator)
	for entry in table.entries {
		distance, measurable := spatial_distance(origin, entry.key)
		if !measurable {
			return nil, false
		}
		if distance <= radius {
			append(&out, Spatial_Hit{id = entry.id, distance = distance})
		}
	}
	slice.sort_by(out[:], spatial_hit_less)
	return out[:], true
}

// spatial_hit_less is the nearest-first order: ascending distance, the stable
// Id as the tiebreak — two equidistant rows answer in Id order, the §08 §3
// Id-tiebroken determinism rule.
spatial_hit_less :: proc(a, b: Spatial_Hit) -> bool {
	if a.distance != b.distance {
		return a.distance < b.distance
	}
	return a.id.raw < b.id.raw
}

// spatial_distance measures origin → key through the fixed-point kernel:
// vec2_length / vec3_length over the component difference (bit-exact on
// perfect squares, floor-rounded otherwise — deterministic on every machine,
// §10.5). ok is false on any arm mismatch: only a like-dimensioned vector pair
// has a defined distance.
spatial_distance :: proc(origin: Field_Value, key: Field_Value) -> (distance: Fixed, ok: bool) {
	switch from in origin {
	case Vec2:
		at, is_vec2 := key.(Vec2)
		if !is_vec2 {
			return 0, false
		}
		return vec2_length(vec2_sub(at, from)), true
	case Vec3:
		at, is_vec3 := key.(Vec3)
		if !is_vec3 {
			return 0, false
		}
		return vec3_length(vec3_sub(at, from)), true
	case i64, Fixed, bool, string, Ref, Record_Value, List_Value, Variant_Value, String_Value:
		return 0, false
	}
	return 0, false
}

// --- The order-preserving canonical key encoding ---------------------------

// index_key_bytes encodes a committed key column into bytes whose
// byte-lexicographic order IS the key order — one tag byte (the frame-digest
// Field_Tag, so two arms never alias), then the arm's payload in an
// order-preserving spelling: a numeric arm as its sign-biased raw bits in
// big-endian (so byte order equals numeric order, no float ever), a Bool as one
// 0/1 byte, a token/String as its raw bytes, a vector lane-by-lane, a Ref as
// its target thing then biased Id, and a structural column (Record/List/
// payload-carrying Variant) by its canonical recursive encoding — a total,
// machine-invariant DEFINED order even where the spec names no semantic one.
// ok is false only for a value outside the committed-column surface (a
// transient interpreter arm boxed inside a structural column), which the
// maintainer treats as an unsupported table — fail closed.
index_key_bytes :: proc(value: Field_Value, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	buf := make([dynamic]u8, 0, 16, allocator)
	if !append_field_key(&buf, value) {
		return nil, false
	}
	return buf[:], true
}

// append_field_key appends one Field_Value arm's order-preserving encoding.
// The structural arms box interpreter Values, so they recurse through
// append_value_key; the switch is total over the Field_Value union.
append_field_key :: proc(buf: ^[dynamic]u8, value: Field_Value) -> bool {
	switch v in value {
	case i64:
		append(buf, u8(Field_Tag.Int))
		append_biased_i64(buf, v)
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		append_biased_i64(buf, i64(v))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, v ? u8(1) : u8(0))
	case string:
		append(buf, u8(Field_Tag.Variant))
		append(buf, ..transmute([]u8)v)
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		append_biased_i64(buf, i64(v.x))
		append_biased_i64(buf, i64(v.y))
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		append_biased_i64(buf, i64(v.x))
		append_biased_i64(buf, i64(v.y))
		append_biased_i64(buf, i64(v.z))
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		append(buf, ..transmute([]u8)v.thing)
		append(buf, 0)
		append_biased_i64(buf, i64(v.id.raw))
	case Record_Value:
		return append_value_key(buf, v)
	case List_Value:
		return append_value_key(buf, v)
	case Variant_Value:
		return append_value_key(buf, v)
	case String_Value:
		append(buf, u8(Field_Tag.String))
		append(buf, ..transmute([]u8)v.text)
	}
	return true
}

// append_value_key appends one interpreter Value's order-preserving encoding —
// the recursive half append_field_key defers structural columns to. The scalar
// arms mirror append_field_key byte-for-byte (so a scalar reached through a
// record field orders identically to one at the top level); a Record encodes
// its type name then its fields in sorted-name order (Odin specifies no map
// iteration order, so the sort is what makes the bytes content-determined), a
// List its elements in list order, a Variant its token then boxed payload.
// false is the unsupported verdict: a transient arm (lambda/tuple/Rng/anim
// handle) is never a committed column, so it can never be an index key.
append_value_key :: proc(buf: ^[dynamic]u8, value: Value) -> bool {
	switch v in value {
	case i64:
		append(buf, u8(Field_Tag.Int))
		append_biased_i64(buf, v)
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		append_biased_i64(buf, i64(v))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, v ? u8(1) : u8(0))
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		append_biased_i64(buf, i64(v.x))
		append_biased_i64(buf, i64(v.y))
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		append_biased_i64(buf, i64(v.x))
		append_biased_i64(buf, i64(v.y))
		append_biased_i64(buf, i64(v.z))
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		append(buf, ..transmute([]u8)v.thing)
		append(buf, 0)
		append_biased_i64(buf, i64(v.id.raw))
	case Record_Value:
		append(buf, u8(Field_Tag.Record))
		append(buf, ..transmute([]u8)v.type_name)
		append(buf, 0)
		names := index_sorted_field_names(v.fields)
		defer delete(names)
		for name in names {
			append(buf, ..transmute([]u8)name)
			append(buf, 0)
			if !append_value_key(buf, v.fields[name]) {
				return false
			}
		}
	case List_Value:
		append(buf, u8(Field_Tag.List))
		for elem in v.elements {
			if !append_value_key(buf, elem) {
				return false
			}
		}
	case Variant_Value:
		append(buf, u8(Field_Tag.Variant))
		append(buf, ..transmute([]u8)variant_to_token(v, context.temp_allocator))
		if v.payload != nil {
			append(buf, 0)
			return append_value_key(buf, v.payload^)
		}
	case String_Value:
		append(buf, u8(Field_Tag.String))
		append(buf, ..transmute([]u8)v.text)
	case Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value, Map_Value:
		// Transient interpreter arms never commit as a column, so they can
		// never key an index — the unsupported verdict, fail closed.
		return false
	}
	return true
}

// index_sorted_field_names returns a record's field names in ascending byte
// order — the DEFINED total order over column names the recursive key encoding
// walks them in. Odin specifies no map iteration order, so this sort is what
// makes a Record key's bytes depend on its content alone (the same discipline
// the frame digest applies to its own — file-private — record writer). The
// caller frees the dynamic array.
index_sorted_field_names :: proc(fields: map[string]Value) -> [dynamic]string {
	names := make([dynamic]string, 0, len(fields))
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names
}

// append_biased_i64 appends a signed value as its sign-biased raw bits in
// BIG-endian order: flipping the sign bit maps i64 order onto unsigned order,
// and big-endian byte order makes byte-lexicographic comparison equal numeric
// comparison — the property the whole DEFINED key order rests on. No float, no
// locale, no machine dependence (§10).
append_biased_i64 :: proc(buf: ^[dynamic]u8, v: i64) {
	biased := u64(v) ~ (u64(1) << 63)
	for shift := uint(56); ; shift -= 8 {
		append(buf, u8(biased >> shift))
		if shift == 0 {
			break
		}
	}
}

// --- The index digest -------------------------------------------------------

// index_table_digest hashes one maintained structure's canonical stream — its
// (kind, thing, field) identity, its supported flag, and every posting's key
// bytes and Id in the DEFINED iteration order — with xxh64 (the same hasher the
// frame digest pins). Two maintained states fed the same committed content
// digest identically on every machine; a posting order or content difference
// names itself here. This is the determinism pin the maintenance goldens
// compare per tick.
index_table_digest :: proc(table: Index_Table_State) -> u64 {
	buf := make([dynamic]u8, 0, 256, context.temp_allocator)
	append(&buf, u8(table.req.kind))
	append(&buf, ..transmute([]u8)table.req.thing)
	append(&buf, 0)
	append(&buf, ..transmute([]u8)table.req.field)
	append(&buf, 0)
	append(&buf, table.supported ? u8(1) : u8(0))
	for entry in table.entries {
		append_biased_i64(&buf, i64(len(entry.key_bytes)))
		append(&buf, ..entry.key_bytes)
		append_biased_i64(&buf, i64(entry.id.raw))
	}
	return u64(xxhash.XXH64(buf[:]))
}

// index_state_digest folds every table's digest in declaration order into one
// state digest — the single per-tick maintenance pin.
index_state_digest :: proc(state: Index_State) -> u64 {
	buf := make([dynamic]u8, 0, 8 * (len(state.tables) + 1), context.temp_allocator)
	append_biased_i64(&buf, i64(len(state.tables)))
	for table in state.tables {
		append_biased_i64(&buf, i64(index_table_digest(table)))
	}
	return u64(xxhash.XXH64(buf[:]))
}

// index_states_equal compares two maintained states value-for-value: same table
// inventory in the same order, same supported verdicts, same postings down to
// the key bytes and Ids. The incremental fold's acceptance — fold result equals
// from-scratch rebuild — reads through this.
index_states_equal :: proc(a, b: Index_State) -> bool {
	if len(a.tables) != len(b.tables) {
		return false
	}
	for table_a, i in a.tables {
		table_b := b.tables[i]
		if table_a.req != table_b.req || table_a.supported != table_b.supported {
			return false
		}
		if len(table_a.entries) != len(table_b.entries) {
			return false
		}
		for entry_a, j in table_a.entries {
			entry_b := table_b.entries[j]
			if entry_a.id != entry_b.id || index_bytes_compare(entry_a.key_bytes, entry_b.key_bytes) != 0 {
				return false
			}
		}
	}
	return true
}
