// LL(1) statement-layer parser over the golden-file surface (spec §02,
// §06, §07): a file-leading @doc as the module doc, per-declaration @doc,
// @gtag, @todo, and §05 §5 debug directives, import in its three forms, the §06/§07 declaration
// layer (data/enum/thing/singleton/signal/behavior/pipeline, module-level
// let, and top-level fn), and test blocks. Every production opens with a
// unique keyword, so one token of lookahead selects it. Expressions route
// through the single parse_expression seam owned by the Pratt cascade
// (expr.odin). This stage produces an AST only — no name resolution and no
// typing (those live in the resolve and typecheck stages).
package funpack

Assert_Node :: struct {
	expr: Expr,
}

Let_Node :: struct {
	name:  string,
	value: Expr,
}

// Return_Node is the mandatory value-producing statement of a fn body
// (spec §02 §6): `return expr`. There is no implicit last-expression
// return.
Return_Node :: struct {
	value: Expr,
}

// If_Node is the early-return statement form a fn body uses (spec §02 §5):
// `if cond { return … }`. The body is the same statement sequence a fn
// body is, so a guarded block can hold its own let/return; the golden pong
// surface only uses the single-`return` shape. There is no `else` arm on
// the golden surface, so this statement form omits it.
If_Node :: struct {
	cond: Expr,
	body: []Statement,
}

// Statement is the closed body-statement set across test blocks and fn
// bodies: a test body is let/assert; a fn body is let/return with an
// optional `if` early-return guard. The union is shared so one
// parse_statement_seq drives both.
Statement :: union {
	Assert_Node,
	Let_Node,
	Return_Node,
	If_Node,
}

Import_Node :: struct {
	segments: []string, // the dotted path as written, excluding any group
	members:  []string, // brace-group members; nil for the groupless forms
	line:     int,      // 1-based source line of the `import` keyword (artifact-format §9 span provenance) — the import-resolution typecheck arms' anchor
	col:      int,      // 1-based column of the `import` keyword's first byte within its line (§15 diagnostic provenance)
}

Test_Node :: struct {
	name: string,
	doc:  string, // the @doc directive preceding this test ("" when absent)
	body: []Statement,
	line: int,    // 1-based source line of the `test` keyword (artifact-format §9 span provenance)
	// probes carries the §05 §5 debug prefix that preceded the test block. A
	// test is NOT in the §28 §4 On-table — no debug probe is admitted on it —
	// so this field exists only to make a mis-placed probe VISIBLE: the .Test
	// arm of parse_declaration carries the pending probes here instead of
	// dropping them silently, and the §28 §4 placement gate
	// (probe_placement_gate.odin) names the test (Probe_Wrong_Placement). Empty
	// on the ordinary probe-free test.
	probes: []Debug_Probe,
}

// Type_Ref is the parse-only syntactic type the declaration grammar
// records: a bare name (`Fixed`, `Side`), a generic application
// (`View[Paddle]`, `Option[Side]`), a list (`[Goal]`, `[Spawn]`), a tuple
// (`(Rng, [Spawn])` — the §04 §1 `(value, next_rng)` return pair), or a
// function type (`fn(T) -> Bool` — the §02 §3 FnType a combinator parameter
// declares). It is purely structural — no resolution to the checker's
// semantic Type (type.odin) happens here; that is the resolve stage's job. A
// list is modeled as the head "[]" with one argument, a tuple as the head
// "()" with its positional element types as args, and a function type as the
// head "fn" whose args are the parameter types followed by the result — the
// LAST arg is always the result, so `fn() -> R` has exactly one arg. Every
// parameterized form thus shares one node shape; the sentinel heads can
// never collide with a declared name (type names are UPPER_IDENT).
Type_Ref :: struct {
	name: string,     // the head name; "[]" list, "()" tuple, "fn" function type
	args: []Type_Ref, // generic / list / tuple / fn arguments; empty for a bare name
}

// Field_Decl is one `name: Type` (or `name: Type = default`) entry in a
// data/thing/singleton/signal body. has_default distinguishes a defaulted
// field (spec §03 §1) from a required one; default is meaningless when
// has_default is false. migrate is the field's §05 §6 @migrate prefix —
// rename/retype evolution metadata only a `data` field may carry (the parser
// rejects it elsewhere); meaningless when has_migrate is false, mirroring
// has_default. probes carries the field's §05 §5 debug prefix — the §28 §4
// On-table admits a `@watch(expr)` on a `data` field (fire watch_fired when
// the value changes); the grammar puts Annotation* on FieldDecl (fun.ebnf §5),
// and the field carries the parsed probe the same way a declaration does. The
// On-table admits ONLY @watch here, so parse_field_list rejects every other
// debug directive (and every non-@migrate/@watch @-form) with a keyed verdict,
// the @migrate field-body mold. Empty when the field carries no probe.
Field_Decl :: struct {
	name:        string,
	type:        Type_Ref,
	default:     Expr,
	has_default: bool,
	migrate:     Migrate_Node,
	has_migrate: bool,
	probes:      []Debug_Probe,
}

// Variant_Decl is one enum variant (spec §03 §2): plain (`Left`),
// tuple-payload (`MoveTo(Vec2)`), or struct-payload (`Rgb{ r: Fixed, … }`).
// The payload shape is the closed Variant_Payload tag; tuple args live in
// `tuple`, struct fields in `fields`. doc is the variant's §05 §1 @doc — the
// ONE directive a variant admits (§05: "each `Draw` variant carries a @doc";
// every other directive names a non-variant target, so parse_enum rejects it
// with a keyed wrong-target verdict); "" when the variant carries none.
Variant_Payload :: enum {
	Plain,  // `Variant`
	Tuple,  // `Variant(T, …)`
	Struct, // `Variant{ f: T, … }`
}

Variant_Decl :: struct {
	name:    string,
	payload: Variant_Payload,
	tuple:   []Type_Ref,    // Tuple payload: positional types
	fields:  []Field_Decl,  // Struct payload: named fields
	doc:     string,        // §05 §1 variant-level @doc; "" when absent
}

// Param_Decl is one `name: Type` parameter of a fn or the reserved
// behavior `step` (spec §06 §3: a behavior's params are its reads).
Param_Decl :: struct {
	name: string,
	type: Type_Ref,
}

// Let_Decl_Node is a module-level constant (spec §02 §7): `let NAME: T =
// expr`, distinct from the test-body Let_Node in that it always carries an
// explicit type ascription.
Let_Decl_Node :: struct {
	name:    string,
	type:    Type_Ref,
	value:   Expr,
	doc:     string,
	gtags:   []string, // @gtag("…") labels attached to this declaration
	probes:  []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:   []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	exposed: bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:    int, // 1-based source line of the `let` keyword (artifact-format §9 span provenance)
}

Data_Node :: struct {
	name:   string,
	kind:   string, // the `Name: Kind` ascription (§03 §4); "" when absent
	// type_params is the §03 §3 generic declaration header (`data Ref[T]`,
	// fun.ebnf §4 TypeParams) — the declared type-parameter names in source
	// order; nil when the declaration has none. Each name is a binder the body's
	// field types reference as ordinary Type_Refs (`data Ref[T] { id: Id }`,
	// `data Choice[T] { value: T }`); resolving those references against the
	// binder is a downstream stage's job. Generics exist only on engine/stdlib
	// containers (§03 §3: user code authors no generics); that gate is likewise
	// downstream, not the parser's — the same split `extern` keeps.
	type_params: []string,
	fields: []Field_Decl,
	doc:    string,
	gtags:  []string,
	probes: []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:  []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	// migrate is the §05 §6 declaration-level @migrate — a RENAMED TYPE
	// declaration (`@migrate(from: "OldName") data NewName { … }`). Rename
	// form only by construction (the parser rejects a decl-level `with:` as
	// Migrate_Wrong_Target); meaningless when has_migrate is false.
	migrate:     Migrate_Node,
	has_migrate: bool,
	exposed:     bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:        int, // 1-based source line of the `data` keyword (artifact-format §9 span provenance)
}

Enum_Node :: struct {
	name:     string,
	kind:     string, // the enum-as-role kind (`enum Steer: Axis`); "" when absent
	// type_params is the §03 §3 generic declaration header (`enum Option[T]`,
	// `enum Result[T, E]` — fun.ebnf §4 TypeParams); nil when absent. See
	// Data_Node.type_params for the binder-scope and engine-only-gate split.
	type_params: []string,
	variants: []Variant_Decl,
	doc:      string,
	gtags:    []string,
	probes:   []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:    []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	exposed:  bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:     int, // 1-based source line of the `enum` keyword (artifact-format §9 span provenance)
}

// Thing_Node carries both `thing` and `singleton` (spec §06 §1–2): a
// singleton is a guaranteed-single-row thing, told apart here only by
// is_singleton so downstream stages key the row-count-1 constraint off one
// flag.
Thing_Node :: struct {
	name:         string,
	is_singleton: bool,
	fields:       []Field_Decl,
	doc:          string,
	gtags:        []string,
	probes:       []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:        []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	exposed:      bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:         int, // 1-based source line of the `thing`/`singleton` keyword (artifact-format §9 span provenance)
}

Signal_Node :: struct {
	name:    string,
	fields:  []Field_Decl,
	doc:     string,
	gtags:   []string,
	probes:  []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:   []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	exposed: bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:    int, // 1-based source line of the `signal` keyword (artifact-format §9 span provenance)
}

// Fn_Node is a top-level function or a behavior's reserved `step` entry
// point (spec §06 §3). The body is the shared Statement sequence
// (let/return/if). return_type is the syntactic `-> R` ascription.
Fn_Node :: struct {
	name:         string,
	params:       []Param_Decl,
	return_type:  Type_Ref,
	body:         []Statement,
	doc:          string,
	gtags:        []string,
	probes:       []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:        []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	exposed:      bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:         int, // 1-based source line of the `fn` keyword (artifact-format §9 span provenance)
	// is_extern marks a §02/§26 `extern fn` — a body-less native-boundary
	// declaration whose definition lives outside funpack (the §17 seam's
	// `extern fn arena() -> Arena` accessors). An extern fn carries a signature
	// (params + return_type) but no body, so the body-typing pass skips it: its
	// implementation is the engine's, not the source's.
	is_extern:    bool,
	// holed marks a §05 §2 typed hole standing in body position
	// (grammar/fun.ebnf §7: FnBody ::= Block | StubExpr): `fn f(…) -> R
	// @stub(T)`. A holed fn has an empty body; callers typecheck against the
	// declared hole_type, the index tracks the hole, and release refuses to
	// ship it (§29 §4) — those stages key off this flag. fallback is the
	// optional `@stub(T, fallback)` approximation expression; has_fallback
	// distinguishes the two-argument form (fallback is meaningless when
	// has_fallback is false, mirroring Field_Decl.has_default).
	holed:        bool,
	hole_type:    Type_Ref,
	fallback:     Expr,
	has_fallback: bool,
}

// Extern_Type_Node is a §02 §7 / §26 §2 `extern type Name` declaration: an
// engine-native OPAQUE type whose representation and ABI are
// compiler/runtime-internal, never observable in `.fun`. It carries no
// funpack-visible fields and no body — the name plus the shared directive
// surface IS the whole declaration (transparent `data` is the preferred
// spelling for engine types, §26 §2). Stdlib/privileged-context only by
// doctrine (§26 §2: extern is a compile error in an ordinary project); that
// gate is a downstream stage's job, not the parser's — the same split
// `extern fn` keeps.
Extern_Type_Node :: struct {
	name:    string,
	// type_params is the §03 §3 generic declaration header (`extern type
	// View[T]` — fun.ebnf §8: ExternType ::= 'type' UPPER_IDENT TypeParams?);
	// nil when absent. The opaque type stays body-less either way — the header
	// only declares the container's parameters (§26 §2 View/Theme). See
	// Data_Node.type_params for the binder-scope and engine-only-gate split.
	type_params: []string,
	doc:     string,
	gtags:   []string,
	probes:  []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:   []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	exposed: bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:    int, // 1-based source line of the `extern` keyword (artifact-format §9 span provenance)
}

// Index_Directive_Kind is the closed §05 §3 data-plane index directive pair —
// `@index(Thing.field)` for reverse/key lookup, `@spatial(Thing.field)` for
// the built-in radius/nearest queries. The set is closed like every directive
// category (spec §05): adding a member is a spec change, never a parser
// convenience.
Index_Directive_Kind :: enum {
	Index,   // @index(Thing.field) — engine-maintained reverse/key lookup
	Spatial, // @spatial(Thing.field) — deterministic radius/nearest queries
}

// Index_Directive is one parsed `@index(Thing.field)` / `@spatial(Thing.field)`
// (spec §05 §3, §08 §3) carried on the query declaration it prefixes — the §08
// §3 placement ("a query needing an index must declare it"); the spec names no
// other admitted target, so any other declaration consuming one is the named
// Index_Wrong_Target verdict. The argument is the lexical-core §5 FieldPath
// (`UPPER_IDENT '.' LOWER_IDENT`), recorded as written; that the path names a
// declared thing and one of its fields is the typecheck stage's job
// (check_index_paths), mirroring @migrate's parse/typecheck split.
Index_Directive :: struct {
	kind:  Index_Directive_Kind,
	thing: string, // the FieldPath head — the indexed thing's type name
	field: string, // the FieldPath member — the indexed field on that thing
	line:  int,    // 1-based source line of the `@` (artifact-format §9 span provenance)
}

