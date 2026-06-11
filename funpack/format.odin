// The §02 canonical formatter's rendering core: a pure AST → text projection.
// Spec §02 fixes the doctrine — "A canonical formatter ships in funpack, is
// mandatory and idempotent; the AST is the source of truth and text is its
// projection" — and this file IS that projection: one canonical text form for
// any well-formed parsed AST, byte-deterministic (no maps walked, no clock, no
// IO — every list renders in slice order) and re-parseable to an equivalent
// AST (equivalence is modulo the `line` span-provenance fields, which are
// projection metadata, not AST content).
//
// Canonical-form rules the renderer fixes where §02 under-specifies (each
// chosen to round-trip and to match the dominant funpack-spec example-corpus
// spelling):
//   - Declarations render in SOURCE ORDER (module @doc, imports, then the
//     Ast's source-ordered declaration sequence): the author's cross-kind
//     interleaving — a thing beside its behaviors and signals — IS canonical
//     form, never reordered (ADR
//     2026-06-10-formatter-canon-source-ordered-declarations, superseding the
//     interim kind-grouped rendering).
//   - One blank line between adjacent top-level declarations; the module @doc
//     and the import block are contiguous.
//   - Directive block order: @doc, the bare @expose marker, @gtag (ONE
//     directive carrying every label), @todo notes, then debug probes,
//     families in slice order. Declaration-targeting directives render
//     adjacent to their keyword, after that block: @index/@spatial before
//     `query`, the decl-level @migrate before `data`; a field-level @migrate
//     renders inline before its field name.
//   - data/enum/signal bodies are single-line (`data Board { w: Fixed, h:
//     Fixed }`); thing/singleton bodies are multiline with the type column
//     aligned to the longest field name; pipeline stages are multiline with
//     the value column aligned to the longest stage name. The one enum
//     exception: an enum any of whose variants carries a §05 §1 @doc renders
//     multiline (the thing/singleton mold), each doc line above its variant —
//     a doc line cannot sit inside a single-line body, and a doc-less enum
//     keeps the single-line corpus rendering unchanged.
//   - Record literals are tight (`Vec2{x: v.x}`); `with` updates are spaced
//     (`self with { y: v }`); declaration braces are spaced (`{ w: Fixed }`).
//   - Expressions render on one line — separators normalize to `, `, member
//     chains do not break — except `match`, which always renders multiline
//     with one arm per line.
//   - An `if` STATEMENT with a single-statement body renders on one line
//     (`if cond { return x }`); otherwise multiline.
//   - Minimal parentheses are re-inserted from precedence alone (the parser
//     unwraps groupings), and a match scrutinee / `if` condition whose spine
//     would expose a record brace in the parser's no-struct-literal context is
//     wrapped in one pair of parentheses.
//   - A Fixed literal renders as the SHORTEST decimal spelling whose
//     fixed_from_decimal bits equal the stored bits (`160.0`, `0.5`).
package funpack

import "core:strings"

// FMT_INDENT is the one indentation unit of the canonical form (spec §02 §1:
// the formatter re-indents, so whitespace is never counted).
FMT_INDENT :: "  "

// render_canonical projects a parsed AST to its single canonical text form.
// Pure: two calls on the same AST yield byte-identical strings. The returned
// string is allocated in `allocator`.
render_canonical :: proc(ast: Ast, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	wrote_header := false
	if ast.module_doc != "" {
		fmt_doc_line(&b, ast.module_doc)
		wrote_header = true
	}
	for imp in ast.imports {
		fmt_import(&b, imp)
		wrote_header = true
	}
	wrote_decl := wrote_header
	// Declarations render through the Ast's source-ordered sequence — the
	// author's cross-kind interleaving is the canonical order, so the
	// projection preserves it (the switch is total over Ast_Decl_Kind: a new
	// declaration kind is a visible compile gap here).
	for ref in ast.decls {
		fmt_decl_separator(&b, &wrote_decl)
		switch ref.kind {
		case .Let:
			fmt_let_decl(&b, ast.lets[ref.index])
		case .Data:
			fmt_data(&b, ast.datas[ref.index])
		case .Enum:
			fmt_enum(&b, ast.enums[ref.index])
		case .Thing:
			fmt_thing(&b, ast.things[ref.index])
		case .Signal:
			fmt_signal(&b, ast.signals[ref.index])
		case .Fn:
			fmt_fn_decl(&b, ast.fns[ref.index])
		case .Query:
			fmt_query(&b, ast.queries[ref.index])
		case .Behavior:
			fmt_behavior(&b, ast.behaviors[ref.index])
		case .Pipeline:
			fmt_pipeline(&b, ast.pipelines[ref.index])
		case .Test:
			fmt_test(&b, ast.tests[ref.index])
		case .Extern_Type:
			fmt_extern_type(&b, ast.extern_types[ref.index])
		}
	}
	return strings.to_string(b)
}

// fmt_decl_separator writes the single blank line between adjacent top-level
// declarations (and between the header block and the first declaration).
fmt_decl_separator :: proc(b: ^strings.Builder, wrote_prior: ^bool) {
	if wrote_prior^ {
		strings.write_string(b, "\n")
	}
	wrote_prior^ = true
}

