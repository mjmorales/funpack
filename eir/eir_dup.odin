// The dup clone engine: a bottom-up canonical-form serialization over core:odin/ast
// that RETARGETS funpack's §29 dup_class doctrine (funpack/gates.odin: dup_canon /
// dup_class / canon_expr / canon_name) from the funpack AST onto Odin's. The
// doctrine, mirrored verbatim: an alpha frame holds bound names in binding order, a
// reference to a bound name canonicalizes to its positional SLOT INDEX (so two units
// identical modulo bound-name renaming canonicalize identically — Type-2), a FREE
// name (anything not bound in the unit — a package-qualified call, a type, a field
// selector) keeps its spelling, and the canonical BYTES are the clone identity. Like
// funpack, eir canonicalizes EVERY subtree bottom-up: a node's canonical form folds
// its kind tag, its kept free spellings, and its children's canonical bytes
// (length-prefixed), so equal subtrees produce byte-equal forms at every level and
// the clusterer can report clones wherever they sit.
//
// core:hash.fnv64a digests each node's canonical bytes into a u64 used ONLY as a
// bucket index for clustering. Identity is decided by exact byte-equality of the
// canonical form, never by the digest, so a 64-bit hash collision can never merge
// two structurally-distinct subtrees into one false clone — this is why a parent
// folds its children's full canonical bytes, not a digest of them.
//
// The walk replaces core:odin/ast's own visitor (ast.walk/inspect): that visitor
// threads no scope state and yields no per-node child ordering, so the alpha frame
// and the bottom-up fold are driven by a manual switch over `derived` that mirrors
// walk.odin's child-traversal map node-for-node.
package eir

import "base:runtime"
import "core:hash"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// DEFAULT_MIN_NODES is the subtree node-count floor below which a clone class is
// dropped as noise: a bare identifier, a two-node expression, a one-line call all
// recur across a codebase without signalling real duplication. Thirty nodes is
// roughly a small multi-statement block — the smallest clone worth a human's
// attention (decision eir-dup-min-nodes-default-30).
DEFAULT_MIN_NODES :: 30

// Dup_Options configures one clone scan. min_nodes is the node-count floor;
// fold_literals, when set, canonicalizes every literal to a single token so two
// subtrees that differ only in their constants collide — the "same shape, different
// numbers" clone that distinct-literal hashing keeps apart.
Dup_Options :: struct {
	min_nodes:     int,
	fold_literals: bool,
}

// dup_default_options returns the engine defaults — the option set `eir dup` runs
// with when the operator passes no overriding flag.
dup_default_options :: proc() -> Dup_Options {
	return Dup_Options{min_nodes = DEFAULT_MIN_NODES, fold_literals = false}
}

// Clone_Instance is one occurrence of a clone class: where the duplicated subtree
// sits. path borrows the loader's path string (valid for the loader's lifetime),
// is_test carries the discovery tag so a report can scope test vs production code,
// and the line span comes from the node's start/end tokens.
Clone_Instance :: struct {
	path:       string,
	is_test:    bool,
	line_start: int,
	line_end:   int,
}

// Clone_Class is one set of structurally-identical subtrees (modulo bound-name
// alpha-renaming, and modulo literals when fold_literals is set). hash is the shared
// fnv64a digest of the canonical form — a bucket index, not a unique id, since a
// 64-bit collision can seat two distinct-canon classes at one hash — node_count the
// subtree size (used for the floor and for maximal-only ranking), kind the
// node-kind tag of the clone root (for a report's label), and instances every
// occurrence in deterministic order. A class always carries >= 2 instances — a
// single occurrence is not a clone.
Clone_Class :: struct {
	hash:       u64,
	node_count: int,
	kind:       string,
	instances:  []Clone_Instance,
}

// Subtree_Record is one canonicalized subtree the walk kept: its canonical bytes
// (the clone IDENTITY), its fnv64a digest (a bucket index over those bytes), node
// count, kind tag, and source location. Only subtrees at or above the floor are
// recorded — the floor is applied at record time so the candidate set never holds
// the noise it would later drop. Package-private (not file-private) so the
// collision-trust regression can drive cluster_and_suppress with synthetic records.
@(private)
Subtree_Record :: struct {
	hash:       u64,
	canon:      string,
	node_count: int,
	kind:       string,
	path:       string,
	is_test:    bool,
	line_start: int,
	line_end:   int,
}

// Dup_Engine is the per-scan state the hashing walk threads: the options, the
// growing record set, and the current file's path/test tag (set before each file so
// dup_canon can stamp a record without re-deriving it). records and per-node scratch
// live in context.temp_allocator; the returned classes live in the find_clones
// allocator.
@(private = "file")
Dup_Engine :: struct {
	opts:        Dup_Options,
	records:     [dynamic]Subtree_Record,
	cur_path:    string,
	cur_is_test: bool,
}

