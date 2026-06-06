// Parser for the modeling DSL (.fpm) — the second funpack language (spec §16,
// grammar/fpm.ebnf), wholly separate from the `.fun` parser (parser.odin). It
// consumes the Fpm_Token stream (fpm_lexer.odin) and builds an Fpm_Unit: a
// `model`/`rig` block of members (§16 §2) over a Solid geometry IR. This stage
// produces structure only — no name resolution, no geometry scoring (that is the
// §16.3 gate stage, fpm_gates.odin, run over the Solid IR this parser builds).
//
// The grammar is deliberately NOT LL(1) (fpm.ebnf header): a call takes NAMED
// arguments (`pbr(color: teal, rough: 0.7)`), so the labeled-vs-positional peek
// the `.fun` grammar avoids is taken freely here — an argument is parsed as an
// expression, then a `:` after a bare LOWER_IDENT promotes it to a labeled arg.
// The operator ladder mirrors `.fun` (add/mul/unary/postfix) but in the float
// domain (§16 §1). Expressions are kept as a small closed Fpm_Expr union: enough
// to (a) re-parse faithfully and (b) let the geometry gate compute a primitive's
// manifold/volume/tri properties from its literal/constant arguments. The Solid
// IR (Fpm_Solid) is the load-bearing structure: a primitive (capsule/sphere/box/
// cyl) carries its sizing arguments, a transform wraps an inner Solid, and a
// boolean (union/difference/intersect) carries its operand Solids — so the gate
// stage walks one tree to score geometry invariants.

package funpack

// Fpm_Parse_Error is closed with one arm per way a .fpm source can fail to
// parse, and no catch-all: a malformed source names exactly which grammar
// expectation it violated. It mirrors the `.fun` Parse_Error discipline
// (parser.odin) — Unexpected_Token / Unexpected_End — plus Wrong_Case for an
// identifier whose initial-case is wrong for its grammar position (a LOWER_IDENT
// where the grammar demands an UPPER_IDENT bone/type, or vice versa,
// lexical-core.ebnf §2).
Fpm_Parse_Error :: enum {
	None,
	Unexpected_Token,
	Unexpected_End,
	Wrong_Case,
}

// Fpm_Expr is the closed expression set of the .fpm operator ladder (fpm.ebnf
// Expr). It is a small union — literals, names, member access, calls (with named
// or positional args), unary/binary arithmetic, and a `for`-loop range — kept as
// pointers so the tree nests without a fixed-size union blowup, matching the
// `.fun` Expr discipline (expr.odin). The geometry gate reads a primitive call's
// argument expressions to compute its sizing; arithmetic over literal/param
// arguments (`limb_r * 0.85`) folds to a value the gate can score.
Fpm_Expr :: union {
	^Fpm_Int_Lit,
	^Fpm_Float_Lit,
	^Fpm_String_Lit,
	^Fpm_Name,
	^Fpm_Member,
	^Fpm_Call,
	^Fpm_Unary,
	^Fpm_Binary,
	^Fpm_Range,
}

Fpm_Int_Lit :: struct {
	value: i64,
}

Fpm_Float_Lit :: struct {
	value: f64,
}

Fpm_String_Lit :: struct {
	text: string,
}

// Fpm_Name is a bare identifier reference — a LOWER_IDENT value/param/fn or an
// UPPER_IDENT type/bone. The `case` field carries the initial-case class so a
// downstream stage can tell a param reference from a bone reference without
// re-lexing.
Fpm_Name :: struct {
	name:       string,
	ident_case: Fpm_Ident_Case,
}

// Fpm_Member is one `.field` access on a receiver — a `.fpm` member selector
// (`slab.face`, the receiver spine of a postfix transform chain). A member
// followed by `(` is the callee of an Fpm_Call (a method/transform call), so
// `.up(0)` parses as a Call whose callee is this Member.
Fpm_Member :: struct {
	receiver: Fpm_Expr,
	member:   string,
}

// Fpm_Call is a call with named-or-positional arguments (fpm.ebnf CallArgs/Arg).
// The callee is a bare name for a primitive/constructor (`capsule(r, h)`,
// `pbr(...)`) or a Member for a transform (`...up(0)`, `slab.face("top")`). Each
// argument carries an optional label: a positional arg has label "" (`capsule(r,
// h)`), a named arg carries its label (`pbr(color: teal)`, `.offset(z: 2)`).
Fpm_Call :: struct {
	callee: Fpm_Expr,
	args:   []Fpm_Arg,
}

// Fpm_Arg is one call argument: the value expression plus an optional label.
// labeled distinguishes a named arg (`color: teal`) from a positional one
// (`r`); label is meaningless when labeled is false.
Fpm_Arg :: struct {
	label:   string,
	labeled: bool,
	value:   Fpm_Expr,
}

Fpm_Unary :: struct {
	op:      Fpm_Token_Kind, // Minus only (the sole prefix operator, fpm.ebnf UnaryExpr)
	operand: Fpm_Expr,
}

Fpm_Binary :: struct {
	op:  Fpm_Token_Kind, // Plus/Minus/Star/Slash/Percent (fpm.ebnf Add/MulExpr)
	lhs: Fpm_Expr,
	rhs: Fpm_Expr,
}

// Fpm_Range is the `a..b` integer-range iterable of an accumulating `for` loop
// (§16 §1, fpm.ebnf — `for x in a..b`). It is an expression form so a loop's
// iterable parses through the one expression seam.
Fpm_Range :: struct {
	lo: Fpm_Expr,
	hi: Fpm_Expr,
}

// ── Solid geometry IR (§16 §2) ───────────────────────────────────────────────

// Fpm_Solid is the geometry algebra the §16.3 gates score (§16 §2, "boring on
// purpose"): primitives (capsule/sphere/box/cyl), transforms (.up/.down/.at/
// .rotate/.scale wrapping an inner solid), and booleans (union/difference/
// intersect over operand solids). The parser lifts a geometry-valued Fpm_Expr
// into this tree (fpm_solid_of_expr) so the gate stage walks ONE typed
// structure, not the raw expression union — a capsule's manifold/volume/tri
// properties are computable from its sizing, a degenerate primitive (zero
// radius/height) is the zero-volume case, and a difference of overlapping solids
// is the self-intersection case.
Fpm_Solid :: union {
	^Fpm_Primitive,
	^Fpm_Transform,
	^Fpm_Boolean,
}

