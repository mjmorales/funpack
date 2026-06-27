package funpack

Type_Error :: enum {
	None,
	Assert_Not_Bool,
	Type_Mismatch,
	Unsupported_Expr,
	Unknown_Method,
	Unknown_Module,
	Unknown_Member,
	Package_Private,
	Package_Imports_Package,
	Expose_Closure_Violation,
	Unresolved_Name,
	Name_Collision,
	Unregistered_Layer,
	Reserved_Signal_Name,
	Tuple_Pattern_Arity,
	Let_Tuple_Arity_Mismatch,
	Migrate_From_Collision,
	Migrate_Convert_Unknown,
	Migrate_Convert_Arity,
	Migrate_Convert_Return,
	Index_Unknown_Thing,
	Index_Unknown_Field,
	All_Outside_Query,
	All_Unknown_Thing,
	Spatial_Requirement_Missing,
	Spatial_Requirement_Ambiguous,
	Query_Param_Not_Value,
}

Scope :: map[string]Type

Check_Ctx :: struct {
	bindings:        Bindings,
	env:             Type_Env,
	index:           Module_Index,
	scope:           Scope,
	expected_return: Type,
	in_query:        bool,
	query_indexes:   []Index_Directive,
	importer_root:   string,
	diag:            ^Type_Diag_Site,
}

Type_Diag_Site :: struct {
	line:        int,
	col:         int,
	declaration: string,
	hint:        string,
	set:         bool,
}

Type_Verdict :: struct {
	err:         Type_Error,
	line:        int,
	col:         int,
	declaration: string,
	hint:        string,
}

stage_typecheck :: proc(ast: Ast) -> (typed: Typed_Ast, err: Type_Error) {
	return stage_typecheck_indexed(ast, Module_Index{})
}

stage_typecheck_located :: proc(ast: Ast, index: Module_Index, importer_root := "") -> (typed: Typed_Ast, verdict: Type_Verdict) {
	site := Type_Diag_Site{}
	checked, err := stage_typecheck_sited(ast, index, importer_root, &site)
	if err == .None {
		return checked, Type_Verdict{}
	}
	return checked, Type_Verdict{err = err, line = site.line, col = site.col, declaration = site.declaration, hint = site.hint}
}

stage_typecheck_indexed :: proc(ast: Ast, index: Module_Index, importer_root := "") -> (typed: Typed_Ast, err: Type_Error) {
	return stage_typecheck_sited(ast, index, importer_root, nil)
}

stage_typecheck_sited :: proc(ast: Ast, index: Module_Index, importer_root: string, site: ^Type_Diag_Site) -> (typed: Typed_Ast, err: Type_Error) {
	bindings := resolve_imports_indexed(ast, index, importer_root, site) or_return
	env := resolve_env(ast, bindings, index, site) or_return
	check_layer_registry(ast, site) or_return
	check_migrations(ast, site) or_return
	check_index_paths(ast, site) or_return
	check_expose_closure(ast, bindings, index, site) or_return
	check_bodies(bindings, env, index, ast, importer_root, site) or_return
	check_tests(bindings, env, index, ast, importer_root, site) or_return
	check_probe_args(bindings, env, index, ast, importer_root, site) or_return
	return Typed_Ast{ast = ast, bindings = bindings, env = env}, .None
}

check_layer_registry :: proc(ast: Ast, site: ^Type_Diag_Site = nil) -> Type_Error {
	registry := collision_layer_registry(ast)
	for fn in ast.fns {
		if err := layer_walk_body(fn.body, registry); err != .None {
			stamp_decl(site, fn.name, fn.line)
			return err
		}
		if fn.has_fallback {
			if err := layer_walk_expr(fn.fallback, registry); err != .None {
				stamp_decl(site, fn.name, fn.line)
				return err
			}
		}
	}
	for behavior in ast.behaviors {
		if err := layer_walk_body(behavior.step.body, registry); err != .None {
			stamp_decl(site, behavior.name, behavior.line)
			return err
		}
		if behavior.step.has_fallback {
			if err := layer_walk_expr(behavior.step.fallback, registry); err != .None {
				stamp_decl(site, behavior.name, behavior.line)
				return err
			}
		}
	}
	for test in ast.tests {
		if err := layer_walk_body(test.body, registry); err != .None {
			stamp_decl(site, test.name, test.line)
			return err
		}
	}
	return .None
}

collision_layer_registry :: proc(ast: Ast) -> []string {
	names := make([dynamic]string, 0, 8, context.temp_allocator)
	for decl in ast.enums {
		if decl.kind != "CollisionLayer" {
			continue
		}
		for variant in decl.variants {
			append(&names, variant.name)
		}
	}
	return names[:]
}

check_migrations :: proc(ast: Ast, site: ^Type_Diag_Site = nil) -> Type_Error {
	for decl in ast.datas {
		if decl.has_migrate && type_name_is_live(ast, decl.migrate.from) {
			stamp_decl(site, decl.name, decl.line)
			return .Migrate_From_Collision
		}
		for field in decl.fields {
			if !field.has_migrate {
				continue
			}
			if field.migrate.has_from {
				for other in decl.fields {
					if other.name == field.migrate.from {
						stamp_decl(site, decl.name, decl.line)
						return .Migrate_From_Collision
					}
				}
			}
			if field.migrate.has_with {
				if err := check_migrate_convert(ast, field); err != .None {
					stamp_decl(site, decl.name, decl.line)
					return err
				}
			}
		}
	}
	return .None
}

check_index_paths :: proc(ast: Ast, site: ^Type_Diag_Site = nil) -> Type_Error {
	for query in ast.queries {
		for directive in query.indexes {
			thing, declared := thing_by_name(ast, directive.thing)
			if !declared {
				stamp_decl(site, query.name, query.line)
				return .Index_Unknown_Thing
			}
			if !fields_declare(thing.fields, directive.field) {
				stamp_decl(site, query.name, query.line)
				return .Index_Unknown_Field
			}
		}
	}
	return .None
}

thing_by_name :: proc(ast: Ast, name: string) -> (thing: Thing_Node, declared: bool) {
	for decl in ast.things {
		if decl.name == name {
			return decl, true
		}
	}
	return Thing_Node{}, false
}

fields_declare :: proc(fields: []Field_Decl, name: string) -> bool {
	for field in fields {
		if field.name == name {
			return true
		}
	}
	return false
}

type_name_is_live :: proc(ast: Ast, name: string) -> bool {
	for decl in ast.datas {
		if decl.name == name {
			return true
		}
	}
	for decl in ast.enums {
		if decl.name == name {
			return true
		}
	}
	for decl in ast.things {
		if decl.name == name {
			return true
		}
	}
	for decl in ast.signals {
		if decl.name == name {
			return true
		}
	}
	return false
}

check_migrate_convert :: proc(ast: Ast, field: Field_Decl) -> Type_Error {
	for fn in ast.fns {
		if fn.name != field.migrate.with {
			continue
		}
		if len(fn.params) != 1 {
			return .Migrate_Convert_Arity
		}
		if type_ref_string(fn.return_type) != type_ref_string(field.type) {
			return .Migrate_Convert_Return
		}
		return .None
	}
	return .Migrate_Convert_Unknown
}

layer_walk_body :: proc(body: []Statement, registry: []string) -> Type_Error {
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			layer_walk_expr(node.value, registry) or_return
		case Assert_Node:
			layer_walk_expr(node.expr, registry) or_return
		case Return_Node:
			layer_walk_expr(node.value, registry) or_return
		case If_Node:
			layer_walk_expr(node.cond, registry) or_return
			layer_walk_body(node.body, registry) or_return
		}
	}
	return .None
}