// ── header ───────────────────────────────────────────────────────────────

// fmt_doc_line writes one `@doc("…")` line; the content is the lexer-verbatim
// inner text — a quote can only appear ESCAPED (`\"`, lexical-core §4) and the
// lexer carries the raw spelling, backslash included, so it re-lexes whole.
fmt_doc_line :: proc(b: ^strings.Builder, doc: string) {
	strings.write_string(b, "@doc(\"")
	strings.write_string(b, doc)
	strings.write_string(b, "\")\n")
}

// fmt_import writes one import in its parsed form (spec §02 §4): the dotted
// path, plus the `.{m, …}` member group when one was written.
fmt_import :: proc(b: ^strings.Builder, imp: Import_Node) {
	strings.write_string(b, "import ")
	for segment, i in imp.segments {
		if i > 0 {
			strings.write_string(b, ".")
		}
		strings.write_string(b, segment)
	}
	if imp.members != nil {
		strings.write_string(b, ".{")
		for member, i in imp.members {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, member)
		}
		strings.write_string(b, "}")
	}
	strings.write_string(b, "\n")
}

// ── directives ───────────────────────────────────────────────────────────

// fmt_directives writes a declaration's leading directive block in canonical
// order: @doc, the bare @expose marker (the spec §30 §6 exemplar order — the
// doc line leads, the contract marker follows), ONE @gtag carrying every
// label, the @todo notes, then the debug probes — families in slice order.
// The parser accumulates each family independently, so this fixed order
// re-parses to the same Directives.
fmt_directives :: proc(b: ^strings.Builder, doc: string, exposed: bool, gtags: []string, todos: []Todo_Node, probes: []Debug_Probe) {
	if doc != "" {
		fmt_doc_line(b, doc)
	}
	if exposed {
		strings.write_string(b, "@expose\n")
	}
	if len(gtags) > 0 {
		strings.write_string(b, "@gtag(")
		for tag, i in gtags {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, "\"")
			strings.write_string(b, tag)
			strings.write_string(b, "\"")
		}
		strings.write_string(b, ")\n")
	}
	for todo in todos {
		strings.write_string(b, "@todo(\"")
		strings.write_string(b, todo.message)
		strings.write_string(b, "\", ")
		fmt_todo_window(b, todo.window)
		strings.write_string(b, ")\n")
	}
	for probe in probes {
		fmt_probe(b, probe)
	}
}

// fmt_todo_window writes one §05 §2 expiry window in its form's one obvious
// spelling: `30d`, `2026-09-01` (4/2/2 zero-padded), `5builds`, `T-0042`
// (digits verbatim — zero padding kept).
fmt_todo_window :: proc(b: ^strings.Builder, window: Todo_Window) {
	switch window.form {
	case .Duration:
		strings.write_i64(b, window.amount)
		strings.write_string(b, window.unit)
	case .Date:
		fmt_zero_padded(b, window.year, 4)
		strings.write_string(b, "-")
		fmt_zero_padded(b, window.month, 2)
		strings.write_string(b, "-")
		fmt_zero_padded(b, window.day, 2)
	case .Build_Count:
		strings.write_i64(b, window.amount)
		strings.write_string(b, "builds")
	case .Task_Ref:
		strings.write_string(b, "T-")
		strings.write_string(b, window.task)
	}
}

// fmt_probe writes one §05 §5 debug directive: `@break(pred)` / `@log(expr)`
// / `@watch(expr)` with their mandatory argument, `@trace` bare.
fmt_probe :: proc(b: ^strings.Builder, probe: Debug_Probe) {
	switch probe.kind {
	case .Break:
		strings.write_string(b, "@break(")
	case .Log:
		strings.write_string(b, "@log(")
	case .Watch:
		strings.write_string(b, "@watch(")
	case .Trace:
		strings.write_string(b, "@trace\n")
		return
	}
	fmt_expr(b, probe.arg, 0)
	strings.write_string(b, ")\n")
}

// fmt_migrate writes one §05 §6 @migrate directive in its closed form set:
// `@migrate(from: "old")`, `@migrate(with: convert)`, or the combined
// `@migrate(from: "old", with: convert)` — `from` before `with`, the only
// order the parser admits, so the rendering re-parses to the same node.
fmt_migrate :: proc(b: ^strings.Builder, node: Migrate_Node) {
	strings.write_string(b, "@migrate(")
	if node.has_from {
		strings.write_string(b, "from: \"")
		strings.write_string(b, node.from)
		strings.write_string(b, "\"")
	}
	if node.has_with {
		if node.has_from {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, "with: ")
		strings.write_string(b, node.with)
	}
	strings.write_string(b, ")")
}

// fmt_zero_padded writes a non-negative value left-padded with zeros to the
// given width — the ISO date components' 4/2/2 spellings.
fmt_zero_padded :: proc(b: ^strings.Builder, value: i64, width: int) {
	digits: [20]byte
	n := 0
	v := value
	for {
		digits[n] = byte('0' + v % 10)
		v /= 10
		n += 1
		if v == 0 {
			break
		}
	}
	for _ in n ..< width {
		strings.write_string(b, "0")
	}
	for i := n - 1; i >= 0; i -= 1 {
		strings.write_byte(b, digits[i])
	}
}

