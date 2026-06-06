// Evaluator over tagged Values and the saturating scalar kernel.
// Every operation is total and all-integer (spec §10) — no epsilon, no
// float, bit-identical on every machine. eval_expr fails closed: a form
// outside the evaluable domain returns ok = false, and the typecheck
// gate keeps such forms from reaching a counted assert. Each test block
// owns an environment frame; let statements bind into it in statement
// order, and lambda applications chain child frames off the captured
// env so iterations never leak bindings.
//
// The §06/§07 gameplay surface evaluates against the resolved module: a
// test calls user top-level fns by their recorded signature, invokes a
// behavior's `step` in test position (the §04 name.step(args) form), and
// constructs/compares user records and enum variants. Eval_Ctx threads the
// typed module (its fn/behavior/enum/record schemas) through evaluation so
// those forms resolve; the numeric kernel forms ignore it.
package funpack

// Env is a chained binding frame. Lookups walk toward the root; only
// the owning scope ever inserts, and nothing iterates the map — map
// order can never reach evaluation results (the determinism tripwire).
Env :: struct {
	bindings: map[string]Value,
	parent:   ^Env,
}

// Eval_Ctx carries the resolved module through evaluation: ast supplies the
// user fn/behavior bodies and the module-level `let` constants, env the
// declared record/enum schemas (resolve.odin). It is read-only — evaluation
// never mutates it — and is threaded alongside the per-call binding frame so
// a user fn call or a name.step invocation reaches the body to execute.
Eval_Ctx :: struct {
	ast: Ast,
	env: Type_Env,
}

new_env :: proc(parent: ^Env) -> ^Env {
	env := new(Env, context.temp_allocator)
	env.bindings = make(map[string]Value, context.temp_allocator)
	env.parent = parent
	return env
}

env_lookup :: proc(env: ^Env, name: string) -> (value: Value, ok: bool) {
	for frame := env; frame != nil; frame = frame.parent {
		if v, found := frame.bindings[name]; found {
			return v, true
		}
	}
	return nil, false
}

stage_evaluate :: proc(typed: Typed_Ast) -> Eval_Result {
	result := Eval_Result{}
	ctx := Eval_Ctx{ast = typed.ast, env = typed.env}
	for test in typed.ast.tests {
		env := new_env(nil)
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				// A failed RHS leaves the name unbound; the asserts
				// reading it then fail rather than trapping.
				if value, ok := eval_expr(ctx, env, node.value); ok {
					env.bindings[node.name] = value
				}
			case Assert_Node:
				if eval_assert(ctx, env, node) {
					result.passed += 1
				} else {
					result.failed += 1
				}
			case Return_Node, If_Node:
				// Return/If are fn-body statements; a test block never holds
				// them, so the evaluator skips them.
			}
		}
	}
	return result
}

// eval_assert passes only when the expression evaluates to Bool true.
eval_assert :: proc(ctx: Eval_Ctx, env: ^Env, node: Assert_Node) -> bool {
	value, ok := eval_expr(ctx, env, node.expr)
	if !ok {
		return false
	}
	passed, is_bool := value.(bool)
	return is_bool && passed
}

eval_expr :: proc(ctx: Eval_Ctx, env: ^Env, expr: Expr) -> (value: Value, ok: bool) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return e.value, true
	case ^Fixed_Lit_Expr:
		return e.bits, true
	case ^String_Lit_Expr:
		// A string literal evaluates to its raw inner text — the §19 asset name a
		// handle constructor (sound("coin_sfx")) or a handle literal (SoundHandle{
		// name: "coin_sfx"}) keys on. Interpolation holes are retained verbatim
		// (a lowering concern, not evaluation), matching the parse-only `text`.
		return e.text, true
	case ^Name_Expr:
		// §02 §2 Bool literals resolve before the environment, mirroring
		// name_check — they are keywords, never shadowable bindings.
		if e.name == "true" {
			return true, true
		}
		if e.name == "false" {
			return false, true
		}
		if bound, found := env_lookup(env, e.name); found {
			return bound, true
		}
		// A module-level `let` constant is a value name resolved through the
		// module (BOARD), evaluated against an empty frame — a constant's RHS
		// reads no local binding.
		if constant, declared := eval_module_const(ctx, e.name); declared {
			return constant, true
		}
		// The sanctioned lowercase constants are the builtin fallback.
		if e.name == "pi" {
			return PI_FIXED, true
		}
		return nil, false
	case ^Unary_Expr:
		return eval_unary(ctx, env, e)
	case ^Binary_Expr:
		return eval_binary(ctx, env, e)
	case ^Member_Expr:
		return eval_member(ctx, env, e)
	case ^Call_Expr:
		return eval_call(ctx, env, e)
	case ^Variant_Expr:
		return eval_variant(ctx, env, e)
	case ^Record_Expr:
		return eval_record(ctx, env, e)
	case ^List_Expr:
		return eval_list(ctx, env, e)
	case ^Tuple_Expr:
		return eval_tuple(ctx, env, e)
	case ^With_Expr:
		return eval_with(ctx, env, e)
	case ^Match_Expr:
		return eval_match(ctx, env, e)
	case ^If_Expr:
		return eval_if(ctx, env, e)
	case ^Lambda_Expr:
		return Lambda_Value{node = e, env = env}, true
	}
	return nil, false
}

// eval_if evaluates a value-producing if-expression (spec §02 §5): the
// condition evaluates to a Bool, then exactly one arm evaluates and yields the
// if-expression's value — the consequent when true, the alternate when false.
// Both arms are present (the parser requires `else`) and unify (the
// typechecker), so a false guard always has an alternate to take. A non-Bool
// condition is a fail-closed ok = false — a typecheck-rejected shape that never
// reaches a passing program.
eval_if :: proc(ctx: Eval_Ctx, env: ^Env, e: ^If_Expr) -> (value: Value, ok: bool) {
	cond := eval_expr(ctx, env, e.cond) or_return
	guard, is_bool := cond.(bool)
	if !is_bool {
		return nil, false
	}
	if guard {
		return eval_expr(ctx, env, e.then_branch)
	}
	return eval_expr(ctx, env, e.else_branch)
}

eval_list :: proc(ctx: Eval_Ctx, env: ^Env, e: ^List_Expr) -> (value: Value, ok: bool) {
	elements := make([]Value, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		elements[i] = eval_expr(ctx, env, element) or_return
	}
	return List_Value{elements = elements}, true
}

// eval_tuple lowers a tuple literal `(a, b, …)` (spec §02; §04 §1): each position
// evaluates in source order into a positional Tuple_Value — the `(value,
// next_rng)` / `(Option, Rng)` shape a draw/startup returns and a tuple-pattern
// match destructures.
eval_tuple :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Tuple_Expr) -> (value: Value, ok: bool) {
	elements := make([]Value, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		elements[i] = eval_expr(ctx, env, element) or_return
	}
	return Tuple_Value{elements = elements}, true
}

// apply_lambda binds the parameters in a fresh child frame off the
// captured environment, so applications are isolated from one another.
apply_lambda :: proc(ctx: Eval_Ctx, lambda: Lambda_Value, args: []Value) -> (value: Value, ok: bool) {
	if len(args) != len(lambda.node.params) {
		return nil, false
	}
	frame := new_env(lambda.env)
	for param, i in lambda.node.params {
		frame.bindings[param] = args[i]
	}
	return eval_expr(ctx, frame, lambda.node.body)
}

// eval_module_const evaluates a module-level `let NAME = expr` constant
// (resolve.odin records it as a Const term). The RHS reads no local binding,
// so it evaluates against a fresh root frame; a name that is not a declared
// const returns declared = false for the caller to fall through.
eval_module_const :: proc(ctx: Eval_Ctx, name: string) -> (value: Value, declared: bool) {
	if term, found := env_term_name(ctx.env, name); !found || term.kind != .Const {
		return nil, false
	}
	for decl in ctx.ast.lets {
		if decl.name == name {
			v, ok := eval_expr(ctx, new_env(nil), decl.value)
			return v, ok
		}
	}
	return nil, false
}

