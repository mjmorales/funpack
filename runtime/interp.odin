// The runtime interpreter over the §2.7 checked-AST node forest: the canonical
// semantics of a funpack behavior is what THIS evaluator computes over the
// artifact's node encoding (spec §09 §1 — the interpreter is the ground truth,
// there is no second definition in source the runtime can never read). The tick
// transaction (tick.odin) folds the pipeline and drives this evaluator once per
// behavior instance; this file is the pure expression/statement engine it calls.
//
// PURITY: evaluation is a pure function of (the program's functions/consts, the
// pre-tick committed version it reads Views against, the input snapshot, the
// time resource, the inbound signal lists) and the behavior's bound params. It
// reads the world, never writes it — a behavior's writes are the RETURN value
// the tick transaction folds, never a mutation the evaluator performs. No float
// ever enters: every numeric op flows through the fixed.odin kernel.
//
// runtime/** never imports funpack/**; the artifact node forest is the only
// coupling to the compiler product (spec §29, §09).
package funpack_runtime

import "core:mem"
import "core:strings"

// --- The runtime value model ---------------------------------------------

// Record_Value is an evaluated record or thing blackboard: a by-name field map
// the same shape state.odin's Row blackboard carries, so a `self`-typed param is
// the row's fields and a record literal is a fresh map. `type_name` carries the
// record's declared type (a thing or data name, or "" for an anonymous record)
// so a `with` reconstructs the same type and a returned blackboard knows its
// thing. The map is owned by the evaluation arena (the tick's temp allocator).
Record_Value :: struct {
	type_name: string,
	fields:    map[string]Value,
}

// List_Value is an evaluated `[T]` list: an ordered slice of element values. A
// signal list a behavior emits, a `[Goal]` param a consumer reads, and the
// `first`/`fold` combinators all range over this. Order is the deterministic
// evaluation order the list literal or signal route produced it in.
List_Value :: struct {
	elements: []Value,
}

// Variant_Value is an evaluated tagged-enum value: its enum type, its case name,
// and an optional payload value (a tuple/struct payload is carried as one
// element here — pong's Option::Some(x) and Side::Left cover the unit and
// single-payload cases). A bare enum variant (Side::Left) has no payload.
Variant_Value :: struct {
	enum_type: string,
	case_name: string,
	payload:   ^Value, // nil for a unit variant; the Some-payload otherwise
}

// Lambda_Value is an evaluated lambda closure: its single parameter name, its
// body node, and the captured environment it closes over. `first`/`fold` apply
// it per element. Pong's only lambda is paddle_bounce's `pad => overlaps(...)`.
Lambda_Value :: struct {
	param:    string,
	body:     ^Node,
	captured: ^Env,
}

// Value is the closed set of runtime values the interpreter computes. The
// scalar arms mirror the blackboard's Field_Value (Int/Fixed/variant-as-string
// is NOT used — an enum value is a Variant_Value so a match can read its case);
// the structural arms (record/list/variant/lambda) are the shapes a behavior
// body builds and folds before returning. No float ever (spec §10).
Value :: union {
	i64, // an Int
	Fixed, // a Fixed (Q32.32 bits)
	bool, // a Bool (comparison / logical result)
	Vec2, // a two-Fixed vector (§10 Num kind)
	Ref, // a weak typed handle to a row
	Record_Value, // a record literal / thing blackboard
	List_Value, // a [T] list
	Variant_Value, // a tagged enum value
	Lambda_Value, // a lambda closure
}

// --- The evaluation environment ------------------------------------------

// Env is one lexical scope binding names to values: the behavior/function
// params plus every `let` and lambda binder in scope. Scopes chain through
// `parent` so a lambda body sees its captured outer names; a lookup walks the
// chain inner-to-outer. The interpreter owns no globals beyond the program's
// functions/consts, which it resolves separately (a name that is not a local is
// a const or a 0-arg function, evaluated on demand).
Env :: struct {
	names:  map[string]Value,
	parent: ^Env,
}