// find_clones runs the doctrine over a Load_Result and returns the clone classes in
// a deterministic order (by hash, then first-instance span). It walks each parsed
// file's top-level declarations with a FRESH alpha frame per declaration — mirroring
// funpack's per-unit reset, so a package-level name is always free and slot indices
// align across two alpha-equivalent declarations. The result borrows the loader's
// path strings; keep the loader alive while reading it.
find_clones :: proc(
	result: Load_Result,
	opts: Dup_Options,
	allocator := context.allocator,
) -> []Clone_Class {
	floor := opts.min_nodes
	if floor < 1 {
		floor = 1
	}

	eng := Dup_Engine {
		opts    = Dup_Options{min_nodes = floor, fold_literals = opts.fold_literals},
		records = make([dynamic]Subtree_Record, 0, 256, context.temp_allocator),
	}

	alpha := make([dynamic]string, 0, 16, context.temp_allocator)
	for loaded in result.files {
		if loaded.file == nil {
			continue
		}
		eng.cur_path = loaded.path
		eng.cur_is_test = loaded.is_test
		for decl in loaded.file.decls {
			clear(&alpha)
			dup_canon(&eng, decl, &alpha, false)
		}
	}

	return cluster_and_suppress(eng.records[:], allocator)
}

// Subtree_Fingerprint is one subtree's identity for the near-miss tier: the canonical
// hash the exact tier clusters on, and node_count as its weight (a larger shared subtree
// is stronger evidence of similarity than a tiny one). Package-private so the near tier
// (eir_near.odin) consumes it while the canon walk that produces it stays file-private.
@(private)
Subtree_Fingerprint :: struct {
	hash:       u64,
	node_count: int,
}

// canon_fingerprint canonicalizes ONE top-level declaration and returns every subtree at
// or above `floor` as a (hash, node_count), plus the whole declaration's own hash and
// node count. The near-miss tier compares two declarations by the OVERLAP of these
// subtree multisets, so it measures similarity over the SAME canonical form the exact
// tier clusters on — a renamed-but-near-identical proc shares almost every subtree hash.
// Only the floor differs from a clone scan: it is finer (sub-proc shingles, not the
// 30-node clone floor) so a small shared block still registers. The walk is dup_canon
// itself — the near tier never re-implements the canonicalization, so the two tiers can
// never drift apart (and the near walk can never become the clone the gate would flag).
// decl_hash lets a caller drop exact-clone pairs (identical whole-decl canon), which
// belong to the exact tier, keeping the two surfaces disjoint. Allocated in `allocator`.
@(private)
canon_fingerprint :: proc(
	decl: ^ast.Node,
	floor: int,
	fold_literals: bool,
	allocator := context.allocator,
) -> (
	decl_hash: u64,
	decl_node_count: int,
	subtrees: []Subtree_Fingerprint,
) {
	min_nodes := floor
	if min_nodes < 1 {
		min_nodes = 1
	}
	eng := Dup_Engine {
		opts    = Dup_Options{min_nodes = min_nodes, fold_literals = fold_literals},
		records = make([dynamic]Subtree_Record, 0, 64, context.temp_allocator),
	}
	alpha := make([dynamic]string, 0, 16, context.temp_allocator)
	canon, n := dup_canon(&eng, decl, &alpha, false)

	out := make([]Subtree_Fingerprint, len(eng.records), allocator)
	for r, i in eng.records {
		out[i] = Subtree_Fingerprint{hash = r.hash, node_count = r.node_count}
	}
	return hash.fnv64a(transmute([]byte)canon), n, out
}

