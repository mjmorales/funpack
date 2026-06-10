// Serialized checked-AST body reader (docs/artifact-format.md §2.7). Every
// executable body the runtime interprets — each fn body, each behavior step
// body, each const initializer, the bindings() and setup() bodies — is carried
// IN the artifact as a flat pre-order (depth-first, node-then-children) run of
// `node` lines. The runtime rebuilds the tree from this document alone, with
// zero funpack source on its path: the artifact is the whole node graph, so a
// body is never a span reference into source the runtime can never read (§09 §1
// — the interpreter is the canonical semantics).
//
// The encoding is TOTAL and COUNT-DRIVEN: every node line ends in `child_count`,
// and a reader consumes a node then exactly that many child subtrees, never
// looking ahead past a node's own declared children. The ONE exception is a
// SCALAR-pattern `arm`, which always has 0 children (its trailing field is a
// variable-length binder list), so its child count is fixed by kind, not read as
// a trailing token. A `tuple` arm (schema v2) is the lone arm kind that DOES
// carry children — its positional sub-pattern arms — so it ends in a trailing
// `child_count` read the generic way.
package funpack_runtime

import "core:strconv"
import "core:strings"

// Node_Kind is the CLOSED checked-AST node-kind set (§2.7). A new kind is a
// schema-version bump (§1). It mirrors the checked surface AST (spec §02 §5–§6).
Node_Kind :: enum {
	Int,
	Fixed,
	Name,
	String,
	Field,
	Call,
	Variant,
	Record,
	Recfield,
	With,
	List,
	Tuple,
	Lambda,
	Unary,
	Binary,
	Match,
	Arm,
	Let,
	If_Return,
	Return,
	// Stub is the §05 §2 typed hole standing as a holed body's sole statement
	// subtree (schema v7): `node stub fallback 1` carries the approximation
	// expression as its one child, `node stub bare 0` carries nothing and is
	// the defined fail-closed no-value outcome at evaluation time.
	Stub,
	// All is the §08 §3 world read `all[T]` (schema v10): `node all THING 0`,
	// a leaf carrying the read table's thing type name — it evaluates to that
	// thing's rows in stable Id order, the only world read a query body holds.
	All,
}

// Node is one interpreted body node: its kind, its decoded scalar fields kept as
// raw tokens (positionally typed per §2.7 — the interpreter decodes a
// `fixed`'s token through the kernel when it evaluates), and its children in
// evaluation/source order. The tree is owned by the loader's allocator.
Node :: struct {
	kind:     Node_Kind,
	fields:   []string, // the kind's scalar tokens, in documented order
	children: []Node,
}

// node_kind_from_tag maps a node-line KIND tag to its closed Node_Kind. An
// unknown tag is a schema mismatch — refused, never guessed.
node_kind_from_tag :: proc(tag: string) -> (kind: Node_Kind, ok: bool) {
	switch tag {
	case "int":
		return .Int, true
	case "fixed":
		return .Fixed, true
	case "name":
		return .Name, true
	case "string":
		return .String, true
	case "field":
		return .Field, true
	case "call":
		return .Call, true
	case "variant":
		return .Variant, true
	case "record":
		return .Record, true
	case "recfield":
		return .Recfield, true
	case "with":
		return .With, true
	case "list":
		return .List, true
	case "tuple":
		// A `tuple` node is count-driven like `list`: `node tuple <len>` with <len>
		// element subtrees (spec §02; §04 §1 — a draw's (value, next_rng) pair). The
		// trailing token IS the child count, so node_child_count reads it the generic
		// way; no special handling beyond this tag mapping.
		return .Tuple, true
	case "lambda":
		return .Lambda, true
	case "unary":
		return .Unary, true
	case "binary":
		return .Binary, true
	case "match":
		return .Match, true
	case "arm":
		return .Arm, true
	case "let":
		return .Let, true
	case "if_return":
		return .If_Return, true
	case "return":
		return .Return, true
	case "stub":
		// A `stub` node is count-driven the generic way: its FORM scalar
		// (`bare`/`fallback`) precedes the trailing child count (0 for bare, 1 —
		// the approximation expression — for fallback), so no special handling
		// beyond this tag mapping (§2.7, schema v7).
		return .Stub, true
	case "all":
		// An `all` node is a leaf read the generic way: its THING scalar
		// precedes the trailing child count (always 0), so no special handling
		// beyond this tag mapping (§2.7, schema v10).
		return .All, true
	}
	return .Int, false
}

