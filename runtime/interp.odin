package funpack_runtime

import "core:mem"
import "core:strconv"
import "core:strings"

Record_Value :: struct {
	type_name: string,
	fields:    map[string]Value,
}

List_Value :: struct {
	elements: []Value,
}

Map_Value :: struct {
	entries: []Map_Entry,
}

Map_Entry :: struct {
	key:   Value,
	value: Value,
}

Variant_Value :: struct {
	enum_type: string,
	case_name: string,
	payload:   ^Value,
}

Lambda_Value :: struct {
	params:   []string,
	body:     ^Node,
	captured: ^Env,
}

String_Value :: struct {
	text: string,
}

Tuple_Value :: struct {
	elements: []Value,
}

Value :: union {
	i64,
	Fixed,
	bool,
	Vec2,
	Ref,
	Record_Value,
	List_Value,
	Map_Value,
	Variant_Value,
	Lambda_Value,
	String_Value,
	Tuple_Value,
	Rng,
	Vec3,
	Transform_Value,
	Pose_Value,
	Handle_Value,
	Nav_Value,
}

Nav_Value :: struct {
	route:  Record_Value,
	failed: bool,
	err:    string,
}

Env :: struct {
	names:  map[string]Value,
	parent: ^Env,
}

Interp :: struct {
	program:       ^Program,
	version:       ^World_Version,
	tick:          ^Tick_State,
	input:         Input,
	time:          Record_Value,
	registry:      Action_Registry,
	allocator:     Runtime_Allocator,
	query_indexes: []Index_Req,
}

new_interp :: proc(
	program: ^Program,
	version: ^World_Version,
	tick: ^Tick_State,
	input: Input,
	time: Record_Value,
	allocator := context.allocator,
) -> Interp {
	registry := program.registry
	if registry.by_key == nil {
		registry = build_action_registry(program^, allocator)
	}
	return Interp {
		program = program,
		version = version,
		tick = tick,
		input = input,
		time = time,
		registry = registry,
		allocator = allocator,
	}
}

Runtime_Allocator :: mem.Allocator

eval_const :: proc(interp: ^Interp, name: string) -> (value: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.body) != 1 {
		return nil, false
	}
	root := Env{names = make(map[string]Value, interp.allocator)}
	return eval_statement(interp, &fn.body[0], &root)
}

eval_behavior_body :: proc(interp: ^Interp, body: []Node, env: ^Env) -> (value: Value, ok: bool) {
	return eval_body(interp, body, env)
}

bind_let_tuple_value :: proc(env: ^Env, names: []string, v: Value) -> (ok: bool) {
	tuple, is_tuple := v.(Tuple_Value)
	if !is_tuple || len(tuple.elements) != len(names) {
		return false
	}
	for name, i in names {
		env.names[name] = tuple.elements[i]
	}
	return true
}

Step_Outcome :: enum {
	Continued,
	Returned,
	Foreign,
}

step_statement :: proc(interp: ^Interp, stmt: ^Node, scope: ^Env) -> (value: Value, outcome: Step_Outcome, ok: bool) {
	#partial switch stmt.kind {
	case .Let:
		bound, bound_ok := eval(interp, &stmt.children[0], scope)
		if !bound_ok {
			return nil, .Continued, false
		}
		scope.names[stmt.fields[0]] = bound
		return nil, .Continued, true
	case .Let_Tuple:
		bound, bound_ok := eval(interp, &stmt.children[0], scope)
		if !bound_ok {
			return nil, .Continued, false
		}
		if !bind_let_tuple_value(scope, stmt.fields[1:], bound) {
			return nil, .Continued, false
		}
		return nil, .Continued, true
	case .If_Return:
		cond, cond_ok := eval(interp, &stmt.children[0], scope)
		if !cond_ok {
			return nil, .Continued, false
		}
		if as_bool(cond) {
			if stmt.children[1].kind == .Block {
				block_value, returned, block_ok := eval_guard_block(interp, stmt.children[1].children, scope)
				if !block_ok {
					return nil, .Continued, false
				}
				if returned {
					return block_value, .Returned, true
				}
				return nil, .Continued, true
			}
			result, result_ok := eval(interp, &stmt.children[1], scope)
			return result, .Returned, result_ok
		}
		return nil, .Continued, true
	case .Return:
		result, result_ok := eval(interp, &stmt.children[0], scope)
		return result, .Returned, result_ok
	}
	return nil, .Foreign, true
}