// Interp is the read-only context every evaluation threads: the loaded program
// (its functions and consts), the pre-tick committed version a View ranges over,
// the input snapshot a `value`/`pressed` query reads, the time resource a `dt`
// read resolves, and the evaluation allocator the value tree is built in. It is
// the immutable world a behavior observes; the behavior's writes are its return,
// folded by the tick transaction, never a field of this context.
Interp :: struct {
	program:   ^Program,
	version:   ^World_Version, // the pre-tick world Views read (population fixed within a tick)
	input:     Input, // the §23 action snapshot a behavior queries
	time:      Record_Value, // the Time resource: { dt: Fixed }
	allocator: Runtime_Allocator,
}

// Runtime_Allocator is the evaluation arena alias — every value the interpreter
// builds (records, lists, variants) is allocated here, so the tick transaction
// owns the lifetime of one tick's intermediate values and frees them as one
// arena. Kept as a named alias so the seam is explicit at every call site.
Runtime_Allocator :: mem.Allocator

// --- Public entry points --------------------------------------------------

// eval_const evaluates a module-level const (a §9 `let`) to its value — a pure
// function of the artifact, no params. The tick reads BOARD this way: BOARD.w/h
// resolve against the interpreted Board record, no source needed. A const whose
// body is not exactly one statement is a refusal (a const is one expression).
eval_const :: proc(interp: ^Interp, name: string) -> (value: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.body) != 1 {
		return nil, false
	}
	root := Env{names = make(map[string]Value, interp.allocator)}
	return eval_statement(interp, &fn.body[0], &root)
}

// eval_behavior_body runs a behavior step body against its already-bound
// environment (the tick transaction binds self/resources/signals/Views into
// `env`). It returns the body's RETURN value — the blackboard write, the signal
// list emitted, or the pass-through self — which the tick folds. A body that
// falls off the end with no return yields ok=false (a step body always returns
// per its contract, so a missing return is a malformed body).
eval_behavior_body :: proc(interp: ^Interp, body: []Node, env: ^Env) -> (value: Value, ok: bool) {
	return eval_body(interp, body, env)
}

// --- Statement / body evaluation ------------------------------------------

// eval_body folds a forest of statements top-to-bottom: a `let` binds a name and
// continues, an `if_return` returns when its guard holds, a `return` ends the
// body with its value. The fold threads one environment so a later statement
// sees every earlier `let`. The first statement that returns wins; reaching the
// end with no return is a malformed body (ok=false).
eval_body :: proc(interp: ^Interp, body: []Node, env: ^Env) -> (value: Value, ok: bool) {
	for &stmt in body {
		switch stmt.kind {
		case .Let:
			// `let NAME = expr`: bind NAME for the rest of the body.
			bound, bound_ok := eval(interp, &stmt.children[0], env)
			if !bound_ok {
				return nil, false
			}
			env.names[stmt.fields[0]] = bound
		case .If_Return:
			// `if cond { return value }`: child[0] is the guard, child[1] the value.
			cond, cond_ok := eval(interp, &stmt.children[0], env)
			if !cond_ok {
				return nil, false
			}
			if as_bool(cond) {
				return eval(interp, &stmt.children[1], env)
			}
		case .Return:
			return eval(interp, &stmt.children[0], env)
		case .Int, .Fixed, .Name, .String, .Field, .Call, .Variant, .Record, .Recfield, .With, .List, .Lambda, .Unary, .Binary, .Match, .Arm:
			// A non-statement node at statement position is a malformed body.
			return nil, false
		}
	}
	return nil, false
}

// eval_statement evaluates a single statement node (a const's lone `return`, or
// a recursive `if_return`/`return` inside a body). It shares the body fold's
// statement semantics so a const and a behavior body read the same encoding.
eval_statement :: proc(interp: ^Interp, stmt: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	one := []Node{stmt^}
	return eval_body(interp, one, env)
}

