// The hand-built hunt Program the AI-fold proof (hunt_ai_test.odin) executes
// over — hunt's enums, things, decomposed AI functions, the think behavior, the
// module consts, and the setup spawn batch, every body built node-by-node as a
// §2.7 checked-AST forest. The hunt ARTIFACT (testdata) is the sibling-compiler
// epic's leaf (team Lore #7 ownership boundary, Lore #8 build order); runtime
// proves the engine arms compose ahead of it on this hand-built fixture, the
// interp_test/state_test/tick_view_test pattern.
//
// The function bodies mirror hunt.fun verbatim in node form, so the interpreter
// evaluates hunt's REAL decomposition — step_to (length-gated motion), visible
// (a first(view, pred) perception predicate returning Option), patrol/chase/
// search (match-with-binder transitions over `seen`), seek (the Fixed countdown),
// and think (sense-once then match self.ai). The package-visible builders
// (hunt_program / hunt_call_two / hunt_call_three) are read by hunt_ai_test.odin;
// the node constructors stay file-private here.
package funpack_runtime

import "core:strconv"

// --- the hunt program -----------------------------------------------------

// hunt_program builds the whole hunt artifact in memory: the Hunt/Drive enums,
// the Player/Hunter things, the six AI helpers + three consts as §9 functions,
// the think behavior over the ai stage, the one-stage pipeline, and the setup
// batch (one Player + two Hunters). Allocated in the test temp arena so the leak
// checker stays clean. This is the substrate the AI-fold tests evaluate against.
hunt_program :: proc() -> Program {
	a := context.temp_allocator

	enums := make([]Enum_Decl, 2, a)
	enums[0] = Enum_Decl{name = "Hunt", kind = .None, variants = hunt_variants(a)}
	enums[1] = Enum_Decl{name = "Drive", kind = .Axis, variants = drive_variants(a)}

	things := make([]Thing_Decl, 2, a)
	things[0] = Thing_Decl{name = "Player", fields = player_fields(a)}
	things[1] = Thing_Decl{name = "Hunter", singleton = false, fields = hunter_fields(a)}

	functions := make([]Function_Decl, 9, a)
	functions[0] = const_fn("SIGHT", hf_fixed_node(to_fixed(30), a), a)
	functions[1] = const_fn("H_SPEED", hf_fixed_node(to_fixed(1), a), a)
	functions[2] = const_fn("SEARCH_TIME", hf_fixed_node(to_fixed(2), a), a)
	functions[3] = step_to_fn(a)
	functions[4] = visible_fn(a)
	functions[5] = patrol_fn(a)
	functions[6] = chase_fn(a)
	functions[7] = search_fn(a)
	functions[8] = seek_fn(a)

	behaviors := make([]Behavior_Decl, 1, a)
	behaviors[0] = think_behavior(a)

	pipeline := make([]Pipeline_Step, 1, a)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "ai", behavior = "think"}

	setup := make([]Spawn_Command, 3, a)
	// Player at (10, 0): within SIGHT(30) of Hunter 0, far from Hunter 1.
	setup[0] = Spawn_Command{thing = "Player", fields = vec2_spawn(a, "pos", to_fixed(10), to_fixed(0))}
	// Hunter 0 at (5, 0): 5 units from the player → sees it (5 < SIGHT 30).
	setup[1] = Spawn_Command{thing = "Hunter", fields = hunter_spawn(a, to_fixed(5), to_fixed(0))}
	// Hunter 1 at (200, 0): 200 units from the player → does NOT see it.
	setup[2] = Spawn_Command{thing = "Hunter", fields = hunter_spawn(a, to_fixed(200), to_fixed(0))}

	return Program {
		enums = enums,
		things = things,
		functions = functions,
		behaviors = behaviors,
		pipeline = pipeline,
		setup = setup,
	}
}

// hunt_variants is the Hunt state enum's three cases — the state SET the think
// match exhausts (Patrol/Chase/Search, §13 §1).
@(private = "file")
hunt_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 3, a)
	v[0] = Enum_Variant{name = "Patrol", payload = "unit"}
	v[1] = Enum_Variant{name = "Chase", payload = "unit"}
	v[2] = Enum_Variant{name = "Search", payload = "unit"}
	return v
}

