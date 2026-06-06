// The production artifact emitter: the pure source → artifact serializer.
// It walks the checked AST (parse → resolve → typecheck → contracts) and the
// depth-first flattened pipeline (pipeline_flatten.odin) and writes every
// section of the v1 byte format in the spec's fixed order
// (docs/artifact-format.md §3). The output reproduces the committed golden
// fixture (testdata/pong.artifact) byte-for-byte from the pong source, and the
// runtime parses those bytes with zero funpack imports.
//
// PURITY (spec §09, §29; docs/artifact-format.md §2): emission is a pure
// function of source — no clock, no machine paths, no float, no host bytes.
// Every Fixed is its raw Q32.32 i64 bits in decimal (the same kernel
// representation as fixed.odin), every list is in a defined total order
// (declaration order or the flattened pipeline order, never map order), and the
// only path-derived datum is the §15 module name carried in a span. Two
// emissions from the same source are therefore byte-identical: no field's value
// depends on when, where, or on which machine it was emitted.
//
// Boundary: bytes only. This file does not wire a CLI verb (the build verb is
// out of scope), does not emit the Index Contract NDJSON (§29, out of scope),
// and does not execute the artifact (the runtime owns execution).
package funpack

import "core:strings"

// Emit_Input bundles the four pure inputs the emitter projects into bytes: the
// checked AST (source declarations), the flattened pipeline (the §11 total
// order and §12 routing map), the §14 project identity (the [meta] name/version
// and the span module name), and the §14 entrypoint wiring ([entrypoint]). Each
// is itself a pure function of source, so the whole emission is.
Emit_Input :: struct {
	ast:        Ast,
	flat:       Flattened_Pipeline,
	module:     string, // the §15 path-derived module name carried in [functions] spans
	project:    Project_Identity,
	entrypoint: Entrypoint_Config,
}

// Emit_Error distinguishes the ways emission can refuse before it writes bytes:
// the source failed to compile (Parse/Gate/Typecheck/Contract/Flatten — the same
// checked-pipeline floors the test verb runs), or the entrypoint config failed —
// malformed, more than one block, or a pipeline/bindings reference the checked
// source does not declare (§07's dangling-reference obligation, enforced at
// emission so a [entrypoint] section can never name wiring the runtime cannot
// resolve). The emitter only serializes a fully-checked program (spec §09: the
// artifact is the checked AST), so a source that does not compile yields no
// artifact.
Emit_Error :: enum {
	None,
	Parse_Failed,
	Gate_Failed,
	Typecheck_Failed,
	Contract_Failed,
	Flatten_Failed,
	Entrypoint_Failed,
}

// stage_emit is the source → artifact seam: it runs the full checked pipeline
// (lex → parse → gates → typecheck → contracts → flatten) over one project
// source, parses the §14 entrypoint config through the one entrypoints
// production and validates its references against the checked AST, then bundles
// the checked AST, flattened pipeline, §14 project identity, and selected
// entrypoint into an Emit_Input and serializes it. Emission is a pure function
// of the three inputs — the source bytes, the project identity, and the
// entrypoint config text — so two calls on the same inputs are byte-identical.
// A source that fails any checked-pipeline floor returns the matching
// Emit_Error and no bytes.
stage_emit :: proc(
	source: string,
	module: string,
	project: Project_Identity,
	entrypoint_fcfg: string,
	allocator := context.allocator,
) -> (artifact: string, err: Emit_Error) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return "", .Parse_Failed
	}
	if stage_gates(ast) != .None {
		return "", .Gate_Failed
	}
	typed, type_err := stage_typecheck(ast)
	if type_err != .None {
		return "", .Typecheck_Failed
	}
	if stage_contracts(typed).err != .None {
		return "", .Contract_Failed
	}
	verdict := stage_flatten(typed)
	if verdict.err != .None {
		return "", .Flatten_Failed
	}
	entrypoints, ep_err := parse_entrypoints_fcfg(entrypoint_fcfg)
	if ep_err != .None {
		return "", .Entrypoint_Failed
	}
	if validate_entrypoints(entrypoints, ast) != .None {
		return "", .Entrypoint_Failed
	}
	entrypoint, sel_err := select_entrypoint(entrypoints)
	if sel_err != .None {
		return "", .Entrypoint_Failed
	}
	input := Emit_Input {
		ast        = ast,
		flat       = verdict.flat,
		module     = module,
		project    = project,
		entrypoint = entrypoint,
	}
	return emit_artifact(input, allocator), .None
}

