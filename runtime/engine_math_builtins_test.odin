// Parity + behavioral spec for the §10 engine.math computational builtins in the
// runtime interpreter (interp_call.odin eval_named_call). The runtime interp is
// declared the ground truth (§09.5), so EVERY computational name the compiler
// surface (funpack/surface.odin STDLIB_SURFACE engine.math) admits MUST resolve
// here — a name the surface accepts but the runtime drops evaluates ok=false, and
// the per-instance step loop (tick.odin) silently drops the whole blackboard write
// on !ok (no error, no diagnostic). That class of silent step-drop is exactly the
// bug space-invaders' cannon_fire hit: `max(self.cooldown - time.dt, 0.0)` was
// unwired, so the cooldown froze. This file is the regression FLOOR for the whole
// class:
//
//   1. PARITY — every engine.math computational builtin name resolves through
//      eval_named_call with ok=true (so a future surface addition that is not
//      wired into the runtime fails CI here, not silently in a shipped game).
//   2. BEHAVIORAL — max/floor/round/lerp/checked_div/etc. fold to their EXACT
//      fixed-point values through the full eval path (the kernel semantics, pinned
//      bit-for-bit to funpack/evaluate.odin's test interpreter — the determinism
//      bet, §10.5: no float ever).
//   3. THE COMMIT JUNCTION — a hand-built singleton thing whose behavior returns
//      the cannon_fire shape `(self with { f: max(self.f - dt, 0.0) }, [])` with an
//      EMPTY command list MUST COMMIT its blackboard write through a real
//      step_tick. This is the precise junction the bug lived at: eval failed inside
//      the With value expression, so fold_behavior_result never landed the write.
//      The assertion reads the COMMITTED column, not just ok=true.
//
// The names are restated here as a runtime-package constant (the runtime does not
// import funpack — §29 process boundary), so this list is the runtime's authored
// mirror of the surface partition. Growing engine.math is a deliberate edit to
// BOTH the surface table and this list, and the parity test forces the runtime
// wiring at the same time.
package funpack_runtime

import "core:strconv"
import "core:testing"

// --- the authoritative engine.math computational builtin surface ----------

// Math_Builtin_Case is one engine.math computational name plus a well-typed call
// node that exercises it — the parity sweep evaluates each and asserts ok=true.
// `node` carries the exact arg shape the surface signature declares (the typed,
// typecheck-passing form), so the resolution is over a REAL call, not a bare name
// lookup.
@(private = "file")
Math_Builtin_Case :: struct {
	name: string,
	node: Node,
}

