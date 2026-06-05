// Typecheck for the §06/§07 gameplay surface and the evaluable numeric
// domain alike: every free name binds to exactly one declaration — a
// let/param binding, a user thing/data/enum/signal/fn/behavior, or an
// imported surface member (spec §02: one name, one meaning) — and an
// unresolved name is a compile error, never a fallback. There is no
// implicit promotion (spec §10): equality and arithmetic demand same-typed
// sides, and the Int → Fixed lift is the explicit to_fixed call.
//
// The pass runs in two sweeps over the resolved environment (resolve.odin):
// the body sweep types every top-level fn body and behavior step body
// against its parameters — a behavior's params are its reads, its return is
// its writes (spec §06 §3) — and the test sweep types each test block,
// including the §04 `name.step(args)` behavior-invocation form. Both sweeps
// share expr_check. Types are the parameterized model in type.odin; the
// engine/stdlib types the value kernel does not ground (View[T], Spawn,
// Draw, Input, Time, Bindings, the engine enums) carry nominal Engine_Type
// handles, with the axis-role and axis-source boundaries staying the nil
// unknown the typing pass cannot ground further.
package funpack

Type_Error :: enum {
	None,
	Assert_Not_Bool,  // an assert whose expression is not Bool-typed
	Type_Mismatch,    // differently-typed sides — no implicit promotion
	Unsupported_Expr, // a parsed form outside the typeable domain
	Unknown_Module,   // an import naming a module outside the surface
	Unknown_Member,   // an import naming a member its module lacks
	Unresolved_Name,  // a free name with no let binding, no user decl, and no import
	Name_Collision,   // one name, two meanings (spec §02): a user decl colliding with an import or another user decl, or two imports binding one name to different declarations
}

// Scope maps a body's or test block's bound names to their checked types —
// fn/step parameters, let bindings, lambda parameters, and match-arm payload
// binders. Lookups only — nothing iterates the map.
Scope :: map[string]Type

// Check_Ctx threads the file-level import resolutions, the resolved
// user-declaration environment (resolve.odin), and the current scope through
// expression checking. expected_return is the body sweep's declared `-> R`
// type, against which a `return`/`if`-arm `return` is checked; it is nil in
// the test sweep, where statements are let/assert with no return. Every map
// is lookup-only below stage_typecheck.
Check_Ctx :: struct {
	bindings:        Bindings,
	env:             Type_Env,
	scope:           Scope,
	expected_return: Type,
}

stage_typecheck :: proc(ast: Ast) -> (typed: Typed_Ast, err: Type_Error) {
	bindings := resolve_imports(ast) or_return
	env := resolve_env(ast, bindings) or_return
	check_bodies(bindings, env, ast) or_return
	check_tests(bindings, env, ast) or_return
	return Typed_Ast{ast = ast, bindings = bindings, env = env}, .None
}

// check_bodies types every top-level fn body and behavior step body against
// its parameters (spec §06 §3: a behavior's params are its reads, its return
// its writes). bindings()/setup() are top-level fns, so they ride this sweep.
check_bodies :: proc(bindings: Bindings, env: Type_Env, ast: Ast) -> Type_Error {
	for fn in ast.fns {
		check_fn_body(bindings, env, fn) or_return
	}
	for behavior in ast.behaviors {
		check_fn_body(bindings, env, behavior.step) or_return
	}
	return .None
}

// check_fn_body types one fn/step body: it seeds a scope with the declared
// parameters as their resolved types, threads the declared return type as the
// body's expected_return, and types the statement sequence.
check_fn_body :: proc(bindings: Bindings, env: Type_Env, fn: Fn_Node) -> Type_Error {
	ctx := Check_Ctx {
		bindings        = bindings,
		env             = env,
		scope           = make(Scope, context.temp_allocator),
		expected_return = resolve_type_ref(env, bindings, fn.return_type),
	}
	for param in fn.params {
		ctx.scope[param.name] = resolve_type_ref(env, bindings, param.type)
	}
	return check_statements(ctx, fn.body)
}