// drive_variants is the Drive:Axis enum (Move) — present so the program is shaped
// like hunt's, though the AI-fold tests do not read the player drive path.
@(private = "file")
drive_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 1, a)
	v[0] = Enum_Variant{name = "Move", payload = "unit"}
	return v
}

// player_fields is the Player blackboard schema: a single Vec2 pos column.
@(private = "file")
player_fields :: proc(a := context.allocator) -> []Field_Decl {
	f := make([]Field_Decl, 1, a)
	f[0] = Field_Decl{name = "pos", type = "Vec2"}
	return f
}

// hunter_fields is the Hunter blackboard schema (§13): pos/home Vec2, the Hunt
// `ai` state defaulting to Patrol, the last_seen chase memory, and the search_t
// give-up countdown defaulting to 0 — all plain columns, so the AI saves/replays
// as a fold.
@(private = "file")
hunter_fields :: proc(a := context.allocator) -> []Field_Decl {
	f := make([]Field_Decl, 5, a)
	f[0] = Field_Decl{name = "pos", type = "Vec2"}
	f[1] = Field_Decl{name = "home", type = "Vec2"}
	f[2] = Field_Decl{name = "ai", type = "Hunt", has_default = true, default_encoded = "Hunt::Patrol"}
	f[3] = Field_Decl{name = "last_seen", type = "Vec2"}
	f[4] = Field_Decl{name = "search_t", type = "Fixed", has_default = true, default_encoded = encode_fixed_bits(to_fixed(0), a)}
	return f
}

// --- function bodies (hunt.fun verbatim, in node form) --------------------

// step_to_fn builds step_to(from, to, speed): `let delta = to - from; let d =
// length(delta); if d <= speed { return to }; return from + delta * (speed / d)`
// — the pure motion both patrol/chase/seek call. The length call is the §10
// magnitude gap this story's perception/motion depend on.
@(private = "file")
step_to_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 3, a)
	params[0] = Param_Decl{name = "from", type = "Vec2"}
	params[1] = Param_Decl{name = "to", type = "Vec2"}
	params[2] = Param_Decl{name = "speed", type = "Fixed"}

	body := make([]Node, 4, a)
	// let delta = to - from
	body[0] = let_node("delta", binary_node("sub", name_node("to", a), name_node("from", a), a), a)
	// let d = length(delta)
	body[1] = let_node("d", call_node_h(a, "length", name_node("delta", a)), a)
	// if d <= speed { return to }
	body[2] = if_return_node(
		binary_node("le", name_node("d", a), name_node("speed", a), a),
		name_node("to", a),
		a,
	)
	// return from + delta * (speed / d)
	scaled := binary_node(
		"mul",
		name_node("delta", a),
		binary_node("div", name_node("speed", a), name_node("d", a), a),
		a,
	)
	body[3] = return_node_h(binary_node("add", name_node("from", a), scaled, a), a)
	return Function_Decl{name = "step_to", kind = .Fn, params = params, body = body}
}

// visible_fn builds visible(from, players): `return match first(players, fn(p) {
// return length(p.pos - from) <= SIGHT }) { Some(p) => Some(p.pos), None => None
// }` — the pure perception predicate over a View (§13 §1). first(view, pred)
// boxes the matched record as Option::Some(p); the Some arm binds p and reads its
// pos Vec2 column.
@(private = "file")
visible_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "from", type = "Vec2"}
	params[1] = Param_Decl{name = "players", type = "View[Player]"}

	// fn(p) => length(p.pos - from) <= SIGHT  — a lambda body is a bare expression
	// node (eval_lambda evaluates child[0] directly), so the predicate is the `le`
	// comparison itself, not a wrapping return statement.
	pred_body := binary_node(
		"le",
		call_node_h(a, "length", binary_node("sub", field_node_h(name_node("p", a), "pos", a), name_node("from", a), a)),
		name_node("SIGHT", a),
		a,
	)
	pred := lambda_node_h(a, pred_body, "p")

	// first(players, pred)
	scrutinee := call_node_h(a, "first", name_node("players", a), pred)

	// Some(p) => Some(p.pos)
	some_arm := variant_binds_arm("Option", "Some", "p", a)
	some_body := variant_payload_node("Option", "Some", field_node_h(name_node("p", a), "pos", a), a)
	// None => None
	none_arm := bare_variant_arm("Option", "None", a)
	none_body := variant_unit_node("Option", "None", a)

	match := match_node(scrutinee, a, some_arm, some_body, none_arm, none_body)
	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "visible", kind = .Fn, params = params, body = body}
}

