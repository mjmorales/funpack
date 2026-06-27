package funpack

import "core:fmt"
import "core:strings"

Diag_Stage :: enum {
	Parse,
	Gate,
	Typecheck,
	Contract,
	Closure,
}

Diagnostic :: struct {
	stage:       Diag_Stage,
	rule:        string,
	line:        int,
	col:         int,
	declaration: string,
	message:     string,
	hint:        string,
	path:        string,
}

render_diagnostic :: proc(d: Diagnostic, source: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
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
	if d.hint != "" {
		fmt.sbprintf(&b, " — %s", d.hint)
	}
	if d.line != 0 {
		excerpt := source_line(source, d.line)
		number := fmt.tprintf("%d", d.line)
		fmt.sbprintf(&b, "\n  %s | %s", number, excerpt)
		if d.col != 0 {
			fmt.sbprint(&b, "\n  ")
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
		if f.has_operands {
			gutter := strings.repeat(" ", len(number), context.temp_allocator)
			fmt.sbprintf(&b, "\n  %s | left:  %s", gutter, f.lhs_display)
			fmt.sbprintf(&b, "\n  %s | right: %s", gutter, f.rhs_display)
		}
	}
	return strings.to_string(b)
}

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