// emit_artifact serializes the checked program to the versioned artifact bytes
// (docs/artifact-format.md). It writes the version stamp — the magic then the
// current ARTIFACT_SCHEMA_VERSION, the single compatibility gate — then every
// section in the fixed order, each as a `[name N]` header followed by its
// records. The returned string is the whole artifact, terminated by a single
// trailing '\n' like every other line — byte-identical across emissions by
// construction.
emit_artifact :: proc(input: Emit_Input, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	emit_line(&b, ARTIFACT_MAGIC, " ", encode_int(ARTIFACT_SCHEMA_VERSION, context.temp_allocator))

	emit_meta(&b, input.project)
	emit_enums(&b, input.ast)
	emit_data(&b, input.ast)
	emit_signals(&b, input.ast)
	emit_things(&b, input.ast)
	emit_functions(&b, input.ast, input.module)
	emit_behaviors(&b, input.ast, input.flat)
	emit_pipeline_flattened(&b, input.flat)
	emit_signal_routing(&b, input.flat)
	emit_setup(&b, input.ast)
	emit_bindings(&b, input.ast)
	emit_entrypoint(&b, input.entrypoint)

	return strings.to_string(b)
}

// emit_line writes the concatenation of parts then the single LF terminator the
// format mandates (docs/artifact-format.md §2.1). It is the one place a line
// ends, so every record is exactly one '\n'-terminated line.
emit_line :: proc(b: ^strings.Builder, parts: ..string) {
	for part in parts {
		strings.write_string(b, part)
	}
	strings.write_byte(b, '\n')
}

// emit_header writes a `[name N]` section header (docs/artifact-format.md §2.1):
// the section name and its exact top-level record count. A reader re-derives N
// by counting lead lines and refuses a mismatch, so N must equal the records
// that follow.
emit_header :: proc(b: ^strings.Builder, name: string, count: int) {
	strings.write_byte(b, '[')
	strings.write_string(b, name)
	strings.write_byte(b, ' ')
	strings.write_int(b, count)
	emit_line(b, "]")
}

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