// ── declarations ─────────────────────────────────────────────────────────

// fmt_let_decl writes a module-level constant: `let NAME: T = expr`.
fmt_let_decl :: proc(b: ^strings.Builder, decl: Let_Decl_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "let ")
	strings.write_string(b, decl.name)
	strings.write_string(b, ": ")
	fmt_type_ref(b, decl.type)
	strings.write_string(b, " = ")
	fmt_expr(b, decl.value, 0)
	strings.write_string(b, "\n")
}

// fmt_data writes `data Name { f: T, g: U }` single-line (the dominant corpus
// spelling for data), with the optional §03 §3 generic header and the
// optional `: Kind` ascription, in the fun.ebnf §4 declaration order.
fmt_data :: proc(b: ^strings.Builder, decl: Data_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	if decl.has_migrate {
		// The decl-level @migrate (a renamed type, spec §05 §6) renders
		// adjacent to the `data` keyword it targets — the @index/@spatial
		// adjacency mold — after the ordinary directive block.
		fmt_migrate(b, decl.migrate)
		strings.write_string(b, "\n")
	}
	strings.write_string(b, "data ")
	strings.write_string(b, decl.name)
	fmt_type_params(b, decl.type_params)
	if decl.kind != "" {
		strings.write_string(b, ": ")
		strings.write_string(b, decl.kind)
	}
	fmt_field_list_inline(b, decl.fields)
	strings.write_string(b, "\n")
}

// fmt_enum writes `enum Name { A, B(T), C{f: T} }` single-line, with the
// optional §03 §3 generic header and the optional enum-as-role `: Kind`
// ascription, in the fun.ebnf §4 declaration order. An enum any of whose
// variants carries a §05 §1 @doc renders multiline instead (the
// thing/singleton mold): one variant per line, comma-terminated except the
// last, each doc-carrying variant's `@doc("…")` line above it at the same
// indent — a doc line cannot sit inside the single-line body, and the
// doc-less rendering stays untouched so the existing corpus does not reshape.
fmt_enum :: proc(b: ^strings.Builder, decl: Enum_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "enum ")
	strings.write_string(b, decl.name)
	fmt_type_params(b, decl.type_params)
	if decl.kind != "" {
		strings.write_string(b, ": ")
		strings.write_string(b, decl.kind)
	}
	if len(decl.variants) == 0 {
		strings.write_string(b, " {}\n")
		return
	}
	any_variant_doc := false
	for variant in decl.variants {
		if variant.doc != "" {
			any_variant_doc = true
			break
		}
	}
	if any_variant_doc {
		strings.write_string(b, " {\n")
		for variant, i in decl.variants {
			if variant.doc != "" {
				strings.write_string(b, FMT_INDENT)
				fmt_doc_line(b, variant.doc)
			}
			strings.write_string(b, FMT_INDENT)
			fmt_variant_decl(b, variant)
			if i < len(decl.variants) - 1 {
				strings.write_string(b, ",")
			}
			strings.write_string(b, "\n")
		}
		strings.write_string(b, "}\n")
		return
	}
	strings.write_string(b, " { ")
	for variant, i in decl.variants {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		fmt_variant_decl(b, variant)
	}
	strings.write_string(b, " }\n")
}

// fmt_variant_decl writes one enum variant: plain `Left`, tuple-payload
// `MoveTo(Vec2)`, or struct-payload `Rgb{r: Fixed}` (tight braces, the §02 §7
// table spelling).
fmt_variant_decl :: proc(b: ^strings.Builder, variant: Variant_Decl) {
	strings.write_string(b, variant.name)
	switch variant.payload {
	case .Plain:
	case .Tuple:
		strings.write_string(b, "(")
		for type, i in variant.tuple {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_type_ref(b, type)
		}
		strings.write_string(b, ")")
	case .Struct:
		strings.write_string(b, "{")
		for field, i in variant.fields {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, field.name)
			strings.write_string(b, ": ")
			fmt_type_ref(b, field.type)
		}
		strings.write_string(b, "}")
	}
}

// fmt_thing writes `thing`/`singleton Name { … }` multiline with the type
// column aligned to the longest field name — the dominant corpus spelling for
// entity declarations (pong's Paddle, snake's Snake).
fmt_thing :: proc(b: ^strings.Builder, decl: Thing_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "singleton " if decl.is_singleton else "thing ")
	strings.write_string(b, decl.name)
	strings.write_string(b, " {\n")
	fmt_fields_aligned(b, decl.fields)
	strings.write_string(b, "}\n")
}

// fmt_signal writes `signal Name { f: T }` single-line, `signal Name {}` for
// the field-less form (snake's Died).
fmt_signal :: proc(b: ^strings.Builder, decl: Signal_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "signal ")
	strings.write_string(b, decl.name)
	fmt_field_list_inline(b, decl.fields)
	strings.write_string(b, "\n")
}