// dup_canon computes the canonical bytes of the subtree rooted at `node`, threading
// the alpha frame and recording the subtree when it meets the floor. canon folds the
// kind tag, the node's kept free spellings, and the children's canonical bytes
// (length-prefixed); n is the subtree node count. The bucketing digest is
// fnv64a(canon), computed where the record is stamped — canon, not the digest, is
// the clone identity. in_local marks whether `node` sits inside a procedure body: a
// LOCAL value declaration binds its names into the alpha frame (positional slots,
// renamed away), while a PACKAGE-level one keeps its names as free spellings (so two
// differently-named top-level procs do not collide at the declaration node — their
// proc literals collide instead, with the name excluded).
//
// Parentheses are transparent: a parenthesized expression canonicalizes as its inner
// expression, so `(x)` and `x` are one clone.
@(private = "file")
dup_canon :: proc(
	eng: ^Dup_Engine,
	node: ^ast.Node,
	alpha: ^[dynamic]string,
	in_local: bool,
) -> (
	canon: string,
	n: int,
) {
	if node == nil {
		return "", 0
	}
	if p, ok := node.derived.(^ast.Paren_Expr); ok && p.expr != nil {
		return dup_canon(eng, p.expr, alpha, in_local)
	}

	b := strings.builder_make(context.temp_allocator)
	n = 1
	kind := "nil"

	switch e in node.derived {
	case ^ast.Ident:
		kind = "ident"
		hb_str(&b, kind)
		hb_name(&b, e.name, alpha)
	case ^ast.Basic_Lit:
		kind = "lit"
		hb_str(&b, kind)
		hb_literal(&b, e.tok.text, eng.opts.fold_literals)
	case ^ast.Basic_Directive:
		kind = "basic_dir"
		hb_str(&b, kind)
		hb_str(&b, e.name)
	case ^ast.Implicit:
		kind = "implicit"
		hb_str(&b, kind)
		hb_str(&b, e.tok.text)
	case ^ast.Undef:
		kind = "undef"
		hb_str(&b, kind)
	case ^ast.Ellipsis:
		kind = "ellipsis"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
	case ^ast.Tag_Expr:
		kind = "tag_expr"
		hb_str(&b, kind)
		hb_str(&b, e.name)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
	case ^ast.Unary_Expr:
		kind = "unary"
		hb_str(&b, kind)
		hb_str(&b, e.op.text)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
	case ^ast.Binary_Expr:
		kind = "binary"
		hb_str(&b, kind)
		hb_str(&b, e.op.text)
		emit_child(eng, &b, e.left, alpha, in_local, &n)
		emit_child(eng, &b, e.right, alpha, in_local, &n)
	case ^ast.Paren_Expr:
		kind = "paren"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
	case ^ast.Selector_Expr:
		kind = "selector"
		hb_str(&b, kind)
		hb_str(&b, e.op.text)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		// The field is a structural selector (`.field`, `->field`), not a binding,
		// so its spelling is kept verbatim and never alpha-renamed.
		hb_str(&b, e.field != nil ? e.field.name : "")
	case ^ast.Implicit_Selector_Expr:
		kind = "implicit_selector"
		hb_str(&b, kind)
		hb_str(&b, e.field != nil ? e.field.name : "")
	case ^ast.Selector_Call_Expr:
		kind = "selector_call"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		emit_child(eng, &b, e.call, alpha, in_local, &n)
	case ^ast.Index_Expr:
		kind = "index"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		emit_child(eng, &b, e.index, alpha, in_local, &n)
	case ^ast.Matrix_Index_Expr:
		kind = "matrix_index"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		emit_child(eng, &b, e.row_index, alpha, in_local, &n)
		emit_child(eng, &b, e.column_index, alpha, in_local, &n)
	case ^ast.Deref_Expr:
		kind = "deref"
		hb_str(&b, kind)
		hb_str(&b, e.op.text)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
	case ^ast.Slice_Expr:
		kind = "slice"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		hb_str(&b, e.interval.text)
		emit_child(eng, &b, e.low, alpha, in_local, &n)
		emit_child(eng, &b, e.high, alpha, in_local, &n)
	case ^ast.Call_Expr:
		kind = "call"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		emit_exprs(eng, &b, e.args, alpha, in_local, &n)
	case ^ast.Field_Value:
		kind = "field_value"
		hb_str(&b, kind)
		hb_field_key(eng, &b, e.field, alpha, in_local, &n)
		emit_child(eng, &b, e.value, alpha, in_local, &n)
	case ^ast.Ternary_If_Expr:
		kind = "ternary_if"
		hb_str(&b, kind)
		emit_child(eng, &b, e.x, alpha, in_local, &n)
		emit_child(eng, &b, e.cond, alpha, in_local, &n)
		emit_child(eng, &b, e.y, alpha, in_local, &n)
	case ^ast.Ternary_When_Expr:
		kind = "ternary_when"
		hb_str(&b, kind)
		emit_child(eng, &b, e.x, alpha, in_local, &n)
		emit_child(eng, &b, e.cond, alpha, in_local, &n)
		emit_child(eng, &b, e.y, alpha, in_local, &n)
	case ^ast.Or_Else_Expr:
		kind = "or_else"
		hb_str(&b, kind)
		emit_child(eng, &b, e.x, alpha, in_local, &n)
		emit_child(eng, &b, e.y, alpha, in_local, &n)
	case ^ast.Or_Return_Expr:
		kind = "or_return"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
	case ^ast.Or_Branch_Expr:
		kind = "or_branch"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		emit_child(eng, &b, e.label, alpha, in_local, &n)
	case ^ast.Type_Assertion:
		kind = "type_assert"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
	case ^ast.Type_Cast:
		kind = "type_cast"
		hb_str(&b, kind)
		hb_str(&b, e.tok.text)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
	case ^ast.Auto_Cast:
		kind = "auto_cast"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
	case ^ast.Inline_Asm_Expr:
		kind = "inline_asm"
		hb_str(&b, kind)
		emit_exprs(eng, &b, e.param_types, alpha, in_local, &n)
		emit_child(eng, &b, e.return_type, alpha, in_local, &n)
		emit_child(eng, &b, e.constraints_string, alpha, in_local, &n)
		emit_child(eng, &b, e.asm_string, alpha, in_local, &n)
	case ^ast.Proc_Lit:
		kind = "proc_lit"
		hb_str(&b, kind)
		// Params and named returns bind ONLY inside the body: push them as positional
		// slots over a frame marker, walk the body, then pop — so the bindings never
		// leak past the literal and a param/return rename canonicalizes away.
		base := len(alpha)
		if e.type != nil {
			emit_signature(eng, &b, e.type.params, alpha, &n)
			emit_signature(eng, &b, e.type.results, alpha, &n)
		}
		emit_child(eng, &b, e.body, alpha, true, &n)
		resize(alpha, base)
	case ^ast.Comp_Lit:
		kind = "comp_lit"
		hb_str(&b, kind)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
		emit_exprs(eng, &b, e.elems, alpha, in_local, &n)
	case ^ast.Proc_Group:
		kind = "proc_group"
		hb_str(&b, kind)
		emit_exprs(eng, &b, e.args, alpha, in_local, &n)
	case ^ast.Typeid_Type:
		kind = "typeid_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.specialization, alpha, in_local, &n)
	case ^ast.Helper_Type:
		kind = "helper_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
	case ^ast.Distinct_Type:
		kind = "distinct_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
	case ^ast.Poly_Type:
		kind = "poly_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
		emit_child(eng, &b, e.specialization, alpha, in_local, &n)
	case ^ast.Proc_Type:
		kind = "proc_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.params, alpha, in_local, &n)
		emit_child(eng, &b, e.results, alpha, in_local, &n)
	case ^ast.Pointer_Type:
		kind = "pointer_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.elem, alpha, in_local, &n)
	case ^ast.Multi_Pointer_Type:
		kind = "multi_pointer_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.elem, alpha, in_local, &n)
	case ^ast.Array_Type:
		kind = "array_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.len, alpha, in_local, &n)
		emit_child(eng, &b, e.elem, alpha, in_local, &n)
	case ^ast.Dynamic_Array_Type:
		kind = "dyn_array_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.elem, alpha, in_local, &n)
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		kind = "fixed_dyn_array_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.capacity, alpha, in_local, &n)
		emit_child(eng, &b, e.elem, alpha, in_local, &n)
	case ^ast.Struct_Type:
		kind = "struct_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.poly_params, alpha, in_local, &n)
		emit_child(eng, &b, e.fields, alpha, in_local, &n)
	case ^ast.Union_Type:
		kind = "union_type"
		hb_str(&b, kind)
		emit_exprs(eng, &b, e.variants, alpha, in_local, &n)
	case ^ast.Enum_Type:
		kind = "enum_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.base_type, alpha, in_local, &n)
		emit_exprs(eng, &b, e.fields, alpha, in_local, &n)
	case ^ast.Bit_Set_Type:
		kind = "bit_set_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.elem, alpha, in_local, &n)
		emit_child(eng, &b, e.underlying, alpha, in_local, &n)
	case ^ast.Map_Type:
		kind = "map_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.key, alpha, in_local, &n)
		emit_child(eng, &b, e.value, alpha, in_local, &n)
	case ^ast.Relative_Type:
		kind = "relative_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.tag, alpha, in_local, &n)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
	case ^ast.Matrix_Type:
		kind = "matrix_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.row_count, alpha, in_local, &n)
		emit_child(eng, &b, e.column_count, alpha, in_local, &n)
		emit_child(eng, &b, e.elem, alpha, in_local, &n)
	case ^ast.Bit_Field_Type:
		kind = "bit_field_type"
		hb_str(&b, kind)
		emit_child(eng, &b, e.backing_type, alpha, in_local, &n)
		hb_u32(&b, u32(len(e.fields)))
		for f in e.fields {
			emit_child(eng, &b, f, alpha, in_local, &n)
		}
	case ^ast.Bit_Field_Field:
		kind = "bit_field_field"
		hb_str(&b, kind)
		emit_child(eng, &b, e.name, alpha, in_local, &n)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
		emit_child(eng, &b, e.bit_size, alpha, in_local, &n)
	case ^ast.Bad_Expr:
		kind = "bad_expr"
		hb_str(&b, kind)
	case ^ast.Bad_Stmt:
		kind = "bad_stmt"
		hb_str(&b, kind)
	case ^ast.Bad_Decl:
		kind = "bad_decl"
		hb_str(&b, kind)
	case ^ast.Empty_Stmt:
		kind = "empty_stmt"
		hb_str(&b, kind)
	case ^ast.Expr_Stmt:
		kind = "expr_stmt"
		hb_str(&b, kind)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
	case ^ast.Tag_Stmt:
		kind = "tag_stmt"
		hb_str(&b, kind)
		hb_str(&b, e.name)
		emit_child(eng, &b, e.stmt, alpha, in_local, &n)
	case ^ast.Assign_Stmt:
		kind = "assign"
		hb_str(&b, kind)
		hb_str(&b, e.op.text)
		emit_exprs(eng, &b, e.lhs, alpha, in_local, &n)
		emit_exprs(eng, &b, e.rhs, alpha, in_local, &n)
	case ^ast.Block_Stmt:
		kind = "block"
		hb_str(&b, kind)
		// A block opens a scope: local bindings inside push onto the frame and pop at
		// block close, so a name does not leak to a sibling block.
		base := len(alpha)
		emit_stmts(eng, &b, e.stmts, alpha, true, &n)
		resize(alpha, base)
	case ^ast.If_Stmt:
		kind = "if"
		hb_str(&b, kind)
		base := len(alpha)
		emit_child(eng, &b, e.init, alpha, in_local, &n)
		emit_child(eng, &b, e.cond, alpha, in_local, &n)
		emit_child(eng, &b, e.body, alpha, in_local, &n)
		emit_child(eng, &b, e.else_stmt, alpha, in_local, &n)
		resize(alpha, base)
	case ^ast.When_Stmt:
		kind = "when"
		hb_str(&b, kind)
		emit_child(eng, &b, e.cond, alpha, in_local, &n)
		emit_child(eng, &b, e.body, alpha, in_local, &n)
		emit_child(eng, &b, e.else_stmt, alpha, in_local, &n)
	case ^ast.Return_Stmt:
		kind = "return"
		hb_str(&b, kind)
		emit_exprs(eng, &b, e.results, alpha, in_local, &n)
	case ^ast.Defer_Stmt:
		kind = "defer"
		hb_str(&b, kind)
		emit_child(eng, &b, e.stmt, alpha, in_local, &n)
	case ^ast.For_Stmt:
		kind = "for"
		hb_str(&b, kind)
		base := len(alpha)
		emit_child(eng, &b, e.init, alpha, in_local, &n)
		emit_child(eng, &b, e.cond, alpha, in_local, &n)
		emit_child(eng, &b, e.post, alpha, in_local, &n)
		emit_child(eng, &b, e.body, alpha, in_local, &n)
		resize(alpha, base)
	case ^ast.Range_Stmt:
		kind = "range"
		hb_str(&b, kind)
		// The iterated expression is in scope before the loop vars bind; the vars bind
		// for the body only.
		base := len(alpha)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		push_bind_idents(alpha, e.vals, &n)
		emit_child(eng, &b, e.body, alpha, in_local, &n)
		resize(alpha, base)
	case ^ast.Inline_Range_Stmt:
		kind = "inline_range"
		hb_str(&b, kind)
		base := len(alpha)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		push_bind_ident(alpha, e.val0, &n)
		push_bind_ident(alpha, e.val1, &n)
		emit_child(eng, &b, e.body, alpha, in_local, &n)
		resize(alpha, base)
	case ^ast.Case_Clause:
		kind = "case"
		hb_str(&b, kind)
		emit_exprs(eng, &b, e.list, alpha, in_local, &n)
		base := len(alpha)
		emit_stmts(eng, &b, e.body, alpha, in_local, &n)
		resize(alpha, base)
	case ^ast.Switch_Stmt:
		kind = "switch"
		hb_str(&b, kind)
		base := len(alpha)
		emit_child(eng, &b, e.init, alpha, in_local, &n)
		emit_child(eng, &b, e.cond, alpha, in_local, &n)
		emit_child(eng, &b, e.body, alpha, in_local, &n)
		resize(alpha, base)
	case ^ast.Type_Switch_Stmt:
		kind = "type_switch"
		hb_str(&b, kind)
		base := len(alpha)
		emit_child(eng, &b, e.tag, alpha, in_local, &n)
		emit_child(eng, &b, e.expr, alpha, in_local, &n)
		emit_child(eng, &b, e.body, alpha, in_local, &n)
		resize(alpha, base)
	case ^ast.Branch_Stmt:
		kind = "branch"
		hb_str(&b, kind)
		hb_str(&b, e.tok.text)
		hb_str(&b, e.label != nil ? e.label.name : "")
	case ^ast.Using_Stmt:
		kind = "using"
		hb_str(&b, kind)
		emit_exprs(eng, &b, e.list, alpha, in_local, &n)
	case ^ast.Value_Decl:
		kind = "value_decl"
		hb_str(&b, kind)
		mut: u8 = 0
		if e.is_mutable {
			mut = 1
		}
		strings.write_byte(&b, mut)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
		// Initializers are canonicalized BEFORE the names become visible (a binding
		// cannot reference itself), mirroring funpack's Let_Node order.
		emit_exprs(eng, &b, e.values, alpha, in_local, &n)
		hb_value_names(eng, &b, e.names, alpha, in_local, &n)
	case ^ast.Package_Decl:
		kind = "pkg_decl"
		hb_str(&b, kind)
	case ^ast.Import_Decl:
		kind = "import"
		hb_str(&b, kind)
		hb_str(&b, e.relpath.text)
	case ^ast.Foreign_Block_Decl:
		kind = "foreign_block"
		hb_str(&b, kind)
		emit_child(eng, &b, e.foreign_library, alpha, in_local, &n)
		emit_child(eng, &b, e.body, alpha, in_local, &n)
	case ^ast.Foreign_Import_Decl:
		kind = "foreign_import"
		hb_str(&b, kind)
		hb_str(&b, e.collection_name)
		emit_exprs(eng, &b, e.fullpaths, alpha, in_local, &n)
	case ^ast.Attribute:
		kind = "attribute"
		hb_str(&b, kind)
		emit_exprs(eng, &b, e.elems, alpha, in_local, &n)
	case ^ast.Field:
		kind = "field"
		hb_str(&b, kind)
		// In a struct/result list a field name is a structural selector, kept verbatim
		// — the binding-list path (emit_signature) handles param names separately.
		hb_field_names(&b, e.names)
		emit_child(eng, &b, e.type, alpha, in_local, &n)
		emit_child(eng, &b, e.default_value, alpha, in_local, &n)
	case ^ast.Field_List:
		kind = "field_list"
		hb_str(&b, kind)
		hb_u32(&b, u32(len(e.list)))
		for f in e.list {
			emit_child(eng, &b, f, alpha, in_local, &n)
		}
	case ^ast.Comment_Group:
		kind = "comment"
		hb_str(&b, kind)
	case ^ast.File:
		kind = "file"
		hb_str(&b, kind)
	case ^ast.Package:
		kind = "package"
		hb_str(&b, kind)
	case nil:
		hb_str(&b, kind)
	}

	canon = strings.to_string(b)
	if n >= eng.opts.min_nodes {
		append(
			&eng.records,
			Subtree_Record {
				hash = hash.fnv64a(transmute([]byte)canon),
				canon = canon,
				node_count = n,
				kind = kind,
				path = eng.cur_path,
				is_test = eng.cur_is_test,
				line_start = node.pos.line,
				line_end = node.end.line,
			},
		)
	}
	return
}