layer_walk_expr :: proc(expr: Expr, registry: []string) -> Type_Error {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr:
		return .None
	case ^Call_Expr:
		layer_walk_expr(e.callee, registry) or_return
		for arg in e.args {
			layer_walk_expr(arg, registry) or_return
		}
	case ^Member_Expr:
		layer_walk_expr(e.receiver, registry) or_return
	case ^Variant_Expr:
		for arg in e.payload {
			layer_walk_expr(arg, registry) or_return
		}
		for field in e.fields {
			layer_walk_expr(field.value, registry) or_return
		}
	case ^Record_Expr:
		if e.type_name == "Body" {
			check_body_layers(e, registry) or_return
		}
		for field in e.fields {
			layer_walk_expr(field.value, registry) or_return
		}
	case ^List_Expr:
		for element in e.elements {
			layer_walk_expr(element, registry) or_return
		}
	case ^Lambda_Expr:
		layer_walk_expr(e.body, registry) or_return
	case ^Unary_Expr:
		layer_walk_expr(e.operand, registry) or_return
	case ^Binary_Expr:
		layer_walk_expr(e.lhs, registry) or_return
		layer_walk_expr(e.rhs, registry) or_return
	case ^With_Expr:
		layer_walk_expr(e.base, registry) or_return
		for field in e.fields {
			layer_walk_expr(field.value, registry) or_return
		}
	case ^Match_Expr:
		layer_walk_expr(e.scrutinee, registry) or_return
		for arm in e.arms {
			layer_walk_expr(arm.body, registry) or_return
		}
	case ^Tuple_Expr:
		for element in e.elements {
			layer_walk_expr(element, registry) or_return
		}
	case ^If_Expr:
		layer_walk_expr(e.cond, registry) or_return
		layer_walk_expr(e.then_branch, registry) or_return
		layer_walk_expr(e.else_branch, registry) or_return
	case ^Stub_Expr:
		if e.has_fallback {
			layer_walk_expr(e.fallback, registry) or_return
		}
	case ^All_Expr:
	}
	return .None
}

check_body_layers :: proc(e: ^Record_Expr, registry: []string) -> Type_Error {
	for field in e.fields {
		if field.name == "layer" {
			check_layer_value(field.value, registry) or_return
		}
		if field.name == "mask" {
			if list, is_list := field.value.(^List_Expr); is_list {
				for element in list.elements {
					check_layer_value(element, registry) or_return
				}
			}
		}
	}
	return .None
}

check_layer_value :: proc(expr: Expr, registry: []string) -> Type_Error {
	variant, is_variant := expr.(^Variant_Expr)
	if !is_variant {
		return .None
	}
	if !name_in_set(variant.variant, registry) {
		return .Unregistered_Layer
	}
	return .None
}

check_bodies :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, ast: Ast, importer_root := "", site: ^Type_Diag_Site = nil) -> Type_Error {
	for fn in ast.fns {
		if fn.is_extern {
			continue
		}
		if err := check_fn_body(bindings, env, index, fn, importer_root, site); err != .None {
			stamp_decl(site, fn.name, fn.line)
			return err
		}
	}
	for query in ast.queries {
		if err := check_query_body(bindings, env, index, query, importer_root, site); err != .None {
			stamp_decl(site, query.name, query.line)
			return err
		}
	}
	for behavior in ast.behaviors {
		if err := check_fn_body(bindings, env, index, behavior.step, importer_root, site); err != .None {
			stamp_decl(site, behavior.name, behavior.line)
			return err
		}
	}
	return .None
}

stamp_decl :: proc(site: ^Type_Diag_Site, name: string, line: int) {
	if site == nil {
		return
	}
	site.declaration = name
	if !site.set {
		site.line = line
		site.set = true
	}
}

stamp_expr :: proc(ctx: Check_Ctx, expr: Expr) {
	if ctx.diag == nil || ctx.diag.set {
		return
	}
	line, col := expr_span(expr)
	if line != 0 {
		ctx.diag.line = line
		ctx.diag.col = col
		ctx.diag.set = true
	}
}

stamp_member :: proc(ctx: Check_Ctx, callee: ^Member_Expr, hint: string) {
	if ctx.diag == nil || ctx.diag.set {
		return
	}
	if callee.member_line != 0 {
		ctx.diag.line = callee.member_line
		ctx.diag.col = callee.member_col
		ctx.diag.hint = hint
		ctx.diag.set = true
	}
}

query_as_fn :: proc(query: Query_Node) -> Fn_Node {
	return Fn_Node {
		name = query.name,
		params = query.params,
		return_type = query.return_type,
		body = query.body,
		line = query.line,
	}
}

check_fn_body :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, fn: Fn_Node, importer_root := "", site: ^Type_Diag_Site = nil) -> Type_Error {
	ctx := fn_body_ctx(bindings, env, index, fn, importer_root)
	ctx.diag = site
	if fn.holed {
		return check_stub_hole(ctx, fn)
	}
	return check_statements(ctx, fn.body)
}

check_query_body :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, query: Query_Node, importer_root := "", site: ^Type_Diag_Site = nil) -> Type_Error {
	ctx := fn_body_ctx(bindings, env, index, query_as_fn(query), importer_root)
	ctx.diag = site
	ctx.in_query = true
	ctx.query_indexes = query.indexes
	for param in query.params {
		if type_outside_value_domain(ctx.scope[param.name]) {
			return .Query_Param_Not_Value
		}
	}
	return check_statements(ctx, query.body)
}

type_outside_value_domain :: proc(t: Type) -> bool {
	switch v in t {
	case Ground_Type:
		return false
	case ^Option_Type:
		return type_outside_value_domain(v.elem)
	case ^List_Type:
		return type_outside_value_domain(v.elem)
	case ^Map_Type:
		return type_outside_value_domain(v.key) || type_outside_value_domain(v.value)
	case ^Tuple_Type:
		for elem in v.elements {
			if type_outside_value_domain(elem) {
				return true
			}
		}
		return false
	case ^Func_Type:
		return true
	case ^User_Type:
		return false
	case ^Engine_Type:
		#partial switch v.kind {
		case .View, .Ref, .Nav, .Input, .Time, .Rng, .Bindings:
			return true
		}
		return false
	}
	return false
}

fn_body_ctx :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, fn: Fn_Node, importer_root := "") -> Check_Ctx {
	ctx := Check_Ctx {
		bindings        = bindings,
		env             = env,
		index           = index,
		scope           = make(Scope, context.temp_allocator),
		expected_return = resolve_type_ref(env, bindings, fn.return_type, index),
		importer_root   = importer_root,
	}
	for param in fn.params {
		ctx.scope[param.name] = resolve_type_ref(env, bindings, param.type, index)
	}
	return ctx
}

check_stub_hole :: proc(ctx: Check_Ctx, fn: Fn_Node) -> Type_Error {
	hole := resolve_type_ref(ctx.env, ctx.bindings, fn.hole_type, ctx.index)
	if !types_compatible(hole, ctx.expected_return) {
		return .Type_Mismatch
	}
	if fn.has_fallback {
		fallback := expr_check(ctx, fn.fallback) or_return
		if !types_compatible(fallback, hole) {
			stamp_expr(ctx, fn.fallback)
			return .Type_Mismatch
		}
	}
	return .None
}

check_statements :: proc(ctx: Check_Ctx, body: []Statement) -> Type_Error {
	ctx := ctx
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			type := expr_check(ctx, node.value) or_return
			if node.is_tuple {
				bind_let_tuple(&ctx.scope, node.names, type) or_return
			} else {
				ctx.scope[node.name] = type
			}
		case Return_Node:
			value := expr_check(ctx, node.value) or_return
			if !types_compatible(value, ctx.expected_return) {
				stamp_expr(ctx, node.value)
				return .Type_Mismatch
			}
		case If_Node:
			cond := expr_check(ctx, node.cond) or_return
			if !is_ground(cond, .Bool) {
				stamp_expr(ctx, node.cond)
				return .Type_Mismatch
			}
			check_statements(ctx, node.body) or_return
		case Assert_Node:
		}
	}
	return .None
}