eval_body :: proc(interp: ^Interp, body: []Node, env: ^Env) -> (value: Value, ok: bool) {
	for &stmt in body {
		result, outcome, step_ok := step_statement(interp, &stmt, env)
		if !step_ok {
			return nil, false
		}
		switch outcome {
		case .Returned:
			return result, true
		case .Continued:
			continue
		case .Foreign:
			if stmt.kind == .Stub && len(stmt.fields) == 1 && stmt.fields[0] == "fallback" && len(stmt.children) == 1 {
				return eval(interp, &stmt.children[0], env)
			}
			return nil, false
		}
	}
	return nil, false
}

eval_guard_block :: proc(interp: ^Interp, stmts: []Node, env: ^Env) -> (value: Value, returned: bool, ok: bool) {
	scope := Env {
		names  = make(map[string]Value, interp.allocator),
		parent = env,
	}
	for &stmt in stmts {
		result, outcome, step_ok := step_statement(interp, &stmt, &scope)
		if !step_ok {
			return nil, false, false
		}
		switch outcome {
		case .Returned:
			return result, true, true
		case .Continued:
			continue
		case .Foreign:
			return nil, false, false
		}
	}
	return nil, false, true
}

eval_statement :: proc(interp: ^Interp, stmt: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	one := []Node{stmt^}
	return eval_body(interp, one, env)
}

eval :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	switch node.kind {
	case .Int:
		n, n_ok := decode_int(node.fields[0])
		return n, n_ok
	case .Fixed:
		f, f_ok := decode_fixed(node.fields[0])
		return f, f_ok
	case .String:
		s, s_ok := decode_string(node.fields[0])
		if !s_ok {
			return nil, false
		}
		return string_value(interp, s, env), true
	case .Name:
		return eval_name(interp, node.fields[0], env)
	case .Field:
		return eval_field(interp, node, env)
	case .Variant:
		return eval_variant(interp, node, env)
	case .Record:
		return eval_record(interp, node, env)
	case .With:
		return eval_with(interp, node, env)
	case .List:
		return eval_list(interp, node, env)
	case .Tuple:
		return eval_tuple(interp, node, env)
	case .Unary:
		return eval_unary(interp, node, env)
	case .Binary:
		return eval_binary(interp, node, env)
	case .Match:
		return eval_match(interp, node, env)
	case .If_Expr:
		cond, cond_ok := eval(interp, &node.children[0], env)
		if !cond_ok {
			return nil, false
		}
		if as_bool(cond) {
			return eval(interp, &node.children[1], env)
		}
		return eval(interp, &node.children[2], env)
	case .Call:
		return eval_call(interp, node, env)
	case .Lambda:
		return eval_lambda(interp, node, env), true
	case .All:
		return view_rows_as_list(interp, node.fields[0]), true
	case .Recfield, .Arm, .Let, .Let_Tuple, .If_Return, .Return, .Stub, .Block:
		return nil, false
	}
	return nil, false
}

