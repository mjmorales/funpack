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
import "core:strconv"
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

// Lambda_Value is an evaluated lambda closure: its parameter names in order, its
// body node, and the captured environment it closes over. Most combinators apply
// a unary lambda per element (pong's `pad => overlaps(...)`, snake's `f => f.cell`);
// grid_cells applies a binary `fn(x, y) -> Cell`, so the arity is the param count,
// not a fixed one. apply_lambda binds the unary case, apply_two_arg_lambda the
// binary case.
Lambda_Value :: struct {
	params:   []string,
	body:     ^Node,
	captured: ^Env,
}

// String_Value is an evaluated, fully-interpolated String literal: the concrete
// bytes a `[Draw]` Text command carries (§20). A funpack String appears only in a
// render text node, so this arm exists for the render projection alone — the
// interpolation holes (`{self.left}`) are resolved against the behavior's bound
// `self` at evaluation time, so the value is the final rendered text, not a
// template. The bytes live in the evaluation arena.
String_Value :: struct {
	text: string,
}

// Tuple_Value is an evaluated fixed-arity positional aggregate `(a, b, …)` — the
// shape a seeded draw and an RNG-threaded behavior return: `pick(free, rng)`
// yields `(Option, Rng)` and a replenish/setup step returns `(Rng, [Spawn])`
// (spec §04 §1 — every draw returns the pair `(value, next_rng)`). It is NOT a
// blackboard column (a tuple never lands in a Row); it lives only in flight, as a
// match scrutinee a tuple pattern destructures or a behavior return the tick
// splits into its Rng + emit halves. Elements are in positional source order; the
// slice is owned by the evaluation arena.
Tuple_Value :: struct {
	elements: []Value,
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
	String_Value, // an interpolated String literal (render [Draw] text only, §20)
	Tuple_Value, // a positional aggregate `(a, b)` — a draw's (value, next_rng), §04 §1
	Rng, // a first-class threaded PRNG resource (§26): pick consumes it, a draw returns the advanced one
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
// (its functions and consts), the committed version a View falls back to, the
// in-flight working tables a mid-tick cross-thing read observes, the input
// snapshot a `value`/`pressed` query reads, the time resource a `dt` read
// resolves, and the evaluation allocator the value tree is built in. It is the
// world a behavior observes; the behavior's writes are its return, folded by the
// tick transaction, never a field of this context.
//
// Mid-tick read consistency (§08: "within a tick the population is fixed while
// blackboard writes fold forward, so a mid-tick query sees a stable set of rows
// with evolving columns"; §07 §4: "a stage sees every earlier stage's writes").
// A View[T] binding and a Ref resolution observe the WORKING tables `tick`
// points at — the in-flight rows the stage fold mutates in place — so a later
// stage reads the SAME-TICK writes of an earlier stage (evolving columns). The
// working row SET was materialized at tick start and only columns evolve
// (spawns/despawns land at the boundary), so population fixity holds. When `tick`
// is nil (a pure read-layer evaluation with no fold in flight) the read falls
// back to `version`, the committed snapshot.
Interp :: struct {
	program:   ^Program,
	version:   ^World_Version, // the committed version a read falls back to when no tick is in flight
	tick:      ^Tick_State, // the in-flight working tables a mid-tick cross-thing read observes; nil off a fold
	input:     Input, // the §23 action snapshot a behavior queries
	time:      Record_Value, // the Time resource: { dt: Fixed }
	registry:  Action_Registry, // the §23 action registry, minted ONCE per program (interp_call.odin reads it)
	allocator: Runtime_Allocator,
}

// new_interp builds the read-only context a tick fold (or a render pass) threads,
// minting the §23 action registry ONCE here so `input.value` never rebuilds it
// per behavior-instance per tick — the registry is a pure function of the program,
// so one program-scoped copy serves every input query the run evaluates. The
// caller supplies the committed version a read falls back to, the in-flight tick
// state (nil off a fold), and the Input/Time resources the behaviors observe.
new_interp :: proc(
	program: ^Program,
	version: ^World_Version,
	tick: ^Tick_State,
	input: Input,
	time: Record_Value,
	allocator := context.allocator,
) -> Interp {
	return Interp {
		program = program,
		version = version,
		tick = tick,
		input = input,
		time = time,
		registry = build_action_registry(program^, allocator),
		allocator = allocator,
	}
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
		case .Int, .Fixed, .Name, .String, .Field, .Call, .Variant, .Record, .Recfield, .With, .List, .Tuple, .Lambda, .Unary, .Binary, .Match, .Arm:
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
		// A String literal appears only in a render [Draw] text node (§20); the
		// executed control/collision/scoring stages carry none. The decoded template
		// has its `{recv.field}` interpolation holes resolved against the bound `self`
		// here, so the value is the FINAL rendered text the draw-list asserts.
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

// eval_name resolves an identifier: the Bool literals `true`/`false` (the §2
// `encode_literal` spelling for a Bool — a bare-name node, not a variant), then a
// local binding (param / let / lambda binder), walking the scope chain; otherwise
// a module-level const or a nullary function evaluated on demand (BOARD reads this
// way). A local binding shadows the literals only if a program ever bound a name
// `true`/`false` (it cannot — they are reserved), so checking the literal first is
// safe and lets snake's `grow: false` recfield resolve. An unbound name is ok=false.
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
		// dangling Ref has no field, so the read takes the absent arm. Resolved
		// through the tick's working rows when a fold is in flight, so the join
		// reads the referent's SAME-TICK writes (evolving columns, §08 / §07 §4).
		row, some := interp_resolve_ref(interp, r)
		if !some {
			return nil, false
		}
		fv, present := row.fields[field]
		if !present {
			return nil, false
		}
		return field_value_to_value(fv), true
	case i64, Fixed, bool, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng:
		// A tuple is positional (read by a tuple pattern, never by name) and an Rng
		// has no field — neither is a `recv.field` receiver.
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
// A field the literal OMITS is filled from the type's §06 declared default — so
// `Snake{}` evaluates to a Snake carrying head/body/dir/grow/state, the same way
// a `setup` Spawn fills omitted fields, and a later `snake.head` read never faults
// on an absent column (§03 §1, §06).
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
	fill_record_defaults(interp, type_name, &fields)
	return Record_Value{type_name = type_name, fields = fields}, true
}

// fill_record_defaults fills any field a record literal omitted with the type's
// §06 declared default, looked up in the program's thing then data decls. A field
// already supplied is left untouched (an explicit value overrides the default);
// an undecodable default is skipped, leaving the field absent. The decoded
// default is lifted from a Field_Value column to an interpreter Value so the
// filled record carries the same value shape an explicit literal would.
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

// record_field_decls returns a type's declared §06 fields — a thing's blackboard
// schema or a data type's field list — or nil for an unknown/built-in type
// (Vec2, handled separately). It is the schema lookup eval_record reads to fill a
// record literal's omitted defaults.
record_field_decls :: proc(program: ^Program, type_name: string) -> []Field_Decl {
	if thing := program_thing(program, type_name); thing != nil {
		return thing.fields
	}
	if data := program_data(program, type_name); data != nil {
		return data.fields
	}
	return nil
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
	case i64, Fixed, bool, Ref, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng:
		// A `with` is a record/Vec2 functional update; a tuple/Rng is not a record.
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

// eval_tuple builds a `(a, b, …)` tuple literal: `tuple ELEM_COUNT` with one child
// per positional element, evaluated left-to-right so the elements keep their
// deterministic source order (§04 §1 — `(value, next_rng)` is value-then-rng). A
// tuple is the in-flight aggregate a draw returns and a tuple pattern destructures;
// it never lowers to a blackboard column, so it exists only between a draw and the
// match (or the behavior return) that consumes it.
eval_tuple :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	elements := make([]Value, len(node.children), interp.allocator)
	for &child, i in node.children {
		ev, ev_ok := eval(interp, &child, env)
		if !ev_ok {
			return nil, false
		}
		elements[i] = ev
	}
	return Tuple_Value{elements = elements}, true
}

// eval_lambda closes a lambda over its current environment: `lambda PARAM_COUNT
// PARAM…` with the body as child[0]. fields[0] is the param count, fields[1:] the
// binder names in order — one for pong's `pad => …`, two for snake's grid_cells
// `fn(x, y) => …`. The closure captures `env` so the body sees outer names.
eval_lambda :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> Value {
	params := node.fields[1:]
	return Lambda_Value{params = params, body = &node.children[0], captured = env}
}

// eval_unary applies a unary operator: `neg` (Fixed/Int/Vec2 negation, the
// kernel's saturating negate, total at the rails) or `not` (Bool logical
// negation, snake's `not contains(occ, c)` free-cell predicate). An operator on
// the wrong operand arm is ok=false.
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
		case bool, Ref, Record_Value, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng:
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
// by their kernel-stable bits; an enum value and a record (`data`) compare by
// structural equality (§03 — every `data` carries universal `Eq`, so snake's
// `f.cell == self.head` and `contains` over Cell records resolve here). A
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
	case Variant_Value, Record_Value:
		// An enum or a `data` record is an equality-only comparison (§03 universal
		// Eq): `eq`/`ne` is structural, an ordered op over these shapes is malformed.
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

// values_equal is structural value equality over the §03 universal-Eq surface:
// two values are equal when they share an arm and that arm's contents match. A
// `data` record compares field-by-field by name (order-independent — the map is
// the canonical shape), an enum compares type+case+payload, a list compares
// length-then-elementwise in order, and the scalar arms compare by their
// kernel-stable bits. A cross-arm comparison (Int vs record) is never equal. This
// is the equality `contains`/`filter`/the `==` operator fold through over Cell
// records (snake's free-cell selection); a non-comparable arm (lambda) is never
// equal, since a closure has no value identity.
values_equal :: proc(a, b: Value) -> bool {
	switch av in a {
	case i64:
		bv, ok := b.(i64)
		return ok && av == bv
	case Fixed:
		// A Fixed and an Int never share an arm here — the checked AST keeps an `==`
		// on one numeric kind, so a Fixed compares only to a Fixed by its raw bits.
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
		// A unit variant has nil payload on both sides; a single-payload variant
		// (Option::Some(x)) compares its boxed payloads structurally.
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
	case Tuple_Value:
		// A tuple compares positionally — same arity, then each position structurally
		// in order (the same length-then-elementwise rule as a list).
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
	case Lambda_Value, String_Value, Rng:
		// A closure has no value identity, a String is render-only, and an Rng is a
		// threaded resource — none is a comparand the §03 Eq surface admits.
		return false
	}
	return false
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

// string_value interpolates a decoded String literal template into the final
// rendered text (§20). The template carries `{recv.field}` holes (pong's score
// readout is `{self.left}   {self.right}`); each hole is resolved against the
// bound `env` — the receiver name looked up, the field read, the value formatted
// — and the literal text between holes is copied verbatim. A hole that does not
// resolve renders empty, so a render behavior never faults on a missing column.
// A funpack String appears ONLY in a render text node, so this is the render
// projection's string completion, evaluated against the behavior's `self`.
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
			// An unterminated hole is copied verbatim — the template is malformed but
			// the projection stays total.
			strings.write_string(&b, rest[open:])
			break
		}
		hole := rest[open + 1:open + close]
		strings.write_string(&b, interpolate_hole(interp, hole, env))
		rest = rest[open + close + 1:]
	}
	return String_Value{text = strings.to_string(b)}
}