check_tests :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, ast: Ast, importer_root := "", site: ^Type_Diag_Site = nil) -> Type_Error {
	for test in ast.tests {
		ctx := Check_Ctx{bindings = bindings, env = env, index = index, scope = make(Scope, context.temp_allocator), importer_root = importer_root, diag = site}
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				type, err := expr_check(ctx, node.value)
				if err != .None {
					stamp_decl(site, test.name, test.line)
					return err
				}
				if node.is_tuple {
					if berr := bind_let_tuple(&ctx.scope, node.names, type); berr != .None {
						stamp_decl(site, test.name, test.line)
						return berr
					}
				} else {
					ctx.scope[node.name] = type
				}
			case Assert_Node:
				if err := check_assert(ctx, node); err != .None {
					stamp_decl(site, test.name, test.line)
					return err
				}
			case Return_Node, If_Node:
			}
		}
	}
	return .None
}

check_assert :: proc(ctx: Check_Ctx, node: Assert_Node) -> Type_Error {
	type := expr_check(ctx, node.expr) or_return
	if !is_ground(type, .Bool) {
		stamp_expr(ctx, node.expr)
		return .Assert_Not_Bool
	}
	return .None
}

check_probe_args :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, ast: Ast, importer_root := "", site: ^Type_Diag_Site = nil) -> Type_Error {
	for behavior in ast.behaviors {
		ctx := fn_body_ctx(bindings, env, index, behavior.step, importer_root)
		ctx.diag = site
		for probe in behavior.probes {
			if err := check_one_probe_arg(ctx, probe); err != .None {
				stamp_decl(site, behavior.name, behavior.line)
				return err
			}
		}
	}
	for decl in ast.datas {
		ctx := probe_field_ctx(bindings, env, index, decl.name, importer_root)
		ctx.diag = site
		for field in decl.fields {
			for probe in field.probes {
				if err := check_one_probe_arg(ctx, probe); err != .None {
					stamp_decl(site, decl.name, decl.line)
					return err
				}
			}
		}
	}
	for pipeline in ast.pipelines {
		for stage in pipeline.stages {
			for probe in stage.probes {
				check_stage_probe_arg(probe) or_return
			}
		}
	}
	return .None
}

check_one_probe_arg :: proc(ctx: Check_Ctx, probe: Debug_Probe) -> Type_Error {
	if probe.arg == nil {
		return .None
	}
	_ = expr_check(ctx, probe.arg) or_return
	return .None
}

check_stage_probe_arg :: proc(probe: Debug_Probe) -> Type_Error {
	ctx := Check_Ctx{scope = make(Scope, context.temp_allocator)}
	return check_one_probe_arg(ctx, probe)
}

probe_field_ctx :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, data_name: string, importer_root := "") -> Check_Ctx {
	ctx := Check_Ctx {
		bindings      = bindings,
		env           = env,
		index         = index,
		scope         = make(Scope, context.temp_allocator),
		importer_root = importer_root,
	}
	ctx.scope["self"] = user_type_of(data_name, .Data)
	return ctx
}

expr_check :: proc(ctx: Check_Ctx, expr: Expr) -> (type: Type, err: Type_Error) {
	type, err = expr_check_inner(ctx, expr)
	if err != .None {
		stamp_expr(ctx, expr)
	}
	return type, err
}

expr_check_inner :: proc(ctx: Check_Ctx, expr: Expr) -> (type: Type, err: Type_Error) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return Ground_Type.Int, .None
	case ^Fixed_Lit_Expr:
		return Ground_Type.Fixed, .None
	case ^String_Lit_Expr:
		return engine_type_of(.String), .None
	case ^Name_Expr:
		return name_check(ctx, e)
	case ^Unary_Expr:
		operand := expr_check(ctx, e.operand) or_return
		if e.op.kind == .Ident && e.op.text == "not" {
			if !is_ground(operand, .Bool) {
				return nil, .Type_Mismatch
			}
			return Ground_Type.Bool, .None
		}
		if e.op.kind != .Minus {
			return nil, .Unsupported_Expr
		}
		if !is_numeric_ground(operand) {
			return nil, .Type_Mismatch
		}
		return operand, .None
	case ^Binary_Expr:
		return binary_check(ctx, e)
	case ^Member_Expr:
		return member_check(ctx, e)
	case ^Record_Expr:
		return record_check(ctx, e)
	case ^List_Expr:
		return list_check(ctx, e)
	case ^Lambda_Expr:
		return func_of(nil, nil), .None
	case ^Call_Expr:
		return call_check(ctx, e)
	case ^Variant_Expr:
		return variant_check(ctx, e)
	case ^With_Expr:
		return with_check(ctx, e)
	case ^Match_Expr:
		return match_check(ctx, e)
	case ^Tuple_Expr:
		return tuple_check(ctx, e)
	case ^If_Expr:
		return if_check(ctx, e)
	case ^Stub_Expr:
		return stub_expr_check(ctx, e)
	case ^All_Expr:
		return all_check(ctx, e)
	}
	return nil, .Unsupported_Expr
}

all_check :: proc(ctx: Check_Ctx, e: ^All_Expr) -> (type: Type, err: Type_Error) {
	if !ctx.in_query {
		return nil, .All_Outside_Query
	}
	record, declared := ctx.env.records[e.thing]
	if !declared || record.kind != .Thing {
		return nil, .All_Unknown_Thing
	}
	return engine_type_of(.View, user_type_of(e.thing, .Thing)), .None
}

stub_expr_check :: proc(ctx: Check_Ctx, e: ^Stub_Expr) -> (type: Type, err: Type_Error) {
	hole := resolve_type_ref(ctx.env, ctx.bindings, e.hole_type, ctx.index)
	if e.has_fallback {
		fallback := expr_check(ctx, e.fallback) or_return
		if !types_compatible(fallback, hole) {
			return nil, .Type_Mismatch
		}
	}
	return hole, .None
}

if_check :: proc(ctx: Check_Ctx, e: ^If_Expr) -> (type: Type, err: Type_Error) {
	cond := expr_check(ctx, e.cond) or_return
	if !is_ground(cond, .Bool) {
		return nil, .Type_Mismatch
	}
	then_type := expr_check(ctx, e.then_branch) or_return
	else_type := expr_check(ctx, e.else_branch) or_return
	if !types_compatible(then_type, else_type) {
		return nil, .Type_Mismatch
	}
	if then_type == nil {
		return else_type, .None
	}
	return then_type, .None
}

bind_let_tuple :: proc(scope: ^Scope, names: []string, rhs: Type) -> Type_Error {
	tuple, is_tuple := rhs.(^Tuple_Type)
	if !is_tuple || len(tuple.elements) != len(names) {
		return .Let_Tuple_Arity_Mismatch
	}
	for name, i in names {
		scope[name] = tuple.elements[i]
	}
	return .None
}

tuple_check :: proc(ctx: Check_Ctx, e: ^Tuple_Expr) -> (type: Type, err: Type_Error) {
	elements := make([]Type, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		elements[i] = expr_check(ctx, element) or_return
	}
	return tuple_of(elements), .None
}

name_check :: proc(ctx: Check_Ctx, e: ^Name_Expr) -> (type: Type, err: Type_Error) {
	if e.name == "true" || e.name == "false" {
		return Ground_Type.Bool, .None
	}
	if bound, found := ctx.scope[e.name]; found {
		return bound, .None
	}
	if term, found := env_term_name(ctx.env, e.name); found {
		#partial switch term.kind {
		case .Const:
			return term.type, .None
		case .Fn, .Query:
			return term.signature, .None
		case .Behavior:
			return nil, .Unsupported_Expr
		}
	}
	if binding, found := ctx.bindings.names[e.name]; found {
		if binding.kind == .Value {
			if value_type, typed := surface_value_type(e.name); typed {
				return value_type, .None
			}
			if const_type, is_cross := module_member_const_type(ctx.index, ctx.bindings, e.name); is_cross {
				return const_type, .None
			}
		}
		if binding.kind == .Func {
			if signature, is_cross := module_call_signature(ctx.index, ctx.bindings, e.name); is_cross {
				return signature, .None
			}
		}
		return nil, .Unsupported_Expr
	}
	if env_declares(ctx.env, e.name) {
		return nil, .Unsupported_Expr
	}
	return nil, .Unresolved_Name
}