// math_builtin_cases enumerates EVERY computational `.Func` decl the engine.math
// partition exports (funpack/surface.odin STDLIB_SURFACE), plus the prelude-owned
// to_fixed that engine.math re-exports (STDLIB_REEXPORTS). Type-constructor names
// (Vec2/Vec3/Quat/Mat4/Aabb) and value constants (pi/tau) are excluded — they are
// not call-dispatched builtins. The list is the runtime's mirror of the closed
// surface table; a name added to engine.math without a runtime case here is the
// silent-step-drop class this floor forbids.
@(private = "file")
math_builtin_cases :: proc(a := context.allocator) -> []Math_Builtin_Case {
	fx :: proc(f: Fixed, a: Runtime_Allocator) -> Node {return em_fixed_node(f, a)}
	v2 :: proc(x, y: Fixed, a: Runtime_Allocator) -> Node {return em_vec2_node(x, y, a)}
	v3 :: proc(x, y, z: Fixed, a: Runtime_Allocator) -> Node {return em_vec3_node(x, y, z, a)}

	cases := make([dynamic]Math_Builtin_Case, 0, 16, a)
	// Scalar transcendentals / roots: (Fixed) -> Fixed.
	append(&cases, Math_Builtin_Case{"sin", em_call_node(a, "sin", fx(to_fixed(0), a))})
	append(&cases, Math_Builtin_Case{"cos", em_call_node(a, "cos", fx(to_fixed(0), a))})
	append(&cases, Math_Builtin_Case{"sqrt", em_call_node(a, "sqrt", fx(to_fixed(4), a))})
	append(&cases, Math_Builtin_Case{"abs", em_call_node(a, "abs", fx(to_fixed(-3), a))})
	// (Fixed, Fixed, Fixed) -> Fixed.
	append(&cases, Math_Builtin_Case{"clamp", em_call_node(a, "clamp", fx(to_fixed(5), a), fx(to_fixed(0), a), fx(to_fixed(3), a))})
	append(&cases, Math_Builtin_Case{"lerp", em_call_node(a, "lerp", fx(to_fixed(0), a), fx(to_fixed(10), a), em_half(a))})
	// trunc/floor/round: (Fixed) -> Int.
	append(&cases, Math_Builtin_Case{"trunc", em_call_node(a, "trunc", em_half(a))})
	append(&cases, Math_Builtin_Case{"floor", em_call_node(a, "floor", em_half(a))})
	append(&cases, Math_Builtin_Case{"round", em_call_node(a, "round", em_half(a))})
	// checked_div: (Fixed, Fixed) -> Option[Fixed].
	append(&cases, Math_Builtin_Case{"checked_div", em_call_node(a, "checked_div", fx(to_fixed(6), a), fx(to_fixed(2), a))})
	// to_fixed: (Int) -> Fixed (re-exported by engine.math, owned by prelude).
	append(&cases, Math_Builtin_Case{"to_fixed", em_call_node(a, "to_fixed", em_int_node(3, a))})
	// max: (Fixed, Fixed) -> Fixed | (Int, Int) -> Int.
	append(&cases, Math_Builtin_Case{"max", em_call_node(a, "max", fx(to_fixed(1), a), fx(to_fixed(2), a))})
	// Vector ops.
	append(&cases, Math_Builtin_Case{"dot", em_call_node(a, "dot", v2(to_fixed(1), to_fixed(2), a), v2(to_fixed(3), to_fixed(4), a))})
	append(&cases, Math_Builtin_Case{"cross", em_call_node(a, "cross", v3(to_fixed(1), to_fixed(0), to_fixed(0), a), v3(to_fixed(0), to_fixed(1), to_fixed(0), a))})
	append(&cases, Math_Builtin_Case{"length", em_call_node(a, "length", v2(to_fixed(3), to_fixed(4), a))})
	append(&cases, Math_Builtin_Case{"normalize", em_call_node(a, "normalize", v2(to_fixed(3), to_fixed(4), a))})
	return cases[:]
}

// --- (1) parity: every engine.math computational name resolves -------------

// The parity floor: each enumerated engine.math builtin resolves through
// eval_named_call with ok=true on a well-typed call. A name the surface admits but
// the runtime drops fails HERE (ok=false), the same ok=false that silently drops a
// blackboard write in the step loop — so this test converts a silent-game-bug into
// a loud CI failure. sqrt and normalize have no counterpart in
// funpack/evaluate.odin's named-call switch, so the runtime is their sole
// evaluator; this floor pins the kernel any funpack impl of either must match.
@(test)
test_engine_math_builtins_all_resolve :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := new(Program, a)
	interp := Interp{program = program, allocator = a}
	cases := math_builtin_cases(a)
	for c in cases {
		node := c.node
		env := interp_empty_env()
		_, ok := eval(&interp, &node, &env)
		testing.expectf(
			t,
			ok,
			"engine.math builtin %q evaluated ok=false — a surface name unwired in the runtime interpreter silently drops the blackboard write (interp_call.odin eval_named_call)",
			c.name,
		)
	}
}

// --- (2) behavioral: exact fixed-point values through the full eval path ----

// max(Fixed, Fixed) returns the larger, kind-preserving — the EXACT cannon_fire
// case `max(self.cooldown - time.dt, 0.0)`: a positive cooldown stays positive, a
// negative one floors to 0. max(Int, Int) preserves the Int rail (the hud
// countdown). The >= tie-break returns the first arg on equality, matching
// funpack/evaluate.odin's eval_max bit-for-bit.
@(test)
test_max_fixed_and_int :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)

	// max(0.05, 0.0) -> 0.05 (cooldown mid-decrement: positive wins).
	hi := em_eval_call(&interp, a, "max", em_fixed_node(em_fx(1, 20), a), em_fixed_node(to_fixed(0), a))
	got_hi, ok_hi := hi.(Fixed)
	testing.expect(t, ok_hi)
	testing.expect_value(t, got_hi, em_fx(1, 20))

	// max(-0.05, 0.0) -> 0.0 (cooldown undershoot: the floor wins — the §ge bug
	// would have left cooldown negative without max).
	lo := em_eval_call(&interp, a, "max", em_fixed_node(fixed_neg(em_fx(1, 20)), a), em_fixed_node(to_fixed(0), a))
	got_lo, ok_lo := lo.(Fixed)
	testing.expect(t, ok_lo)
	testing.expect_value(t, got_lo, to_fixed(0))

	// max(3, 7) -> 7 on the Int rail (kind preserved, no Fixed promotion).
	int_max := em_eval_call(&interp, a, "max", em_int_node(3, a), em_int_node(7, a))
	got_int, ok_int := int_max.(i64)
	testing.expect(t, ok_int)
	testing.expect_value(t, got_int, i64(7))

	// max(5, 5) -> 5: the equality tie-break returns the first arg.
	tie := em_eval_call(&interp, a, "max", em_int_node(5, a), em_int_node(5, a))
	got_tie, _ := tie.(i64)
	testing.expect_value(t, got_tie, i64(5))
}