// Query_Node is a §08 §3 first-class query declaration: `query name(p: T, …)
// -> R { … }` — a read-only, pure function over (version, params)
// (grammar/fun.ebnf §7 QueryDecl). Its body is the ordinary fn statement
// Block — the grammar admits no body-position `@stub` hole on a query (FnBody
// is the fn production only). indexes carries the §05 §3 `@index`/`@spatial`
// declarations prefixing it — the query's declared index requirements.
Query_Node :: struct {
	name:        string,
	params:      []Param_Decl,
	return_type: Type_Ref,
	body:        []Statement,
	doc:         string,
	gtags:       []string,
	probes:      []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:       []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	indexes:     []Index_Directive, // §05 §3 @index/@spatial requirements declared on this query
	exposed:     bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:        int, // 1-based source line of the `query` keyword (artifact-format §9 span provenance)
}

// Behavior_Node is a pure transition attached to a thing (spec §06 §3):
// `behavior name on Thing { fn step(…) -> … { … } }`. target is the `on
// Thing` type name; step is the single reserved entry point (the parser
// enforces the name `step`).
Behavior_Node :: struct {
	name:    string,
	target:  string,
	step:    Fn_Node,
	doc:     string,
	gtags:   []string,
	probes:  []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:   []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	exposed: bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:    int, // 1-based source line of the `behavior` keyword (artifact-format §9 span provenance)
}

// Pipeline_Stage is one ordered named stage of a pipeline (spec §07 §1).
// Stage order is the contract, so stages travel as an ordered slice. A stage
// has one of two value shapes: a behavior-name list `name: [behavior, …]`
// (behaviors holds the names, is_battery false), or a single bare battery
// name `name: solve` (battery holds the name, is_battery true) — the yard
// `physics: solve` engine-owned stage that integrates and resolves with no
// user behaviors. is_battery discriminates the two; the unused slice/field is
// empty. The battery name is not validated here — the surface/typecheck story
// owns that.
// probes carries the stage's §05 §5 debug prefix — the §28 §4 On-table admits
// a `@trace` on a pipeline stage (record the full per-step (in -> out)
// transition); the grammar puts Annotation* on StageEntry (fun.ebnf §9), and
// the stage carries the parsed probe the same way a declaration does. The
// On-table admits ONLY @trace here, so parse_pipeline_stage rejects every other
// @-form with a keyed verdict, the @migrate field-body mold. Empty when the
// stage carries no probe.
Pipeline_Stage :: struct {
	name:       string,
	behaviors:  []string, // behavior-list stage: the member behavior names
	battery:    string,   // single-battery stage: the bare battery name
	is_battery: bool,      // true for the bare-battery stage form
	probes:     []Debug_Probe,
}

Pipeline_Node :: struct {
	name:    string,
	stages:  []Pipeline_Stage,
	doc:     string,
	gtags:   []string,
	probes:  []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:   []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	exposed: bool, // §05 §4 @expose — published into the external contract (spec §30 §6, §27 §2)
	line:    int, // 1-based source line of the `pipeline` keyword (artifact-format §9 span provenance)
}

// Debug_Probe_Kind is the closed §05 §5 debug directive family — the
// observe-class, dev-only probes (spec §28 §4). The set is closed like every
// directive category (spec §05): adding a member is a spec change, never a
// parser convenience.
Debug_Probe_Kind :: enum {
	Break, // @break(pred) — pause when the predicate holds
	Log,   // @log(expr) — emit the structured value each step
	Watch, // @watch(expr) — fire watch_fired when the value changes
	Trace, // @trace — record the full per-step (in -> out) transition; no argument
}

// Debug_Probe is one parsed §05 §5 debug directive (@break/@log/@watch/@trace)
// carried on the declaration it prefixes, like @gtag. The argument is ordinary
// funpack (a predicate for @break, the value to emit/watch for @log/@watch),
// never a debugger DSL; @trace carries none, so arg is nil exactly when kind
// is .Trace. Parse+AST only here: release-forbidding and index registration
// are downstream stages' jobs, keyed off these nodes.
Debug_Probe :: struct {
	kind: Debug_Probe_Kind,
	arg:  Expr, // the probe's predicate/expression; nil for @trace
	line: int,  // 1-based source line of the `@` (artifact-format §9 span provenance)
}

// Todo_Window_Form is the closed §05 §2 expiry-window family of @todo —
// four forms, one obvious spelling each (spec §29 §4). The set is closed
// like every directive category (spec §05): adding a form is a spec change,
// never a parser convenience.
Todo_Window_Form :: enum {
	Duration,    // `<int>` + unit h/d/w/mo/q/y — that long after the introducing build
	Date,        // ISO-8601 YYYY-MM-DD — expires on that date
	Build_Count, // `<int>builds` — after that many builds
	Task_Ref,    // `T-<digits>` — when the task closes; the recommended default
}

// Todo_Window is one parsed @todo expiry window, recorded VERBATIM as
// written: the parser tags the form and keeps the spelled components, and
// never evaluates expiry — the build-clock that dates a window is a recorded
// input to `funpack build` (spec §29 §1/§4), an argument the parse stage does
// not have. Only the form-tagged fields are meaningful; the rest are zero.
// Date components are ISO shape-checked only (4/2/2 digit spellings, month
// 1–12, day 1–31): calendar validity (a Feb 30) is deliberately NOT a parse
// concern — the window evaluator owns the calendar.
Todo_Window :: struct {
	form:   Todo_Window_Form,
	amount: i64,    // Duration / Build_Count: the leading count
	unit:   string, // Duration: the trailing unit as written (h/d/w/mo/q/y)
	year:   i64,    // Date: the YYYY component
	month:  i64,    // Date: the MM component (1–12)
	day:    i64,    // Date: the DD component (1–31)
	task:   string, // Task_Ref: the digits as written — zero padding kept ("0042")
}

// Migrate_Node is one parsed `@migrate(…)` (spec §05 §6) — the dedicated
// breaking-change channel for schema evolution, covering the two structural
// breaks the name-keyed schema-diff cannot auto-resolve (spec §09 §4): a
// RENAME names the prior key (`from: "old_name"`), a RETYPE names a pure
// conversion fn (`with: convert`), and the combined form carries both. It
// prefixes the renamed/retyped data FIELD, or — rename form only — a renamed
// `data` type declaration. The form set is closed: at least one of
// has_from/has_with is true by construction (an empty `@migrate()` is the
// named Malformed_Migrate verdict). Parse+AST only here: collision and
// conversion admissibility are the typecheck stage's job (check_migrations),
// and the loader-driving carry is the artifact emitter's.
Migrate_Node :: struct {
	from:     string, // the prior field/type name as written; meaningful iff has_from
	with:     string, // the pure `fn(Old) -> New` conversion's name; meaningful iff has_with
	has_from: bool,
	has_with: bool,
	line:     int, // 1-based source line of the `@` (artifact-format §9 span provenance)
}

// Todo_Node is one parsed `@todo("msg", window)` (spec §05 §2) — the only
// legal temporal note — carried on the declaration it prefixes, like @gtag.
// Parse+AST only here: index recording (spec §29 §2) and window-expiry
// evaluation are downstream stages' jobs, keyed off these nodes.
Todo_Node :: struct {
	message: string,
	window:  Todo_Window,
	line:    int, // 1-based source line of the `@` (artifact-format §9 span provenance)
}

// Directives carries the @doc / @expose / @gtag / @todo / @migrate /
// debug-probe prefix block attached to a declaration (spec §05). It
// accumulates as leading directives are parsed and is consumed by the
// declaration that follows them. migrate is the §05 §6 declaration-level form
// — a renamed TYPE declaration — which only a `data` declaration may consume
// (Migrate_Wrong_Target otherwise); at most one accumulates (a second is
// Malformed_Migrate). exposed is the §05 §4 `@expose` marker — bare by
// grammar (lexical-core §5), idempotent under repetition (a flag, not an
// accumulating family) — publishing the declaration into the package/mod
// external contract (spec §30 §6, §27 §2).
Directives :: struct {
	doc:         string,
	exposed:     bool,
	gtags:       [dynamic]string,
	probes:      [dynamic]Debug_Probe,
	todos:       [dynamic]Todo_Node,
	// indexes accumulates the §05 §3 @index/@spatial directives — only a
	// `query` declaration may consume them (Index_Wrong_Target otherwise,
	// spec §08 §3); a query may declare several.
	indexes:     [dynamic]Index_Directive,
	migrate:     Migrate_Node,
	has_migrate: bool,
}

Parse_Error :: enum {
	None,
	Unexpected_Token,
	Unexpected_End,
	Wrong_Case,           // an identifier whose casing class is wrong for its grammar position (spec §02)
	Missing_Else,         // an if-EXPRESSION with no `else` arm (spec §02 §5): both arms are required in value position, so a missing alternate has no type to unify against — never a silent fallback (grammar/fun.ebnf §15 IfExpr)
	Probe_Missing_Arg,    // a @break/@log/@watch debug probe without its mandatory `(expr)` argument (spec §05 §5: the predicate/expression is the probe's whole content)
	Probe_Unexpected_Arg, // a @trace carrying an argument — @trace takes none (spec §05 §5; grammar/fun.ebnf §1 DebugDirective)
	Probe_Wrong_Target,   // a well-formed debug probe in a sub-declaration position the §28 §4 On-table does not admit — only @watch prefixes a `data` field and only @trace prefixes a pipeline stage; every other probe there (a @break/@log/@trace on a field, a @break/@log/@watch on a stage) names a behavior/declaration target, never this one — the Migrate_Wrong_Target mold
	Malformed_Todo_Window, // a @todo whose mandatory window is missing or matches none of the four §05 §2 forms (unknown unit, mis-shaped/out-of-range ISO date, quoted or lowercase task ref)
	Malformed_Migrate,     // a @migrate whose argument list matches none of the three closed §05 §6 forms (missing/empty parens, unknown or duplicated key, with-before-from order, unquoted from, empty prior name, trailing junk) — or a second @migrate on one target
	Migrate_Wrong_Target,  // a well-formed @migrate where the spec admits none (spec §05 §6): prefixing a non-`data` declaration, a field outside a `data` body, a retype (`with:`) form on a type declaration (a type admits the rename form only), or dangling with no field to attach to
	Malformed_Index_Path,  // an @index/@spatial whose argument is not exactly the lexical-core §5 FieldPath `(Thing.field)` (missing/empty parens, no dot, trailing junk) — the one casing-class deviation (a lowercase head, an UpperCamel field) keeps the parser-wide Wrong_Case verdict
	Index_Wrong_Target,    // a well-formed @index/@spatial prefixing a declaration the spec does not admit — §08 §3 places the directive on a `query` declaration (the query's declared index requirement), and the spec names no other target
	Expose_Unexpected_Arg, // an @expose carrying an argument — @expose is bare (lexical-core §5; spec §05 §4: it publishes the declaration it prefixes, there is no value to name), the @trace mold
	Malformed_Extern,      // an `extern` prefixing neither `fn` nor `type` — the §02 §7 extern family is closed (fun.ebnf §8: ExternDecl ::= 'extern' (ExternFn | ExternType)), so a stray `extern data …` is a named malformed-extern verdict, never a generic token error
	Malformed_Type_Params, // a §03 §3 generic declaration header whose `[…]` matches none of the TypeParams forms (fun.ebnf §4: '[' UPPER_IDENT (',' UPPER_IDENT)* ']') — empty brackets, a non-identifier parameter, a trailing comma, or a missing `]` between parameters; the one casing-class deviation (a lowercase parameter name) keeps the parser-wide Wrong_Case verdict, the Malformed_Index_Path mold
	Malformed_Fn_Type,     // a §02 §3 function type whose shape matches none of the FnType form (fun.ebnf §11: 'fn' '(' (Type (',' Type)*)? ')' '->' Type) — a missing `(` after `fn`, a trailing comma or non-type parameter, a missing `)`/comma between parameters, or a missing `->` before the result; an element type's OWN errors keep their verdicts (a lowercase name stays Wrong_Case), the Malformed_Type_Params mold
	Malformed_String_Escape, // a string literal whose backslash escape is outside the closed lexical-core §4 set (`\"` `\{` `\}`) — an unknown escape character, or a trailing backslash at line/input end; the lexer marks the literal (Token_Kind.Malformed_Escape) and advance names the verdict centrally, so every string position reports it; an UNTERMINATED string keeps its existing Unexpected_Token verdict — the Malformed_Fn_Type mold
	Variant_Directive_Wrong_Target, // a declaration-family directive (@gtag/@todo/@expose/a debug probe) prefixing an enum variant — §05 admits exactly @doc on a variant ("each `Draw` variant carries a @doc"); every other directive names a non-variant target — or a variant @doc left dangling with no variant to attach to; @migrate and @index/@spatial on a variant keep their directive-keyed Migrate_Wrong_Target / Index_Wrong_Target verdicts — the Migrate_Wrong_Target mold
	Bool_Pattern_Unsupported, // a `match` scrutinee dispatched on a bool literal pattern (`true`/`false` arm) — §02 §5 admits a match over a closed enum/tuple, not over Bool's two values, so a Bool match is a named verdict steering the author to `if`/`else` rather than the casing-class Wrong_Case the snake_case `true`/`false` head would otherwise trip (the parser sees `true`/`false` as a snake_case Ident in variant-head position); the Wrong_Case mold, branched ahead of the casing check
	Newline_Before_Binary_Op, // a statement/expression-start position whose first token is a binary operator (`and`/`or`, a comparison `== != < <= > >=`, or an arithmetic `+ * / %`) — funpack is newline-terminated (spec §02 §1), so the prior line already ended a complete expression and a binary operator cannot continue it across the newline; a named verdict steering the author to keep each line a complete expression (or bind an intermediate `let`) rather than the bare Unexpected_Token the dangling operator would otherwise trip. Unary-capable leads (`-`, `not`) are EXCLUDED — they legally open a fresh expression — so only the binary-only operators arm this verdict
}

