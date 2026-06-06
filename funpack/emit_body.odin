// The §2.7 body serializer: it lowers a checked body (a sequence of statement
// subtrees) into the pre-order `node` run the artifact carries
// (docs/artifact-format.md §2.7). Every fn body, behavior step body, const
// initializer, and the bindings/setup bodies serialize through this one walk, so
// the runtime interprets the carried node graph directly with no funpack source
// on its path. The walk is depth-first, node-then-children, and every node line
// ends in its child_count (the `arm` node is the one exception — its trailing
// field is the binder list, so its child count is fixed at 0 by kind).
//
// This file also renders the syntactic types and primitive literals the body
// and schema lines carry — a Type_Ref to its source spelling (`View[Paddle]`,
// `[Goal]`) and a literal Expr to its §2 primitive encoding.
package funpack

import "core:strings"

// emit_body writes a body's node run (docs/artifact-format.md §2.7): the
// back-to-back pre-order subtrees of its top-level statements, in source order.
// The owning record's body_count is len(body), and this run is exactly those
// statement subtrees with no leftover lines.
emit_body :: proc(b: ^strings.Builder, body: []Statement) {
	for stmt in body {
		emit_statement(b, stmt)
	}
}

// emit_statement serializes one top-level body statement as a node subtree
// (docs/artifact-format.md §2.7): a `let n = e` is a `let` node over its value,
// a `return e` is a `return` node over its value, and an `if cond { return v }`
// early-return guard is an `if_return` node over (condition, returned value).
// The gameplay surface's guard blocks are the single-`return` shape, so the
// if_return's second child is the guard's returned expression.
emit_statement :: proc(b: ^strings.Builder, stmt: Statement) {
	switch node in stmt {
	case Let_Node:
		emit_line(b, "node let ", node.name, " 1")
		emit_expr(b, node.value)
	case Return_Node:
		emit_line(b, "node return 1")
		emit_expr(b, node.value)
	case If_Node:
		emit_line(b, "node if_return 2")
		emit_expr(b, node.cond)
		emit_expr(b, if_return_value(node))
	case Assert_Node:
		// Assert is a test-body statement, never a fn/step/const body — the
		// emitter serializes only executable bodies the runtime interprets, so
		// an assert never reaches here.
	}
}

// if_return_value returns the value an early-return guard returns — the value of
// the guard block's single `return` statement (docs/artifact-format.md §2.7).
// The gameplay surface's guards are the single-`return` shape proven by the
// frontend, so the body's lone statement is a `return`.
if_return_value :: proc(node: If_Node) -> Expr {
	if len(node.body) == 1 {
		if ret, ok := node.body[0].(Return_Node); ok {
			return ret.value
		}
	}
	return nil
}

// emit_expr serializes one expression as a pre-order node subtree
// (docs/artifact-format.md §2.7): one `node KIND field… child_count` line, then
// its children in evaluation/source order. The node kind mirrors the checked
// surface AST (spec §02 §5–§6); each arm writes its scalar fields, then recurses
// into its children, so a reader rebuilds the tree by consuming exactly each
// node's declared child count.
emit_expr :: proc(b: ^strings.Builder, expr: Expr) {
	switch e in expr {
	case ^Int_Lit_Expr:
		emit_line(b, "node int ", encode_int(e.value, context.temp_allocator), " 0")
	case ^Fixed_Lit_Expr:
		emit_line(b, "node fixed ", encode_fixed(e.bits, context.temp_allocator), " 0")
	case ^String_Lit_Expr:
		emit_line(b, "node string ", encode_string(e.text, context.temp_allocator), " 0")
	case ^Name_Expr:
		emit_line(b, "node name ", e.name, " 0")
	case ^Member_Expr:
		emit_line(b, "node field ", e.member, " 1")
		emit_expr(b, e.receiver)
	case ^Call_Expr:
		emit_call(b, e)
	case ^Variant_Expr:
		emit_variant(b, e)
	case ^Record_Expr:
		emit_record(b, e)
	case ^List_Expr:
		emit_list(b, e)
	case ^Lambda_Expr:
		emit_lambda(b, e)
	case ^Unary_Expr:
		emit_line(b, "node unary ", unary_op_name(e.op), " 1")
		emit_expr(b, e.operand)
	case ^Binary_Expr:
		emit_line(b, "node binary ", binary_op_name(e.op), " 2")
		emit_expr(b, e.lhs)
		emit_expr(b, e.rhs)
	case ^With_Expr:
		emit_with(b, e)
	case ^Match_Expr:
		emit_match(b, e)
	case ^Tuple_Expr:
		emit_tuple(b, e)
	}
}