binary_check :: proc(ctx: Check_Ctx, e: ^Binary_Expr) -> (type: Type, err: Type_Error) {
	lhs := expr_check(ctx, e.lhs) or_return
	rhs := expr_check(ctx, e.rhs) or_return
	if e.op.kind == .Eq_Eq || e.op.kind == .Not_Eq {
		if !types_compatible(lhs, rhs) {
			return nil, .Type_Mismatch
		}
		return Ground_Type.Bool, .None
	}
	#partial switch e.op.kind {
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		if !(is_numeric_ground(lhs) || is_numeric_ground(rhs)) || !types_compatible(lhs, rhs) {
			return nil, .Type_Mismatch
		}
		return Ground_Type.Bool, .None
	case .Plus, .Minus, .Star, .Slash, .Percent:
		return arithmetic_check(lhs, rhs)
	case .Ident:
		if e.op.text == "and" || e.op.text == "or" {
			if !is_ground(lhs, .Bool) || !is_ground(rhs, .Bool) {
				return nil, .Type_Mismatch
			}
			return Ground_Type.Bool, .None
		}
	}
	return nil, .Unsupported_Expr
}

arithmetic_check :: proc(lhs, rhs: Type) -> (type: Type, err: Type_Error) {
	if lhs == nil {
		return rhs, .None
	}
	if rhs == nil {
		return lhs, .None
	}
	if is_numeric_ground(lhs) && types_compatible(lhs, rhs) {
		return lhs, .None
	}
	if is_vector_ground(lhs) {
		if types_compatible(lhs, rhs) {
			return lhs, .None
		}
		if is_ground(rhs, .Fixed) {
			return lhs, .None
		}
	}
	if is_vector_ground(rhs) && is_ground(lhs, .Fixed) {
		return rhs, .None
	}
	return nil, .Type_Mismatch
}

member_check :: proc(ctx: Check_Ctx, e: ^Member_Expr) -> (type: Type, err: Type_Error) {
	if recv, is_name := e.receiver.(^Name_Expr); is_name {
		if member_type, handled, member_err := module_member_check(ctx, recv.name, e.member); handled {
			return member_type, member_err
		}
		if _, in_scope := ctx.scope[recv.name]; !in_scope {
			if _, is_term := env_term_name(ctx.env, recv.name); !is_term {
				if binding, imported := ctx.bindings.names[recv.name]; imported && binding.kind == .Type_Name {
					return associated_member(recv.name, e.member)
				}
			}
		}
	}
	receiver := expr_check(ctx, e.receiver) or_return
	return field_member(ctx, receiver, e.member)
}

module_member_check :: proc(ctx: Check_Ctx, handle: string, member: string) -> (type: Type, handled: bool, err: Type_Error) {
	if _, in_scope := ctx.scope[handle]; in_scope {
		return nil, false, .None
	}
	kind, exported, handle_known, importable := module_member_kind(ctx.index, ctx.bindings, handle, member, ctx.importer_root)
	if !handle_known {
		return nil, false, .None
	}
	if !exported {
		return nil, true, .Unknown_Member
	}
	if !importable {
		return nil, true, .Package_Private
	}
	if kind != .Const {
		return nil, true, .Unsupported_Expr
	}
	const_type, found := module_const_type(ctx.index, ctx.bindings, handle, member)
	if !found {
		return nil, true, .Unknown_Member
	}
	return const_type, true, .None
}

associated_member :: proc(type_name: string, member: string) -> (type: Type, err: Type_Error) {
	associated, declared := surface_associated(type_name, member)
	if !declared {
		return nil, .Unsupported_Expr
	}
	if _, is_constructor := associated.(^Func_Type); is_constructor {
		return nil, .Unsupported_Expr
	}
	return associated, .None
}

ctx_record_schema :: proc(ctx: Check_Ctx, name: string) -> (schema: Record_Schema, found: bool) {
	if record, declared := ctx.env.records[name]; declared {
		return record, true
	}
	if record, is_cross := module_record_schema(ctx.index, ctx.bindings, name); is_cross {
		return record, true
	}
	return surface_structural_record(ctx.bindings, name)
}

field_member :: proc(ctx: Check_Ctx, receiver: Type, member: string) -> (type: Type, err: Type_Error) {
	switch r in receiver {
	case ^User_Type:
		if record, found := ctx_record_schema(ctx, r.name); found {
			if field, has := record_field_type(record, member); has {
				return field, .None
			}
		}
		return nil, .Type_Mismatch
	case Ground_Type:
		if r == .Vec2 && (member == "x" || member == "y") {
			return Ground_Type.Fixed, .None
		}
		if r == .Vec3 && (member == "x" || member == "y" || member == "z") {
			return Ground_Type.Fixed, .None
		}
		return nil, .Type_Mismatch
	case ^Engine_Type:
		if field, found := surface_engine_member(r, member); found {
			return field, .None
		}
		if field, found := surface_engine_member_record(r, member); found {
			return field, .None
		}
		return nil, .Type_Mismatch
	case ^Option_Type, ^List_Type, ^Map_Type, ^Tuple_Type, ^Func_Type:
		return nil, .Type_Mismatch
	}
	return nil, .Unsupported_Expr
}

record_field_type :: proc(schema: Record_Schema, name: string) -> (type: Type, found: bool) {
	for field in schema.fields {
		if field.name == name {
			return field.type, true
		}
	}
	return nil, false
}

record_check :: proc(ctx: Check_Ctx, e: ^Record_Expr) -> (type: Type, err: Type_Error) {
	if binding, imported := ctx.bindings.names[e.type_name]; imported {
		if binding.kind != .Type_Name {
			return nil, .Unsupported_Expr
		}
		switch e.type_name {
		case "Vec2":
			ground_record_check(ctx, e, {"x", "y"}) or_return
			return Ground_Type.Vec2, .None
		case "Vec3":
			ground_record_check(ctx, e, {"x", "y", "z"}) or_return
			return Ground_Type.Vec3, .None
		}
		if result, fields, is_record := surface_engine_record(e.type_name); is_record {
			engine_record_check(ctx, e, fields) or_return
			return result, .None
		}
		if record, declared := module_record_schema(ctx.index, ctx.bindings, e.type_name); declared {
			user_record_check(ctx, e, record) or_return
			return user_type_of(record.type_name, record.kind), .None
		}
		if record, is_structural := surface_structural_record(ctx.bindings, e.type_name); is_structural {
			user_record_check(ctx, e, record) or_return
			return user_type_of(record.type_name, record.kind), .None
		}
		return nil, .Unsupported_Expr
	}
	if record, declared := ctx_record_schema(ctx, e.type_name); declared {
		user_record_check(ctx, e, record) or_return
		return user_type_of(record.type_name, record.kind), .None
	}
	if env_declares(ctx.env, e.type_name) {
		return nil, .Unsupported_Expr
	}
	return nil, .Unresolved_Name
}