// eval_user_fn evaluates a top-level user fn or a behavior's `step` body
// against its arguments (spec §06 §3): the params bind in a fresh root frame
// (a fn body is a closed scope — it reads only its params and module-level
// constants), then the statement sequence runs to its `return`. ok = false
// when the body produces no value (a body with no reachable return is a
// typecheck-rejected shape that never reaches here).
eval_user_fn :: proc(ctx: Eval_Ctx, fn: Fn_Node, args: []Value) -> (value: Value, ok: bool) {
	if len(args) != len(fn.params) {
		return nil, false
	}
	frame := new_env(nil)
	for param, i in fn.params {
		frame.bindings[param.name] = args[i]
	}
	return eval_statements(ctx, frame, fn.body)
}

// eval_statements runs a fn-body statement sequence to its return value: a let
// binds into the frame, an `if cond { return … }` early-return fires its body
// when the guard is true, and a `return expr` yields. The first return reached
// is the body's value; reaching the end with no return is ok = false.
eval_statements :: proc(ctx: Eval_Ctx, frame: ^Env, body: []Statement) -> (value: Value, ok: bool) {
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			v := eval_expr(ctx, frame, node.value) or_return
			frame.bindings[node.name] = v
		case If_Node:
			cond := eval_expr(ctx, frame, node.cond) or_return
			guard, is_bool := cond.(bool)
			if !is_bool {
				return nil, false
			}
			if guard {
				return eval_statements(ctx, frame, node.body)
			}
		case Return_Node:
			return eval_expr(ctx, frame, node.value)
		case Assert_Node:
			// An assert is a test-block statement; a fn body never holds one.
		}
	}
	return nil, false
}

// eval_variant lowers an enum-variant value: Option::Some/None (the
// evaluable Option family), a bare engine enum variant (Color::White,
// Side::Left is a user enum below), a struct-payload engine command
// (Draw::Rect{…}), or a bare user enum variant. Option is special-cased for
// its payload box; every other bare variant lowers to an Enum_Value.
eval_variant :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Variant_Expr) -> (value: Value, ok: bool) {
	if e.type_name == "Option" {
		return eval_option_variant(ctx, env, e)
	}
	if e.has_fields {
		// A struct-payload engine command variant (Draw::Rect{at, size, color}).
		return eval_struct_variant(ctx, env, e)
	}
	if e.has_payload {
		// The pong surface carries no tuple-payload user or engine variant
		// outside Option; such a form is outside the evaluable domain.
		return nil, false
	}
	// A bare variant value — a user enum (Side::Left) or an engine enum
	// (Color::White). Both lower to the same (type_name, variant) tag.
	return Enum_Value{type_name = e.type_name, variant = e.variant}, true
}

// eval_option_variant lowers Option::Some(v)/Option::None — the boxed Option
// family the numeric kernel and the match arms read.
eval_option_variant :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Variant_Expr) -> (value: Value, ok: bool) {
	switch e.variant {
	case "Some":
		if !e.has_payload || len(e.payload) != 1 {
			return nil, false
		}
		inner := eval_expr(ctx, env, e.payload[0]) or_return
		boxed := new(Value, context.temp_allocator)
		boxed^ = inner
		return Option_Value{is_some = true, payload = boxed}, true
	case "None":
		if e.has_payload {
			return nil, false
		}
		return Option_Value{is_some = false, payload = nil}, true
	}
	return nil, false
}

// eval_struct_variant constructs a struct-payload engine command value
// (Draw::Rect{at, size, color}): each named field evaluates and the result is
// a variant-tagged Record_Value the equality compares structurally.
eval_struct_variant :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Variant_Expr) -> (value: Value, ok: bool) {
	fields := make([]Record_Field_Value, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		fields[i] = Record_Field_Value{name = field.name, value = v}
	}
	return Record_Value{type_name = e.type_name, variant = e.variant, fields = fields}, true
}

// eval_record lowers a record literal: Vec2/Vec3 onto the component slots, and
// a user thing/data/signal literal into a Record_Value carrying its evaluated
// fields. A user literal may omit a defaulted field (spec §03 §1), so the
// declared defaults fill any field the literal did not name.
eval_record :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr) -> (value: Value, ok: bool) {
	switch e.type_name {
	case "Vec2":
		v := Vec2_Value{}
		for field in e.fields {
			component := eval_expr(ctx, env, field.value) or_return
			f := component.(Fixed) or_return
			switch field.name {
			case "x":
				v.x = f
			case "y":
				v.y = f
			case:
				return nil, false
			}
		}
		return v, true
	case "Vec3":
		v := Vec3_Value{}
		for field in e.fields {
			component := eval_expr(ctx, env, field.value) or_return
			f := component.(Fixed) or_return
			switch field.name {
			case "x":
				v.x = f
			case "y":
				v.y = f
			case "z":
				v.z = f
			case:
				return nil, false
			}
		}
		return v, true
	}
	if record, declared := ctx.env.records[e.type_name]; declared {
		return eval_user_record(ctx, env, e, record)
	}
	// A §19 typed asset-handle literal (MeshHandle{name: "coin"}, SoundHandle{name:
	// "coin_sfx"}): the only engine records the evaluator constructs — each named
	// field evaluates into a tagged Record_Value carrying the handle's type name, so
	// the typed seam constant compares equal to the string-constructor handle of the
	// same name (the §19 golden's assets.coin_sfx == sound("coin_sfx")). Reached only
	// for a handle name (surface_engine_record's handle arms); a non-handle engine
	// record (Body, Save) never reaches construction in test position.
	if _, _, is_handle := surface_engine_record(e.type_name); is_handle && is_asset_handle_name(e.type_name) {
		return eval_asset_handle_literal(ctx, env, e)
	}
	return nil, false
}

// is_asset_handle_name reports whether `name` is one of the four §19/§26 typed
// asset handle records — the closed set the evaluator constructs as literals.
// surface_engine_record also schemas Body/Save/etc., which the evaluator does not
// build in test position, so the handle set is named explicitly here rather than
// constructing every engine record.
is_asset_handle_name :: proc(name: string) -> bool {
	switch name {
	case "MeshHandle", "TextureHandle", "SoundHandle", "AtlasHandle":
		return true
	}
	return false
}

// eval_asset_handle_literal builds a typed asset-handle value from its literal:
// each named field evaluates and the result is a Record_Value tagged with the
// handle's type name (no variant). A handle's one field is its String `name`, so
// the value is the handle-typed record the equality compares structurally against
// the string-constructor handle of the same name.
eval_asset_handle_literal :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr) -> (value: Value, ok: bool) {
	fields := make([]Record_Field_Value, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		fields[i] = Record_Field_Value{name = field.name, value = v}
	}
	return Record_Value{type_name = e.type_name, fields = fields}, true
}

// eval_user_record builds a user thing/data/signal value: every field the
// literal names evaluates, then each defaulted field the literal omitted is
// filled from its declared default expression (spec §03 §1). The result is a
// plain (untagged) Record_Value carrying one slot per schema field.
eval_user_record :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr, schema: Record_Schema) -> (value: Value, ok: bool) {
	fields := make([dynamic]Record_Field_Value, 0, len(schema.fields), context.temp_allocator)
	for field in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		append(&fields, Record_Field_Value{name = field.name, value = v})
	}
	// Fill any defaulted schema field the literal left out, in schema order, so
	// two records of the same type carry the same field set regardless of which
	// optional fields each literal named (the Scoreboard{left, right} golden).
	for decl in record_decl_fields(ctx.ast, e.type_name) {
		if !decl.has_default {
			continue
		}
		if _, present := record_field_value(fields[:], decl.name); present {
			continue
		}
		v := eval_expr(ctx, env, decl.default) or_return
		append(&fields, Record_Field_Value{name = decl.name, value = v})
	}
	return Record_Value{type_name = e.type_name, fields = fields[:]}, true
}

