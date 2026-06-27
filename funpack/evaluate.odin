package funpack

import "core:slice"
import "core:strings"

Env :: struct {
	bindings: map[string]Value,
	parent:   ^Env,
}

Eval_Ctx :: struct {
	ast:           Ast,
	env:           Type_Env,
	bindings:      Bindings,
	modules:       []Module_Eval,
	module:        string,
	visiting:      ^Const_Visit,
	query_indexes: []Index_Directive,
}

Const_Visit :: struct {
	active: map[string]bool,
}

Module_Eval :: struct {
	module:   string,
	ast:      Ast,
	env:      Type_Env,
	bindings: Bindings,
	modules:  []Module_Eval,
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
	return stage_evaluate_indexed(typed, nil, "")
}

stage_evaluate_indexed :: proc(typed: Typed_Ast, modules: []Module_Eval, module: string) -> Eval_Result {
	result := Eval_Result{}
	failures := make([dynamic]Assert_Failure, 0, 0, context.temp_allocator)
	visit := new(Const_Visit, context.temp_allocator)
	visit.active = make(map[string]bool, context.temp_allocator)
	ctx := Eval_Ctx {
		ast      = typed.ast,
		env      = typed.env,
		bindings = typed.bindings,
		modules  = modules,
		module   = module,
		visiting = visit,
	}
	for test in typed.ast.tests {
		env := new_env(nil)
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				if value, ok := eval_expr(ctx, env, node.value); ok {
					if node.is_tuple {
						bind_let_tuple_value(env, node.names, value)
					} else {
						env.bindings[node.name] = value
					}
				}
			case Assert_Node:
				if eval_assert(ctx, env, node) {
					result.passed += 1
				} else {
					result.failed += 1
					append(&failures, assert_failure(ctx, env, test.name, node))
				}
			case Return_Node, If_Node:
			}
		}
	}
	result.failures = failures[:]
	return result
}

eval_assert :: proc(ctx: Eval_Ctx, env: ^Env, node: Assert_Node) -> bool {
	value, ok := eval_expr(ctx, env, node.expr)
	if !ok {
		return false
	}
	passed, is_bool := value.(bool)
	return is_bool && passed
}

assert_failure :: proc(ctx: Eval_Ctx, env: ^Env, test_name: string, node: Assert_Node) -> Assert_Failure {
	line, _ := expr_span(node.expr)
	failure := Assert_Failure {
		test_name = test_name,
		line      = line,
		expr_text = expr_text(node.expr, context.temp_allocator),
	}
	if binary, is_binary := node.expr.(^Binary_Expr); is_binary {
		if binary.op.kind == .Eq_Eq || binary.op.kind == .Not_Eq {
			lhs, lhs_ok := eval_expr(ctx, env, binary.lhs)
			rhs, rhs_ok := eval_expr(ctx, env, binary.rhs)
			if lhs_ok && rhs_ok {
				failure.op = binary.op.text
				failure.lhs_display = value_display(lhs, context.temp_allocator)
				failure.rhs_display = value_display(rhs, context.temp_allocator)
				failure.has_operands = true
			}
		}
	}
	return failure
}

expr_text :: proc(expr: Expr, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt_expr(&b, expr, 0)
	return strings.to_string(b)
}

eval_expr :: proc(ctx: Eval_Ctx, env: ^Env, expr: Expr) -> (value: Value, ok: bool) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return e.value, true
	case ^Fixed_Lit_Expr:
		return e.bits, true
	case ^String_Lit_Expr:
		return e.text, true
	case ^Name_Expr:
		if e.name == "true" {
			return true, true
		}
		if e.name == "false" {
			return false, true
		}
		if bound, found := env_lookup(env, e.name); found {
			return bound, true
		}
		if constant, declared := eval_module_const(ctx, e.name); declared {
			return constant, true
		}
		if constant, is_const := eval_imported_const(ctx, e.name); is_const {
			return constant, true
		}
		if e.name == "pi" {
			return PI_FIXED, true
		}
		if e.name == "tau" {
			return TAU_FIXED, true
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
	case ^Stub_Expr:
		return eval_stub_hole(ctx, env, e.fallback, e.has_fallback)
	case ^All_Expr:
		return eval_all(ctx, e)
	}
	return nil, false
}

eval_all :: proc(ctx: Eval_Ctx, e: ^All_Expr) -> (value: Value, ok: bool) {
	_, declared := thing_by_name(ctx.ast, e.thing)
	if !declared {
		return nil, false
	}
	spawns, _, resolved := resolve_setup_values(ctx)
	if !resolved {
		return nil, false
	}
	rows := make([dynamic]Value, 0, len(spawns), context.temp_allocator)
	for spawn in spawns {
		if spawn.type_name != e.thing {
			continue
		}
		append(&rows, spawn.record)
	}
	return List_Value{elements = rows[:]}, true
}

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

eval_tuple :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Tuple_Expr) -> (value: Value, ok: bool) {
	elements := make([]Value, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		elements[i] = eval_expr(ctx, env, element) or_return
	}
	return Tuple_Value{elements = elements}, true
}

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

eval_module_const :: proc(ctx: Eval_Ctx, name: string) -> (value: Value, declared: bool) {
	if term, found := env_term_name(ctx.env, name); !found || term.kind != .Const {
		return nil, false
	}
	for decl in ctx.ast.lets {
		if decl.name == name {
			key := const_cycle_key(ctx.module, name)
			if ctx.visiting != nil && ctx.visiting.active[key] {
				return nil, false
			}
			if ctx.visiting != nil {
				ctx.visiting.active[key] = true
			}
			v, ok := eval_expr(ctx, new_env(nil), decl.value)
			if ctx.visiting != nil {
				delete_key(&ctx.visiting.active, key)
			}
			return v, ok
		}
	}
	return nil, false
}

const_cycle_key :: proc(module: string, name: string) -> string {
	return strings.concatenate({module, ".", name}, context.temp_allocator)
}

eval_user_fn :: proc(ctx: Eval_Ctx, fn: Fn_Node, args: []Value) -> (value: Value, ok: bool) {
	if len(args) != len(fn.params) {
		return nil, false
	}
	frame := new_env(nil)
	for param, i in fn.params {
		frame.bindings[param.name] = args[i]
	}
	if fn.holed {
		return eval_stub_hole(ctx, frame, fn.fallback, fn.has_fallback)
	}
	return eval_statements(ctx, frame, fn.body)
}

eval_stub_hole :: proc(ctx: Eval_Ctx, frame: ^Env, fallback: Expr, has_fallback: bool) -> (value: Value, ok: bool) {
	if has_fallback {
		return eval_expr(ctx, frame, fallback)
	}
	return nil, false
}

bind_let_tuple_value :: proc(frame: ^Env, names: []string, v: Value) -> (ok: bool) {
	tuple, is_tuple := v.(Tuple_Value)
	if !is_tuple || len(tuple.elements) != len(names) {
		return false
	}
	for name, i in names {
		frame.bindings[name] = tuple.elements[i]
	}
	return true
}

eval_statements :: proc(ctx: Eval_Ctx, frame: ^Env, body: []Statement) -> (value: Value, ok: bool) {
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			v := eval_expr(ctx, frame, node.value) or_return
			if node.is_tuple {
				bind_let_tuple_value(frame, node.names, v) or_return
			} else {
				frame.bindings[node.name] = v
			}
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
		}
	}
	return nil, false
}