// Fpm_Prim_Kind is the closed primitive set (§16 §2): the four engine-provided
// shapes the geometry gate can size. An unknown constructor name is not a
// primitive — the parser leaves it as a plain Fpm_Expr and the gate skips it.
Fpm_Prim_Kind :: enum {
	Capsule, // capsule(r, h)
	Sphere,  // sphere(r)
	Box,     // box(w, d, h)
	Cyl,     // cyl(r, h)
}

// Fpm_Primitive is one geometry primitive with its sizing arguments evaluated to
// the float domain. dims holds the positional dimensions in declaration order
// (capsule/cyl: [r, h]; sphere: [r]; box: [w, d, h]); the gate reads them to
// compute volume and triangle count. A dimension whose argument is not a
// foldable literal/constant expression is recorded as NaN-free 0 only when the
// expression genuinely evaluates to zero — fpm_eval_number returns ok=false for
// a non-foldable argument so the gate does not mistake an unknown size for a
// degenerate one.
Fpm_Primitive :: struct {
	kind: Fpm_Prim_Kind,
	dims: []f64,
}

// Fpm_Transform_Kind is the closed transform set (§16 §2): the placement
// operators that wrap an inner solid without changing its topology. A transform
// preserves manifoldness and (for rigid moves) volume, so the gate passes its
// inner solid's verdict through.
Fpm_Transform_Kind :: enum {
	Up,     // .up(z)
	Down,   // .down(z)
	At,     // .at(...)
	Rotate, // .rotate(...)
	Scale,  // .scale(s) — the one transform that rescales volume/tri density
}

// Fpm_Transform wraps an inner solid with a placement operator. scale holds the
// uniform scale factor for a .scale transform (1.0 for every other kind), so the
// gate can rescale the inner volume without re-walking arguments.
Fpm_Transform :: struct {
	kind:  Fpm_Transform_Kind,
	inner: Fpm_Solid,
	scale: f64,
}

// Fpm_Bool_Kind is the closed boolean set (§16 §2, CSG on the OpenSCAD prior):
// union joins, difference subtracts, intersect keeps the overlap. The gate scores
// each differently — a difference of fully-overlapping solids can carve to zero
// volume, an intersect of disjoint solids is empty (zero volume), a union of
// touching solids can be non-manifold at the shared face.
Fpm_Bool_Kind :: enum {
	Union,
	Difference,
	Intersect,
}

Fpm_Boolean :: struct {
	kind:     Fpm_Bool_Kind,
	operands: []Fpm_Solid,
}

// ── Member declarations (§16 §2) ─────────────────────────────────────────────

// Fpm_Param is a `param name: Type = default` knob (§16 §2): a tunable that
// generates a field on the params `data` (§16 §4). The default is optional
// (fpm.ebnf ParamDecl); has_default distinguishes a defaulted knob from a
// required one.
Fpm_Param :: struct {
	name:        string,
	type:        string, // the bare Type head (`Length`, `Fixed`); list/generic args dropped (gate-irrelevant)
	default:     Fpm_Expr,
	has_default: bool,
}

// Fpm_Fn is a bake-time `fn name(params) -> Type { body }` (§16 §1): an
// imperative-bodied helper that returns a Solid (or any value). The body holds
// let/return/for/assign/expr statements (fpm.ebnf Stmt); solid carries the
// geometry the fn's `return` produces when it is a Solid expression, so a
// `part ... = fn_name()` binding resolves to a scorable solid through the fn.
Fpm_Fn :: struct {
	name:   string,
	params: []Fpm_Param, // reuse the param shape (name + type); defaults unused on a fn param
	ret:    string,      // the bare return-Type head
	body:   []Fpm_Stmt,
	solid:  Fpm_Solid, // the geometry of the fn's `return` expr, nil when it returns a non-Solid
}

// Fpm_Stmt is the closed imperative-body statement set (§16 §1, fpm.ebnf Stmt):
// let-binding, return, accumulating for-loop, local reassignment (Assign), and a
// bare expression. The for-loop and assign are the bake-time-only forms with no
// `.fun` counterpart (§16 §1) — the sim has neither mutation nor loops.
Fpm_Stmt :: union {
	Fpm_Let,
	Fpm_Return,
	Fpm_For,
	Fpm_Assign,
	Fpm_Expr_Stmt,
}

Fpm_Let :: struct {
	name:  string,
	type:  string, // optional `: Type` head; "" when absent
	value: Fpm_Expr,
}

Fpm_Return :: struct {
	value: Fpm_Expr,
}

// Fpm_For is the accumulating loop `for x in <iterable> { body }` (§16 §1): a
// bake-time-only construct over a list expression or an `a..b` integer range. The
// body is a nested statement sequence.
Fpm_For :: struct {
	binder:   string,
	iterable: Fpm_Expr,
	body:     []Fpm_Stmt,
}

// Fpm_Assign is a local reassignment `path = expr` (§16 §1): the l-value is a
// dotted path into a bound local (fpm.ebnf LValuePath — `name (. name)*`). Legal
// only in a `.fpm` body; the sim has no mutation.
Fpm_Assign :: struct {
	path:  []string, // the l-value path segments, e.g. ["acc"] or ["t", "pos"]
	value: Fpm_Expr,
}

Fpm_Expr_Stmt :: struct {
	value: Fpm_Expr,
}

// Fpm_Bind is one geometry-producing member binding with a name and an optional
// bone attach point: emit/anchor/socket/material/collide (§16 §2) and a rig
// `part ... at BONE = ...` (§16 §7). kind tells them apart; bone is the attach
// bone for a part (`TORSO`), "" for the non-part bindings; solid carries the
// member's geometry when its value is a Solid expression (an emit, a collide
// proxy, or a part mesh), nil for a material/anchor that is not geometry.
Fpm_Bind_Kind :: enum {
	Emit,     // emit <expr> — render geometry (no name)
	Anchor,   // anchor name = <expr>
	Socket,   // socket name = <expr>
	Material, // material name = <expr>
	Collide,  // collide name = <expr>
	Part,     // part name at BONE = <expr>
}

