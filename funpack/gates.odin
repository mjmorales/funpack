package funpack

import "core:hash"
import "core:strings"

MAX_CYCLOMATIC :: 10
MAX_NESTING_DEPTH :: 3
MAX_FN_STATEMENTS :: 40
MAX_PARAM_ARITY :: 5

MAX_DUPLICATE_UNITS :: 1

Gate_Error :: enum {
	None,
	Cyclomatic_Exceeded,
	Nesting_Exceeded,
	Fn_Size_Exceeded,
	Arity_Exceeded,
	Non_Exhaustive_Match,
	Duplicate_Declaration,
	Query_Missing_Index,
	Query_Unused_Index,
	Probe_Wrong_Placement,
}

Gate_Unit :: struct {
	name: string,
	line: int,
	body: []Statement,
	dup_exempt: bool,
}

gate_units :: proc(ast: Ast) -> []Gate_Unit {
	units := make([dynamic]Gate_Unit, 0, len(ast.decls), context.temp_allocator)
	for ref in ast.decls {
		#partial switch ref.kind {
		case .Test:
			test := ast.tests[ref.index]
			append(&units, Gate_Unit{name = test.name, line = test.line, body = test.body})
		case .Fn:
			fn := ast.fns[ref.index]
			if fn.is_extern || fn.holed {
				continue
			}
			append(&units, Gate_Unit{name = fn.name, line = fn.line, body = fn.body, dup_exempt = is_const_accessor(fn)})
		case .Query:
			query := ast.queries[ref.index]
			append(&units, Gate_Unit{name = query.name, line = query.line, body = query.body})
		case .Behavior:
			behavior := ast.behaviors[ref.index]
			if behavior.step.holed {
				continue
			}
			append(&units, Gate_Unit{name = behavior.name, line = behavior.line, body = behavior.step.body})
		}
	}
	return units[:]
}

is_const_accessor :: proc(fn: Fn_Node) -> bool {
	if len(fn.params) != 0 || len(fn.body) != 1 {
		return false
	}
	ret, is_return := fn.body[0].(Return_Node)
	if !is_return {
		return false
	}
	#partial switch _ in ret.value {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr:
		return true
	}
	return false
}

release_holed_decl :: proc(ast: Ast) -> (declaration: string, holed: bool) {
	for ref in ast.decls {
		switch ref.kind {
		case .Data:
			decl := ast.datas[ref.index]
			if fields_hold_stub(decl.fields) {
				return decl.name, true
			}
		case .Enum:
			decl := ast.enums[ref.index]
			if variants_hold_stub(decl.variants) {
				return decl.name, true
			}
		case .Thing:
			decl := ast.things[ref.index]
			if fields_hold_stub(decl.fields) {
				return decl.name, true
			}
		case .Signal:
			decl := ast.signals[ref.index]
			if fields_hold_stub(decl.fields) {
				return decl.name, true
			}
		case .Fn:
			fn := ast.fns[ref.index]
			if fn_holds_stub(fn) {
				return fn.name, true
			}
		case .Query:
			query := ast.queries[ref.index]
			if body_holds_stub(query.body) {
				return query.name, true
			}
		case .Behavior:
			behavior := ast.behaviors[ref.index]
			if fn_holds_stub(behavior.step) {
				return behavior.name, true
			}
		case .Pipeline:
		case .Let:
			decl := ast.lets[ref.index]
			if expr_holds_stub(decl.value) {
				return decl.name, true
			}
		case .Test:
			decl := ast.tests[ref.index]
			if body_holds_stub(decl.body) {
				return decl.name, true
			}
		case .Extern_Type:
		}
	}
	return "", false
}

fn_holds_stub :: proc(fn: Fn_Node) -> bool {
	if fn.holed {
		return true
	}
	return body_holds_stub(fn.body)
}

body_holds_stub :: proc(body: []Statement) -> bool {
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			if expr_holds_stub(s.value) {
				return true
			}
		case Assert_Node:
			if expr_holds_stub(s.expr) {
				return true
			}
		case Return_Node:
			if expr_holds_stub(s.value) {
				return true
			}
		case If_Node:
			if expr_holds_stub(s.cond) || body_holds_stub(s.body) {
				return true
			}
		}
	}
	return false
}

fields_hold_stub :: proc(fields: []Field_Decl) -> bool {
	for field in fields {
		if field.has_default && expr_holds_stub(field.default) {
			return true
		}
	}
	return false
}

