// The fix-criteria diagnostic seam (README quality-gate non-negotiable): a
// compiler refusal is not a bare enum name (`Gate_Failed`, `Compile_Failed`)
// but a `rustc`/`gofmt`-flavored block naming the offending construct, its
// `file:line:col`, the specific closed-enum rule, and a concise fix sentence —
// so an agent's write→check→fix loop converges. This file owns the core
// Diagnostic record, the PURE renderer (render_diagnostic — a function of
// (Diagnostic, source) alone, so goldens pin it byte-for-byte), and the closed
// per-stage mapping procs (one per stage error enum) that are the SINGLE source
// of truth for the human wording. Each stage's seam (gates.odin, parser.odin,
// typecheck.odin, contracts.odin, pipeline_flatten.odin) keeps its existing
// closed enum as the machine contract and ADDS the offender coordinates beside
// the arm; the mapping proc here turns (arm, line, col, declaration) into the
// rendered Diagnostic. The CLI (main.odin, build.odin) fills `path` and re-reads
// the source the renderer excerpts from — funpack stays pure (no clock, no host
// nondeterminism beyond the file read the CLI owns).
package funpack

import "core:fmt"
import "core:strings"

// Diag_Stage names which pipeline stage refused, so a diagnostic header carries
// the same stage vocabulary the Pipeline_Error / Build_Error arms do. Closed
// like every funpack taxonomy: one member per stage seam, never a catch-all.
Diag_Stage :: enum {
	Parse,     // stage_parse rejected the token stream (Parse_Error)
	Gate,      // stage_gates overshot a structural budget (Gate_Error)
	Typecheck, // stage_typecheck_indexed found a type fault (Type_Error)
	Contract,  // stage_contracts rejected a behavior's slot contract (Contract_Error)
	Closure,   // stage_flatten rejected flattening or effect-closure (Flatten_Error)
}

// Diagnostic is one compiler refusal rendered as fix-criteria: the stage that
// refused, the specific closed-enum arm name as `rule`, the offender's 1-based
// line/col (0 = unknown, as for a declaration-anchored gate offender or a
// synthetic node), the offending declaration's §15 name (module-qualified by
// the project layer; "" when the fault has no owning declaration), the fix
// sentence, and the source file `path` the CLI fills from the failing module.
// The stage seams build everything but `path`; the CLI stamps `path` and
// re-reads the file render_diagnostic excerpts the offending line from.
Diagnostic :: struct {
	stage:       Diag_Stage,
	rule:        string, // the closed-enum arm's own name, e.g. "Type_Mismatch"
	line:        int,    // 1-based; 0 = unknown
	col:         int,    // 1-based; 0 = unknown
	declaration: string, // offending decl name (module-qualified); "" if none
	message:     string, // the fix-criteria sentence for this rule
	hint:        string, // optional per-instance detail appended after message (e.g. the receiver type's real methods for Unknown_Method); "" for the static-message arms
	path:        string, // source file; filled by the CLI/project layer
}