// floor/round/trunc reduce a Fixed to an Int (the surface types them (Fixed) ->
// Int), each rounding by its rule — bit-identical to the funpack kernel copy. 2.5
// floors to 2, rounds to 3 (ties away from zero), truncs to 2; -2.5 floors to -3,
// rounds to -3, truncs to -2.
@(test)
test_floor_round_trunc_to_int :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)

	pos := em_fx(5, 2) // 2.5
	neg := fixed_neg(pos) // -2.5

	expect_int(t, em_eval_call(&interp, a, "floor", em_fixed_node(pos, a)), 2, "floor(2.5)")
	expect_int(t, em_eval_call(&interp, a, "round", em_fixed_node(pos, a)), 3, "round(2.5)")
	expect_int(t, em_eval_call(&interp, a, "trunc", em_fixed_node(pos, a)), 2, "trunc(2.5)")
	expect_int(t, em_eval_call(&interp, a, "floor", em_fixed_node(neg, a)), -3, "floor(-2.5)")
	expect_int(t, em_eval_call(&interp, a, "round", em_fixed_node(neg, a)), -3, "round(-2.5)")
	expect_int(t, em_eval_call(&interp, a, "trunc", em_fixed_node(neg, a)), -2, "trunc(-2.5)")
}

// lerp(a, b, t) is a + (b - a) * t over the kernel: lerp(0, 10, 0.25) = 2.5, exact
// in Q32.32 (0.25 is a perfect power-of-two fraction). The endpoints are exact:
// lerp(0,10,0) = 0, lerp(0,10,1) = 10.
@(test)
test_lerp_fixed :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)
	quarter := em_fx(1, 4)

	mid := em_eval_call(&interp, a, "lerp", em_fixed_node(to_fixed(0), a), em_fixed_node(to_fixed(10), a), em_fixed_node(quarter, a))
	got, ok := mid.(Fixed)
	testing.expect(t, ok)
	testing.expect_value(t, got, em_fx(5, 2)) // 2.5

	zero := em_eval_call(&interp, a, "lerp", em_fixed_node(to_fixed(0), a), em_fixed_node(to_fixed(10), a), em_fixed_node(to_fixed(0), a))
	zg, _ := zero.(Fixed)
	testing.expect_value(t, zg, to_fixed(0))

	one := em_eval_call(&interp, a, "lerp", em_fixed_node(to_fixed(0), a), em_fixed_node(to_fixed(10), a), em_fixed_node(to_fixed(1), a))
	og, _ := one.(Fixed)
	testing.expect_value(t, og, to_fixed(10))
}

// checked_div surfaces the zero divisor as Option::None instead of saturating, and
// wraps a real quotient in Option::Some — the runtime Option representation
// (Variant_Value "Option"). 6/2 = Some(3); 6/0 = None.
@(test)
test_checked_div_option :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)

	some := em_eval_call(&interp, a, "checked_div", em_fixed_node(to_fixed(6), a), em_fixed_node(to_fixed(2), a))
	sv, is_variant := some.(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, sv.enum_type, "Option")
	testing.expect_value(t, sv.case_name, "Some")
	testing.expect(t, sv.payload != nil)
	if sv.payload != nil {
		q, q_ok := sv.payload^.(Fixed)
		testing.expect(t, q_ok)
		testing.expect_value(t, q, to_fixed(3))
	}

	none := em_eval_call(&interp, a, "checked_div", em_fixed_node(to_fixed(6), a), em_fixed_node(to_fixed(0), a))
	nv, n_variant := none.(Variant_Value)
	testing.expect(t, n_variant)
	testing.expect_value(t, nv.enum_type, "Option")
	testing.expect_value(t, nv.case_name, "None")
}