variants_hold_stub :: proc(variants: []Variant_Decl) -> bool {
	for variant in variants {
		if fields_hold_stub(variant.fields) {
			return true
		}
	}
	return false
}

expr_holds_stub :: proc(expr: Expr) -> bool {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
		return false
	case ^Stub_Expr:
		return true
	case ^Call_Expr:
		if expr_holds_stub(e.callee) {
			return true
		}
		for arg in e.args {
			if expr_holds_stub(arg) {
				return true
			}
		}
	case ^Member_Expr:
		return expr_holds_stub(e.receiver)
	case ^Variant_Expr:
		for arg in e.payload {
			if expr_holds_stub(arg) {
				return true
			}
		}
		for field in e.fields {
			if expr_holds_stub(field.value) {
				return true
			}
		}
	case ^Record_Expr:
		for field in e.fields {
			if expr_holds_stub(field.value) {
				return true
			}
		}
	case ^List_Expr:
		for element in e.elements {
			if expr_holds_stub(element) {
				return true
			}
		}
	case ^Lambda_Expr:
		return expr_holds_stub(e.body)
	case ^Unary_Expr:
		return expr_holds_stub(e.operand)
	case ^Binary_Expr:
		return expr_holds_stub(e.lhs) || expr_holds_stub(e.rhs)
	case ^With_Expr:
		if expr_holds_stub(e.base) {
			return true
		}
		for field in e.fields {
			if expr_holds_stub(field.value) {
				return true
			}
		}
	case ^Match_Expr:
		if expr_holds_stub(e.scrutinee) {
			return true
		}
		for arm in e.arms {
			if expr_holds_stub(arm.body) {
				return true
			}
		}
	case ^Tuple_Expr:
		for element in e.elements {
			if expr_holds_stub(element) {
				return true
			}
		}
	case ^If_Expr:
		return expr_holds_stub(e.cond) || expr_holds_stub(e.then_branch) || expr_holds_stub(e.else_branch)
	}
	return false
}