// --- Expression evaluation ------------------------------------------------

// eval computes one expression node to a Value against the environment. It is
// total over the closed §2.7 expression kinds; a statement-only kind at
// expression position is ok=false (a malformed body the loader would not emit).
eval :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	switch node.kind {
	case .Int:
		n, n_ok := decode_int(node.fields[0])
		return n, n_ok
	case .Fixed:
		f, f_ok := decode_fixed(node.fields[0])
		return f, f_ok
	case .String:
		// A String literal appears only in a render [Draw] text node; the executed
		// control/collision/scoring stages carry none. The decoded bytes ride a
		// one-field record keyed by the raw token so no String arm widens the Value
		// union — the render projection is not produced by this fold.
		s, s_ok := decode_string(node.fields[0])
		return string_value(interp, s), s_ok
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
	case .Unary:
		return eval_unary(interp, node, env)
	case .Binary:
		return eval_binary(interp, node, env)
	case .Match:
		return eval_match(interp, node, env)
	case .Call:
		return eval_call(interp, node, env)
	case .Lambda:
		return eval_lambda(interp, node, env), true
	case .Recfield, .Arm, .Let, .If_Return, .Return:
		// These appear only as children of their owning construct, never as a
		// standalone expression — reaching one here is a malformed body.
		return nil, false
	}
	return nil, false
}

// eval_name resolves an identifier: a local binding (param / let / lambda
// binder) first, walking the scope chain; otherwise a module-level const or a
// nullary function evaluated on demand (BOARD reads this way). An unbound name
// is ok=false.
eval_name :: proc(interp: ^Interp, name: string, env: ^Env) -> (value: Value, ok: bool) {
	for scope := env; scope != nil; scope = scope.parent {
		if v, present := scope.names[name]; present {
			return v, true
		}
	}
	// Not a local — a const or a 0-param function. Pong reads BOARD here.
	if fn := program_function(interp.program, name); fn != nil && len(fn.params) == 0 {
		return eval_const(interp, name)
	}
	return nil, false
}

// eval_field reads a field off a receiver value: a record/blackboard field by
// name, a Vec2's x/y component, or a Ref column resolved through the version. It
// is the descriptor-driven `recv.field` — the receiver's runtime shape decides
// which read applies, since the field type lives in the artifact, not the value.
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
	case Ref:
		// A Ref column read followed by a field is the resolve-then-read join: a
		// dangling Ref has no field, so the read takes the absent arm.
		row, some := resolve_ref(interp.version, r)
		if !some {
			return nil, false
		}
		fv, present := row.fields[field]
		if !present {
			return nil, false
		}
		return field_value_to_value(fv), true
	case i64, Fixed, bool, List_Value, Variant_Value, Lambda_Value:
		return nil, false
	}
	return nil, false
}

// eval_variant builds a tagged-enum value: `variant ENUM CASE HAS_PAYLOAD` with
// HAS_PAYLOAD-many payload children. Pong's Option::Some(x) carries one payload
// child; a bare Side::Left/Option::None carries none.
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

// eval_record builds a record literal: `record TYPE FIELD_COUNT` with one
// `recfield NAME = value` child per field. A Vec2 record collapses to the Vec2
// value (its x/y recfields), so vector arithmetic stays on the kernel's Vec2;
// every other record becomes a by-name Record_Value carrying its declared type.
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
	return Record_Value{type_name = type_name, fields = fields}, true
}

// eval_with reconstructs a record with some fields replaced: `with CHANGE_COUNT`
// over a base record, child[0] the base, the remaining children the replacement
// recfields. It is functional update — the base is read, never mutated, and a
// fresh record carries the merge (the immutable-blackboard write a behavior
// returns). A Vec2 base updates its x/y the same way.
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
	case i64, Fixed, bool, Ref, List_Value, Variant_Value, Lambda_Value:
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