// sqrt/cos/dot/cross/normalize fold to their exact kernel values. sqrt(4)=2 (a
// perfect square, bit-exact). cos(0)=1. dot({1,2},{3,4}) = 1*3 + 2*4 = 11.
// cross(x̂, ŷ) = ẑ. normalize({3,4}) = {0.6, 0.8} (3-4-5 triangle, length 5).
@(test)
test_sqrt_cos_dot_cross_normalize :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)

	root := em_eval_call(&interp, a, "sqrt", em_fixed_node(to_fixed(4), a))
	rg, r_ok := root.(Fixed)
	testing.expect(t, r_ok)
	testing.expect_value(t, rg, to_fixed(2))

	cosine := em_eval_call(&interp, a, "cos", em_fixed_node(to_fixed(0), a))
	cg, c_ok := cosine.(Fixed)
	testing.expect(t, c_ok)
	testing.expect_value(t, cg, FIXED_ONE)

	d := em_eval_call(&interp, a, "dot", em_vec2_node(to_fixed(1), to_fixed(2), a), em_vec2_node(to_fixed(3), to_fixed(4), a))
	dg, d_ok := d.(Fixed)
	testing.expect(t, d_ok)
	testing.expect_value(t, dg, to_fixed(11))

	x := em_eval_call(&interp, a, "cross", em_vec3_node(to_fixed(1), to_fixed(0), to_fixed(0), a), em_vec3_node(to_fixed(0), to_fixed(1), to_fixed(0), a))
	xg, x_ok := x.(Vec3)
	testing.expect(t, x_ok)
	testing.expect_value(t, xg, Vec3{to_fixed(0), to_fixed(0), to_fixed(1)})

	unit := em_eval_call(&interp, a, "normalize", em_vec2_node(to_fixed(3), to_fixed(4), a))
	ug, u_ok := unit.(Vec2)
	testing.expect(t, u_ok)
	// 3/5 = 0.6, 4/5 = 0.8 over the kernel (bit-exact: div by an exact length).
	testing.expect_value(t, ug.x, fixed_div(to_fixed(3), to_fixed(5)))
	testing.expect_value(t, ug.y, fixed_div(to_fixed(4), to_fixed(5)))
}

// --- (3) the commit junction: the empty-list (Thing, [Command]) write -------

// THE BUG'S EXACT JUNCTION, self-contained. A singleton Cannon with a `cooldown:
// Fixed` column runs a cannon_fire-shaped behavior: `return (self with { cooldown:
// max(self.cooldown - dt, 0.0) }, [])`. The command list is EMPTY — the red herring
// the friction report blamed; the real failure was that max() evaluated ok=false
// INSIDE the With value, so eval_behavior_body returned ok=false and the step loop
// dropped the whole write at tick.odin (`if !ok { continue }`), freezing cooldown.
// This drives a REAL step_tick (eval -> fold_behavior_result -> commit) and asserts
// the COMMITTED cooldown DECREMENTED by dt — the value must land, not just resolve.
// Two ticks prove it keeps decrementing (the frozen-at-0.35 symptom was a stuck
// value across every subsequent tick), and the floor holds at 0 (max never goes
// negative).
@(test)
test_cooldown_decrement_commits_with_empty_command_list :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := em_cannon_program(a)

	world := new_world(program, a)
	base := initial_version(world, a)
	base = run_startup(&program, base, a)

	// Startup seeded one Cannon with cooldown = 0.35 (the post-fire state the bug
	// froze at).
	start_cd := em_cannon_cooldown(t, &base)
	testing.expect_value(t, start_cd, em_fx(35, 100)) // 0.35

	dt := em_dt_60hz()
	time := em_time(dt, a)

	// Tick 1: cooldown must drop by dt to 0.35 - 1/60. Pre-fix this was DROPPED and
	// cooldown stayed 0.35 (the frozen symptom).
	next1 := step_tick(&program, base, empty(), time, a)
	cd1 := em_cannon_cooldown(t, &next1)
	testing.expect_value(t, cd1, fixed_sub(em_fx(35, 100), dt))
	testing.expectf(t, cd1 != start_cd, "cooldown FROZE at %v — the empty-list step was dropped (the bug)", start_cd)

	// Tick 2: it keeps decrementing — not stuck at the tick-1 value.
	next2 := step_tick(&program, next1, empty(), time, a)
	cd2 := em_cannon_cooldown(t, &next2)
	testing.expect_value(t, cd2, fixed_sub(cd1, dt))
}