// emit_tuple serializes a tuple literal `(a, b, …)` as a count-driven `tuple`
// node — a `tuple len` head with its `len` element subtrees in source order,
// the same total, lookahead-free shape as `list` (emit_list). The
// artifact-format §2.7 ratification of the `tuple` node KIND (it is a closed
// set, so a new kind is a schema-version bump) lands with the golden-
// integration seam that first emits a tuple-returning behavior end-to-end;
// this grammar seam emits the structurally-sound node so the body walk stays
// total and the build's complete Expr switch is exhaustive.
emit_tuple :: proc(b: ^strings.Builder, e: ^Tuple_Expr) {
	strings.write_string(b, "node tuple ")
	strings.write_int(b, len(e.elements))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.elements))
	emit_line(b, "")
	for element in e.elements {
		emit_expr(b, element)
	}
}

// emit_call serializes a call `f(a, b)` (docs/artifact-format.md §2.7): a `call`
// node with `1 + N` children — the callee subtree then the N argument subtrees,
// in source order.
emit_call :: proc(b: ^strings.Builder, e: ^Call_Expr) {
	emit_node_head(b, "call", 1 + len(e.args))
	emit_expr(b, e.callee)
	for arg in e.args {
		emit_expr(b, arg)
	}
}

// emit_variant serializes an enum-variant value (docs/artifact-format.md §2.7).
// A bare or tuple-payload variant `Type::Case` / `Type::Case(args)` is a
// `variant TYPE CASE has_payload` node whose children are the N positional
// payload arg subtrees. A struct-payload variant `Type::Case{ f: v, … }` (a
// command constructor like `Draw::Rect{…}`) is a `record` node whose type is the
// `::`-joined `Type::Case` and whose children are one `recfield` per named field
// — the same shape as a record literal, since a struct-payload variant IS a
// named-field constructor.
emit_variant :: proc(b: ^strings.Builder, e: ^Variant_Expr) {
	if e.has_fields {
		emit_struct_variant(b, e)
		return
	}
	strings.write_string(b, "node variant ")
	strings.write_string(b, e.type_name)
	strings.write_byte(b, ' ')
	strings.write_string(b, e.variant)
	strings.write_byte(b, ' ')
	strings.write_string(b, encode_bool(e.has_payload))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.payload))
	emit_line(b, "")
	for arg in e.payload {
		emit_expr(b, arg)
	}
}

// emit_struct_variant serializes a struct-payload variant `Type::Case{ f: v, … }`
// as a `record Type::Case field_count child_count` node (docs/artifact-format.md
// §2.7): the type is the `::`-joined constructor name and each named field is a
// `recfield` child, in source order. field_count and child_count are equal.
emit_struct_variant :: proc(b: ^strings.Builder, e: ^Variant_Expr) {
	strings.write_string(b, "node record ")
	strings.write_string(b, e.type_name)
	strings.write_string(b, "::")
	strings.write_string(b, e.variant)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.fields))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.fields))
	emit_line(b, "")
	for field in e.fields {
		emit_recfield(b, field)
	}
}

// emit_record serializes a record literal `Type{ f: v, … }`
// (docs/artifact-format.md §2.7): a `record TYPE field_count child_count` node
// whose children are one `recfield` per field, in source order. field_count and
// child_count are equal — each field contributes exactly one `recfield` subtree.
emit_record :: proc(b: ^strings.Builder, e: ^Record_Expr) {
	strings.write_string(b, "node record ")
	strings.write_string(b, e.type_name)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.fields))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.fields))
	emit_line(b, "")
	for field in e.fields {
		emit_recfield(b, field)
	}
}