// fmt_field_list_inline writes a declaration field list on one line —
// ` { f: T, g: U = d }`, or ` {}` when empty — with the spaced declaration
// braces the corpus uses (distinct from tight record-literal braces).
fmt_field_list_inline :: proc(b: ^strings.Builder, fields: []Field_Decl) {
	if len(fields) == 0 {
		strings.write_string(b, " {}")
		return
	}
	strings.write_string(b, " { ")
	for field, i in fields {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		if field.has_migrate {
			// A field-level @migrate (spec §05 §6 — only a `data` field
			// carries one) renders inline before its field, the parser's
			// single-line spelling.
			fmt_migrate(b, field.migrate)
			strings.write_string(b, " ")
		}
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		fmt_type_ref(b, field.type)
		if field.has_default {
			strings.write_string(b, " = ")
			fmt_expr(b, field.default, 0)
		}
	}
	strings.write_string(b, " }")
}

// fmt_fields_aligned writes one field per line, two-space indented, with the
// type column aligned to the longest field name (the gen_emit multiline
// alignment rule: pad after the colon is longest - len(name) + 1).
fmt_fields_aligned :: proc(b: ^strings.Builder, fields: []Field_Decl) {
	longest := 0
	for field in fields {
		if len(field.name) > longest {
			longest = len(field.name)
		}
	}
	for field in fields {
		strings.write_string(b, FMT_INDENT)
		strings.write_string(b, field.name)
		strings.write_string(b, ":")
		for _ in 0 ..< longest - len(field.name) + 1 {
			strings.write_string(b, " ")
		}
		fmt_type_ref(b, field.type)
		if field.has_default {
			strings.write_string(b, " = ")
			fmt_expr(b, field.default, 0)
		}
		strings.write_string(b, "\n")
	}
}

// fmt_fn_decl writes a top-level fn in its three body forms: an `extern fn`
// signature line, a holed `fn name(…) -> R @stub(…)` line, or the
// brace-delimited statement body.
fmt_fn_decl :: proc(b: ^strings.Builder, decl: Fn_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	if decl.is_extern {
		strings.write_string(b, "extern ")
	}
	strings.write_string(b, "fn ")
	strings.write_string(b, decl.name)
	fmt_signature(b, decl.params, decl.return_type)
	if decl.is_extern {
		strings.write_string(b, "\n")
		return
	}
	if decl.holed {
		strings.write_string(b, " ")
		fmt_stub(b, decl.hole_type, decl.fallback, decl.has_fallback, 0)
		strings.write_string(b, "\n")
		return
	}
	strings.write_string(b, " {\n")
	fmt_statements(b, decl.body, 1)
	strings.write_string(b, "}\n")
}

// fmt_extern_type writes `extern type Name` after the shared directive block,
// with the optional §03 §3 generic header (`extern type View[T]`) — the whole
// declaration is the one header line (§26 §2: an opaque type carries no
// funpack-visible fields and no body, so there is nothing else to project).
fmt_extern_type :: proc(b: ^strings.Builder, decl: Extern_Type_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "extern type ")
	strings.write_string(b, decl.name)
	fmt_type_params(b, decl.type_params)
	strings.write_string(b, "\n")
}

// fmt_type_params writes the §03 §3 generic declaration header `[T]` /
// `[T, E]` tight against the declared name, comma-space separated — the
// spelling fmt_type_ref gives a generic application, so a header and a use
// project identically. Writes nothing when the declaration has none.
fmt_type_params :: proc(b: ^strings.Builder, params: []string) {
	if len(params) == 0 {
		return
	}
	strings.write_string(b, "[")
	for param, i in params {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, param)
	}
	strings.write_string(b, "]")
}

// fmt_signature writes `(p: T, …) -> R` — the parameter list and return
// ascription shared by fns, extern fns, queries, and the behavior step.
fmt_signature :: proc(b: ^strings.Builder, params: []Param_Decl, return_type: Type_Ref) {
	strings.write_string(b, "(")
	for param, i in params {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, param.name)
		strings.write_string(b, ": ")
		fmt_type_ref(b, param.type)
	}
	strings.write_string(b, ") -> ")
	fmt_type_ref(b, return_type)
}

// fmt_query writes a §08 §3 query declaration: its directive block, then the
// declared §05 §3 index requirements (one `@index(Thing.field)` /
// `@spatial(Thing.field)` line each, in slice order, adjacent to the `query`
// keyword — the spec §08 §3 spelling), then `query name(…) -> R { … }`. The
// grammar admits no body-position hole on a query (fun.ebnf §7), so the body
// is always the brace-delimited statement block.
fmt_query :: proc(b: ^strings.Builder, decl: Query_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	for index in decl.indexes {
		switch index.kind {
		case .Index:
			strings.write_string(b, "@index(")
		case .Spatial:
			strings.write_string(b, "@spatial(")
		}
		strings.write_string(b, index.thing)
		strings.write_string(b, ".")
		strings.write_string(b, index.field)
		strings.write_string(b, ")\n")
	}
	strings.write_string(b, "query ")
	strings.write_string(b, decl.name)
	fmt_signature(b, decl.params, decl.return_type)
	strings.write_string(b, " {\n")
	fmt_statements(b, decl.body, 1)
	strings.write_string(b, "}\n")
}