eval_variant :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Variant_Expr) -> (value: Value, ok: bool) {
	if e.type_name == "Option" {
		return eval_option_variant(ctx, env, e)
	}
	if e.has_fields {
		return eval_struct_variant(ctx, env, e)
	}
	if e.has_payload {
		if len(e.payload) != 1 {
			return nil, false
		}
		inner := eval_expr(ctx, env, e.payload[0]) or_return
		boxed := new(Value, context.temp_allocator)
		boxed^ = inner
		return Enum_Value{type_name = e.type_name, variant = e.variant, payload = boxed}, true
	}
	return Enum_Value{type_name = e.type_name, variant = e.variant}, true
}

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

eval_struct_variant :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Variant_Expr) -> (value: Value, ok: bool) {
	fields := make([]Record_Field_Value, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		fields[i] = Record_Field_Value{name = field.name, value = v}
	}
	return Record_Value{type_name = e.type_name, variant = e.variant, fields = fields}, true
}

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
	if e.type_name == "Path" {
		return eval_asset_handle_literal(ctx, env, e)
	}
	if record, declared := ctx.env.records[e.type_name]; declared {
		return eval_user_record(ctx, env, e, record)
	}
	if crossmod_value, crossmod_ok, is_crossmod := eval_module_record(ctx, env, e); is_crossmod {
		return crossmod_value, crossmod_ok
	}
	if _, _, is_handle := surface_engine_record(e.type_name); is_handle && is_asset_handle_name(e.type_name) {
		return eval_asset_handle_literal(ctx, env, e)
	}
	if _, fields, is_engine := surface_engine_record(e.type_name); is_engine {
		return eval_engine_record(ctx, env, e, fields)
	}
	if schema, is_structural := surface_structural_record(ctx.bindings, e.type_name); is_structural {
		return eval_structural_record(ctx, env, e, schema)
	}
	return nil, false
}

eval_structural_record :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr, schema: Record_Schema) -> (value: Value, ok: bool) {
	fields := make([]Record_Field_Value, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		fields[i] = Record_Field_Value{name = field.name, value = v}
	}
	return Record_Value{type_name = schema.type_name, fields = fields}, true
}

is_asset_handle_name :: proc(name: string) -> bool {
	switch name {
	case "MeshHandle", "TextureHandle", "SoundHandle", "AtlasHandle", "TilesetHandle", "TilemapHandle":
		return true
	}
	return false
}

eval_asset_handle_literal :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr) -> (value: Value, ok: bool) {
	fields := make([]Record_Field_Value, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		fields[i] = Record_Field_Value{name = field.name, value = v}
	}
	return Record_Value{type_name = e.type_name, fields = fields}, true
}

eval_engine_record :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr, schema: []Surface_Field) -> (value: Value, ok: bool) {
	fields := make([dynamic]Record_Field_Value, 0, len(schema), context.temp_allocator)
	for field in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		append(&fields, Record_Field_Value{name = field.name, value = v})
	}
	for slot in schema {
		if !slot.has_default {
			continue
		}
		if _, present := record_field_value(fields[:], slot.name); present {
			continue
		}
		append(&fields, Record_Field_Value{name = slot.name, value = slot.default})
	}
	return Record_Value{type_name = e.type_name, fields = fields[:]}, true
}

eval_user_record :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr, schema: Record_Schema) -> (value: Value, ok: bool) {
	fields := make([dynamic]Record_Field_Value, 0, len(schema.fields), context.temp_allocator)
	for field in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		append(&fields, Record_Field_Value{name = field.name, value = v})
	}
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

eval_module_record :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr) -> (value: Value, ok: bool, is_crossmod: bool) {
	binding, bound := ctx.bindings.names[e.type_name]
	if !bound || binding.kind != .Type_Name {
		return nil, false, false
	}
	owner, found := module_eval_lookup(ctx.modules, binding.module)
	if !found {
		return nil, false, false
	}
	if _, declared := owner.env.records[e.type_name]; !declared {
		return nil, false, false
	}
	owner_ctx := Eval_Ctx {
		ast      = owner.ast,
		env      = owner.env,
		bindings = owner.bindings,
		modules  = owner.modules,
		module   = binding.module,
		visiting = ctx.visiting,
	}

	fields := make([dynamic]Record_Field_Value, 0, 4, context.temp_allocator)
	for field in e.fields {
		v, field_ok := eval_expr(ctx, env, field.value)
		if !field_ok {
			return nil, false, true
		}
		append(&fields, Record_Field_Value{name = field.name, value = v})
	}
	owner_env := new_env(nil)
	for decl in record_decl_fields(owner.ast, e.type_name) {
		if !decl.has_default {
			continue
		}
		if _, present := record_field_value(fields[:], decl.name); present {
			continue
		}
		v, default_ok := eval_expr(owner_ctx, owner_env, decl.default)
		if !default_ok {
			return nil, false, true
		}
		append(&fields, Record_Field_Value{name = decl.name, value = v})
	}
	return Record_Value{type_name = e.type_name, fields = fields[:]}, true, true
}

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

record_replace_field :: proc(fields: []Record_Field_Value, name: string, value: Value) -> (replaced: bool) {
	for &field in fields {
		if field.name == name {
			field.value = value
			return true
		}
	}
	return false
}

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
		if len(pattern.elements) != 1 {
			return env, false
		}
		payload: Value
		if option, is_option := scrutinee.(Option_Value); is_option {
			if !option.is_some || pattern.variant != "Some" {
				return env, false
			}
			payload = option.payload^
		} else if variant, is_variant := scrutinee.(Enum_Value); is_variant {
			if variant.type_name != pattern.type_name || variant.variant != pattern.variant || variant.payload == nil {
				return env, false
			}
			payload = variant.payload^
		} else {
			return env, false
		}
		return match_pattern(pattern.elements[0], payload, env)
	case .Struct_Binds:
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
		if len(pattern.binders) != 1 {
			return env, false
		}
		child := new_env(env)
		child.bindings[pattern.binders[0]] = scrutinee
		return child, true
	case .Tuple:
		return match_tuple_pattern(pattern, scrutinee, env)
	}
	return env, false
}

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
	if s, is_fixed := rhs.(Fixed); is_fixed {
		#partial switch op {
		case .Star:
			return vec2_scale(l, s), true
		case .Slash:
			return vec2_div(l, s), true
		}
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