// emit_enums writes one record per enum in source-declaration order, each
// followed by one `variant` line per variant. KIND is the §03 §4 role kind
// (Axis/Button/…) or `-` for none; pong's variants are all `unit` (no payload).
emit_enums :: proc(b: ^strings.Builder, ast: Ast) {
	emit_header(b, "enums", len(ast.enums))
	for decl in ast.enums {
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

// emit_data writes one `data` record per declaration in source order, each
// followed by its fields. `mut` is `true` for a `mut data` (§03 §7) — pong has
// none, so it is always `false` here. After the user data decls, it emits any
// SYNTHESIZED engine-type data decls (docs/artifact-format.md §8): an engine
// record the source uses by default but has no user `data` for (yard's Settings).
// The runtime's composite-default decode resolves a `Settings(…)` default's nested
// field types against the §8 data decl, so the projection must be present in
// [data]; the funpack surface owns the engine type, the artifact carries its
// representable projection. The synthesized decls land in a fixed order after the
// user decls, so the section stays byte-deterministic.
emit_data :: proc(b: ^strings.Builder, ast: Ast) {
	synthetic := synthetic_data_decls(ast)
	emit_header(b, "data", len(ast.datas) + len(synthetic))
	for decl in ast.datas {
		strings.write_string(b, "data ")
		strings.write_string(b, decl.name)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(decl.fields))
		emit_line(b, " false")
		emit_fields(b, decl.fields)
	}
	for decl in synthetic {
		emit_synthetic_data(b, decl)
	}
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
// require the artifact to carry (docs/artifact-format.md §8). The current case: a
// Settings default (`Settings.defaults()`) needs the §8 Settings projection in
// [data] so the runtime decode resolves its nested field types — AND its nested
// AccessOpts sub-record's projection, because the Settings default carries an
// `access=AccessOpts(reduce_motion=false)` token whose `reduce_motion` field type
// the runtime resolves against AccessOpts' own §8 decl (a nested composite default
// decodes each field against its declared type, so the nested ctor MUST have a data
// decl or its Bool would lift to a bare string token, not a Bool). Both are emitted
// iff some thing/data/signal field declares Settings, so a source that never uses
// Settings emits no extra data record (pong/snake/hunt are unchanged). AccessOpts
// follows Settings in a fixed order, so the section stays byte-deterministic.
synthetic_data_decls :: proc(ast: Ast) -> []Synthetic_Data {
	out := make([dynamic]Synthetic_Data, 0, 2, context.temp_allocator)
	if uses_engine_type(ast, "Settings") {
		append(&out, Synthetic_Data{name = "Settings", fields = SETTINGS_DATA_FIELDS})
		append(&out, Synthetic_Data{name = "AccessOpts", fields = ACCESS_OPTS_DATA_FIELDS})
	}
	return out[:]
}

// uses_engine_type reports whether any thing/singleton/data/signal field declares
// the given engine type name as its field type — the trigger for synthesizing
// that engine type's §8 data projection. It reads the field TYPE spelling
// (type_ref_string), so `Settings` matches the bare engine type a singleton field
// holds (yard's `Menu.settings: Settings`).
uses_engine_type :: proc(ast: Ast, type_name: string) -> bool {
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

// emit_signals writes one `signal` record per declaration in source order, same
// field grammar as [data] but with no `mut` flag (a signal is per-tick, never
// mutated, §06 §5).
emit_signals :: proc(b: ^strings.Builder, ast: Ast) {
	emit_header(b, "signals", len(ast.signals))
	for decl in ast.signals {
		strings.write_string(b, "signal ")
		strings.write_string(b, decl.name)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(decl.fields))
		emit_line(b, "")
		emit_fields(b, decl.fields)
	}
}

// emit_things writes one `thing` record per thing/singleton in source order,
// each followed by its `@gtag` set and its blackboard schema. SINGLETON is
// `true` for a `singleton` (§06 §2); pong models the score as a `thing`, so all
// three are `false`.
emit_things :: proc(b: ^strings.Builder, ast: Ast) {
	emit_header(b, "things", len(ast.things))
	for decl in ast.things {
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
		emit_fields(b, decl.fields)
	}
}

// emit_fields writes one `field` line per field (docs/artifact-format.md §6):
// the field name, its syntactic type (the Type_Ref spelling — `Fixed`,
// `View[Paddle]`, `[Goal]`), and its default. The default is `-` for a required
// field or `=ENCODED` for a defaulted one (§03 §1).
emit_fields :: proc(b: ^strings.Builder, fields: []Field_Decl) {
	for field in fields {
		emit_line(b, "field ", field.name, " ", type_ref_string(field.type), " ", field_default_token(field))
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

// ───────────────────────────────────────────────────────────────────────────
// [functions] — pure helpers, module constants, bindings/setup heads
// (docs/artifact-format.md §9)
// ───────────────────────────────────────────────────────────────────────────

// emit_functions writes one record per module-level fn, module-level `let`
// (a `const`), the `bindings()` fn, and the `setup()` fn. Each record carries
// its signature, a `body_count` of top-level statement subtrees, and the span;
// the `param` lines and the body `node` run (§2.7) follow. Records are grouped
// by KIND in the fixed order fn-helpers → const → bindings → startup, each group
// in source-declaration order — the deterministic order
// (docs/artifact-format.md §9) the golden fixture and the runtime's positional
// reader both rely on.
emit_functions :: proc(b: ^strings.Builder, ast: Ast, module: string) {
	records := function_records(ast)
	emit_header(b, "functions", len(records))
	for record in records {
		emit_function_record(b, record, module)
	}
}

// Function_Record is one [functions] entry, normalized across the four kinds a
// function record carries: a top-level fn, a module-level const (`let`), the
// bindings head, and the setup head. kind is the artifact KIND token; params is
// empty for a const; body is the top-level statement subtrees (a const/bindings/
// setup body is a single `return` statement); line is the source line for the
// span.
Function_Record :: struct {
	name:        string,
	kind:        string,
	params:      []Param_Decl,
	return_type: Type_Ref,
	body:        []Statement,
	line:        int,
}

// function_records collects the module's fns and module-level `let` constants
// into the [functions] order: grouped by KIND (fn-helper → const → bindings →
// startup), each group in source-declaration order (docs/artifact-format.md §9).
// The `bindings`/`setup` fns are ordinary fns whose names select the
// `bindings`/`startup` KIND, so they sort into their own trailing groups; every
// other fn is a `fn` helper, the consts come from the separate `let` slice.
function_records :: proc(ast: Ast) -> []Function_Record {
	records := make([dynamic]Function_Record, 0, len(ast.fns) + len(ast.lets), context.temp_allocator)
	append_fn_records(&records, ast, "fn")
	for decl in ast.lets {
		append(&records, Function_Record{
			name        = decl.name,
			kind        = "const",
			params      = nil,
			return_type = decl.type,
			body        = const_body(decl),
			line        = decl.line,
		})
	}
	append_fn_records(&records, ast, "bindings")
	append_fn_records(&records, ast, "startup")
	return records[:]
}

// append_fn_records appends the module fns whose KIND matches `kind`, in source-
// declaration order — the helper-fn, bindings, and startup groups of the
// [functions] order (docs/artifact-format.md §9). ast.fns is already in source
// order, so each group's relative order is preserved.
append_fn_records :: proc(records: ^[dynamic]Function_Record, ast: Ast, kind: string) {
	for fn in ast.fns {
		if function_kind(fn.name) != kind {
			continue
		}
		append(records, Function_Record{
			name        = fn.name,
			kind        = kind,
			params      = fn.params,
			return_type = fn.return_type,
			body        = fn.body,
			line        = fn.line,
		})
	}
}

// function_kind maps a fn name to its artifact KIND (docs/artifact-format.md
// §9): the §23 `bindings()` head is `bindings`, the §06 `setup()` Startup head
// is `startup`, every other top-level fn is a plain `fn` helper.
function_kind :: proc(name: string) -> string {
	switch name {
	case "bindings":
		return "bindings"
	case "setup":
		return "startup"
	}
	return "fn"
}

// const_body wraps a module-level `let`'s initializer as a single `return`
// statement so a const's body serializes through the same statement-subtree
// path as a fn body (docs/artifact-format.md §9: a const initializer is a single
// top-level `return` subtree, body_count 1).
const_body :: proc(decl: Let_Decl_Node) -> []Statement {
	body := make([]Statement, 1, context.temp_allocator)
	body[0] = Return_Node{value = decl.value}
	return body
}

// emit_function_record writes one [functions] record: the `function` lead line
// (name, KIND, param_count, return type, body_count, span), then the `param`
// lines and the body `node` run (§2.7). body_count is the count of top-level
// statement subtrees, one per source statement line.
emit_function_record :: proc(b: ^strings.Builder, record: Function_Record, module: string) {
	strings.write_string(b, "function ")
	strings.write_string(b, record.name)
	strings.write_byte(b, ' ')
	strings.write_string(b, record.kind)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(record.params))
	strings.write_string(b, " return:")
	strings.write_string(b, type_ref_string(record.return_type))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(record.body))
	strings.write_string(b, " span:")
	strings.write_string(b, module)
	strings.write_byte(b, ':')
	strings.write_int(b, record.line)
	emit_line(b, "")
	for param in record.params {
		emit_line(b, "param ", param.name, " ", type_ref_string(param.type))
	}
	emit_body(b, record.body)
}

// ───────────────────────────────────────────────────────────────────────────
// [behaviors] — transitions keyed to their pipeline stage
// (docs/artifact-format.md §10)
// ───────────────────────────────────────────────────────────────────────────

// emit_behaviors writes one record per behavior in source-declaration order,
// each carrying its stage slot, the conferred contract, its `@gtag` set, the
// reserved `step` signature (params/emit), and the step body. The stage a
// behavior occupies is read from the flattened pipeline (the step whose behavior
// is this one); the contract is the §06 §6 slot contract that stage confers.
emit_behaviors :: proc(b: ^strings.Builder, ast: Ast, flat: Flattened_Pipeline) {
	emit_header(b, "behaviors", len(ast.behaviors))
	for decl in ast.behaviors {
		stage := behavior_stage(flat, decl.name)
		contract := contract_name(slot_of_stage(stage))
		emits := behavior_emits(decl)
		strings.write_string(b, "behavior ")
		strings.write_string(b, decl.name)
		strings.write_string(b, " on:")
		strings.write_string(b, decl.target)
		strings.write_string(b, " stage:")
		strings.write_string(b, stage)
		strings.write_string(b, " contract:")
		strings.write_string(b, contract)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(decl.gtags))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(decl.step.params))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(emits))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(decl.step.body))
		emit_line(b, "")
		emit_gtags(b, decl.gtags)
		for param in decl.step.params {
			emit_line(b, "param ", param.name, " ", type_ref_string(param.type))
		}
		for emit in emits {
			emit_line(b, "emit ", emit)
		}
		emit_body(b, decl.step.body)
	}
}

