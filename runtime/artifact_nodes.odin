package funpack_runtime

import "core:strconv"
import "core:strings"

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
	Let_Tuple,
	If_Return,
	If_Expr,
	Return,
	Stub,
	All,
	Block,
}

Node :: struct {
	kind:     Node_Kind,
	fields:   []string,
	children: []Node,
}

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
	case "let_tuple":
		return .Let_Tuple, true
	case "if_return":
		return .If_Return, true
	case "if_expr":
		return .If_Expr, true
	case "return":
		return .Return, true
	case "stub":
		return .Stub, true
	case "all":
		return .All, true
	case "block":
		return .Block, true
	}
	return .Int, false
}

node_child_count :: proc(line: string) -> (count: int, ok: bool) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 2 || fields[0] != "node" {
		return 0, false
	}
	if fields[1] == "arm" {
		if len(fields) >= 3 && fields[2] == "tuple" {
			return strconv.parse_int(fields[len(fields) - 1])
		}
		return 0, true
	}
	if fields[1] == "string" {
		_, child_count, str_ok := split_string_node(line)
		return child_count, str_ok
	}
	return strconv.parse_int(fields[len(fields) - 1])
}

node_scalar_fields :: proc(line: string, allocator := context.allocator) -> []string {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 2 {
		return nil
	}
	if fields[1] == "arm" {
		return slice_clone(fields[2:], allocator)
	}
	if fields[1] == "string" {
		token, _, str_ok := split_string_node(line)
		if !str_ok {
			return nil
		}
		out := make([]string, 1, allocator)
		out[0] = strings.clone(token, allocator)
		return out
	}
	if len(fields) <= 3 {
		return nil
	}
	return slice_clone(fields[2:len(fields) - 1], allocator)
}

split_string_node :: proc(line: string) -> (token: string, count: int, ok: bool) {
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

slice_clone :: proc(src: []string, allocator := context.allocator) -> []string {
	out := make([]string, len(src), allocator)
	for s, i in src {
		out[i] = strings.clone(s, allocator)
	}
	return out
}

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
	if cursor != len(lines) {
		return nil, .Body_Count_Mismatch
	}
	return out[:], .None
}

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

node_line_kind_tag :: proc(line: string) -> string {
	rest := strings.trim_prefix(line, "node ")
	space := strings.index_byte(rest, ' ')
	if space < 0 {
		return rest
	}
	return rest[:space]
}