// interpolate_hole resolves one `recv.field` template hole against the bound
// environment, returning the formatted text of the field value. The hole splits
// on the first `.` into a receiver name (a behavior param like `self`) and a
// field name; the receiver is looked up in scope and the field read off its
// record/blackboard. An unresolved receiver, field, or non-`recv.field` shape
// renders empty (the projection stays total, never faulting on a bad template).
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

// format_value renders a scalar blackboard value to its display text for a §20
// Text command. An Int renders its decimal digits; a Fixed renders its truncated
// integer part (pong's score columns are Ints, so the integer rendering is what
// the score readout asserts); an enum value renders its case name. A structural
// value (record/list) has no display form here and renders empty.
format_value :: proc(interp: ^Interp, v: Value) -> string {
	switch x in v {
	case i64:
		return aprint_int(x, interp.allocator)
	case Fixed:
		return aprint_int(fixed_trunc(x), interp.allocator)
	case Variant_Value:
		return strings.clone(x.case_name, interp.allocator)
	case bool, Vec2, Ref, Record_Value, List_Value, Lambda_Value, String_Value, Tuple_Value, Rng:
		// A tuple/Rng never reaches a §20 Text hole (render carries no draw); no
		// display form, render empty.
		return ""
	}
	return ""
}

// aprint_int renders a signed integer to its decimal text in the supplied arena —
// the digits a §20 Text hole substitutes for an Int/Fixed column.
aprint_int :: proc(n: i64, allocator := context.allocator) -> string {
	buf: [32]byte
	return strings.clone(strconv.write_int(buf[:], n, 10), allocator)
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
	case bool, Vec2, Ref, Record_Value, List_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Rng:
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
// scalar/Bool/Vec2/Ref and the structural Record/List arms; a stored enum token
// (a string column) becomes a Variant_Value by splitting its "Enum::Case" form so
// a match can read the case. A Record_Value/List_Value column lifts unchanged —
// the column already holds the same value shape (snake's `head: Cell` / `body:
// [Cell]`), so a `self.head` field read and a `contains(self.body, …)` fold see
// the committed structural value directly.
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
	case Ref:
		return v
	case Record_Value:
		return v
	case List_Value:
		return v
	case string:
		return variant_from_token(v)
	}
	return nil
}