release_debug_decl :: proc(ast: Ast) -> (declaration: string, probed: bool) {
	for ref in ast.decls {
		switch ref.kind {
		case .Data:
			decl := ast.datas[ref.index]
			if len(decl.probes) > 0 || fields_hold_probe(decl.fields) {
				return decl.name, true
			}
		case .Enum:
			decl := ast.enums[ref.index]
			if len(decl.probes) > 0 || variants_hold_probe(decl.variants) {
				return decl.name, true
			}
		case .Thing:
			decl := ast.things[ref.index]
			if len(decl.probes) > 0 || fields_hold_probe(decl.fields) {
				return decl.name, true
			}
		case .Signal:
			decl := ast.signals[ref.index]
			if len(decl.probes) > 0 || fields_hold_probe(decl.fields) {
				return decl.name, true
			}
		case .Fn:
			decl := ast.fns[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Query:
			decl := ast.queries[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Behavior:
			decl := ast.behaviors[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Pipeline:
			decl := ast.pipelines[ref.index]
			if len(decl.probes) > 0 || stages_hold_probe(decl.stages) {
				return decl.name, true
			}
		case .Let:
			decl := ast.lets[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Test:
			decl := ast.tests[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Extern_Type:
			decl := ast.extern_types[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		}
	}
	return "", false
}

fields_hold_probe :: proc(fields: []Field_Decl) -> bool {
	for field in fields {
		if len(field.probes) > 0 {
			return true
		}
	}
	return false
}

variants_hold_probe :: proc(variants: []Variant_Decl) -> bool {
	for variant in variants {
		if fields_hold_probe(variant.fields) {
			return true
		}
	}
	return false
}

stages_hold_probe :: proc(stages: []Pipeline_Stage) -> bool {
	for stage in stages {
		if len(stage.probes) > 0 {
			return true
		}
	}
	return false
}

Nesting_Cause :: enum {
	None,
	Block,
	Expression,
}

Gate_Verdict :: struct {
	err:           Gate_Error,
	declaration:   string,
	line:          int,
	nesting_cause: Nesting_Cause,
}

stage_gates :: proc(ast: Ast) -> Gate_Error {
	return gate_verdict(ast).err
}

gate_verdict :: proc(ast: Ast) -> Gate_Verdict {
	units := gate_units(ast)
	sets := closed_variant_sets(ast)
	for unit in units {
		if len(statements_count(unit.body)) > MAX_FN_STATEMENTS {
			return Gate_Verdict{err = .Fn_Size_Exceeded, declaration = unit.name, line = unit.line}
		}
	}
	for unit in units {
		if err := gate_arity_unit(unit); err != .None {
			return Gate_Verdict{err = err, declaration = unit.name, line = unit.line}
		}
	}
	for unit in units {
		if err := check_cyclomatic(unit); err != .None {
			return Gate_Verdict{err = err, declaration = unit.name, line = unit.line}
		}
		if err, cause := check_nesting(unit); err != .None {
			return Gate_Verdict{err = err, declaration = unit.name, line = unit.line, nesting_cause = cause}
		}
	}
	for unit in units {
		if err := check_match_exhaustiveness_unit(unit, sets); err != .None {
			return Gate_Verdict{err = err, declaration = unit.name, line = unit.line}
		}
	}
	if verdict := check_query_index_gate(ast); verdict.err != .None {
		return verdict
	}
	if verdict := check_probe_placement_gate(ast); verdict.err != .None {
		return verdict
	}
	if err, name, line := gate_duplication(units); err != .None {
		return Gate_Verdict{err = err, declaration = name, line = line}
	}
	return Gate_Verdict{err = .None}
}

statements_count :: proc(body: []Statement) -> []Statement {
	flat := make([dynamic]Statement, 0, len(body), context.temp_allocator)
	for stmt in body {
		append(&flat, stmt)
		if guard, is_if := stmt.(If_Node); is_if {
			inner := statements_count(guard.body)
			for s in inner {
				append(&flat, s)
			}
		}
	}
	return flat[:]
}

gate_arity_unit :: proc(unit: Gate_Unit) -> Gate_Error {
	return arity_walk_body(unit.body)
}

arity_walk_body :: proc(body: []Statement) -> Gate_Error {
	for stmt in body {
		switch s in stmt {
		case Assert_Node:
			if err := arity_walk_expr(s.expr); err != .None {
				return err
			}
		case Let_Node:
			if err := arity_walk_expr(s.value); err != .None {
				return err
			}
		case Return_Node:
			if err := arity_walk_expr(s.value); err != .None {
				return err
			}
		case If_Node:
			if err := arity_walk_expr(s.cond); err != .None {
				return err
			}
			if err := arity_walk_body(s.body); err != .None {
				return err
			}
		}
	}
	return .None
}

arity_walk_expr :: proc(expr: Expr) -> Gate_Error {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
	case ^Call_Expr:
		if err := arity_walk_expr(e.callee); err != .None {
			return err
		}
		for arg in e.args {
			if err := arity_walk_expr(arg); err != .None {
				return err
			}
		}
	case ^Member_Expr:
		return arity_walk_expr(e.receiver)
	case ^Variant_Expr:
		for arg in e.payload {
			if err := arity_walk_expr(arg); err != .None {
				return err
			}
		}
		for field in e.fields {
			if err := arity_walk_expr(field.value); err != .None {
				return err
			}
		}
	case ^Record_Expr:
		for field in e.fields {
			if err := arity_walk_expr(field.value); err != .None {
				return err
			}
		}
	case ^List_Expr:
		for element in e.elements {
			if err := arity_walk_expr(element); err != .None {
				return err
			}
		}
	case ^Lambda_Expr:
		if len(e.params) > MAX_PARAM_ARITY {
			return .Arity_Exceeded
		}
		return arity_walk_expr(e.body)
	case ^Unary_Expr:
		return arity_walk_expr(e.operand)
	case ^Binary_Expr:
		if err := arity_walk_expr(e.lhs); err != .None {
			return err
		}
		return arity_walk_expr(e.rhs)
	case ^With_Expr:
		if err := arity_walk_expr(e.base); err != .None {
			return err
		}
		for field in e.fields {
			if err := arity_walk_expr(field.value); err != .None {
				return err
			}
		}
	case ^Match_Expr:
		if err := arity_walk_expr(e.scrutinee); err != .None {
			return err
		}
		for arm in e.arms {
			if err := arity_walk_expr(arm.body); err != .None {
				return err
			}
		}
	case ^Tuple_Expr:
		for element in e.elements {
			if err := arity_walk_expr(element); err != .None {
				return err
			}
		}
	case ^If_Expr:
		if err := arity_walk_expr(e.cond); err != .None {
			return err
		}
		if err := arity_walk_expr(e.then_branch); err != .None {
			return err
		}
		if err := arity_walk_expr(e.else_branch); err != .None {
			return err
		}
	case ^Stub_Expr:
		if e.has_fallback {
			return arity_walk_expr(e.fallback)
		}
	}
	return .None
}

check_cyclomatic :: proc(unit: Gate_Unit) -> Gate_Error {
	if 1 + body_decisions(unit.body) > MAX_CYCLOMATIC {
		return .Cyclomatic_Exceeded
	}
	return .None
}

body_decisions :: proc(body: []Statement) -> int {
	decisions := 0
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			decisions += count_short_circuit(s.value)
		case Assert_Node:
			decisions += count_short_circuit(s.expr)
		case Return_Node:
			decisions += count_short_circuit(s.value)
		case If_Node:
			decisions += 1
			decisions += count_short_circuit(s.cond)
			decisions += body_decisions(s.body)
		}
	}
	return decisions
}

count_short_circuit :: proc(expr: Expr) -> int {
	count := 0
	#partial switch e in expr {
	case ^Unary_Expr:
		count += count_short_circuit(e.operand)
	case ^Binary_Expr:
		if is_short_circuit(e.op) {
			count += 1
		}
		count += count_short_circuit(e.lhs)
		count += count_short_circuit(e.rhs)
	case ^Member_Expr:
		count += count_short_circuit(e.receiver)
	case ^Call_Expr:
		count += count_short_circuit(e.callee)
		for arg in e.args {
			count += count_short_circuit(arg)
		}
	case ^Record_Expr:
		for field in e.fields {
			count += count_short_circuit(field.value)
		}
	case ^List_Expr:
		for element in e.elements {
			count += count_short_circuit(element)
		}
	case ^Lambda_Expr:
		count += count_short_circuit(e.body)
	case ^Variant_Expr:
		for arg in e.payload {
			count += count_short_circuit(arg)
		}
		for field in e.fields {
			count += count_short_circuit(field.value)
		}
	case ^With_Expr:
		count += count_short_circuit(e.base)
		for field in e.fields {
			count += count_short_circuit(field.value)
		}
	case ^Match_Expr:
		count += count_short_circuit(e.scrutinee)
		for arm in e.arms {
			count += count_short_circuit(arm.body)
		}
	case ^Tuple_Expr:
		for element in e.elements {
			count += count_short_circuit(element)
		}
	case ^If_Expr:
		count += 1
		count += count_short_circuit(e.cond)
		count += count_short_circuit(e.then_branch)
		count += count_short_circuit(e.else_branch)
	case ^Stub_Expr:
		if e.has_fallback {
			count += count_short_circuit(e.fallback)
		}
	}
	return count
}

is_short_circuit :: proc(op: Token) -> bool {
	return op.kind == .Ident && (op.text == "and" || op.text == "or")
}

check_nesting :: proc(unit: Gate_Unit) -> (err: Gate_Error, cause: Nesting_Cause) {
	return nesting_walk_body(unit.body, 0)
}

nesting_walk_body :: proc(body: []Statement, depth: int) -> (err: Gate_Error, cause: Nesting_Cause) {
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			if depth + nesting_depth(s.value) > MAX_NESTING_DEPTH {
				return .Nesting_Exceeded, nesting_cause_at(depth)
			}
		case Assert_Node:
			if depth + nesting_depth(s.expr) > MAX_NESTING_DEPTH {
				return .Nesting_Exceeded, nesting_cause_at(depth)
			}
		case Return_Node:
			if depth + nesting_depth(s.value) > MAX_NESTING_DEPTH {
				return .Nesting_Exceeded, nesting_cause_at(depth)
			}
		case If_Node:
			if depth + nesting_depth(s.cond) > MAX_NESTING_DEPTH {
				return .Nesting_Exceeded, nesting_cause_at(depth)
			}
			if e, c := nesting_walk_body(s.body, depth + 1); e != .None {
				return e, c
			}
		}
	}
	return .None, .None
}

