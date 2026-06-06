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
	case ^With_Expr:
		return eval_with(ctx, env, e)
	case ^Match_Expr:
		return eval_match(ctx, env, e)
	case ^Lambda_Expr:
		return Lambda_Value{node = e, env = env}, true
	}
	return nil, false
}

eval_list :: proc(ctx: Eval_Ctx, env: ^Env, e: ^List_Expr) -> (value: Value, ok: bool) {
	elements := make([]Value, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		elements[i] = eval_expr(ctx, env, element) or_return
	}
	return List_Value{elements = elements}, true
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
	return nil, false
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
	}
	return env, false
}

eval_unary :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Unary_Expr) -> (value: Value, ok: bool) {
	if e.op.kind != .Minus {
		return nil, false
	}
	operand := eval_expr(ctx, env, e.operand) or_return
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
// (Goal.side, self.pos) or a Vec2/Vec3 component (v.x).
eval_field_access :: proc(receiver: Value, member: string) -> (value: Value, ok: bool) {
	#partial switch r in receiver {
	case Record_Value:
		return record_field_value(r.fields, member)
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
	case "fold":
		return eval_fold(ctx, env, e)
	case "first":
		return eval_first(ctx, env, e)
	}
	// A call to a user-declared top-level fn (advance, goal_side, add_goal):
	// resolve its body off the module and evaluate it against the arguments.
	if fn, declared := find_user_fn(ctx.ast, name.name); declared {
		args := eval_args(ctx, env, e.args) or_return
		return eval_user_fn(ctx, fn, args)
	}
	return nil, false
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
		}
	}
	receiver := eval_expr(ctx, env, callee.receiver) or_return
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