// behavior_stage returns the pipeline stage a behavior occupies — the stage
// name of the flattened step whose behavior is this one (docs/artifact-format.md
// §10: the slot confers the contract). A behavior referenced in [behaviors] is
// always scheduled, so the lookup always finds a step.
behavior_stage :: proc(flat: Flattened_Pipeline, name: string) -> string {
	for step in flat.order {
		if step.behavior == name {
			return step.stage
		}
	}
	return ""
}

// contract_name maps a pipeline slot to its §06 §6 contract token
// (docs/artifact-format.md §10): Update/Render/Startup/Ui/Audio. The slot is the
// engine-closed contract a stage confers, so the token is the slot's name.
contract_name :: proc(slot: Pipeline_Slot) -> string {
	switch slot {
	case .Update:
		return "Update"
	case .Render:
		return "Render"
	case .Startup:
		return "Startup"
	case .Ui:
		return "Ui"
	case .Audio:
		return "Audio"
	}
	return "Update"
}

// behavior_emits returns the behavior step's return-side emissions
// (docs/artifact-format.md §10): its return is its writes (§06 §3). Each pong
// behavior writes exactly one value — its blackboard, a signal list, or a
// command list — so the emit set is the single rendered return type.
behavior_emits :: proc(decl: Behavior_Node) -> []string {
	emits := make([]string, 1, context.temp_allocator)
	emits[0] = type_ref_string(decl.step.return_type)
	return emits
}