// emit_child folds one optional child into the parent buffer: a one-byte presence
// marker (so a nil and a present child can never canonicalize the same), then the
// child's length-prefixed canonical bytes when present. The child's node count
// accumulates into `count`. This is the bottom-up fold — a parent embeds its
// children's full canonical FORMS, so byte-equal parents are structurally equal all
// the way down (no digest stands in for a child, so no child collision can forge a
// parent match).
@(private = "file")
emit_child :: proc(
	eng: ^Dup_Engine,
	b: ^strings.Builder,
	child: ^ast.Node,
	alpha: ^[dynamic]string,
	in_local: bool,
	count: ^int,
) {
	if child == nil {
		strings.write_byte(b, 0)
		return
	}
	strings.write_byte(b, 1)
	cc, cn := dup_canon(eng, child, alpha, in_local)
	// Length-prefix the child canon so the serialization stays injective: a
	// variable-length child can never run into the next sibling's bytes.
	hb_u32(b, u32(len(cc)))
	strings.write_string(b, cc)
	count^ += cn
}

// emit_exprs folds an expression list: a length prefix (the arity is structural) then
// each element via emit_child.
@(private = "file")
emit_exprs :: proc(
	eng: ^Dup_Engine,
	b: ^strings.Builder,
	list: []^ast.Expr,
	alpha: ^[dynamic]string,
	in_local: bool,
	count: ^int,
) {
	hb_u32(b, u32(len(list)))
	for x in list {
		emit_child(eng, b, x, alpha, in_local, count)
	}
}