// record_decl_fields returns a user record's declared field list (with the
// default expressions the schema does not retain), looked up by type name
// across the thing/data/signal declarations — the source of a literal's
// defaulted fields.
record_decl_fields :: proc(ast: Ast, type_name: string) -> []Field_Decl {
	for decl in ast.things {
		if decl.name == type_name {
			return decl.fields
		}
	}
	for decl in ast.datas {
		if decl.name == type_name {
			return decl.fields
		}
	}
	for decl in ast.signals {
		if decl.name == type_name {
			return decl.fields
		}
	}
	return nil
}

// eval_with applies a record-update `base with { field: v, … }` (spec §02 §5):
// the base evaluates to a Record_Value, then each named field is replaced by
// its new value (copy-on-write — a fresh field slice, the base untouched).
eval_with :: proc(ctx: Eval_Ctx, env: ^Env, e: ^With_Expr) -> (value: Value, ok: bool) {
	base := eval_expr(ctx, env, e.base) or_return
	record, is_record := base.(Record_Value)
	if !is_record {
		return nil, false
	}
	updated := make([]Record_Field_Value, len(record.fields), context.temp_allocator)
	copy(updated, record.fields)
	for replacement in e.fields {
		v := eval_expr(ctx, env, replacement.value) or_return
		if !record_replace_field(updated, replacement.name, v) {
			return nil, false
		}
	}
	return Record_Value{type_name = record.type_name, variant = record.variant, fields = updated}, true
}

// record_replace_field overwrites a named field's slot in place; replaced =
// false when the field is not in the record (a typecheck-rejected shape that
// never reaches evaluation).
record_replace_field :: proc(fields: []Record_Field_Value, name: string, value: Value) -> (replaced: bool) {
	for &field in fields {
		if field.name == name {
			field.value = value
			return true
		}
	}
	return false
}

// eval_match evaluates a match (spec §02 §5): the scrutinee evaluates, then the
// first arm whose pattern matches it runs its body with any payload binders
// bound in a child frame. Pattern matching covers the wildcard, a bare variant
// (user Side::Left or boxed Option::None), and a payload-binding variant
// (Option::Some(v)). Exhaustiveness is the gate's guarantee, so a scrutinee
// always matches some arm here.
eval_match :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Match_Expr) -> (value: Value, ok: bool) {
	scrutinee := eval_expr(ctx, env, e.scrutinee) or_return
	for arm in e.arms {
		frame, matched := match_pattern(arm.pattern, scrutinee, env)
		if matched {
			return eval_expr(ctx, frame, arm.body)
		}
	}
	return nil, false
}

// match_pattern tests one arm pattern against a scrutinee value and, on a
// match, returns a frame holding the pattern's payload binders. A wildcard
// always matches with no binders; a bare variant matches an Enum_Value of the
// same (type_name, variant) or the Option None tag; a payload-binding variant
// matches Option::Some and binds its single payload.
match_pattern :: proc(pattern: Pattern, scrutinee: Value, env: ^Env) -> (frame: ^Env, matched: bool) {
	switch pattern.kind {
	case .Wildcard:
		return env, true
	case .Bare_Variant:
		if pattern.type_name == "Option" {
			option, is_option := scrutinee.(Option_Value)
			return env, is_option && !option.is_some && pattern.variant == "None"
		}
		variant, is_variant := scrutinee.(Enum_Value)
		matched = is_variant && variant.type_name == pattern.type_name && variant.variant == pattern.variant
		return env, matched
	case .Variant_Binds:
		option, is_option := scrutinee.(Option_Value)
		if !is_option || !option.is_some || pattern.variant != "Some" || len(pattern.binders) != 1 {
			return env, false
		}
		child := new_env(env)
		child.bindings[pattern.binders[0]] = option.payload^
		return child, true
	case .Struct_Binds:
		// A struct-payload variant value materializes as a Record_Value carrying
		// its variant tag and fields; the pattern matches on (type_name, variant)
		// and field-puns each named binder from the record's fields. A missing
		// field is a non-match rather than a binding to a hole.
		record, is_record := scrutinee.(Record_Value)
		if !is_record || record.type_name != pattern.type_name || record.variant != pattern.variant {
			return env, false
		}
		child := new_env(env)
		for binder in pattern.binders {
			value, found := record_field_value(record.fields, binder)
			if !found {
				return env, false
			}
			child.bindings[binder] = value
		}
		return child, true
	case .Bare_Binder:
		// A bare binder matches any value and binds it to its single name — a
		// tuple position that captures the whole element (snake's `next` Rng
		// position in `(Option::Some(cell), next)`).
		if len(pattern.binders) != 1 {
			return env, false
		}
		child := new_env(env)
		child.bindings[pattern.binders[0]] = scrutinee
		return child, true
	case .Tuple:
		// Tuple decomposition: the scrutinee must be a Tuple_Value of the same
		// arity, and every positional sub-pattern must match its element. Binders
		// from every position accumulate into one shared child frame, so
		// `(Option::Some(cell), next)` binds both `cell` (from the nested variant
		// arm) and `next` (the bare binder) for the body — the §04 §1 pick-result
		// destructure. A non-tuple, an arity mismatch, or any position miss is a
		// non-match.
		return match_tuple_pattern(pattern, scrutinee, env)
	}
	return env, false
}

// match_tuple_pattern destructures a tuple scrutinee against a tuple pattern:
// each positional sub-pattern is matched against the element at the same
// position by a recursive match_pattern, threading the accumulating binder frame
// through every position so binders from all positions are visible in the arm
// body. The threaded frame starts at `env` and each matched sub-pattern returns
// the next frame (a child when it bound names, the same frame otherwise).
match_tuple_pattern :: proc(pattern: Pattern, scrutinee: Value, env: ^Env) -> (frame: ^Env, matched: bool) {
	tuple, is_tuple := scrutinee.(Tuple_Value)
	if !is_tuple || len(tuple.elements) != len(pattern.elements) {
		return env, false
	}
	current := env
	for sub, i in pattern.elements {
		next, sub_matched := match_pattern(sub, tuple.elements[i], current)
		if !sub_matched {
			return env, false
		}
		current = next
	}
	return current, true
}

// eval_unary lowers the two unary forms (spec §02): numeric negation `-x` over a
// Fixed/Int, and the word operator `not x` over a Bool — the `not contains(occ,
// c)` predicate body snake's free-cell filter takes. `not` is carried as an
// Ident token (parse_unary), so it is keyed by text, not kind.
eval_unary :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Unary_Expr) -> (value: Value, ok: bool) {
	operand := eval_expr(ctx, env, e.operand) or_return
	if e.op.kind == .Ident && e.op.text == "not" {
		b, is_bool := operand.(bool)
		if !is_bool {
			return nil, false
		}
		return !b, true
	}
	if e.op.kind != .Minus {
		return nil, false
	}
	#partial switch v in operand {
	case Fixed:
		return fixed_neg(v), true
	case i64:
		return int_neg(v), true
	}
	return nil, false
}