user_record_check :: proc(ctx: Check_Ctx, e: ^Record_Expr, schema: Record_Schema) -> Type_Error {
	for field in e.fields {
		declared, known := record_field_type(schema, field.name)
		if !known {
			return .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !types_compatible(got, declared) {
			return .Type_Mismatch
		}
	}
	return .None
}

engine_record_check :: proc(ctx: Check_Ctx, e: ^Record_Expr, fields: []Surface_Field) -> Type_Error {
	for field in e.fields {
		want, known := surface_field_type(fields, field.name)
		if !known {
			return .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !types_compatible(got, want) {
			return .Type_Mismatch
		}
	}
	return .None
}

ground_record_check :: proc(ctx: Check_Ctx, e: ^Record_Expr, allowed: []string) -> Type_Error {
	for field in e.fields {
		if !name_in_set(field.name, allowed) {
			return .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !is_ground(got, .Fixed) {
			return .Type_Mismatch
		}
	}
	return .None
}

name_in_set :: proc(name: string, set: []string) -> bool {
	for candidate in set {
		if candidate == name {
			return true
		}
	}
	return false
}

list_check :: proc(ctx: Check_Ctx, e: ^List_Expr) -> (type: Type, err: Type_Error) {
	element_type: Type
	for element in e.elements {
		got := expr_check(ctx, element) or_return
		if !types_compatible(element_type, got) {
			return nil, .Type_Mismatch
		}
		if element_type == nil {
			element_type = got
		}
	}
	return list_of(element_type), .None
}

with_check :: proc(ctx: Check_Ctx, e: ^With_Expr) -> (type: Type, err: Type_Error) {
	base := expr_check(ctx, e.base) or_return
	if engine, is_engine := base.(^Engine_Type); is_engine {
		_, fields, has_schema := surface_engine_record(engine_kind_name(engine.kind))
		if !has_schema {
			return nil, .Type_Mismatch
		}
		engine_record_check(ctx, e_with_as_record(e), fields) or_return
		return base, .None
	}
	user, is_user := base.(^User_Type)
	if !is_user {
		return nil, .Type_Mismatch
	}
	record, declared := ctx_record_schema(ctx, user.name)
	if !declared {
		return nil, .Type_Mismatch
	}
	for field in e.fields {
		want, known := record_field_type(record, field.name)
		if !known {
			return nil, .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !types_compatible(got, want) {
			return nil, .Type_Mismatch
		}
	}
	return base, .None
}

e_with_as_record :: proc(e: ^With_Expr) -> ^Record_Expr {
	adapter := new(Record_Expr, context.temp_allocator)
	adapter.fields = e.fields
	return adapter
}

match_check :: proc(ctx: Check_Ctx, e: ^Match_Expr) -> (type: Type, err: Type_Error) {
	ctx := ctx
	scrutinee := expr_check(ctx, e.scrutinee) or_return
	result: Type
	for arm in e.arms {
		check_pattern_arity(arm.pattern, scrutinee) or_return
		binders, types := pattern_binders(ctx.env, arm.pattern, scrutinee)
		saved := overlay_scope(&ctx.scope, binders, types)
		body, body_err := expr_check(ctx, arm.body)
		restore_scope(&ctx.scope, binders, saved)
		if body_err != .None {
			return nil, body_err
		}
		if !types_compatible(result, body) {
			return nil, .Type_Mismatch
		}
		if result == nil {
			result = body
		}
	}
	return result, .None
}

check_pattern_arity :: proc(pattern: Pattern, scrutinee: Type) -> Type_Error {
	if pattern.kind != .Tuple {
		return .None
	}
	tuple, is_tuple := scrutinee.(^Tuple_Type)
	if !is_tuple {
		return .None
	}
	if len(pattern.elements) != len(tuple.elements) {
		return .Tuple_Pattern_Arity
	}
	for sub, i in pattern.elements {
		check_pattern_arity(sub, tuple.elements[i]) or_return
	}
	return .None
}

pattern_binders :: proc(env: Type_Env, pattern: Pattern, scrutinee: Type) -> (names: []string, types: []Type) {
	out_names := make([dynamic]string, 0, 4, context.temp_allocator)
	out_types := make([dynamic]Type, 0, 4, context.temp_allocator)
	collect_pattern_binders(env, pattern, scrutinee, &out_names, &out_types)
	return out_names[:], out_types[:]
}

collect_pattern_binders :: proc(
	env: Type_Env,
	pattern: Pattern,
	scrutinee: Type,
	names: ^[dynamic]string,
	types: ^[dynamic]Type,
) {
	switch pattern.kind {
	case .Wildcard, .Bare_Variant:
	case .Bare_Binder:
		for binder in pattern.binders {
			append(names, binder)
			append(types, scrutinee)
		}
	case .Variant_Binds:
		position_type: Type
		if option, is_option := scrutinee.(^Option_Type); is_option {
			position_type = option.elem
		} else if schema, declared := env.enums[pattern.type_name]; declared {
			payload, _ := enum_variant_payload(schema, pattern.variant)
			position_type = payload
		}
		for sub in pattern.elements {
			collect_pattern_binders(env, sub, position_type, names, types)
		}
	case .Struct_Binds:
		_, payload_fields, has_schema := surface_struct_variant(pattern.type_name, pattern.variant)
		for binder in pattern.binders {
			binder_type: Type
			if has_schema {
				if field_type, known := surface_field_type(payload_fields, binder); known {
					binder_type = field_type
				}
			}
			append(names, binder)
			append(types, binder_type)
		}
	case .Tuple:
		tuple, is_tuple := scrutinee.(^Tuple_Type)
		for sub, i in pattern.elements {
			element: Type
			if is_tuple && i < len(tuple.elements) {
				element = tuple.elements[i]
			}
			collect_pattern_binders(env, sub, element, names, types)
		}
	}
}

call_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if member, is_method := e.callee.(^Member_Expr); is_method {
		return method_check(ctx, member, e)
	}
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, .Unsupported_Expr
	}
	if _, let_bound := ctx.scope[name.name]; let_bound {
		return nil, .Unsupported_Expr
	}
	if term, found := env_term_name(ctx.env, name.name); found {
		if (term.kind == .Fn || term.kind == .Query) && term.signature != nil {
			check_args(ctx, e, term.signature.params) or_return
			return term.signature.result, .None
		}
		return nil, .Unsupported_Expr
	}
	binding, found := ctx.bindings.names[name.name]
	if !found {
		return nil, .Unresolved_Name
	}
	if binding.kind == .Type_Name {
		if signature, is_command := surface_command(name.name); is_command {
			command := signature.(^Func_Type)
			check_args(ctx, e, command.params) or_return
			return command.result, .None
		}
		return nil, .Unsupported_Expr
	}
	if binding.kind != .Func {
		return nil, .Type_Mismatch
	}
	if signature, is_cross := module_call_signature(ctx.index, ctx.bindings, name.name); is_cross {
		check_args(ctx, e, signature.params) or_return
		return signature.result, .None
	}
	if comb_type, handled, comb_err := combinator_call_check(ctx, name.name, e); handled {
		return comb_type, comb_err
	}
	overloads, has_signature := surface_signatures(name.name)
	if !has_signature {
		return nil, .Unsupported_Expr
	}
	return overloads_check(ctx, e, overloads)
}

combinator_call_check :: proc(ctx: Check_Ctx, name: string, e: ^Call_Expr) -> (type: Type, handled: bool, err: Type_Error) {
	switch name {
	case "fold":
		t, fe := fold_check(ctx, e)
		return t, true, fe
	case "first":
		t, fe := first_check(ctx, e)
		return t, true, fe
	case "find":
		t, fe := find_check(ctx, e)
		return t, true, fe
	case "last":
		t, le := last_check(ctx, e)
		return t, true, le
	case "neighbors":
		t, ne := neighbors_check(ctx, e)
		return t, true, ne
	case "in_bounds":
		t, ie := in_bounds_check(ctx, e)
		return t, true, ie
	case "within":
		t, we := spatial_combinator_check(ctx, e, true)
		return t, true, we
	case "nearest_first":
		t, ne := spatial_combinator_check(ctx, e, false)
		return t, true, ne
	case "or_else":
		t, oe := or_else_check(ctx, e)
		return t, true, oe
	case "is_some":
		t, ie := is_some_check(ctx, e)
		return t, true, ie
	case "map":
		t, me := map_check(ctx, e)
		return t, true, me
	case "filter":
		t, fe := filter_check(ctx, e)
		return t, true, fe
	case "concat":
		t, ce := concat_check(ctx, e)
		return t, true, ce
	case "contains":
		t, ce := contains_check(ctx, e)
		return t, true, ce
	case "prepend":
		t, pe := prepend_check(ctx, e)
		return t, true, pe
	case "append":
		t, ae := append_check(ctx, e)
		return t, true, ae
	case "reverse":
		t, re := reverse_check(ctx, e)
		return t, true, re
	case "init":
		t, ie := init_check(ctx, e)
		return t, true, ie
	case "is_empty":
		t, ie := is_empty_check(ctx, e)
		return t, true, ie
	case "len":
		t, le := len_check(ctx, e)
		return t, true, le
	case "get":
		t, ge := get_check(ctx, e)
		return t, true, ge
	case "empty":
		t, ee := map_empty_check(ctx, e)
		return t, true, ee
	case "has":
		t, he := map_has_check(ctx, e)
		return t, true, he
	case "set":
		t, se := map_set_check(ctx, e)
		return t, true, se
	case "remove":
		t, re := map_remove_check(ctx, e)
		return t, true, re
	case "keys":
		t, ke := map_keys_check(ctx, e)
		return t, true, ke
	case "values":
		t, ve := map_values_check(ctx, e)
		return t, true, ve
	case "pick":
		t, pe := pick_check(ctx, e)
		return t, true, pe
	case "grid_cells":
		t, ge := grid_cells_check(ctx, e)
		return t, true, ge
	}
	return nil, false, .None
}

is_combinator_name :: proc(name: string) -> bool {
	switch name {
	case "fold", "first", "find", "last", "neighbors", "in_bounds", "within",
	     "nearest_first", "or_else", "is_some", "map", "filter", "concat", "contains",
	     "prepend", "append", "reverse", "init", "is_empty", "len", "get",
	     "empty", "has", "set", "remove", "keys", "values", "pick", "grid_cells":
		return true
	}
	return false
}

map_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	result := combinator_result(ctx, e.args[1], {elem}) or_return
	return list_of(result), .None
}

filter_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	combinator_check(ctx, e.args[1], {elem}, Ground_Type.Bool) or_return
	return list_of(elem), .None
}