nesting_cause_at :: proc(depth: int) -> Nesting_Cause {
	if depth >= MAX_NESTING_DEPTH {
		return .Block
	}
	return .Expression
}

nesting_depth :: proc(expr: Expr) -> int {
	#partial switch e in expr {
	case ^Unary_Expr:
		return nesting_depth(e.operand)
	case ^Binary_Expr:
		return max(nesting_depth(e.lhs), nesting_depth(e.rhs))
	case ^Member_Expr:
		return nesting_depth(e.receiver)
	case ^Call_Expr:
		if method, is_method := e.callee.(^Member_Expr); is_method {
			inner := nesting_depth(method.receiver)
			for arg in e.args {
				inner = max(inner, 1 + arg_nesting_depth(arg))
			}
			return inner
		}
		inner := nesting_depth(e.callee)
		for arg in e.args {
			inner = max(inner, arg_nesting_depth(arg))
		}
		return 1 + inner
	case ^Record_Expr:
		inner := 0
		for field in e.fields {
			inner = max(inner, nesting_depth(field.value))
		}
		return inner
	case ^List_Expr:
		inner := 0
		for element in e.elements {
			inner = max(inner, nesting_depth(element))
		}
		return inner
	case ^Lambda_Expr:
		return 1 + nesting_depth(e.body)
	case ^Variant_Expr:
		inner := 0
		opens_level := false
		for arg in e.payload {
			if is_payload_variant(arg) {
				opens_level = true
			}
			inner = max(inner, nesting_depth(arg))
		}
		for field in e.fields {
			if is_payload_variant(field.value) {
				opens_level = true
			}
			inner = max(inner, nesting_depth(field.value))
		}
		if opens_level {
			return 1 + inner
		}
		return inner
	case ^With_Expr:
		inner := nesting_depth(e.base)
		for field in e.fields {
			inner = max(inner, nesting_depth(field.value))
		}
		return 1 + inner
	case ^Match_Expr:
		inner := nesting_depth(e.scrutinee)
		for arm in e.arms {
			inner = max(inner, 1 + nesting_depth(arm.body))
		}
		return inner
	case ^Tuple_Expr:
		inner := 0
		for element in e.elements {
			inner = max(inner, nesting_depth(element))
		}
		return inner
	case ^If_Expr:
		inner := nesting_depth(e.cond)
		inner = max(inner, 1 + nesting_depth(e.then_branch))
		inner = max(inner, 1 + nesting_depth(e.else_branch))
		return inner
	}
	return 0
}