eval_binary :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Binary_Expr) -> (value: Value, ok: bool) {
	lhs := eval_expr(ctx, env, e.lhs) or_return
	rhs := eval_expr(ctx, env, e.rhs) or_return
	if e.op.kind == .Eq_Eq {
		return value_equal(lhs, rhs), true
	}
	if e.op.kind == .Not_Eq {
		return !value_equal(lhs, rhs), true
	}
	if compared, handled := eval_comparison(e.op.kind, lhs, rhs); handled {
		return compared, true
	}
	if e.op.kind == .Ident {
		return eval_logical(e.op.text, lhs, rhs)
	}
	#partial switch l in lhs {
	case Fixed:
		r, is_fixed := rhs.(Fixed)
		if !is_fixed {
			return nil, false
		}
		#partial switch e.op.kind {
		case .Plus:
			return fixed_add(l, r), true
		case .Minus:
			return fixed_sub(l, r), true
		case .Star:
			return fixed_mul(l, r), true
		case .Slash:
			return fixed_div(l, r), true
		case .Percent:
			return fixed_mod(l, r), true
		}
	case i64:
		r, is_int := rhs.(i64)
		if !is_int {
			return nil, false
		}
		#partial switch e.op.kind {
		case .Plus:
			return int_add(l, r), true
		case .Minus:
			return int_sub(l, r), true
		case .Star:
			return int_mul(l, r), true
		case .Slash:
			return int_div(l, r), true
		case .Percent:
			return int_mod(l, r), true
		}
	case Vec2_Value:
		return eval_vec2_binary(e.op.kind, l, rhs)
	case Vec3_Value:
		return eval_vec3_binary(e.op.kind, l, rhs)
	}
	return nil, false
}

// eval_comparison handles the ordering operators (< <= > >=) over two
// same-typed numeric scalars into a Bool. handled = false for any other
// operator so the caller continues to the arithmetic arms.
eval_comparison :: proc(op: Token_Kind, lhs, rhs: Value) -> (value: Value, handled: bool) {
	#partial switch op {
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
	case:
		return nil, false
	}
	if l, is_fixed := lhs.(Fixed); is_fixed {
		if r, ok := rhs.(Fixed); ok {
			return compare_ordered(op, i64(l), i64(r)), true
		}
	}
	if l, is_int := lhs.(i64); is_int {
		if r, ok := rhs.(i64); ok {
			return compare_ordered(op, l, r), true
		}
	}
	return nil, false
}

compare_ordered :: proc(op: Token_Kind, l, r: i64) -> bool {
	#partial switch op {
	case .Lt:
		return l < r
	case .Lt_Eq:
		return l <= r
	case .Gt:
		return l > r
	case .Gt_Eq:
		return l >= r
	}
	return false
}

// eval_logical evaluates the word operators `and`/`or` over two Bool sides.
// Both sides are already evaluated (the kernel has no short-circuit shape),
// matching the typecheck that demands two Bool operands.
eval_logical :: proc(op: string, lhs, rhs: Value) -> (value: Value, ok: bool) {
	l, l_bool := lhs.(bool)
	r, r_bool := rhs.(bool)
	if !l_bool || !r_bool {
		return nil, false
	}
	switch op {
	case "and":
		return l && r, true
	case "or":
		return l || r, true
	}
	return nil, false
}

// eval_vec2_binary lowers Vec2 arithmetic: Vec2 ± Vec2 component-wise, and
// Vec2 * Fixed component scaling — the `at + vel*dt` form the pong advance
// helper takes (spec §10).
eval_vec2_binary :: proc(op: Token_Kind, l: Vec2_Value, rhs: Value) -> (value: Value, ok: bool) {
	if r, is_vec := rhs.(Vec2_Value); is_vec {
		#partial switch op {
		case .Plus:
			return vec2_add(l, r), true
		case .Minus:
			return vec2_sub(l, r), true
		}
		return nil, false
	}
	if s, is_fixed := rhs.(Fixed); is_fixed && op == .Star {
		return vec2_scale(l, s), true
	}
	return nil, false
}

eval_vec3_binary :: proc(op: Token_Kind, l: Vec3_Value, rhs: Value) -> (value: Value, ok: bool) {
	if r, is_vec := rhs.(Vec3_Value); is_vec {
		#partial switch op {
		case .Plus:
			return vec3_add(l, r), true
		case .Minus:
			return vec3_sub(l, r), true
		}
		return nil, false
	}
	if s, is_fixed := rhs.(Fixed); is_fixed && op == .Star {
		return vec3_scale(l, s), true
	}
	return nil, false
}

// eval_member resolves a type's associated constants (Fixed.MAX, Fixed.MIN,
// Quat.identity) and field access off a value receiver — a user record's
// declared field (self.pos) or a Vec2/Vec3 component (v.x).
eval_member :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Member_Expr) -> (value: Value, ok: bool) {
	if recv, is_name := e.receiver.(^Name_Expr); is_name {
		if _, bound := env_lookup(env, recv.name); !bound {
			switch recv.name {
			case "Fixed":
				switch e.member {
				case "MAX":
					return FIXED_MAX, true
				case "MIN":
					return FIXED_MIN, true
				}
			case "Quat":
				if e.member == "identity" {
					return QUAT_IDENTITY, true
				}
			}
		}
	}
	receiver := eval_expr(ctx, env, e.receiver) or_return
	return eval_field_access(receiver, e.member)
}

// eval_field_access reads a member off a value: a user record's field
// (Goal.side, self.pos), a Vec2/Vec3 component (v.x), or the §04 Time resource's
// dt — the per-tick delta in fixed seconds the hunt search countdown folds.
eval_field_access :: proc(receiver: Value, member: string) -> (value: Value, ok: bool) {
	#partial switch r in receiver {
	case Record_Value:
		return record_field_value(r.fields, member)
	case Time_Value:
		if member == "dt" {
			return r.dt, true
		}
	case Vec2_Value:
		switch member {
		case "x":
			return r.x, true
		case "y":
			return r.y, true
		}
	case Vec3_Value:
		switch member {
		case "x":
			return r.x, true
		case "y":
			return r.y, true
		case "z":
			return r.z, true
		}
	}
	return nil, false
}