concat_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	left := expr_check(ctx, e.args[0]) or_return
	right := expr_check(ctx, e.args[1]) or_return
	left_list, left_ok := left.(^List_Type)
	right_list, right_ok := right.(^List_Type)
	if !left_ok || !right_ok {
		return nil, .Type_Mismatch
	}
	if !types_compatible(left_list.elem, right_list.elem) {
		return nil, .Type_Mismatch
	}
	elem := left_list.elem
	if elem == nil {
		elem = right_list.elem
	}
	return list_of(elem), .None
}

contains_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	list_type := expr_check(ctx, e.args[0]) or_return
	value := expr_check(ctx, e.args[1]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	if !types_compatible(list.elem, value) {
		return nil, .Type_Mismatch
	}
	return Ground_Type.Bool, .None
}

prepend_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	value := expr_check(ctx, e.args[0]) or_return
	list_type := expr_check(ctx, e.args[1]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	if !types_compatible(list.elem, value) {
		return nil, .Type_Mismatch
	}
	elem := list.elem
	if elem == nil {
		elem = value
	}
	return list_of(elem), .None
}

init_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	list_type := expr_check(ctx, e.args[0]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	return list_of(list.elem), .None
}

append_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	list_type := expr_check(ctx, e.args[0]) or_return
	value := expr_check(ctx, e.args[1]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	if !types_compatible(list.elem, value) {
		return nil, .Type_Mismatch
	}
	elem := list.elem
	if elem == nil {
		elem = value
	}
	return list_of(elem), .None
}

reverse_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	list_type := expr_check(ctx, e.args[0]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	return list_of(list.elem), .None
}

is_empty_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	if _, ok := source_element(source); !ok {
		return nil, .Type_Mismatch
	}
	return Ground_Type.Bool, .None
}

len_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	if _, is_map := source.(^Map_Type); is_map {
		return Ground_Type.Int, .None
	}
	if _, ok := source_element(source); !ok {
		return nil, .Type_Mismatch
	}
	return Ground_Type.Int, .None
}

get_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	if m, is_map := source.(^Map_Type); is_map {
		key := expr_check(ctx, e.args[1]) or_return
		if !types_compatible(m.key, key) {
			return nil, .Type_Mismatch
		}
		return option_of(m.value), .None
	}
	index := expr_check(ctx, e.args[1]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	if !is_ground(index, .Int) {
		return nil, .Type_Mismatch
	}
	return option_of(elem), .None
}

map_unify_param :: proc(param, arg: Type) -> (unified: Type, ok: bool) {
	if !types_compatible(param, arg) {
		return nil, false
	}
	if param != nil {
		return param, true
	}
	return arg, true
}

map_empty_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 0 {
		return nil, .Type_Mismatch
	}
	return map_of(nil, nil), .None
}

map_has_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	m, is_map := source.(^Map_Type)
	if !is_map {
		return nil, .Type_Mismatch
	}
	key := expr_check(ctx, e.args[1]) or_return
	if !types_compatible(m.key, key) {
		return nil, .Type_Mismatch
	}
	return Ground_Type.Bool, .None
}

map_set_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 3 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	m, is_map := source.(^Map_Type)
	if !is_map {
		return nil, .Type_Mismatch
	}
	key := expr_check(ctx, e.args[1]) or_return
	value := expr_check(ctx, e.args[2]) or_return
	new_key, key_ok := map_unify_param(m.key, key)
	if !key_ok {
		return nil, .Type_Mismatch
	}
	new_value, value_ok := map_unify_param(m.value, value)
	if !value_ok {
		return nil, .Type_Mismatch
	}
	return map_of(new_key, new_value), .None
}

map_remove_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	m, is_map := source.(^Map_Type)
	if !is_map {
		return nil, .Type_Mismatch
	}
	key := expr_check(ctx, e.args[1]) or_return
	if !types_compatible(m.key, key) {
		return nil, .Type_Mismatch
	}
	return map_of(m.key, m.value), .None
}

map_keys_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	m, is_map := source.(^Map_Type)
	if !is_map {
		return nil, .Type_Mismatch
	}
	return list_of(m.key), .None
}

map_values_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	m, is_map := source.(^Map_Type)
	if !is_map {
		return nil, .Type_Mismatch
	}
	return list_of(m.value), .None
}

pick_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	rng := expr_check(ctx, e.args[0]) or_return
	list_type := expr_check(ctx, e.args[1]) or_return
	if !is_engine(rng, .Rng) {
		return nil, .Type_Mismatch
	}
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	return tuple_of({option_of(list.elem), engine_type_of(.Rng)}), .None
}

grid_cells_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) == 1 {
		size := expr_check(ctx, e.args[0]) or_return
		if !is_cell_shaped(ctx, size) {
			return nil, .Type_Mismatch
		}
		return list_of(size), .None
	}
	if len(e.args) != 3 {
		return nil, .Type_Mismatch
	}
	width := expr_check(ctx, e.args[0]) or_return
	height := expr_check(ctx, e.args[1]) or_return
	if !is_ground(width, .Int) || !is_ground(height, .Int) {
		return nil, .Type_Mismatch
	}
	cell := combinator_result(ctx, e.args[2], {Ground_Type.Int, Ground_Type.Int}) or_return
	return list_of(cell), .None
}

is_cell_shaped :: proc(ctx: Check_Ctx, t: Type) -> bool {
	user, is_user := t.(^User_Type)
	if !is_user {
		return false
	}
	schema, found := ctx_record_schema(ctx, user.name)
	if !found || len(schema.fields) != 2 {
		return false
	}
	x_type, has_x := record_field_type(schema, "x")
	y_type, has_y := record_field_type(schema, "y")
	return has_x && has_y && is_ground(x_type, .Int) && is_ground(y_type, .Int)
}