// render_diagnostic renders one Diagnostic as the deterministic rustc/gofmt
// block — a PURE function of (d, source) so a golden pins it byte-for-byte:
//
//   <path>:<line>:<col>: <rule>: <message>
//     <line> | <the offending source line>
//            |        ^   (caret under col; omitted when col == 0)
//
// A set `declaration` rides the header in parens (`<rule> (<declaration>):`).
// When `line == 0` (no position — a declaration-anchored gate offender whose
// decl line was not captured, or a synthetic node) the block collapses to the
// one-line header, no excerpt. `source` is the file text the CLI re-reads from
// `d.path`; the excerpt is `source`'s 1-based `line`th line. A `line` past the
// source (a stale span) prints the header and the gutter with an empty line,
// never crashes — the renderer fails open on a bad coordinate, never silent.
render_diagnostic :: proc(d: Diagnostic, source: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	// Header: `<path>:<line>:<col>: <rule> (<declaration>): <message>`. The
	// position triple omits the unknown halves so a declaration-anchored gate
	// offender reads `<path>: <rule> …` (no `:0:0:` noise), the rustc form for a
	// position-less diagnostic.
	fmt.sbprint(&b, d.path)
	if d.line != 0 {
		fmt.sbprintf(&b, ":%d", d.line)
		if d.col != 0 {
			fmt.sbprintf(&b, ":%d", d.col)
		}
	}
	fmt.sbprint(&b, ": ")
	fmt.sbprint(&b, d.rule)
	if d.declaration != "" {
		fmt.sbprintf(&b, " (%s)", d.declaration)
	}
	fmt.sbprintf(&b, ": %s", d.message)
	// A per-instance hint (the receiver type's real methods for an Unknown_Method,
	// say) rides after the static fix-sentence — the dynamic detail the static
	// per-arm message cannot carry, kept OFF the header's machine-stable triple so
	// it never disturbs rule/declaration parsing. "" for the static-message arms.
	if d.hint != "" {
		fmt.sbprintf(&b, " — %s", d.hint)
	}
	// Excerpt: only when a line is known. The gutter width is the line number's
	// decimal width, so the `|` rules align under the header's path and the caret
	// gutter matches the excerpt gutter exactly.
	if d.line != 0 {
		excerpt := source_line(source, d.line)
		number := fmt.tprintf("%d", d.line)
		fmt.sbprintf(&b, "\n  %s | %s", number, excerpt)
		if d.col != 0 {
			fmt.sbprint(&b, "\n  ")
			// The caret gutter is blanks the width of the line number, then `| `,
			// then (col-1) blanks and the caret — so `^` sits under the offending
			// column of the excerpt above (the excerpt body starts after `| `).
			for _ in 0 ..< len(number) {
				fmt.sbprint(&b, " ")
			}
			fmt.sbprint(&b, " | ")
			for _ in 0 ..< d.col - 1 {
				fmt.sbprint(&b, " ")
			}
			fmt.sbprint(&b, "^")
		}
	}
	return strings.to_string(b)
}

// source_line returns the 1-based `line`th line of `source` (no trailing
// newline), or "" when `line` is out of range — the fail-open excerpt for a
// stale or synthetic coordinate. strings.split_lines is the same line splitter
// the Index Contract config reader uses (index_contract.odin), so the excerpt
// indexes lines exactly as the rest of the compiler counts them.
source_line :: proc(source: string, line: int) -> string {
	if line < 1 {
		return ""
	}
	lines := strings.split_lines(source, context.temp_allocator)
	if line > len(lines) {
		return ""
	}
	return lines[line - 1]
}

// render_assert_failure renders ONE failed `assert` as the deterministic
// rustc/gofmt-flavored block — the EXIT-1 sibling of render_diagnostic (a compile
// error is exit 2; the machine contract is unchanged, this is the added human
// body for a failed assertion). Like render_diagnostic it is a PURE function of
// (f, source) so a golden pins it byte-for-byte:
//
//   <path>:<line>: assertion failed (<test name>): <assert expression>
//     <line> | <the offending source line>
//            left:  <lhs display>
//            right: <rhs display>
//
// The header carries the test name in parens (the declaration analogue of
// render_diagnostic's `(<declaration>)`), the §02 §4 assert expression text as
// the body, and the source line as the gutter-numbered excerpt. The left/right
// operand lines are shown only for a top-level `==`/`!=` whose both sides
// evaluated (f.has_operands); a bare-predicate assert renders the expression and
// excerpt alone. `line == 0` (a synthetic span) collapses to the header; a `line`
// past the source prints the header and an empty excerpt, never crashes — the
// fail-open coordinate discipline render_diagnostic holds.
render_assert_failure :: proc(f: Assert_Failure, source: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprint(&b, f.path)
	if f.line != 0 {
		fmt.sbprintf(&b, ":%d", f.line)
	}
	fmt.sbprint(&b, ": assertion failed")
	if f.test_name != "" {
		fmt.sbprintf(&b, " (%s)", f.test_name)
	}
	fmt.sbprintf(&b, ": %s", f.expr_text)
	if f.line != 0 {
		excerpt := source_line(source, f.line)
		number := fmt.tprintf("%d", f.line)
		fmt.sbprintf(&b, "\n  %s | %s", number, excerpt)
		// The left/right gutter aligns under the excerpt gutter: blanks the width
		// of the line number, then `| `, matching render_diagnostic's caret gutter.
		if f.has_operands {
			gutter := strings.repeat(" ", len(number), context.temp_allocator)
			fmt.sbprintf(&b, "\n  %s | left:  %s", gutter, f.lhs_display)
			fmt.sbprintf(&b, "\n  %s | right: %s", gutter, f.rhs_display)
		}
	}
	return strings.to_string(b)
}