eval_member :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Member_Expr) -> (value: Value, ok: bool) {
	if recv, is_name := e.receiver.(^Name_Expr); is_name {
		if _, bound := env_lookup(env, recv.name); !bound {
			if const_value, is_const := eval_module_qualified_const(ctx, recv.name, e.member); is_const {
				return const_value, true
			}
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

eval_module_qualified_const :: proc(ctx: Eval_Ctx, handle: string, member: string) -> (value: Value, is_const: bool) {
	binding, bound := ctx.bindings.names[handle]
	if !bound || binding.kind != .Module {
		return nil, false
	}
	owner, found := module_eval_lookup(ctx.modules, binding.module)
	if !found {
		return nil, false
	}
	owner_ctx := Eval_Ctx {
		ast      = owner.ast,
		env      = owner.env,
		bindings = owner.bindings,
		modules  = owner.modules,
		module   = binding.module,
		visiting = ctx.visiting,
	}
	return eval_module_const(owner_ctx, member)
}

eval_imported_const :: proc(ctx: Eval_Ctx, name: string) -> (value: Value, is_const: bool) {
	binding, bound := ctx.bindings.names[name]
	if !bound || binding.kind != .Value || binding.module == ctx.module {
		return nil, false
	}
	owner, found := module_eval_lookup(ctx.modules, binding.module)
	if !found {
		return nil, false
	}
	owner_ctx := Eval_Ctx {
		ast      = owner.ast,
		env      = owner.env,
		bindings = owner.bindings,
		modules  = owner.modules,
		module   = binding.module,
		visiting = ctx.visiting,
	}
	return eval_module_const(owner_ctx, name)
}

module_eval_lookup :: proc(modules: []Module_Eval, module: string) -> (entry: Module_Eval, found: bool) {
	for candidate in modules {
		if candidate.module == module {
			return candidate, true
		}
	}
	return Module_Eval{}, false
}

eval_field_access :: proc(receiver: Value, member: string) -> (value: Value, ok: bool) {
	#partial switch r in receiver {
	case Record_Value:
		return record_field_value(r.fields, member)
	case Time_Value:
		switch member {
		case "dt":
			return r.dt, true
		case "t":
			return r.t, true
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
	case "to_int", "trunc":
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
		angle := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return transform_rot_x(angle), true
	case "up":
		d := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return transform_up(d), true
	case "max":
		return eval_max(ctx, env, e)
	case "compare":
		return eval_compare(ctx, env, e)
	case "fold":
		return eval_fold(ctx, env, e)
	case "first":
		return eval_first(ctx, env, e)
	case "find":
		return eval_find(ctx, env, e)
	case "or_else":
		return eval_or_else(ctx, env, e)
	case "is_some":
		return eval_is_some(ctx, env, e)
	case "last":
		return eval_last(ctx, env, e)
	case "neighbors":
		return eval_neighbors(ctx, env, e)
	case "in_bounds":
		return eval_in_bounds(ctx, env, e)
	case "within":
		return eval_within(ctx, env, e)
	case "nearest_first":
		return eval_nearest_first(ctx, env, e)
	case "prepend":
		return eval_prepend(ctx, env, e)
	case "append":
		return eval_append(ctx, env, e)
	case "reverse":
		return eval_reverse(ctx, env, e)
	case "init":
		return eval_init(ctx, env, e)
	case "contains":
		return eval_contains(ctx, env, e)
	case "concat":
		return eval_concat(ctx, env, e)
	case "is_empty":
		return eval_is_empty(ctx, env, e)
	case "len":
		return eval_len(ctx, env, e)
	case "get":
		return eval_get(ctx, env, e)
	case "empty":
		return eval_map_empty(ctx, env, e)
	case "has":
		return eval_map_has(ctx, env, e)
	case "set":
		return eval_map_set(ctx, env, e)
	case "remove":
		return eval_map_remove(ctx, env, e)
	case "keys":
		return eval_map_keys(ctx, env, e)
	case "values":
		return eval_map_values(ctx, env, e)
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
	case "seed":
		return eval_rand_seed(ctx, env, e)
	case "next":
		return eval_rand_next(ctx, env, e)
	case "range":
		return eval_rand_range(ctx, env, e)
	case "chance":
		return eval_rand_chance(ctx, env, e)
	case "split":
		return eval_rand_split(ctx, env, e)
	case "pick":
		return eval_rand_pick(ctx, env, e)
	case "Despawn":
		if len(e.args) != 0 {
			return nil, false
		}
		return Record_Value{type_name = "Despawn"}, true
	case "Spawn":
		if len(e.args) != 1 {
			return nil, false
		}
		thing := eval_expr(ctx, env, e.args[0]) or_return
		fields := make([]Record_Field_Value, 1, context.temp_allocator)
		fields[0] = Record_Field_Value{name = "thing", value = thing}
		return Record_Value{type_name = "Spawn", fields = fields}, true
	}
	if fn, indexes, declared := find_user_callable(ctx.ast, name.name); declared {
		args := eval_args(ctx, env, e.args) or_return
		body_ctx := ctx
		body_ctx.query_indexes = indexes
		return eval_user_fn(body_ctx, fn, args)
	}
	if owner_ctx, fn, found := find_imported_fn(ctx, name.name); found {
		args := eval_args(ctx, env, e.args) or_return
		return eval_user_fn(owner_ctx, fn, args)
	}
	return nil, false
}

find_imported_fn :: proc(ctx: Eval_Ctx, name: string) -> (owner_ctx: Eval_Ctx, fn: Fn_Node, found: bool) {
	binding, bound := ctx.bindings.names[name]
	if !bound || binding.kind != .Func {
		return
	}
	owner, has_owner := module_eval_lookup(ctx.modules, binding.module)
	if !has_owner {
		return
	}
	user_fn, indexes, declared := find_user_callable(owner.ast, name)
	if !declared {
		return
	}
	owner_ctx = Eval_Ctx {
		ast      = owner.ast,
		env      = owner.env,
		bindings = owner.bindings,
		modules  = owner.modules,
		module   = binding.module,
		visiting = ctx.visiting,
	}
	owner_ctx.query_indexes = indexes
	return owner_ctx, user_fn, true
}

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

eval_args :: proc(ctx: Eval_Ctx, env: ^Env, args: []Expr) -> (values: []Value, ok: bool) {
	out := make([]Value, len(args), context.temp_allocator)
	for arg, i in args {
		out[i] = eval_expr(ctx, env, arg) or_return
	}
	return out, true
}

find_user_fn :: proc(ast: Ast, name: string) -> (fn: Fn_Node, found: bool) {
	for decl in ast.fns {
		if decl.name == name {
			return decl, true
		}
	}
	return Fn_Node{}, false
}

find_user_callable :: proc(ast: Ast, name: string) -> (fn: Fn_Node, indexes: []Index_Directive, found: bool) {
	if declared_fn, declared := find_user_fn(ast, name); declared {
		return declared_fn, nil, true
	}
	for decl in ast.queries {
		if decl.name == name {
			return query_as_fn(decl), decl.indexes, true
		}
	}
	return Fn_Node{}, nil, false
}

eval_within :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 3) or_return
	origin := eval_expr(ctx, env, e.args[1]) or_return
	radius_value := eval_expr(ctx, env, e.args[2]) or_return
	radius, is_fixed := radius_value.(Fixed)
	if !is_fixed {
		return nil, false
	}
	out := make([dynamic]Value, 0, len(elements), context.temp_allocator)
	for element in elements {
		distance := spatial_element_distance(ctx, element, origin) or_return
		if distance <= radius {
			append(&out, element)
		}
	}
	return List_Value{elements = out[:]}, true
}

eval_nearest_first :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	origin := eval_expr(ctx, env, e.args[1]) or_return
	keyed := make([]Spatial_Keyed_Row, len(elements), context.temp_allocator)
	for element, i in elements {
		distance := spatial_element_distance(ctx, element, origin) or_return
		keyed[i] = Spatial_Keyed_Row{row = element, distance = distance}
	}
	slice.stable_sort_by(keyed, spatial_keyed_row_less)
	out := make([]Value, len(keyed), context.temp_allocator)
	for entry, i in keyed {
		out[i] = entry.row
	}
	return List_Value{elements = out}, true
}

Spatial_Keyed_Row :: struct {
	row:      Value,
	distance: Fixed,
}

spatial_keyed_row_less :: proc(a, b: Spatial_Keyed_Row) -> bool {
	return a.distance < b.distance
}

spatial_element_distance :: proc(ctx: Eval_Ctx, element: Value, origin: Value) -> (distance: Fixed, ok: bool) {
	record, is_record := element.(Record_Value)
	if !is_record {
		return 0, false
	}
	field := spatial_field_for(ctx, record.type_name) or_return
	at := record_field_value(record.fields, field) or_return
	#partial switch from in origin {
	case Vec2_Value:
		at2, is_vec2 := at.(Vec2_Value)
		if !is_vec2 {
			return 0, false
		}
		return vec2_length(vec2_sub(at2, from)), true
	case Vec3_Value:
		at3, is_vec3 := at.(Vec3_Value)
		if !is_vec3 {
			return 0, false
		}
		return vec3_length(vec3_sub(at3, from)), true
	}
	return 0, false
}