eval_name :: proc(interp: ^Interp, name: string, env: ^Env) -> (value: Value, ok: bool) {
	switch name {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	for scope := env; scope != nil; scope = scope.parent {
		if v, present := scope.names[name]; present {
			return v, true
		}
	}
	if fn := program_function(interp.program, name); fn != nil && len(fn.params) == 0 {
		return eval_const(interp, name)
	}
	switch name {
	case "tau":
		return TAU_FIXED, true
	case "pi":
		return PI_FIXED, true
	}
	return nil, false
}

eval_field :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	recv, recv_ok := eval(interp, &node.children[0], env)
	if !recv_ok {
		return nil, false
	}
	field := node.fields[0]
	switch r in recv {
	case Record_Value:
		v, present := r.fields[field]
		return v, present
	case Vec2:
		switch field {
		case "x":
			return r.x, true
		case "y":
			return r.y, true
		}
		return nil, false
	case Vec3:
		switch field {
		case "x":
			return r.x, true
		case "y":
			return r.y, true
		case "z":
			return r.z, true
		}
		return nil, false
	case Ref:
		row, some := interp_resolve_ref(interp, r)
		if !some {
			return nil, false
		}
		fv, present := row.fields[field]
		if !present {
			return nil, false
		}
		return field_value_to_value(fv), true
	case i64, Fixed, bool, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value, Map_Value:
		return nil, false
	}
	return nil, false
}

eval_variant :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	enum_type := node.fields[0]
	case_name := node.fields[1]
	has_payload := node.fields[2] == "true"
	out := Variant_Value{enum_type = enum_type, case_name = case_name}
	if has_payload && len(node.children) >= 1 {
		payload, payload_ok := eval(interp, &node.children[0], env)
		if !payload_ok {
			return nil, false
		}
		boxed := new(Value, interp.allocator)
		boxed^ = payload
		out.payload = boxed
	}
	return out, true
}

eval_record :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	type_name := node.fields[0]
	fields := make(map[string]Value, interp.allocator)
	for &child in node.children {
		if child.kind != .Recfield {
			return nil, false
		}
		fv, fv_ok := eval(interp, &child.children[0], env)
		if !fv_ok {
			return nil, false
		}
		fields[child.fields[0]] = fv
	}
	if type_name == "Vec2" {
		return record_to_vec2(fields)
	}
	if type_name == "Vec3" {
		return record_to_vec3(fields)
	}
	fill_record_defaults(interp, type_name, &fields)
	return Record_Value{type_name = type_name, fields = fields}, true
}

fill_record_defaults :: proc(interp: ^Interp, type_name: string, fields: ^map[string]Value) {
	decls := record_field_decls(interp.program, type_name)
	for fd in decls {
		if _, present := fields[fd.name]; present {
			continue
		}
		if !fd.has_default {
			continue
		}
		if fv, decoded := decode_default(interp.program, fd, interp.allocator); decoded {
			fields[strings.clone(fd.name, interp.allocator)] = field_value_to_value(fv)
		}
	}
}

record_field_decls :: proc(program: ^Program, type_name: string) -> []Field_Decl {
	if thing := program_thing(program, type_name); thing != nil {
		return thing.fields
	}
	if data := program_data(program, type_name); data != nil {
		return data.fields
	}
	return nil
}

eval_with :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	base, base_ok := eval(interp, &node.children[0], env)
	if !base_ok {
		return nil, false
	}
	merged := make(map[string]Value, interp.allocator)
	type_name := ""
	switch b in base {
	case Record_Value:
		type_name = b.type_name
		for k, v in b.fields {
			merged[k] = v
		}
	case Vec2:
		type_name = "Vec2"
		merged["x"] = b.x
		merged["y"] = b.y
	case i64, Fixed, bool, Ref, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng, Vec3, Transform_Value, Pose_Value, Handle_Value, Nav_Value, Map_Value:
		return nil, false
	}
	for i in 1 ..< len(node.children) {
		child := &node.children[i]
		if child.kind != .Recfield {
			return nil, false
		}
		rv, rv_ok := eval(interp, &child.children[0], env)
		if !rv_ok {
			return nil, false
		}
		merged[child.fields[0]] = rv
	}
	if type_name == "Vec2" {
		return record_to_vec2(merged)
	}
	return Record_Value{type_name = type_name, fields = merged}, true
}

eval_value_elements :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (elements: []Value, ok: bool) {
	out := make([]Value, len(node.children), interp.allocator)
	for &child, i in node.children {
		ev, ev_ok := eval(interp, &child, env)
		if !ev_ok {
			return nil, false
		}
		out[i] = ev
	}
	return out, true
}