// parse_diagnostic builds a Diagnostic from a Parse_Error arm and the offending
// token's line/col. The `rule` is the arm's own name; the `message` is the
// fix-criteria sentence distilled from the arm's rich doc-comment in
// parser.odin's Parse_Error declaration. A parse fault has no resolved
// declaration (the parser failed before the declaration was built), so
// declaration is always "". The switch is total over Parse_Error so a new arm
// is a visible compile gap here, never a silently-wordless diagnostic. .None is
// not a fault; it maps to an empty rule so a caller that never reaches a fault
// renders nothing.
parse_diagnostic :: proc(err: Parse_Error, line: int, col: int) -> Diagnostic {
	d := Diagnostic{stage = .Parse, line = line, col = col, rule = fmt.tprintf("%v", err)}
	switch err {
	case .None:
		d.rule = ""
	case .Unexpected_Token:
		d.message = "unexpected token here — the grammar expects a different construct at this position"
	case .Unexpected_End:
		d.message = "the source ended mid-construct — a closing token (a `}`, `)`, or the rest of the declaration) is missing"
	case .Wrong_Case:
		d.message = "this identifier's casing is wrong for its grammar position (spec §02 §1): snake_case for fn/field names, UpperCamel for types, UPPER_SNAKE for constants"
	case .Missing_Else:
		d.message = "an `if` used as a value expression needs both arms — add the `else { … }` arm so the expression has a type to unify (spec §02 §5)"
	case .Probe_Missing_Arg:
		d.message = "this debug probe needs its `(expr)` argument — the predicate/value is the probe's whole content (spec §05 §5)"
	case .Probe_Unexpected_Arg:
		d.message = "@trace takes no argument — drop the parentheses (spec §05 §5)"
	case .Probe_Wrong_Target:
		d.message = "this debug probe sits on a position the §28 §4 On-table forbids — only @watch prefixes a `data` field and only @trace prefixes a pipeline stage"
	case .Malformed_Todo_Window:
		d.message = "this @todo's window matches none of the four §05 §2 forms — use a known unit, a valid ISO date, or an unquoted task ref"
	case .Malformed_Migrate:
		d.message = "this @migrate's argument list matches none of the three §05 §6 forms — check the key spelling, the from/with order, and the quoting"
	case .Migrate_Wrong_Target:
		d.message = "this @migrate prefixes a position the spec forbids — it attaches to a `data` declaration or one of its fields (spec §05 §6)"
	case .Malformed_Index_Path:
		d.message = "this @index/@spatial argument is not a `(Thing.field)` FieldPath — write exactly `(UpperCamel.snake_case)` (spec §05 §3)"
	case .Index_Wrong_Target:
		d.message = "@index/@spatial prefixes a `query` declaration, never this one (spec §08 §3)"
	case .Expose_Unexpected_Arg:
		d.message = "@expose is bare — drop the argument; it publishes the declaration it prefixes (spec §05 §4)"
	case .Malformed_Extern:
		d.message = "`extern` prefixes only `fn` or `type` — the §02 §7 extern family is closed (spec §02 §7)"
	case .Malformed_Type_Params:
		d.message = "this generic header's `[…]` matches none of the TypeParams forms — write `[T]` or `[T, U]` with UpperCamel parameters (spec §03 §3)"
	case .Malformed_Fn_Type:
		d.message = "this function type's shape is wrong — write `fn(T, U) -> R` with parenthesized parameters and an arrow result (spec §02 §3)"
	case .Malformed_String_Escape:
		d.message = "this string escape is outside the closed set — only `\\\"`, `\\{`, and `\\}` are escapes (lexical-core §4)"
	case .Variant_Directive_Wrong_Target:
		d.message = "an enum variant admits only @doc — move this directive off the variant (spec §05)"
	case .Bool_Pattern_Unsupported:
		d.message = "a bool is not matchable — `match` dispatches over a closed enum or tuple, not over `true`/`false`; use `if`/`else` instead (spec §02 §5)"
	case .Newline_Before_Binary_Op:
		d.message = "an expression does not continue across a newline before a binary operator — funpack ends a statement at the newline, so keep each line a complete expression, or bind an intermediate `let` (spec §02 §1)"
	case .Lambda_Body_Multi_Statement:
		d.message = "a lambda body is a single statement — one expression, an if-expression, or a `return` — never a multi-statement block; lift the locals into a named helper `fn` and call it from the one-statement lambda (spec §02 §5)"
	case .Statement_In_Value_Block:
		d.message = "a value block holds a single expression — a statement-form `if … { return … }` cannot stand here; rewrite it as the if-EXPRESSION `if cond { value } else { value }`, both arms a bare value (spec §02 §5)"
	}
	return d
}