// ───────────────────────────────────────────────────────────────────────────
// [pipeline_flattened] / [signal_routing] — the derived schedule
// (docs/artifact-format.md §11, §12)
// ───────────────────────────────────────────────────────────────────────────

// emit_pipeline_flattened writes the one total order (docs/artifact-format.md
// §11): one `step` line per flattened ordinal, in order, each naming its stage
// and behavior. The order is stage_flatten's depth-first flattening — the order
// the runtime folds — so the ordinals are contiguous and gap-free.
emit_pipeline_flattened :: proc(b: ^strings.Builder, flat: Flattened_Pipeline) {
	emit_header(b, "pipeline_flattened", len(flat.order))
	for step in flat.order {
		strings.write_string(b, "step ")
		strings.write_int(b, step.ordinal)
		strings.write_string(b, " stage:")
		strings.write_string(b, step.stage)
		emit_line(b, " behavior:", step.behavior)
	}
}

// emit_signal_routing writes the producer(s) → consumer(s) map
// (docs/artifact-format.md §12): one `route` record per signal that is emitted
// or consumed anywhere, in signal-declaration order, each followed by its
// producer and consumer endpoints keyed by flattened ordinal. The routes come
// straight from stage_flatten, already in declaration order.
emit_signal_routing :: proc(b: ^strings.Builder, flat: Flattened_Pipeline) {
	emit_header(b, "signal_routing", len(flat.routes))
	for route in flat.routes {
		strings.write_string(b, "route ")
		strings.write_string(b, route.signal)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(route.producers))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(route.consumers))
		emit_line(b, "")
		for producer in route.producers {
			emit_endpoint(b, "producer", producer)
		}
		for consumer in route.consumers {
			emit_endpoint(b, "consumer", consumer)
		}
	}
}