eval_list :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	elements := eval_value_elements(interp, node, env) or_return
	return List_Value{elements = elements}, true
}

eval_tuple :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	elements := eval_value_elements(interp, node, env) or_return
	return Tuple_Value{elements = elements}, true
}

eval_lambda :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> Value {
	params := node.fields[1:]
	return Lambda_Value{params = params, body = &node.children[0], captured = env}
}

eval_unary :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	operand, operand_ok := eval(interp, &node.children[0], env)
	if !operand_ok {
		return nil, false
	}
	switch node.fields[0] {
	case "neg":
		switch v in operand {
		case Fixed:
			return fixed_neg(v), true
		case i64:
			return int_neg(v), true
		case Vec2:
			return Vec2{fixed_neg(v.x), fixed_neg(v.y)}, true
		case Vec3:
			return Vec3{fixed_neg(v.x), fixed_neg(v.y), fixed_neg(v.z)}, true
		case bool, Ref, Record_Value, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value, Map_Value:
			return nil, false
		}
	case "not":
		if b, is_bool := operand.(bool); is_bool {
			return !b, true
		}
		return nil, false
	}
	return nil, false
}

eval_binary :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	lhs, lhs_ok := eval(interp, &node.children[0], env)
	rhs, rhs_ok := eval(interp, &node.children[1], env)
	if !lhs_ok || !rhs_ok {
		return nil, false
	}
	op := node.fields[0]
	switch op {
	case "and":
		return as_bool(lhs) && as_bool(rhs), true
	case "or":
		return as_bool(lhs) || as_bool(rhs), true
	case "add", "sub", "mul", "div", "mod":
		return eval_arith(op, lhs, rhs)
	case "lt", "le", "gt", "ge", "eq", "ne":
		return eval_compare(op, lhs, rhs)
	}
	return nil, false
}

eval_arith :: proc(op: string, lhs, rhs: Value) -> (value: Value, ok: bool) {
	#partial switch l in lhs {
	case Fixed:
		r, r_ok := as_fixed(rhs)
		if !r_ok {
			return nil, false
		}
		return apply_fixed_arith(op, l, r)
	case i64:
		r, r_ok := rhs.(i64)
		if !r_ok {
			return nil, false
		}
		return apply_int_arith(op, l, r)
	case Vec2:
		return apply_vec2_arith(op, l, rhs)
	case Vec3:
		return apply_vec3_arith(op, l, rhs)
	}
	return nil, false
}

apply_fixed_arith :: proc(op: string, a, b: Fixed) -> (value: Value, ok: bool) {
	switch op {
	case "add":
		return fixed_add(a, b), true
	case "sub":
		return fixed_sub(a, b), true
	case "mul":
		return fixed_mul(a, b), true
	case "div":
		return fixed_div(a, b), true
	case "mod":
		return fixed_mod(a, b), true
	}
	return nil, false
}

apply_int_arith :: proc(op: string, a, b: i64) -> (value: Value, ok: bool) {
	switch op {
	case "add":
		return int_add(a, b), true
	case "sub":
		return int_sub(a, b), true
	case "mul":
		return int_mul(a, b), true
	case "div":
		return int_div(a, b), true
	case "mod":
		return int_mod(a, b), true
	}
	return nil, false
}

apply_vec2_arith :: proc(op: string, a: Vec2, rhs: Value) -> (value: Value, ok: bool) {
	switch op {
	case "add":
		b, b_ok := rhs.(Vec2)
		if !b_ok {
			return nil, false
		}
		return vec2_add(a, b), true
	case "sub":
		b, b_ok := rhs.(Vec2)
		if !b_ok {
			return nil, false
		}
		return vec2_sub(a, b), true
	case "mul":
		s, s_ok := as_fixed(rhs)
		if !s_ok {
			return nil, false
		}
		return vec2_scale(a, s), true
	}
	return nil, false
}