is_payload_variant :: proc(expr: Expr) -> bool {
	variant, is_variant := expr.(^Variant_Expr)
	if !is_variant {
		return false
	}
	return variant.has_payload || variant.has_fields
}

arg_nesting_depth :: proc(arg: Expr) -> int {
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		return nesting_depth(lambda.body)
	}
	return nesting_depth(arg)
}

gate_duplication :: proc(units: []Gate_Unit) -> (err: Gate_Error, name: string, line: int) {
	seen := make(map[string]int, context.temp_allocator)
	for unit in units {
		if unit.dup_exempt {
			continue
		}
		key := dup_canon(unit.body)
		seen[key] += 1
		if seen[key] > MAX_DUPLICATE_UNITS {
			return .Duplicate_Declaration, unit.name, unit.line
		}
	}
	return .None, "", 0
}

dup_canon :: proc(body: []Statement) -> string {
	b := strings.builder_make(context.temp_allocator)
	alpha := make([dynamic]string, 0, 8, context.temp_allocator)
	canon_body(&b, body, &alpha)
	return strings.to_string(b)
}

dup_class :: proc(body: []Statement) -> u64 {
	return hash.fnv64a(transmute([]byte)dup_canon(body))
}

canon_body :: proc(b: ^strings.Builder, body: []Statement, alpha: ^[dynamic]string) {
	strings.write_string(b, "(body")
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			strings.write_string(b, " (let ")
			canon_expr(b, s.value, alpha)
			strings.write_byte(b, ')')
			append(alpha, s.name)
		case Assert_Node:
			strings.write_string(b, " (assert ")
			canon_expr(b, s.expr, alpha)
			strings.write_byte(b, ')')
		case Return_Node:
			strings.write_string(b, " (return ")
			canon_expr(b, s.value, alpha)
			strings.write_byte(b, ')')
		case If_Node:
			strings.write_string(b, " (if ")
			canon_expr(b, s.cond, alpha)
			canon_body(b, s.body, alpha)
			strings.write_byte(b, ')')
		}
	}
	strings.write_byte(b, ')')
}