Fpm_Bind :: struct {
	kind:  Fpm_Bind_Kind,
	name:  string,    // the binding name; "" for an `emit`
	bone:  string,    // the attach bone for a Part; "" otherwise
	value: Fpm_Expr,
	solid: Fpm_Solid, // the binding's geometry when value is a Solid expr; nil otherwise
}

// Fpm_Mirror is a `mirror L -> R` directive (§16 §7): model one side, generate
// the other. from/to are the UPPER_IDENT side labels.
Fpm_Mirror :: struct {
	from: string,
	to:   string,
}

// Fpm_Unit is the parsed .fpm modeling unit: a `model` or `rig` block (§16 §2,
// fpm.ebnf ModelBlock/RigBlock). is_rig tells them apart so a rig-only member
// (skeleton/part/mirror/clearance) outside a rig can be rejected. The members are
// split into per-kind slices the gate and the downstream seam emitter consume.
// has_clearance/clearance carry the optional warn-level joint gap (§16 §7).
Fpm_Unit :: struct {
	name:          string, // the block label (UPPER_IDENT), which IS the model/rig name
	is_rig:        bool,
	skeleton:      string, // the named topology of a rig (`humanoid`); "" for a model or an absent skeleton
	params:        []Fpm_Param,
	fns:           []Fpm_Fn,
	binds:         []Fpm_Bind, // emit/anchor/socket/material/collide/part bindings
	mirrors:       []Fpm_Mirror,
	has_clearance: bool,
	clearance:     f64,
}

Fpm_Parser :: struct {
	tokens: []Fpm_Token,
	pos:    int,
}

// fpm_parse is the stage entry: it parses one .fpm modeling unit (a single
// `model` or `rig` block) from the token stream into an Fpm_Unit, or returns the
// first grammar violation. A directive prefix (`@doc(...)`) before the block is
// permitted by the grammar (Decl ::= Directive* …) but unexemplified in the
// hand-built fixtures, so it is skipped if present. The file is one unit (the
// fixtures, and the krognid example, each carry exactly one block).
fpm_parse :: proc(tokens: []Fpm_Token) -> (unit: Fpm_Unit, err: Fpm_Parse_Error) {
	p := Fpm_Parser{tokens = tokens}
	fpm_skip_newlines(&p)
	#partial switch fpm_peek_kind(&p) {
	case .Model:
		return fpm_parse_block(&p, is_rig = false)
	case .Rig:
		return fpm_parse_block(&p, is_rig = true)
	}
	return unit, .Unexpected_Token
}

// fpm_parse_block parses a `model`/`rig UPPER_IDENT { members }` block. The
// opening keyword is already peeked; the block name is the UPPER_IDENT label,
// which IS the model/rig name (§16 §2). Members are Sep-separated; the loop reads
// one member per leading keyword until the closing brace.
fpm_parse_block :: proc(p: ^Fpm_Parser, is_rig: bool) -> (unit: Fpm_Unit, err: Fpm_Parse_Error) {
	fpm_advance(p) or_return // `model` or `rig`
	name := fpm_expect_upper(p) or_return
	fpm_expect(p, .L_Brace) or_return
	unit.name = name
	unit.is_rig = is_rig
	params := make([dynamic]Fpm_Param, 0, 8, context.temp_allocator)
	fns := make([dynamic]Fpm_Fn, 0, 8, context.temp_allocator)
	binds := make([dynamic]Fpm_Bind, 0, 8, context.temp_allocator)
	mirrors := make([dynamic]Fpm_Mirror, 0, 2, context.temp_allocator)
	fpm_skip_seps(p)
	for fpm_peek_kind(p) != .R_Brace && !fpm_at_end(p) {
		#partial switch fpm_peek_kind(p) {
		case .Param:
			node := fpm_parse_param(p) or_return
			append(&params, node)
		case .Fn:
			node := fpm_parse_fn(p) or_return
			append(&fns, node)
		case .Emit:
			node := fpm_parse_emit(p) or_return
			append(&binds, node)
		case .Anchor, .Socket, .Material, .Collide:
			node := fpm_parse_named_bind(p) or_return
			append(&binds, node)
		case .Skeleton:
			topology := fpm_parse_skeleton(p) or_return
			unit.skeleton = topology
		case .Part:
			node := fpm_parse_part(p) or_return
			append(&binds, node)
		case .Mirror:
			node := fpm_parse_mirror(p) or_return
			append(&mirrors, node)
		case .Clearance:
			value := fpm_parse_clearance(p) or_return
			unit.has_clearance = true
			unit.clearance = value
		case:
			return unit, .Unexpected_Token
		}
		fpm_skip_seps(p)
	}
	fpm_expect(p, .R_Brace) or_return
	unit.params = params[:]
	unit.fns = fns[:]
	unit.binds = binds[:]
	unit.mirrors = mirrors[:]
	return unit, .None
}

// fpm_parse_param parses `param name: Type (= default)?` (§16 §2, fpm.ebnf
// ParamDecl): a tunable knob whose name is a LOWER_IDENT and whose type is the
// bare Type head. The default is an optional expression.
fpm_parse_param :: proc(p: ^Fpm_Parser) -> (node: Fpm_Param, err: Fpm_Parse_Error) {
	fpm_expect(p, .Param) or_return
	name := fpm_expect_lower(p) or_return
	fpm_expect(p, .Colon) or_return
	type := fpm_parse_type(p) or_return
	node = Fpm_Param{name = name, type = type}
	if fpm_peek_kind(p) == .Eq {
		fpm_advance(p) or_return
		node.default = fpm_parse_expression(p) or_return
		node.has_default = true
	}
	fpm_terminate(p) or_return
	return node, .None
}