// check_statements types a fn-body statement sequence: a let binds its
// inferred type into the scope, a return is checked against the body's
// expected return type, and an if early-return guard checks its condition is
// Bool and its guarded block under the same expected return.
check_statements :: proc(ctx: Check_Ctx, body: []Statement) -> Type_Error {
	ctx := ctx
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			type := expr_check(ctx, node.value) or_return
			ctx.scope[node.name] = type
		case Return_Node:
			value := expr_check(ctx, node.value) or_return
			if !types_compatible(value, ctx.expected_return) {
				return .Type_Mismatch
			}
		case If_Node:
			cond := expr_check(ctx, node.cond) or_return
			if !is_ground(cond, .Bool) {
				return .Type_Mismatch
			}
			check_statements(ctx, node.body) or_return
		case Assert_Node:
			// An assert is a test-block statement; a fn body never holds one.
		}
	}
	return .None
}

// check_tests types every test block: a let binds its inferred type, an
// assert demands a Bool expression. The §04 name.step form and the closed
// return-form literals reach the same expr_check the bodies use.
check_tests :: proc(bindings: Bindings, env: Type_Env, ast: Ast) -> Type_Error {
	for test in ast.tests {
		ctx := Check_Ctx{bindings = bindings, env = env, scope = make(Scope, context.temp_allocator)}
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				type := expr_check(ctx, node.value) or_return
				ctx.scope[node.name] = type
			case Assert_Node:
				check_assert(ctx, node) or_return
			case Return_Node, If_Node:
				// Return/If are fn-body statements, never present in a test
				// block — the only statement sequence this sweep checks.
			}
		}
	}
	return .None
}

check_assert :: proc(ctx: Check_Ctx, node: Assert_Node) -> Type_Error {
	type := expr_check(ctx, node.expr) or_return
	if !is_ground(type, .Bool) {
		return .Assert_Not_Bool
	}
	return .None
}

expr_check :: proc(ctx: Check_Ctx, expr: Expr) -> (type: Type, err: Type_Error) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return Ground_Type.Int, .None
	case ^Fixed_Lit_Expr:
		return Ground_Type.Fixed, .None
	case ^String_Lit_Expr:
		// A string literal types as the engine String regardless of its
		// interpolation holes (spec §02 §2: the holes are retained verbatim;
		// splitting them is a lowering concern, not typing).
		return engine_type_of(.String), .None
	case ^Name_Expr:
		return name_check(ctx, e)
	case ^Unary_Expr:
		if e.op.kind != .Minus {
			return nil, .Unsupported_Expr
		}
		operand := expr_check(ctx, e.operand) or_return
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
		// Outside combinator position a lambda has no expected type to
		// infer params from — the opaque placeholder signature.
		return func_of(nil, nil), .None
	case ^Call_Expr:
		return call_check(ctx, e)
	case ^Variant_Expr:
		return variant_check(ctx, e)
	case ^With_Expr:
		return with_check(ctx, e)
	case ^Match_Expr:
		return match_check(ctx, e)
	}
	return nil, .Unsupported_Expr
}