// patrol_fn builds patrol(self, seen): `return match seen { Some(p) => self with
// { ai: Hunt::Chase, last_seen: p }, None => self with { pos: step_to(self.pos,
// self.home, H_SPEED) } }` — the patrol transition (§13 §1). The Some arm flips
// to Chase recording the sighting; the None arm walks home.
@(private = "file")
patrol_fn :: proc(a := context.allocator) -> Function_Decl {
	params := hunter_seen_params(a)

	some_arm := variant_binds_arm("Option", "Some", "p", a)
	some_body := with_node(
		name_node("self", a),
		a,
		recfield_spec("ai", variant_unit_node("Hunt", "Chase", a)),
		recfield_spec("last_seen", name_node("p", a)),
	)
	none_arm := bare_variant_arm("Option", "None", a)
	none_body := with_node(
		name_node("self", a),
		a,
		recfield_spec(
			"pos",
			call_node_h(
				a,
				"step_to",
				field_node_h(name_node("self", a), "pos", a),
				field_node_h(name_node("self", a), "home", a),
				name_node("H_SPEED", a),
			),
		),
	)

	match := match_node(name_node("seen", a), a, some_arm, some_body, none_arm, none_body)
	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "patrol", kind = .Fn, params = params, body = body}
}

// chase_fn builds chase(self, seen): `return match seen { Some(p) => self with {
// pos: step_to(self.pos, p, H_SPEED), last_seen: p }, None => self with { ai:
// Hunt::Search, search_t: SEARCH_TIME } }` — the chase transition (§13 §1 §2).
// The Some arm steps toward the player; the None arm drops to Search with a full
// timer (the countdown set, never an async delay).
@(private = "file")
chase_fn :: proc(a := context.allocator) -> Function_Decl {
	params := hunter_seen_params(a)

	some_arm := variant_binds_arm("Option", "Some", "p", a)
	some_body := with_node(
		name_node("self", a),
		a,
		recfield_spec(
			"pos",
			call_node_h(
				a,
				"step_to",
				field_node_h(name_node("self", a), "pos", a),
				name_node("p", a),
				name_node("H_SPEED", a),
			),
		),
		recfield_spec("last_seen", name_node("p", a)),
	)
	none_arm := bare_variant_arm("Option", "None", a)
	none_body := with_node(
		name_node("self", a),
		a,
		recfield_spec("ai", variant_unit_node("Hunt", "Search", a)),
		recfield_spec("search_t", name_node("SEARCH_TIME", a)),
	)

	match := match_node(name_node("seen", a), a, some_arm, some_body, none_arm, none_body)
	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "chase", kind = .Fn, params = params, body = body}
}

// search_fn builds search(self, seen, dt): `return match seen { Some(p) => self
// with { ai: Hunt::Chase, last_seen: p }, None => seek(self, dt) }` — the search
// transition (§13 §1). The Some arm re-acquires straight to Chase; the None arm
// delegates to seek (the countdown step).
@(private = "file")
search_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 3, a)
	params[0] = Param_Decl{name = "self", type = "Hunter"}
	params[1] = Param_Decl{name = "seen", type = "Option[Vec2]"}
	params[2] = Param_Decl{name = "dt", type = "Fixed"}

	some_arm := variant_binds_arm("Option", "Some", "p", a)
	some_body := with_node(
		name_node("self", a),
		a,
		recfield_spec("ai", variant_unit_node("Hunt", "Chase", a)),
		recfield_spec("last_seen", name_node("p", a)),
	)
	none_arm := bare_variant_arm("Option", "None", a)
	none_body := call_node_h(a, "seek", name_node("self", a), name_node("dt", a))

	match := match_node(name_node("seen", a), a, some_arm, some_body, none_arm, none_body)
	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "search", kind = .Fn, params = params, body = body}
}