// The max floor holds inside the committed write: a cooldown already at 0 stays at
// 0 (max(0 - dt, 0) = 0), never going negative — proving the max() inside the With
// is the floor, committed through the same empty-list path.
@(test)
test_cooldown_floor_holds_at_zero :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := em_cannon_program_with_cooldown(a, to_fixed(0))

	world := new_world(program, a)
	base := run_startup(&program, initial_version(world, a), a)
	testing.expect_value(t, em_cannon_cooldown(t, &base), to_fixed(0))

	dt := em_dt_60hz()
	next := step_tick(&program, base, empty(), em_time(dt, a), a)
	// max(0 - dt, 0) = 0 — the floor commits, no negative cooldown.
	testing.expect_value(t, em_cannon_cooldown(t, &next), to_fixed(0))
}

// --- the hand-built Cannon program -----------------------------------------

// em_cannon_program builds a minimal one-singleton program: a Cannon thing with a
// `cooldown: Fixed` column, a `cannon_fire`-shaped behavior on a control stage, a
// one-step pipeline, and a setup spawn seeding cooldown = 0.35 (the post-fire
// state). This is the substrate the commit-junction tests fold over — the SAME
// shape space-invaders' cannon_fire decrement path takes, hand-built so the test
// is self-contained (no cross-repo artifact path).
@(private = "file")
em_cannon_program :: proc(a := context.allocator) -> Program {
	return em_cannon_program_with_cooldown(a, em_fx(35, 100))
}

// em_cannon_program_with_cooldown parameterizes the seeded cooldown so a test can
// start at the floor (0) or mid-decrement (0.35). The cooldown is the singleton's
// FIELD DEFAULT (a singleton is engine-spawned from its defaulted schema before
// tick 0, never by a setup Spawn — §06 §2), encoded as the kernel's raw Q32.32
// bits the same way the funpack emitter would write a Fixed default.
@(private = "file")
em_cannon_program_with_cooldown :: proc(a: Runtime_Allocator, cooldown: Fixed) -> Program {
	things := make([]Thing_Decl, 1, a)
	cannon_fields := make([]Field_Decl, 1, a)
	cannon_fields[0] = Field_Decl{name = "cooldown", type = "Fixed", has_default = true, default_encoded = em_fixed_bits(cooldown, a)}
	things[0] = Thing_Decl{name = "Cannon", singleton = true, fields = cannon_fields}

	behaviors := make([]Behavior_Decl, 1, a)
	behaviors[0] = em_cannon_fire_behavior(a)

	pipeline := make([]Pipeline_Step, 1, a)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "control", behavior = "cannon_fire"}

	return Program{things = things, behaviors = behaviors, pipeline = pipeline}
}

// em_cannon_fire_behavior builds the decrement arm of cannon_fire verbatim in node
// form: `return (self with { cooldown: max(self.cooldown - dt, 0.0) }, [])`. The
// dt comes off a `time: Time` param (time.dt), the command list is empty — the
// exact (Thing, [Command]) empty-list shape the bug dropped.
@(private = "file")
em_cannon_fire_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "self", type = "Cannon"}
	params[1] = Param_Decl{name = "time", type = "Time"}
	// The emit shape is the (Thing, [Command]) tuple cannon_fire returns: a Cannon
	// blackboard write paired with a [Spawn] command list (a bullet on the fire
	// edge, empty on the decrement tick). The DECLARED tuple type is load-bearing —
	// fold_tuple_emit splits the return by this type (split_tuple_type), so the
	// first half routes to the Cannon blackboard write and the second to the spawn
	// batch. Without the declared tuple type the fold falls back to a value-arm split
	// that IGNORES the Record_Value half — the write would silently not commit (the
	// fold-side twin of the eval-side silent drop this story closes).
	emits := make([]string, 1, a)
	emits[0] = "(Cannon, [Spawn])"

	// max(self.cooldown - time.dt, 0.0)
	decrement := em_binary_node(
		"sub",
		em_field_node(em_name_node("self", a), "cooldown", a),
		em_field_node(em_name_node("time", a), "dt", a),
		a,
	)
	floored := em_call_node(a, "max", decrement, em_fixed_node(to_fixed(0), a))
	updated := em_with_node(em_name_node("self", a), a, em_recfield("cooldown", floored))

	// return (self with { ... }, [])
	body := make([]Node, 1, a)
	body[0] = em_return_node(em_tuple_node(a, updated, em_empty_list_node(a)), a)
	return Behavior_Decl{name = "cannon_fire", on_thing = "Cannon", stage = "control", params = params, emits = emits, body = body}
}