// fpm_parse_fn parses `fn name(params) -> Type { body }` (§16 §1, fpm.ebnf
// FnDecl): a bake-time imperative helper. The body's `return` solid (when its
// value lifts to a Solid) is captured on the node so a `part ... = name()` can
// resolve to scorable geometry through the fn.
fpm_parse_fn :: proc(p: ^Fpm_Parser) -> (node: Fpm_Fn, err: Fpm_Parse_Error) {
	fpm_expect(p, .Fn) or_return
	name := fpm_expect_lower(p) or_return
	fpm_expect(p, .L_Paren) or_return
	params := make([dynamic]Fpm_Param, 0, 4, context.temp_allocator)
	for fpm_peek_kind(p) != .R_Paren && !fpm_at_end(p) {
		pname := fpm_expect_lower(p) or_return
		fpm_expect(p, .Colon) or_return
		ptype := fpm_parse_type(p) or_return
		append(&params, Fpm_Param{name = pname, type = ptype})
		if fpm_peek_kind(p) == .Comma {
			fpm_advance(p) or_return
		}
	}
	fpm_expect(p, .R_Paren) or_return
	fpm_expect(p, .Arrow) or_return
	ret := fpm_parse_type(p) or_return
	body := fpm_parse_block_body(p) or_return
	node = Fpm_Fn{name = name, params = params[:], ret = ret, body = body}
	node.solid = fpm_return_solid(body)
	return node, .None
}

// fpm_return_solid lifts the geometry of a fn body's first `return` into a Solid
// IR, so a `part ... = fn()` binding scores the geometry the fn produces (§16
// §7: a part's mesh is a fn call). It returns nil when the body has no return or
// the returned expression is not a geometry expression.
fpm_return_solid :: proc(body: []Fpm_Stmt) -> Fpm_Solid {
	for stmt in body {
		if ret, is_ret := stmt.(Fpm_Return); is_ret {
			return fpm_solid_of_expr(ret.value)
		}
	}
	return nil
}

// fpm_parse_block_body parses a `{ Stmt (Sep Stmt)* Sep? }` imperative body
// (fpm.ebnf Block). Each statement opens with let/return/for or is an
// assignment/expression; the leading keyword (or a LOWER_IDENT followed by `=`/
// `.`) selects the production.
fpm_parse_block_body :: proc(p: ^Fpm_Parser) -> (body: []Fpm_Stmt, err: Fpm_Parse_Error) {
	fpm_expect(p, .L_Brace) or_return
	stmts := make([dynamic]Fpm_Stmt, 0, 8, context.temp_allocator)
	fpm_skip_seps(p)
	for fpm_peek_kind(p) != .R_Brace && !fpm_at_end(p) {
		stmt := fpm_parse_stmt(p) or_return
		append(&stmts, stmt)
		fpm_skip_seps(p)
	}
	fpm_expect(p, .R_Brace) or_return
	return stmts[:], .None
}

// fpm_parse_stmt parses one imperative-body statement (fpm.ebnf Stmt). A leading
// `let`/`return`/`for` selects its production directly; otherwise the statement
// is an Assign or a bare Expr, told apart by whether the parsed l-value path is
// followed by `=` (assignment) or not (expression statement).
fpm_parse_stmt :: proc(p: ^Fpm_Parser) -> (stmt: Fpm_Stmt, err: Fpm_Parse_Error) {
	#partial switch fpm_peek_kind(p) {
	case .Let:
		return fpm_parse_let(p)
	case .Return:
		fpm_advance(p) or_return
		value := fpm_parse_expression(p) or_return
		fpm_terminate(p) or_return
		return Fpm_Return{value = value}, .None
	case .For:
		return fpm_parse_for(p)
	}
	// An Assign begins with an l-value path (LOWER_IDENT ('.' LOWER_IDENT)*)
	// followed by `=`. A bare expression that happens to start with a name is the
	// fall-through (a `fn()` call statement). Parse the full expression, then
	// promote it to an Assign only when it is a plain dotted name-path followed by
	// `=`.
	expr := fpm_parse_expression(p) or_return
	if fpm_peek_kind(p) == .Eq {
		path, ok := fpm_lvalue_path(expr)
		if !ok {
			return stmt, .Unexpected_Token
		}
		fpm_advance(p) or_return // `=`
		value := fpm_parse_expression(p) or_return
		fpm_terminate(p) or_return
		return Fpm_Assign{path = path, value = value}, .None
	}
	fpm_terminate(p) or_return
	return Fpm_Expr_Stmt{value = expr}, .None
}

// fpm_lvalue_path flattens a name/member expression into a dotted l-value path
// (fpm.ebnf LValuePath). A bare Name is a single segment; a Member chain over a
// Name is the dotted path. Any other expression form is not a valid l-value, so
// ok is false and the assignment is rejected.
fpm_lvalue_path :: proc(expr: Fpm_Expr) -> (path: []string, ok: bool) {
	segs := make([dynamic]string, 0, 4, context.temp_allocator)
	cursor := expr
	for {
		switch e in cursor {
		case ^Fpm_Name:
			append(&segs, e.name)
			// Segments were collected leaf-to-root via member receivers; reverse
			// to root-to-leaf order.
			reversed := make([]string, len(segs), context.temp_allocator)
			for i in 0 ..< len(segs) {
				reversed[i] = segs[len(segs) - 1 - i]
			}
			return reversed, true
		case ^Fpm_Member:
			append(&segs, e.member)
			cursor = e.receiver
		case ^Fpm_Int_Lit, ^Fpm_Float_Lit, ^Fpm_String_Lit, ^Fpm_Call, ^Fpm_Unary, ^Fpm_Binary, ^Fpm_Range:
			return nil, false
		case nil:
			return nil, false
		}
	}
}