// node_child_count reads how many child subtrees a node line declares. Every
// node ends in `child_count` (its last token) EXCEPT a SCALAR-pattern `arm`,
// which is fixed at 0 by kind because its trailing field is a variable-length
// binder list, not a count (§2.7). A `tuple` arm (schema v2) is the one arm kind
// that carries children — its positional sub-pattern arms — so its line
// `node arm tuple <child_count>` ends in a trailing count read the generic way.
// This is the single primitive the body forest reader is built on, and it
// mirrors funpack's emitter exactly (funpack/artifact_format.odin
// node_child_count).
//
// A `string` node's scalar is a length-prefixed String (§2.4) that may contain
// raw spaces, so its line is NOT whitespace-tokenizable: the count is the last
// token AFTER the length-explicit String, found by reading past the byte count.
node_child_count :: proc(line: string) -> (count: int, ok: bool) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 2 || fields[0] != "node" {
		return 0, false
	}
	if fields[1] == "arm" {
		// A `tuple` arm carries its sub-pattern arms as children (the trailing
		// count); every scalar-pattern arm is fixed at 0 (its trailing field is
		// the binder list). The pattern token is fields[2] (§2.7 v2).
		if len(fields) >= 3 && fields[2] == "tuple" {
			return strconv.parse_int(fields[len(fields) - 1])
		}
		return 0, true // scalar arm: always 0 children, regardless of trailing binders
	}
	if fields[1] == "string" {
		_, child_count, str_ok := split_string_node(line)
		return child_count, str_ok
	}
	return strconv.parse_int(fields[len(fields) - 1])
}

// node_scalar_fields returns a node line's scalar field tokens — everything
// between the kind tag and the trailing `child_count` — in documented order.
// For `arm`, the binder list is variable-length and there is no trailing count,
// so all tokens after the kind tag are scalar fields (the binder names follow
// the fixed `pat type case binder_count` prefix). Tokens stay raw: a field is
// decoded by its position (§2.7), which the interpreter does at evaluation time.
node_scalar_fields :: proc(line: string, allocator := context.allocator) -> []string {
	fields := strings.fields(line, context.temp_allocator)
	// fields[0] == "node", fields[1] == KIND tag.
	if len(fields) < 2 {
		return nil
	}
	if fields[1] == "arm" {
		// arm carries no trailing child_count — every token after the tag is a
		// scalar field (pat, type, case, binder_count, then the binder names).
		return slice_clone(fields[2:], allocator)
	}
	if fields[1] == "string" {
		// The single scalar is the length-prefixed String token, read by byte
		// count so embedded spaces never split it (§2.4).
		token, _, str_ok := split_string_node(line)
		if !str_ok {
			return nil
		}
		out := make([]string, 1, allocator)
		out[0] = strings.clone(token, allocator)
		return out
	}
	// A non-arm node's last token is child_count; scalars are between the tag
	// and that count. `call`, `if_return`, `return` have no scalar fields, so
	// the slice is empty when len == 3 (node KIND child_count).
	if len(fields) <= 3 {
		return nil
	}
	return slice_clone(fields[2:len(fields) - 1], allocator)
}