// emit_recfield serializes one `name: value` pair of a record/with as a
// `recfield NAME` node with its single value-subtree child (docs/artifact-format
// .md §2.7).
emit_recfield :: proc(b: ^strings.Builder, field: Record_Field) {
	emit_line(b, "node recfield ", field.name, " 1")
	emit_expr(b, field.value)
}

// emit_with serializes a record-update `value with { f: v, … }`
// (docs/artifact-format.md §2.7): a `with field_count child_count` node whose
// `1 + field_count` children are the base value subtree then one `recfield` per
// replaced field, in source order.
emit_with :: proc(b: ^strings.Builder, e: ^With_Expr) {
	strings.write_string(b, "node with ")
	strings.write_int(b, len(e.fields))
	strings.write_byte(b, ' ')
	strings.write_int(b, 1 + len(e.fields))
	emit_line(b, "")
	emit_expr(b, e.base)
	for field in e.fields {
		emit_recfield(b, field)
	}
}

// emit_list serializes a list literal `[a, b]` (docs/artifact-format.md §2.7): a
// `list len` node whose children are the `len` element subtrees, in source
// order.
emit_list :: proc(b: ^strings.Builder, e: ^List_Expr) {
	strings.write_string(b, "node list ")
	strings.write_int(b, len(e.elements))
	strings.write_byte(b, ' ')
	strings.write_int(b, len(e.elements))
	emit_line(b, "")
	for element in e.elements {
		emit_expr(b, element)
	}
}

// emit_lambda serializes a lambda `fn(p) { return e }`
// (docs/artifact-format.md §2.7): a `lambda param_count params…` node whose
// single child is the single-return body expression.
emit_lambda :: proc(b: ^strings.Builder, e: ^Lambda_Expr) {
	strings.write_string(b, "node lambda ")
	strings.write_int(b, len(e.params))
	for param in e.params {
		strings.write_byte(b, ' ')
		strings.write_string(b, param)
	}
	emit_line(b, " 1")
	emit_expr(b, e.body)
}

// emit_match serializes a `match e { … }` (docs/artifact-format.md §2.7): a
// `match arm_count child_count` node with `1 + 2*arm_count` children — the
// scrutinee subtree, then for each arm an `arm` node immediately followed by its
// body subtree, in source order. The arm node carries the pattern; its body is
// the following sibling.
emit_match :: proc(b: ^strings.Builder, e: ^Match_Expr) {
	strings.write_string(b, "node match ")
	strings.write_int(b, len(e.arms))
	strings.write_byte(b, ' ')
	strings.write_int(b, 1 + 2 * len(e.arms))
	emit_line(b, "")
	emit_expr(b, e.scrutinee)
	for arm in e.arms {
		emit_arm(b, arm.pattern)
		emit_expr(b, arm.body)
	}
}