// fpm_parse_let parses `let name (: Type)? = expr` (fpm.ebnf Stmt). The type
// ascription is optional in a body (the surrounding expression context supplies
// inference), unlike the `.fun` module-level constant.
fpm_parse_let :: proc(p: ^Fpm_Parser) -> (stmt: Fpm_Stmt, err: Fpm_Parse_Error) {
	fpm_expect(p, .Let) or_return
	name := fpm_expect_lower(p) or_return
	type := ""
	if fpm_peek_kind(p) == .Colon {
		fpm_advance(p) or_return
		type = fpm_parse_type(p) or_return
	}
	fpm_expect(p, .Eq) or_return
	value := fpm_parse_expression(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Let{name = name, type = type, value = value}, .None
}

// fpm_parse_for parses `for binder in <iterable> { body }` (§16 §1): the
// accumulating loop over a list expression or an `a..b` range. The range is
// parsed by the expression seam (fpm_parse_expression admits `..`).
fpm_parse_for :: proc(p: ^Fpm_Parser) -> (stmt: Fpm_Stmt, err: Fpm_Parse_Error) {
	fpm_expect(p, .For) or_return
	binder := fpm_expect_lower(p) or_return
	fpm_expect(p, .In) or_return
	iterable := fpm_parse_expression(p) or_return
	body := fpm_parse_block_body(p) or_return
	return Fpm_For{binder = binder, iterable = iterable, body = body}, .None
}

// fpm_parse_emit parses `emit <expr>` (§16 §2): the render geometry. It carries
// no name; the geometry lifts to a Solid for the gate.
fpm_parse_emit :: proc(p: ^Fpm_Parser) -> (node: Fpm_Bind, err: Fpm_Parse_Error) {
	fpm_expect(p, .Emit) or_return
	value := fpm_parse_expression(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Bind{kind = .Emit, value = value, solid = fpm_solid_of_expr(value)}, .None
}

// fpm_parse_named_bind parses the `<kw> name = <expr>` members that share a
// shape: anchor/socket/material/collide (§16 §2). The keyword selects the kind;
// the value lifts to a Solid when it is geometry (a collide proxy is `box(...)`),
// nil for a material/anchor that is not geometry.
fpm_parse_named_bind :: proc(p: ^Fpm_Parser) -> (node: Fpm_Bind, err: Fpm_Parse_Error) {
	kw := fpm_advance(p) or_return
	kind: Fpm_Bind_Kind
	#partial switch kw.kind {
	case .Anchor:
		kind = .Anchor
	case .Socket:
		kind = .Socket
	case .Material:
		kind = .Material
	case .Collide:
		kind = .Collide
	case:
		return node, .Unexpected_Token
	}
	name := fpm_expect_lower(p) or_return
	fpm_expect(p, .Eq) or_return
	value := fpm_parse_expression(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Bind{kind = kind, name = name, value = value, solid = fpm_solid_of_expr(value)}, .None
}

// fpm_parse_part parses `part name at BONE = <expr>` (§16 §7): the part's modeled
// origin IS that bone's joint (a checked pivot, downstream). The bone is an
// UPPER_IDENT; the value (a mesh fn call) lifts to a Solid through the fn it
// calls when the gate resolves it.
fpm_parse_part :: proc(p: ^Fpm_Parser) -> (node: Fpm_Bind, err: Fpm_Parse_Error) {
	fpm_expect(p, .Part) or_return
	name := fpm_expect_lower(p) or_return
	fpm_expect(p, .At) or_return
	bone := fpm_expect_upper(p) or_return
	fpm_expect(p, .Eq) or_return
	value := fpm_parse_expression(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Bind{kind = .Part, name = name, bone = bone, value = value, solid = fpm_solid_of_expr(value)}, .None
}

// fpm_parse_skeleton parses `skeleton: <topology>` (§16 §7): a named engine
// topology (`humanoid`/`quadruped`/`robot`). The inline bone-tree escape is
// spec-permitted but unexemplified, so only the named-topology form is grammar.
fpm_parse_skeleton :: proc(p: ^Fpm_Parser) -> (topology: string, err: Fpm_Parse_Error) {
	fpm_expect(p, .Skeleton) or_return
	fpm_expect(p, .Colon) or_return
	name := fpm_expect_lower(p) or_return
	fpm_terminate(p) or_return
	return name, .None
}

// fpm_parse_mirror parses `mirror L -> R` (§16 §7): model the left side, generate
// the right. Both labels are UPPER_IDENT.
fpm_parse_mirror :: proc(p: ^Fpm_Parser) -> (node: Fpm_Mirror, err: Fpm_Parse_Error) {
	fpm_expect(p, .Mirror) or_return
	from := fpm_expect_upper(p) or_return
	fpm_expect(p, .Arrow) or_return
	to := fpm_expect_upper(p) or_return
	fpm_terminate(p) or_return
	return Fpm_Mirror{from = from, to = to}, .None
}

// fpm_parse_clearance parses `clearance N` (§16 §7): the warn-level minimum joint
// gap. N is a Number (Int or Float), folded to the float domain.
fpm_parse_clearance :: proc(p: ^Fpm_Parser) -> (value: f64, err: Fpm_Parse_Error) {
	fpm_expect(p, .Clearance) or_return
	num := fpm_parse_unary(p) or_return
	v, ok := fpm_eval_number(num)
	if !ok {
		return 0, .Unexpected_Token
	}
	fpm_terminate(p) or_return
	return v, .None
}

// fpm_parse_type parses a Type: `UPPER_IDENT TypeArgs?` or `[ Type ]` (fpm.ebnf
// Type). Only the head name is retained — generic/list arguments are dropped, as
// no gate reads them. A list type's head is "[]".
fpm_parse_type :: proc(p: ^Fpm_Parser) -> (name: string, err: Fpm_Parse_Error) {
	if fpm_peek_kind(p) == .L_Bracket {
		fpm_advance(p) or_return
		fpm_parse_type(p) or_return // element type, dropped
		fpm_expect(p, .R_Bracket) or_return
		return "[]", .None
	}
	head := fpm_expect_upper(p) or_return
	// Optional generic args `[T, …]` — consume and drop (no gate reads them).
	if fpm_peek_kind(p) == .L_Bracket {
		fpm_advance(p) or_return
		fpm_parse_type(p) or_return
		for fpm_peek_kind(p) == .Comma {
			fpm_advance(p) or_return
			fpm_parse_type(p) or_return
		}
		fpm_expect(p, .R_Bracket) or_return
	}
	return head, .None
}

// ── Expression ladder (fpm.ebnf §57) ─────────────────────────────────────────

// fpm_parse_expression is the single expression seam. It parses the add-level
// expression, then admits the `..` range operator at the top — `a..b` is an
// iterable expression (§16 §1), parsed only at expression top-level so it never
// collides with a member-access `.`.
fpm_parse_expression :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	lhs := fpm_parse_add(p) or_return
	if fpm_peek_kind(p) == .Dot_Dot {
		fpm_advance(p) or_return
		hi := fpm_parse_add(p) or_return
		node := new(Fpm_Range, context.temp_allocator)
		node^ = Fpm_Range{lo = lhs, hi = hi}
		return node, .None
	}
	return lhs, .None
}

// fpm_parse_add parses `MulExpr (('+' | '-') MulExpr)*` (fpm.ebnf AddExpr),
// left-associative.
fpm_parse_add :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	lhs := fpm_parse_mul(p) or_return
	for fpm_peek_kind(p) == .Plus || fpm_peek_kind(p) == .Minus {
		op := fpm_advance(p) or_return
		rhs := fpm_parse_mul(p) or_return
		node := new(Fpm_Binary, context.temp_allocator)
		node^ = Fpm_Binary{op = op.kind, lhs = lhs, rhs = rhs}
		lhs = node
	}
	return lhs, .None
}

// fpm_parse_mul parses `UnaryExpr (('*' | '/' | '%') UnaryExpr)*` (fpm.ebnf
// MulExpr), left-associative — higher precedence than add.
fpm_parse_mul :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	lhs := fpm_parse_unary(p) or_return
	for fpm_peek_kind(p) == .Star || fpm_peek_kind(p) == .Slash || fpm_peek_kind(p) == .Percent {
		op := fpm_advance(p) or_return
		rhs := fpm_parse_unary(p) or_return
		node := new(Fpm_Binary, context.temp_allocator)
		node^ = Fpm_Binary{op = op.kind, lhs = lhs, rhs = rhs}
		lhs = node
	}
	return lhs, .None
}