// emit_stmts folds a statement list: a length prefix then each statement via
// emit_child.
@(private = "file")
emit_stmts :: proc(
	eng: ^Dup_Engine,
	b: ^strings.Builder,
	list: []^ast.Stmt,
	alpha: ^[dynamic]string,
	in_local: bool,
	count: ^int,
) {
	hb_u32(b, u32(len(list)))
	for x in list {
		emit_child(eng, b, x, alpha, in_local, count)
	}
}

// emit_signature folds a proc parameter or result list, BINDING each field's names
// into the alpha frame as positional slots. The field arity and each field's type are
// structural (written into the buffer); the names are renamed away (pushed, not
// written) so two procs with renamed params canonicalize identically. A named return
// binds the same way, so the body can reference it by slot.
@(private = "file")
emit_signature :: proc(
	eng: ^Dup_Engine,
	b: ^strings.Builder,
	fl: ^ast.Field_List,
	alpha: ^[dynamic]string,
	count: ^int,
) {
	if fl == nil {
		strings.write_byte(b, 0)
		return
	}
	strings.write_byte(b, 1)
	hb_u32(b, u32(len(fl.list)))
	for field in fl.list {
		emit_child(eng, b, field.type, alpha, false, count)
		emit_child(eng, b, field.default_value, alpha, false, count)
		hb_u32(b, u32(len(field.names)))
		for nm in field.names {
			if id, ok := nm.derived.(^ast.Ident); ok {
				append(alpha, id.name)
				count^ += 1
			} else {
				emit_child(eng, b, nm, alpha, false, count)
			}
		}
	}
}