// gate_diagnostic builds a Diagnostic from a Gate_Error arm, the offending
// declaration's line, its name, and (for the nesting arm) which depth source
// tripped the ceiling. Gate offenders are declaration-anchored — the budget is a
// per-declaration compiler constant (spec §01 P5) — so col is always 0 (no
// expression column; the whole declaration overshot) and the declaration name
// rides the header. The duplication gate's offender is a colliding pair, not a
// single declaration, so its name/line may be "" / 0 (gate_verdict leaves them
// unset there). `cause` is consulted only on the Nesting_Exceeded arm (it is
// .None on every other arm); it selects the remedy that actually drops the depth
// — block nesting flattens with early returns, expression-composition nesting
// extracts a helper or binds an intermediate `let`. Total over Gate_Error, and
// the nesting arm is total over Nesting_Cause, so a new gate arm OR a new depth
// source is a visible compile gap here, never a silently-wordless or
// mis-remedied refusal.
gate_diagnostic :: proc(err: Gate_Error, line: int, declaration: string, cause := Nesting_Cause.None) -> Diagnostic {
	d := Diagnostic{stage = .Gate, line = line, declaration = declaration, rule = fmt.tprintf("%v", err)}
	switch err {
	case .None:
		d.rule = ""
	case .Cyclomatic_Exceeded:
		d.message = fmt.tprintf("this declaration's branch count exceeds the cyclomatic ceiling (%d) — split it into smaller functions (spec §01 P5)", MAX_CYCLOMATIC)
	case .Nesting_Exceeded:
		d.message = nesting_exceeded_message(cause)
	case .Fn_Size_Exceeded:
		d.message = fmt.tprintf("this declaration's body holds more than the statement ceiling (%d) — extract part of it into a helper (spec §01 P5)", MAX_FN_STATEMENTS)
	case .Arity_Exceeded:
		d.message = fmt.tprintf("a parameter list here is longer than the arity ceiling (%d) — group related parameters into a record (spec §01 P5)", MAX_PARAM_ARITY)
	case .Non_Exhaustive_Match:
		d.message = "this match leaves a variant of its scrutinee unhandled — add the missing arm(s) so every case is covered (spec §02 §5)"
	case .Duplicate_Declaration:
		d.message = "two declarations normalize to the same body — remove the duplicate or differentiate them (spec §01 P5)"
	case .Query_Missing_Index:
		d.message = "this query runs a spatial combinator over `all[T]` without declaring its index — add `@spatial(T.field)` on the query (spec §08 §3)"
	case .Query_Unused_Index:
		d.message = "this @index/@spatial is declared but no read in the query body uses it — remove the dead index (spec §08 §3)"
	case .Probe_Wrong_Placement:
		d.message = "this declaration-prefix debug probe sits on a declaration the §28 §4 On-table forbids — a decl-prefix probe is admitted only on a behavior (spec §28 §4)"
	}
	return d
}

// nesting_exceeded_message is the §01 P5 nesting refusal's fix sentence, with the
// remedy clause chosen to fit the depth source that tripped the ceiling — a block
// here nesting deeper does NOT fit pure call-expression depth (`np_id(np_id(…))`
// has no block and no branch to early-return from), so the remedy must name what
// actually drops the depth:
//   - Block       — flatten the structure with early returns (collapse the
//                    guard ladder so the body stops re-entering deeper blocks);
//   - Expression  — extract a named helper or bind an intermediate `let` (pull
//                    the nested call/composition out so no single expression
//                    nests past the ceiling).
// .None is defensive: a Nesting_Exceeded verdict always carries a real cause
// (check_nesting sets it at the overshoot), but should that ever not hold, name
// BOTH remedies precisely rather than guess one — never a misleading single
// remedy. Total over Nesting_Cause, so a new depth source is a visible compile
// gap here.
nesting_exceeded_message :: proc(cause: Nesting_Cause) -> string {
	switch cause {
	case .Block:
		return fmt.tprintf("a block here nests deeper than the nesting ceiling (%d) — flatten the structure with early returns (spec §01 P5)", MAX_NESTING_DEPTH)
	case .Expression:
		return fmt.tprintf("an expression here nests deeper than the nesting ceiling (%d) — extract a named helper or bind an intermediate `let` so no single expression nests past the ceiling (spec §01 P5)", MAX_NESTING_DEPTH)
	case .None:
		return fmt.tprintf("this declaration nests deeper than the nesting ceiling (%d) — for block nesting flatten the structure with early returns, for nested call expressions extract a named helper or bind an intermediate `let` (spec §01 P5)", MAX_NESTING_DEPTH)
	}
	return ""
}