eval_call :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if member, is_method := e.callee.(^Member_Expr); is_method {
		return eval_method_call(ctx, env, member, e.args)
	}
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, false
	}
	switch name.name {
	case "to_fixed":
		if len(e.args) != 1 {
			return nil, false
		}
		arg := eval_expr(ctx, env, e.args[0]) or_return
		n, is_int := arg.(i64)
		if !is_int {
			return nil, false
		}
		return to_fixed(n), true
	case "trunc":
		f := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_trunc(f), true
	case "floor":
		f := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_floor(f), true
	case "round":
		f := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_round(f), true
	case "abs":
		f := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_abs(f), true
	case "clamp":
		x := eval_fixed_arg(ctx, env, e, 0, 3) or_return
		lo := eval_fixed_arg(ctx, env, e, 1, 3) or_return
		hi := eval_fixed_arg(ctx, env, e, 2, 3) or_return
		return fixed_clamp(x, lo, hi), true
	case "lerp":
		a := eval_fixed_arg(ctx, env, e, 0, 3) or_return
		b := eval_fixed_arg(ctx, env, e, 1, 3) or_return
		t := eval_fixed_arg(ctx, env, e, 2, 3) or_return
		return fixed_lerp(a, b, t), true
	case "checked_div":
		a := eval_fixed_arg(ctx, env, e, 0, 2) or_return
		b := eval_fixed_arg(ctx, env, e, 1, 2) or_return
		quotient, has_quotient := fixed_checked_div(a, b)
		if !has_quotient {
			return Option_Value{is_some = false, payload = nil}, true
		}
		boxed := new(Value, context.temp_allocator)
		boxed^ = quotient
		return Option_Value{is_some = true, payload = boxed}, true
	case "dot":
		if len(e.args) != 2 {
			return nil, false
		}
		lhs := eval_expr(ctx, env, e.args[0]) or_return
		rhs := eval_expr(ctx, env, e.args[1]) or_return
		if a2, is_vec2 := lhs.(Vec2_Value); is_vec2 {
			b2 := rhs.(Vec2_Value) or_return
			return vec2_dot(a2, b2), true
		}
		a3 := lhs.(Vec3_Value) or_return
		b3 := rhs.(Vec3_Value) or_return
		return vec3_dot(a3, b3), true
	case "cross":
		if len(e.args) != 2 {
			return nil, false
		}
		lhs := eval_expr(ctx, env, e.args[0]) or_return
		rhs := eval_expr(ctx, env, e.args[1]) or_return
		a3 := lhs.(Vec3_Value) or_return
		b3 := rhs.(Vec3_Value) or_return
		return vec3_cross(a3, b3), true
	case "length":
		if len(e.args) != 1 {
			return nil, false
		}
		arg := eval_expr(ctx, env, e.args[0]) or_return
		if v2, is_vec2 := arg.(Vec2_Value); is_vec2 {
			return vec2_length(v2), true
		}
		v3 := arg.(Vec3_Value) or_return
		return vec3_length(v3), true
	case "sin":
		angle := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_sin(angle), true
	case "cos":
		angle := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_cos(angle), true
	case "rot_x":
		// §16 §7 the per-bone X-axis rotation builder: a fixed-point angle
		// (radians) into a Transform with the identity translation, a rotation of
		// `angle` about the local X axis, and unit scale — the leg/arm swing a pose
		// generator drives a bone with (pose_walk's rot_x(s)). At angle 0 the
		// quaternion is the identity, so rot_x(0.0) is the rest transform.
		angle := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return transform_rot_x(angle), true
	case "up":
		// §16 §7 the per-bone vertical-offset builder: a fixed-point displacement
		// into a Transform translating by `d` along the local +Y axis, with the
		// identity rotation and unit scale — pose_idle's torso breathing bob.
		d := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return transform_up(d), true
	case "fold":
		return eval_fold(ctx, env, e)
	case "first":
		return eval_first(ctx, env, e)
	case "prepend":
		return eval_prepend(ctx, env, e)
	case "init":
		return eval_init(ctx, env, e)
	case "contains":
		return eval_contains(ctx, env, e)
	case "concat":
		return eval_concat(ctx, env, e)
	case "is_empty":
		return eval_is_empty(ctx, env, e)
	case "map":
		return eval_map(ctx, env, e)
	case "filter":
		return eval_filter(ctx, env, e)
	case "grid_cells":
		return eval_grid_cells(ctx, env, e)
	case "mesh":
		return eval_asset_constructor(ctx, env, e, "MeshHandle")
	case "texture":
		return eval_asset_constructor(ctx, env, e, "TextureHandle")
	case "sound":
		return eval_asset_constructor(ctx, env, e, "SoundHandle")
	case "atlas":
		return eval_asset_constructor(ctx, env, e, "AtlasHandle")
	}
	// A call to a user-declared top-level fn (advance, goal_side, add_goal):
	// resolve its body off the module and evaluate it against the arguments.
	if fn, declared := find_user_fn(ctx.ast, name.name); declared {
		args := eval_args(ctx, env, e.args) or_return
		return eval_user_fn(ctx, fn, args)
	}
	return nil, false
}

// eval_asset_constructor lowers a §19/§26 manifest-checked string constructor
// (mesh/texture/sound/atlas): a single String asset name into the same typed
// handle value the seam constant's literal builds — Record_Value tagged with the
// handle type, carrying the one `name` field set to the string argument. So
// sound("coin_sfx") evaluates to the identical handle that SoundHandle{name:
// "coin_sfx"} (the typed constant assets.coin_sfx) does, and the two compare equal
// (the §19 golden assertion). The closed-registry kind/name validity is the build
// gate's (asset_registry.odin); the evaluator builds the value the typecheck-passed
// reference names.
eval_asset_constructor :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr, handle_type: string) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	arg := eval_expr(ctx, env, e.args[0]) or_return
	name, is_string := arg.(string)
	if !is_string {
		return nil, false
	}
	fields := make([]Record_Field_Value, 1, context.temp_allocator)
	fields[0] = Record_Field_Value{name = "name", value = name}
	return Record_Value{type_name = handle_type, fields = fields}, true
}

// eval_args evaluates a call's argument expressions left-to-right into a value
// slice — the argument row a user fn or behavior step binds its parameters to.
eval_args :: proc(ctx: Eval_Ctx, env: ^Env, args: []Expr) -> (values: []Value, ok: bool) {
	out := make([]Value, len(args), context.temp_allocator)
	for arg, i in args {
		out[i] = eval_expr(ctx, env, arg) or_return
	}
	return out, true
}

// find_user_fn looks up a top-level user fn by name (advance, goal_side,
// add_goal). A behavior's `step` is reached through eval_method_call, not here.
find_user_fn :: proc(ast: Ast, name: string) -> (fn: Fn_Node, found: bool) {
	for decl in ast.fns {
		if decl.name == name {
			return decl, true
		}
	}
	return Fn_Node{}, false
}

// eval_fold reduces strictly left-to-right: acc = combinator(acc, element)
// in element order, never tree-reduced or reordered — fixed-point + is
// not reorder-invariant under saturation, so the order IS the result
// (spec §10). The combinator is a literal lambda or a bare user-fn value
// (tally's fold(goals, self, add_goal) passes the add_goal fn by name).
eval_fold :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 3 {
		return nil, false
	}
	list_value := eval_expr(ctx, env, e.args[0]) or_return
	list := list_value.(List_Value) or_return
	acc := eval_expr(ctx, env, e.args[1]) or_return
	for element in list.elements {
		acc = apply_combinator(ctx, env, e.args[2], {acc, element}) or_return
	}
	return acc, true
}

// eval_first lowers the §08 list combinator first: first(list) yields the
// head wrapped in Option (None on empty), and first(list, pred) yields the
// first element the predicate accepts. The pong serve behavior takes the
// one-argument form over a [Goal] list; the predicate form rides the same
// combinator-application seam fold uses.
eval_first :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 && len(e.args) != 2 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	list := source.(List_Value) or_return
	for element in list.elements {
		if len(e.args) == 1 {
			return some_value(element), true
		}
		verdict := apply_combinator(ctx, env, e.args[1], {element}) or_return
		accepted, is_bool := verdict.(bool)
		if is_bool && accepted {
			return some_value(element), true
		}
	}
	return Option_Value{is_some = false, payload = nil}, true
}

// eval_list_arg evaluates argument i of an expected-arity call and demands a
// list — the shared shape the §08 list combinators read. A View materializes as
// a List_Value (eval reads its rows as elements), so a View argument satisfies
// this just as a literal list does.
eval_list_arg :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr, i: int, arity: int) -> (elements: []Value, ok: bool) {
	if len(e.args) != arity {
		return nil, false
	}
	value := eval_expr(ctx, env, e.args[i]) or_return
	list, is_list := value.(List_Value)
	if !is_list {
		return nil, false
	}
	return list.elements, true
}

// eval_prepend lowers `prepend(elem, list) -> [T]` (spec §08): a fresh list with
// `elem` at the front then every element of `list` in order. Snake's cells()
// prepends the head onto the body. The input list is never mutated.
eval_prepend :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	elem := eval_expr(ctx, env, e.args[0]) or_return
	elements := eval_list_arg(ctx, env, e, 1, 2) or_return
	out := make([]Value, len(elements) + 1, context.temp_allocator)
	out[0] = elem
	for element, i in elements {
		out[i + 1] = element
	}
	return List_Value{elements = out}, true
}

// eval_init lowers `init(list) -> [T]` (spec §08): every element except the last.
// Snake's body_after drops the tail this way when the snake is not growing. The
// empty list yields the empty list (total — no fault on a missing last element).
eval_init :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 1) or_return
	if len(elements) == 0 {
		return List_Value{elements = make([]Value, 0, context.temp_allocator)}, true
	}
	out := make([]Value, len(elements) - 1, context.temp_allocator)
	for i in 0 ..< len(elements) - 1 {
		out[i] = elements[i]
	}
	return List_Value{elements = out}, true
}