// fmt_behavior writes `behavior name on Thing { fn step(…) -> R { … } }`
// multiline; a holed step renders its `@stub(…)` body on the signature line.
fmt_behavior :: proc(b: ^strings.Builder, decl: Behavior_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "behavior ")
	strings.write_string(b, decl.name)
	strings.write_string(b, " on ")
	strings.write_string(b, decl.target)
	strings.write_string(b, " {\n")
	strings.write_string(b, FMT_INDENT)
	strings.write_string(b, "fn step")
	fmt_signature(b, decl.step.params, decl.step.return_type)
	if decl.step.holed {
		strings.write_string(b, " ")
		fmt_stub(b, decl.step.hole_type, decl.step.fallback, decl.step.has_fallback, 1)
		strings.write_string(b, "\n")
	} else {
		strings.write_string(b, " {\n")
		fmt_statements(b, decl.step.body, 2)
		strings.write_string(b, FMT_INDENT)
		strings.write_string(b, "}\n")
	}
	strings.write_string(b, "}\n")
}

// fmt_pipeline writes `pipeline Name { … }` multiline with the stage value
// column aligned to the longest stage name (the corpus spelling); an empty
// pipeline keeps its `{\n}` body (drift's Drift).
fmt_pipeline :: proc(b: ^strings.Builder, decl: Pipeline_Node) {
	fmt_directives(b, decl.doc, decl.exposed, decl.gtags, decl.todos, decl.probes)
	strings.write_string(b, "pipeline ")
	strings.write_string(b, decl.name)
	strings.write_string(b, " {\n")
	longest := 0
	for stage in decl.stages {
		if len(stage.name) > longest {
			longest = len(stage.name)
		}
	}
	for stage in decl.stages {
		strings.write_string(b, FMT_INDENT)
		strings.write_string(b, stage.name)
		strings.write_string(b, ":")
		for _ in 0 ..< longest - len(stage.name) + 1 {
			strings.write_string(b, " ")
		}
		if stage.is_battery {
			strings.write_string(b, stage.battery)
		} else {
			strings.write_string(b, "[")
			for name, i in stage.behaviors {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				strings.write_string(b, name)
			}
			strings.write_string(b, "]")
		}
		strings.write_string(b, "\n")
	}
	strings.write_string(b, "}\n")
}

// fmt_test writes `test "name" { … }` with its optional leading @doc.
fmt_test :: proc(b: ^strings.Builder, decl: Test_Node) {
	if decl.doc != "" {
		fmt_doc_line(b, decl.doc)
	}
	strings.write_string(b, "test \"")
	strings.write_string(b, decl.name)
	strings.write_string(b, "\" {\n")
	fmt_statements(b, decl.body, 1)
	strings.write_string(b, "}\n")
}

// ── statements ───────────────────────────────────────────────────────────

// fmt_statements writes a statement sequence, one statement per line at the
// given indent depth.
fmt_statements :: proc(b: ^strings.Builder, stmts: []Statement, indent: int) {
	for stmt in stmts {
		fmt_statement(b, stmt, indent)
	}
}

// fmt_statement writes one body statement (let / assert / return / if guard)
// with its indentation and trailing newline.
fmt_statement :: proc(b: ^strings.Builder, stmt: Statement, indent: int) {
	switch node in stmt {
	case Let_Node:
		fmt_write_indent(b, indent)
		strings.write_string(b, "let ")
		strings.write_string(b, node.name)
		strings.write_string(b, " = ")
		fmt_expr(b, node.value, indent)
		strings.write_string(b, "\n")
	case Assert_Node:
		fmt_write_indent(b, indent)
		strings.write_string(b, "assert ")
		fmt_expr(b, node.expr, indent)
		strings.write_string(b, "\n")
	case Return_Node:
		fmt_write_indent(b, indent)
		strings.write_string(b, "return ")
		fmt_expr(b, node.value, indent)
		strings.write_string(b, "\n")
	case If_Node:
		fmt_if_stmt(b, node, indent)
	}
}

// fmt_if_stmt writes the early-return guard. A single-statement body whose
// rendering holds one line renders as the corpus one-liner `if cond { return
// x }`; anything else renders multiline.
fmt_if_stmt :: proc(b: ^strings.Builder, node: If_Node, indent: int) {
	if len(node.body) == 1 {
		inner := strings.builder_make(context.temp_allocator)
		fmt_statement(&inner, node.body[0], 0)
		rendered := strings.to_string(inner)
		// The probe rendered with a trailing newline; one line means exactly one.
		if strings.count(rendered, "\n") == 1 {
			fmt_write_indent(b, indent)
			strings.write_string(b, "if ")
			fmt_guarded_expr(b, node.cond, indent)
			strings.write_string(b, " { ")
			strings.write_string(b, strings.trim_suffix(rendered, "\n"))
			strings.write_string(b, " }\n")
			return
		}
	}
	fmt_write_indent(b, indent)
	strings.write_string(b, "if ")
	fmt_guarded_expr(b, node.cond, indent)
	strings.write_string(b, " {\n")
	fmt_statements(b, node.body, indent + 1)
	fmt_write_indent(b, indent)
	strings.write_string(b, "}\n")
}

fmt_write_indent :: proc(b: ^strings.Builder, indent: int) {
	for _ in 0 ..< indent {
		strings.write_string(b, FMT_INDENT)
	}
}

// ── types ────────────────────────────────────────────────────────────────