// split_string_node decodes a `node string Lk:<k bytes> child_count` line by the
// String's explicit byte length (§2.4), returning the length-prefixed token, the
// child count, and ok. It never delimiter-scans the String body, so an embedded
// space, tab, or any other byte inside the string cannot break the parse.
split_string_node :: proc(line: string) -> (token: string, count: int, ok: bool) {
	// Past the `node string ` prefix lies `Lk:<k bytes> child_count`.
	rest := strings.trim_prefix(line, "node string ")
	if len(rest) < 2 || rest[0] != 'L' {
		return "", 0, false
	}
	colon := strings.index_byte(rest, ':')
	if colon < 0 {
		return "", 0, false
	}
	n, n_ok := strconv.parse_int(rest[1:colon])
	if !n_ok {
		return "", 0, false
	}
	// The token is `Lk:` plus exactly n raw body bytes; the child count follows
	// after a single space.
	token_end := colon + 1 + n
	if token_end > len(rest) {
		return "", 0, false
	}
	token = rest[:token_end]
	tail := rest[token_end:]
	tail = strings.trim_space(tail)
	c, c_ok := strconv.parse_int(tail)
	if !c_ok {
		return "", 0, false
	}
	return token, c, true
}

// slice_clone copies a []string into freshly-allocated storage so the returned
// fields outlive the temp_allocator fields() call.
slice_clone :: proc(src: []string, allocator := context.allocator) -> []string {
	out := make([]string, len(src), allocator)
	for s, i in src {
		out[i] = strings.clone(s, allocator)
	}
	return out
}

// parse_node_forest reads a body's flat pre-order `node` run into a forest of
// `body_count` statement subtrees (§2.7). It consumes exactly each node's
// declared children, asserts the run yields exactly `body_count` top-level
// subtrees with no leftover line (an over- or under-shaped body is refused), and
// returns the statements in source order.
parse_node_forest :: proc(
	lines: []string,
	body_count: int,
	allocator := context.allocator,
) -> (
	statements: []Node,
	err: Artifact_Error,
) {
	out := make([dynamic]Node, 0, body_count, allocator)
	cursor := 0
	for _ in 0 ..< body_count {
		node, next, node_err := parse_node(lines, cursor, allocator)
		if node_err != .None {
			return nil, node_err
		}
		append(&out, node)
		cursor = next
	}
	// Every body line must be consumed by exactly body_count statements — a
	// leftover trailing node is an over-shaped body (§2.7).
	if cursor != len(lines) {
		return nil, .Body_Count_Mismatch
	}
	return out[:], .None
}

// parse_node consumes one node subtree starting at `lines[start]`: the node, its
// scalar fields, then recursively exactly `child_count` child subtrees in
// documented order. It never looks ahead past its own declared children, so the
// recursion is total (§2.7). Returns the node and the index just past its
// subtree.
parse_node :: proc(
	lines: []string,
	start: int,
	allocator := context.allocator,
) -> (
	node: Node,
	next: int,
	err: Artifact_Error,
) {
	if start >= len(lines) {
		// The forest declared more statements/children than the run carries —
		// an under-shaped body that overruns the slice.
		return {}, start, .Body_Count_Mismatch
	}
	line := lines[start]
	tag := node_line_kind_tag(line)
	kind, kind_ok := node_kind_from_tag(tag)
	if !kind_ok {
		return {}, start, .Bad_Body_Node
	}
	child_count, count_ok := node_child_count(line)
	if !count_ok {
		return {}, start, .Bad_Body_Node
	}

	scalars := node_scalar_fields(line, allocator)
	children := make([dynamic]Node, 0, child_count, allocator)
	cursor := start + 1
	for _ in 0 ..< child_count {
		child, after, child_err := parse_node(lines, cursor, allocator)
		if child_err != .None {
			return {}, cursor, child_err
		}
		append(&children, child)
		cursor = after
	}
	return Node{kind = kind, fields = scalars, children = children[:]}, cursor, .None
}

// node_line_kind_tag returns the KIND tag of a `node KIND …` line (the token
// after the `node` keyword).
node_line_kind_tag :: proc(line: string) -> string {
	rest := strings.trim_prefix(line, "node ")
	space := strings.index_byte(rest, ' ')
	if space < 0 {
		return rest
	}
	return rest[:space]
}