// emit_endpoint writes one routing endpoint line (docs/artifact-format.md §12):
// `producer`/`consumer ORDINAL behavior:NAME` — the flattened-order ordinal and
// the behavior at that step, so closure is a forward-flow check over ordinals.
emit_endpoint :: proc(b: ^strings.Builder, role: string, endpoint: Signal_Endpoint) {
	strings.write_string(b, role)
	strings.write_byte(b, ' ')
	strings.write_int(b, endpoint.ordinal)
	emit_line(b, " behavior:", endpoint.behavior)
}

// ───────────────────────────────────────────────────────────────────────────
// [setup] — the Startup [Spawn] program (docs/artifact-format.md §13)
// ───────────────────────────────────────────────────────────────────────────

// emit_setup writes the Startup spawn batch (docs/artifact-format.md §13): one
// `spawn THING field_count` per spawn in the setup() body's source list order, each
// followed by one `set FIELD =ENCODED` per supplied field. The batch is fully
// CONSTANT-FOLDED at compile time (setup_eval.odin resolve_setup_spawns) — yard's
// setup() spawns through user helper fns (`crate_at(…)`, `wall_body(size)`) and
// constructs engine Body records with §11 §2 defaults left implicit, so the emitter
// inlines those calls and applies the omitted defaults BEFORE encoding. A scalar/
// enum/Vec2 field keeps its §13 form; a composite engine record (a Body) and a list
// take the §6 single-token nested form (encode_setup_field_value). The runtime then
// spawns the initial population without interpreting an initializer.
emit_setup :: proc(b: ^strings.Builder, ast: Ast) {
	spawns := resolve_setup_spawns(ast)
	emit_header(b, "setup", len(spawns))
	for spawn in spawns {
		strings.write_string(b, "spawn ")
		strings.write_string(b, spawn.type_name)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(spawn.fields))
		emit_line(b, "")
		for field in spawn.fields {
			emit_line(b, "set ", field.name, " =", encode_setup_field_value(field.value))
		}
	}
}

// single_return_list returns the list a body's single `return [list]` statement
// returns. The setup() and (read-side) bindings shapes are a lone `return` of a
// list/builder expression; this reads that list for the [setup] walk.
single_return_list :: proc(body: []Statement) -> (list: ^List_Expr, ok: bool) {
	if len(body) != 1 {
		return nil, false
	}
	ret, is_return := body[0].(Return_Node)
	if !is_return {
		return nil, false
	}
	list, ok = ret.value.(^List_Expr)
	return
}

// vec2_component_bits reads a named Fixed component out of a Vec2 record literal
// (docs/artifact-format.md §13: a Vec2 setup value is `vec2 x_bits y_bits`). The
// gate stage proved the setup record well-typed, so the named component is a
// Fixed literal.
vec2_component_bits :: proc(record: ^Record_Expr, name: string) -> Fixed {
	for field in record.fields {
		if field.name == name {
			if lit, ok := field.value.(^Fixed_Lit_Expr); ok {
				return lit.bits
			}
		}
	}
	return Fixed(0)
}

// ───────────────────────────────────────────────────────────────────────────
// [bindings] — the §23 axis/button source map (docs/artifact-format.md §14)
// ───────────────────────────────────────────────────────────────────────────

// emit_bindings writes the resolved binding table (docs/artifact-format.md §14):
// one `bind` record per `.axis(…)`/`.button(…)` call in source-call order, the
// only device-aware data in the artifact. Each carries the analog/digital kind,
// the PlayerId, the targeted enum variant, and the device source as the builder
// call that produced it.
emit_bindings :: proc(b: ^strings.Builder, ast: Ast) {
	binds := binding_calls(ast)
	emit_header(b, "bindings", len(binds))
	for bind in binds {
		strings.write_string(b, "bind ")
		strings.write_string(b, bind.kind)
		strings.write_byte(b, ' ')
		strings.write_string(b, bind.player)
		strings.write_byte(b, ' ')
		strings.write_string(b, bind.action)
		emit_line(b, " source:", bind.source)
	}
}