spatial_field_for :: proc(ctx: Eval_Ctx, thing: string) -> (field: string, ok: bool) {
	found := false
	for directive in ctx.query_indexes {
		if directive.kind != .Spatial || directive.thing != thing {
			continue
		}
		if found {
			return "", false
		}
		field = directive.field
		found = true
	}
	return field, found
}

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

eval_find :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	list := source.(List_Value) or_return
	for element in list.elements {
		verdict := apply_combinator(ctx, env, e.args[1], {element}) or_return
		accepted, is_bool := verdict.(bool)
		if is_bool && accepted {
			return some_value(element), true
		}
	}
	return Option_Value{is_some = false, payload = nil}, true
}

eval_or_else :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	option := eval_expr(ctx, env, e.args[0]) or_return
	boxed, is_option := option.(Option_Value)
	if !is_option {
		return nil, false
	}
	if boxed.is_some {
		return boxed.payload^, true
	}
	return eval_expr(ctx, env, e.args[1])
}

eval_is_some :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	option := eval_expr(ctx, env, e.args[0]) or_return
	boxed, is_option := option.(Option_Value)
	if !is_option {
		return nil, false
	}
	return boxed.is_some, true
}

eval_last :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 1) or_return
	if len(elements) == 0 {
		return Option_Value{is_some = false, payload = nil}, true
	}
	return some_value(elements[len(elements) - 1]), true
}

eval_neighbors :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	arg := eval_expr(ctx, env, e.args[0]) or_return
	x, y, type_name, is_cell := tilemap_cell_coords(arg)
	if !is_cell {
		return nil, false
	}
	offsets := [4][2]i64{{0, -1}, {-1, 0}, {1, 0}, {0, 1}}
	elements := make([]Value, 4, context.temp_allocator)
	for offset, i in offsets {
		elements[i] = structural_cell_value(type_name, x + offset[0], y + offset[1])
	}
	return List_Value{elements = elements}, true
}

eval_in_bounds :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	cell := eval_expr(ctx, env, e.args[0]) or_return
	size := eval_expr(ctx, env, e.args[1]) or_return
	x, y, _, cell_ok := tilemap_cell_coords(cell)
	sx, sy, _, size_ok := tilemap_cell_coords(size)
	if !cell_ok || !size_ok {
		return nil, false
	}
	return x >= 0 && x < sx && y >= 0 && y < sy, true
}

structural_cell_value :: proc(type_name: string, x, y: i64) -> Value {
	fields := make([]Record_Field_Value, 2, context.temp_allocator)
	fields[0] = Record_Field_Value{name = "x", value = x}
	fields[1] = Record_Field_Value{name = "y", value = y}
	return Record_Value{type_name = type_name, fields = fields}
}

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

// Evaluator twin of runtime/interp_call.odin's rng_draw_tuple — keep the (value, next) tuple shape mirrored or gameplay diverges.
rand_draw_tuple :: proc(value: Value, advanced: Value) -> Value {
	elements := make([]Value, 2, context.temp_allocator)
	elements[0] = value
	elements[1] = advanced
	return Tuple_Value{elements = elements}
}

eval_rand_seed :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	arg := eval_expr(ctx, env, e.args[0]) or_return
	n := arg.(i64) or_return
	return rand_seed(n), true
}

eval_rand_next :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	recv := eval_expr(ctx, env, e.args[0]) or_return
	rng := recv.(Rng) or_return
	drawn, advanced := rand_next_fixed(rng)
	return rand_draw_tuple(drawn, advanced), true
}

eval_rand_range :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 3 {
		return nil, false
	}
	recv := eval_expr(ctx, env, e.args[0]) or_return
	rng := recv.(Rng) or_return
	lo_val := eval_expr(ctx, env, e.args[1]) or_return
	hi_val := eval_expr(ctx, env, e.args[2]) or_return
	lo := lo_val.(i64) or_return
	hi := hi_val.(i64) or_return
	drawn, advanced := rand_range(rng, lo, hi)
	return rand_draw_tuple(drawn, advanced), true
}

eval_rand_chance :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	recv := eval_expr(ctx, env, e.args[0]) or_return
	rng := recv.(Rng) or_return
	p := eval_fixed_arg(ctx, env, e, 1, 2) or_return
	drawn, advanced := rand_chance(rng, p)
	return rand_draw_tuple(drawn, advanced), true
}

eval_rand_split :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	recv := eval_expr(ctx, env, e.args[0]) or_return
	rng := recv.(Rng) or_return
	a, b := rand_split(rng)
	return rand_draw_tuple(a, b), true
}

// Picked position is bit-identical to runtime/interp_call.odin's builtin_pick (shared rand_bounded) — mirror any change there.
eval_rand_pick :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	rng_val := eval_expr(ctx, env, e.args[0]) or_return
	rng := rng_val.(Rng) or_return
	elements := eval_list_arg(ctx, env, e, 1, 2) or_return
	if len(elements) == 0 {
		_, advanced := rand_next(rng)
		return rand_draw_tuple(Option_Value{is_some = false, payload = nil}, advanced), true
	}
	index, advanced := rand_bounded(rng, len(elements))
	boxed := new(Value, context.temp_allocator)
	boxed^ = elements[index]
	return rand_draw_tuple(Option_Value{is_some = true, payload = boxed}, advanced), true
}

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

eval_append :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	elem := eval_expr(ctx, env, e.args[1]) or_return
	out := make([]Value, len(elements) + 1, context.temp_allocator)
	for element, i in elements {
		out[i] = element
	}
	out[len(elements)] = elem
	return List_Value{elements = out}, true
}

eval_reverse :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 1) or_return
	out := make([]Value, len(elements), context.temp_allocator)
	for element, i in elements {
		out[len(elements) - 1 - i] = element
	}
	return List_Value{elements = out}, true
}

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

eval_is_empty :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 1) or_return
	return len(elements) == 0, true
}

eval_len :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	if m, is_map := source.(Map_Value); is_map {
		return i64(len(m.entries)), true
	}
	list, is_list := source.(List_Value)
	if !is_list {
		return nil, false
	}
	return i64(len(list.elements)), true
}

eval_get :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	if m, is_map := source.(Map_Value); is_map {
		key := eval_expr(ctx, env, e.args[1]) or_return
		for entry in m.entries {
			if value_equal(entry.key, key) {
				return some_value(entry.value), true
			}
		}
		return Option_Value{is_some = false, payload = nil}, true
	}
	list, is_list := source.(List_Value)
	if !is_list {
		return nil, false
	}
	index_value := eval_expr(ctx, env, e.args[1]) or_return
	i, is_int := index_value.(i64)
	if !is_int {
		return nil, false
	}
	if i < 0 || int(i) >= len(list.elements) {
		return Option_Value{is_some = false, payload = nil}, true
	}
	return some_value(list.elements[i]), true
}

eval_map_empty :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 0 {
		return nil, false
	}
	return Map_Value{}, true
}

eval_map_has :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	key := eval_expr(ctx, env, e.args[1]) or_return
	for entry in m.entries {
		if value_equal(entry.key, key) {
			return true, true
		}
	}
	return false, true
}

eval_map_set :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 3 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	key := eval_expr(ctx, env, e.args[1]) or_return
	val := eval_expr(ctx, env, e.args[2]) or_return
	for entry, i in m.entries {
		if value_equal(entry.key, key) {
			out := make([]Map_Entry, len(m.entries), context.temp_allocator)
			copy(out, m.entries)
			out[i] = Map_Entry{key = entry.key, value = val}
			return Map_Value{entries = out}, true
		}
	}
	out := make([]Map_Entry, len(m.entries) + 1, context.temp_allocator)
	copy(out, m.entries)
	out[len(m.entries)] = Map_Entry{key = key, value = val}
	return Map_Value{entries = out}, true
}