// type_diagnostic builds a Diagnostic from a Type_Error arm, the offending
// expression's span (expr_span) or the offending declaration's line, and the
// owning declaration's name. The `message` is the fix-criteria sentence
// distilled from the arm's rich doc-comment in typecheck.odin's Type_Error
// declaration. Total over Type_Error so a new arm is a visible compile gap.
type_diagnostic :: proc(err: Type_Error, line: int, col: int, declaration: string, hint := "") -> Diagnostic {
	d := Diagnostic{stage = .Typecheck, line = line, col = col, declaration = declaration, rule = fmt.tprintf("%v", err), hint = hint}
	switch err {
	case .None:
		d.rule = ""
	case .Assert_Not_Bool:
		d.message = "this assert's expression is not Bool-typed — an assertion must evaluate to a Bool (spec §02)"
	case .Type_Mismatch:
		d.message = "the two sides here have different types — funpack has no implicit promotion, so make the types match (spec §02)"
	case .Unsupported_Expr:
		d.message = "this expression form is outside the typeable domain — rewrite it in the supported expression grammar (spec §02)"
	case .Unknown_Method:
		d.message = "no such method on this type — `recv.NAME(…)` names neither a method of the receiver's type nor a stdlib free fn reachable through it (spec §02 §4)"
	case .Unknown_Module:
		d.message = "this import names a module outside the surface — check the module name (spec §15)"
	case .Unknown_Member:
		d.message = "this import names a member its module does not declare — check the member name against the module's exports (spec §15)"
	case .Package_Private:
		d.message = "this import names a declaration its package does not @expose — add @expose to it, or import an exposed item (spec §30 §6)"
	case .Package_Imports_Package:
		d.message = "a package module may import only engine and its own package — this import reaches beyond the §30 §2 star graph (spec §30 §2)"
	case .Expose_Closure_Violation:
		d.message = "this @expose'd declaration's public signature references a non-@expose'd user type — expose that type too, or drop it from the signature (spec §30 §6)"
	case .Unresolved_Name:
		d.message = "this name has no binding in scope — no let, no user declaration, no import defines it (spec §02)"
	case .Name_Collision:
		d.message = "this name has two meanings — a user declaration and an import (or two imports) bind it; rename one (spec §02)"
	case .Unregistered_Layer:
		d.message = "this layer/mask names a value outside any CollisionLayer enum's variants — register it in a `enum … : CollisionLayer` (spec §11 §5)"
	case .Reserved_Signal_Name:
		d.message = "this signal is declared under an engine-routed name (Trigger/Contact) — rename it so it broadcasts (spec §11 §4)"
	case .Tuple_Pattern_Arity:
		d.message = "this tuple match pattern's arity disagrees with its Tuple-typed scrutinee — match every position (spec §02 §5)"
	case .Let_Tuple_Arity_Mismatch:
		d.message = "this `let (a, b, …)` destructure's binder count disagrees with the right-hand tuple — bind exactly one name per tuple element, or `let name = …` if the right-hand side is not a tuple (spec §02 §5)"
	case .Migrate_From_Collision:
		d.message = "this @migrate's prior name is still live — a renamed-from name must not name a current field/type (spec §05 §6)"
	case .Migrate_Convert_Unknown:
		d.message = "this @migrate `with:` names no fn this module declares — the conversion must resolve to a declared fn (spec §05 §6)"
	case .Migrate_Convert_Arity:
		d.message = "this @migrate conversion is not a single-parameter fn — the shape is `fn(Old) -> New` (spec §05 §6)"
	case .Migrate_Convert_Return:
		d.message = "this @migrate conversion's return type differs from the migrated field's new type — `fn(Old) -> New` must land on New (spec §05 §6)"
	case .Index_Unknown_Thing:
		d.message = "this @index/@spatial FieldPath's head names no declared thing/singleton — only a thing carries an index (spec §05 §3)"
	case .Index_Unknown_Field:
		d.message = "this @index/@spatial FieldPath names a field the thing's schema lacks — check the field name (spec §05 §3)"
	case .All_Outside_Query:
		d.message = "the world read `all[T]` is used outside a query body — only a query reads the world this way (spec §08 §3)"
	case .All_Unknown_Thing:
		d.message = "this `all[T]`'s T names no declared thing/singleton — the read table is a thing's instance set (spec §08 §3)"
	case .Spatial_Requirement_Missing:
		d.message = "this within/nearest_first has no @spatial declared for its element thing on the enclosing query — declare the index (spec §08 §3)"
	case .Spatial_Requirement_Ambiguous:
		d.message = "this within/nearest_first's element thing carries several @spatial declarations — the query must declare exactly one (spec §08 §3)"
	case .Query_Param_Not_Value:
		d.message = "this query parameter is outside the value domain — a query takes only value parameters and reads the world through `all[T]` (spec §08 §3)"
	}
	return d
}