// seek_fn builds seek(self, dt): `let t = self.search_t - dt; if t <= 0.0 {
// return self with { ai: Hunt::Patrol, search_t: 0.0 } }; return self with { pos:
// step_to(self.pos, self.last_seen, H_SPEED), search_t: t }` — the Fixed
// countdown step (§13 §2). The 'wait' is a field folded by dt, never an async
// delay: t <= 0 gives up to Patrol, else walks the last-seen point.
@(private = "file")
seek_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "self", type = "Hunter"}
	params[1] = Param_Decl{name = "dt", type = "Fixed"}

	body := make([]Node, 3, a)
	// let t = self.search_t - dt
	body[0] = let_node(
		"t",
		binary_node("sub", field_node_h(name_node("self", a), "search_t", a), name_node("dt", a), a),
		a,
	)
	// if t <= 0.0 { return self with { ai: Hunt::Patrol, search_t: 0.0 } }
	give_up := with_node(
		name_node("self", a),
		a,
		recfield_spec("ai", variant_unit_node("Hunt", "Patrol", a)),
		recfield_spec("search_t", hf_fixed_node(to_fixed(0), a)),
	)
	body[1] = if_return_node(binary_node("le", name_node("t", a), hf_fixed_node(to_fixed(0), a), a), give_up, a)
	// return self with { pos: step_to(self.pos, self.last_seen, H_SPEED), search_t: t }
	keep := with_node(
		name_node("self", a),
		a,
		recfield_spec(
			"pos",
			call_node_h(
				a,
				"step_to",
				field_node_h(name_node("self", a), "pos", a),
				field_node_h(name_node("self", a), "last_seen", a),
				name_node("H_SPEED", a),
			),
		),
		recfield_spec("search_t", name_node("t", a)),
	)
	body[2] = return_node_h(keep, a)
	return Function_Decl{name = "seek", kind = .Fn, params = params, body = body}
}

// think_behavior builds the think step on Hunter: `let seen = visible(self.pos,
// players); return match self.ai { Hunt::Patrol => patrol(self, seen), Hunt::Chase
// => chase(self, seen), Hunt::Search => search(self, seen, time.dt) }` — the state
// machine (§13 §1): sense once, then dispatch on the current state. The exhaustive
// match IS the transition function.
@(private = "file")
think_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 3, a)
	params[0] = Param_Decl{name = "self", type = "Hunter"}
	params[1] = Param_Decl{name = "players", type = "View[Player]"}
	params[2] = Param_Decl{name = "time", type = "Time"}
	emits := make([]string, 1, a)
	emits[0] = "Hunter"

	body := make([]Node, 2, a)
	// let seen = visible(self.pos, players)
	body[0] = let_node(
		"seen",
		call_node_h(a, "visible", field_node_h(name_node("self", a), "pos", a), name_node("players", a)),
		a,
	)
	// return match self.ai { Patrol => patrol(self, seen), Chase => chase(self, seen), Search => search(self, seen, time.dt) }
	patrol_arm := bare_variant_arm("Hunt", "Patrol", a)
	patrol_body := call_node_h(a, "patrol", name_node("self", a), name_node("seen", a))
	chase_arm := bare_variant_arm("Hunt", "Chase", a)
	chase_body := call_node_h(a, "chase", name_node("self", a), name_node("seen", a))
	search_arm := bare_variant_arm("Hunt", "Search", a)
	search_body := call_node_h(
		a,
		"search",
		name_node("self", a),
		name_node("seen", a),
		field_node_h(name_node("time", a), "dt", a),
	)
	match := match_node(
		field_node_h(name_node("self", a), "ai", a),
		a,
		patrol_arm,
		patrol_body,
		chase_arm,
		chase_body,
		search_arm,
		search_body,
	)
	body[1] = return_node_h(match, a)
	return Behavior_Decl{name = "think", on_thing = "Hunter", stage = "ai", params = params, emits = emits, body = body}
}

// hunter_seen_params is the shared (self: Hunter, seen: Option[Vec2]) param pair
// patrol and chase declare.
@(private = "file")
hunter_seen_params :: proc(a := context.allocator) -> []Param_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "self", type = "Hunter"}
	params[1] = Param_Decl{name = "seen", type = "Option[Vec2]"}
	return params
}

// --- call drivers ---------------------------------------------------------

// hunt_call_two applies a two-param hunt helper (patrol/chase) against seeded
// params, folding its body — the test driver for a body whose args are runtime
// values rather than literals (mirrors interp_test's call_two).
hunt_call_two :: proc(interp: ^Interp, name: string, a, b: Value) -> (result: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 2 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = a
	scope.names[fn.params[1].name] = b
	return eval_body(interp, fn.body, &scope)
}