// em_cannon_cooldown reads the committed singleton Cannon's cooldown column — the
// COMMITTED value the junction test asserts (not the returned tuple). A singleton
// is read by type (singleton_row), never iterated (§06 §2).
@(private = "file")
em_cannon_cooldown :: proc(t: ^testing.T, version: ^World_Version) -> Fixed {
	row, ok := singleton_row(version, "Cannon")
	testing.expect(t, ok)
	cd, present := row_field(row, "cooldown")
	testing.expect(t, present)
	f, is_fixed := cd.(Fixed)
	testing.expect(t, is_fixed)
	return f
}

// --- value/node + driver helpers -------------------------------------------

// em_fx builds the Fixed fraction num/den over the kernel — the readable form of a
// tuning value (em_fx(1, 20) is 0.05, em_fx(35, 100) is 0.35), bit-exact through
// fixed_div so the expected value is the SAME bits the body folds.
@(private = "file")
em_fx :: proc(num, den: i64) -> Fixed {
	return fixed_div(to_fixed(num), to_fixed(den))
}

// em_half is 0.5 (a perfect power-of-two fraction) — the lerp t and the
// floor/round/trunc parity arg.
@(private = "file")
em_half :: proc(a: Runtime_Allocator) -> Node {
	return em_fixed_node(em_fx(1, 2), a)
}

// em_dt_60hz is the fixed 60hz step (1/60 in Q32.32) — the time.dt the cannon
// decrements by each tick.
@(private = "file")
em_dt_60hz :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

// em_time builds the minimal Time resource (one `dt` field) a behavior's `time`
// param binds to.
@(private = "file")
em_time :: proc(dt: Fixed, a: Runtime_Allocator) -> Record_Value {
	fields := make(map[string]Value, a)
	fields["dt"] = dt
	return Record_Value{type_name = "Time", fields = fields}
}

// em_bare_interp builds a program-less interpreter over the test arena — the
// computational builtins are leaf evaluators that never reach a user helper.
@(private = "file")
em_bare_interp :: proc(a: Runtime_Allocator) -> Interp {
	program := new(Program, a)
	return Interp{program = program, allocator = a}
}

// interp_empty_env builds a fresh empty scope — the parity sweep's leaf calls bind
// no names.
@(private = "file")
interp_empty_env :: proc() -> Env {
	return Env{names = make(map[string]Value, context.temp_allocator)}
}

// em_eval_call builds and folds a `name(args)` call through the full eval path,
// returning the value (ok dropped — the callers assert the concrete type).
@(private = "file")
em_eval_call :: proc(interp: ^Interp, a: Runtime_Allocator, name: string, args: ..Node) -> Value {
	node := em_call_node(a, name, ..args)
	env := interp_empty_env()
	value, _ := eval(interp, &node, &env)
	return value
}

// em_fixed_node builds a `.Fixed` literal node carrying the raw Q32.32 bits token
// decode_fixed parses back.
@(private = "file")
em_fixed_node :: proc(f: Fixed, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = em_fixed_bits(f, a)
	return Node{kind = .Fixed, fields = fields}
}

// em_fixed_bits renders a Fixed's raw Q32.32 bits to the decimal token the .Fixed
// node carries.
@(private = "file")
em_fixed_bits :: proc(f: Fixed, a := context.allocator) -> string {
	buf := make([]u8, 24, a)
	return strconv.write_int(buf, i64(f), 10)
}

// em_int_node builds a `.Int` literal node carrying the plain decimal token
// decode_int parses back.
@(private = "file")
em_int_node :: proc(n: i64, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	buf := make([]u8, 24, a)
	fields[0] = strconv.write_int(buf, n, 10)
	return Node{kind = .Int, fields = fields}
}