Parser :: struct {
	tokens: []Token,
	pos:    int,
	// no_record_brace marks the no-struct-literal context of a match
	// scrutinee (spec §02 §5): the `{` after the scrutinee opens the
	// match block, so a name in scrutinee position must not consume it as
	// a record literal. Set only while parsing the scrutinee.
	no_record_brace: bool,
	// err_line/err_col is the offending token's 1-based span, stamped by reject
	// at the rejection site (where the offender is in hand) — the fix-criteria
	// diagnostic anchor (spec §15). Zero = unset: a production that rejects
	// WITHOUT a token in hand (a peek-reject, an end-of-input fault) leaves these
	// 0, and stage_parse_located falls back to parser_stop_span, which stays
	// correct there (p.pos already points at the offender). First-write-wins, so
	// the INNERMOST reject — the real offender — survives any outer wrapper that
	// re-returns the same error up the call stack.
	err_line: int,
	err_col:  int,
}

// reject stamps the offending token's span onto the parser FIRST-WRITE-WINS and
// returns the error, so a rejection site that has the offender in hand anchors
// the diagnostic on THAT token rather than wherever p.pos happened to stop.
// First-write-wins is load-bearing: a post-`advance` casing reject already moved
// p.pos one token PAST the offender, and an outer production may re-return the
// same error after the inner one already stamped — keeping the first write means
// the earliest (innermost, leftmost) offender wins, the deterministic
// first-offender anchor. A site with NO token in hand returns the bare error and
// leaves err_line/err_col 0, deferring to parser_stop_span's peek anchor.
reject :: proc(p: ^Parser, tok: Token, err: Parse_Error) -> Parse_Error {
	if p.err_line == 0 {
		p.err_line = tok.line
		p.err_col = tok.col
	}
	return err
}

// Parse_Verdict pairs a parse failure with the offending token's 1-based
// line/col — the fix-criteria diagnostic anchor (spec §15). The span is the one
// reject stamped at the rejection site (the offending token in hand), so a
// post-`advance` casing reject anchors on the mis-cased identifier even though
// p.pos has moved one token past it. When no site stamped (a peek-reject raised
// BEFORE advance, an end-of-input fault), stage_parse_located falls back to
// parser_stop_span — the token at clamp(p.pos, last), where p.pos already points
// at the offender for a peek-reject. line/col are 0 only when err is None (no
// fault) or the token stream is empty (no token to anchor at).
Parse_Verdict :: struct {
	err:  Parse_Error,
	line: int,
	col:  int,
}

// stage_parse_located is stage_parse plus the offending token's span — the
// diagnostic-bearing entry the pipeline driver consumes (run_module_pipeline_named
// builds a Parse-stage Diagnostic from it). It runs the same parse over a fresh
// Parser and, on a fault, reads the token at the parser's stop position as the
// anchor. The bare stage_parse stays the form every other caller (emit, index,
// fmt) consumes — they need the error class, not the span — so this is an additive
// sibling, not a signature change to the ~50 existing call sites.
stage_parse_located :: proc(tokens: []Token) -> (ast: Ast, verdict: Parse_Verdict) {
	p := Parser{tokens = tokens}
	parsed, err := parse_module(&p)
	if err == .None {
		return parsed, Parse_Verdict{}
	}
	// Prefer the offender's span captured at the rejection site (reject), which
	// anchors on the actual offending token even when p.pos has advanced past it
	// (every post-`advance` casing reject). Fall back to the parser's stop token
	// only when no site stamped — a peek-reject raised BEFORE advance, where p.pos
	// already points AT the offender, so parser_stop_span stays correct there.
	line, col := p.err_line, p.err_col
	if line == 0 {
		line, col = parser_stop_span(&p)
	}
	return parsed, Parse_Verdict{err = err, line = line, col = col}
}

// parser_stop_span returns the 1-based line/col of the token the parser stopped
// at — p.tokens[clamp(p.pos, 0, last)], the single-token-lookahead anchor. On an
// empty stream there is no token, so it reports (0, 0) — no position. Pure (a
// function of parser state alone) so the same source always anchors at the same
// token.
parser_stop_span :: proc(p: ^Parser) -> (line: int, col: int) {
	if len(p.tokens) == 0 {
		return 0, 0
	}
	idx := p.pos
	if idx >= len(p.tokens) {
		idx = len(p.tokens) - 1
	}
	tok := p.tokens[idx]
	return tok.line, tok.col
}

stage_parse :: proc(tokens: []Token) -> (ast: Ast, err: Parse_Error) {
	p := Parser{tokens = tokens}
	return parse_module(&p)
}

// parse_module is the shared parse loop both stage_parse (bare error) and
// stage_parse_located (error + offending-token span) drive over a caller-owned
// Parser, so the located entry can read p.pos for the diagnostic anchor after a
// fault. Factoring the loop out keeps the two entries from drifting — they parse
// the identical grammar, differing only in what they surface on a reject.
parse_module :: proc(p: ^Parser) -> (ast: Ast, err: Parse_Error) {
	out := Decl_Sink {
		imports   = make([dynamic]Import_Node, 0, 8, context.temp_allocator),
		decls     = make([dynamic]Decl_Ref, 0, 32, context.temp_allocator),
		lets      = make([dynamic]Let_Decl_Node, 0, 4, context.temp_allocator),
		datas     = make([dynamic]Data_Node, 0, 4, context.temp_allocator),
		enums     = make([dynamic]Enum_Node, 0, 4, context.temp_allocator),
		things    = make([dynamic]Thing_Node, 0, 8, context.temp_allocator),
		signals   = make([dynamic]Signal_Node, 0, 4, context.temp_allocator),
		fns       = make([dynamic]Fn_Node, 0, 16, context.temp_allocator),
		queries   = make([dynamic]Query_Node, 0, 4, context.temp_allocator),
		behaviors = make([dynamic]Behavior_Node, 0, 16, context.temp_allocator),
		pipelines = make([dynamic]Pipeline_Node, 0, 2, context.temp_allocator),
		tests     = make([dynamic]Test_Node, 0, 8, context.temp_allocator),
		extern_types = make([dynamic]Extern_Type_Node, 0, 4, context.temp_allocator),
	}
	module_doc := ""
	seen_decl := false
	pending := empty_directives()
	skip_newlines(p)
	for !at_end(p) {
		if peek_kind(p) == .At {
			parse_directive(p, &module_doc, &pending, seen_decl) or_return
			skip_newlines(p)
			continue
		}
		parse_declaration(p, &out, &pending) or_return
		seen_decl = true
		// Each declaration consumes its leading directives.
		pending = empty_directives()
		skip_newlines(p)
	}
	return Ast {
			module_doc = module_doc,
			imports = out.imports[:],
			decls = out.decls[:],
			lets = out.lets[:],
			datas = out.datas[:],
			enums = out.enums[:],
			things = out.things[:],
			signals = out.signals[:],
			fns = out.fns[:],
			queries = out.queries[:],
			behaviors = out.behaviors[:],
			pipelines = out.pipelines[:],
			tests = out.tests[:],
			extern_types = out.extern_types[:],
		},
		.None
}

// empty_directives is the fresh accumulator stage_parse threads between
// declarations — one constructor so the init and the per-declaration reset
// cannot drift as the directive family grows.
empty_directives :: proc() -> Directives {
	return Directives {
		gtags = make([dynamic]string, 0, 4, context.temp_allocator),
		probes = make([dynamic]Debug_Probe, 0, 4, context.temp_allocator),
		todos = make([dynamic]Todo_Node, 0, 4, context.temp_allocator),
		indexes = make([dynamic]Index_Directive, 0, 2, context.temp_allocator),
	}
}

// Decl_Sink collects the per-kind declaration slices stage_parse builds,
// plus the source-ordered Decl_Ref sequence (`decls`) recording the parse
// order across kinds. One sink threaded through parse_declaration keeps the
// dispatch loop flat and the per-kind append sites obvious; every kind
// append is paired with a sink_mark so the sequence and the slices cannot
// drift.
Decl_Sink :: struct {
	imports:   [dynamic]Import_Node,
	decls:     [dynamic]Decl_Ref,
	lets:      [dynamic]Let_Decl_Node,
	datas:     [dynamic]Data_Node,
	enums:     [dynamic]Enum_Node,
	things:    [dynamic]Thing_Node,
	signals:   [dynamic]Signal_Node,
	fns:       [dynamic]Fn_Node,
	queries:   [dynamic]Query_Node,
	behaviors: [dynamic]Behavior_Node,
	pipelines: [dynamic]Pipeline_Node,
	tests:     [dynamic]Test_Node,
	extern_types: [dynamic]Extern_Type_Node, // `extern type Name` opaque types (§26 §2)
}

// sink_mark appends the just-appended declaration's Decl_Ref onto the
// source-ordered sequence: the index is the matching kind slice's last slot,
// so calling it immediately after the kind append records exactly that
// declaration. Imports are the module header, not declarations, so no
// import is ever marked.
sink_mark :: proc(out: ^Decl_Sink, kind: Ast_Decl_Kind) {
	index := 0
	switch kind {
	case .Let:
		index = len(out.lets) - 1
	case .Data:
		index = len(out.datas) - 1
	case .Enum:
		index = len(out.enums) - 1
	case .Thing:
		index = len(out.things) - 1
	case .Signal:
		index = len(out.signals) - 1
	case .Fn:
		index = len(out.fns) - 1
	case .Query:
		index = len(out.queries) - 1
	case .Behavior:
		index = len(out.behaviors) - 1
	case .Pipeline:
		index = len(out.pipelines) - 1
	case .Test:
		index = len(out.tests) - 1
	case .Extern_Type:
		index = len(out.extern_types) - 1
	}
	append(&out.decls, Decl_Ref{kind = kind, index = index})
}

// parse_declaration dispatches one top-level declaration off its unique
// opening keyword (LL(1), spec §02 §7) and appends it to the matching sink
// slice, attaching the accumulated leading @doc / @gtag directives.
parse_declaration :: proc(p: ^Parser, out: ^Decl_Sink, pending: ^Directives) -> Parse_Error {
	if pending.has_migrate {
		// A declaration-level @migrate marks a RENAMED TYPE declaration
		// (spec §05 §6), and the schema-evolution channel is the name-keyed
		// `data` schema (spec §09 §4) — so only a `data` declaration may
		// consume it, and only in the rename form (a type declaration has no
		// value to convert, so `with:` has no admitted decl-level reading).
		// Both deviations are the named Migrate_Wrong_Target verdict.
		if peek_kind(p) != .Ident || p.tokens[p.pos].text != "data" {
			return .Migrate_Wrong_Target
		}
		if pending.migrate.has_with {
			return .Migrate_Wrong_Target
		}
	}
	if len(pending.indexes) > 0 {
		// An @index/@spatial declares a query's index requirement (spec §08 §3)
		// — the one placement the spec names — so only a `query` declaration may
		// consume the accumulated directives. Any other declaration following
		// them is the named Index_Wrong_Target verdict, the @migrate
		// wrong-target mold.
		if peek_kind(p) != .Ident || p.tokens[p.pos].text != "query" {
			return .Index_Wrong_Target
		}
	}
	#partial switch peek_kind(p) {
	case .Import:
		node := parse_import(p) or_return
		append(&out.imports, node)
	case .Let:
		node := parse_let_decl(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.lets, node)
		sink_mark(out, .Let)
	case .Ident:
		// `data`/`enum`/`thing`/`singleton` are CONTEXTUAL keywords (fun.ll1.md
		// §2): they lex as Ident, so the keyword is recognized by text here — and
		// only here, at the declaration-opening position the top-level loop calls
		// parse_declaration in. One token of lookahead still selects the
		// production (the surface has no module-level expression statement, so a
		// leading Ident that is not a decl opener is an error), preserving LL(1).
		// In value/binding/field position these same words are ordinary Idents the
		// expression and field grammars consume, never reaching this dispatch.
		return parse_contextual_declaration(p, out, pending)
	case .Signal:
		node := parse_signal(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.signals, node)
		sink_mark(out, .Signal)
	case .Fn:
		node := parse_fn_decl(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.fns, node)
		sink_mark(out, .Fn)
	case .Extern:
		return parse_extern_declaration(p, out, pending)
	case .Behavior:
		node := parse_behavior(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.behaviors, node)
		sink_mark(out, .Behavior)
	case .Pipeline:
		node := parse_pipeline(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.pipelines, node)
		sink_mark(out, .Pipeline)
	case .Test:
		node := parse_test(p) or_return
		node.doc = pending.doc
		// A test admits @doc only (§05 §1). A §05 §5 debug probe is NOT in the
		// §28 §4 On-table for a test, so a pending probe is carried onto the
		// node — never dropped silently — so the §28 §4 placement gate
		// (probe_placement_gate.odin) names the test (Probe_Wrong_Placement).
		node.probes = pending.probes[:]
		append(&out.tests, node)
		sink_mark(out, .Test)
	case:
		return .Unexpected_Token
	}
	return .None
}