// contract_diagnostic builds a Diagnostic from a Contract_Error arm, the
// offending behavior's declaration line, and its name. Every contract fault is
// behavior-level (the reject names which behavior broke which slot contract,
// spec §06 §6), so the declaration is the behavior name and col is 0 (the whole
// signature, not a column, violated). Total over Contract_Error.
contract_diagnostic :: proc(err: Contract_Error, line: int, declaration: string) -> Diagnostic {
	d := Diagnostic{stage = .Contract, line = line, declaration = declaration, rule = fmt.tprintf("%v", err)}
	switch err {
	case .None:
		d.rule = ""
	case .Render_Emits:
		d.message = "this render behavior returns a signal/command list — a render behavior may return only a [Draw] list (spec §06 §6)"
	case .Render_Takes_Signal:
		d.message = "this render behavior takes an inbound [Signal] param — render has no inbound edge (spec §06 §6)"
	case .Render_Takes_Rng:
		d.message = "this render behavior takes an Rng resource — render is a deterministic projection (spec §06 render-slot)"
	case .Render_No_Draw:
		d.message = "this render behavior returns something other than a [Draw] list — render's only write is [Draw] (spec §06 §6)"
	case .Startup_Reads_Thing:
		d.message = "this startup occupant reads an unspawned thing — only engine resources are in scope at startup (spec §06 §6)"
	case .Startup_No_Spawn:
		d.message = "this startup occupant returns something other than a [Spawn] list — startup's only write is [Spawn] (spec §06 §6)"
	case .Update_Dead:
		d.message = "this update behavior neither writes its blackboard nor emits a list — it is dead code (spec §06 §6 / §01 P5)"
	case .Unknown_Battery:
		d.message = "this bare-battery stage names a battery outside the engine set — the only battery is `solve` (spec §11 §3)"
	}
	return d
}

// flatten_diagnostic builds a Diagnostic from a Flatten_Error arm, the
// offending declaration's line, and its name. An Unclosed_Signal names the
// signal that went unclosed (spec §07 §2); the structural flatten faults
// (Unknown_Member / Recursive_Pipeline) name the offending pipeline member.
// col is 0 (the fault is a declaration/signal-level edge, not a column).
// Total over Flatten_Error.
flatten_diagnostic :: proc(err: Flatten_Error, line: int, declaration: string) -> Diagnostic {
	d := Diagnostic{stage = .Closure, line = line, declaration = declaration, rule = fmt.tprintf("%v", err)}
	switch err {
	case .None:
		d.rule = ""
	case .Unknown_Member:
		d.message = "this pipeline stage names something that is neither a behavior nor a sub-pipeline — check the member name (spec §07 §3)"
	case .Recursive_Pipeline:
		d.message = "a sub-pipeline reference cycles — a pipeline tree must be acyclic (spec §07 §3)"
	case .Unclosed_Signal:
		d.message = "this signal is emitted but no downstream stage consumes it — every emitted signal needs a consumer (effect closure, spec §07 §2)"
	}
	return d
}