// em_vec2_node builds a `Vec2{x, y}` record node (collapses to a Vec2 value).
@(private = "file")
em_vec2_node :: proc(x, y: Fixed, a := context.allocator) -> Node {
	return em_record_node(a, "Vec2", em_recfield("x", em_fixed_node(x, a)), em_recfield("y", em_fixed_node(y, a)))
}

// em_vec3_node builds a `Vec3{x, y, z}` record node (collapses to a Vec3 value).
@(private = "file")
em_vec3_node :: proc(x, y, z: Fixed, a := context.allocator) -> Node {
	return em_record_node(
		a,
		"Vec3",
		em_recfield("x", em_fixed_node(x, a)),
		em_recfield("y", em_fixed_node(y, a)),
		em_recfield("z", em_fixed_node(z, a)),
	)
}

// Em_Recfield is one `name = value` pair of a record/with update.
@(private = "file")
Em_Recfield :: struct {
	name:  string,
	value: Node,
}

// em_recfield is the terse Em_Recfield constructor.
@(private = "file")
em_recfield :: proc(name: string, value: Node) -> Em_Recfield {
	return Em_Recfield{name = name, value = value}
}

// em_recfield_node builds a `.Recfield` child node (`recfield NAME` over its one
// value child) — the field-update form a record/with node carries.
@(private = "file")
em_recfield_node :: proc(spec: Em_Recfield, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = spec.name
	children := make([]Node, 1, a)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

// em_record_node builds a `.Record` literal node with one recfield child per pair.
@(private = "file")
em_record_node :: proc(a: Runtime_Allocator, type_name: string, specs: ..Em_Recfield) -> Node {
	fields := make([]string, 2, a)
	fields[0] = type_name
	buf := make([]u8, 8, a)
	fields[1] = strconv.write_int(buf, i64(len(specs)), 10)
	children := make([]Node, len(specs), a)
	for spec, i in specs {
		children[i] = em_recfield_node(spec, a)
	}
	return Node{kind = .Record, fields = fields, children = children}
}

// em_name_node builds a `name N` reference node.
@(private = "file")
em_name_node :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

// em_field_node builds a `recv.FIELD` read node over a single receiver child.
@(private = "file")
em_field_node :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

// em_binary_node builds a `.Binary` op node (`binary OP` over lhs/rhs children) —
// the `self.cooldown - time.dt` subtraction.
@(private = "file")
em_binary_node :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

// em_call_node builds a `.Call` node: child[0] is the callee `name`, children[1:]
// the positional arg nodes the builtin reads.
@(private = "file")
em_call_node :: proc(a: Runtime_Allocator, callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = em_name_node(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

// em_with_node builds a `.With` functional-update node (`base with { specs… }`) —
// the `self with { cooldown: … }` record update. child[0] is the base, children[1:]
// the recfield updates.
@(private = "file")
em_with_node :: proc(base: Node, a: Runtime_Allocator, specs: ..Em_Recfield) -> Node {
	children := make([]Node, len(specs) + 1, a)
	children[0] = base
	for spec, i in specs {
		children[i + 1] = em_recfield_node(spec, a)
	}
	return Node{kind = .With, children = children}
}

// em_return_node builds a `.Return` statement node over its one value child.
@(private = "file")
em_return_node :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}

// em_tuple_node builds a `.Tuple` literal node — the (Thing, [Command]) pair a
// behavior returns.
@(private = "file")
em_tuple_node :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	copy(children, elements)
	return Node{kind = .Tuple, children = children}
}

// em_empty_list_node builds an empty `.List` literal node — the `[]` command list
// the decrement arm returns (the bug's red herring; the eval failed before the
// list ever mattered).
@(private = "file")
em_empty_list_node :: proc(a: Runtime_Allocator) -> Node {
	return Node{kind = .List, children = make([]Node, 0, a)}
}

// expect_int asserts a Value is an i64 equal to want — the trunc/floor/round result
// assertion (those return Int, not Fixed).
@(private = "file")
expect_int :: proc(t: ^testing.T, v: Value, want: i64, label: string) {
	got, ok := v.(i64)
	testing.expectf(t, ok, "%s: expected Int, got %v", label, v)
	testing.expectf(t, got == want, "%s: got %d, want %d", label, got, want)
}