// value_to_field_value lowers an interpreter Value back into a blackboard
// Field_Value for the tick transaction to commit — the inverse of
// field_value_to_value over the scalar/Bool/Vec2/Ref/enum AND the structural
// Record/List arms. A Bool/Record/List lowers into a real column (snake's `grow`,
// `head`, `body`); a Record/List is cloned into the supplied allocator (the tick
// arena that owns the committed version) so the committed row owns its structural
// column independent of the transient eval arena, exactly as the enum-token arm
// clones its string. A genuinely non-column value (lambda / render String / a
// tuple split before commit / a threaded Rng) yields ok=false; the commit path
// skips it, leaving the prior column.
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
	case Ref:
		return x, true
	case Variant_Value:
		return variant_to_token(x, allocator), true
	case Record_Value:
		return clone_record_value(x, allocator), true
	case List_Value:
		return clone_list_value(x, allocator), true
	case Lambda_Value, String_Value, Tuple_Value, Rng:
		// A String is render-only (§20 Text); a Tuple is split by the tick into its
		// halves before commit and never lands whole on a row; an Rng is THREADED
		// (carried in Tick_State, written forward), never persisted as a column. None
		// is a blackboard column — the commit path treats them as no-column values.
		return nil, false
	}
	return nil, false
}

// clone_record_value deep-copies a Record_Value into the supplied allocator so a
// committed structural column outlives the transient eval arena it was built in —
// the structural analog of variant_to_token's string clone. Each field value is
// recursively cloned (a nested record/list/Vec2 too), so the committed `head:
// Cell` carries no pointer back into the freed tick-temp arena.
clone_record_value :: proc(rec: Record_Value, allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, len(rec.fields), allocator)
	for k, v in rec.fields {
		fields[strings.clone(k, allocator)] = clone_column_value(v, allocator)
	}
	return Record_Value{type_name = strings.clone(rec.type_name, allocator), fields = fields}
}