eval_map_remove :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	key := eval_expr(ctx, env, e.args[1]) or_return
	idx := -1
	for entry, i in m.entries {
		if value_equal(entry.key, key) {
			idx = i
			break
		}
	}
	if idx < 0 {
		return m, true
	}
	out := make([]Map_Entry, len(m.entries) - 1, context.temp_allocator)
	copy(out[:idx], m.entries[:idx])
	copy(out[idx:], m.entries[idx + 1:])
	return Map_Value{entries = out}, true
}

eval_map_keys :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	out := make([]Value, len(m.entries), context.temp_allocator)
	for entry, i in m.entries {
		out[i] = entry.key
	}
	return List_Value{elements = out}, true
}

eval_map_values :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	m, is_map := source.(Map_Value)
	if !is_map {
		return nil, false
	}
	out := make([]Value, len(m.entries), context.temp_allocator)
	for entry, i in m.entries {
		out[i] = entry.value
	}
	return List_Value{elements = out}, true
}

eval_max :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	a := eval_expr(ctx, env, e.args[0]) or_return
	b := eval_expr(ctx, env, e.args[1]) or_return
	if af, a_fixed := a.(Fixed); a_fixed {
		bf, b_fixed := b.(Fixed)
		if !b_fixed {
			return nil, false
		}
		return (i64(af) >= i64(bf)) ? af : bf, true
	}
	if ai, a_int := a.(i64); a_int {
		bi, b_int := b.(i64)
		if !b_int {
			return nil, false
		}
		return (ai >= bi) ? ai : bi, true
	}
	return nil, false
}

eval_compare :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	a := eval_expr(ctx, env, e.args[0]) or_return
	b := eval_expr(ctx, env, e.args[1]) or_return
	if af, a_fixed := a.(Fixed); a_fixed {
		bf, b_fixed := b.(Fixed)
		if !b_fixed {
			return nil, false
		}
		return ordering_value(i64(af), i64(bf)), true
	}
	if ai, a_int := a.(i64); a_int {
		bi, b_int := b.(i64)
		if !b_int {
			return nil, false
		}
		return ordering_value(ai, bi), true
	}
	return nil, false
}

ordering_value :: proc(l, r: i64) -> Value {
	variant := "Equal"
	if l < r {
		variant = "Less"
	} else if l > r {
		variant = "Greater"
	}
	return Enum_Value{type_name = "Ordering", variant = variant}
}

eval_map :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	out := make([]Value, len(elements), context.temp_allocator)
	for element, i in elements {
		out[i] = apply_combinator(ctx, env, e.args[1], {element}) or_return
	}
	return List_Value{elements = out}, true
}

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

eval_grid_cells :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) == 1 {
		size_val := eval_expr(ctx, env, e.args[0]) or_return
		size, is_record := size_val.(Record_Value)
		if !is_record {
			return nil, false
		}
		w_val := record_field_value(size.fields, "x") or_return
		h_val := record_field_value(size.fields, "y") or_return
		w, w_is_int := w_val.(i64)
		h, h_is_int := h_val.(i64)
		if !w_is_int || !h_is_int {
			return nil, false
		}
		count := (w > 0 && h > 0) ? int(w) * int(h) : 0
		out := make([]Value, count, context.temp_allocator)
		idx := 0
		for y in 0 ..< h {
			for x in 0 ..< w {
				fields := make([]Record_Field_Value, 2, context.temp_allocator)
				fields[0] = Record_Field_Value{name = "x", value = x}
				fields[1] = Record_Field_Value{name = "y", value = y}
				out[idx] = Record_Value{type_name = size.type_name, fields = fields}
				idx += 1
			}
		}
		return List_Value{elements = out}, true
	}
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

some_value :: proc(inner: Value) -> Value {
	boxed := new(Value, context.temp_allocator)
	boxed^ = inner
	return Option_Value{is_some = true, payload = boxed}
}

apply_combinator :: proc(ctx: Eval_Ctx, env: ^Env, arg: Expr, args: []Value) -> (value: Value, ok: bool) {
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		return apply_lambda(ctx, Lambda_Value{node = lambda, env = env}, args)
	}
	if name, is_name := arg.(^Name_Expr); is_name {
		if fn, indexes, declared := find_user_callable(ctx.ast, name.name); declared {
			body_ctx := ctx
			body_ctx.query_indexes = indexes
			return eval_user_fn(body_ctx, fn, args)
		}
		if owner_ctx, fn, found := find_imported_fn(ctx, name.name); found {
			return eval_user_fn(owner_ctx, fn, args)
		}
	}
	return nil, false
}

eval_method_call :: proc(ctx: Eval_Ctx, env: ^Env, callee: ^Member_Expr, args: []Expr) -> (value: Value, ok: bool) {
	if recv, is_name := callee.receiver.(^Name_Expr); is_name {
		if _, bound := env_lookup(env, recv.name); !bound {
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
			if recv.name == "Map" && callee.member == "empty" {
				if len(args) != 0 {
					return nil, false
				}
				return Map_Value{}, true
			}
			if audio, is_audio := eval_audio_constructor(ctx, env, recv.name, callee.member, args); is_audio {
				return audio, true
			}
			if builder, is_builder := eval_resource_builder(ctx, env, recv.name, callee.member, args); is_builder {
				return builder, true
			}
		}
	}
	receiver := eval_expr(ctx, env, callee.receiver) or_return
	if ufcs, is_ufcs := eval_ufcs_method(ctx, env, receiver, callee.member, args); is_ufcs {
		return ufcs, true
	}
	if record, is_record := receiver.(Record_Value); is_record {
		if audio, is_audio := eval_audio_adder(ctx, env, record, callee.member, args); is_audio {
			return audio, true
		}
		if record.type_name == "Path" && callee.member == "advance" {
			return eval_path_advance(ctx, env, record, args)
		}
		if record.type_name == "Body" && callee.member == "apply_impulse" {
			return eval_body_apply_impulse(ctx, env, record, args)
		}
	}
	if nav, is_nav := receiver.(Nav_Value); is_nav {
		return eval_nav_method(ctx, env, nav, callee.member, args)
	}
	if list, is_list := receiver.(List_Value); is_list {
		switch callee.member {
		case "count":
			return eval_view_count(ctx, env, list, args)
		case "at":
			return eval_view_at(ctx, env, list, args)
		case "ref":
			return eval_view_ref(ctx, env, args)
		case "resolve":
			return eval_view_resolve(ctx, env, list, args)
		}
	}
	if input, is_input := receiver.(Input_Value); is_input {
		return eval_input_method(ctx, env, input, callee.member, args)
	}
	if tilemap, is_tilemap := receiver.(Tilemap_Value); is_tilemap {
		return eval_tilemap_method(ctx, env, tilemap, callee.member, args)
	}
	if pose, is_pose := receiver.(Pose_Value); is_pose {
		return eval_pose_method(ctx, env, pose, callee.member, args)
	}
	if q, is_quat := receiver.(Quat_Value); is_quat {
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
	}
	if is_stdlib_free_fn(callee.member) {
		return eval_call(ctx, env, stdlib_ufcs_call(callee, args, callee.line, callee.col))
	}
	return nil, false
}

eval_ufcs_method :: proc(ctx: Eval_Ctx, env: ^Env, receiver: Value, member: string, args: []Expr) -> (value: Value, is_ufcs: bool) {
	fn, declared := find_user_fn(ctx.ast, member)
	if !declared || len(fn.params) == 0 {
		return nil, false
	}
	tail, tail_ok := eval_args(ctx, env, args)
	if !tail_ok {
		return nil, false
	}
	values := make([]Value, len(tail) + 1, context.temp_allocator)
	values[0] = receiver
	copy(values[1:], tail)
	result, ok := eval_user_fn(ctx, fn, values)
	return result, ok
}