canon_expr :: proc(b: ^strings.Builder, expr: Expr, alpha: ^[dynamic]string) {
	switch e in expr {
	case ^Int_Lit_Expr:
		strings.write_string(b, "(int ")
		strings.write_i64(b, e.value)
		strings.write_byte(b, ')')
	case ^Fixed_Lit_Expr:
		strings.write_string(b, "(fixed ")
		strings.write_i64(b, i64(e.bits))
		strings.write_byte(b, ')')
	case ^String_Lit_Expr:
		strings.write_string(b, "(string ")
		strings.write_string(b, e.text)
		strings.write_byte(b, ')')
	case ^Name_Expr:
		canon_name(b, e.name, alpha)
	case ^Call_Expr:
		strings.write_string(b, "(call ")
		canon_expr(b, e.callee, alpha)
		for arg in e.args {
			strings.write_byte(b, ' ')
			canon_expr(b, arg, alpha)
		}
		strings.write_byte(b, ')')
	case ^Member_Expr:
		strings.write_string(b, "(member ")
		canon_expr(b, e.receiver, alpha)
		strings.write_byte(b, ' ')
		strings.write_string(b, e.member)
		strings.write_byte(b, ')')
	case ^Variant_Expr:
		strings.write_string(b, "(variant ")
		strings.write_string(b, e.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, e.variant)
		if e.has_payload {
			strings.write_string(b, " (payload)")
		}
		for arg in e.payload {
			strings.write_byte(b, ' ')
			canon_expr(b, arg, alpha)
		}
		for field in e.fields {
			strings.write_string(b, " (")
			strings.write_string(b, field.name)
			strings.write_byte(b, ' ')
			canon_expr(b, field.value, alpha)
			strings.write_byte(b, ')')
		}
		strings.write_byte(b, ')')
	case ^Record_Expr:
		strings.write_string(b, "(record ")
		strings.write_string(b, e.type_name)
		for field in e.fields {
			strings.write_string(b, " (")
			strings.write_string(b, field.name)
			strings.write_byte(b, ' ')
			canon_expr(b, field.value, alpha)
			strings.write_byte(b, ')')
		}
		strings.write_byte(b, ')')
	case ^List_Expr:
		strings.write_string(b, "(list")
		for el in e.elements {
			strings.write_byte(b, ' ')
			canon_expr(b, el, alpha)
		}
		strings.write_byte(b, ')')
	case ^Lambda_Expr:
		strings.write_string(b, "(lambda ")
		strings.write_int(b, len(e.params))
		base := len(alpha)
		for p in e.params {
			append(alpha, p)
		}
		strings.write_string(b, " (body ")
		canon_expr(b, e.body, alpha)
		strings.write_byte(b, ')')
		resize(alpha, base)
		strings.write_byte(b, ')')
	case ^Unary_Expr:
		strings.write_string(b, "(unary ")
		strings.write_string(b, op_tag(e.op))
		strings.write_byte(b, ' ')
		canon_expr(b, e.operand, alpha)
		strings.write_byte(b, ')')
	case ^Binary_Expr:
		strings.write_string(b, "(binary ")
		strings.write_string(b, op_tag(e.op))
		strings.write_byte(b, ' ')
		canon_expr(b, e.lhs, alpha)
		strings.write_byte(b, ' ')
		canon_expr(b, e.rhs, alpha)
		strings.write_byte(b, ')')
	case ^With_Expr:
		strings.write_string(b, "(with ")
		canon_expr(b, e.base, alpha)
		for field in e.fields {
			strings.write_string(b, " (")
			strings.write_string(b, field.name)
			strings.write_byte(b, ' ')
			canon_expr(b, field.value, alpha)
			strings.write_byte(b, ')')
		}
		strings.write_byte(b, ')')
	case ^Match_Expr:
		strings.write_string(b, "(match ")
		canon_expr(b, e.scrutinee, alpha)
		for arm in e.arms {
			canon_arm(b, arm, alpha)
		}
		strings.write_byte(b, ')')
	case ^Tuple_Expr:
		strings.write_string(b, "(tuple")
		for element in e.elements {
			strings.write_byte(b, ' ')
			canon_expr(b, element, alpha)
		}
		strings.write_byte(b, ')')
	case ^If_Expr:
		strings.write_string(b, "(if ")
		canon_expr(b, e.cond, alpha)
		strings.write_byte(b, ' ')
		canon_expr(b, e.then_branch, alpha)
		strings.write_byte(b, ' ')
		canon_expr(b, e.else_branch, alpha)
		strings.write_byte(b, ')')
	case ^Stub_Expr:
		strings.write_string(b, "(stub ")
		strings.write_string(b, type_ref_string(e.hole_type))
		if e.has_fallback {
			strings.write_byte(b, ' ')
			canon_expr(b, e.fallback, alpha)
		}
		strings.write_byte(b, ')')
	case ^All_Expr:
		strings.write_string(b, "(all ")
		strings.write_string(b, e.thing)
		strings.write_byte(b, ')')
	case nil:
		strings.write_string(b, "(nil)")
	}
}