// name_check types a bare name use: a scope binding (param/let/binder) first,
// then a module-let constant or top-level fn through the user environment,
// then an imported value constant. A type-position name or a behavior name is
// not a value on its own (it is only meaningful as a constructor head,
// variant head, or `.step` receiver), so it is Unsupported_Expr; a name no
// partition claims is Unresolved_Name.
name_check :: proc(ctx: Check_Ctx, e: ^Name_Expr) -> (type: Type, err: Type_Error) {
	if bound, found := ctx.scope[e.name]; found {
		return bound, .None
	}
	if term, found := env_term_name(ctx.env, e.name); found {
		#partial switch term.kind {
		case .Const:
			return term.type, .None
		case .Fn:
			// A bare fn name is a function value — its signature, the form
			// fold's accumulator argument (add_goal) takes.
			return term.signature, .None
		case .Behavior:
			// A behavior is only meaningful through its `.step` receiver.
			return nil, .Unsupported_Expr
		}
	}
	if binding, found := ctx.bindings.names[e.name]; found {
		if binding.kind == .Value {
			if value_type, typed := surface_value_type(e.name); typed {
				return value_type, .None
			}
		}
		// A type, module, or bare function name is not a value.
		return nil, .Unsupported_Expr
	}
	if env_declares(ctx.env, e.name) {
		// A type-position user name (a record/enum) binds but is not a value.
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
		// Ordering compares two same-typed numeric sides into a Bool.
		if !is_numeric_ground(lhs) || !types_compatible(lhs, rhs) {
			return nil, .Type_Mismatch
		}
		return Ground_Type.Bool, .None
	case .Plus, .Minus, .Star, .Slash, .Percent:
		// Arithmetic admits two same-typed numeric scalars, or a vector with
		// a numeric side (Vec2 * Fixed, Vec2 + Vec2) the kernel lowers — the
		// pong `advance` helper's `vel * dt` and `at + vel*dt`.
		return arithmetic_check(lhs, rhs)
	case .Ident:
		// `and`/`or` ride as Ident tokens; both sides must be Bool.
		if e.op.text == "and" || e.op.text == "or" {
			if !is_ground(lhs, .Bool) || !is_ground(rhs, .Bool) {
				return nil, .Type_Mismatch
			}
			return Ground_Type.Bool, .None
		}
	}
	return nil, .Unsupported_Expr
}

// arithmetic_check types `a op b` for the numeric and vector-numeric forms
// the §10 kernel lowers: two same-typed numeric scalars, a vector with a
// matching vector, or a vector scaled by a numeric scalar on either side.
// There is no Int→Fixed promotion — the two scalar sides must already agree.
arithmetic_check :: proc(lhs, rhs: Type) -> (type: Type, err: Type_Error) {
	if is_numeric_ground(lhs) && types_compatible(lhs, rhs) {
		return lhs, .None
	}
	if is_vector_ground(lhs) {
		if types_compatible(lhs, rhs) {
			return lhs, .None
		}
		// A vector scaled by a fixed scalar keeps the vector type.
		if is_ground(rhs, .Fixed) {
			return lhs, .None
		}
	}
	if is_vector_ground(rhs) && is_ground(lhs, .Fixed) {
		return rhs, .None
	}
	return nil, .Type_Mismatch
}

// member_check types `receiver.member`: a value receiver exposes its fields
// (a user record's schema field, a Vec2/Vec3 component, an engine resource's
// member), while a Type-name receiver resolved through the surface selects an
// associated constant (Fixed.MAX, Quat.identity).
member_check :: proc(ctx: Check_Ctx, e: ^Member_Expr) -> (type: Type, err: Type_Error) {
	if recv, is_name := e.receiver.(^Name_Expr); is_name {
		// A Type-name receiver imported through the surface selects an
		// associated constant before any value path.
		if _, in_scope := ctx.scope[recv.name]; !in_scope {
			if _, is_term := env_term_name(ctx.env, recv.name); !is_term {
				if binding, imported := ctx.bindings.names[recv.name]; imported && binding.kind == .Type_Name {
					return associated_member(recv.name, e.member)
				}
			}
		}
	}
	// Every other receiver is a value: type it, then read the member off its
	// type.
	receiver := expr_check(ctx, e.receiver) or_return
	return field_member(ctx, receiver, e.member)
}

// associated_member types a Type-name receiver's associated constant (a
// constructor is only meaningful applied, so it is Unsupported_Expr here).
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