// eval_contains lowers `contains(list, elem) -> Bool` (spec §08): true when any
// element structurally equals `elem`. Snake tests `contains(self.body, self.head)`
// over Cell records, so the membership is the deep record equality value_equal folds.
eval_contains :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	elem := eval_expr(ctx, env, e.args[1]) or_return
	for element in elements {
		if value_equal(element, elem) {
			return true, true
		}
	}
	return false, true
}

// eval_concat lowers `concat(a, b) -> [T]` (spec §08): every element of `a` then
// every element of `b`, both in order. Snake's occupied() concatenates the
// snake's cells with the food cells. Both inputs are read, never mutated.
eval_concat :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	a := eval_list_arg(ctx, env, e, 0, 2) or_return
	b := eval_list_arg(ctx, env, e, 1, 2) or_return
	out := make([]Value, len(a) + len(b), context.temp_allocator)
	for element, i in a {
		out[i] = element
	}
	for element, i in b {
		out[len(a) + i] = element
	}
	return List_Value{elements = out}, true
}

// eval_is_empty lowers `is_empty(list) -> Bool` (spec §08): true when the list
// has no elements. Snake gates grow/replenish/apply_death on an empty signal
// list this way.
eval_is_empty :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 1) or_return
	return len(elements) == 0, true
}

// eval_map lowers `map(source, fn) -> [U]` (spec §08): a fresh list applying the
// unary function to each element in source order. The function slot is a literal
// lambda or a bare user-fn name (apply_combinator), the same two forms fold's
// combinator admits. Snake projects food rows to cells and cells to draw rects
// this way; the View source materializes as a list, so map over a View yields a list.
eval_map :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	out := make([]Value, len(elements), context.temp_allocator)
	for element, i in elements {
		out[i] = apply_combinator(ctx, env, e.args[1], {element}) or_return
	}
	return List_Value{elements = out}, true
}

// eval_filter lowers `filter(source, pred) -> [T]` (spec §08): a fresh list of
// the elements the unary predicate accepts, in source order. Snake's free-cell
// selection filters all_cells() by un-occupied, and detect_eat filters foods by
// the head cell. The kept elements preserve the deterministic source order.
eval_filter :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	kept := make([dynamic]Value, 0, len(elements), context.temp_allocator)
	for element in elements {
		verdict := apply_combinator(ctx, env, e.args[1], {element}) or_return
		accepted, is_bool := verdict.(bool)
		if !is_bool {
			return nil, false
		}
		if accepted {
			append(&kept, element)
		}
	}
	return List_Value{elements = kept[:]}, true
}

// eval_grid_cells lowers `grid_cells(w, h, fn(x, y) -> Cell) -> [Cell]` (spec
// §26): every cell of a w×h grid in STABLE ROW-MAJOR order, built by the two-arg
// lambda. The outer loop walks rows (y from 0), the inner walks columns (x from
// 0), so the enumeration is machine-identical — driven by the loop indices, never
// by any map iteration. A non-positive extent yields the empty list (total). The
// w/h are Ints (§10). Snake's all_cells() folds free-cell selection through this.
eval_grid_cells :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 3 {
		return nil, false
	}
	w_val := eval_expr(ctx, env, e.args[0]) or_return
	h_val := eval_expr(ctx, env, e.args[1]) or_return
	fn_val := eval_expr(ctx, env, e.args[2]) or_return
	w, w_is_int := w_val.(i64)
	h, h_is_int := h_val.(i64)
	lambda, is_lambda := fn_val.(Lambda_Value)
	if !w_is_int || !h_is_int || !is_lambda {
		return nil, false
	}
	count := (w > 0 && h > 0) ? int(w) * int(h) : 0
	out := make([]Value, count, context.temp_allocator)
	idx := 0
	for y in 0 ..< h {
		for x in 0 ..< w {
			cell := apply_lambda(ctx, lambda, {x, y}) or_return
			out[idx] = cell
			idx += 1
		}
	}
	return List_Value{elements = out}, true
}

// some_value boxes a value as Option::Some — the payload pointer a union
// cannot hold inline.
some_value :: proc(inner: Value) -> Value {
	boxed := new(Value, context.temp_allocator)
	boxed^ = inner
	return Option_Value{is_some = true, payload = boxed}
}

// apply_combinator applies a fold/first function argument to an argument row:
// a literal lambda binds its params and evaluates its body, while a bare
// user-fn name resolves to the fn and runs its body — the two forms a
// combinator's function slot admits (add_goal by name, a literal predicate).
apply_combinator :: proc(ctx: Eval_Ctx, env: ^Env, arg: Expr, args: []Value) -> (value: Value, ok: bool) {
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		return apply_lambda(ctx, Lambda_Value{node = lambda, env = env}, args)
	}
	if name, is_name := arg.(^Name_Expr); is_name {
		if fn, declared := find_user_fn(ctx.ast, name.name); declared {
			return eval_user_fn(ctx, fn, args)
		}
	}
	return nil, false
}

// eval_method_call dispatches receiver.method(args). The §04 name.step(args)
// behavior-invocation form runs a behavior's step body in test position; a
// Quat type-name receiver selects an associated constructor (Quat.axis_angle);
// a value receiver selects a method on the evaluated quaternion.
eval_method_call :: proc(ctx: Eval_Ctx, env: ^Env, callee: ^Member_Expr, args: []Expr) -> (value: Value, ok: bool) {
	if recv, is_name := callee.receiver.(^Name_Expr); is_name {
		if _, bound := env_lookup(env, recv.name); !bound {
			// A behavior name reached through `.step` runs that behavior's step
			// body against the test arguments (spec §04).
			if behavior, is_behavior := find_user_behavior(ctx.ast, recv.name); is_behavior && callee.member == "step" {
				values := eval_args(ctx, env, args) or_return
				return eval_user_fn(ctx, behavior.step, values)
			}
			if recv.name == "Quat" {
				return eval_quat_constructor(ctx, env, callee.member, args)
			}
			if recv.name == "Pose" {
				return eval_pose_static(ctx, env, callee.member, args)
			}
			// The §23 static resource builders: Input.empty() the empty input
			// snapshot, Time.at(dt) a fixed-dt Time, View.of(list) a §08 read table
			// materialized as a list. A resource name is never an env binding, so
			// this branch only fires for the type-name static-method form.
			if builder, is_builder := eval_resource_builder(ctx, env, recv.name, callee.member, args); is_builder {
				return builder, true
			}
		}
	}
	receiver := eval_expr(ctx, env, callee.receiver) or_return
	// A method call on a value receiver: the §23 §2 Input queries (an inline test
	// seeds the snapshot via Input.empty().with_pressed(…) and reads it via
	// .pressed(…)), then the quaternion methods.
	if input, is_input := receiver.(Input_Value); is_input {
		return eval_input_method(ctx, env, input, callee.member, args)
	}
	// A §16 §7 method on a Pose value: set(Bone, Transform) drives one bone
	// (returning the Pose, so a generator chains .set across bones), get(Bone)
	// reads a bone's Transform (rest when the pose leaves it undriven).
	if pose, is_pose := receiver.(Pose_Value); is_pose {
		return eval_pose_method(ctx, env, pose, callee.member, args)
	}
	q := receiver.(Quat_Value) or_return
	switch callee.member {
	case "rotate":
		if len(args) != 1 {
			return nil, false
		}
		arg := eval_expr(ctx, env, args[0]) or_return
		v := arg.(Vec3_Value) or_return
		return quat_rotate(q, v), true
	case "mul":
		if len(args) != 1 {
			return nil, false
		}
		arg := eval_expr(ctx, env, args[0]) or_return
		other := arg.(Quat_Value) or_return
		return quat_mul(q, other), true
	case "slerp":
		if len(args) != 2 {
			return nil, false
		}
		other_value := eval_expr(ctx, env, args[0]) or_return
		other := other_value.(Quat_Value) or_return
		t_value := eval_expr(ctx, env, args[1]) or_return
		t := t_value.(Fixed) or_return
		return quat_slerp(q, other, t), true
	}
	return nil, false
}