// fpm_parse_unary parses `'-' UnaryExpr | PostfixExpr` (fpm.ebnf UnaryExpr): a
// leading `-` is the unary negation (the sole prefix operator); otherwise a
// postfix expression.
fpm_parse_unary :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	if fpm_peek_kind(p) == .Minus {
		fpm_advance(p) or_return
		operand := fpm_parse_unary(p) or_return
		node := new(Fpm_Unary, context.temp_allocator)
		node^ = Fpm_Unary{op = .Minus, operand = operand}
		return node, .None
	}
	return fpm_parse_postfix(p)
}

// fpm_parse_postfix parses `Atom PostfixOp*` (fpm.ebnf PostfixExpr): an atom
// followed by zero or more postfix operators. A postfix op is `.member CallArgs?`
// (member access, optionally a method call — `.up(0)`, `.face("top")`) or bare
// `CallArgs` (a direct call — `capsule(r, h)`, `torso_mesh()`). The chain is
// left-associative: each op wraps the running expression as its receiver/callee.
fpm_parse_postfix :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	atom := fpm_parse_atom(p) or_return
	for {
		#partial switch fpm_peek_kind(p) {
		case .Dot:
			fpm_advance(p) or_return
			member := fpm_expect_lower(p) or_return
			mnode := new(Fpm_Member, context.temp_allocator)
			mnode^ = Fpm_Member{receiver = atom, member = member}
			if fpm_peek_kind(p) == .L_Paren {
				args := fpm_parse_call_args(p) or_return
				cnode := new(Fpm_Call, context.temp_allocator)
				cnode^ = Fpm_Call{callee = mnode, args = args}
				atom = cnode
			} else {
				atom = mnode
			}
		case .L_Paren:
			args := fpm_parse_call_args(p) or_return
			cnode := new(Fpm_Call, context.temp_allocator)
			cnode^ = Fpm_Call{callee = atom, args = args}
			atom = cnode
		case:
			return atom, .None
		}
	}
}

// fpm_parse_call_args parses `( (Arg (',' Arg)*)? )` (fpm.ebnf CallArgs). Each
// Arg is `(LOWER_IDENT ':')? Expr` — a named arg when a bare LOWER_IDENT is
// followed by `:`, else positional. The named-vs-positional discrimination is the
// one place the grammar is not LL(1): it peeks two tokens (an Ident then `:`),
// which the spec licenses for `.fpm` (fpm.ebnf header).
fpm_parse_call_args :: proc(p: ^Fpm_Parser) -> (args: []Fpm_Arg, err: Fpm_Parse_Error) {
	fpm_expect(p, .L_Paren) or_return
	list := make([dynamic]Fpm_Arg, 0, 4, context.temp_allocator)
	for fpm_peek_kind(p) != .R_Paren && !fpm_at_end(p) {
		arg: Fpm_Arg
		// Two-token peek: a LOWER_IDENT immediately followed by `:` is a label.
		if fpm_peek_kind(p) == .Lower_Ident && fpm_peek_kind_at(p, 1) == .Colon {
			label := fpm_advance(p) or_return
			fpm_advance(p) or_return // `:`
			arg.label = label.text
			arg.labeled = true
		}
		arg.value = fpm_parse_expression(p) or_return
		append(&list, arg)
		if fpm_peek_kind(p) == .Comma {
			fpm_advance(p) or_return
		}
	}
	fpm_expect(p, .R_Paren) or_return
	return list[:], .None
}

// fpm_parse_atom parses `Number | String | LOWER_IDENT | UPPER_IDENT | '(' Expr
// ')'` (fpm.ebnf Atom). A parenthesized expression groups; a name carries its
// initial-case class.
fpm_parse_atom :: proc(p: ^Fpm_Parser) -> (expr: Fpm_Expr, err: Fpm_Parse_Error) {
	tok := fpm_peek(p)
	#partial switch tok.kind {
	case .Int_Lit:
		fpm_advance(p) or_return
		node := new(Fpm_Int_Lit, context.temp_allocator)
		node^ = Fpm_Int_Lit{value = tok.int_value}
		return node, .None
	case .Float_Lit:
		fpm_advance(p) or_return
		node := new(Fpm_Float_Lit, context.temp_allocator)
		node^ = Fpm_Float_Lit{value = tok.float_value}
		return node, .None
	case .String_Lit:
		fpm_advance(p) or_return
		node := new(Fpm_String_Lit, context.temp_allocator)
		node^ = Fpm_String_Lit{text = tok.text}
		return node, .None
	case .Lower_Ident, .Upper_Ident:
		fpm_advance(p) or_return
		node := new(Fpm_Name, context.temp_allocator)
		node^ = Fpm_Name{name = tok.text, ident_case = tok.ident_case}
		return node, .None
	case .L_Paren:
		fpm_advance(p) or_return
		inner := fpm_parse_expression(p) or_return
		fpm_expect(p, .R_Paren) or_return
		return inner, .None
	}
	if fpm_at_end(p) {
		return expr, .Unexpected_End
	}
	return expr, .Unexpected_Token
}

