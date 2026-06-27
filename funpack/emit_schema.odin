// The schema-section serializers of the artifact emitter: [meta], [enums],
// [data], [signals], and [things] (docs/artifact-format.md §4-§8). One file for
// the type-schema half of the byte format — the program's declared types and
// their field defaults, plus the emitter-synthesized engine-type projections
// (Settings/AccessOpts/Path) a composite default decodes its nested types against.
package funpack

import "core:strings"

// ───────────────────────────────────────────────────────────────────────────
// [meta] — project identity (docs/artifact-format.md §4)
// ───────────────────────────────────────────────────────────────────────────

// emit_meta writes the two-record [meta] block: the project name (the §14
// project.fcfg block label) and the version as a length-prefixed String field.
// It carries no clock and no platform — identity only (§14 §4).
emit_meta :: proc(b: ^strings.Builder, project: Project_Identity) {
	emit_header(b, "meta", 2)
	emit_line(b, "project ", project.name)
	emit_line(b, "version ", encode_string(project.version, context.temp_allocator))
}

// ───────────────────────────────────────────────────────────────────────────
// [enums] — sum types and role kinds (docs/artifact-format.md §5)
// ───────────────────────────────────────────────────────────────────────────

// emit_enums writes one record per enum — the entrypoint module's own enums in
// source-declaration order, then the v15 imported carry (emit_seam_decls.odin)
// in import-then-member order — each followed by one `variant` line per
// variant. KIND is the §03 §4 role kind (Axis/Button/…) or `-` for none;
// pong's variants are all `unit` (no payload).
emit_enums :: proc(b: ^strings.Builder, ast: Ast, imported: []Enum_Node) {
	emit_header(b, "enums", len(ast.enums) + len(imported))
	for decl in ast.enums {
		emit_enum_record(b, decl)
	}
	for decl in imported {
		emit_enum_record(b, decl)
	}
}