eval_audio_constructor :: proc(ctx: Eval_Ctx, env: ^Env, type_name, member: string, args: []Expr) -> (value: Value, is_audio: bool) {
	switch type_name {
	case "Sound":
		switch member {
		case "sfx":
			if len(args) != 1 {
				return nil, false
			}
			clip, clip_ok := eval_expr(ctx, env, args[0])
			if !clip_ok {
				return nil, false
			}
			return sound_record(clip, none_value()), true
		case "sfx_at":
			if len(args) != 2 {
				return nil, false
			}
			clip, clip_ok := eval_expr(ctx, env, args[0])
			pos, pos_ok := eval_expr(ctx, env, args[1])
			if !clip_ok || !pos_ok {
				return nil, false
			}
			return sound_record(clip, some_value(pos)), true
		}
	case "Audio":
		if member == "track" && len(args) == 2 {
			key, key_ok := eval_expr(ctx, env, args[0])
			clip, clip_ok := eval_expr(ctx, env, args[1])
			if !key_ok || !clip_ok {
				return nil, false
			}
			return audio_record(key, clip), true
		}
	}
	return nil, false
}

sound_record :: proc(clip: Value, at: Value) -> Value {
	fields := make([]Record_Field_Value, 5, context.temp_allocator)
	fields[0] = Record_Field_Value{name = "clip", value = clip}
	fields[1] = Record_Field_Value{name = "gain", value = FIXED_ONE}
	fields[2] = Record_Field_Value{name = "pitch", value = FIXED_ONE}
	fields[3] = Record_Field_Value{name = "bus", value = bus_variant("Sfx")}
	fields[4] = Record_Field_Value{name = "at", value = at}
	return Record_Value{type_name = "Sound", fields = fields}
}

audio_record :: proc(key: Value, clip: Value) -> Value {
	fields := make([]Record_Field_Value, 6, context.temp_allocator)
	fields[0] = Record_Field_Value{name = "key", value = key}
	fields[1] = Record_Field_Value{name = "clip", value = clip}
	fields[2] = Record_Field_Value{name = "gain", value = FIXED_ONE}
	fields[3] = Record_Field_Value{name = "pitch", value = FIXED_ONE}
	fields[4] = Record_Field_Value{name = "bus", value = bus_variant("Music")}
	fields[5] = Record_Field_Value{name = "at", value = none_value()}
	return Record_Value{type_name = "Audio", fields = fields}
}

bus_variant :: proc(variant: string) -> Value {
	return Enum_Value{type_name = "Bus", variant = variant}
}

none_value :: proc() -> Value {
	return Option_Value{is_some = false, payload = nil}
}

settings_defaults :: proc() -> Value {
	access := engine_record_from_defaults("AccessOpts")
	settings_fields := make([]Record_Field_Value, 1, context.temp_allocator)
	settings_fields[0] = Record_Field_Value{name = "access", value = access}
	return Record_Value{type_name = "Settings", fields = settings_fields}
}

engine_record_from_defaults :: proc(type_name: string) -> Value {
	_, schema, found := surface_engine_record(type_name)
	if !found {
		return Record_Value{type_name = type_name}
	}
	fields := make([dynamic]Record_Field_Value, 0, len(schema), context.temp_allocator)
	for slot in schema {
		if !slot.has_default {
			continue
		}
		append(&fields, Record_Field_Value{name = slot.name, value = slot.default})
	}
	return Record_Value{type_name = type_name, fields = fields[:]}
}

eval_body_apply_impulse :: proc(ctx: Eval_Ctx, env: ^Env, body: Record_Value, args: []Expr) -> (value: Value, ok: bool) {
	if len(args) != 1 {
		return nil, false
	}
	arg := eval_expr(ctx, env, args[0]) or_return
	push, is_vec2 := arg.(Vec2_Value)
	if !is_vec2 {
		return nil, false
	}
	current, has_impulse := record_field_value(body.fields, "impulse")
	if !has_impulse {
		return nil, false
	}
	prior, is_prior_vec2 := current.(Vec2_Value)
	if !is_prior_vec2 {
		return nil, false
	}
	updated := make([]Record_Field_Value, len(body.fields), context.temp_allocator)
	copy(updated, body.fields)
	if !record_replace_field(updated, "impulse", vec2_add(prior, push)) {
		return nil, false
	}
	return Record_Value{type_name = body.type_name, variant = body.variant, fields = updated}, true
}

eval_audio_adder :: proc(ctx: Eval_Ctx, env: ^Env, record: Record_Value, member: string, args: []Expr) -> (value: Value, is_audio: bool) {
	if record.type_name != "Sound" && record.type_name != "Audio" {
		return nil, false
	}
	field: string
	wrap_some := false
	switch member {
	case "gain", "pitch", "bus":
		field = member
	case "at":
		field = "at"
		wrap_some = true
	case:
		return nil, false
	}
	if len(args) != 1 {
		return nil, false
	}
	arg, arg_ok := eval_expr(ctx, env, args[0])
	if !arg_ok {
		return nil, false
	}
	if wrap_some {
		arg = some_value(arg)
	}
	updated := make([]Record_Field_Value, len(record.fields), context.temp_allocator)
	copy(updated, record.fields)
	if !record_replace_field(updated, field, arg) {
		return nil, false
	}
	return Record_Value{type_name = record.type_name, variant = record.variant, fields = updated}, true
}

eval_resource_builder :: proc(ctx: Eval_Ctx, env: ^Env, type_name, member: string, args: []Expr) -> (value: Value, is_builder: bool) {
	switch type_name {
	case "Rng":
		if member == "seed" && len(args) == 1 {
			seed_value, seed_ok := eval_expr(ctx, env, args[0])
			if !seed_ok {
				return nil, false
			}
			n, is_int := seed_value.(i64)
			if !is_int {
				return nil, false
			}
			return rand_seed(n), true
		}
	case "TilemapHandle":
		if member == "of" && len(args) == 2 {
			return eval_tilemap_fixture(ctx, env, args)
		}
	case "Nav":
		if member == "of" && len(args) == 1 {
			route_value, route_ok := eval_expr(ctx, env, args[0])
			if !route_ok {
				return nil, false
			}
			route, is_path := route_value.(Record_Value)
			if !is_path || route.type_name != "Path" {
				return nil, false
			}
			return Nav_Value{route = route}, true
		}
		if member == "fail" && len(args) == 1 {
			err_value, err_ok := eval_expr(ctx, env, args[0])
			if !err_ok {
				return nil, false
			}
			err, is_enum := err_value.(Enum_Value)
			if !is_enum || err.type_name != "NavError" {
				return nil, false
			}
			return Nav_Value{failed = true, err = err.variant}, true
		}
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
	case "Settings":
		if member == "defaults" && len(args) == 0 {
			return settings_defaults(), true
		}
	case "View":
		if member == "of" && len(args) == 1 {
			source, source_ok := eval_expr(ctx, env, args[0])
			if !source_ok {
				return nil, false
			}
			list, is_list := source.(List_Value)
			if !is_list {
				return nil, false
			}
			return list, true
		}
	}
	return nil, false
}

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
		return Input_Value{pressed = next, analog1d = input.analog1d, analog2d = input.analog2d}, true
	case "with_value":
		player, axis, sample, args_ok := eval_input_analog_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		f, is_fixed := sample.(Fixed)
		if !is_fixed {
			return nil, false
		}
		next := make([]Input_Analog_Value, len(input.analog1d) + 1, context.temp_allocator)
		copy(next, input.analog1d)
		next[len(input.analog1d)] = Input_Analog_Value{player = player, axis = axis, value = f}
		return Input_Value{pressed = input.pressed, analog1d = next, analog2d = input.analog2d}, true
	case "with_axis":
		player, axis, sample, args_ok := eval_input_analog_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		v, is_vec2 := sample.(Vec2_Value)
		if !is_vec2 {
			return nil, false
		}
		next := make([]Input_Analog_Axis, len(input.analog2d) + 1, context.temp_allocator)
		copy(next, input.analog2d)
		next[len(input.analog2d)] = Input_Analog_Axis{player = player, axis = axis, value = v}
		return Input_Value{pressed = input.pressed, analog1d = input.analog1d, analog2d = next}, true
	case "pressed", "held":
		player, action, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return input_is_pressed(input, player, action), true
	case "released":
		_, _, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return false, true
	case "value":
		player, axis, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return input_analog_value(input, player, axis), true
	case "axis":
		player, axis, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return input_analog_axis(input, player, axis), true
	}
	return nil, false
}