apply_vec3_arith :: proc(op: string, a: Vec3, rhs: Value) -> (value: Value, ok: bool) {
	switch op {
	case "add":
		b, b_ok := rhs.(Vec3)
		if !b_ok {
			return nil, false
		}
		return vec3_add(a, b), true
	case "sub":
		b, b_ok := rhs.(Vec3)
		if !b_ok {
			return nil, false
		}
		return vec3_sub(a, b), true
	case "mul":
		s, s_ok := as_fixed(rhs)
		if !s_ok {
			return nil, false
		}
		return vec3_scale(a, s), true
	}
	return nil, false
}

eval_compare :: proc(op: string, lhs, rhs: Value) -> (value: Value, ok: bool) {
	#partial switch l in lhs {
	case Fixed:
		r, r_ok := as_fixed(rhs)
		if !r_ok {
			return nil, false
		}
		return compare_ordered(op, i64(l), i64(r)), true
	case i64:
		r, r_ok := rhs.(i64)
		if !r_ok {
			return nil, false
		}
		return compare_ordered(op, l, r), true
	case Variant_Value, Record_Value:
		switch op {
		case "eq":
			return values_equal(lhs, rhs), true
		case "ne":
			return !values_equal(lhs, rhs), true
		}
		return nil, false
	}
	return nil, false
}

values_equal :: proc(a, b: Value) -> bool {
	switch av in a {
	case i64:
		bv, ok := b.(i64)
		return ok && av == bv
	case Fixed:
		bv, ok := b.(Fixed)
		return ok && av == bv
	case bool:
		bv, ok := b.(bool)
		return ok && av == bv
	case Vec2:
		bv, ok := b.(Vec2)
		return ok && av.x == bv.x && av.y == bv.y
	case Ref:
		bv, ok := b.(Ref)
		return ok && av == bv
	case Variant_Value:
		bv, ok := b.(Variant_Value)
		if !ok || av.enum_type != bv.enum_type || av.case_name != bv.case_name {
			return false
		}
		if av.payload == nil || bv.payload == nil {
			return av.payload == nil && bv.payload == nil
		}
		return values_equal(av.payload^, bv.payload^)
	case Record_Value:
		bv, ok := b.(Record_Value)
		if !ok || len(av.fields) != len(bv.fields) {
			return false
		}
		for name, val in av.fields {
			other, present := bv.fields[name]
			if !present || !values_equal(val, other) {
				return false
			}
		}
		return true
	case List_Value:
		bv, ok := b.(List_Value)
		if !ok || len(av.elements) != len(bv.elements) {
			return false
		}
		for elem, i in av.elements {
			if !values_equal(elem, bv.elements[i]) {
				return false
			}
		}
		return true
	case Map_Value:
		bv, ok := b.(Map_Value)
		if !ok || len(av.entries) != len(bv.entries) {
			return false
		}
		for entry, i in av.entries {
			if !values_equal(entry.key, bv.entries[i].key) ||
			   !values_equal(entry.value, bv.entries[i].value) {
				return false
			}
		}
		return true
	case Tuple_Value:
		bv, ok := b.(Tuple_Value)
		if !ok || len(av.elements) != len(bv.elements) {
			return false
		}
		for elem, i in av.elements {
			if !values_equal(elem, bv.elements[i]) {
				return false
			}
		}
		return true
	case String_Value:
		bv, ok := b.(String_Value)
		return ok && av.text == bv.text
	case Vec3:
		bv, ok := b.(Vec3)
		return ok && av.x == bv.x && av.y == bv.y && av.z == bv.z
	case Transform_Value:
		bv, ok := b.(Transform_Value)
		return ok && transforms_equal(av, bv)
	case Pose_Value:
		bv, ok := b.(Pose_Value)
		return ok && poses_equal(av, bv)
	case Handle_Value:
		bv, ok := b.(Handle_Value)
		return ok && handles_equal(av, bv)
	case Lambda_Value, Rng, Nav_Value:
		return false
	}
	return false
}

compare_ordered :: proc(op: string, a, b: i64) -> bool {
	switch op {
	case "lt":
		return a < b
	case "le":
		return a <= b
	case "gt":
		return a > b
	case "ge":
		return a >= b
	case "eq":
		return a == b
	case "ne":
		return a != b
	}
	return false
}