// ── Solid lifting ────────────────────────────────────────────────────────────

// PRIM_DIM_COUNT is the closed arity each primitive constructor takes (§16 §2):
// capsule(r, h) and cyl(r, h) take 2, sphere(r) takes 1, box(w, d, h) takes 3.
// The gate reads this to know how many dims a primitive carries.
@(rodata)
FPM_PRIM_NAMES := [Fpm_Prim_Kind]string {
	.Capsule = "capsule",
	.Sphere  = "sphere",
	.Box     = "box",
	.Cyl     = "cyl",
}

@(rodata)
FPM_TRANSFORM_NAMES := [Fpm_Transform_Kind]string {
	.Up     = "up",
	.Down   = "down",
	.At     = "at",
	.Rotate = "rotate",
	.Scale  = "scale",
}

@(rodata)
FPM_BOOL_NAMES := [Fpm_Bool_Kind]string {
	.Union      = "union",
	.Difference = "difference",
	.Intersect  = "intersect",
}

// fpm_solid_of_expr lifts a geometry-valued expression into the Solid IR the
// §16.3 gates score. A bare-name call to a primitive constructor (`capsule(r,
// h)`) becomes an Fpm_Primitive with its sizing folded to the float domain; a
// method-call transform (`...up(0)`, `...scale(2)`) wraps its receiver solid; a
// boolean call (`union(a, b)`, `difference(a, b)`) wraps its operand solids. Any
// expression that is not one of these geometry forms (a `pbr(...)` material, a
// fn call that does not name a primitive) lifts to nil — the gate scores only the
// solids it can size, and a non-geometry binding carries no solid.
fpm_solid_of_expr :: proc(expr: Fpm_Expr) -> Fpm_Solid {
	call, is_call := expr.(^Fpm_Call)
	if !is_call {
		return nil
	}
	// A method call's callee is a Member — it is a transform (.up/.scale/…) over
	// the receiver's solid.
	if member, is_member := call.callee.(^Fpm_Member); is_member {
		if kind, ok := fpm_transform_kind(member.member); ok {
			inner := fpm_solid_of_expr(member.receiver)
			if inner == nil {
				return nil
			}
			node := new(Fpm_Transform, context.temp_allocator)
			node^ = Fpm_Transform{kind = kind, inner = inner, scale = fpm_transform_scale(kind, call.args)}
			return node
		}
		return nil
	}
	// A bare-name call is a primitive or a boolean.
	name, is_name := call.callee.(^Fpm_Name)
	if !is_name {
		return nil
	}
	if kind, ok := fpm_prim_kind(name.name); ok {
		return fpm_lift_primitive(kind, call.args)
	}
	if kind, ok := fpm_bool_kind(name.name); ok {
		return fpm_lift_boolean(kind, call.args)
	}
	return nil
}

// fpm_lift_primitive builds an Fpm_Primitive from a constructor call, folding
// each positional argument to a float dimension. A non-foldable argument (a
// param reference the gate cannot resolve) is recorded with ok=false handling:
// the dim slot holds the folded value only when foldable, else a sentinel the
// gate treats as "unknown, not degenerate" (it stores -1, distinct from a real
// zero, so an unknown-radius primitive is not falsely flagged Zero_Volume).
fpm_lift_primitive :: proc(kind: Fpm_Prim_Kind, args: []Fpm_Arg) -> Fpm_Solid {
	dims := make([]f64, len(args), context.temp_allocator)
	for arg, i in args {
		if v, ok := fpm_eval_number(arg.value); ok {
			dims[i] = v
		} else {
			dims[i] = -1 // unknown sizing — the gate distinguishes this from a real 0
		}
	}
	node := new(Fpm_Primitive, context.temp_allocator)
	node^ = Fpm_Primitive{kind = kind, dims = dims}
	return node
}

// fpm_lift_boolean builds an Fpm_Boolean from a CSG call, lifting each operand to
// a solid. An operand that does not lift to geometry is dropped — a well-formed
// boolean's operands are all solids, and the gate scores only the lifted ones.
fpm_lift_boolean :: proc(kind: Fpm_Bool_Kind, args: []Fpm_Arg) -> Fpm_Solid {
	operands := make([dynamic]Fpm_Solid, 0, len(args), context.temp_allocator)
	for arg in args {
		if solid := fpm_solid_of_expr(arg.value); solid != nil {
			append(&operands, solid)
		}
	}
	node := new(Fpm_Boolean, context.temp_allocator)
	node^ = Fpm_Boolean{kind = kind, operands = operands[:]}
	return node
}

// fpm_transform_scale extracts the uniform scale factor of a `.scale(s)`
// transform from its first argument; every other transform leaves volume
// unchanged, so its scale is 1.0.
fpm_transform_scale :: proc(kind: Fpm_Transform_Kind, args: []Fpm_Arg) -> f64 {
	if kind != .Scale || len(args) == 0 {
		return 1
	}
	if v, ok := fpm_eval_number(args[0].value); ok {
		return v
	}
	return 1
}