// field_member reads a member off a value's type: a user record's declared
// field, a Vec2/Vec3 component, or an engine resource's member (Time.dt).
field_member :: proc(ctx: Check_Ctx, receiver: Type, member: string) -> (type: Type, err: Type_Error) {
	switch r in receiver {
	case ^User_Type:
		if record, found := ctx.env.records[r.name]; found {
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
		return nil, .Type_Mismatch
	case ^Option_Type, ^List_Type, ^Func_Type:
		return nil, .Type_Mismatch
	}
	return nil, .Unsupported_Expr
}

// record_field_type reads a declared field's type from a record schema by
// name — a linear lookup, so field order never reaches the verdict.
record_field_type :: proc(schema: Record_Schema, name: string) -> (type: Type, found: bool) {
	for field in schema.fields {
		if field.name == name {
			return field.type, true
		}
	}
	return nil, false
}

// record_check types a record literal: Vec2/Vec3 lower to their ground type
// with Fixed components, and a user thing/data/signal literal checks each
// field value against its declared schema type and yields the record's
// nominal handle.
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
		return nil, .Unsupported_Expr
	}
	if record, declared := ctx.env.records[e.type_name]; declared {
		user_record_check(ctx, e, record) or_return
		return user_type_of(record.type_name, record.kind), .None
	}
	if env_declares(ctx.env, e.type_name) {
		return nil, .Unsupported_Expr
	}
	return nil, .Unresolved_Name
}

// user_record_check checks each field value of a user record literal against
// its declared schema type and demands every named field belong to the
// schema. A missing required field is not rejected here — defaults make a
// field omittable (spec §03 §1), and field presence is a downstream concern.
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

// ground_record_check demands every field name belong to the engine ground
// record's component set and every component expression be Fixed.
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

// list_check types a list literal: every element must agree, and the element
// type is the first concrete one (nil for the empty list). The closed §04
// return-form lists ([Spawn], [Draw], [Goal]) are list literals whose element
// type the typing pass infers from their constructors.
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