// Binding_Record is one resolved binding (docs/artifact-format.md §14): the
// analog/digital kind (`axis`/`button`), the PlayerId case (`P1`), the targeted
// action variant (`Steer::Move`), and the device source rendered as its builder
// call (`keys_axis(Key::W,Key::S)`).
Binding_Record :: struct {
	kind:   string,
	player: string,
	action: string,
	source: string,
}

// binding_calls walks the bindings() body's builder chain and lifts each
// `.axis(player, action, source)` / `.button(…)` call into a record, in
// source-call order. The body is `Bindings.empty().axis(…).axis(…)…`, a
// left-nested call/member chain, so the outermost call is the last binding; the
// walk recurses to the base first, then records this call, recovering source
// order (bindings stack, §23 §3).
binding_calls :: proc(ast: Ast) -> []Binding_Record {
	for fn in ast.fns {
		if fn.name != "bindings" {
			continue
		}
		if len(fn.body) != 1 {
			return nil
		}
		ret, is_return := fn.body[0].(Return_Node)
		if !is_return {
			return nil
		}
		binds := make([dynamic]Binding_Record, 0, 4, context.temp_allocator)
		collect_binding_calls(ret.value, &binds)
		return binds[:]
	}
	return nil
}

// collect_binding_calls walks a binding builder chain inner-to-outer, appending
// one record per `.axis(…)`/`.button(…)` call so the output is in source-call
// order (docs/artifact-format.md §14). It recurses into the call's receiver
// (the prior link) before recording the current call, so `.empty()` and any
// non-binding link contribute nothing and the binding calls land in order. A
// key-LIST button source (`[Key::W, Key::Up]`) SPREADS into one record per
// listed key — stacking is §23 §3 semantics, so each key is its own bind — and
// a builder-call source lowers through lower_source_call into the closed §14
// source-form set (schema v3).
collect_binding_calls :: proc(expr: Expr, binds: ^[dynamic]Binding_Record) {
	call, is_call := expr.(^Call_Expr)
	if !is_call {
		return
	}
	member, is_member := call.callee.(^Member_Expr)
	if !is_member {
		return
	}
	collect_binding_calls(member.receiver, binds)
	kind := binding_kind(member.member)
	if kind == "" {
		return
	}
	if len(call.args) != 3 {
		return
	}
	player := variant_case(call.args[0])
	action := variant_path(call.args[1])
	if list, is_list := call.args[2].(^List_Expr); is_list {
		// One stacked bind per listed device code: `[Key::W, Key::Up]` becomes
		// `source:key(Key::W)` + `source:key(Key::Up)` (§23 §3 stacking). An
		// element whose enum is not a device set contributes nothing — the
		// checker owns refusing it; the emitter never emits an empty source.
		for element in list.elements {
			source := device_code_source(element)
			if source == "" {
				continue
			}
			append(binds, Binding_Record{kind = kind, player = player, action = action, source = source})
		}
		return
	}
	append(binds, Binding_Record{
		kind   = kind,
		player = player,
		action = action,
		source = lower_source_call(call.args[2]),
	})
}

// device_code_source renders one spread key-list element as its single-code
// §14 source form: `Key::W` → `key(Key::W)`, `PadButton::A` → `pad(PadButton::A)`.
// The helper name comes from the device enum, so the artifact records the same
// builder-call spelling an explicit `key(…)` source would produce. A non-device
// element returns "" and is skipped by the caller.
device_code_source :: proc(expr: Expr) -> string {
	variant, is_variant := expr.(^Variant_Expr)
	if !is_variant {
		return ""
	}
	helper := ""
	switch variant.type_name {
	case "Key":
		helper = "key"
	case "PadButton":
		helper = "pad"
	case:
		return ""
	}
	return strings.concatenate({helper, "(", variant.type_name, "::", variant.variant, ")"}, context.temp_allocator)
}