// fmt_type_ref writes a syntactic type: bare `Fixed`, generic `View[Paddle]`,
// list `[Goal]` (the "[]" head), tuple `(Rng, [Spawn])` (the "()" head), or
// function type `fn(T) -> Bool` (the "fn" head, whose last arg is the result).
fmt_type_ref :: proc(b: ^strings.Builder, type: Type_Ref) {
	switch type.name {
	case "[]":
		strings.write_string(b, "[")
		fmt_type_ref(b, type.args[0])
		strings.write_string(b, "]")
	case "fn":
		// The §02 §3 FnType: comma-space separated parameters, then the
		// spaced `-> R` — the same spelling fmt_signature gives a declared
		// signature, so a declared and a parameter-position fn project alike.
		strings.write_string(b, "fn(")
		for arg, i in type.args[:len(type.args)-1] {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_type_ref(b, arg)
		}
		strings.write_string(b, ") -> ")
		fmt_type_ref(b, type.args[len(type.args)-1])
	case "()":
		strings.write_string(b, "(")
		for arg, i in type.args {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_type_ref(b, arg)
		}
		strings.write_string(b, ")")
	case:
		strings.write_string(b, type.name)
		if len(type.args) > 0 {
			strings.write_string(b, "[")
			for arg, i in type.args {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				fmt_type_ref(b, arg)
			}
			strings.write_string(b, "]")
		}
	}
}

// ── expressions ──────────────────────────────────────────────────────────

// fmt_expr writes one expression. indent is the enclosing statement's depth,
// consumed only by the multiline `match` form; everything else renders on the
// current line. Parentheses are re-inserted minimally: the parser unwraps
// groupings, so the renderer restores exactly the pairs precedence requires.
fmt_expr :: proc(b: ^strings.Builder, expr: Expr, indent: int) {
	switch e in expr {
	case ^Int_Lit_Expr:
		strings.write_i64(b, e.value)
	case ^Fixed_Lit_Expr:
		fmt_fixed_literal(b, e.bits)
	case ^String_Lit_Expr:
		strings.write_string(b, "\"")
		strings.write_string(b, e.text)
		strings.write_string(b, "\"")
	case ^Name_Expr:
		strings.write_string(b, e.name)
	case ^Call_Expr:
		fmt_postfix_operand(b, e.callee, indent)
		strings.write_string(b, "(")
		for arg, i in e.args {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_expr(b, arg, indent)
		}
		strings.write_string(b, ")")
	case ^Member_Expr:
		fmt_postfix_operand(b, e.receiver, indent)
		strings.write_string(b, ".")
		strings.write_string(b, e.member)
	case ^Variant_Expr:
		strings.write_string(b, e.type_name)
		strings.write_string(b, "::")
		strings.write_string(b, e.variant)
		if e.has_payload {
			strings.write_string(b, "(")
			for arg, i in e.payload {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				fmt_expr(b, arg, indent)
			}
			strings.write_string(b, ")")
		}
		if e.has_fields {
			fmt_record_fields_tight(b, e.fields, indent)
		}
	case ^Record_Expr:
		strings.write_string(b, e.type_name)
		fmt_record_fields_tight(b, e.fields, indent)
	case ^List_Expr:
		strings.write_string(b, "[")
		for element, i in e.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_expr(b, element, indent)
		}
		strings.write_string(b, "]")
	case ^Tuple_Expr:
		strings.write_string(b, "(")
		for element, i in e.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_expr(b, element, indent)
		}
		strings.write_string(b, ")")
	case ^Lambda_Expr:
		strings.write_string(b, "fn(")
		for param, i in e.params {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, param)
		}
		strings.write_string(b, ") { return ")
		fmt_expr(b, e.body, indent)
		strings.write_string(b, " }")
	case ^Unary_Expr:
		strings.write_string(b, e.op.text)
		if e.op.kind == .Ident {
			// The word operator `not` needs the separating space; `-` is tight.
			strings.write_string(b, " ")
		}
		fmt_unary_operand(b, e.operand, indent)
	case ^Binary_Expr:
		fmt_binary_operand(b, e.lhs, infix_power(e.op), false, indent)
		strings.write_string(b, " ")
		strings.write_string(b, e.op.text)
		strings.write_string(b, " ")
		fmt_binary_operand(b, e.rhs, infix_power(e.op), true, indent)
	case ^With_Expr:
		fmt_with_base(b, e.base, indent)
		strings.write_string(b, " with { ")
		for field, i in e.fields {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, field.name)
			strings.write_string(b, ": ")
			fmt_expr(b, field.value, indent)
		}
		strings.write_string(b, " }")
	case ^Match_Expr:
		fmt_match(b, e, indent)
	case ^If_Expr:
		fmt_if_expr(b, e, indent)
	case ^Stub_Expr:
		fmt_stub(b, e.hole_type, e.fallback, e.has_fallback, indent)
	case ^All_Expr:
		// The §08 §3 world read renders as its one canonical spelling.
		strings.write_string(b, "all[")
		strings.write_string(b, e.thing)
		strings.write_string(b, "]")
	}
}