canon_name :: proc(b: ^strings.Builder, name: string, alpha: ^[dynamic]string) {
	for i := len(alpha) - 1; i >= 0; i -= 1 {
		if alpha[i] == name {
			strings.write_string(b, "(bound ")
			strings.write_int(b, i)
			strings.write_byte(b, ')')
			return
		}
	}
	strings.write_string(b, "(free ")
	strings.write_string(b, name)
	strings.write_byte(b, ')')
}

canon_arm :: proc(b: ^strings.Builder, arm: Match_Arm, alpha: ^[dynamic]string) {
	strings.write_string(b, " (arm ")
	canon_pattern(b, arm.pattern)
	strings.write_string(b, " (binders ")
	strings.write_int(b, pattern_binder_count(arm.pattern))
	strings.write_byte(b, ')')
	base := len(alpha)
	push_pattern_binders(alpha, arm.pattern)
	strings.write_byte(b, ' ')
	canon_expr(b, arm.body, alpha)
	resize(alpha, base)
	strings.write_byte(b, ')')
}

pattern_binder_count :: proc(pattern: Pattern) -> int {
	switch pattern.kind {
	case .Wildcard, .Bare_Variant:
		return 0
	case .Struct_Binds, .Bare_Binder:
		return len(pattern.binders)
	case .Variant_Binds, .Tuple:
		count := 0
		for sub in pattern.elements {
			count += pattern_binder_count(sub)
		}
		return count
	}
	return 0
}

canon_pattern :: proc(b: ^strings.Builder, pattern: Pattern) {
	switch pattern.kind {
	case .Wildcard:
		strings.write_string(b, "wild")
	case .Bare_Variant:
		strings.write_string(b, "bare ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
	case .Variant_Binds:
		strings.write_string(b, "binds ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
		for sub in pattern.elements {
			strings.write_byte(b, ' ')
			canon_pattern(b, sub)
		}
	case .Struct_Binds:
		strings.write_string(b, "struct ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
	case .Bare_Binder:
		strings.write_string(b, "bind")
	case .Tuple:
		strings.write_string(b, "tup")
		for sub in pattern.elements {
			strings.write_byte(b, ' ')
			canon_pattern(b, sub)
		}
	}
}

push_pattern_binders :: proc(alpha: ^[dynamic]string, pattern: Pattern) {
	switch pattern.kind {
	case .Wildcard, .Bare_Variant:
	case .Struct_Binds, .Bare_Binder:
		for binder in pattern.binders {
			append(alpha, binder)
		}
	case .Variant_Binds:
		for sub in pattern.elements {
			push_pattern_binders(alpha, sub)
		}
	case .Tuple:
		for sub in pattern.elements {
			push_pattern_binders(alpha, sub)
		}
	}
}

op_tag :: proc(tok: Token) -> string {
	#partial switch tok.kind {
	case .Eq_Eq:
		return "=="
	case .Not_Eq:
		return "!="
	case .Lt:
		return "<"
	case .Lt_Eq:
		return "<="
	case .Gt:
		return ">"
	case .Gt_Eq:
		return ">="
	case .Plus:
		return "+"
	case .Minus:
		return "-"
	case .Star:
		return "*"
	case .Slash:
		return "/"
	case .Percent:
		return "%"
	case .Ident:
		return tok.text
	}
	return "?"
}

Closed_Variant_Set :: struct {
	type_name: string,
	variants:  []string,
}

@(rodata)
CLOSED_VARIANT_SETS := []Closed_Variant_Set{
	{type_name = "Option", variants = {"Some", "None"}},
	{type_name = "Result", variants = {"Ok", "Err"}},
	{type_name = "Ordering", variants = {"Less", "Equal", "Greater"}},
}

closed_variant_sets :: proc(ast: Ast) -> []Closed_Variant_Set {
	sets := make([dynamic]Closed_Variant_Set, 0, len(CLOSED_VARIANT_SETS) + len(ast.enums), context.temp_allocator)
	for set in CLOSED_VARIANT_SETS {
		append(&sets, set)
	}
	for decl in ast.enums {
		variants := make([]string, len(decl.variants), context.temp_allocator)
		for variant, i in decl.variants {
			variants[i] = variant.name
		}
		append(&sets, Closed_Variant_Set{type_name = decl.name, variants = variants})
	}
	return sets[:]
}

closed_variant_set :: proc(sets: []Closed_Variant_Set, type_name: string) -> (set: Closed_Variant_Set, found: bool) {
	for candidate in sets {
		if candidate.type_name == type_name {
			return candidate, true
		}
	}
	return Closed_Variant_Set{}, false
}

check_match_exhaustiveness_unit :: proc(unit: Gate_Unit, sets: []Closed_Variant_Set) -> Gate_Error {
	return match_walk_body(unit.body, sets)
}

match_walk_body :: proc(body: []Statement, sets: []Closed_Variant_Set) -> Gate_Error {
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			if err := match_walk_expr(node.value, sets); err != .None {
				return err
			}
		case Assert_Node:
			if err := match_walk_expr(node.expr, sets); err != .None {
				return err
			}
		case Return_Node:
			if err := match_walk_expr(node.value, sets); err != .None {
				return err
			}
		case If_Node:
			if err := match_walk_expr(node.cond, sets); err != .None {
				return err
			}
			if err := match_walk_body(node.body, sets); err != .None {
				return err
			}
		}
	}
	return .None
}

