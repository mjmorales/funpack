// The §08 §3 query evaluation surface: a call to a declared `query` evaluates
// its carried body as a PURE READ — the body sees only its bound parameters
// plus module consts, exactly a §9 helper's scope — and the result is
// WITHIN-TICK MEMOIZED on (query name, canonical argument bytes). A query is
// pure over its arguments (it can never mutate, §08 CQRS read side), so a memo
// hit returns the identical value the first caller paid for and every later
// caller within the tick pays once (§08 §3). The cache lives on the Tick_State,
// so the tick boundary clears it by construction; an evaluation with no tick in
// flight (a read-layer probe off a committed version) evaluates directly.
//
// INTERIM READ SHAPE, stated for the record: the spec's query reads the world
// via `all[T]` over value-only parameters, but the compiler does not yet admit
// the `all[T]` expression form — a compiled query body reads the world through
// an explicit View[T] parameter instead (bound, like a behavior's, to the
// row-list of its thing). The memo key encodes the FULL argument content, so a
// View-shaped argument memoizes soundly: a same-tick caller passing the same
// rows hits, a caller observing different working content misses. When the
// compiler lands `all[T]`, the world read moves inside the body and the key
// reduces to the spec's (version, params).
package funpack_runtime

import "core:strings"

// eval_query_call applies a declared query at a `name(args)` call site: the
// argument expressions evaluate in the CALLER's scope (left to right, the §9
// helper discipline), then the bound evaluation defers to eval_query_values —
// the single memo + body path the runtime and the test/golden drivers share.
eval_query_call :: proc(
	interp: ^Interp,
	query: ^Query_Decl,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	ok: bool,
) {
	arg_count := len(node.children) - 1
	if arg_count != len(query.params) {
		return nil, false
	}
	args := make([]Value, arg_count, interp.allocator)
	for i in 0 ..< arg_count {
		arg, arg_ok := eval(interp, &node.children[i + 1], env)
		if !arg_ok {
			return nil, false
		}
		args[i] = arg
	}
	return eval_query_values(interp, query, args)
}

// eval_query_values evaluates a query over already-evaluated argument values —
// the memoized §08 §3 read. A tick in flight consults the tick's memo first
// (key hit: the cached result, one body fold per distinct key per tick) and
// records a computed result under its key; no tick, or an argument outside the
// canonical key encoding (a lambda — nothing a compiled query signature can
// receive), evaluates directly with no cache. The body folds in a fresh scope
// binding only the declared params — a query closes over no caller locals, so
// its result is a pure function of its arguments and the memo is sound.
eval_query_values :: proc(
	interp: ^Interp,
	query: ^Query_Decl,
	args: []Value,
) -> (
	value: Value,
	ok: bool,
) {
	if len(args) != len(query.params) {
		return nil, false
	}
	key, keyed := query_memo_key(query.name, args, context.temp_allocator)
	if keyed && interp.tick != nil {
		if cached, hit := interp.tick.query_memo[key]; hit {
			interp.tick.query_memo_hits += 1
			return cached, true
		}
	}
	scope := Env {
		names = make(map[string]Value, interp.allocator),
	}
	for param, i in query.params {
		scope.names[param.name] = args[i]
	}
	value, ok = eval_body(interp, query.body, &scope)
	if ok && keyed && interp.tick != nil {
		interp.tick.query_memo_misses += 1
		interp.tick.query_memo[strings.clone(key, interp.allocator)] = value
	}
	return value, ok
}

// query_memo_key builds the canonical memo key: the query name, then each
// argument's order-preserving canonical encoding length-prefixed — framing
// every argument so two argument lists can never alias across a boundary
// (["ab"] + ["c"] never keys like ["a"] + ["bc"]). The value encoding is the
// index layer's append_value_key, so a key is exact down to the fixed-point
// bits. ok is false for an argument outside the closed encoding (a transient
// interpreter arm), which the caller treats as not-memoizable — evaluate
// directly, never a wrong cache key.
query_memo_key :: proc(
	name: string,
	args: []Value,
	allocator := context.allocator,
) -> (
	key: string,
	ok: bool,
) {
	buf := make([dynamic]u8, 0, 64, allocator)
	append(&buf, ..transmute([]u8)name)
	for arg in args {
		arg_buf := make([dynamic]u8, 0, 32, context.temp_allocator)
		if !append_value_key(&arg_buf, arg) {
			return "", false
		}
		append_biased_i64(&buf, i64(len(arg_buf)))
		append(&buf, ..arg_buf[:])
	}
	return string(buf[:]), true
}