// eval_resource_builder lowers the §23 static resource builders applied as a
// type-name static method (spec §23): Input.empty() is the empty input snapshot
// an inline test seeds, Time.at(dt) a fixed-dt Time resource, and View.of(list) a
// §08 read table built from a literal list — materialized as a List_Value so the
// list combinators (first/map/filter) read its rows as elements exactly as they
// read a literal list. is_builder is false for any other (type, member) pair so
// the caller falls through to its other type-name forms.
eval_resource_builder :: proc(ctx: Eval_Ctx, env: ^Env, type_name, member: string, args: []Expr) -> (value: Value, is_builder: bool) {
	switch type_name {
	case "Input":
		if member == "empty" && len(args) == 0 {
			return Input_Value{pressed = make([]Input_Press, 0, context.temp_allocator)}, true
		}
	case "Time":
		if member == "at" && len(args) == 1 {
			dt_value, dt_ok := eval_expr(ctx, env, args[0])
			if !dt_ok {
				return nil, false
			}
			dt, is_fixed := dt_value.(Fixed)
			if !is_fixed {
				return nil, false
			}
			return Time_Value{dt = dt}, true
		}
	case "View":
		if member == "of" && len(args) == 1 {
			source, source_ok := eval_expr(ctx, env, args[0])
			if !source_ok {
				return nil, false
			}
			// View.of(list) materializes the read table as the list itself — a View
			// row read is the underlying element read (the runtime threads View rows
			// to a behavior as a list, so the evaluator mirrors that here).
			list, is_list := source.(List_Value)
			if !is_list {
				return nil, false
			}
			return list, true
		}
	}
	return nil, false
}

// eval_input_method lowers a §23 §2 query on an Input snapshot value: pressed/
// released/held read whether a (player, action) button is in the snapshot's held
// set, with_pressed returns a new snapshot adding one held button, and value/axis
// read the analog channels — which a with_pressed snapshot never seeds, so they
// read the zero / zero-vector default (a behavior never faults on input). The
// (player, action) pair is identified by its variant names (PlayerId::P1,
// Move::Down), matching the snapshot's recorded press identity.
eval_input_method :: proc(ctx: Eval_Ctx, env: ^Env, input: Input_Value, member: string, args: []Expr) -> (value: Value, ok: bool) {
	switch member {
	case "with_pressed":
		player, action, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		next := make([]Input_Press, len(input.pressed) + 1, context.temp_allocator)
		copy(next, input.pressed)
		next[len(input.pressed)] = Input_Press{player = player, action = action}
		return Input_Value{pressed = next}, true
	case "pressed", "held":
		player, action, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return input_is_pressed(input, player, action), true
	case "released":
		// A released edge is never set by with_pressed (which marks down-this-tick),
		// so a seeded snapshot reads no release — the §23 §2 default.
		_, _, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return false, true
	case "value":
		// The analog 1D read of an unseeded channel is the zero default.
		_, _, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return Fixed(0), true
	case "axis":
		// The analog 2D read of an unseeded channel is the zero vector default.
		_, _, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return Vec2_Value{}, true
	}
	return nil, false
}

// eval_input_button_args evaluates an Input query's (player, action) argument
// pair to their variant names — the (PlayerId, action-enum) the snapshot keys a
// press on. ok is false on a wrong arity or a non-variant argument.
eval_input_button_args :: proc(ctx: Eval_Ctx, env: ^Env, args: []Expr) -> (player, action: string, ok: bool) {
	if len(args) != 2 {
		return "", "", false
	}
	player_value, p_ok := eval_expr(ctx, env, args[0])
	action_value, a_ok := eval_expr(ctx, env, args[1])
	if !p_ok || !a_ok {
		return "", "", false
	}
	player_variant, is_player := player_value.(Enum_Value)
	action_variant, is_action := action_value.(Enum_Value)
	if !is_player || !is_action {
		return "", "", false
	}
	return player_variant.variant, action_variant.variant, true
}

// input_is_pressed reports whether a (player, action) button is in a snapshot's
// held set — a linear scan over the recorded presses, keyed by variant name.
input_is_pressed :: proc(input: Input_Value, player, action: string) -> bool {
	for press in input.pressed {
		if press.player == player && press.action == action {
			return true
		}
	}
	return false
}

// eval_quat_constructor lowers the Quat.axis_angle associated constructor.
eval_quat_constructor :: proc(ctx: Eval_Ctx, env: ^Env, member: string, args: []Expr) -> (value: Value, ok: bool) {
	if member != "axis_angle" || len(args) != 2 {
		return nil, false
	}
	axis_value := eval_expr(ctx, env, args[0]) or_return
	axis := axis_value.(Vec3_Value) or_return
	angle_value := eval_expr(ctx, env, args[1]) or_return
	angle := angle_value.(Fixed) or_return
	return quat_axis_angle(axis, angle), true
}

// transform_identity is the §16 §7 rest transform: no translation, the identity
// rotation, unit scale — the transform a Pose assigns to a bone it does not drive
// (Pose.get of an undriven bone), and the base every rot_x/up builds off.
transform_identity :: proc() -> Transform_Value {
	return Transform_Value{
		pos   = Vec3_Value{},
		rot   = QUAT_IDENTITY,
		scale = Vec3_Value{x = FIXED_ONE, y = FIXED_ONE, z = FIXED_ONE},
	}
}

// transform_rot_x builds the §16 §7 rot_x(angle) Transform: the identity
// translation, a quaternion rotating `angle` radians about the local X axis, and
// unit scale. At angle 0 the quaternion is the identity (sin(0)=0, cos(0)=1), so
// rot_x(0.0) equals the rest transform — the zero-crossing the pose_walk golden
// asserts.
transform_rot_x :: proc(angle: Fixed) -> Transform_Value {
	t := transform_identity()
	t.rot = quat_axis_angle(Vec3_Value{x = FIXED_ONE}, angle)
	return t
}

// transform_up builds the §16 §7 up(d) Transform: a translation of `d` along the
// local +Y axis, the identity rotation, and unit scale — the torso bob a pose
// generator drives the torso with.
transform_up :: proc(d: Fixed) -> Transform_Value {
	t := transform_identity()
	t.pos = Vec3_Value{y = d}
	return t
}

// eval_pose_static lowers the §16 §7 Pose Type-name static builders/combinators:
// empty() seeds the sparse pose a generator .set()s bones on; blend(a, b, weight)
// per-bone interpolates two poses; layer(base, overlay) lets the overlay win per
// bone. ok = false for any other (member, arity) shape — a typecheck-rejected
// form that never reaches a passing program.
eval_pose_static :: proc(ctx: Eval_Ctx, env: ^Env, member: string, args: []Expr) -> (value: Value, ok: bool) {
	switch member {
	case "empty":
		if len(args) != 0 {
			return nil, false
		}
		return Pose_Value{bones = make([]Pose_Bone_Transform, 0, context.temp_allocator)}, true
	case "blend":
		if len(args) != 3 {
			return nil, false
		}
		a := eval_pose_expr(ctx, env, args[0]) or_return
		b := eval_pose_expr(ctx, env, args[1]) or_return
		weight := eval_expr(ctx, env, args[2]) or_return
		w, is_fixed := weight.(Fixed)
		if !is_fixed {
			return nil, false
		}
		return eval_pose_blend(a, b, w), true
	case "layer":
		if len(args) != 2 {
			return nil, false
		}
		base := eval_pose_expr(ctx, env, args[0]) or_return
		overlay := eval_pose_expr(ctx, env, args[1]) or_return
		return eval_pose_layer(base, overlay), true
	}
	return nil, false
}