// hunt_call_three applies a three-param hunt helper (search/step_to) against
// seeded params, folding its body.
hunt_call_three :: proc(interp: ^Interp, name: string, a, b, c: Value) -> (result: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 3 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = a
	scope.names[fn.params[1].name] = b
	scope.names[fn.params[2].name] = c
	return eval_body(interp, fn.body, &scope)
}

// --- spawn-field builders -------------------------------------------------

// vec2_spawn builds a Spawn_Command's one supplied Vec2 field (the Player's pos).
@(private = "file")
vec2_spawn :: proc(a: Runtime_Allocator, name: string, x, y: Fixed) -> []Spawn_Field {
	fields := make([]Spawn_Field, 1, a)
	fields[0] = Spawn_Field{name = name, kind = .Vec2, vec2_x = x, vec2_y = y}
	return fields
}

// hunter_spawn builds a Hunter's supplied setup fields (pos + home at the same
// anchor); ai/last_seen/search_t fall to their declared defaults (Patrol, zero,
// zero) — the §13 setup omitted-field fill the tick's spawn blackboard applies.
@(private = "file")
hunter_spawn :: proc(a: Runtime_Allocator, x, y: Fixed) -> []Spawn_Field {
	fields := make([]Spawn_Field, 2, a)
	fields[0] = Spawn_Field{name = "pos", kind = .Vec2, vec2_x = x, vec2_y = y}
	fields[1] = Spawn_Field{name = "home", kind = .Vec2, vec2_x = x, vec2_y = y}
	return fields
}

// --- node constructors (§2.7 checked-AST subtrees) ------------------------

// const_fn builds a module-level `let NAME = value` const (a nullary function the
// body resolves through eval_name — SIGHT/H_SPEED/SEARCH_TIME read this way).
@(private = "file")
const_fn :: proc(name: string, value: Node, a := context.allocator) -> Function_Decl {
	body := make([]Node, 1, a)
	body[0] = return_node_h(value, a)
	return Function_Decl{name = name, kind = .Const, body = body}
}

// hf_fixed_node builds a `.Fixed` literal node carrying the raw Q32.32 bits token
// decode_fixed parses back — the form a Fixed const/literal lowers to.
@(private = "file")
hf_fixed_node :: proc(f: Fixed, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = encode_fixed_bits(f, a)
	return Node{kind = .Fixed, fields = fields}
}

// name_node builds a `.Name` reference node — a param/let/const identifier the
// body resolves through the scope chain.
@(private = "file")
name_node :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

// field_node_h builds a `.Field` access node `recv.FIELD` over a single receiver
// child — the column read step_to/visible/think perform (self.pos, p.pos, time.dt).
@(private = "file")
field_node_h :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

// binary_node builds a `.Binary` op node `lhs OP rhs` over the kernel — the
// arithmetic (sub/mul/div/add) and comparison (le) the AI bodies fold through.
@(private = "file")
binary_node :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