// with_check types a record-update `base with { field: v, … }` (spec §02 §5):
// the base must be a user record, every updated field must belong to its
// schema, every value must match the field's declared type, and the result is
// the same record type (an update never changes the nominal type).
with_check :: proc(ctx: Check_Ctx, e: ^With_Expr) -> (type: Type, err: Type_Error) {
	base := expr_check(ctx, e.base) or_return
	user, is_user := base.(^User_Type)
	if !is_user {
		return nil, .Type_Mismatch
	}
	record, declared := ctx.env.records[user.name]
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

// match_check types a match expression (spec §02 §5): the scrutinee is typed,
// each arm's pattern binders bind against the scrutinee's variant payloads,
// each arm body is typed under those binders, and every arm body must agree —
// the unified arm type is the match's type. Exhaustiveness is the gate's job
// (gates.odin), not this pass's. An arm's binders overlay the shared scope
// only for that arm's body, then are removed, so one arm's binder never leaks
// into the next.
match_check :: proc(ctx: Check_Ctx, e: ^Match_Expr) -> (type: Type, err: Type_Error) {
	ctx := ctx
	scrutinee := expr_check(ctx, e.scrutinee) or_return
	result: Type
	for arm in e.arms {
		binders, types := pattern_binders(arm.pattern, scrutinee)
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

// pattern_binders computes an arm pattern's payload binder names and their
// types against the scrutinee. A Variant_Binds over Option binds the single
// payload to the option's element; a bare or wildcard pattern binds nothing.
// A user-enum variant carries no payload on the pong surface, so its binders
// (none) contribute nothing.
pattern_binders :: proc(pattern: Pattern, scrutinee: Type) -> (names: []string, types: []Type) {
	if pattern.kind != .Variant_Binds || len(pattern.binders) == 0 {
		return nil, nil
	}
	binder_type: Type
	if option, is_option := scrutinee.(^Option_Type); is_option && len(pattern.binders) == 1 {
		binder_type = option.elem
	}
	bound := make([]Type, len(pattern.binders), context.temp_allocator)
	for i in 0 ..< len(pattern.binders) {
		bound[i] = binder_type
	}
	return pattern.binders, bound
}

// call_check types a call. A method/step receiver routes to method_check; a
// free-name callee resolves through the let scope, the user environment, and
// the imported surface to its signature or combinator rule.
call_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if member, is_method := e.callee.(^Member_Expr); is_method {
		return method_check(ctx, member, e)
	}
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, .Unsupported_Expr
	}
	if _, let_bound := ctx.scope[name.name]; let_bound {
		// Calling a let/param-bound lambda value waits on combinator
		// inference — the placeholder Func carries no signature to check.
		return nil, .Unsupported_Expr
	}
	// A call to a user-declared fn checks its arguments against the recorded
	// signature (resolve.odin); a behavior is not callable as a bare name.
	if term, found := env_term_name(ctx.env, name.name); found {
		if term.kind == .Fn && term.signature != nil {
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
		// A §04 command constructor applied (Spawn(thing)).
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
	if name.name == "fold" {
		return fold_check(ctx, e)
	}
	if name.name == "first" {
		return first_check(ctx, e)
	}
	overloads, has_signature := surface_signatures(name.name)
	if !has_signature {
		return nil, .Unsupported_Expr
	}
	return overloads_check(ctx, e, overloads)
}

// fold is (List[T], A, (A, T) -> A) -> A: T unifies from the list's element
// type, A from the init, and the accumulator function is either a literal
// lambda inferred as (A, T) or a bare fn whose recorded signature is checked
// against (A, T) -> A — the form tally's fold(goals, self, add_goal) takes.
fold_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 3 {
		return nil, .Type_Mismatch
	}
	list_type := expr_check(ctx, e.args[0]) or_return
	init := expr_check(ctx, e.args[1]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	combinator_check(ctx, e.args[2], {init, list.elem}, init) or_return
	return init, .None
}

// first has two forms (spec §08): first(view, pred) over a View[T] yields
// Option[T] where pred is (T) -> Bool, and first(list) over a List[T] yields
// Option[T]. The element type drives the inferred predicate parameter, the
// same combinator inference fold uses extended to a one-parameter predicate.
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

// source_element reads the element type of a read source — a View[T] read
// table or a List[T] — the two forms first/fold iterate over.
source_element :: proc(source: Type) -> (elem: Type, ok: bool) {
	if view, is_view := source.(^Engine_Type); is_view && view.kind == .View {
		return view.elem, true
	}
	if list, is_list := source.(^List_Type); is_list {
		return list.elem, true
	}
	return nil, false
}

// combinator_check types a combinator's function argument against an expected
// parameter row and result. A literal lambda infers its parameters from the
// row and types its body in a child scope holding exactly them; a bare fn
// value (or another function-typed expression) is checked structurally
// against the expected signature.
combinator_check :: proc(ctx: Check_Ctx, arg: Expr, params: []Type, result: Type) -> Type_Error {
	ctx := ctx
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		if len(lambda.params) != len(params) {
			return .Type_Mismatch
		}
		// The lambda is a closure: its body sees the enclosing scope (the
		// paddle_bounce predicate reads `self`) with the inferred parameters
		// overlaid for the body, then restored — so a parameter shadowing an
		// enclosing name never erases that name once the body is typed.
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

// Saved_Binding records a name's prior scope state so a shadowing overlay can
// be undone exactly: present carries the prior type, or marks the name absent
// so restore deletes the overlay rather than reviving a binding that was never
// there.
Saved_Binding :: struct {
	type:    Type,
	present: bool,
}

// overlay_scope binds each name to its overlay type, returning the prior state
// of every name so restore_scope can undo the overlay. Names and types are
// positional — types[i] is bound to names[i].
overlay_scope :: proc(scope: ^Scope, names: []string, types: []Type) -> []Saved_Binding {
	saved := make([]Saved_Binding, len(names), context.temp_allocator)
	for name, i in names {
		prior, present := scope[name]
		saved[i] = Saved_Binding{type = prior, present = present}
		scope[name] = types[i]
	}
	return saved
}

// restore_scope undoes overlay_scope: a name that had a prior binding regains
// it, and a name that was absent before the overlay is removed.
restore_scope :: proc(scope: ^Scope, names: []string, saved: []Saved_Binding) {
	for name, i in names {
		if saved[i].present {
			scope[name] = saved[i].type
		} else {
			delete_key(scope, name)
		}
	}
}

// overloads_check types the arguments once and admits the call when the
// argument row matches one overload's parameters exactly.
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
		got := expr_check(ctx, e.args[i]) or_return
		if !types_compatible(got, want) {
			return .Type_Mismatch
		}
	}
	return .None
}

// method_check types receiver.member(args). A Type-name receiver resolved
// through the surface selects an associated constructor (Quat.axis_angle) or
// a static builder entry (Bindings.empty()); a behavior-name receiver selects
// its reserved `.step` signature (the §04 name.step test-invocation form); any
// other receiver is a value whose methods the surface keys by its type.
method_check :: proc(ctx: Check_Ctx, callee: ^Member_Expr, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if recv, is_name := callee.receiver.(^Name_Expr); is_name {
		if _, in_scope := ctx.scope[recv.name]; !in_scope {
			if static, handled, static_err := static_method_check(ctx, recv.name, callee.member, e); handled {
				return static, static_err
			}
		}
	}
	receiver := expr_check(ctx, callee.receiver) or_return
	return value_method_check(ctx, receiver, callee.member, e)
}

// static_method_check handles a method whose receiver names a declaration,
// not a value: a behavior's `.step`, a Type-name surface constructor, or a
// Type-name static builder. handled is false when the receiver is not one of
// these, so the caller falls through to the value-method path.
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
		// The §04 name.step(args) form: a behavior reaches its step signature
		// through its own name key (resolve.odin).
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
	// A Type-name associated constructor (Quat.axis_angle).
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

// value_method_check types a method off a typed value receiver: an engine
// resource's method (Input.value, Bindings.axis) or a ground type's method
// (the Quat method set).
value_method_check :: proc(ctx: Check_Ctx, receiver: Type, member: string, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if engine, is_engine := receiver.(^Engine_Type); is_engine {
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

// variant_check types an enum-variant value. Option carries the evaluable
// Some/None; a user enum yields its nominal handle (a bare variant or a
// struct-payload constructor like [Goal{…}]'s element); an engine enum yields
// its engine handle (Color::White, PlayerId::P1); a struct-payload engine
// variant (Draw::Rect{…}) checks its fields against the surface schema.
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
		if engine, found := surface_enum_variant(e.type_name, e.variant); found {
			if e.has_payload {
				return nil, .Unsupported_Expr
			}
			return engine, .None
		}
		return nil, .Unsupported_Expr
	}
	if enum_schema, declared := ctx.env.enums[e.type_name]; declared {
		if e.has_payload {
			// User enums on the pong surface carry no tuple payload.
			return nil, .Unsupported_Expr
		}
		if !name_in_set(e.variant, enum_schema.variants) {
			return nil, .Type_Mismatch
		}
		return user_type_of(e.type_name, .Enum), .None
	}
	if env_declares(ctx.env, e.type_name) {
		return nil, .Unsupported_Expr
	}
	return nil, .Unresolved_Name
}

// option_variant_check types Option::Some(v) into Option[typeof v] and
// Option::None into the unknown-element Option.
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

// struct_variant_check types a struct-payload engine-enum variant
// (Draw::Rect{…}, Draw::Text{…}, spec §20): every named field must belong to
// the surface schema and match its declared type; the result is the variant's
// engine command type.
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

// surface_field_type reads an engine struct-variant field's declared type by
// name — a linear lookup, so field order never reaches the verdict.
surface_field_type :: proc(fields: []Surface_Field, name: string) -> (type: Type, found: bool) {
	for field in fields {
		if field.name == name {
			return field.type, true
		}
	}
	return nil, false
}