// eval_pose_method lowers the §16 §7 Pose value methods: set(Bone, Transform)
// returns a new pose driving the named bone, get(Bone) reads a bone's transform
// (the rest transform when the pose leaves the bone undriven).
eval_pose_method :: proc(ctx: Eval_Ctx, env: ^Env, pose: Pose_Value, member: string, args: []Expr) -> (value: Value, ok: bool) {
	switch member {
	case "set":
		if len(args) != 2 {
			return nil, false
		}
		bone := eval_bone_arg(ctx, env, args[0]) or_return
		transform_value := eval_expr(ctx, env, args[1]) or_return
		transform, is_transform := transform_value.(Transform_Value)
		if !is_transform {
			return nil, false
		}
		return eval_pose_set(pose, bone, transform), true
	case "get":
		if len(args) != 1 {
			return nil, false
		}
		bone := eval_bone_arg(ctx, env, args[0]) or_return
		return eval_pose_get(pose, bone), true
	}
	return nil, false
}

// eval_pose_set returns a new pose driving `bone` with `transform`: an existing
// driven bone is overwritten in place (a re-`.set` of the same bone replaces, not
// duplicates), a new bone is appended — keeping the driven-bone slice in a
// deterministic insert order, never a map (the determinism tripwire). The input
// pose is never mutated (a fresh slice copy).
eval_pose_set :: proc(pose: Pose_Value, bone: string, transform: Transform_Value) -> Value {
	for driven, i in pose.bones {
		if driven.bone == bone {
			next := make([]Pose_Bone_Transform, len(pose.bones), context.temp_allocator)
			copy(next, pose.bones)
			next[i].transform = transform
			return Pose_Value{bones = next}
		}
	}
	next := make([]Pose_Bone_Transform, len(pose.bones) + 1, context.temp_allocator)
	copy(next, pose.bones)
	next[len(pose.bones)] = Pose_Bone_Transform{bone = bone, transform = transform}
	return Pose_Value{bones = next}
}

// eval_pose_get reads the transform a pose drives on `bone`, or the rest
// (identity) transform when the pose leaves the bone undriven — the §16 §7
// "absent bones default to rest" rule a sparse-pose comparison rests on
// (Pose.get of an undriven bone == identity).
eval_pose_get :: proc(pose: Pose_Value, bone: string) -> Value {
	if transform, found := pose_bone_transform(pose.bones, bone); found {
		return transform
	}
	return transform_identity()
}

// eval_pose_blend per-bone interpolates two poses by `weight` (§16 §7): for every
// bone EITHER pose drives, the result drives the lerp from a's transform (a's
// driven value, or rest when a omits it) to b's (b's driven value, or rest when b
// omits it) — so a blend of disjoint bone sets keeps every bone, each
// interpolating against the other pose's rest. The driven-bone union is built in
// a deterministic order: a's bones in their order, then b's bones new to the
// result in theirs. At weight 0 every bone reads a's transform, at weight 1 b's.
eval_pose_blend :: proc(a, b: Pose_Value, weight: Fixed) -> Value {
	bones := make([dynamic]Pose_Bone_Transform, 0, len(a.bones) + len(b.bones), context.temp_allocator)
	for driven in a.bones {
		other, _ := pose_bone_transform(b.bones, driven.bone)
		append(&bones, Pose_Bone_Transform{
			bone      = driven.bone,
			transform = transform_blend(driven.transform, other, weight),
		})
	}
	for driven in b.bones {
		if _, already := pose_bone_transform(a.bones, driven.bone); already {
			continue
		}
		append(&bones, Pose_Bone_Transform{
			bone      = driven.bone,
			transform = transform_blend(transform_identity(), driven.transform, weight),
		})
	}
	return Pose_Value{bones = bones[:]}
}

// transform_blend interpolates two transforms: position and scale lerp
// component-wise, orientation slerps — the §16 §7 "lerp position, slerp rotation"
// rule. quat_slerp returns its endpoints bit-exactly, so a weight of 0 yields a
// and 1 yields b without recomputation.
transform_blend :: proc(a, b: Transform_Value, weight: Fixed) -> Transform_Value {
	return Transform_Value{
		pos   = vec3_lerp(a.pos, b.pos, weight),
		rot   = quat_slerp(a.rot, b.rot, weight),
		scale = vec3_lerp(a.scale, b.scale, weight),
	}
}

// vec3_lerp interpolates two vectors component-wise over the saturating kernel —
// each lane through fixed_lerp (spec §10: vector arithmetic is component-wise).
vec3_lerp :: proc(a, b: Vec3_Value, t: Fixed) -> Vec3_Value {
	return Vec3_Value{
		x = fixed_lerp(a.x, b.x, t),
		y = fixed_lerp(a.y, b.y, t),
		z = fixed_lerp(a.z, b.z, t),
	}
}

// eval_pose_layer composes two poses by override (§16 §7): the overlay's bones
// replace the base's, the base shows through elsewhere — overlay wins per bone.
// The result is the base's driven bones (each overwritten by the overlay where it
// drives the same bone) followed by the overlay's bones new to the base, in a
// deterministic order.
eval_pose_layer :: proc(base, overlay: Pose_Value) -> Value {
	bones := make([dynamic]Pose_Bone_Transform, 0, len(base.bones) + len(overlay.bones), context.temp_allocator)
	for driven in base.bones {
		if over, wins := pose_bone_transform(overlay.bones, driven.bone); wins {
			append(&bones, Pose_Bone_Transform{bone = driven.bone, transform = over})
		} else {
			append(&bones, driven)
		}
	}
	for driven in overlay.bones {
		if _, already := pose_bone_transform(base.bones, driven.bone); already {
			continue
		}
		append(&bones, driven)
	}
	return Pose_Value{bones = bones[:]}
}

// eval_pose_expr evaluates an expression expected to be a Pose value — the
// shared shape blend/layer read their pose arguments through. ok = false on a
// non-Pose value (a typecheck-rejected shape that never reaches a passing test).
eval_pose_expr :: proc(ctx: Eval_Ctx, env: ^Env, expr: Expr) -> (pose: Pose_Value, ok: bool) {
	value := eval_expr(ctx, env, expr) or_return
	return value.(Pose_Value)
}

// eval_bone_arg evaluates an argument expected to be a Bone variant and returns
// its variant name — the key a Pose drives a transform on. ok = false on a
// non-variant argument.
eval_bone_arg :: proc(ctx: Eval_Ctx, env: ^Env, expr: Expr) -> (bone: string, ok: bool) {
	value := eval_expr(ctx, env, expr) or_return
	variant, is_variant := value.(Enum_Value)
	if !is_variant {
		return "", false
	}
	return variant.variant, true
}

// find_user_behavior looks up a behavior by name — the §04 name.step receiver.
find_user_behavior :: proc(ast: Ast, name: string) -> (behavior: Behavior_Node, found: bool) {
	for decl in ast.behaviors {
		if decl.name == name {
			return decl, true
		}
	}
	return Behavior_Node{}, false
}

// eval_fixed_arg evaluates argument i of an expected-arity call and
// demands a Fixed — the shared shape of the scalar-surface builtins.
eval_fixed_arg :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr, i: int, arity: int) -> (f: Fixed, ok: bool) {
	if len(e.args) != arity {
		return Fixed(0), false
	}
	value := eval_expr(ctx, env, e.args[i]) or_return
	return value.(Fixed)
}