// parse_contextual_declaration dispatches a `data`/`enum`/`thing`/`singleton`/
// `query` declaration off the leading Ident's TEXT (fun.ll1.md §2: these are
// contextual keywords, lexed as Ident). It is reached only from parse_declaration, i.e.
// only at the start of a module-level statement — the one position the word is
// the keyword. A leading Ident whose text is none of these is not a declaration
// opener: the surface has no module-level expression statement, so it is an
// Unexpected_Token (the same verdict the prior hard-keyword dispatch's default
// gave for a stray leading word).
parse_contextual_declaration :: proc(p: ^Parser, out: ^Decl_Sink, pending: ^Directives) -> Parse_Error {
	switch p.tokens[p.pos].text {
	case "data":
		node := parse_data(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		// The decl-level @migrate (a renamed type, spec §05 §6) lands here;
		// parse_declaration already verified the target kind and the
		// rename-only form, so this is a plain carry.
		node.migrate = pending.migrate
		node.has_migrate = pending.has_migrate
		node.exposed = pending.exposed
		append(&out.datas, node)
		sink_mark(out, .Data)
	case "enum":
		node := parse_enum(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.enums, node)
		sink_mark(out, .Enum)
	case "thing", "singleton":
		node := parse_thing(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.things, node)
		sink_mark(out, .Thing)
	case "query":
		node := parse_query(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		// The §05 §3 @index/@spatial requirements land here; parse_declaration
		// already verified the target kind, so this is a plain carry.
		node.indexes = pending.indexes[:]
		append(&out.queries, node)
		sink_mark(out, .Query)
	case:
		return .Unexpected_Token
	}
	return .None
}

// parse_directive parses one declaration-prefix directive (spec §05):
// `@doc("…")`, `@expose`, `@gtag("…", …)`, `@todo("msg", window)`, or a §05
// §5 debug probe (@break/@log/@watch/@trace). The file-leading @doc documents the module
// (spec §15, fun.ll1.md §5B): the first @doc is the module doc only when it
// is followed by an `import` — imports carry no directives, so a @doc before
// one cannot be the import's. Blank lines between the file-leading @doc and the
// first import are insignificant, so skip any run of newlines before testing
// for the import (the main loop skips them anyway, so advancing here is safe).
// A first @doc followed instead by @gtag or a declaration keyword is that
// declaration's doc. @gtag labels, @todo notes, and debug probes accumulate;
// a declaration consumes the whole accumulated directive set.
parse_directive :: proc(p: ^Parser, module_doc: ^string, pending: ^Directives, seen_decl: bool) -> Parse_Error {
	at_tok := expect(p, .At) or_return
	name := expect(p, .Ident) or_return
	switch name.text {
	case "doc":
		expect(p, .L_Paren) or_return
		str := expect(p, .String_Lit) or_return
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
		skip_newlines(p)
		if !seen_decl && module_doc^ == "" && peek_kind(p) == .Import {
			module_doc^ = str.text
		} else {
			pending.doc = str.text
		}
	case "gtag":
		// @gtag("ball", "score") — one or more string-literal tag labels.
		expect(p, .L_Paren) or_return
		for peek_kind(p) == .String_Lit {
			tag := advance(p) or_return
			append(&pending.gtags, tag.text)
			if peek_kind(p) == .Comma {
				p.pos += 1
			} else {
				break
			}
		}
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
	case "todo":
		// @todo("msg", window) — the only legal temporal note (spec §05 §2).
		// The window is MANDATORY: a @todo with no expiry can rot forever, so
		// its absence is the named Malformed_Todo_Window verdict, never a
		// generic token error. Trailing junk AFTER a well-formed window stays
		// the generic Unexpected_Token — the named diagnostic covers window
		// malformation only.
		expect(p, .L_Paren) or_return
		msg := expect(p, .String_Lit) or_return
		if peek_kind(p) != .Comma {
			return reject(p, at_tok, .Malformed_Todo_Window)
		}
		p.pos += 1
		window := parse_todo_window(p) or_return
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
		append(&pending.todos, Todo_Node{message = msg.text, window = window, line = at_tok.line})
	case "break", "log", "watch":
		// @break(pred) / @log(expr) / @watch(expr) — the §05 §5 observe-class
		// debug probes. The single argument is ordinary funpack (a predicate
		// for @break, the value to emit/watch for @log/@watch), never a
		// debugger DSL, and it is mandatory: a probe with nothing to test or
		// emit is malformed, reported by the named Probe_Missing_Arg verdict
		// so an agent repairs the exact shape.
		if peek_kind(p) != .L_Paren {
			return reject(p, at_tok, .Probe_Missing_Arg)
		}
		p.pos += 1
		if peek_kind(p) == .R_Paren {
			return reject(p, at_tok, .Probe_Missing_Arg)
		}
		arg := parse_expression(p) or_return
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
		kind: Debug_Probe_Kind
		switch name.text {
		case "break":
			kind = .Break
		case "log":
			kind = .Log
		case "watch":
			kind = .Watch
		}
		append(&pending.probes, Debug_Probe{kind = kind, arg = arg, line = at_tok.line})
	case "migrate":
		// @migrate(from: "…") prefixing a declaration marks a RENAMED TYPE
		// declaration (spec §05 §6). The closed argument shape is shared with
		// the field-level form (parse_migrate_args); which targets may consume
		// it — and that a type declaration admits the rename form only — is
		// parse_declaration's check, where the target is known. At most one
		// accumulates: a second @migrate before one declaration is the named
		// Malformed_Migrate verdict, never a silent overwrite.
		if pending.has_migrate {
			return reject(p, at_tok, .Malformed_Migrate)
		}
		node := parse_migrate_args(p, at_tok.line) or_return
		terminate_statement(p) or_return
		pending.migrate = node
		pending.has_migrate = true
	case "trace":
		// @trace takes NO argument (spec §05 §5; grammar/fun.ebnf §1
		// DebugDirective): it records the declaration's full per-step
		// (in -> out) transition, so there is no value to name. A
		// parenthesized argument is malformed — the named
		// Probe_Unexpected_Arg verdict, never silently consumed.
		if peek_kind(p) == .L_Paren {
			return reject(p, at_tok, .Probe_Unexpected_Arg)
		}
		terminate_statement(p) or_return
		append(&pending.probes, Debug_Probe{kind = .Trace, line = at_tok.line})
	case "expose":
		// @expose is bare (lexical-core §5; spec §05 §4): it publishes the
		// declaration it prefixes into the external contract — packages (§30
		// §6) and mods (§27 §2) — so there is no value to name. A
		// parenthesized argument is malformed, the named
		// Expose_Unexpected_Arg verdict (the @trace mold). The flag is
		// idempotent: a repeated @expose sets it again, never an error — it
		// marks a fact, not an accumulating family.
		if peek_kind(p) == .L_Paren {
			return reject(p, at_tok, .Expose_Unexpected_Arg)
		}
		terminate_statement(p) or_return
		pending.exposed = true
	case "index", "spatial":
		// @index(Thing.field) / @spatial(Thing.field) — the §05 §3 data-plane
		// index directives. The mandatory argument is the lexical-core §5
		// FieldPath; which declaration may consume the accumulated set — a
		// `query` only (spec §08 §3) — is parse_declaration's check, where the
		// target is known, mirroring @migrate. Several accumulate: a query may
		// declare more than one index requirement.
		kind := Index_Directive_Kind.Index if name.text == "index" else Index_Directive_Kind.Spatial
		node := parse_index_path(p, kind, at_tok.line) or_return
		terminate_statement(p) or_return
		append(&pending.indexes, node)
	case:
		// Only @doc/@expose/@gtag/@todo/@migrate/@index/@spatial and the §05
		// §5 debug probes prefix a declaration. @stub in particular is NOT a
		// prefix directive — it stands in body/expression position only
		// (spec §05: parse_stub_body owns it), so a leading `@stub` is an
		// Unexpected_Token here, never silently accepted. The offending
		// directive name is in hand (consumed above), so anchor on it.
		return reject(p, name, .Unexpected_Token)
	}
	return .None
}

// parse_todo_window parses the mandatory @todo expiry window — one of the
// four closed §05 §2 forms, selected LL(1) off the opening token plus one
// lookahead (spec §05: the forms are mutually unambiguous — a date carries
// two `-`, a task ref leads with `T-`, and a duration and a build count
// differ by their trailing unit). The lexer splits the spellings naturally:
// `30d` is Int_Lit + adjacent Ident, `2026-09-01` is Int_Lit/Minus/Int_Lit/
// Minus/Int_Lit, `T-0042` is Ident/Minus/Int_Lit. Anything outside the four
// forms — a bare count with no unit, an unknown unit, a quoted window, a
// lowercase task ref — is the named Malformed_Todo_Window verdict, so an
// agent repairs the exact window shape rather than chasing a token error.
parse_todo_window :: proc(p: ^Parser) -> (window: Todo_Window, err: Parse_Error) {
	#partial switch peek_kind(p) {
	case .Int_Lit:
		lead := advance(p) or_return
		if peek_kind(p) == .Minus {
			// Two `-` follow only in the date form; the date helper owns the
			// ISO shape from here.
			return parse_todo_date(p, lead)
		}
		if peek_kind(p) != .Ident {
			// A bare `<int>` names no unit — neither a duration nor a build
			// count (spec §05 §2: one obvious spelling each). Anchor on the
			// window's lead count token, the malformed window's first byte.
			return window, reject(p, lead, .Malformed_Todo_Window)
		}
		unit := advance(p) or_return
		switch unit.text {
		case "h", "d", "w", "mo", "q", "y":
			return Todo_Window{form = .Duration, amount = lead.int_value, unit = unit.text}, .None
		case "builds":
			return Todo_Window{form = .Build_Count, amount = lead.int_value}, .None
		case:
			return window, reject(p, lead, .Malformed_Todo_Window)
		}
	case .Ident:
		// Task ref `T-<digits>` — the recommended default. The lead is the
		// literal uppercase `T`: a lowercase `t-0042` matches no form.
		lead := advance(p) or_return
		if lead.text != "T" || peek_kind(p) != .Minus {
			return window, reject(p, lead, .Malformed_Todo_Window)
		}
		p.pos += 1
		if peek_kind(p) != .Int_Lit {
			return window, reject(p, lead, .Malformed_Todo_Window)
		}
		digits := advance(p) or_return
		// The digits are kept as WRITTEN — `T-0042` keeps its zero padding —
		// because a T-ref resolves against the operator's task tooling
		// (spec §05 §2), whose ids are spelled strings, not numbers.
		return Todo_Window{form = .Task_Ref, task = digits.text}, .None
	case:
		// A quoted window (`@todo("msg", "30d")`), a fixed-point literal, or
		// any other opener matches none of the four forms.
		return window, .Malformed_Todo_Window
	}
}

// parse_todo_date parses the ISO-8601 `YYYY-MM-DD` window after its year
// Int_Lit and the peeked first `-` (spec §05 §2). Enforcement is ISO SHAPE
// only, off the token texts the lexer kept verbatim: 4/2/2 digit spellings
// (so `2026-9-01` is malformed — the zero-padded two-digit month is the one
// obvious spelling) plus month 1–12 / day 1–31 range checks. Calendar
// validity (a Feb 30) is deliberately NOT checked at parse: the window is
// evaluated as a pure function of (source, clock) downstream (spec §29 §4),
// and the calendar belongs to that evaluator.
parse_todo_date :: proc(p: ^Parser, year_tok: Token) -> (window: Todo_Window, err: Parse_Error) {
	// Every date-shape fault anchors on the window's lead year token — the
	// malformed window's first byte (the date components share one window span).
	if len(year_tok.text) != 4 {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	p.pos += 1 // the first `-` (the caller peeked it)
	if peek_kind(p) != .Int_Lit {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	month_tok := advance(p) or_return
	if len(month_tok.text) != 2 || month_tok.int_value < 1 || month_tok.int_value > 12 {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	if peek_kind(p) != .Minus {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	p.pos += 1
	if peek_kind(p) != .Int_Lit {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	day_tok := advance(p) or_return
	if len(day_tok.text) != 2 || day_tok.int_value < 1 || day_tok.int_value > 31 {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	return Todo_Window {
			form = .Date,
			year = year_tok.int_value,
			month = month_tok.int_value,
			day = day_tok.int_value,
		},
		.None
}

// parse_migrate_args parses the mandatory @migrate argument list — one of the
// three closed §05 §6 forms, selected LL(1) off the first key token:
// `(from: "old_name")` (rename), `(with: convert)` (retype), or
// `(from: "old_name", with: convert)` (both, in exactly that order — the spec
// table's spelling, which the formatter canonicalizes to). `from:` is the
// prior name as a String (spec §05 §6) and must be non-empty; `with:` is a
// bare snake_case fn name (the table's `convert` spelling — a named pure
// `fn(Old) -> New`, never a lambda). Anything outside the closed shape — no
// parens, an empty list, an unknown or duplicated key, `with` before `from`,
// an unquoted prior name, trailing junk before `)` — is the named
// Malformed_Migrate verdict, so an agent repairs the exact form rather than
// chasing a token error; the one casing-class deviation (a non-snake_case
// convert name) keeps the parser-wide Wrong_Case verdict.
parse_migrate_args :: proc(p: ^Parser, line: int) -> (node: Migrate_Node, err: Parse_Error) {
	node.line = line
	if peek_kind(p) != .L_Paren {
		return node, .Malformed_Migrate
	}
	p.pos += 1
	if peek_kind(p) == .Ident && p.tokens[p.pos].text == "from" {
		p.pos += 1
		if peek_kind(p) != .Colon {
			return node, .Malformed_Migrate
		}
		p.pos += 1
		if peek_kind(p) != .String_Lit {
			return node, .Malformed_Migrate
		}
		from := advance(p) or_return
		if from.text == "" {
			return node, reject(p, from, .Malformed_Migrate)
		}
		node.from = from.text
		node.has_from = true
		if peek_kind(p) == .Comma {
			p.pos += 1
			// Only `with:` may follow a rename key — a second `from`, or any
			// other token, falls outside the three closed forms.
			if peek_kind(p) != .With {
				return node, .Malformed_Migrate
			}
			parse_migrate_with(p, &node) or_return
		}
	} else if peek_kind(p) == .With {
		parse_migrate_with(p, &node) or_return
	} else {
		// An empty list, an unknown key, or a non-key opener matches no form.
		return node, .Malformed_Migrate
	}
	if peek_kind(p) != .R_Paren {
		return node, .Malformed_Migrate
	}
	p.pos += 1
	return node, .None
}

// parse_migrate_with parses the `with: convert` key of a @migrate argument
// list, from the peeked `with` keyword (a reserved token, so the key is
// .With, never an Ident). convert is a bare snake_case fn name — the §05 §6
// pure `fn(Old) -> New` the loader runs the old value through; its
// admissibility (declared, unary, returning the field's type) is the
// typecheck stage's check_migrations.
parse_migrate_with :: proc(p: ^Parser, node: ^Migrate_Node) -> Parse_Error {
	p.pos += 1 // the `with` keyword (the caller peeked it)
	if peek_kind(p) != .Colon {
		return .Malformed_Migrate
	}
	p.pos += 1
	if peek_kind(p) != .Ident {
		return .Malformed_Migrate
	}
	convert := advance(p) or_return
	// A fn name is snake_case (spec §02) — the parser-wide casing verdict.
	if convert.class != .Snake_Case {
		return reject(p, convert, .Wrong_Case)
	}
	node.with = convert.text
	node.has_with = true
	return .None
}

// parse_index_path parses the mandatory @index/@spatial argument — exactly the
// lexical-core §5 FieldPath `(Thing.field)` (`'(' UPPER_IDENT '.' LOWER_IDENT
// ')'`, spec §05 §3, §08 §3). Anything outside that closed shape — no parens,
// an empty list, a missing dot, trailing junk before `)` — is the named
// Malformed_Index_Path verdict, so an agent repairs the exact path shape rather
// than chasing a token error; the casing-class deviations (a lowercase thing
// head, a non-snake_case field) keep the parser-wide Wrong_Case verdict, the
// parse_migrate_args precedent. The path is recorded as written — that it
// names a declared thing and one of its fields is the typecheck stage's
// check_index_paths.
parse_index_path :: proc(p: ^Parser, kind: Index_Directive_Kind, line: int) -> (node: Index_Directive, err: Parse_Error) {
	node.kind = kind
	node.line = line
	if peek_kind(p) != .L_Paren {
		return node, .Malformed_Index_Path
	}
	p.pos += 1
	if peek_kind(p) != .Ident {
		return node, .Malformed_Index_Path
	}
	thing := advance(p) or_return
	// The path head is the indexed thing's type name — UPPER_IDENT
	// (lexical-core.ebnf §5 FieldPath).
	if !is_upper_ident(thing.class) {
		return node, reject(p, thing, .Wrong_Case)
	}
	if peek_kind(p) != .Dot {
		return node, .Malformed_Index_Path
	}
	p.pos += 1
	if peek_kind(p) != .Ident {
		return node, .Malformed_Index_Path
	}
	field := advance(p) or_return
	// The path member is a field name — snake_case (spec §02).
	if field.class != .Snake_Case {
		return node, reject(p, field, .Wrong_Case)
	}
	if peek_kind(p) != .R_Paren {
		return node, .Malformed_Index_Path
	}
	p.pos += 1
	node.thing = thing.text
	node.field = field.text
	return node, .None
}

parse_import :: proc(p: ^Parser) -> (node: Import_Node, err: Parse_Error) {
	import_tok := expect(p, .Import) or_return
	segments := make([dynamic]string, 0, 4, context.temp_allocator)
	members: []string
	for {
		tok := expect(p, .Ident) or_return
		if peek_kind(p) == .Dot {
			// An interior segment is a module name — snake_case only
			// (spec §02); the final segment may also be an UpperCamel
			// type or UPPER_SNAKE constant member.
			if tok.class != .Snake_Case {
				return node, reject(p, tok, .Wrong_Case)
			}
			append(&segments, tok.text)
			p.pos += 1
			if peek_kind(p) == .L_Brace {
				members = parse_import_group(p) or_return
				break
			}
			continue
		}
		if tok.class == .Mixed {
			return node, reject(p, tok, .Wrong_Case)
		}
		append(&segments, tok.text)
		break
	}
	terminate_statement(p) or_return
	// line/col anchor on the `import` keyword — the import-resolution typecheck
	// arms (Unknown_Module/Unknown_Member/Package_Private/Name_Collision) point at
	// the offending import statement, which owns no expression span (artifact-format
	// §9 span provenance, the decl `.line` mold).
	return Import_Node {
			segments = segments[:],
			members = members,
			line = import_tok.line,
			col = import_tok.col,
		},
		.None
}

parse_import_group :: proc(p: ^Parser) -> (members: []string, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	list := make([dynamic]string, 0, 8, context.temp_allocator)
	skip_newlines(p)
	for peek_kind(p) == .Ident {
		tok := advance(p) or_return
		if tok.class == .Mixed {
			return nil, reject(p, tok, .Wrong_Case)
		}
		append(&list, tok.text)
		// Members separate by `,` or newline, both legal (spec §02).
		for peek_kind(p) == .Comma || peek_kind(p) == .Newline {
			p.pos += 1
		}
	}
	expect(p, .R_Brace) or_return
	return list[:], .None
}

parse_test :: proc(p: ^Parser) -> (test: Test_Node, err: Parse_Error) {
	test_tok := expect(p, .Test) or_return
	name_tok := expect(p, .String_Lit) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	body := make([dynamic]Statement, 0, 4, context.temp_allocator)
	body_loop: for {
		#partial switch peek_kind(p) {
		case .Assert:
			node := parse_assert(p) or_return
			append(&body, node)
		case .Let:
			node := parse_let(p) or_return
			append(&body, node)
		case:
			break body_loop
		}
		skip_newlines(p)
	}
	expect(p, .R_Brace) or_return
	return Test_Node{name = name_tok.text, body = body[:], line = test_tok.line}, .None
}

parse_assert :: proc(p: ^Parser) -> (node: Assert_Node, err: Parse_Error) {
	expect(p, .Assert) or_return
	expr := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Assert_Node{expr = expr}, .None
}

parse_let :: proc(p: ^Parser) -> (node: Let_Node, err: Parse_Error) {
	expect(p, .Let) or_return
	name := expect(p, .Ident) or_return
	// A binding name is a value name: snake_case, or UPPER_SNAKE for a
	// module-level constant (spec §02).
	if name.class != .Snake_Case && name.class != .Upper_Snake {
		return node, reject(p, name, .Wrong_Case)
	}
	expect(p, .Eq) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Let_Node{name = name.text, value = value}, .None
}

// parse_let_decl parses a module-level constant `let NAME: T = expr`
// (spec §02 §6–7). The type ascription is mandatory at module level (the
// constant has no surrounding inference context); the name is UPPER_SNAKE
// or snake_case (spec §02: the sanctioned constant exceptions pi/tau
// classify snake_case).
parse_let_decl :: proc(p: ^Parser) -> (node: Let_Decl_Node, err: Parse_Error) {
	let_tok := expect(p, .Let) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case && name.class != .Upper_Snake {
		return node, reject(p, name, .Wrong_Case)
	}
	expect(p, .Colon) or_return
	type := parse_type_ref(p) or_return
	expect(p, .Eq) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Let_Decl_Node{name = name.text, type = type, value = value, line = let_tok.line}, .None
}

// parse_data parses `data Name { field: T = default … }` (spec §03 §1),
// with the optional §03 §3 generic header (`data Ref[T] { … }`) and the
// optional `data Name: Kind { … }` kind ascription (§03 §4), in the fun.ebnf
// §4 order (DataDecl ::= 'data' UPPER_IDENT TypeParams? KindAsc? RecordBody).
// The kind is contextual — a bare UpperCamel name in the post-colon position,
// never a reserved word.
parse_data :: proc(p: ^Parser) -> (node: Data_Node, err: Parse_Error) {
	// `data` is a contextual keyword (Ident); the by-text dispatch in
	// parse_contextual_declaration already verified the text, so consume the
	// opener as an Ident here.
	data_tok := expect(p, .Ident) or_return
	name := expect_type_name(p) or_return
	type_params := parse_type_params(p) or_return
	kind := parse_optional_kind(p) or_return
	// A data body is the one field list whose fields may carry the `data`-only
	// field directives — the §05 §6 @migrate prefix (the name-keyed schema is
	// the evolution channel) and the §28 §4 @watch probe (a `data` field is the
	// On-table's watchable field).
	fields := parse_field_list(p, is_data_body = true) or_return
	return Data_Node{name = name, kind = kind, type_params = type_params, fields = fields, line = data_tok.line}, .None
}

// parse_thing parses `thing Name { … }` and `singleton Name { … }`
// (spec §06 §1–2); a singleton is told apart only by the is_singleton flag.
parse_thing :: proc(p: ^Parser) -> (node: Thing_Node, err: Parse_Error) {
	// `thing`/`singleton` are contextual keywords (Idents); the opener's text
	// (verified by parse_contextual_declaration's dispatch) tells the two forms
	// apart, recorded in is_singleton.
	is_singleton := p.tokens[p.pos].text == "singleton"
	thing_tok := expect(p, .Ident) or_return // `thing` or `singleton`
	name := expect_type_name(p) or_return
	fields := parse_field_list(p) or_return
	return Thing_Node{name = name, is_singleton = is_singleton, fields = fields, line = thing_tok.line}, .None
}

// parse_signal parses `signal Name { field: T }` (spec §03 §6, §06 §5) —
// a data value the engine routes; its body is a field list like data.
parse_signal :: proc(p: ^Parser) -> (node: Signal_Node, err: Parse_Error) {
	signal_tok := expect(p, .Signal) or_return
	name := expect_type_name(p) or_return
	fields := parse_field_list(p) or_return
	return Signal_Node{name = name, fields = fields, line = signal_tok.line}, .None
}

// parse_type_params reads the optional §03 §3 generic declaration header
// `[T]` / `[T, E]` after a declared type name (fun.ebnf §4: TypeParams ::=
// '[' UPPER_IDENT (',' UPPER_IDENT)* ']'; LL(1) on the one `[` token —
// fun.ll1.md: `[` ⇒ params, else skip). Only the engine-container decl kinds
// the grammar names admit the header — data, enum, and extern type — so this
// is called from exactly those three productions; every other decl kind keeps
// rejecting a post-name `[` through its own next expectation. A mis-shaped
// header — empty brackets, a non-identifier parameter, a trailing comma, a
// missing `]` — is the named Malformed_Type_Params verdict; a lowercase
// parameter name keeps the parser-wide Wrong_Case verdict. Returns nil when
// the next token is not `[`.
parse_type_params :: proc(p: ^Parser) -> (params: []string, err: Parse_Error) {
	if peek_kind(p) != .L_Bracket {
		return nil, .None
	}
	p.pos += 1
	list := make([dynamic]string, 0, 2, context.temp_allocator)
	for {
		if peek_kind(p) != .Ident {
			// Empty `[]`, a trailing comma, or a non-identifier parameter — the
			// grammar requires at least one UPPER_IDENT after `[` and after
			// every comma.
			return nil, .Malformed_Type_Params
		}
		tok := advance(p) or_return
		if !is_upper_ident(tok.class) {
			return nil, reject(p, tok, .Wrong_Case)
		}
		append(&list, tok.text)
		if peek_kind(p) == .Comma {
			p.pos += 1
			continue
		}
		break
	}
	if peek_kind(p) != .R_Bracket {
		// `[T U]` — parameters are comma-separated, and nothing else stands
		// between the last parameter and the closer.
		return nil, .Malformed_Type_Params
	}
	p.pos += 1
	return list[:], .None
}

// parse_optional_kind reads a `: Kind` ascription after a type name
// (spec §03 §4). The kind is a contextual UpperCamel name; returns "" when
// the next token is not `:`.
parse_optional_kind :: proc(p: ^Parser) -> (kind: string, err: Parse_Error) {
	if peek_kind(p) != .Colon {
		return "", .None
	}
	p.pos += 1
	kind_tok := expect_type_name(p) or_return
	return kind_tok, .None
}

// parse_field_list parses `{ name: T (= default)? … }` — the shared body of
// data/thing/singleton/signal declarations (spec §03 §1). Fields are
// newline- or comma-separated (the body is a block, so the lexer kept the
// newlines); a defaulted field carries `= expr` (spec §03 §1: a defaulted
// field may be omitted from a literal). is_data_body is true only for a `data`
// body, which alone admits the `data`-only field directives — a §05 §6
// @migrate prefix (the name-keyed schema is the evolution channel) and the §28
// §4 @watch probe (a `data` field is the On-table's watchable field). Both ride
// on their own line or inline before the field, consumed by the field that
// follows them; elsewhere @migrate is the named Migrate_Wrong_Target verdict
// (the schema-evolution channel is the name-keyed `data` schema, spec §09 §4)
// and a field @watch is Probe_Wrong_Target, as is either left dangling with no
// field to attach to. A field @break/@log/@trace is Probe_Wrong_Target: the
// On-table places those on a behavior or a stage, never a field.
parse_field_list :: proc(p: ^Parser, is_data_body := false) -> (fields: []Field_Decl, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	list := make([dynamic]Field_Decl, 0, 8, context.temp_allocator)
	pending_migrate := Migrate_Node{}
	has_pending_migrate := false
	// pending_probes accumulates the §05 §5 debug prefix that attaches to the
	// field which follows — the field-level @migrate carry mold, for the one
	// probe the §28 §4 On-table admits on a `data` field (@watch). The grammar
	// puts Annotation* on FieldDecl (fun.ebnf §5), a star, so several @watch
	// lines stack the same way declaration-prefix probes accumulate.
	pending_probes := make([dynamic]Debug_Probe, 0, 2, context.temp_allocator)
	for {
		if peek_kind(p) == .At {
			at_tok := advance(p) or_return
			directive := expect(p, .Ident) or_return
			switch directive.text {
			case "migrate":
				if !is_data_body {
					return nil, reject(p, at_tok, .Migrate_Wrong_Target)
				}
				if has_pending_migrate {
					// A second @migrate before one field — never a silent
					// overwrite.
					return nil, reject(p, at_tok, .Malformed_Migrate)
				}
				pending_migrate = parse_migrate_args(p, at_tok.line) or_return
				has_pending_migrate = true
			case "watch":
				// @watch(expr) is the ONE debug probe the §28 §4 On-table admits
				// on a field, and only on a `data` field (a `thing`/`singleton`/
				// `signal` field is not a `data` record field, §03 §1) — the
				// `data`-only gate @migrate uses. The argument is mandatory and
				// is ordinary funpack (the value whose change fires watch_fired),
				// parsed exactly as the declaration-prefix @watch arm does, so a
				// missing/empty `(expr)` is the shared Probe_Missing_Arg verdict.
				if !is_data_body {
					return nil, reject(p, at_tok, .Probe_Wrong_Target)
				}
				if peek_kind(p) != .L_Paren {
					return nil, reject(p, at_tok, .Probe_Missing_Arg)
				}
				p.pos += 1
				if peek_kind(p) == .R_Paren {
					return nil, reject(p, at_tok, .Probe_Missing_Arg)
				}
				arg := parse_expression(p) or_return
				expect(p, .R_Paren) or_return
				append(&pending_probes, Debug_Probe{kind = .Watch, arg = arg, line = at_tok.line})
			case "break", "log", "trace":
				// Well-formed debug probes the On-table places on a behavior or a
				// stage, never a field (spec §28 §4) — the keyed wrong-target
				// verdict, never a silently dropped probe or a generic token error.
				return nil, reject(p, at_tok, .Probe_Wrong_Target)
			case:
				// @migrate/@watch are the only field-body directives (spec §05
				// §6, §28 §4); every other @-form stays the generic token error,
				// the prior field-body default.
				return nil, reject(p, at_tok, .Unexpected_Token)
			}
			// A field directive may sit on its own line above its field; commas
			// stay field separators, so only newlines are skipped here.
			skip_newlines(p)
			continue
		}
		if peek_kind(p) != .Ident {
			break
		}
		fname := advance(p) or_return
		// Field names are value names — snake_case (spec §02).
		if fname.class != .Snake_Case {
			return nil, reject(p, fname, .Wrong_Case)
		}
		expect(p, .Colon) or_return
		type := parse_type_ref(p) or_return
		field := Field_Decl{name = fname.text, type = type}
		if peek_kind(p) == .Eq {
			p.pos += 1
			field.default = parse_expression(p) or_return
			field.has_default = true
		}
		field.migrate = pending_migrate
		field.has_migrate = has_pending_migrate
		if len(pending_probes) > 0 {
			field.probes = pending_probes[:]
		}
		pending_migrate = Migrate_Node{}
		has_pending_migrate = false
		pending_probes = make([dynamic]Debug_Probe, 0, 2, context.temp_allocator)
		append(&list, field)
		skip_field_separators(p)
	}
	if has_pending_migrate {
		// A @migrate with no field following it migrates nothing.
		return nil, .Migrate_Wrong_Target
	}
	if len(pending_probes) > 0 {
		// A @watch with no field following it watches nothing — the
		// dangling-@migrate mold (spec §28 §4: a probe needs its target).
		return nil, .Probe_Wrong_Target
	}
	expect(p, .R_Brace) or_return
	return list[:], .None
}

// parse_enum parses `enum Name { Variant, Variant(T), Variant{ f: T } }`
// (spec §03 §2), with the optional §03 §3 generic header (`enum Option[T]
// { … }`) and the optional enum-as-role kind ascription `enum Steer: Axis
// { … }` (§03 §4), in the fun.ebnf §4 order (EnumDecl ::= 'enum' UPPER_IDENT
// TypeParams? KindAsc? '{' … '}'). Variants are UpperCamel, newline- or
// comma-separated, and a variant may carry a §05 §1 @doc prefix (on its own
// line or inline before the variant), consumed by the variant that follows it
// — the field-level @migrate carry mold. @doc is the ONE directive §05 admits
// on a variant ("each `Draw` variant carries a @doc"); any other directive in
// variant position is a keyed wrong-target verdict: @migrate and
// @index/@spatial keep their directive-keyed verdicts, the rest of the
// declaration family is Variant_Directive_Wrong_Target — never a silently
// dropped annotation.
parse_enum :: proc(p: ^Parser) -> (node: Enum_Node, err: Parse_Error) {
	// `enum` is a contextual keyword (Ident); the by-text dispatch already
	// verified the text, so consume the opener as an Ident here.
	enum_tok := expect(p, .Ident) or_return
	name := expect_type_name(p) or_return
	type_params := parse_type_params(p) or_return
	kind := parse_optional_kind(p) or_return
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	variants := make([dynamic]Variant_Decl, 0, 8, context.temp_allocator)
	pending_doc := ""
	has_pending_doc := false
	for {
		if peek_kind(p) == .At {
			p.pos += 1
			directive := expect(p, .Ident) or_return
			switch directive.text {
			case "doc":
				expect(p, .L_Paren) or_return
				str := expect(p, .String_Lit) or_return
				expect(p, .R_Paren) or_return
				// Last-wins on repetition, the decl-level @doc semantics; the
				// directive may sit on its own line above its variant, so only
				// newlines are skipped (commas stay variant separators).
				pending_doc = str.text
				has_pending_doc = true
				skip_newlines(p)
			case "migrate":
				// The schema-evolution channel targets data fields and renamed
				// type declarations (spec §05 §6), never a variant — the
				// directive-keyed verdict, mirroring parse_field_list.
				return node, reject(p, directive, .Migrate_Wrong_Target)
			case "index", "spatial":
				// §08 §3 places the data-plane index requirement on a `query`
				// declaration only — the directive-keyed verdict.
				return node, reject(p, directive, .Index_Wrong_Target)
			case "gtag", "todo", "expose", "break", "log", "watch", "trace":
				// Well-formed declaration-family directives §05 admits on
				// declarations but NOT on a variant (a variant is not a decl
				// record — it carries no index entry to label, note, or
				// publish, and no step to probe).
				return node, reject(p, directive, .Variant_Directive_Wrong_Target)
			case:
				// Outside the closed §05 directive set entirely — the generic
				// token error, matching parse_directive's default arm.
				return node, reject(p, directive, .Unexpected_Token)
			}
			continue
		}
		if peek_kind(p) != .Ident {
			break
		}
		variant := parse_variant(p) or_return
		variant.doc = pending_doc
		pending_doc = ""
		has_pending_doc = false
		append(&variants, variant)
		skip_field_separators(p)
	}
	if has_pending_doc {
		// A @doc with no variant following it documents nothing — dangling at
		// the body's close is the wrong-target verdict (the @migrate mold).
		return node, .Variant_Directive_Wrong_Target
	}
	expect(p, .R_Brace) or_return
	return Enum_Node{name = name, kind = kind, type_params = type_params, variants = variants[:], line = enum_tok.line}, .None
}

// parse_variant parses one enum variant: plain `Left`, tuple-payload
// `MoveTo(Vec2)`, or struct-payload `Rgb{ r: Fixed, … }` (spec §03 §2).
parse_variant :: proc(p: ^Parser) -> (variant: Variant_Decl, err: Parse_Error) {
	name := expect(p, .Ident) or_return
	// Variant names are UPPER_IDENT (lexical-core.ebnf §2).
	if !is_upper_ident(name.class) {
		return variant, reject(p, name, .Wrong_Case)
	}
	variant.name = name.text
	#partial switch peek_kind(p) {
	case .L_Paren:
		// Tuple payload: positional types.
		p.pos += 1
		types := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
		for peek_kind(p) != .R_Paren {
			type := parse_type_ref(p) or_return
			append(&types, type)
			if peek_kind(p) == .Comma {
				p.pos += 1
			} else {
				break
			}
		}
		expect(p, .R_Paren) or_return
		variant.payload = .Tuple
		variant.tuple = types[:]
	case .L_Brace:
		// Struct payload: named fields, same shape as a data field list.
		fields := parse_field_list(p) or_return
		variant.payload = .Struct
		variant.fields = fields
	case:
		variant.payload = .Plain
	}
	return variant, .None
}

// parse_fn_decl parses a top-level function `fn name(p: T, …) -> R { … }`
// (spec §02 §7, §04). The name is snake_case; the body is the shared
// statement sequence (let/return/if early-return) — generalizing the
// single-return lambda the Pratt cascade carries (expr.odin).
parse_fn_decl :: proc(p: ^Parser) -> (node: Fn_Node, err: Parse_Error) {
	fn_tok := expect(p, .Fn) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, reject(p, name, .Wrong_Case)
	}
	fn := parse_fn_rest(p) or_return
	fn.name = name.text
	fn.line = fn_tok.line
	return fn, .None
}

// parse_extern_declaration dispatches the §02 §7 extern family off the one
// token after the consumed `extern` keyword (LL(1), fun.ebnf §8: ExternDecl
// ::= 'extern' (ExternFn | ExternType)): `fn` opens the body-less
// native-boundary fn, `type` the engine-native opaque type (§26 §2). The
// family is closed, so any other follower is the named Malformed_Extern
// verdict — a stray `extern data …` reports the malformed extern, never a
// generic token error. Both arms consume the shared pending directive block,
// mirroring every other declaration arm of parse_declaration.
parse_extern_declaration :: proc(p: ^Parser, out: ^Decl_Sink, pending: ^Directives) -> Parse_Error {
	extern_tok := expect(p, .Extern) or_return
	#partial switch peek_kind(p) {
	case .Fn:
		// `extern fn` (§02/§26) is the body-less native-boundary fn the §17 seam
		// declares (`extern fn arena_spawns() -> [Spawn]`). It joins ast.fns
		// alongside ordinary fns — same export surface, same term partition — and
		// carries is_extern so the body-typing pass skips it.
		node := parse_extern_fn_decl(p, extern_tok.line) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.fns, node)
		sink_mark(out, .Fn)
	case .Type:
		node := parse_extern_type_decl(p, extern_tok.line) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.extern_types, node)
		sink_mark(out, .Extern_Type)
	case:
		// A peek-reject: p.pos still points AT the stray follower (the `data` in
		// `extern data …`), so the offender is in hand without an advance. Stamp it
		// explicitly so the anchor survives a future refactor that consumes the
		// token before rejecting; the bare token (Token{} at end of input) leaves
		// the span 0 and falls back to parser_stop_span.
		return reject(p, peek_tok(p), .Malformed_Extern)
	}
	return .None
}

// parse_extern_fn_decl parses the `fn name(p: T, …) -> R` remainder of an
// `extern fn` declaration (spec §02 §7, §26) — parse_extern_declaration has
// already consumed the `extern` keyword, whose line is the declaration's span
// anchor. It shares the name and signature grammar with parse_fn_decl but
// stops at the return type — an extern fn has NO `{ … }` body, so the next
// token is the statement terminator, not a brace. The node lands in ast.fns
// with is_extern set, so it exports its name like any fn while the body-typing
// pass skips it. This is the §17 seam's `extern fn arena() -> Arena` form,
// whose implementation the engine provides.
parse_extern_fn_decl :: proc(p: ^Parser, extern_line: int) -> (node: Fn_Node, err: Parse_Error) {
	expect(p, .Fn) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, reject(p, name, .Wrong_Case)
	}
	params := parse_param_list(p) or_return
	expect(p, .Arrow) or_return
	return_type := parse_type_ref(p) or_return
	terminate_statement(p) or_return
	return Fn_Node {
			name = name.text,
			params = params,
			return_type = return_type,
			line = extern_line,
			is_extern = true,
		},
		.None
}