// eval_list builds a `[T]` list literal: `list ELEM_COUNT` with one child per
// element, evaluated in source order so the list keeps its deterministic order.
eval_list :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	elements := make([]Value, len(node.children), interp.allocator)
	for &child, i in node.children {
		ev, ev_ok := eval(interp, &child, env)
		if !ev_ok {
			return nil, false
		}
		elements[i] = ev
	}
	return List_Value{elements = elements}, true
}

// eval_lambda closes a lambda over its current environment: `lambda PARAM_COUNT
// PARAM` with the body as child[0]. Pong's only lambda is unary, so PARAM is the
// single binder name; the closure captures `env` so the body sees outer names.
eval_lambda :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> Value {
	return Lambda_Value{param = node.fields[1], body = &node.children[0], captured = env}
}

// eval_unary applies a unary operator. Pong uses only `neg` (Fixed/Int/Vec2
// negation); the kernel's saturating negate keeps it total at the rails.
eval_unary :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	operand, operand_ok := eval(interp, &node.children[0], env)
	if !operand_ok {
		return nil, false
	}
	if node.fields[0] != "neg" {
		return nil, false
	}
	switch v in operand {
	case Fixed:
		return fixed_neg(v), true
	case i64:
		return int_neg(v), true
	case Vec2:
		return Vec2{fixed_neg(v.x), fixed_neg(v.y)}, true
	case bool, Ref, Record_Value, List_Value, Variant_Value, Lambda_Value:
		return nil, false
	}
	return nil, false
}

// eval_binary applies a binary operator over the fixed.odin kernel — arithmetic
// (add/sub/mul/div), comparison (lt/le/gt/ge/eq), and short-circuit-free logical
// (and/or). Numeric ops route through the kernel so the bits are machine-stable;
// a Vec2 operand uses the consolidated Vec2 surface (state.odin). No float.
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

// eval_arith applies an arithmetic op over two numeric values through the
// kernel. A Fixed pair uses the Fixed ops; an Int pair the Int ops; a Vec2 pair
// the Vec2 surface (component-wise add/sub, scalar mul). A mixed/unsupported
// pair is ok=false (the checked AST never emits one for pong).
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
	}
	return nil, false
}

// apply_fixed_arith dispatches one Fixed arithmetic op to the kernel.
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

// apply_int_arith dispatches one Int arithmetic op to the kernel.
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

// apply_vec2_arith dispatches a Vec2 arithmetic op: component-wise add/sub over
// a Vec2 rhs, scalar mul over a Fixed rhs (the §10 Num-kind surface). It reuses
// the consolidated state.odin Vec2 ops so the math is defined in one place.
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

// eval_compare applies a comparison op, yielding a Bool. Fixed and Int compare
// by their kernel-stable bits; an enum-value equality compares case names. A
// comparison the checked AST never emits for these operand shapes is ok=false.
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
	case Variant_Value:
		r, r_ok := rhs.(Variant_Value)
		if !r_ok {
			return nil, false
		}
		eq := l.enum_type == r.enum_type && l.case_name == r.case_name
		switch op {
		case "eq":
			return eq, true
		case "ne":
			return !eq, true
		}
		return nil, false
	}
	return nil, false
}

// compare_ordered applies an ordered/equality comparison over two i64 operands —
// the raw Fixed bits or plain Int values both order correctly as signed i64, so
// one comparator serves Fixed and Int (the kernel keeps the bit order monotone).
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

// --- Internal value helpers -----------------------------------------------

// string_value carries a decoded String literal as a runtime value. A funpack
// String has no dedicated Value arm — pong uses one only in a render `[Draw]`
// text, which this fold does not produce — so the decoded bytes ride a record
// typed "String" whose single field keys the literal under its own bytes. The
// render projection reads the bytes back; the executed control/collision/scoring
// stages never evaluate a String node, so this path is build-complete but
// unexercised by the executed fold.
string_value :: proc(interp: ^Interp, s: string) -> Value {
	fields := make(map[string]Value, interp.allocator)
	fields[s] = bool(true)
	return Record_Value{type_name = "String", fields = fields}
}