// hb_value_names handles a value declaration's names. A LOCAL binding pushes its
// names as positional slots (renamed away — not written), so a renamed local
// canonicalizes identically. A PACKAGE-level name keeps its spelling (written
// verbatim), so two differently-named top-level declarations do not collide at the
// declaration node — their initializers (e.g. proc literals) collide instead, name
// excluded.
@(private = "file")
hb_value_names :: proc(
	eng: ^Dup_Engine,
	b: ^strings.Builder,
	names: []^ast.Expr,
	alpha: ^[dynamic]string,
	in_local: bool,
	count: ^int,
) {
	if in_local {
		for nm in names {
			if id, ok := nm.derived.(^ast.Ident); ok {
				append(alpha, id.name)
				count^ += 1
			} else {
				emit_child(eng, b, nm, alpha, in_local, count)
			}
		}
		return
	}
	hb_u32(b, u32(len(names)))
	for nm in names {
		if id, ok := nm.derived.(^ast.Ident); ok {
			strings.write_byte(b, 1)
			hb_str(b, id.name)
		} else {
			strings.write_byte(b, 2)
			emit_child(eng, b, nm, alpha, in_local, count)
		}
	}
}

// hb_field_key folds a composite-literal field key: an Ident key is a structural
// field selector kept verbatim (`{x = 1}` differs from `{y = 1}`); any other key
// form (an index, a nested expression) folds as a child.
@(private = "file")
hb_field_key :: proc(
	eng: ^Dup_Engine,
	b: ^strings.Builder,
	field: ^ast.Expr,
	alpha: ^[dynamic]string,
	in_local: bool,
	count: ^int,
) {
	if field == nil {
		strings.write_byte(b, 0)
		return
	}
	if id, ok := field.derived.(^ast.Ident); ok {
		strings.write_byte(b, 1)
		hb_str(b, id.name)
		return
	}
	strings.write_byte(b, 2)
	emit_child(eng, b, field, alpha, in_local, count)
}