// parse_extern_type_decl parses the `type Name` remainder of an `extern type`
// declaration (spec §02 §7, §26 §2) — parse_extern_declaration has already
// consumed the `extern` keyword, whose line is the declaration's span anchor.
// The UPPER_IDENT name plus the optional §03 §3 generic header (`extern type
// View[T]`, fun.ebnf §8: ExternType ::= 'type' UPPER_IDENT TypeParams?) IS
// the whole declaration: an opaque type carries no funpack-visible fields and
// no body (§26 §2), so the header is followed by the statement terminator.
parse_extern_type_decl :: proc(p: ^Parser, extern_line: int) -> (node: Extern_Type_Node, err: Parse_Error) {
	expect(p, .Type) or_return
	name := expect_type_name(p) or_return
	type_params := parse_type_params(p) or_return
	terminate_statement(p) or_return
	return Extern_Type_Node{name = name, type_params = type_params, line = extern_line}, .None
}

// parse_query parses a §08 §3 first-class query declaration: `query name(p: T,
// …) -> R { … }` (grammar/fun.ebnf §7 QueryDecl). `query` is a contextual
// keyword (Ident); the by-text dispatch in parse_contextual_declaration already
// verified the text, so the opener is consumed as an Ident here. The signature
// grammar is the fn's (snake_case name, typed params, `-> R`); the body is the
// statement Block ONLY — QueryDecl admits no `@stub` body position (FnBody is
// the fn production, grammar/fun.ebnf §7), so a `@` where the body brace
// belongs is an Unexpected_Token, never a silently-admitted hole.
parse_query :: proc(p: ^Parser) -> (node: Query_Node, err: Parse_Error) {
	query_tok := expect(p, .Ident) or_return // `query`
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, reject(p, name, .Wrong_Case)
	}
	params := parse_param_list(p) or_return
	expect(p, .Arrow) or_return
	return_type := parse_type_ref(p) or_return
	body := parse_fn_body(p) or_return
	return Query_Node {
			name = name.text,
			params = params,
			return_type = return_type,
			body = body,
			line = query_tok.line,
		},
		.None
}