string_value :: proc(interp: ^Interp, template: string, env: ^Env) -> Value {
	b := strings.builder_make(interp.allocator)
	rest := template
	for {
		open := strings.index_byte(rest, '{')
		if open < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:open])
		close := strings.index_byte(rest[open:], '}')
		if close < 0 {
			strings.write_string(&b, rest[open:])
			break
		}
		hole := rest[open + 1:open + close]
		strings.write_string(&b, interpolate_hole(interp, hole, env))
		rest = rest[open + close + 1:]
	}
	return String_Value{text = strings.to_string(b)}
}

interpolate_hole :: proc(interp: ^Interp, hole: string, env: ^Env) -> string {
	dot := strings.index_byte(hole, '.')
	if dot < 0 {
		return ""
	}
	recv_name := strings.trim_space(hole[:dot])
	field_name := strings.trim_space(hole[dot + 1:])
	recv, recv_ok := eval_name(interp, recv_name, env)
	if !recv_ok {
		return ""
	}
	record, is_record := recv.(Record_Value)
	if !is_record {
		return ""
	}
	field_val, present := record.fields[field_name]
	if !present {
		return ""
	}
	return format_value(interp, field_val)
}

format_value :: proc(interp: ^Interp, v: Value) -> string {
	switch x in v {
	case i64:
		return aprint_int(x, interp.allocator)
	case Fixed:
		return aprint_int(fixed_trunc(x), interp.allocator)
	case Variant_Value:
		return strings.clone(x.case_name, interp.allocator)
	case bool, Vec2, Ref, Record_Value, List_Value, Lambda_Value, String_Value, Tuple_Value, Rng, Vec3, Transform_Value, Pose_Value, Handle_Value, Nav_Value, Map_Value:
		return ""
	}
	return ""
}

aprint_int :: proc(n: i64, allocator := context.allocator) -> string {
	buf: [32]byte
	return strings.clone(strconv.write_int(buf[:], n, 10), allocator)
}

as_bool :: proc(v: Value) -> bool {
	b, ok := v.(bool)
	return ok && b
}

as_fixed :: proc(v: Value) -> (f: Fixed, ok: bool) {
	switch n in v {
	case Fixed:
		return n, true
	case i64:
		return to_fixed(n), true
	case bool, Vec2, Ref, Record_Value, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng, Vec3, Transform_Value, Pose_Value, Handle_Value, Nav_Value, Map_Value:
		return Fixed(0), false
	}
	return Fixed(0), false
}

record_to_vec2 :: proc(fields: map[string]Value) -> (v: Value, ok: bool) {
	xv, x_present := fields["x"]
	yv, y_present := fields["y"]
	if !x_present || !y_present {
		return nil, false
	}
	x, x_ok := as_fixed(xv)
	y, y_ok := as_fixed(yv)
	if !x_ok || !y_ok {
		return nil, false
	}
	return Vec2{x, y}, true
}

record_to_vec3 :: proc(fields: map[string]Value) -> (v: Value, ok: bool) {
	xv, x_present := fields["x"]
	yv, y_present := fields["y"]
	zv, z_present := fields["z"]
	if !x_present || !y_present || !z_present {
		return nil, false
	}
	x, x_ok := as_fixed(xv)
	y, y_ok := as_fixed(yv)
	z, z_ok := as_fixed(zv)
	if !x_ok || !y_ok || !z_ok {
		return nil, false
	}
	return Vec3{x = x, y = y, z = z}, true
}

record_name_field :: proc(record: Record_Value, field: string) -> (name: string, ok: bool) {
	value, present := record.fields[field]
	if !present {
		return "", false
	}
	text, is_string := value.(String_Value)
	if !is_string {
		return "", false
	}
	return text.text, true
}

handle_value_name :: proc(value: Value) -> (name: string, ok: bool) {
	#partial switch v in value {
	case Record_Value:
		return record_name_field(v, "name")
	case String_Value:
		return v.text, true
	}
	return "", false
}