// clone_list_value deep-copies a List_Value (snake's `body: [Cell]`) into the
// supplied allocator, recursively cloning each element, so the committed list
// column owns its elements in the tick arena, never the freed eval arena.
clone_list_value :: proc(list: List_Value, allocator := context.allocator) -> List_Value {
	elements := make([]Value, len(list.elements), allocator)
	for elem, i in list.elements {
		elements[i] = clone_column_value(elem, allocator)
	}
	return List_Value{elements = elements}
}

// clone_column_value deep-copies one column-shaped Value into the supplied
// allocator. The scalar/Vec2/Ref/Bool arms copy by value; an enum Variant_Value
// keeps its split form; a nested Record/List recurses. A non-column value
// (lambda / render String / tuple / Rng) is not stored in a structural column, so
// it copies by value as a defensive identity — value_to_field_value already
// excludes the standalone forms.
clone_column_value :: proc(v: Value, allocator := context.allocator) -> Value {
	switch x in v {
	case Record_Value:
		return clone_record_value(x, allocator)
	case List_Value:
		return clone_list_value(x, allocator)
	case Variant_Value:
		return clone_variant_value(x, allocator)
	case i64, Fixed, bool, Vec2, Ref, Lambda_Value, String_Value, Tuple_Value, Rng:
		return v
	}
	return v
}

// clone_variant_value deep-copies a Variant_Value's tag strings and its optional
// payload into the supplied allocator, so a Variant nested in a committed
// structural column owns its bytes in the tick arena.
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