// parse_fn_rest parses everything after a function's name: the parameter
// list, the `-> R` return type, and the body — a brace-delimited statement
// Block or a `@stub(…)` typed hole (grammar/fun.ebnf §7: FnBody ::= Block |
// StubExpr; one token of lookahead selects: `{` opens the Block, `@` the
// hole). Shared by top-level fns and the behavior `step` entry point, so a
// behavior step may be holed exactly like a fn.
parse_fn_rest :: proc(p: ^Parser) -> (node: Fn_Node, err: Parse_Error) {
	params := parse_param_list(p) or_return
	expect(p, .Arrow) or_return
	return_type := parse_type_ref(p) or_return
	if peek_kind(p) == .At {
		node = parse_stub_body(p) or_return
		node.params = params
		node.return_type = return_type
		return node, .None
	}
	body := parse_fn_body(p) or_return
	return Fn_Node{params = params, return_type = return_type, body = body}, .None
}

// parse_param_list parses `(name: T, …)` — a function's typed parameters
// (spec §06 §3: a behavior's params are its reads). Parameter names are
// snake_case value names.
parse_param_list :: proc(p: ^Parser) -> (params: []Param_Decl, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	list := make([dynamic]Param_Decl, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		pname := advance(p) or_return
		if pname.class != .Snake_Case {
			return nil, .Wrong_Case
		}
		expect(p, .Colon) or_return
		type := parse_type_ref(p) or_return
		append(&list, Param_Decl{name = pname.text, type = type})
		if peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	expect(p, .R_Paren) or_return
	return list[:], .None
}

// parse_fn_body parses a `{ let … / if … / return … }` statement sequence
// (spec §02 §6). A fn body produces its value only through an explicit
// `return`; an `if cond { return … }` is the early-return guard form.
parse_fn_body :: proc(p: ^Parser) -> (body: []Statement, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	stmts := make([dynamic]Statement, 0, 4, context.temp_allocator)
	body_loop: for {
		#partial switch peek_kind(p) {
		case .Let:
			node := parse_let(p) or_return
			append(&stmts, node)
		case .Return:
			node := parse_return(p) or_return
			append(&stmts, node)
		case .If:
			node := parse_if_stmt(p) or_return
			append(&stmts, node)
		case:
			// A leading binary operator at statement start is a continuation
			// dangling off the prior (already complete) statement — funpack is
			// newline-terminated, so `return a < b` then `and c < d` ended the
			// return on the first line. Name the verdict here, ahead of the
			// R_Brace expectation that would otherwise report a bare
			// Unexpected_Token on the operator (spec §02 §1). The expression-entry
			// seam (expr.odin parse_binary) catches the same fault when the
			// operator opens an expression directly (a match-arm body, a list
			// element); this catches it at the fn-body statement boundary.
			if !at_end(p) && leading_binary_op(p.tokens[p.pos]) {
				return nil, reject(p, p.tokens[p.pos], .Newline_Before_Binary_Op)
			}
			break body_loop
		}
		skip_newlines(p)
	}
	expect(p, .R_Brace) or_return
	return stmts[:], .None
}