// emit_enum_record writes one [enums] record (docs/artifact-format.md §5) —
// the per-decl half emit_enums walks own and imported declarations through.
emit_enum_record :: proc(b: ^strings.Builder, decl: Enum_Node) {
	kind := decl.kind if decl.kind != "" else "-"
	strings.write_string(b, "enum ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_string(b, kind)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.variants))
	emit_line(b, "")
	for variant in decl.variants {
		emit_line(b, "variant ", variant.name, " ", variant_payload_tag(variant))
	}
}

// variant_payload_tag renders a variant's payload shape (docs/artifact-format.md
// §5): `unit` for a plain variant, `tuple K` for K positional types, `struct K`
// for K named fields. Pong's enums are all `unit`; the tuple/struct heads carry
// the count so a reader knows how many type/field tokens follow.
variant_payload_tag :: proc(variant: Variant_Decl) -> string {
	switch variant.payload {
	case .Tuple:
		return strings.concatenate({"tuple ", encode_int(i64(len(variant.tuple)), context.temp_allocator)}, context.temp_allocator)
	case .Struct:
		return strings.concatenate({"struct ", encode_int(i64(len(variant.fields)), context.temp_allocator)}, context.temp_allocator)
	case .Plain:
		return "unit"
	}
	return "unit"
}

// ───────────────────────────────────────────────────────────────────────────
// [data] / [signals] / [things] — schemas with field defaults
// (docs/artifact-format.md §6, §7, §8)
// ───────────────────────────────────────────────────────────────────────────

// emit_data writes one `data` record per declaration — the entrypoint module's
// own decls in source order, then the v15 imported carry in import-then-member
// order — each followed by its fields. `mut` is `true` for a `mut data`
// (§03 §7) — pong has none, so it is always `false` here. After the user data
// decls, it emits any SYNTHESIZED engine-type data decls
// (docs/artifact-format.md §8): an engine record the source uses by default but
// has no user `data` for (yard's Settings, warren's Path). The runtime's
// composite-default decode resolves a `Settings(…)` or `Path(…)` default's
// nested field types against the §8 data decl, so the projection must be present
// in [data]; the funpack surface
// owns the engine type, the artifact carries its representable projection. The
// synthesized decls land in a fixed order after the user and imported decls, so
// the section stays byte-deterministic.
emit_data :: proc(b: ^strings.Builder, ast: Ast, imported: Imported_Decls) {
	synthetic := synthetic_data_decls(ast, imported)
	emit_header(b, "data", len(ast.datas) + len(imported.datas) + len(synthetic))
	for decl in ast.datas {
		emit_data_record(b, decl, ast)
	}
	for decl in imported.datas {
		emit_data_record(b, decl, ast)
	}
	for decl in synthetic {
		emit_synthetic_data(b, decl)
	}
}

// emit_data_record writes one [data] record (docs/artifact-format.md §6) —
// the per-decl half emit_data walks own and imported declarations through.
emit_data_record :: proc(b: ^strings.Builder, decl: Data_Node, ast: Ast) {
	strings.write_string(b, "data ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.fields))
	emit_line(b, " false")
	// A renamed TYPE declaration (decl-level @migrate, rename form only)
	// carries its `migrate` line between the lead line and the first
	// `field` line (docs/artifact-format.md §6, schema v8).
	if decl.has_migrate {
		emit_line(b, "migrate ", decl.migrate.from, " -")
	}
	emit_data_fields(b, decl.fields, ast)
}

// Synthetic_Data is one emitter-synthesized engine-type data decl — the
// runtime-representable projection of an engine record the source references by
// type but does not declare as user `data` (yard's Settings). name is the
// artifact type name; fields is the projected field schema (all required).
Synthetic_Data :: struct {
	name:   string,
	fields: []Synthetic_Field,
}

// synthetic_data_decls returns the engine-type data decls the source's defaults
// require the artifact to carry (docs/artifact-format.md §8). Two cases. (1) A
// Settings default (`Settings.defaults()`) needs the §8 Settings projection in
// [data] so the runtime decode resolves its nested field types — AND its nested
// AccessOpts sub-record's projection, because the Settings default carries an
// `access=AccessOpts(reduce_motion=false)` token whose `reduce_motion` field type
// the runtime resolves against AccessOpts' own §8 decl (a nested composite default
// decodes each field against its declared type, so the nested ctor MUST have a data
// decl or its Bool would lift to a bare string token, not a Bool). (2) A Path
// default (`Path{steps: [], cost: 0.0}` on warren_world's Rabbit/Ferret, carried
// into [things] by the v15 declaration carry) needs the §8 Path projection so the
// runtime resolves `steps`/`cost` in the `=Path(steps=[],cost=0)` token to
// [Vec2]/Fixed instead of lifting them untyped. Each group is emitted iff some
// thing/data/signal field — own or imported — declares the trigger type, so a
// source that never uses Settings or Path emits no extra data record (pong/snake/
// hunt are unchanged). The fixed order Settings, AccessOpts, Path keeps the
// section byte-deterministic.
synthetic_data_decls :: proc(ast: Ast, imported: Imported_Decls) -> []Synthetic_Data {
	out := make([dynamic]Synthetic_Data, 0, 3, context.temp_allocator)
	if uses_engine_type(ast, imported, "Settings") {
		append(&out, Synthetic_Data{name = "Settings", fields = SETTINGS_DATA_FIELDS})
		append(&out, Synthetic_Data{name = "AccessOpts", fields = ACCESS_OPTS_DATA_FIELDS})
	}
	if uses_engine_type(ast, imported, "Path") {
		append(&out, Synthetic_Data{name = "Path", fields = PATH_DATA_FIELDS})
	}
	if references_cell_type(ast, imported) && !declares_data_type(ast, imported, "Cell") {
		append(&out, Synthetic_Data{name = "Cell", fields = CELL_DATA_FIELDS})
	}
	return out[:]
}

// CELL_DATA_FIELDS is the §8 projection of the imported structural stdlib record
// engine.grid.Cell (`data Cell { x: Int, y: Int }`). A game that imports Cell
// rather than declaring its own carries no user [data] decl for it, so the runtime
// has no schema to type Cell's Int fields when it decodes a `Cell(x=N,y=N)` token —
// it would lift the bare integers to raw Fixed bits (a 1/2^32-scaled coordinate).
// Projecting Cell into [data] gives the runtime the same schema snake/dungeon get
// from their own `data Cell` decl.
@(rodata)
CELL_DATA_FIELDS := []Synthetic_Field{{name = "x", type_name = "Int"}, {name = "y", type_name = "Int"}}

// references_cell_type reports whether any field — own or imported — is typed Cell,
// [Cell], or Option[Cell], the structural-stdlib forms a grid game stores. Kept a
// closed wrapper set (not a substring scan) so CellCursor and other Cell-prefixed
// types never false-match.
references_cell_type :: proc(ast: Ast, imported: Imported_Decls) -> bool {
	return(
		uses_engine_type(ast, imported, "Cell") ||
		uses_engine_type(ast, imported, "[Cell]") ||
		uses_engine_type(ast, imported, "Option[Cell]") \
	)
}

// declares_data_type reports whether a user (own or v15-imported) [data] decl
// already names the type — the guard that keeps Cell's synthetic projection from
// duplicating a game's own `data Cell` (snake, dungeon).
declares_data_type :: proc(ast: Ast, imported: Imported_Decls, type_name: string) -> bool {
	for decl in ast.datas {
		if decl.name == type_name {
			return true
		}
	}
	for decl in imported.datas {
		if decl.name == type_name {
			return true
		}
	}
	return false
}

// uses_engine_type reports whether any thing/singleton/data/signal field — the
// entrypoint module's own or the v15 imported carry's — declares the given
// engine type name as its field type — the trigger for synthesizing that engine
// type's §8 data projection. It reads the field TYPE spelling
// (type_ref_string), so `Settings` matches the bare engine type a singleton
// field holds (yard's `Menu.settings: Settings`).
uses_engine_type :: proc(ast: Ast, imported: Imported_Decls, type_name: string) -> bool {
	for decl in ast.things {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in ast.datas {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in ast.signals {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in imported.things {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in imported.datas {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	for decl in imported.signals {
		if fields_declare_type(decl.fields, type_name) {
			return true
		}
	}
	return false
}

// fields_declare_type reports whether any field's declared type renders to the
// given bare type name — the per-record half of uses_engine_type.
fields_declare_type :: proc(fields: []Field_Decl, type_name: string) -> bool {
	for field in fields {
		if type_ref_string(field.type) == type_name {
			return true
		}
	}
	return false
}

// emit_synthetic_data writes one synthesized engine-type data record (the §8
// shape): `data NAME field_count false` then one `field NAME TYPE -` per field.
// Every projected field is required (the §6 DEFAULT slot is `-`); a Settings
// default supplies both `volume`/`fullscreen` inline, so the runtime never reads a
// field-level default off this decl. mut is always false (an engine record
// projection is never `mut data`).
emit_synthetic_data :: proc(b: ^strings.Builder, decl: Synthetic_Data) {
	strings.write_string(b, "data ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.fields))
	emit_line(b, " false")
	for field in decl.fields {
		emit_line(b, "field ", field.name, " ", field.type_name, " -")
	}
}

// emit_signals writes one `signal` record per declaration — the entrypoint
// module's own signals in source order, then the v15 imported carry in
// import-then-member order — same field grammar as [data] but with no `mut`
// flag (a signal is per-tick, never mutated, §06 §5).
emit_signals :: proc(b: ^strings.Builder, ast: Ast, imported: []Signal_Node) {
	emit_header(b, "signals", len(ast.signals) + len(imported))
	for decl in ast.signals {
		emit_signal_record(b, decl, ast)
	}
	for decl in imported {
		emit_signal_record(b, decl, ast)
	}
}

// emit_signal_record writes one [signals] record (docs/artifact-format.md §7) —
// the per-decl half emit_signals walks own and imported declarations through.
emit_signal_record :: proc(b: ^strings.Builder, decl: Signal_Node, ast: Ast) {
	strings.write_string(b, "signal ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.fields))
	emit_line(b, "")
	emit_fields(b, decl.fields, ast)
}

// emit_things writes one `thing` record per thing/singleton — the entrypoint
// module's own things in source order, then the v15 imported carry in
// import-then-member order (dungeon_world's Player/Slime/Chest, the schemas the
// level-backed [setup] batch spawns against) — each followed by its `@gtag` set
// and its blackboard schema. SINGLETON is `true` for a `singleton` (§06 §2);
// pong models the score as a `thing`, so all three are `false`.
emit_things :: proc(b: ^strings.Builder, ast: Ast, imported: []Thing_Node) {
	emit_header(b, "things", len(ast.things) + len(imported))
	for decl in ast.things {
		emit_thing_record(b, decl, ast)
	}
	// Imported things arrive with their §6 defaults already folded against their
	// OWN module's lets (collect_imported_decls); re-folding against the entry `ast`
	// here is a no-op on those closed values, so the entry table never needs the
	// sibling module's constants.
	for decl in imported {
		emit_thing_record(b, decl, ast)
	}
}

// emit_thing_record writes one [things] record (docs/artifact-format.md §8) —
// the per-decl half emit_things walks own and imported declarations through.
emit_thing_record :: proc(b: ^strings.Builder, decl: Thing_Node, ast: Ast) {
	strings.write_string(b, "thing ")
	strings.write_string(b, decl.name)
	strings.write_byte(b, ' ')
	strings.write_string(b, encode_bool(decl.is_singleton))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.gtags))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(decl.fields))
	emit_line(b, "")
	emit_gtags(b, decl.gtags)
	emit_fields(b, decl.fields, ast)
}

// emit_fields writes one `field` line per field (docs/artifact-format.md §6):
// the field name, its syntactic type (the Type_Ref spelling — `Fixed`,
// `View[Paddle]`, `[Goal]`), and its default. The default is `-` for a required
// field or `=ENCODED` for a defaulted one (§03 §1).
emit_fields :: proc(b: ^strings.Builder, fields: []Field_Decl, ast: Ast) {
	for field in fold_field_decls(fields, ast) {
		emit_line(b, "field ", field.name, " ", type_ref_string(field.type), " ", field_default_token(field))
	}
}

// emit_data_fields is emit_fields for a [data] record — the one section whose
// fields may carry §05 §6 migration metadata (docs/artifact-format.md §6,
// schema v8). A migrated field's `field` line is followed by its fixed
// three-token `migrate FROM WITH` line (`-` for the absent half; the parser
// guarantees at least one present); an unmigrated field emits exactly the
// shared emit_fields shape, so a migration-free [data] section is
// byte-identical to the v7 layout.
emit_data_fields :: proc(b: ^strings.Builder, fields: []Field_Decl, ast: Ast) {
	for field in fold_field_decls(fields, ast) {
		emit_line(b, "field ", field.name, " ", type_ref_string(field.type), " ", field_default_token(field))
		if field.has_migrate {
			from := field.migrate.from if field.migrate.has_from else "-"
			with := field.migrate.with if field.migrate.has_with else "-"
			emit_line(b, "migrate ", from, " ", with)
		}
	}
}

// emit_gtags writes one `gtag` line per registered tag, each as a length-
// prefixed String field, in source order (docs/artifact-format.md §8).
emit_gtags :: proc(b: ^strings.Builder, gtags: []string) {
	for tag in gtags {
		emit_line(b, "gtag ", encode_string(tag, context.temp_allocator))
	}
}

// field_default_token renders a field's DEFAULT (docs/artifact-format.md §6):
// `-` when the field has no default, else `=ENCODED` where ENCODED is the
// default's single-token encoding. Pong's defaults are all scalar (the Scoreboard
// `Int = 0` pair); snake and hunt add the enum-variant, empty-list, and composite
// record forms (`Dir::Right`, `[]`, `Cell(x=10,y=10)`, `Hunt::Patrol`,
// `Vec2(x=0,y=0)`) — every form a single space-free token, since a `field` line
// is whitespace-delimited and a reader reads DEFAULT at one position.
field_default_token :: proc(field: Field_Decl) -> string {
	if !field.has_default {
		return "-"
	}
	return strings.concatenate({"=", encode_field_default(field.default)}, context.temp_allocator)
}

// encode_field_default renders a field default's value as the one space-free token
// the §6 DEFAULT slot carries. A scalar (Int/Fixed/Bool/String) routes through
// encode_literal, byte-identical to the original scalar-only encoding. An
// enum-variant default is its `Type::Case` token (§2.6); an empty list is `[]`; a
// composite record default (Vec2/Cell/any constructor) is its inline constructor
// token `Type(field=enc,…)` — the §6 single-token realization of "its constructor
// record inline", parenthesized and space-free so it fits the one-token slot the
// §13 space-spread `vec2` form cannot. An engine static-builder default
// (`Settings.defaults()`) is a CALL the artifact cannot carry as an expression
// (the §13 spawn batch and §6 defaults hold only evaluated values, §29 purity),
// so it lowers to the evaluated factory-default record inline — the same
// `Type(field=enc,…)` composite token a record default produces (engine_builder_default).
encode_field_default :: proc(expr: Expr) -> string {
	#partial switch e in expr {
	case ^Variant_Expr:
		return strings.concatenate({e.type_name, "::", e.variant}, context.temp_allocator)
	case ^List_Expr:
		// A defaulted list seeds empty (the only list literal a default admits,
		// e.g. snake's `body: [Cell] = []`), so the token is the empty-list `[]`.
		return "[]"
	case ^Record_Expr:
		return encode_record_default(e)
	case ^Call_Expr:
		if token, found := engine_builder_default(e); found {
			return token
		}
	}
	return encode_literal(expr)
}

// engine_builder_default lowers an engine static-builder default call to its
// evaluated factory-default record token (docs/artifact-format.md §6, §8). A
// builder like `Settings.defaults()` is a no-arg static call, not a value the
// §29-pure artifact can carry verbatim — so the emitter EVALUATES it to its
// canonical default record and inlines that, matching how a composite record
// default already inline-encodes (`Type(field=enc,…)`). The Settings the artifact
// carries is the runtime's representable two-field projection `{volume: Int,
// fullscreen: Bool}` (the cross-product contract the runtime decode reads against
// the synthesized §8 Settings data decl, emit_data), so the factory default is
// the documented `Settings(volume=128,fullscreen=false)`. The set is closed: a
// new engine builder default is a deliberate edit, mirroring the closed surface.
engine_builder_default :: proc(call: ^Call_Expr) -> (token: string, found: bool) {
	member, is_member := call.callee.(^Member_Expr)
	if !is_member || len(call.args) != 0 {
		return "", false
	}
	type_name, is_name := member.receiver.(^Name_Expr)
	if !is_name {
		return "", false
	}
	if type_name.name == "Settings" && member.member == "defaults" {
		return SETTINGS_DEFAULT_TOKEN, true
	}
	return "", false
}

// SETTINGS_DEFAULT_TOKEN is the evaluated `Settings.defaults()` factory default
// in the artifact's representable Settings projection — the byte-exact token the
// runtime's composite-default decode reads (runtime/decode_default_test.odin).
// Volume 128 is the mid-scale default gain; fullscreen defaults off; `access` is
// the nested AccessOpts sub-record carrying `reduce_motion: false`. The `access`
// column is LOAD-BEARING, not cosmetic: yard reads `settings.access.reduce_motion`
// (toggle_motion), so the singleton spawned from this default MUST carry an access
// sub-record or the nested read hits an absent column the moment the runtime spawns
// Menu from the real yard.artifact. It is a single space-free §6 composite token;
// the nested `AccessOpts(reduce_motion=false)` is itself a space-free token, so the
// composite form nests (docs/artifact-format.md §6).
SETTINGS_DEFAULT_TOKEN :: "Settings(volume=128,fullscreen=false,access=AccessOpts(reduce_motion=false))"

// SETTINGS_DATA_FIELDS is the runtime-representable §8 Settings projection the
// emitter synthesizes into [data] so the runtime can decode a Settings composite
// default's nested field types by declared type (volume → i64, fullscreen → bool,
// access → an AccessOpts record). The funpack SURFACE Settings (§24 §2: volume/
// binds/graphics/access) is the typecheck shape yard's source reads through; the
// ARTIFACT Settings is this projection — volume/fullscreen plus the `access`
// sub-record yard actually reads back (settings.access.reduce_motion). The fields
// are required (no §6 default of their own); a Settings default supplies all inline,
// so the runtime never applies a field-level default off this decl.
@(rodata)
SETTINGS_DATA_FIELDS := []Synthetic_Field{
	{name = "volume", type_name = "Int"},
	{name = "fullscreen", type_name = "Bool"},
	{name = "access", type_name = "AccessOpts"},
}

// ACCESS_OPTS_DATA_FIELDS is the §8 projection of the §24 §2 AccessOpts sub-record
// the Settings default nests. It carries the one field yard reads and toggles —
// `reduce_motion: Bool` — so the runtime resolves the nested
// `AccessOpts(reduce_motion=false)` token's field type to Bool (a missing AccessOpts
// data decl would lift `false` to a bare string token, not a Bool, breaking yard's
// `not settings.access.reduce_motion`). The other §24 AccessOpts fields are out of
// scope (the registry gate's "just enough", mirroring the surface schema).
@(rodata)
ACCESS_OPTS_DATA_FIELDS := []Synthetic_Field{
	{name = "reduce_motion", type_name = "Bool"},
}

// PATH_DATA_FIELDS is the §8 projection of the §08 engine.nav Path route value —
// the ordered waypoint list and the route's total cost, mirroring the surface
// schema (surface.odin surface_engine_record "Path": steps a [Vec2] list, cost a
// Fixed scalar). The runtime's composite-default decode resolves a
// `=Path(steps=[],cost=0)` field-default token (warren_world's Rabbit/Ferret
// `path` fields, reaching [things] via the v15 declaration carry) against this
// decl; without it `steps`/`cost` would lift as untyped tokens the moment the
// runtime spawns a defaulted Rabbit. Both fields are required (the §6 DEFAULT
// slot is `-`); a Path default supplies both inline.
@(rodata)
PATH_DATA_FIELDS := []Synthetic_Field{
	{name = "steps", type_name = "[Vec2]"},
	{name = "cost", type_name = "Fixed"},
}

// Synthetic_Field is one field of an emitter-synthesized engine-type data decl —
// the runtime-representable projection of an engine record (Settings) the source
// has no user `data` declaration for. Each carries the field name and its bare
// artifact type spelling; the field is required (no default), so the §6 DEFAULT
// slot is always `-`.
Synthetic_Field :: struct {
	name:      string,
	type_name: string,
}

// encode_record_default renders a composite record default `Type{f: v, …}` as its
// single-token inline constructor `Type(field=enc,…)` (docs/artifact-format.md §6):
// the type name, then a parenthesized comma-joined `field=ENCODED` list with no
// interior spaces, each value recursively a space-free field-default token so the
// form nests. `Vec2{x: 0.0, y: 0.0}` → `Vec2(x=0,y=0)`; `Cell{x: 10, y: 10}` →
// `Cell(x=10,y=10)`.
encode_record_default :: proc(record: ^Record_Expr) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, record.type_name)
	strings.write_byte(&b, '(')
	for field, i in record.fields {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, field.name)
		strings.write_byte(&b, '=')
		strings.write_string(&b, encode_field_default(field.value))
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}