// fmt_record_fields_tight writes a record literal's `{f: v, …}` body with
// tight braces (`Vec2{x: v.x}`, `Snake{}`) — the dominant corpus spelling.
fmt_record_fields_tight :: proc(b: ^strings.Builder, fields: []Record_Field, indent: int) {
	strings.write_string(b, "{")
	for field, i in fields {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		fmt_expr(b, field.value, indent)
	}
	strings.write_string(b, "}")
}

// fmt_stub writes a §05 §2 typed hole: `@stub(T)` or `@stub(T, fallback)` —
// the one production both the body and expression positions share.
fmt_stub :: proc(b: ^strings.Builder, hole_type: Type_Ref, fallback: Expr, has_fallback: bool, indent: int) {
	strings.write_string(b, "@stub(")
	fmt_type_ref(b, hole_type)
	if has_fallback {
		strings.write_string(b, ", ")
		fmt_expr(b, fallback, indent)
	}
	strings.write_string(b, ")")
}

// fmt_match writes the always-multiline match form: scrutinee on the opening
// line (guarded against record-brace exposure), one arm per line at one
// deeper indent, the closing brace back at the statement indent.
fmt_match :: proc(b: ^strings.Builder, e: ^Match_Expr, indent: int) {
	strings.write_string(b, "match ")
	fmt_guarded_expr(b, e.scrutinee, indent)
	strings.write_string(b, " {\n")
	for arm in e.arms {
		fmt_write_indent(b, indent + 1)
		fmt_pattern(b, arm.pattern)
		strings.write_string(b, " => ")
		fmt_expr(b, arm.body, indent + 1)
		strings.write_string(b, "\n")
	}
	fmt_write_indent(b, indent)
	strings.write_string(b, "}")
}

// fmt_if_expr writes the value conditional on one line: `if c { a } else
// { b }`, with an If_Expr alternate flattening into the `else if` chain.
fmt_if_expr :: proc(b: ^strings.Builder, e: ^If_Expr, indent: int) {
	strings.write_string(b, "if ")
	fmt_guarded_expr(b, e.cond, indent)
	strings.write_string(b, " { ")
	fmt_expr(b, e.then_branch, indent)
	strings.write_string(b, " } else ")
	if chained, is_if := e.else_branch.(^If_Expr); is_if {
		fmt_if_expr(b, chained, indent)
		return
	}
	strings.write_string(b, "{ ")
	fmt_expr(b, e.else_branch, indent)
	strings.write_string(b, " }")
}

// fmt_guarded_expr writes a match scrutinee or `if` condition. Those parse in
// the no-struct-literal context (spec §02 §5): a record brace exposed on the
// expression's spine would be mis-claimed as the construct's block, so such
// an expression is wrapped in one pair of parentheses (which lift the
// context); everything else renders bare.
fmt_guarded_expr :: proc(b: ^strings.Builder, expr: Expr, indent: int) {
	if fmt_spine_exposes_brace(expr) {
		strings.write_string(b, "(")
		fmt_expr(b, expr, indent)
		strings.write_string(b, ")")
		return
	}
	fmt_expr(b, expr, indent)
}

// fmt_spine_exposes_brace reports whether rendering this expression in the
// parser's no-struct-literal context would expose a record-style brace on the
// statement spine — outside the contexts that lift the restriction (call
// arguments, list/tuple brackets, `with` field braces, `@stub` parentheses).
// Match is conservatively true: its own scrutinee/arm parsing rewrites the
// context flag, so a guarded position never carries a bare match.
fmt_spine_exposes_brace :: proc(expr: Expr) -> bool {
	switch e in expr {
	case ^Record_Expr:
		return true
	case ^Variant_Expr:
		return e.has_fields
	case ^Match_Expr:
		return true
	case ^If_Expr:
		// The condition re-enters its own guarded context; the branch bodies
		// inherit the enclosing one.
		return fmt_spine_exposes_brace(e.then_branch) || fmt_spine_exposes_brace(e.else_branch)
	case ^Lambda_Expr:
		// The lambda body inherits the enclosing context.
		return fmt_spine_exposes_brace(e.body)
	case ^With_Expr:
		// The field braces lift the context; only the base stays on the spine.
		return fmt_spine_exposes_brace(e.base)
	case ^Unary_Expr:
		return fmt_spine_exposes_brace(e.operand)
	case ^Binary_Expr:
		return fmt_spine_exposes_brace(e.lhs) || fmt_spine_exposes_brace(e.rhs)
	case ^Member_Expr:
		return fmt_spine_exposes_brace(e.receiver)
	case ^Call_Expr:
		// Arguments parse inside parentheses (lifted); the callee stays exposed.
		return fmt_spine_exposes_brace(e.callee)
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^List_Expr, ^Tuple_Expr, ^Stub_Expr, ^All_Expr:
		return false
	}
	return false
}

// fmt_binary_operand writes one side of a binary operator, parenthesized when
// a looser-or-equal-bound binary child would otherwise re-associate: the
// ladder is left-associative, so the left child needs parens only below the
// parent's power and the right child at-or-below it.
fmt_binary_operand :: proc(b: ^strings.Builder, operand: Expr, parent_power: Binding_Power, is_right: bool, indent: int) {
	if child, is_binary := operand.(^Binary_Expr); is_binary {
		child_power := infix_power(child.op)
		if child_power < parent_power || (is_right && child_power == parent_power) {
			strings.write_string(b, "(")
			fmt_expr(b, operand, indent)
			strings.write_string(b, ")")
			return
		}
	}
	fmt_expr(b, operand, indent)
}