// parse_stub_body parses a `@stub(T)` / `@stub(T, fallback)` typed hole
// standing in BODY position (spec §05 §2; grammar/fun.ebnf §7), reached from
// parse_fn_rest when `@` opens the body. It returns a body-less Fn_Node
// carrying the hole: holed set, hole_type the declared T callers typecheck
// against, and — for the two-argument form — the fallback approximation
// expression with has_fallback set. The directive core is the shared
// parse_stub_parts production (the §15 StubExpr expression Atom reads the
// same one, expr.odin parse_stub_atom), so the two hole positions can never
// drift; only the statement terminator is body-specific here.
parse_stub_body :: proc(p: ^Parser) -> (node: Fn_Node, err: Parse_Error) {
	expect(p, .At) or_return
	node.hole_type, node.fallback, node.has_fallback = parse_stub_parts(p) or_return
	node.holed = true
	terminate_statement(p) or_return
	return node, .None
}

// parse_stub_parts parses the shared `'stub' '(' Type (',' Expr)? ')'` core of
// a §05 §2 typed hole, with the leading `@` already consumed — the single
// production BOTH hole positions reach (parse_stub_body for the FnBody form,
// expr.odin parse_stub_atom for the §15 StubExpr expression Atom), so the two
// spellings share one grammar. The directive name is contextual (`@` then an
// Ident, like @doc/@gtag), and only `stub` stands in body or expression
// position — any other directive here is an Unexpected_Token. The parentheses
// lift the no-struct-literal context exactly like CallArgs (expr.odin
// parse_call_args): a record-literal fallback is valid even when the hole
// stands inside a match scrutinee or an `if` condition.
parse_stub_parts :: proc(p: ^Parser) -> (hole_type: Type_Ref, fallback: Expr, has_fallback: bool, err: Parse_Error) {
	name := expect(p, .Ident) or_return
	if name.text != "stub" {
		return hole_type, nil, false, reject(p, name, .Unexpected_Token)
	}
	expect(p, .L_Paren) or_return
	saved := p.no_record_brace
	p.no_record_brace = false
	defer p.no_record_brace = saved
	hole_type = parse_type_ref(p) or_return
	if peek_kind(p) == .Comma {
		p.pos += 1
		fallback = parse_expression(p) or_return
		has_fallback = true
	}
	expect(p, .R_Paren) or_return
	return hole_type, fallback, has_fallback, .None
}

// parse_return parses `return expr` (spec §02 §6) — the mandatory
// value-producing statement of a fn body.
parse_return :: proc(p: ^Parser) -> (node: Return_Node, err: Parse_Error) {
	expect(p, .Return) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Return_Node{value = value}, .None
}

// parse_if_stmt parses the early-return guard `if cond { return … }`
// (spec §02 §5). The condition parses in the no-struct-literal context (a
// trailing `{` opens the guarded block, not a record literal off the
// condition), mirroring the match-scrutinee rule (expr.odin). The body is
// the same fn-body statement sequence.
parse_if_stmt :: proc(p: ^Parser) -> (node: If_Node, err: Parse_Error) {
	expect(p, .If) or_return
	saved := p.no_record_brace
	p.no_record_brace = true
	cond := parse_expression(p) or_return
	p.no_record_brace = saved
	body := parse_fn_body(p) or_return
	return If_Node{cond = cond, body = body}, .None
}

// parse_behavior parses `behavior name on Thing { fn step(…) -> … { … } }`
// (spec §06 §3). The entry point is the reserved name `step` — a behavior
// has exactly one, and any other name is rejected here. The target is the
// `on Thing` UpperCamel type whose blackboard this behavior owns.
parse_behavior :: proc(p: ^Parser) -> (node: Behavior_Node, err: Parse_Error) {
	behavior_tok := expect(p, .Behavior) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, reject(p, name, .Wrong_Case)
	}
	// `on` is a contextual keyword: it lexes as an Ident, so the header
	// separator is recognized by text here (the same by-text recognition the
	// reserved `step` entry point uses below). A behavior header missing the
	// `on` separator is an Unexpected_Token.
	on_tok := expect(p, .Ident) or_return
	if on_tok.text != "on" {
		return node, reject(p, on_tok, .Unexpected_Token)
	}
	target := expect_type_name(p) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	expect(p, .Fn) or_return
	step_name := expect(p, .Ident) or_return
	if step_name.text != "step" {
		// `step` is the built-in, reserved entry point (spec §06 §3); a
		// behavior names no other.
		return node, reject(p, step_name, .Unexpected_Token)
	}
	step := parse_fn_rest(p) or_return
	step.name = "step"
	skip_newlines(p)
	expect(p, .R_Brace) or_return
	return Behavior_Node{name = name.text, target = target, step = step, line = behavior_tok.line}, .None
}

// parse_pipeline parses `pipeline Name { stage: value … }` (spec §07 §1).
// Stage order is the contract, so stages keep source order. A stage value is
// either a `[behavior, …]` list or a single bare battery name (`physics:
// solve`); a leading `[` selects the list form, a bare ident the battery form.
// A stage entry may carry a leading §28 §4 @trace probe (the grammar puts
// Annotation* on StageEntry, fun.ebnf §9), consumed by the stage that follows
// it — the field-level @migrate carry mold. @trace is the ONE probe the
// On-table admits on a stage, so a misplaced @break/@log/@watch is
// Probe_Wrong_Target and every other @-form is the generic token error.
parse_pipeline :: proc(p: ^Parser) -> (node: Pipeline_Node, err: Parse_Error) {
	pipeline_tok := expect(p, .Pipeline) or_return
	name := expect_type_name(p) or_return
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	stages := make([dynamic]Pipeline_Stage, 0, 8, context.temp_allocator)
	// pending_probes accumulates the @trace prefix that attaches to the stage
	// which follows — the field-level @migrate carry mold. Annotation* is a
	// star, so several @trace lines stack the way declaration-prefix probes do.
	pending_probes := make([dynamic]Debug_Probe, 0, 2, context.temp_allocator)
	for {
		if peek_kind(p) == .At {
			at_tok := advance(p) or_return
			directive := expect(p, .Ident) or_return
			switch directive.text {
			case "trace":
				// @trace takes NO argument (spec §05 §5; fun.ebnf §1
				// DebugDirective): it records the stage's full per-step
				// (in -> out) transition. A parenthesized argument is the named
				// Probe_Unexpected_Arg verdict, the declaration-prefix @trace mold.
				if peek_kind(p) == .L_Paren {
					return node, reject(p, directive, .Probe_Unexpected_Arg)
				}
				append(&pending_probes, Debug_Probe{kind = .Trace, line = at_tok.line})
			case "break", "log", "watch":
				// Well-formed debug probes the On-table places on a behavior or a
				// `data` field, never a stage (spec §28 §4) — the keyed
				// wrong-target verdict, never a silently dropped probe.
				return node, reject(p, directive, .Probe_Wrong_Target)
			case:
				// @trace is the only stage-entry directive (spec §28 §4); every
				// other @-form stays the generic token error, mirroring the
				// field-body default.
				return node, reject(p, directive, .Unexpected_Token)
			}
			// A stage directive may sit on its own line above its stage; commas
			// stay stage separators, so only newlines are skipped here.
			skip_newlines(p)
			continue
		}
		if peek_kind(p) != .Ident {
			break
		}
		sname := advance(p) or_return
		// Stage names are documentary value names — snake_case (spec §07).
		if sname.class != .Snake_Case {
			return node, reject(p, sname, .Wrong_Case)
		}
		expect(p, .Colon) or_return
		stage := parse_pipeline_stage(p, sname.text) or_return
		if len(pending_probes) > 0 {
			stage.probes = pending_probes[:]
		}
		pending_probes = make([dynamic]Debug_Probe, 0, 2, context.temp_allocator)
		append(&stages, stage)
		skip_field_separators(p)
	}
	if len(pending_probes) > 0 {
		// A @trace with no stage following it traces nothing — the
		// dangling-@migrate mold (spec §28 §4: a probe needs its target).
		return node, .Probe_Wrong_Target
	}
	expect(p, .R_Brace) or_return
	return Pipeline_Node{name = name, stages = stages[:], line = pipeline_tok.line}, .None
}