// emit_arm serializes one match arm's pattern (docs/artifact-format.md §2.7): an
// `arm pat type case binder_count binders…` node. The arm always has 0 children
// (its body is the next sibling under the match), and its trailing field is the
// variable-length binder list, so the line ends in the binders rather than a
// child_count. wildcard records `- -` for type/case; bare_variant and
// variant_binds record `type case`, the latter with its payload binder names.
emit_arm :: proc(b: ^strings.Builder, pattern: Pattern) {
	strings.write_string(b, "node arm ")
	switch pattern.kind {
	case .Wildcard:
		emit_line(b, "wildcard - - 0")
	case .Bare_Variant:
		strings.write_string(b, "bare_variant ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
		emit_line(b, " 0")
	case .Variant_Binds:
		strings.write_string(b, "variant_binds ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(pattern.binders))
		for binder in pattern.binders {
			strings.write_byte(b, ' ')
			strings.write_string(b, binder)
		}
		emit_line(b, "")
	case .Bare_Binder:
		// A bare binder position carries its single binding name. The
		// artifact-format §2.7 ratification of the bare_binder/tuple arm KINDs
		// lands with the golden-integration seam (a closed-set schema bump);
		// this grammar seam emits the structurally-honest form so the body
		// walk stays total and the complete Pattern_Kind switch is exhaustive.
		strings.write_string(b, "bare_binder ")
		strings.write_string(b, tuple_binder_name(pattern))
		emit_line(b, " 0")
	case .Tuple:
		strings.write_string(b, "tuple ")
		strings.write_int(b, len(pattern.elements))
		emit_line(b, "")
		for sub in pattern.elements {
			emit_arm(b, sub)
		}
	}
}

// tuple_binder_name returns a bare-binder pattern's single binding name (it
// lives in the one-element binders slice), or "-" when the slice is empty.
tuple_binder_name :: proc(pattern: Pattern) -> string {
	if len(pattern.binders) == 1 {
		return pattern.binders[0]
	}
	return "-"
}

// emit_node_head writes a node line's `node KIND … child_count` prefix for a
// kind with no scalar fields (call/if_return/return), then terminates the line.
// A kind with scalar fields writes them inline before its count instead.
emit_node_head :: proc(b: ^strings.Builder, kind: string, child_count: int) {
	strings.write_string(b, "node ")
	strings.write_string(b, kind)
	strings.write_byte(b, ' ')
	strings.write_int(b, child_count)
	emit_line(b, "")
}

// unary_op_name maps a unary operator token to its node op name
// (docs/artifact-format.md §2.7): `-` → `neg`, the word operator `not` → `not`.
unary_op_name :: proc(op: Token) -> string {
	if op.kind == .Minus {
		return "neg"
	}
	return "not"
}

// binary_op_name maps a binary operator token to its node op name — the closed
// glyph set by name (docs/artifact-format.md §2.7). `and`/`or` are word
// operators carried as Ident tokens, keyed by text; every other operator is a
// glyph keyed by kind.
binary_op_name :: proc(op: Token) -> string {
	#partial switch op.kind {
	case .Plus:
		return "add"
	case .Minus:
		return "sub"
	case .Star:
		return "mul"
	case .Slash:
		return "div"
	case .Percent:
		return "mod"
	case .Eq_Eq:
		return "eq"
	case .Not_Eq:
		return "ne"
	case .Lt:
		return "lt"
	case .Lt_Eq:
		return "le"
	case .Gt:
		return "gt"
	case .Gt_Eq:
		return "ge"
	case .Ident:
		switch op.text {
		case "and":
			return "and"
		case "or":
			return "or"
		}
	}
	return ""
}

// type_ref_string renders a syntactic Type_Ref to its source spelling
// (docs/artifact-format.md §2.6, §6, §9): a bare name (`Fixed`), a list `[T]`,
// a tuple `(T, U)`, or a generic application `Ctor[Arg, …]` (`View[Paddle]`,
// `Option[Side]`). The artifact carries the type as written, so a list head
// "[]" renders to the bracketed form, a tuple head "()" to the parenthesized
// comma-list, and a generic to its `Ctor[args]` form.
type_ref_string :: proc(ref: Type_Ref) -> string {
	if ref.name == "[]" {
		if len(ref.args) == 1 {
			return strings.concatenate({"[", type_ref_string(ref.args[0]), "]"}, context.temp_allocator)
		}
		return "[]"
	}
	if ref.name == "()" {
		// A tuple type spells as `(T, U, …)` — its positional element types
		// comma-joined, the source spelling the §04 §1 return pair is written in.
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '(')
		for arg, i in ref.args {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, type_ref_string(arg))
		}
		strings.write_byte(&b, ')')
		return strings.to_string(b)
	}
	if len(ref.args) == 0 {
		return ref.name
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ref.name)
	strings.write_byte(&b, '[')
	for arg, i in ref.args {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, type_ref_string(arg))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// encode_literal renders a scalar literal expression in this format's primitive
// encoding (docs/artifact-format.md §2): an Int in decimal, a Fixed as its raw
// Q32.32 bits, a Bool as `true`/`false`, a String length-prefixed. It backs the
// `=ENCODED` field default (§6) and the scalar setup values (§13). A non-literal
// expression yields the empty string — the gate stage already proved defaults
// and setup values are concrete literals, so the gameplay path never hits it.
encode_literal :: proc(expr: Expr) -> string {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return encode_int(e.value, context.temp_allocator)
	case ^Fixed_Lit_Expr:
		return encode_fixed(e.bits, context.temp_allocator)
	case ^String_Lit_Expr:
		return encode_string(e.text, context.temp_allocator)
	case ^Name_Expr:
		if e.name == "true" || e.name == "false" {
			return e.name
		}
	}
	return ""
}
