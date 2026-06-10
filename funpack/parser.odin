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
}

Test_Node :: struct {
	name: string,
	doc:  string, // the @doc directive preceding this test ("" when absent)
	body: []Statement,
	line: int,    // 1-based source line of the `test` keyword (artifact-format §9 span provenance)
}

// Type_Ref is the parse-only syntactic type the declaration grammar
// records: a bare name (`Fixed`, `Side`), a generic application
// (`View[Paddle]`, `Option[Side]`), a list (`[Goal]`, `[Spawn]`), or a tuple
// (`(Rng, [Spawn])` — the §04 §1 `(value, next_rng)` return pair). It is
// purely structural — no resolution to the checker's semantic Type
// (type.odin) happens here; that is the resolve stage's job. A list is
// modeled as the head "[]" with one argument and a tuple as the head "()"
// with its positional element types as args, so every parameterized form
// shares one node shape.
Type_Ref :: struct {
	name: string,     // the head name; "[]" for a list `[T]`, "()" for a tuple `(T, …)`
	args: []Type_Ref, // generic / list / tuple element arguments; empty for a bare name
}

// Field_Decl is one `name: Type` (or `name: Type = default`) entry in a
// data/thing/singleton/signal body. has_default distinguishes a defaulted
// field (spec §03 §1) from a required one; default is meaningless when
// has_default is false. migrate is the field's §05 §6 @migrate prefix —
// rename/retype evolution metadata only a `data` field may carry (the parser
// rejects it elsewhere); meaningless when has_migrate is false, mirroring
// has_default.
Field_Decl :: struct {
	name:        string,
	type:        Type_Ref,
	default:     Expr,
	has_default: bool,
	migrate:     Migrate_Node,
	has_migrate: bool,
}

// Variant_Decl is one enum variant (spec §03 §2): plain (`Left`),
// tuple-payload (`MoveTo(Vec2)`), or struct-payload (`Rgb{ r: Fixed, … }`).
// The payload shape is the closed Variant_Payload tag; tuple args live in
// `tuple`, struct fields in `fields`.
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
	name:   string,
	type:   Type_Ref,
	value:  Expr,
	doc:    string,
	gtags:  []string, // @gtag("…") labels attached to this declaration
	probes: []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:  []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	line:   int, // 1-based source line of the `let` keyword (artifact-format §9 span provenance)
}

Data_Node :: struct {
	name:   string,
	kind:   string, // the `Name: Kind` ascription (§03 §4); "" when absent
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
	line:        int, // 1-based source line of the `data` keyword (artifact-format §9 span provenance)
}

Enum_Node :: struct {
	name:     string,
	kind:     string, // the enum-as-role kind (`enum Steer: Axis`); "" when absent
	variants: []Variant_Decl,
	doc:      string,
	gtags:    []string,
	probes:   []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:    []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
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
	line:         int, // 1-based source line of the `thing`/`singleton` keyword (artifact-format §9 span provenance)
}