// parse_pipeline_stage parses one stage's value after its `name:` (spec §07
// §1): a `[behavior, …]` list, or a single bare battery name (`solve`). A
// leading `[` opens the behavior-list form; a bare snake_case ident is the
// battery form — an engine-owned stage (yard `physics: solve`) carrying no
// user behaviors. The battery name is recorded as written; validating that it
// names a real battery is the surface/typecheck story's job.
parse_pipeline_stage :: proc(p: ^Parser, name: string) -> (stage: Pipeline_Stage, err: Parse_Error) {
	if peek_kind(p) == .L_Bracket {
		behaviors := parse_behavior_list(p) or_return
		return Pipeline_Stage{name = name, behaviors = behaviors}, .None
	}
	battery := expect(p, .Ident) or_return
	// A battery name is a value name — snake_case (spec §07).
	if battery.class != .Snake_Case {
		return stage, reject(p, battery, .Wrong_Case)
	}
	return Pipeline_Stage{name = name, battery = battery.text, is_battery = true}, .None
}

// parse_behavior_list parses a `[behavior_name, …]` stage value
// (spec §07 §1). Behavior names are snake_case; the list is newline- or
// comma-separated, though a stage value sits on one line in the golden
// surface.
parse_behavior_list :: proc(p: ^Parser) -> (names: []string, err: Parse_Error) {
	expect(p, .L_Bracket) or_return
	list := make([dynamic]string, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		bname := advance(p) or_return
		if bname.class != .Snake_Case {
			return nil, reject(p, bname, .Wrong_Case)
		}
		append(&list, bname.text)
		for peek_kind(p) == .Comma || peek_kind(p) == .Newline {
			p.pos += 1
		}
	}
	expect(p, .R_Bracket) or_return
	return list[:], .None
}

// parse_type_ref parses a syntactic type (spec §02 §3): a bare name
// (`Fixed`), a generic application (`View[Paddle]`, `Option[Side]`), a list
// (`[Goal]`), a tuple (`(Rng, [Spawn])` — the §04 §1 return pair), or a
// function type (`fn(T) -> Bool`). A list is recorded as the head "[]" with
// one argument, a tuple as the head "()" with its positional element types as
// args, and a function type as the head "fn" with its parameter types then
// its result as args, so every parameterized form shares one node shape. The
// selecting token is single and disjoint (fun.ll1.md §3: FIRST(Type) = { Ʉ,
// '[', fn }). This is parse-only — no resolution to a checker Type.
parse_type_ref :: proc(p: ^Parser) -> (type: Type_Ref, err: Parse_Error) {
	if peek_kind(p) == .L_Bracket {
		// List type `[T]` — the head is "[]" with the element as its arg.
		p.pos += 1
		elem := parse_type_ref(p) or_return
		expect(p, .R_Bracket) or_return
		args := make([]Type_Ref, 1, context.temp_allocator)
		args[0] = elem
		return Type_Ref{name = "[]", args = args}, .None
	}
	if peek_kind(p) == .L_Paren {
		return parse_tuple_type_ref(p)
	}
	if peek_kind(p) == .Fn {
		return parse_fn_type_ref(p)
	}
	name := expect(p, .Ident) or_return
	// Type names are UPPER_IDENT (spec §02; lexical-core.ebnf §2); the
	// wrong-case verdict fires before the construct is built.
	if !is_upper_ident(name.class) {
		return type, reject(p, name, .Wrong_Case)
	}
	type.name = name.text
	if peek_kind(p) == .L_Bracket {
		// Generic application `Name[T, …]` (spec §03 §3: generics on
		// engine/stdlib containers only).
		p.pos += 1
		args := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
		for peek_kind(p) != .R_Bracket {
			arg := parse_type_ref(p) or_return
			append(&args, arg)
			if peek_kind(p) == .Comma {
				p.pos += 1
			} else {
				break
			}
		}
		expect(p, .R_Bracket) or_return
		type.args = args[:]
	}
	return type, .None
}

// parse_tuple_type_ref parses a tuple type `(T, U, …)` after the `(` is the
// peeked head (spec §02 §3; §04 §1 — the `(value, next_rng)` return pair). It
// is recorded as the head "()" with its positional element Type_Refs as args,
// mirroring the list head "[]", so a tuple stays one node shape. A tuple type
// has two or more positional element types — the snake/hunt return pairs.
parse_tuple_type_ref :: proc(p: ^Parser) -> (type: Type_Ref, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	args := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
	for peek_kind(p) != .R_Paren {
		arg := parse_type_ref(p) or_return
		append(&args, arg)
		if peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	expect(p, .R_Paren) or_return
	return Type_Ref{name = "()", args = args[:]}, .None
}

// parse_fn_type_ref parses a function type `fn(T, …) -> R` after the `fn` is
// the peeked head (spec §02 §3; fun.ebnf §11: FnType ::= 'fn' '(' (Type (','
// Type)*)? ')' '->' Type — the type a combinator parameter declares, `pred:
// fn(T) -> Bool`). It is recorded as the head "fn" whose args are the
// parameter types followed by the result — the LAST arg is always the result,
// so a zero-parameter `fn() -> R` carries exactly one arg — mirroring the
// list/tuple sentinel heads so a function type stays one node shape. A
// mis-shaped form — a missing `(`, a trailing comma or non-type parameter, a
// missing `)`/comma between parameters, a missing `->` — is the named
// Malformed_Fn_Type verdict (the Malformed_Type_Params mold); an element
// type's own errors keep their verdicts. NOTE: `fn` stays a RESERVED keyword
// everywhere else (fun.ll1.md §2) — a parameter NAMED `fn` is rejected by
// parse_param_list, since Param ::= LOWER_IDENT ':' Type admits no keyword
// in name position.
parse_fn_type_ref :: proc(p: ^Parser) -> (type: Type_Ref, err: Parse_Error) {
	expect(p, .Fn) or_return
	if peek_kind(p) != .L_Paren {
		// `fn T -> R` / a bare `fn` — the parameter parens are mandatory.
		return type, .Malformed_Fn_Type
	}
	p.pos += 1
	args := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
	if peek_kind(p) != .R_Paren {
		for {
			if !type_ref_ahead(p) {
				// A trailing comma (`fn(T,) -> R`) or a non-type token where a
				// parameter type belongs — the grammar requires a Type after `(`
				// and after every comma.
				return type, .Malformed_Fn_Type
			}
			arg := parse_type_ref(p) or_return
			append(&args, arg)
			if peek_kind(p) == .Comma {
				p.pos += 1
				continue
			}
			break
		}
	}
	if peek_kind(p) != .R_Paren {
		// `fn(T U) -> R` / `fn(T -> R` — parameters are comma-separated and
		// nothing else stands between the last parameter and the closer.
		return type, .Malformed_Fn_Type
	}
	p.pos += 1
	if peek_kind(p) != .Arrow {
		// `fn(T) Bool` — the result arrow is mandatory (a function type always
		// names its result).
		return type, .Malformed_Fn_Type
	}
	p.pos += 1
	result := parse_type_ref(p) or_return
	append(&args, result)
	return Type_Ref{name = "fn", args = args[:]}, .None
}

// type_ref_ahead reports whether the next token can open a syntactic type —
// FIRST(Type) plus the tuple `(` parse_type_ref also admits (fun.ll1.md §3:
// FIRST(ReturnType) = { Ʉ, '[', fn, '(' }). Used by parse_fn_type_ref to give
// a mis-placed parameter the named Malformed_Fn_Type verdict instead of the
// generic token error parse_type_ref would raise.
type_ref_ahead :: proc(p: ^Parser) -> bool {
	#partial switch peek_kind(p) {
	case .Ident, .L_Bracket, .L_Paren, .Fn:
		return true
	}
	return false
}

// expect_type_name consumes an UpperCamel type name — the declared name of
// a data/enum/thing/signal/pipeline or a kind/target ascription (spec §02).
expect_type_name :: proc(p: ^Parser) -> (name: string, err: Parse_Error) {
	tok := expect(p, .Ident) or_return
	// A declared type name or kind/target ascription is UPPER_IDENT
	// (lexical-core.ebnf §2).
	if !is_upper_ident(tok.class) {
		return "", reject(p, tok, .Wrong_Case)
	}
	return tok.text, .None
}

// skip_field_separators consumes the newline-or-comma run between fields,
// variants, or stages (spec §02 §1: both are legal separators).
skip_field_separators :: proc(p: ^Parser) {
	for peek_kind(p) == .Newline || peek_kind(p) == .Comma {
		p.pos += 1
	}
}

// check_ident_case enforces the casing-is-structural rule (spec §02): a
// name followed by `{` (record-literal constructor) or `::` (variant
// selector) stands in type position and must be UPPER_IDENT; a name
// followed by `.` is a member-access receiver — a value name or a
// type's associated module (Fixed.MAX, Quat.identity) — so any sanctioned
// class passes; a name followed by `(` is a callee — a snake_case function
// (clamp(…)) or an UPPER_IDENT command/type constructor (Spawn(…),
// Despawn()) — so any sanctioned class passes there too; any other
// value/function name must be snake_case, or UPPER_SNAKE for a bare
// constant. The casing verdict fires before the construct is parsed, so a
// wrong-case name always reports Wrong_Case rather than a generic
// Unexpected_Token.
check_ident_case :: proc(p: ^Parser, tok: Token, following: Token_Kind) -> Parse_Error {
	if tok.class == .Mixed {
		return reject(p, tok, .Wrong_Case)
	}
	#partial switch following {
	case .L_Brace, .Colon_Colon:
		// A record-literal constructor or an enum-type head stands in type
		// position — an UPPER_IDENT (lexical-core.ebnf §2), which admits a
		// single-capital head as well as multi-word UpperCamel.
		if !is_upper_ident(tok.class) {
			return reject(p, tok, .Wrong_Case)
		}
	case .Dot, .L_Paren:
		// A member-access receiver or a callee — any sanctioned class.
	case:
		if tok.class != .Snake_Case && tok.class != .Upper_Snake {
			return reject(p, tok, .Wrong_Case)
		}
	}
	return .None
}

// terminate_statement consumes the newline statement terminator
// (spec §02); end of input and a closing brace also end the last
// statement of their scope.
terminate_statement :: proc(p: ^Parser) -> Parse_Error {
	if peek_kind(p) == .Newline {
		p.pos += 1
		return .None
	}
	if at_end(p) || peek_kind(p) == .R_Brace {
		return .None
	}
	return .Unexpected_Token
}

at_end :: proc(p: ^Parser) -> bool {
	return p.pos >= len(p.tokens)
}

// peek_kind reports Invalid at end of input so callers' kind checks
// fail closed without a separate end test.
peek_kind :: proc(p: ^Parser) -> Token_Kind {
	if at_end(p) {
		return .Invalid
	}
	return p.tokens[p.pos].kind
}

// peek_tok returns the current token without consuming it — the offender a
// peek-reject (a fault raised before `advance`) names. At end of input there is
// no token, so it returns the zero Token (line/col 0), which reject leaves
// unstamped, deferring to parser_stop_span. Used at the rare peek-reject sites
// that want to stamp the offender explicitly rather than rely on the fallback.
peek_tok :: proc(p: ^Parser) -> Token {
	if at_end(p) {
		return Token{}
	}
	return p.tokens[p.pos]
}

// advance consumes one token. It is the central choke point for the lexer's
// named-error tokens: a Malformed_Escape string literal maps to the
// Malformed_String_Escape verdict HERE, so a string-consuming position (an
// expression atom, @doc, a test name) reports the named verdict without
// per-site checks. A peek-guarded directive-argument loop (@gtag, @migrate)
// surfaces its own sibling verdict instead — still a reject, never a skip.
// Sound because the direct `p.pos += 1` consumption sites are all
// peek-guarded by a specific expected kind, which a Malformed_Escape token
// never matches.
advance :: proc(p: ^Parser) -> (tok: Token, err: Parse_Error) {
	if at_end(p) {
		return Token{}, .Unexpected_End
	}
	tok = p.tokens[p.pos]
	p.pos += 1
	if tok.kind == .Malformed_Escape {
		return Token{}, .Malformed_String_Escape
	}
	return tok, .None
}

expect :: proc(p: ^Parser, kind: Token_Kind) -> (tok: Token, err: Parse_Error) {
	tok = advance(p) or_return
	if tok.kind != kind {
		return Token{}, .Unexpected_Token
	}
	return tok, .None
}

skip_newlines :: proc(p: ^Parser) {
	for peek_kind(p) == .Newline {
		p.pos += 1
	}
}