match_walk_expr :: proc(expr: Expr, sets: []Closed_Variant_Set) -> Gate_Error {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
		return .None
	case ^Call_Expr:
		if err := match_walk_expr(e.callee, sets); err != .None {
			return err
		}
		for arg in e.args {
			if err := match_walk_expr(arg, sets); err != .None {
				return err
			}
		}
		return .None
	case ^Member_Expr:
		return match_walk_expr(e.receiver, sets)
	case ^Variant_Expr:
		for arg in e.payload {
			if err := match_walk_expr(arg, sets); err != .None {
				return err
			}
		}
		for field in e.fields {
			if err := match_walk_expr(field.value, sets); err != .None {
				return err
			}
		}
		return .None
	case ^Record_Expr:
		for field in e.fields {
			if err := match_walk_expr(field.value, sets); err != .None {
				return err
			}
		}
		return .None
	case ^List_Expr:
		for element in e.elements {
			if err := match_walk_expr(element, sets); err != .None {
				return err
			}
		}
		return .None
	case ^Lambda_Expr:
		return match_walk_expr(e.body, sets)
	case ^Unary_Expr:
		return match_walk_expr(e.operand, sets)
	case ^Binary_Expr:
		if err := match_walk_expr(e.lhs, sets); err != .None {
			return err
		}
		return match_walk_expr(e.rhs, sets)
	case ^With_Expr:
		if err := match_walk_expr(e.base, sets); err != .None {
			return err
		}
		for field in e.fields {
			if err := match_walk_expr(field.value, sets); err != .None {
				return err
			}
		}
		return .None
	case ^Match_Expr:
		if err := match_walk_expr(e.scrutinee, sets); err != .None {
			return err
		}
		for arm in e.arms {
			if err := match_walk_expr(arm.body, sets); err != .None {
				return err
			}
		}
		return check_match_total(e, sets)
	case ^Tuple_Expr:
		for element in e.elements {
			if err := match_walk_expr(element, sets); err != .None {
				return err
			}
		}
		return .None
	case ^If_Expr:
		if err := match_walk_expr(e.cond, sets); err != .None {
			return err
		}
		if err := match_walk_expr(e.then_branch, sets); err != .None {
			return err
		}
		return match_walk_expr(e.else_branch, sets)
	case ^Stub_Expr:
		if e.has_fallback {
			return match_walk_expr(e.fallback, sets)
		}
		return .None
	}
	return .None
}

check_match_total :: proc(match: ^Match_Expr, sets: []Closed_Variant_Set) -> Gate_Error {
	type_name := ""
	for arm in match.arms {
		if arm.pattern.kind == .Wildcard {
			return .None
		}
		if type_name == "" {
			type_name = arm.pattern.type_name
		}
	}
	if match_mixes_closed_types(match, sets) {
		return .None
	}
	set, known := closed_variant_set(sets, type_name)
	if !known {
		return .None
	}
	for variant in set.variants {
		if !match_covers_variant(match, type_name, variant) {
			return .Non_Exhaustive_Match
		}
	}
	return .None
}

match_mixes_closed_types :: proc(match: ^Match_Expr, sets: []Closed_Variant_Set) -> bool {
	first := ""
	for arm in match.arms {
		if arm.pattern.type_name == "" {
			continue
		}
		if _, known := closed_variant_set(sets, arm.pattern.type_name); !known {
			continue
		}
		if first == "" {
			first = arm.pattern.type_name
		} else if arm.pattern.type_name != first {
			return true
		}
	}
	return false
}

match_covers_variant :: proc(match: ^Match_Expr, type_name: string, variant: string) -> bool {
	for arm in match.arms {
		if arm.pattern.kind == .Wildcard {
			continue
		}
		if arm.pattern.type_name == type_name && arm.pattern.variant == variant {
			return true
		}
	}
	return false
}