// hb_field_names writes a struct/result field's names verbatim (structural
// selectors), as a length-prefixed list. Non-Ident names canonicalize as the empty
// spelling — a degenerate shape this path never needs to distinguish.
@(private = "file")
hb_field_names :: proc(b: ^strings.Builder, names: []^ast.Expr) {
	hb_u32(b, u32(len(names)))
	for nm in names {
		if id, ok := nm.derived.(^ast.Ident); ok {
			hb_str(b, id.name)
		} else {
			hb_str(b, "")
		}
	}
}

// push_bind_idents binds a list of loop variables into the alpha frame (range
// `for k, v in m`). Each Ident var becomes a positional slot for the body, renamed
// away.
@(private = "file")
push_bind_idents :: proc(alpha: ^[dynamic]string, vals: []^ast.Expr, count: ^int) {
	for v in vals {
		push_bind_ident(alpha, v, count)
	}
}

// push_bind_ident binds one optional loop variable into the alpha frame.
@(private = "file")
push_bind_ident :: proc(alpha: ^[dynamic]string, val: ^ast.Expr, count: ^int) {
	if val == nil {
		return
	}
	if id, ok := val.derived.(^ast.Ident); ok {
		append(alpha, id.name)
		count^ += 1
	}
}

// hb_name resolves a name reference to its canonical form: a BOUND name (found by
// scanning the alpha frame from the top, so the innermost shadow wins) emits its
// positional slot index; a FREE name keeps its spelling. The `#b`/`#f` discriminant
// keeps a bound slot and a free spelling in disjoint encodings. Mirrors funpack's
// canon_name.
@(private = "file")
hb_name :: proc(b: ^strings.Builder, name: string, alpha: ^[dynamic]string) {
	for i := len(alpha) - 1; i >= 0; i -= 1 {
		if alpha[i] == name {
			strings.write_string(b, "#b")
			hb_u32(b, u32(i))
			return
		}
	}
	strings.write_string(b, "#f")
	hb_str(b, name)
}

// hb_literal folds a literal's text. By default the verbatim text is kept (two
// literals of different value are structurally distinct); under fold_literals every
// literal collapses to one token, surfacing clones that differ only in their
// constants.
@(private = "file")
hb_literal :: proc(b: ^strings.Builder, text: string, fold: bool) {
	if fold {
		strings.write_string(b, "#*")
		return
	}
	strings.write_string(b, "#=")
	hb_str(b, text)
}

// hb_str writes a length-prefixed string into the hash buffer. The length prefix
// makes the serialization injective: two adjacent variable-length spellings can never
// run together into a third reading, so distinct structures never share a buffer.
@(private = "file")
hb_str :: proc(b: ^strings.Builder, s: string) {
	hb_u32(b, u32(len(s)))
	strings.write_string(b, s)
}

// hb_u32 writes a fixed-width 4-byte little-endian count into the hash buffer.
@(private = "file")
hb_u32 :: proc(b: ^strings.Builder, x: u32) {
	v := x
	for _ in 0 ..< 4 {
		strings.write_byte(b, u8(v))
		v >>= 8
	}
}

// cluster_and_suppress turns the flat record set into the final clone classes:
// bucket records by their fnv64a digest, PARTITION each bucket into canon-equivalence
// classes (exact byte-equality of the canonical form — the digest is only a bucket
// index, so a 64-bit collision splits back into separate classes instead of merging),
// keep partitions with >= 2 members, sort deterministically, drop classes wholly
// contained in a larger same-instance-set class (maximal-only), and materialize the
// survivors in the result allocator. Map iteration order never reaches the output —
// the explicit sort fixes the ordering. Package-private (not file-private) so the
// collision-trust regression can drive it with synthetic same-hash/different-canon
// records.
@(private)
cluster_and_suppress :: proc(
	records: []Subtree_Record,
	allocator: runtime.Allocator,
) -> []Clone_Class {
	buckets := make(map[u64][dynamic]int, 64, context.temp_allocator)
	for rec, idx in records {
		if _, seen := buckets[rec.hash]; !seen {
			buckets[rec.hash] = make([dynamic]int, 0, 2, context.temp_allocator)
		}
		arr := &buckets[rec.hash]
		append(arr, idx)
	}

	candidates := make([dynamic]Clone_Class, 0, 16, context.temp_allocator)
	for _, idxs in buckets {
		if len(idxs) < 2 {
			continue
		}
		// One digest bucket may hold more than one true clone class: two
		// structurally-distinct subtrees can share a 64-bit fnv64a digest.
		// Partition the bucket by exact canonical-byte equality so each emitted
		// class is one genuine structural form; a lone member left over by a
		// collision is no clone and is dropped.
		grouped := make([]bool, len(idxs), context.temp_allocator)
		for a in 0 ..< len(idxs) {
			if grouped[a] {
				continue
			}
			anchor := records[idxs[a]]
			members := make([dynamic]int, 0, len(idxs), context.temp_allocator)
			append(&members, idxs[a])
			grouped[a] = true
			for c in (a + 1) ..< len(idxs) {
				if grouped[c] {
					continue
				}
				if records[idxs[c]].canon == anchor.canon {
					append(&members, idxs[c])
					grouped[c] = true
				}
			}
			if len(members) < 2 {
				continue
			}
			insts := make([]Clone_Instance, len(members), context.temp_allocator)
			for ri, k in members {
				r := records[ri]
				insts[k] = Clone_Instance {
					path       = r.path,
					is_test    = r.is_test,
					line_start = r.line_start,
					line_end   = r.line_end,
				}
			}
			slice.sort_by(insts, instance_less)
			// Every member shares anchor.canon, so node_count and kind are
			// identical across the partition — anchor's are the class's.
			append(
				&candidates,
				Clone_Class {
					hash = anchor.hash,
					node_count = anchor.node_count,
					kind = anchor.kind,
					instances = insts,
				},
			)
		}
	}

	slice.sort_by(candidates[:], class_less)

	out := make([dynamic]Clone_Class, 0, len(candidates), allocator)
	for i in 0 ..< len(candidates) {
		if class_is_contained(candidates[:], i) {
			continue
		}
		c := candidates[i]
		kept := make([]Clone_Instance, len(c.instances), allocator)
		copy(kept, c.instances)
		append(
			&out,
			Clone_Class {
				hash = c.hash,
				node_count = c.node_count,
				kind = c.kind,
				instances = kept,
			},
		)
	}
	return out[:]
}