// fmt_unary_operand writes a unary operator's operand, parenthesized when it
// is a binary expression (unary binds above every binary tier, so `not (a and
// b)` needs its parens back).
fmt_unary_operand :: proc(b: ^strings.Builder, operand: Expr, indent: int) {
	if _, is_binary := operand.(^Binary_Expr); is_binary {
		strings.write_string(b, "(")
		fmt_expr(b, operand, indent)
		strings.write_string(b, ")")
		return
	}
	fmt_expr(b, operand, indent)
}

// fmt_with_base writes a `with` update's base, parenthesized when the base is
// a unary or binary expression — `with` binds above unary (spec §02 §3), so a
// looser base only reaches it through restored parentheses.
fmt_with_base :: proc(b: ^strings.Builder, base: Expr, indent: int) {
	needs_parens := false
	#partial switch _ in base {
	case ^Binary_Expr, ^Unary_Expr:
		needs_parens = true
	}
	if needs_parens {
		strings.write_string(b, "(")
		fmt_expr(b, base, indent)
		strings.write_string(b, ")")
		return
	}
	fmt_expr(b, base, indent)
}

// fmt_postfix_operand writes a call's callee or a member access's receiver,
// parenthesized when the operand binds looser than the postfix tier (binary,
// unary, or `with` — `(a with { f: 1 }).x` only parses with its parens).
fmt_postfix_operand :: proc(b: ^strings.Builder, operand: Expr, indent: int) {
	needs_parens := false
	#partial switch _ in operand {
	case ^Binary_Expr, ^Unary_Expr, ^With_Expr:
		needs_parens = true
	}
	if needs_parens {
		strings.write_string(b, "(")
		fmt_expr(b, operand, indent)
		strings.write_string(b, ")")
		return
	}
	fmt_expr(b, operand, indent)
}

// ── patterns ─────────────────────────────────────────────────────────────

// fmt_pattern writes one match-arm pattern (spec §02 §5): wildcard `_`, bare
// variant `T::V`, payload binders `T::V(p, q)`, struct field-pun `T::V{a,
// b}`, tuple `(p, q)`, or a bare binder name.
fmt_pattern :: proc(b: ^strings.Builder, pattern: Pattern) {
	switch pattern.kind {
	case .Wildcard:
		strings.write_string(b, "_")
	case .Bare_Binder:
		strings.write_string(b, pattern.binders[0])
	case .Bare_Variant:
		strings.write_string(b, pattern.type_name)
		strings.write_string(b, "::")
		strings.write_string(b, pattern.variant)
	case .Variant_Binds:
		strings.write_string(b, pattern.type_name)
		strings.write_string(b, "::")
		strings.write_string(b, pattern.variant)
		strings.write_string(b, "(")
		for element, i in pattern.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_pattern(b, element)
		}
		strings.write_string(b, ")")
	case .Struct_Binds:
		strings.write_string(b, pattern.type_name)
		strings.write_string(b, "::")
		strings.write_string(b, pattern.variant)
		strings.write_string(b, "{")
		for binder, i in pattern.binders {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, binder)
		}
		strings.write_string(b, "}")
	case .Tuple:
		strings.write_string(b, "(")
		for element, i in pattern.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			fmt_pattern(b, element)
		}
		strings.write_string(b, ")")
	}
}

// ── literals ─────────────────────────────────────────────────────────────

// fmt_fixed_literal writes Q32.32 bits as the SHORTEST decimal spelling whose
// fixed_from_decimal round-trip reproduces the bits exactly: the integer
// part, a dot, then the minimal fractional digit run (a whole value renders
// `N.0`, the corpus spelling). All-integer arithmetic — the same u128 path
// the lexer's fixed_from_decimal uses — so the spelling is machine-identical.
// A parsed literal is non-negative (unary minus is its own token); a negative
// hand-built value renders totally via a leading sign.
fmt_fixed_literal :: proc(b: ^strings.Builder, bits: Fixed) {
	value := bits
	if value < 0 {
		strings.write_string(b, "-")
		value = fixed_neg(value)
	}
	int_part := i64(value) >> FIXED_FRACTION_BITS
	frac := u128(i64(value) & ((1 << FIXED_FRACTION_BITS) - 1))
	strings.write_i64(b, int_part)
	strings.write_string(b, ".")
	if frac == 0 {
		strings.write_string(b, "0")
		return
	}
	pow: u128 = 1
	for width in 1 ..= 10 {
		pow *= 10
		digits := (frac * pow + (1 << (FIXED_FRACTION_BITS - 1))) >> FIXED_FRACTION_BITS
		// Round-trip gate: this digit run re-parses (fixed_from_decimal's own
		// rounding) to exactly the stored fraction bits. At width 10 the decimal
		// grid is finer than 2^-32, so the loop always terminates.
		if (digits << FIXED_FRACTION_BITS + pow / 2) / pow == frac {
			fmt_zero_padded(b, i64(digits), width)
			return
		}
	}
}