// fpm_eval_number folds a numeric expression in the float domain (§16 §1): a
// literal, a unary negation, or arithmetic over foldable operands. A name (a
// param reference, an enum-like color) is not foldable here — the gate scores a
// primitive's literal/arithmetic sizing and treats a param-driven dimension as
// unknown rather than guessing. ok is false for any unfoldable form so the caller
// distinguishes an unknown size from a real zero.
fpm_eval_number :: proc(expr: Fpm_Expr) -> (value: f64, ok: bool) {
	switch e in expr {
	case ^Fpm_Int_Lit:
		return f64(e.value), true
	case ^Fpm_Float_Lit:
		return e.value, true
	case ^Fpm_Unary:
		inner := fpm_eval_number(e.operand) or_return
		return -inner, true
	case ^Fpm_Binary:
		lhs := fpm_eval_number(e.lhs) or_return
		rhs := fpm_eval_number(e.rhs) or_return
		#partial switch e.op {
		case .Plus:
			return lhs + rhs, true
		case .Minus:
			return lhs - rhs, true
		case .Star:
			return lhs * rhs, true
		case .Slash:
			if rhs == 0 {
				return 0, false
			}
			return lhs / rhs, true
		case .Percent:
			if rhs == 0 {
				return 0, false
			}
			return lhs - rhs*f64(i64(lhs/rhs)), true
		}
		return 0, false
	case ^Fpm_String_Lit, ^Fpm_Name, ^Fpm_Member, ^Fpm_Call, ^Fpm_Range:
		return 0, false
	case nil:
		return 0, false
	}
	return 0, false
}

// fpm_prim_kind maps a constructor name to its primitive kind, or ok=false for a
// non-primitive name.
fpm_prim_kind :: proc(name: string) -> (kind: Fpm_Prim_Kind, ok: bool) {
	for candidate in Fpm_Prim_Kind {
		if FPM_PRIM_NAMES[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

// fpm_transform_kind maps a member name to its transform kind, or ok=false for a
// non-transform member (`.face`, `.center` — a query, not a placement).
fpm_transform_kind :: proc(name: string) -> (kind: Fpm_Transform_Kind, ok: bool) {
	for candidate in Fpm_Transform_Kind {
		if FPM_TRANSFORM_NAMES[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

// fpm_bool_kind maps a constructor name to its CSG boolean kind, or ok=false for
// a non-boolean name.
fpm_bool_kind :: proc(name: string) -> (kind: Fpm_Bool_Kind, ok: bool) {
	for candidate in Fpm_Bool_Kind {
		if FPM_BOOL_NAMES[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

// ── Type / identifier expectations ───────────────────────────────────────────

// fpm_expect_lower consumes a LOWER_IDENT, rejecting an UPPER_IDENT in a
// lower-only position (a value/param/fn name) with Wrong_Case.
fpm_expect_lower :: proc(p: ^Fpm_Parser) -> (name: string, err: Fpm_Parse_Error) {
	tok := fpm_advance(p) or_return
	if tok.kind != .Lower_Ident {
		if tok.kind == .Upper_Ident {
			return "", .Wrong_Case
		}
		return "", .Unexpected_Token
	}
	return tok.text, .None
}

// fpm_expect_upper consumes an UPPER_IDENT, rejecting a LOWER_IDENT in an
// upper-only position (a type/bone/side label) with Wrong_Case.
fpm_expect_upper :: proc(p: ^Fpm_Parser) -> (name: string, err: Fpm_Parse_Error) {
	tok := fpm_advance(p) or_return
	if tok.kind != .Upper_Ident {
		if tok.kind == .Lower_Ident {
			return "", .Wrong_Case
		}
		return "", .Unexpected_Token
	}
	return tok.text, .None
}

// ── Cursor helpers ───────────────────────────────────────────────────────────

fpm_at_end :: proc(p: ^Fpm_Parser) -> bool {
	return p.pos >= len(p.tokens)
}

// fpm_peek reports an Invalid token at end of input so a kind check fails closed
// without a separate end test.
fpm_peek :: proc(p: ^Fpm_Parser) -> Fpm_Token {
	if fpm_at_end(p) {
		return Fpm_Token{kind = .Invalid}
	}
	return p.tokens[p.pos]
}

fpm_peek_kind :: proc(p: ^Fpm_Parser) -> Fpm_Token_Kind {
	return fpm_peek(p).kind
}

// fpm_peek_kind_at reports the kind `offset` tokens ahead — the bounded
// lookahead the named-argument discrimination needs (an Ident then `:`). Invalid
// past the end so the check fails closed.
fpm_peek_kind_at :: proc(p: ^Fpm_Parser, offset: int) -> Fpm_Token_Kind {
	idx := p.pos + offset
	if idx >= len(p.tokens) {
		return .Invalid
	}
	return p.tokens[idx].kind
}

fpm_advance :: proc(p: ^Fpm_Parser) -> (tok: Fpm_Token, err: Fpm_Parse_Error) {
	if fpm_at_end(p) {
		return Fpm_Token{}, .Unexpected_End
	}
	tok = p.tokens[p.pos]
	p.pos += 1
	return tok, .None
}

fpm_expect :: proc(p: ^Fpm_Parser, kind: Fpm_Token_Kind) -> (tok: Fpm_Token, err: Fpm_Parse_Error) {
	tok = fpm_advance(p) or_return
	if tok.kind != kind {
		return Fpm_Token{}, .Unexpected_Token
	}
	return tok, .None
}

// fpm_terminate consumes a Sep (newline/comma) statement terminator, accepting a
// closing brace or end of input as the implicit terminator of a scope's last
// member (fpm.ebnf Sep?).
fpm_terminate :: proc(p: ^Fpm_Parser) -> Fpm_Parse_Error {
	if fpm_peek_kind(p) == .Newline || fpm_peek_kind(p) == .Comma {
		fpm_skip_seps(p)
		return .None
	}
	if fpm_at_end(p) || fpm_peek_kind(p) == .R_Brace {
		return .None
	}
	return .Unexpected_Token
}

// fpm_skip_seps consumes a run of Sep tokens (newline or comma) between members
// or statements (fpm.ebnf Sep — `(NEWLINE | ',')+`).
fpm_skip_seps :: proc(p: ^Fpm_Parser) {
	for fpm_peek_kind(p) == .Newline || fpm_peek_kind(p) == .Comma {
		p.pos += 1
	}
}

fpm_skip_newlines :: proc(p: ^Fpm_Parser) {
	for fpm_peek_kind(p) == .Newline {
		p.pos += 1
	}
}