// class_is_contained reports whether candidates[i] is a fragment of a larger clone:
// some OTHER class is strictly larger, carries the SAME number of instances, and
// contains every one of candidates[i]'s instances in a distinct instance of its own.
// Such a class adds no signal — it is just a sub-span repeated once inside each
// larger clone — so maximal-only suppression drops it. The test is order-independent
// (a pure existential over all classes), so the result is deterministic.
@(private = "file")
class_is_contained :: proc(classes: []Clone_Class, i: int) -> bool {
	s := classes[i]
	for j in 0 ..< len(classes) {
		if j == i {
			continue
		}
		l := classes[j]
		if l.node_count <= s.node_count {
			continue
		}
		if len(l.instances) != len(s.instances) {
			continue
		}
		if instances_contained(s.instances, l.instances) {
			return true
		}
	}
	return false
}

// instances_contained reports whether every instance in `inner` maps one-to-one to a
// DISTINCT instance in `outer` that spatially contains it (same file, line span
// nested). Span containment within one file is ancestry — AST node spans nest — so a
// contained inner instance is a proper subtree of its matched outer instance. The
// match is greedy: exact for the common case of disjoint spans, and conservative
// otherwise (a missed match leaves the inner class un-suppressed, the safe default
// for a lint that would rather over-report than hide a clone).
@(private = "file")
instances_contained :: proc(inner, outer: []Clone_Instance) -> bool {
	if len(inner) != len(outer) {
		return false
	}
	used := make([]bool, len(outer), context.temp_allocator)
	for si in inner {
		matched := false
		for oj, k in outer {
			if used[k] {
				continue
			}
			if instance_spans(oj, si) {
				used[k] = true
				matched = true
				break
			}
		}
		if !matched {
			return false
		}
	}
	return true
}

// instance_spans reports whether `outer` spatially contains `inner`: same file, with
// outer's line span enclosing inner's.
@(private = "file")
instance_spans :: proc(outer, inner: Clone_Instance) -> bool {
	return(
		outer.path == inner.path &&
		outer.line_start <= inner.line_start &&
		outer.line_end >= inner.line_end \
	)
}

// span_less is the total order on source spans — (path, line_start, line_end) ascending.
// Both clone tiers tie-break their report ordering by location, so the comparison lives
// here once (package-visible) and every surface — clone instances, near-miss sites —
// delegates, keeping the ordering identical and un-duplicated across them.
span_less :: proc(a_path: string, a_start, a_end: int, b_path: string, b_start, b_end: int) -> bool {
	if a_path != b_path {
		return a_path < b_path
	}
	if a_start != b_start {
		return a_start < b_start
	}
	return a_end < b_end
}

// instance_less orders clone instances within a class by span. Deterministic, and
// human-friendly for a report.
@(private = "file")
instance_less :: proc(a, b: Clone_Instance) -> bool {
	return span_less(a.path, a.line_start, a.line_end, b.path, b.line_start, b.line_end)
}

// class_less is the total order on clone classes: by hash, then by first-instance
// span. The hash is a bucket index, NOT a unique class id — a 64-bit fnv64a collision
// can seat two distinct-canon classes at one hash — so the first-instance-span
// tie-break is load-bearing: it keeps the order a deterministic total order even when
// two classes share a hash.
@(private = "file")
class_less :: proc(a, b: Clone_Class) -> bool {
	if a.hash != b.hash {
		return a.hash < b.hash
	}
	ai := a.instances[0]
	bi := b.instances[0]
	if ai.path != bi.path {
		return ai.path < bi.path
	}
	if ai.line_start != bi.line_start {
		return ai.line_start < bi.line_start
	}
	return ai.line_end < bi.line_end
}