field_value_to_value :: proc(fv: Field_Value) -> Value {
	switch v in fv {
	case i64:
		return v
	case Fixed:
		return v
	case bool:
		return v
	case Vec2:
		return v
	case Vec3:
		return v
	case Ref:
		return v
	case Record_Value:
		return v
	case List_Value:
		return v
	case Map_Value:
		return v
	case string:
		return variant_from_token(v)
	case Variant_Value:
		return v
	case String_Value:
		return v
	}
	return nil
}

value_to_field_value :: proc(
	v: Value,
	allocator := context.allocator,
) -> (
	fv: Field_Value,
	ok: bool,
) {
	switch x in v {
	case i64:
		return x, true
	case Fixed:
		return x, true
	case bool:
		return x, true
	case Vec2:
		return x, true
	case Vec3:
		return x, true
	case Ref:
		return x, true
	case Variant_Value:
		if x.payload == nil {
			return variant_to_token(x, allocator), true
		}
		return clone_variant_value(x, allocator), true
	case String_Value:
		return String_Value{text = strings.clone(x.text, allocator)}, true
	case Record_Value:
		return clone_record_value(x, allocator), true
	case List_Value:
		return clone_list_value(x, allocator), true
	case Map_Value:
		return clone_map_value(x, allocator), true
	case Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value:
		return nil, false
	}
	return nil, false
}

clone_record_value :: proc(rec: Record_Value, allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, len(rec.fields), allocator)
	for k, v in rec.fields {
		fields[strings.clone(k, allocator)] = clone_column_value(v, allocator)
	}
	return Record_Value{type_name = strings.clone(rec.type_name, allocator), fields = fields}
}

clone_list_value :: proc(list: List_Value, allocator := context.allocator) -> List_Value {
	elements := make([]Value, len(list.elements), allocator)
	for elem, i in list.elements {
		elements[i] = clone_column_value(elem, allocator)
	}
	return List_Value{elements = elements}
}

clone_map_value :: proc(m: Map_Value, allocator := context.allocator) -> Map_Value {
	entries := make([]Map_Entry, len(m.entries), allocator)
	for entry, i in m.entries {
		entries[i] = Map_Entry {
			key   = clone_column_value(entry.key, allocator),
			value = clone_column_value(entry.value, allocator),
		}
	}
	return Map_Value{entries = entries}
}

clone_column_value :: proc(v: Value, allocator := context.allocator) -> Value {
	switch x in v {
	case Record_Value:
		return clone_record_value(x, allocator)
	case List_Value:
		return clone_list_value(x, allocator)
	case Map_Value:
		return clone_map_value(x, allocator)
	case Variant_Value:
		return clone_variant_value(x, allocator)
	case i64, Fixed, bool, Vec2, Ref, Lambda_Value, String_Value, Tuple_Value, Rng, Vec3, Transform_Value, Pose_Value, Handle_Value, Nav_Value:
		return v
	}
	return v
}

clone_variant_value :: proc(v: Variant_Value, allocator := context.allocator) -> Variant_Value {
	out := Variant_Value {
		enum_type = strings.clone(v.enum_type, allocator),
		case_name = strings.clone(v.case_name, allocator),
	}
	if v.payload != nil {
		payload := new(Value, allocator)
		payload^ = clone_column_value(v.payload^, allocator)
		out.payload = payload
	}
	return out
}

variant_from_token :: proc(token: string) -> Variant_Value {
	idx := strings.index(token, "::")
	if idx < 0 {
		return Variant_Value{case_name = token}
	}
	return Variant_Value{enum_type = token[:idx], case_name = token[idx + 2:]}
}

variant_to_token :: proc(v: Variant_Value, allocator := context.allocator) -> string {
	if v.enum_type == "" {
		return strings.clone(v.case_name, allocator)
	}
	return strings.concatenate({v.enum_type, "::", v.case_name}, allocator)
}

program_function :: proc(program: ^Program, name: string) -> ^Function_Decl {
	for &fn in program.functions {
		if fn.name == name {
			return &fn
		}
	}
	return nil
}