eval_input_analog_args :: proc(ctx: Eval_Ctx, env: ^Env, args: []Expr) -> (player, axis: string, sample: Value, ok: bool) {
	if len(args) != 3 {
		return "", "", nil, false
	}
	player_value, p_ok := eval_expr(ctx, env, args[0])
	axis_value, a_ok := eval_expr(ctx, env, args[1])
	sample_value, s_ok := eval_expr(ctx, env, args[2])
	if !p_ok || !a_ok || !s_ok {
		return "", "", nil, false
	}
	player_variant, is_player := player_value.(Enum_Value)
	axis_variant, is_axis := axis_value.(Enum_Value)
	if !is_player || !is_axis {
		return "", "", nil, false
	}
	return player_variant.variant, axis_variant.variant, sample_value, true
}

input_analog_value :: proc(input: Input_Value, player, axis: string) -> Fixed {
	result := Fixed(0)
	for sample in input.analog1d {
		if sample.player == player && sample.axis == axis {
			result = sample.value
		}
	}
	return result
}

input_analog_axis :: proc(input: Input_Value, player, axis: string) -> Vec2_Value {
	result := Vec2_Value{}
	for sample in input.analog2d {
		if sample.player == player && sample.axis == axis {
			result = sample.value
		}
	}
	return result
}

eval_view_count :: proc(ctx: Eval_Ctx, env: ^Env, view: List_Value, args: []Expr) -> (value: Value, ok: bool) {
	if len(args) != 0 {
		return nil, false
	}
	return i64(len(view.elements)), true
}

eval_view_at :: proc(ctx: Eval_Ctx, env: ^Env, view: List_Value, args: []Expr) -> (value: Value, ok: bool) {
	if len(args) != 1 {
		return nil, false
	}
	index_value := eval_expr(ctx, env, args[0]) or_return
	index, is_int := index_value.(i64)
	if !is_int {
		return nil, false
	}
	if index < 0 || index >= i64(len(view.elements)) {
		return nil, false
	}
	return view.elements[index], true
}

eval_view_ref :: proc(ctx: Eval_Ctx, env: ^Env, args: []Expr) -> (value: Value, ok: bool) {
	if len(args) != 1 {
		return nil, false
	}
	index_value := eval_expr(ctx, env, args[0]) or_return
	index, is_int := index_value.(i64)
	if !is_int {
		return nil, false
	}
	fields := make([]Record_Field_Value, 1, context.temp_allocator)
	fields[0] = Record_Field_Value{name = "index", value = index}
	return Record_Value{type_name = "Ref", fields = fields}, true
}

eval_view_resolve :: proc(ctx: Eval_Ctx, env: ^Env, view: List_Value, args: []Expr) -> (value: Value, ok: bool) {
	if len(args) != 1 {
		return nil, false
	}
	ref_value := eval_expr(ctx, env, args[0]) or_return
	ref, is_record := ref_value.(Record_Value)
	if !is_record || ref.type_name != "Ref" {
		return nil, false
	}
	index_value, has_index := record_field_value(ref.fields, "index")
	if !has_index {
		return nil, false
	}
	index, is_int := index_value.(i64)
	if !is_int {
		return nil, false
	}
	if index < 0 || index >= i64(len(view.elements)) {
		return Option_Value{is_some = false, payload = nil}, true
	}
	return some_value(view.elements[index]), true
}

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

input_is_pressed :: proc(input: Input_Value, player, action: string) -> bool {
	for press in input.pressed {
		if press.player == player && press.action == action {
			return true
		}
	}
	return false
}

eval_tilemap_fixture :: proc(ctx: Eval_Ctx, env: ^Env, args: []Expr) -> (value: Value, ok: bool) {
	size_value := eval_expr(ctx, env, args[0]) or_return
	cell_size, size_is_int := size_value.(i64)
	if !size_is_int || cell_size <= 0 {
		return nil, false
	}
	rows_value := eval_expr(ctx, env, args[1]) or_return
	rows, is_list := rows_value.(List_Value)
	if !is_list {
		return nil, false
	}
	cells := make([]Tilemap_Seed_Cell, len(rows.elements), context.temp_allocator)
	cell_type_name := ""
	for element, i in rows.elements {
		row, is_tuple := element.(Tuple_Value)
		if !is_tuple || len(row.elements) != 3 {
			return nil, false
		}
		x, y, type_name, cell_ok := tilemap_cell_coords(row.elements[0])
		tile, tile_is_string := row.elements[1].(string)
		solid, solid_is_bool := row.elements[2].(bool)
		if !cell_ok || !tile_is_string || !solid_is_bool {
			return nil, false
		}
		if cell_type_name == "" {
			cell_type_name = type_name
		}
		cells[i] = Tilemap_Seed_Cell{x = x, y = y, tile = tile, solid = solid}
	}
	return Tilemap_Value{cell_size = cell_size, cell_type_name = cell_type_name, cells = cells}, true
}

eval_tilemap_method :: proc(ctx: Eval_Ctx, env: ^Env, tilemap: Tilemap_Value, member: string, args: []Expr) -> (value: Value, ok: bool) {
	if len(args) != 1 {
		return nil, false
	}
	arg := eval_expr(ctx, env, args[0]) or_return
	switch member {
	case "tile_at":
		x, y, _, cell_ok := tilemap_cell_coords(arg)
		if !cell_ok {
			return nil, false
		}
		seed, found := tilemap_seed_lookup(tilemap.cells, x, y)
		if !found {
			return Option_Value{is_some = false}, true
		}
		return some_value(seed.tile), true
	case "solid_at":
		x, y, _, cell_ok := tilemap_cell_coords(arg)
		if !cell_ok {
			return nil, false
		}
		seed, found := tilemap_seed_lookup(tilemap.cells, x, y)
		if !found {
			return false, true
		}
		return seed.solid, true
	case "cell_of":
		pos, is_vec := arg.(Vec2_Value)
		if !is_vec {
			return nil, false
		}
		fields := make([]Record_Field_Value, 2, context.temp_allocator)
		fields[0] = Record_Field_Value{name = "x", value = tilemap_cell_index(pos.x, tilemap.cell_size)}
		fields[1] = Record_Field_Value{name = "y", value = tilemap_cell_index(pos.y, tilemap.cell_size)}
		return Record_Value{type_name = tilemap.cell_type_name, fields = fields}, true
	case "center_of":
		x, y, _, cell_ok := tilemap_cell_coords(arg)
		if !cell_ok {
			return nil, false
		}
		return Vec2_Value{
			x = tilemap_cell_center(x, tilemap.cell_size),
			y = tilemap_cell_center(y, tilemap.cell_size),
		}, true
	}
	return nil, false
}