// as_bool coerces a value to a Bool for a guard or logical op; a non-Bool is
// false (the checked AST only places a Bool here, so the coercion is total for
// well-formed bodies and fails safe otherwise).
as_bool :: proc(v: Value) -> bool {
	b, ok := v.(bool)
	return ok && b
}

// as_fixed reads a value as a Fixed, lifting an Int to Fixed through the kernel
// so a mixed Int/Fixed arithmetic position resolves on the fixed rail. ok is
// false for a non-numeric value.
as_fixed :: proc(v: Value) -> (f: Fixed, ok: bool) {
	switch n in v {
	case Fixed:
		return n, true
	case i64:
		return to_fixed(n), true
	case bool, Vec2, Ref, Record_Value, List_Value, Variant_Value, Lambda_Value:
		return Fixed(0), false
	}
	return Fixed(0), false
}

// record_to_vec2 collapses an {x, y} field map to the kernel Vec2 value — a Vec2
// record literal IS a Vec2, so vector math stays on one type. ok is false unless
// both components are present and numeric.
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

// field_value_to_value lifts a blackboard Field_Value (state.odin's stored
// column type) into the interpreter's Value. The two unions overlap on the
// scalar/Vec2/Ref arms; a stored enum token (a string column) becomes a
// Variant_Value by splitting its "Enum::Case" form so a match can read the case.
field_value_to_value :: proc(fv: Field_Value) -> Value {
	switch v in fv {
	case i64:
		return v
	case Fixed:
		return v
	case Vec2:
		return v
	case Ref:
		return v
	case string:
		return variant_from_token(v)
	}
	return nil
}

// value_to_field_value lowers an interpreter Value back into a blackboard
// Field_Value for the tick transaction to commit — the inverse of
// field_value_to_value over the scalar/Vec2/Ref/enum arms. A structural value
// (record/list/lambda) is not a column and yields ok=false; the tick commits a
// row by writing each field's lowered value. An enum token lowers into the
// supplied allocator (the tick arena that owns the committed version), so the
// committed row owns its string column — never the transient default allocator.
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
	case Vec2:
		return x, true
	case Ref:
		return x, true
	case Variant_Value:
		return variant_to_token(x, allocator), true
	case bool, Record_Value, List_Value, Lambda_Value:
		return nil, false
	}
	return nil, false
}

// variant_from_token splits a stored "Enum::Case" enum token into a Variant_Value
// — the stored form a blackboard enum column carries (state.odin keeps it as a
// string). A token without "::" becomes a case with an empty enum type, which a
// case-name match still reads correctly.
variant_from_token :: proc(token: string) -> Variant_Value {
	idx := strings.index(token, "::")
	if idx < 0 {
		return Variant_Value{case_name = token}
	}
	return Variant_Value{enum_type = token[:idx], case_name = token[idx + 2:]}
}

// variant_to_token renders a Variant_Value back to its "Enum::Case" stored form
// — the column shape a blackboard enum field commits as. A unit-payload variant
// stores only its tag (pong's enum columns are all unit cases like Side::Left).
variant_to_token :: proc(v: Variant_Value, allocator := context.allocator) -> string {
	if v.enum_type == "" {
		return strings.clone(v.case_name, allocator)
	}
	return strings.concatenate({v.enum_type, "::", v.case_name}, allocator)
}

// program_function finds a §9 function/const by name in the loaded program, or
// nil — the resolver eval_name and eval_call route a user-helper or const call
// through.
program_function :: proc(program: ^Program, name: string) -> ^Function_Decl {
	for &fn in program.functions {
		if fn.name == name {
			return &fn
		}
	}
	return nil
}