combinator_result :: proc(ctx: Check_Ctx, arg: Expr, params: []Type) -> (result: Type, err: Type_Error) {
	ctx := ctx
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		if len(lambda.params) != len(params) {
			return nil, .Type_Mismatch
		}
		saved := overlay_scope(&ctx.scope, lambda.params, params)
		body, body_err := expr_check(ctx, lambda.body)
		restore_scope(&ctx.scope, lambda.params, saved)
		if body_err != .None {
			return nil, body_err
		}
		return body, .None
	}
	got := expr_check(ctx, arg) or_return
	func, is_func := got.(^Func_Type)
	if !is_func {
		return nil, .Type_Mismatch
	}
	return func.result, .None
}

fold_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 3 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	init := expr_check(ctx, e.args[1]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	combinator_check(ctx, e.args[2], {init, elem}, init) or_return
	return init, .None
}

first_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) == 1 {
		source := expr_check(ctx, e.args[0]) or_return
		elem, ok := source_element(source)
		if !ok {
			return nil, .Type_Mismatch
		}
		return option_of(elem), .None
	}
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	combinator_check(ctx, e.args[1], {elem}, Ground_Type.Bool) or_return
	return option_of(elem), .None
}

find_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	combinator_check(ctx, e.args[1], {elem}, Ground_Type.Bool) or_return
	return option_of(elem), .None
}

last_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	return option_of(elem), .None
}

neighbors_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	cell := expr_check(ctx, e.args[0]) or_return
	if !cell_shaped_or_unknown(ctx, cell) {
		return nil, .Type_Mismatch
	}
	return list_of(cell), .None
}

in_bounds_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	cell := expr_check(ctx, e.args[0]) or_return
	size := expr_check(ctx, e.args[1]) or_return
	if !cell_shaped_or_unknown(ctx, cell) || !cell_shaped_or_unknown(ctx, size) {
		return nil, .Type_Mismatch
	}
	return Ground_Type.Bool, .None
}

cell_shaped_or_unknown :: proc(ctx: Check_Ctx, t: Type) -> bool {
	return t == nil || is_cell_shaped(ctx, t)
}

or_else_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	opt_type := expr_check(ctx, e.args[0]) or_return
	fallback := expr_check(ctx, e.args[1]) or_return
	option, is_option := opt_type.(^Option_Type)
	if !is_option {
		return nil, .Type_Mismatch
	}
	if !types_compatible(option.elem, fallback) {
		return nil, .Type_Mismatch
	}
	return fallback, .None
}

is_some_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	opt_type := expr_check(ctx, e.args[0]) or_return
	if _, is_option := opt_type.(^Option_Type); !is_option {
		return nil, .Type_Mismatch
	}
	return Ground_Type.Bool, .None
}

spatial_combinator_check :: proc(ctx: Check_Ctx, e: ^Call_Expr, with_radius: bool) -> (type: Type, err: Type_Error) {
	arity := with_radius ? 3 : 2
	if len(e.args) != arity {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, elem_ok := source_element(source)
	if !elem_ok {
		return nil, .Type_Mismatch
	}
	thing, is_user := elem.(^User_Type)
	if !is_user || thing.kind != .Thing {
		return nil, .Type_Mismatch
	}
	field, resolve_err := spatial_requirement_field(ctx, thing.name)
	if resolve_err != .None {
		return nil, resolve_err
	}
	field_type, has_field := thing_field_type(ctx.env, thing.name, field)
	if !has_field || !is_vector_ground(field_type) {
		return nil, .Type_Mismatch
	}
	origin := expr_check(ctx, e.args[1]) or_return
	if !types_compatible(origin, field_type) {
		return nil, .Type_Mismatch
	}
	if with_radius {
		radius := expr_check(ctx, e.args[2]) or_return
		if !is_ground(radius, .Fixed) {
			return nil, .Type_Mismatch
		}
	}
	return list_of(elem), .None
}

spatial_requirement_field :: proc(ctx: Check_Ctx, thing: string) -> (field: string, err: Type_Error) {
	found := false
	for directive in ctx.query_indexes {
		if directive.kind != .Spatial || directive.thing != thing {
			continue
		}
		if found {
			return "", .Spatial_Requirement_Ambiguous
		}
		field = directive.field
		found = true
	}
	if !found {
		return "", .Spatial_Requirement_Missing
	}
	return field, .None
}

thing_field_type :: proc(env: Type_Env, thing: string, field: string) -> (type: Type, ok: bool) {
	record, declared := env.records[thing]
	if !declared {
		return nil, false
	}
	for schema_field in record.fields {
		if schema_field.name == field {
			return schema_field.type, true
		}
	}
	return nil, false
}

source_element :: proc(source: Type) -> (elem: Type, ok: bool) {
	if view, is_view := source.(^Engine_Type); is_view && view.kind == .View {
		return view.elem, true
	}
	if list, is_list := source.(^List_Type); is_list {
		return list.elem, true
	}
	return nil, false
}

combinator_check :: proc(ctx: Check_Ctx, arg: Expr, params: []Type, result: Type) -> Type_Error {
	ctx := ctx
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		if len(lambda.params) != len(params) {
			return .Type_Mismatch
		}
		saved := overlay_scope(&ctx.scope, lambda.params, params)
		body, body_err := expr_check(ctx, lambda.body)
		restore_scope(&ctx.scope, lambda.params, saved)
		if body_err != .None {
			return body_err
		}
		if !types_compatible(body, result) {
			return .Type_Mismatch
		}
		return .None
	}
	got := expr_check(ctx, arg) or_return
	if !types_compatible(got, func_of(params, result)) {
		return .Type_Mismatch
	}
	return .None
}

Saved_Binding :: struct {
	type:    Type,
	present: bool,
}

overlay_scope :: proc(scope: ^Scope, names: []string, types: []Type) -> []Saved_Binding {
	saved := make([]Saved_Binding, len(names), context.temp_allocator)
	for name, i in names {
		prior, present := scope[name]
		saved[i] = Saved_Binding{type = prior, present = present}
		scope[name] = types[i]
	}
	return saved
}

restore_scope :: proc(scope: ^Scope, names: []string, saved: []Saved_Binding) {
	for name, i in names {
		if saved[i].present {
			scope[name] = saved[i].type
		} else {
			delete_key(scope, name)
		}
	}
}

overloads_check :: proc(ctx: Check_Ctx, e: ^Call_Expr, overloads: []Type) -> (type: Type, err: Type_Error) {
	args := make([]Type, len(e.args), context.temp_allocator)
	for arg, i in e.args {
		args[i] = expr_check(ctx, arg) or_return
	}
	for overload in overloads {
		signature, is_func := overload.(^Func_Type)
		if !is_func || len(signature.params) != len(args) {
			continue
		}
		matches := true
		for want, i in signature.params {
			if !types_compatible(args[i], want) {
				matches = false
				break
			}
		}
		if matches {
			return signature.result, .None
		}
	}
	return nil, .Type_Mismatch
}

check_args :: proc(ctx: Check_Ctx, e: ^Call_Expr, signature: []Type) -> Type_Error {
	if len(e.args) != len(signature) {
		return .Type_Mismatch
	}
	for want, i in signature {
		if func, is_func := want.(^Func_Type); is_func && func.params != nil {
			if _, is_lambda := e.args[i].(^Lambda_Expr); is_lambda {
				combinator_check(ctx, e.args[i], func.params, func.result) or_return
				continue
			}
		}
		got := expr_check(ctx, e.args[i]) or_return
		if !types_compatible(got, want) {
			return .Type_Mismatch
		}
	}
	return .None
}

method_check :: proc(ctx: Check_Ctx, callee: ^Member_Expr, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if recv, is_name := callee.receiver.(^Name_Expr); is_name {
		if _, in_scope := ctx.scope[recv.name]; !in_scope {
			if static, handled, static_err := static_method_check(ctx, recv.name, callee.member, e); handled {
				return static, static_err
			}
		}
	}
	receiver := expr_check(ctx, callee.receiver) or_return
	type, err = value_method_check(ctx, receiver, callee.member, e)
	if err == .Unsupported_Expr && is_stdlib_free_fn(callee.member) {
		return call_check(ctx, stdlib_ufcs_call(callee, e.args, e.line, e.col))
	}
	if err == .Unsupported_Expr {
		stamp_member(ctx, callee, surface_methods_for_receiver(receiver))
		return nil, .Unknown_Method
	}
	return type, err
}