// call_node_h builds a `.Call` node: child[0] is the callee `.Name` (the
// dispatcher reads its token), children[1:] the arg subtrees read positionally —
// length/first/step_to/seek/patrol/chase/search calls.
@(private = "file")
call_node_h :: proc(a: Runtime_Allocator, callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = name_node(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

// lambda_node_h builds a `.Lambda` closure node over a single body EXPRESSION —
// visible's `fn(p) => length(p.pos - from) <= SIGHT` perception predicate.
// fields[0] is the param count, fields[1:] the binder names; eval_lambda evaluates
// the lone body child as an expression (never a statement), so the body is the
// bare predicate expression, not a wrapping return.
@(private = "file")
lambda_node_h :: proc(a: Runtime_Allocator, body: Node, params: ..string) -> Node {
	fields := make([]string, len(params) + 1, a)
	fields[0] = fmt_count(len(params), a)
	for p, i in params {
		fields[i + 1] = p
	}
	children := make([]Node, 1, a)
	children[0] = body
	return Node{kind = .Lambda, fields = fields, children = children}
}

// variant_unit_node builds a unit `.Variant` value node `variant ENUM CASE false`
// with no payload — Hunt::Chase/Patrol/Search and Option::None.
@(private = "file")
variant_unit_node :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "false"
	return Node{kind = .Variant, fields = fields}
}

// variant_payload_node builds a single-payload `.Variant` value node `variant
// ENUM CASE true` with the payload subtree as its lone child — visible's
// Option::Some(p.pos).
@(private = "file")
variant_payload_node :: proc(enum_type, case_name: string, payload: Node, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "true"
	children := make([]Node, 1, a)
	children[0] = payload
	return Node{kind = .Variant, fields = fields, children = children}
}

// with_node builds a `.With` functional-update node — child[0] the base record,
// the remaining children the replacement recfields (the `self with { … }` write
// every AI transition returns).
@(private = "file")
with_node :: proc(base: Node, a: Runtime_Allocator, specs: ..Recfield_Spec_H) -> Node {
	children := make([]Node, len(specs) + 1, a)
	children[0] = base
	for spec, i in specs {
		children[i + 1] = recfield_node_h(spec, a)
	}
	return Node{kind = .With, children = children}
}

// Recfield_Spec_H is one `name = value` pair of a with/record update — the field
// name and its already-built value subtree.
@(private = "file")
Recfield_Spec_H :: struct {
	name:  string,
	value: Node,
}

// recfield_spec is the terse constructor for a Recfield_Spec_H pair.
@(private = "file")
recfield_spec :: proc(name: string, value: Node) -> Recfield_Spec_H {
	return Recfield_Spec_H{name = name, value = value}
}

// recfield_node_h builds a `.Recfield` node `NAME = value` — one replaced field of
// a with-update, its value the carried subtree.
@(private = "file")
recfield_node_h :: proc(spec: Recfield_Spec_H, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = spec.name
	children := make([]Node, 1, a)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

// match_node builds a `.Match` node: child[0] the scrutinee, the rest alternating
// arm/body in source order (eval_match pairs them) — the dispatch every hunt
// transition and think run.
@(private = "file")
match_node :: proc(scrutinee: Node, a: Runtime_Allocator, arms_bodies: ..Node) -> Node {
	children := make([]Node, len(arms_bodies) + 1, a)
	children[0] = scrutinee
	for n, i in arms_bodies {
		children[i + 1] = n
	}
	return Node{kind = .Match, children = children}
}

// variant_binds_arm builds an `.Arm` pattern node `variant_binds ENUM CASE 1
// BINDER` — the Some(p) arm binding the payload to one name (arm_matches reads
// fields[3] as the binder count, fields[4] as the binder).
@(private = "file")
variant_binds_arm :: proc(enum_type, case_name, binder: string, a := context.allocator) -> Node {
	fields := make([]string, 5, a)
	fields[0] = "variant_binds"
	fields[1] = enum_type
	fields[2] = case_name
	fields[3] = "1"
	fields[4] = binder
	return Node{kind = .Arm, fields = fields}
}

// bare_variant_arm builds an `.Arm` pattern node `bare_variant ENUM CASE` — a
// no-binder case match (Option::None, Hunt::Patrol/Chase/Search in think).
@(private = "file")
bare_variant_arm :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = "bare_variant"
	fields[1] = enum_type
	fields[2] = case_name
	return Node{kind = .Arm, fields = fields}
}

// let_node builds a `.Let` statement node `let NAME = value` — the binding step_to
// (delta/d), seek (t), and think (seen) thread through their bodies.
@(private = "file")
let_node :: proc(name: string, value: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Let, fields = fields, children = children}
}

// if_return_node builds an `.If_Return` statement node `if GUARD { return VALUE }`
// — child[0] the guard, child[1] the returned value (step_to's snap, seek's
// give-up).
@(private = "file")
if_return_node :: proc(guard, value: Node, a := context.allocator) -> Node {
	children := make([]Node, 2, a)
	children[0] = guard
	children[1] = value
	return Node{kind = .If_Return, children = children}
}

// return_node_h builds a `.Return` statement node wrapping its value subtree — the
// body terminator yielding a transition's folded result.
@(private = "file")
return_node_h :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}

// --- token encoders -------------------------------------------------------

// encode_fixed_bits renders a Fixed's raw Q32.32 bits to the decimal token
// decode_fixed parses back — the artifact form a Fixed literal/default carries
// (the raw i64 bits, not a decimal value).
@(private = "file")
encode_fixed_bits :: proc(f: Fixed, a := context.allocator) -> string {
	buf := make([]u8, 24, a)
	return strconv.write_int(buf, i64(f), 10)
}

// fmt_count renders a small non-negative count to its decimal token — a lambda
// param count carried as text.
@(private = "file")
fmt_count :: proc(n: int, a := context.allocator) -> string {
	buf := make([]u8, 24, a)
	return strconv.write_int(buf, i64(n), 10)
}