Signal_Node :: struct {
	name:   string,
	fields: []Field_Decl,
	doc:    string,
	gtags:  []string,
	probes: []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:  []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	line:   int, // 1-based source line of the `signal` keyword (artifact-format §9 span provenance)
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

// Behavior_Node is a pure transition attached to a thing (spec §06 §3):
// `behavior name on Thing { fn step(…) -> … { … } }`. target is the `on
// Thing` type name; step is the single reserved entry point (the parser
// enforces the name `step`).
Behavior_Node :: struct {
	name:   string,
	target: string,
	step:   Fn_Node,
	doc:    string,
	gtags:  []string,
	probes: []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:  []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	line:   int, // 1-based source line of the `behavior` keyword (artifact-format §9 span provenance)
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
Pipeline_Stage :: struct {
	name:       string,
	behaviors:  []string, // behavior-list stage: the member behavior names
	battery:    string,   // single-battery stage: the bare battery name
	is_battery: bool,      // true for the bare-battery stage form
}

Pipeline_Node :: struct {
	name:   string,
	stages: []Pipeline_Stage,
	doc:    string,
	gtags:  []string,
	probes: []Debug_Probe, // §05 §5 debug directives attached to this declaration
	todos:  []Todo_Node, // @todo("msg", window) notes attached to this declaration (spec §05 §2)
	line:   int, // 1-based source line of the `pipeline` keyword (artifact-format §9 span provenance)
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

// Directives carries the @doc / @gtag / @todo / @migrate / debug-probe prefix
// block attached to a declaration (spec §05). It accumulates as leading
// directives are parsed and is consumed by the declaration that follows them.
// migrate is the §05 §6 declaration-level form — a renamed TYPE declaration —
// which only a `data` declaration may consume (Migrate_Wrong_Target
// otherwise); at most one accumulates (a second is Malformed_Migrate).
Directives :: struct {
	doc:         string,
	gtags:       [dynamic]string,
	probes:      [dynamic]Debug_Probe,
	todos:       [dynamic]Todo_Node,
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
	Malformed_Todo_Window, // a @todo whose mandatory window is missing or matches none of the four §05 §2 forms (unknown unit, mis-shaped/out-of-range ISO date, quoted or lowercase task ref)
	Malformed_Migrate,     // a @migrate whose argument list matches none of the three closed §05 §6 forms (missing/empty parens, unknown or duplicated key, with-before-from order, unquoted from, empty prior name, trailing junk) — or a second @migrate on one target
	Migrate_Wrong_Target,  // a well-formed @migrate where the spec admits none (spec §05 §6): prefixing a non-`data` declaration, a field outside a `data` body, a retype (`with:`) form on a type declaration (a type admits the rename form only), or dangling with no field to attach to
}

Parser :: struct {
	tokens: []Token,
	pos:    int,
	// no_record_brace marks the no-struct-literal context of a match
	// scrutinee (spec §02 §5): the `{` after the scrutinee opens the
	// match block, so a name in scrutinee position must not consume it as
	// a record literal. Set only while parsing the scrutinee.
	no_record_brace: bool,
}

stage_parse :: proc(tokens: []Token) -> (ast: Ast, err: Parse_Error) {
	p := Parser{tokens = tokens}
	out := Decl_Sink {
		imports   = make([dynamic]Import_Node, 0, 8, context.temp_allocator),
		lets      = make([dynamic]Let_Decl_Node, 0, 4, context.temp_allocator),
		datas     = make([dynamic]Data_Node, 0, 4, context.temp_allocator),
		enums     = make([dynamic]Enum_Node, 0, 4, context.temp_allocator),
		things    = make([dynamic]Thing_Node, 0, 8, context.temp_allocator),
		signals   = make([dynamic]Signal_Node, 0, 4, context.temp_allocator),
		fns       = make([dynamic]Fn_Node, 0, 16, context.temp_allocator),
		behaviors = make([dynamic]Behavior_Node, 0, 16, context.temp_allocator),
		pipelines = make([dynamic]Pipeline_Node, 0, 2, context.temp_allocator),
		tests     = make([dynamic]Test_Node, 0, 8, context.temp_allocator),
	}
	module_doc := ""
	seen_decl := false
	pending := empty_directives()
	skip_newlines(&p)
	for !at_end(&p) {
		if peek_kind(&p) == .At {
			parse_directive(&p, &module_doc, &pending, seen_decl) or_return
			skip_newlines(&p)
			continue
		}
		parse_declaration(&p, &out, &pending) or_return
		seen_decl = true
		// Each declaration consumes its leading directives.
		pending = empty_directives()
		skip_newlines(&p)
	}
	return Ast {
			module_doc = module_doc,
			imports = out.imports[:],
			lets = out.lets[:],
			datas = out.datas[:],
			enums = out.enums[:],
			things = out.things[:],
			signals = out.signals[:],
			fns = out.fns[:],
			behaviors = out.behaviors[:],
			pipelines = out.pipelines[:],
			tests = out.tests[:],
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
	}
}

// Decl_Sink collects the per-kind declaration slices stage_parse builds.
// One sink threaded through parse_declaration keeps the dispatch loop flat
// and the per-kind append sites obvious.
Decl_Sink :: struct {
	imports:   [dynamic]Import_Node,
	lets:      [dynamic]Let_Decl_Node,
	datas:     [dynamic]Data_Node,
	enums:     [dynamic]Enum_Node,
	things:    [dynamic]Thing_Node,
	signals:   [dynamic]Signal_Node,
	fns:       [dynamic]Fn_Node,
	behaviors: [dynamic]Behavior_Node,
	pipelines: [dynamic]Pipeline_Node,
	tests:     [dynamic]Test_Node,
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
		append(&out.lets, node)
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
		append(&out.signals, node)
	case .Fn:
		node := parse_fn_decl(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		append(&out.fns, node)
	case .Extern:
		// `extern fn` (§02/§26) is the body-less native-boundary fn the §17 seam
		// declares (`extern fn arena_spawns() -> [Spawn]`). It joins ast.fns
		// alongside ordinary fns — same export surface, same term partition — and
		// carries is_extern so the body-typing pass skips it.
		node := parse_extern_fn_decl(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		append(&out.fns, node)
	case .Behavior:
		node := parse_behavior(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		append(&out.behaviors, node)
	case .Pipeline:
		node := parse_pipeline(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		append(&out.pipelines, node)
	case .Test:
		node := parse_test(p) or_return
		node.doc = pending.doc
		append(&out.tests, node)
	case:
		return .Unexpected_Token
	}
	return .None
}

// parse_contextual_declaration dispatches a `data`/`enum`/`thing`/`singleton`
// declaration off the leading Ident's TEXT (fun.ll1.md §2: these are contextual
// keywords, lexed as Ident). It is reached only from parse_declaration, i.e.
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
		append(&out.datas, node)
	case "enum":
		node := parse_enum(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		append(&out.enums, node)
	case "thing", "singleton":
		node := parse_thing(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		append(&out.things, node)
	case:
		return .Unexpected_Token
	}
	return .None
}

// parse_directive parses one declaration-prefix directive (spec §05):
// `@doc("…")`, `@gtag("…", …)`, `@todo("msg", window)`, or a §05 §5 debug
// probe (@break/@log/@watch/@trace). The file-leading @doc documents the module
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
			return .Malformed_Todo_Window
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
			return .Probe_Missing_Arg
		}
		p.pos += 1
		if peek_kind(p) == .R_Paren {
			return .Probe_Missing_Arg
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
			return .Malformed_Migrate
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
			return .Probe_Unexpected_Arg
		}
		terminate_statement(p) or_return
		append(&pending.probes, Debug_Probe{kind = .Trace, line = at_tok.line})
	case:
		// Only @doc/@gtag and the §05 §5 debug probes prefix a declaration.
		// @stub in particular is NOT a prefix directive — it stands in
		// body/expression position only (spec §05: parse_stub_body owns it),
		// so a leading `@stub` is an Unexpected_Token here, never silently
		// accepted.
		return .Unexpected_Token
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
			// count (spec §05 §2: one obvious spelling each).
			return window, .Malformed_Todo_Window
		}
		unit := advance(p) or_return
		switch unit.text {
		case "h", "d", "w", "mo", "q", "y":
			return Todo_Window{form = .Duration, amount = lead.int_value, unit = unit.text}, .None
		case "builds":
			return Todo_Window{form = .Build_Count, amount = lead.int_value}, .None
		case:
			return window, .Malformed_Todo_Window
		}
	case .Ident:
		// Task ref `T-<digits>` — the recommended default. The lead is the
		// literal uppercase `T`: a lowercase `t-0042` matches no form.
		lead := advance(p) or_return
		if lead.text != "T" || peek_kind(p) != .Minus {
			return window, .Malformed_Todo_Window
		}
		p.pos += 1
		if peek_kind(p) != .Int_Lit {
			return window, .Malformed_Todo_Window
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
	if len(year_tok.text) != 4 {
		return window, .Malformed_Todo_Window
	}
	p.pos += 1 // the first `-` (the caller peeked it)
	if peek_kind(p) != .Int_Lit {
		return window, .Malformed_Todo_Window
	}
	month_tok := advance(p) or_return
	if len(month_tok.text) != 2 || month_tok.int_value < 1 || month_tok.int_value > 12 {
		return window, .Malformed_Todo_Window
	}
	if peek_kind(p) != .Minus {
		return window, .Malformed_Todo_Window
	}
	p.pos += 1
	if peek_kind(p) != .Int_Lit {
		return window, .Malformed_Todo_Window
	}
	day_tok := advance(p) or_return
	if len(day_tok.text) != 2 || day_tok.int_value < 1 || day_tok.int_value > 31 {
		return window, .Malformed_Todo_Window
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
			return node, .Malformed_Migrate
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
		return .Wrong_Case
	}
	node.with = convert.text
	node.has_with = true
	return .None
}

parse_import :: proc(p: ^Parser) -> (node: Import_Node, err: Parse_Error) {
	expect(p, .Import) or_return
	segments := make([dynamic]string, 0, 4, context.temp_allocator)
	members: []string
	for {
		tok := expect(p, .Ident) or_return
		if peek_kind(p) == .Dot {
			// An interior segment is a module name — snake_case only
			// (spec §02); the final segment may also be an UpperCamel
			// type or UPPER_SNAKE constant member.
			if tok.class != .Snake_Case {
				return node, .Wrong_Case
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
			return node, .Wrong_Case
		}
		append(&segments, tok.text)
		break
	}
	terminate_statement(p) or_return
	return Import_Node{segments = segments[:], members = members}, .None
}

parse_import_group :: proc(p: ^Parser) -> (members: []string, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	list := make([dynamic]string, 0, 8, context.temp_allocator)
	skip_newlines(p)
	for peek_kind(p) == .Ident {
		tok := advance(p) or_return
		if tok.class == .Mixed {
			return nil, .Wrong_Case
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
		return node, .Wrong_Case
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
		return node, .Wrong_Case
	}
	expect(p, .Colon) or_return
	type := parse_type_ref(p) or_return
	expect(p, .Eq) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Let_Decl_Node{name = name.text, type = type, value = value, line = let_tok.line}, .None
}

// parse_data parses `data Name { field: T = default … }` (spec §03 §1),
// with the optional `data Name: Kind { … }` kind ascription (§03 §4). The
// kind is contextual — a bare UpperCamel name in the post-colon position,
// never a reserved word.
parse_data :: proc(p: ^Parser) -> (node: Data_Node, err: Parse_Error) {
	// `data` is a contextual keyword (Ident); the by-text dispatch in
	// parse_contextual_declaration already verified the text, so consume the
	// opener as an Ident here.
	data_tok := expect(p, .Ident) or_return
	name := expect_type_name(p) or_return
	kind := parse_optional_kind(p) or_return
	// A data body is the one field list whose fields may carry a §05 §6
	// @migrate prefix — the name-keyed schema is the evolution channel.
	fields := parse_field_list(p, allow_migrate = true) or_return
	return Data_Node{name = name, kind = kind, fields = fields, line = data_tok.line}, .None
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
// field may be omitted from a literal). allow_migrate is true only for a
// `data` body: a field there may carry a §05 §6 @migrate prefix (on its own
// line or inline before the field), consumed by the field that follows it —
// elsewhere a @migrate is the named Migrate_Wrong_Target verdict (the
// schema-evolution channel is the name-keyed `data` schema, spec §09 §4), as
// is one left dangling with no field to attach to.
parse_field_list :: proc(p: ^Parser, allow_migrate := false) -> (fields: []Field_Decl, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	list := make([dynamic]Field_Decl, 0, 8, context.temp_allocator)
	pending_migrate := Migrate_Node{}
	has_pending_migrate := false
	for {
		if peek_kind(p) == .At {
			at_tok := advance(p) or_return
			directive := expect(p, .Ident) or_return
			if directive.text != "migrate" {
				// @migrate is the one directive a field admits here (spec §05
				// §6); any other @-form in a field body stays the generic
				// token error.
				return nil, .Unexpected_Token
			}
			if !allow_migrate {
				return nil, .Migrate_Wrong_Target
			}
			if has_pending_migrate {
				// A second @migrate before one field — never a silent
				// overwrite.
				return nil, .Malformed_Migrate
			}
			pending_migrate = parse_migrate_args(p, at_tok.line) or_return
			has_pending_migrate = true
			// The directive may sit on its own line above its field; commas
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
			return nil, .Wrong_Case
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
		pending_migrate = Migrate_Node{}
		has_pending_migrate = false
		append(&list, field)
		skip_field_separators(p)
	}
	if has_pending_migrate {
		// A @migrate with no field following it migrates nothing.
		return nil, .Migrate_Wrong_Target
	}
	expect(p, .R_Brace) or_return
	return list[:], .None
}

// parse_enum parses `enum Name { Variant, Variant(T), Variant{ f: T } }`
// (spec §03 §2), with the optional enum-as-role kind ascription
// `enum Steer: Axis { … }` (§03 §4). Variants are UpperCamel, newline- or
// comma-separated.
parse_enum :: proc(p: ^Parser) -> (node: Enum_Node, err: Parse_Error) {
	// `enum` is a contextual keyword (Ident); the by-text dispatch already
	// verified the text, so consume the opener as an Ident here.
	enum_tok := expect(p, .Ident) or_return
	name := expect_type_name(p) or_return
	kind := parse_optional_kind(p) or_return
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	variants := make([dynamic]Variant_Decl, 0, 8, context.temp_allocator)
	for peek_kind(p) == .Ident {
		variant := parse_variant(p) or_return
		append(&variants, variant)
		skip_field_separators(p)
	}
	expect(p, .R_Brace) or_return
	return Enum_Node{name = name, kind = kind, variants = variants[:], line = enum_tok.line}, .None
}

// parse_variant parses one enum variant: plain `Left`, tuple-payload
// `MoveTo(Vec2)`, or struct-payload `Rgb{ r: Fixed, … }` (spec §03 §2).
parse_variant :: proc(p: ^Parser) -> (variant: Variant_Decl, err: Parse_Error) {
	name := expect(p, .Ident) or_return
	// Variant names are UPPER_IDENT (lexical-core.ebnf §2).
	if !is_upper_ident(name.class) {
		return variant, .Wrong_Case
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
		return node, .Wrong_Case
	}
	fn := parse_fn_rest(p) or_return
	fn.name = name.text
	fn.line = fn_tok.line
	return fn, .None
}

// parse_extern_fn_decl parses an `extern fn name(p: T, …) -> R` declaration
// (spec §02 §7, §26): a body-less native-boundary function. It shares the name
// and signature grammar with parse_fn_decl but stops at the return type — an
// extern fn has NO `{ … }` body, so the next token is the statement terminator,
// not a brace. The node lands in ast.fns with is_extern set, so it exports its
// name like any fn while the body-typing pass skips it. This is the §17 seam's
// `extern fn arena() -> Arena` form, whose implementation the engine provides.
parse_extern_fn_decl :: proc(p: ^Parser) -> (node: Fn_Node, err: Parse_Error) {
	extern_tok := expect(p, .Extern) or_return
	expect(p, .Fn) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, .Wrong_Case
	}
	params := parse_param_list(p) or_return
	expect(p, .Arrow) or_return
	return_type := parse_type_ref(p) or_return
	terminate_statement(p) or_return
	return Fn_Node {
			name = name.text,
			params = params,
			return_type = return_type,
			line = extern_tok.line,
			is_extern = true,
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
		return hole_type, nil, false, .Unexpected_Token
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
		return node, .Wrong_Case
	}
	// `on` is a contextual keyword: it lexes as an Ident, so the header
	// separator is recognized by text here (the same by-text recognition the
	// reserved `step` entry point uses below). A behavior header missing the
	// `on` separator is an Unexpected_Token.
	on_tok := expect(p, .Ident) or_return
	if on_tok.text != "on" {
		return node, .Unexpected_Token
	}
	target := expect_type_name(p) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	expect(p, .Fn) or_return
	step_name := expect(p, .Ident) or_return
	if step_name.text != "step" {
		// `step` is the built-in, reserved entry point (spec §06 §3); a
		// behavior names no other.
		return node, .Unexpected_Token
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
parse_pipeline :: proc(p: ^Parser) -> (node: Pipeline_Node, err: Parse_Error) {
	pipeline_tok := expect(p, .Pipeline) or_return
	name := expect_type_name(p) or_return
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	stages := make([dynamic]Pipeline_Stage, 0, 8, context.temp_allocator)
	for peek_kind(p) == .Ident {
		sname := advance(p) or_return
		// Stage names are documentary value names — snake_case (spec §07).
		if sname.class != .Snake_Case {
			return node, .Wrong_Case
		}
		expect(p, .Colon) or_return
		stage := parse_pipeline_stage(p, sname.text) or_return
		append(&stages, stage)
		skip_field_separators(p)
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
		return stage, .Wrong_Case
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
			return nil, .Wrong_Case
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
// (`[Goal]`), or a tuple (`(Rng, [Spawn])` — the §04 §1 return pair). A list
// is recorded as the head "[]" with one argument and a tuple as the head "()"
// with its positional element types as args, so every parameterized form
// shares one node shape. This is parse-only — no resolution to a checker Type.
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
	name := expect(p, .Ident) or_return
	// Type names are UPPER_IDENT (spec §02; lexical-core.ebnf §2); the
	// wrong-case verdict fires before the construct is built.
	if !is_upper_ident(name.class) {
		return type, .Wrong_Case
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

// expect_type_name consumes an UpperCamel type name — the declared name of
// a data/enum/thing/signal/pipeline or a kind/target ascription (spec §02).
expect_type_name :: proc(p: ^Parser) -> (name: string, err: Parse_Error) {
	tok := expect(p, .Ident) or_return
	// A declared type name or kind/target ascription is UPPER_IDENT
	// (lexical-core.ebnf §2).
	if !is_upper_ident(tok.class) {
		return "", .Wrong_Case
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
check_ident_case :: proc(tok: Token, following: Token_Kind) -> Parse_Error {
	if tok.class == .Mixed {
		return .Wrong_Case
	}
	#partial switch following {
	case .L_Brace, .Colon_Colon:
		// A record-literal constructor or an enum-type head stands in type
		// position — an UPPER_IDENT (lexical-core.ebnf §2), which admits a
		// single-capital head as well as multi-word UpperCamel.
		if !is_upper_ident(tok.class) {
			return .Wrong_Case
		}
	case .Dot, .L_Paren:
		// A member-access receiver or a callee — any sanctioned class.
	case:
		if tok.class != .Snake_Case && tok.class != .Upper_Snake {
			return .Wrong_Case
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

advance :: proc(p: ^Parser) -> (tok: Token, err: Parse_Error) {
	if at_end(p) {
		return Token{}, .Unexpected_End
	}
	tok = p.tokens[p.pos]
	p.pos += 1
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