is_stdlib_free_fn :: proc(name: string) -> bool {
	if is_combinator_name(name) {
		return true
	}
	if _, found := surface_signatures(name); found {
		return true
	}
	if _, found := surface_command(name); found {
		return true
	}
	return false
}

stdlib_ufcs_call :: proc(callee: ^Member_Expr, member_args: []Expr, line: int, col: int) -> ^Call_Expr {
	name := new(Name_Expr, context.temp_allocator)
	name^ = Name_Expr{name = callee.member, line = callee.line, col = callee.col}
	args := make([]Expr, len(member_args) + 1, context.temp_allocator)
	args[0] = callee.receiver
	copy(args[1:], member_args)
	call := new(Call_Expr, context.temp_allocator)
	call^ = Call_Expr{callee = name, args = args, line = line, col = col}
	return call
}

static_method_check :: proc(
	ctx: Check_Ctx,
	recv_name: string,
	member: string,
	e: ^Call_Expr,
) -> (
	type: Type,
	handled: bool,
	err: Type_Error,
) {
	if term, found := env_term_name(ctx.env, recv_name); found {
		if term.kind == .Behavior && member == "step" && term.signature != nil {
			if arg_err := check_args(ctx, e, term.signature.params); arg_err != .None {
				return nil, true, arg_err
			}
			return term.signature.result, true, .None
		}
		return nil, true, .Unsupported_Expr
	}
	binding, imported := ctx.bindings.names[recv_name]
	if !imported || binding.kind != .Type_Name {
		return nil, false, .None
	}
	if static, found := surface_static_method(recv_name, member); found {
		signature := static.(^Func_Type)
		if arg_err := check_args(ctx, e, signature.params); arg_err != .None {
			return nil, true, arg_err
		}
		return signature.result, true, .None
	}
	associated, declared := surface_associated(recv_name, member)
	if !declared {
		return nil, true, .Unsupported_Expr
	}
	signature, is_constructor := associated.(^Func_Type)
	if !is_constructor {
		return nil, true, .Unsupported_Expr
	}
	if arg_err := check_args(ctx, e, signature.params); arg_err != .None {
		return nil, true, arg_err
	}
	return signature.result, true, .None
}

value_method_check :: proc(ctx: Check_Ctx, receiver: Type, member: string, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if ufcs, handled, ufcs_err := ufcs_method_check(ctx, receiver, member, e); handled {
		return ufcs, ufcs_err
	}
	if engine, is_engine := receiver.(^Engine_Type); is_engine {
		if engine.kind == .View && member == "map" {
			return view_map_check(ctx, engine, e)
		}
		if signature, found := surface_engine_method(engine, member); found {
			method := signature.(^Func_Type)
			check_args(ctx, e, method.params) or_return
			return method.result, .None
		}
		return nil, .Unsupported_Expr
	}
	method, declared := surface_method(receiver, member)
	if !declared {
		return nil, .Unsupported_Expr
	}
	signature, is_func := method.(^Func_Type)
	if !is_func {
		return nil, .Unsupported_Expr
	}
	check_args(ctx, e, signature.params) or_return
	return signature.result, .None
}

ufcs_method_check :: proc(ctx: Check_Ctx, receiver: Type, member: string, e: ^Call_Expr) -> (type: Type, handled: bool, err: Type_Error) {
	term, found := env_term_name(ctx.env, member)
	if !found || term.kind != .Fn || term.signature == nil || len(term.signature.params) == 0 {
		return nil, false, .None
	}
	if !types_compatible(receiver, term.signature.params[0]) {
		return nil, false, .None
	}
	tail := term.signature.params[1:]
	if len(e.args) != len(tail) {
		return nil, true, .Type_Mismatch
	}
	for want, i in tail {
		got := expr_check(ctx, e.args[i]) or_return
		if !types_compatible(got, want) {
			return nil, true, .Type_Mismatch
		}
	}
	return term.signature.result, true, .None
}

view_map_check :: proc(ctx: Check_Ctx, view: ^Engine_Type, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	result := combinator_result(ctx, e.args[0], {view.elem}) or_return
	return engine_type_of(.View, result), .None
}

variant_check :: proc(ctx: Check_Ctx, e: ^Variant_Expr) -> (type: Type, err: Type_Error) {
	if e.has_fields {
		return struct_variant_check(ctx, e)
	}
	if binding, imported := ctx.bindings.names[e.type_name]; imported {
		if binding.kind != .Type_Name {
			return nil, .Unsupported_Expr
		}
		if e.type_name == "Option" {
			return option_variant_check(ctx, e)
		}
		if e.type_name == "Result" {
			return result_variant_check(ctx, e)
		}
		if engine, found := surface_enum_variant(e.type_name, e.variant); found {
			if e.has_payload {
				return nil, .Unsupported_Expr
			}
			return engine, .None
		}
		if enum_schema, found := module_enum_schema(ctx.index, ctx.bindings, e.type_name); found {
			return enum_variant_value_check(ctx, e, enum_schema)
		}
		return nil, .Unsupported_Expr
	}
	if enum_schema, declared := ctx.env.enums[e.type_name]; declared {
		return enum_variant_value_check(ctx, e, enum_schema)
	}
	if env_declares(ctx.env, e.type_name) {
		return nil, .Unsupported_Expr
	}
	return nil, .Unresolved_Name
}

enum_variant_value_check :: proc(ctx: Check_Ctx, e: ^Variant_Expr, enum_schema: Enum_Schema) -> (type: Type, err: Type_Error) {
	if !name_in_set(e.variant, enum_schema.variants) {
		return nil, .Type_Mismatch
	}
	payload, has_payload := enum_variant_payload(enum_schema, e.variant)
	enum_type := user_type_of(e.type_name, .Enum)
	if e.has_payload {
		if !has_payload || len(e.payload) != 1 {
			return nil, .Type_Mismatch
		}
		arg := expr_check(ctx, e.payload[0]) or_return
		if !types_compatible(arg, payload) {
			return nil, .Type_Mismatch
		}
		return enum_type, .None
	}
	if has_payload {
		return func_of({payload}, enum_type), .None
	}
	return enum_type, .None
}

option_variant_check :: proc(ctx: Check_Ctx, e: ^Variant_Expr) -> (type: Type, err: Type_Error) {
	switch e.variant {
	case "Some":
		if !e.has_payload || len(e.payload) != 1 {
			return nil, .Unsupported_Expr
		}
		payload := expr_check(ctx, e.payload[0]) or_return
		return option_of(payload), .None
	case "None":
		if e.has_payload {
			return nil, .Unsupported_Expr
		}
		return option_of(nil), .None
	}
	return nil, .Unsupported_Expr
}

result_variant_check :: proc(ctx: Check_Ctx, e: ^Variant_Expr) -> (type: Type, err: Type_Error) {
	switch e.variant {
	case "Ok", "Err":
		if !e.has_payload || len(e.payload) != 1 {
			return nil, .Unsupported_Expr
		}
		expr_check(ctx, e.payload[0]) or_return
		return engine_type_of(.Result), .None
	}
	return nil, .Unsupported_Expr
}

struct_variant_check :: proc(ctx: Check_Ctx, e: ^Variant_Expr) -> (type: Type, err: Type_Error) {
	result, fields, found := surface_struct_variant(e.type_name, e.variant)
	if !found {
		return nil, .Unsupported_Expr
	}
	for field in e.fields {
		want, known := surface_field_type(fields, field.name)
		if !known {
			return nil, .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !types_compatible(got, want) {
			return nil, .Type_Mismatch
		}
	}
	return result, .None
}

surface_field_type :: proc(fields: []Surface_Field, name: string) -> (type: Type, found: bool) {
	for field in fields {
		if field.name == name {
			return field.type, true
		}
	}
	return nil, false
}