eval_nav_method :: proc(ctx: Eval_Ctx, env: ^Env, nav: Nav_Value, member: string, args: []Expr) -> (value: Value, ok: bool) {
	switch member {
	case "path":
		if len(args) != 2 {
			return nil, false
		}
		if nav.failed {
			boxed := new(Value, context.temp_allocator)
			boxed^ = Enum_Value{type_name = "NavError", variant = nav.err}
			return Enum_Value{type_name = "Result", variant = "Err", payload = boxed}, true
		}
		boxed := new(Value, context.temp_allocator)
		boxed^ = nav.route
		return Enum_Value{type_name = "Result", variant = "Ok", payload = boxed}, true
	case "los", "reachable":
		if len(args) != 2 {
			return nil, false
		}
		return !nav.failed, true
	case "nearest":
		if len(args) != 1 {
			return nil, false
		}
		if nav.failed {
			return none_value(), true
		}
		point := eval_expr(ctx, env, args[0]) or_return
		return some_value(point), true
	}
	return nil, false
}

eval_path_advance :: proc(ctx: Eval_Ctx, env: ^Env, route: Record_Value, args: []Expr) -> (value: Value, ok: bool) {
	if len(args) != 2 {
		return nil, false
	}
	pos_value := eval_expr(ctx, env, args[0]) or_return
	pos, pos_is_vec := pos_value.(Vec2_Value)
	if !pos_is_vec {
		return nil, false
	}
	arrive_value := eval_expr(ctx, env, args[1]) or_return
	arrive, arrive_is_fixed := arrive_value.(Fixed)
	if !arrive_is_fixed {
		return nil, false
	}
	steps_value, has_steps := record_field_value(route.fields, "steps")
	if !has_steps {
		return nil, false
	}
	steps, steps_is_list := steps_value.(List_Value)
	if !steps_is_list {
		return nil, false
	}
	next := 0
	for next < len(steps.elements) {
		wp, wp_is_vec := steps.elements[next].(Vec2_Value)
		if !wp_is_vec {
			return nil, false
		}
		if vec2_length(vec2_sub(wp, pos)) <= arrive {
			next += 1
			continue
		}
		break
	}
	remaining := path_record(steps.elements[next:], route)
	if next >= len(steps.elements) {
		return tuple2(Option_Value{is_some = false}, remaining), true
	}
	return tuple2(some_value(steps.elements[next]), remaining), true
}

path_record :: proc(steps: []Value, source: Record_Value) -> Record_Value {
	fields := make([]Record_Field_Value, 2, context.temp_allocator)
	fields[0] = Record_Field_Value{name = "steps", value = List_Value{elements = steps}}
	cost, _ := record_field_value(source.fields, "cost")
	fields[1] = Record_Field_Value{name = "cost", value = cost}
	return Record_Value{type_name = "Path", fields = fields}
}

tuple2 :: proc(a, b: Value) -> Value {
	elements := make([]Value, 2, context.temp_allocator)
	elements[0] = a
	elements[1] = b
	return Tuple_Value{elements = elements}
}

tilemap_cell_coords :: proc(cell: Value) -> (x, y: i64, type_name: string, ok: bool) {
	record, is_record := cell.(Record_Value)
	if !is_record {
		return 0, 0, "", false
	}
	x_value, has_x := record_field_value(record.fields, "x")
	y_value, has_y := record_field_value(record.fields, "y")
	if !has_x || !has_y {
		return 0, 0, "", false
	}
	xi, x_is_int := x_value.(i64)
	yi, y_is_int := y_value.(i64)
	if !x_is_int || !y_is_int {
		return 0, 0, "", false
	}
	return xi, yi, record.type_name, true
}

tilemap_seed_lookup :: proc(cells: []Tilemap_Seed_Cell, x, y: i64) -> (cell: Tilemap_Seed_Cell, found: bool) {
	for candidate in cells {
		if candidate.x == x && candidate.y == y {
			return candidate, true
		}
	}
	return Tilemap_Seed_Cell{}, false
}

tilemap_cell_index :: proc(coord: Fixed, cell_size: i64) -> i64 {
	span := i128(cell_size) << FIXED_FRACTION_BITS
	quotient := i128(coord) / span
	if i128(coord) % span != 0 && i128(coord) < 0 {
		quotient -= 1
	}
	return int_saturate(quotient)
}

tilemap_cell_center :: proc(index: i64, cell_size: i64) -> Fixed {
	origin := i128(int_mul(index, cell_size)) << FIXED_FRACTION_BITS
	half := i128(cell_size) << (FIXED_FRACTION_BITS - 1)
	return fixed_saturate(origin + half)
}

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

transform_identity :: proc() -> Transform_Value {
	return Transform_Value{
		pos   = Vec3_Value{},
		rot   = QUAT_IDENTITY,
		scale = Vec3_Value{x = FIXED_ONE, y = FIXED_ONE, z = FIXED_ONE},
	}
}

transform_rot_x :: proc(angle: Fixed) -> Transform_Value {
	t := transform_identity()
	t.rot = quat_axis_angle(Vec3_Value{x = FIXED_ONE}, angle)
	return t
}

transform_up :: proc(d: Fixed) -> Transform_Value {
	t := transform_identity()
	t.pos = Vec3_Value{y = d}
	return t
}

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

eval_pose_get :: proc(pose: Pose_Value, bone: string) -> Value {
	if transform, found := pose_bone_transform(pose.bones, bone); found {
		return transform
	}
	return transform_identity()
}

eval_pose_blend :: proc(a, b: Pose_Value, weight: Fixed) -> Value {
	bones := make([dynamic]Pose_Bone_Transform, 0, len(a.bones) + len(b.bones), context.temp_allocator)
	for driven in a.bones {
		other, found := pose_bone_transform(b.bones, driven.bone)
		if !found {
			other = transform_identity()
		}
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

transform_blend :: proc(a, b: Transform_Value, weight: Fixed) -> Transform_Value {
	return Transform_Value{
		pos   = vec3_lerp(a.pos, b.pos, weight),
		rot   = quat_slerp(a.rot, b.rot, weight),
		scale = vec3_lerp(a.scale, b.scale, weight),
	}
}

vec3_lerp :: proc(a, b: Vec3_Value, t: Fixed) -> Vec3_Value {
	return Vec3_Value{
		x = fixed_lerp(a.x, b.x, t),
		y = fixed_lerp(a.y, b.y, t),
		z = fixed_lerp(a.z, b.z, t),
	}
}

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

eval_pose_expr :: proc(ctx: Eval_Ctx, env: ^Env, expr: Expr) -> (pose: Pose_Value, ok: bool) {
	value := eval_expr(ctx, env, expr) or_return
	return value.(Pose_Value)
}

eval_bone_arg :: proc(ctx: Eval_Ctx, env: ^Env, expr: Expr) -> (bone: string, ok: bool) {
	value := eval_expr(ctx, env, expr) or_return
	variant, is_variant := value.(Enum_Value)
	if !is_variant {
		return "", false
	}
	return variant.variant, true
}

find_user_behavior :: proc(ast: Ast, name: string) -> (behavior: Behavior_Node, found: bool) {
	for decl in ast.behaviors {
		if decl.name == name {
			return decl, true
		}
	}
	return Behavior_Node{}, false
}

eval_fixed_arg :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr, i: int, arity: int) -> (f: Fixed, ok: bool) {
	if len(e.args) != arity {
		return Fixed(0), false
	}
	value := eval_expr(ctx, env, e.args[i]) or_return
	return value.(Fixed)
}