// lower_source_call lowers a §23 §3 builder-call source into its ratified §14
// source form (schema v3): `wasd()` lowers to the 2D digital quad
// `keys_quad(Key::A,Key::D,Key::W,Key::S)` — argument order (neg_x, pos_x,
// neg_y, pos_y), up = neg_y in the y-down draw space, matching SDL stick
// polarity — and every already-canonical helper (key/pad/keys_axis/stick/
// stick_x/stick_y) renders verbatim through builder_call_string. `stick(Stick)`
// is deliberately NOT spread into stick_x/stick_y: those are 1D forms feeding
// the action's single 1D value slot, while `stick` is a first-class 2D source
// the runtime folds as both components (ADR
// 2026-06-06-binding-source-lowering-2d-quad-and-stick).
lower_source_call :: proc(expr: Expr) -> string {
	call, is_call := expr.(^Call_Expr)
	if !is_call {
		return ""
	}
	if name, is_name := call.callee.(^Name_Expr); is_name {
		if name.name == "wasd" && len(call.args) == 0 {
			return "keys_quad(Key::A,Key::D,Key::W,Key::S)"
		}
	}
	return builder_call_string(expr)
}

// binding_kind maps the builder method to the artifact bind kind
// (docs/artifact-format.md §14): `.axis` → `axis`, `.button` → `button`; any
// other member (`.empty`) is not a binding and returns "".
binding_kind :: proc(member: string) -> string {
	switch member {
	case "axis":
		return "axis"
	case "button":
		return "button"
	}
	return ""
}

// variant_case renders just the variant case of a `Type::Case` expression — the
// PLAYER field is the PlayerId case alone (`PlayerId::P1` → `P1`,
// docs/artifact-format.md §14).
variant_case :: proc(expr: Expr) -> string {
	if variant, ok := expr.(^Variant_Expr); ok {
		return variant.variant
	}
	return ""
}

// variant_path renders the full `Type::Case` of a variant expression — the
// ACTION field keeps its enum prefix (`Steer::Move`, docs/artifact-format.md
// §14).
variant_path :: proc(expr: Expr) -> string {
	if variant, ok := expr.(^Variant_Expr); ok {
		return strings.concatenate({variant.type_name, "::", variant.variant}, context.temp_allocator)
	}
	return ""
}

// builder_call_string renders a device-source builder call as compact text
// (docs/artifact-format.md §14): `keys_axis(Key::W,Key::S)`,
// `stick_y(Stick::Left)` — the callee name, then the parenthesized variant
// arguments with no interior spaces. The device names appear only here, never
// in sim logic (§23 §3).
builder_call_string :: proc(expr: Expr) -> string {
	call, is_call := expr.(^Call_Expr)
	if !is_call {
		return ""
	}
	name, is_name := call.callee.(^Name_Expr)
	if !is_name {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, name.name)
	strings.write_byte(&b, '(')
	for arg, i in call.args {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, variant_path(arg))
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// ───────────────────────────────────────────────────────────────────────────
// [entrypoint] — the runtime wiring (docs/artifact-format.md §15)
// ───────────────────────────────────────────────────────────────────────────

// emit_entrypoint writes the single entrypoint record (docs/artifact-format.md
// §15): the pipeline ↔ tick ↔ logical ↔ bindings wiring lifted from
// funpack_configs/entrypoints.fcfg (§14 §4), which a pipeline carries no
// configuration for. tick_hz is the integer Hz of the `60hz` tick; logical is
// the `WxH` draw-space extent in integer world units (§20 §3).
emit_entrypoint :: proc(b: ^strings.Builder, entrypoint: Entrypoint_Config) {
	emit_header(b, "entrypoint", 1)
	strings.write_string(b, "entrypoint ")
	strings.write_string(b, entrypoint.name)
	strings.write_string(b, " pipeline:")
	strings.write_string(b, entrypoint.pipeline)
	strings.write_string(b, " tick_hz:")
	strings.write_int(b, entrypoint.tick_hz)
	strings.write_string(b, " logical:")
	strings.write_int(b, entrypoint.logical_w)
	strings.write_byte(b, 'x')
	strings.write_int(b, entrypoint.logical_h)
	emit_line(b, " bindings:", entrypoint.bindings)
}
