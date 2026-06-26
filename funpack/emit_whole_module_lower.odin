// The §19 textured-render WHOLE-MODULE const carry + bare-name lowering (schema
// v17): the seam that makes `assets.dungeon_atlas` resolve in the runtime. The
// dungeon's draw behaviors reference an atlas handle through a WHOLE-MODULE import
// of the generated `assets` seam (`import assets`, then `assets.dungeon_atlas`) —
// distinct from the brace-group level-seam import (`import dungeon.{terrain}`) the
// v6/v15 carry already handles. A whole-module import binds no bare names, so the
// body reference stays the qualified member-expr `assets.dungeon_atlas`, the
// runtime's bare-name lookup never finds the const, and the textured sprite
// fail-closes to no texture (the runtime-confirmed silent drop).
//
// This file closes that gap with the SAME two mechanisms the v6 seam carry uses
// for brace-group imports, extended to the whole-module form:
//   (1) CARRY — collect_whole_module_const_records carries each whole-module-
//       referenced handle const into [functions] as a `function NAME const`
//       record (the v15 imported-const carry form), keyed to the SEAM module's
//       span, with the const's correct §26 typed handle value (AtlasHandle /
//       SoundHandle / MeshHandle / TextureHandle — read from the seam AST's
//       declared type, never hardcoded to atlas).
//   (2) LOWER — lower_whole_module_refs rewrites every `module.NAME` member-expr
//       in the entrypoint AST's behavior/fn/let bodies to a BARE `Name_Expr{NAME}`,
//       so the runtime resolves it by bare name against the carried record (the v6
//       qualified→bare lowering). No runtime special-case: the artifact carries a
//       self-contained bare-name program.
//
// COLLISION DISCIPLINE (the v6 disambiguation): a whole-module const is lowered to
// its bare name ONLY when no own-module declaration already binds that name. A
// collision (the entrypoint declares its own `dungeon_atlas` let/fn) would put two
// [functions] records under one bare name — an ambiguous lookup. That case is
// surfaced as friction (whole_module_lower_collision), never silently resolved by
// picking one, so the build refuses rather than shipping an ambiguous artifact.
//
// PURITY (§29): the carry and the lowering are pure functions of the entrypoint
// AST and the sibling-module ASTs. The walks are import-declaration order then a
// source-order body walk — never a map iteration — so two emissions are
// byte-identical. The module_asts map is read by key, never iterated.
package funpack

import "core:slice"
import "core:strings"

// whole_module_user_imports returns the §15 names of the entrypoint AST's
// WHOLE-MODULE user imports — a single-segment import with NO brace group
// (`import assets` ⇒ segments ["assets"], members nil) whose leading segment is a
// present sibling user module. This is the complement of imported_user_module
// (emit_seam_fns.odin), which matches the brace-group form; the two together
// classify every user-module import. An `engine.*` path (multi-segment) or a
// brace-group import is not a whole-module import, so it is left to the resolver
// and the v6/v15 brace-group carry respectively. The result is in import-
// declaration order (a source-order slice), so downstream walks are deterministic.
whole_module_user_imports :: proc(entry_ast: Ast, module_asts: map[string]Ast) -> []string {
	names := make([dynamic]string, 0, 2, context.temp_allocator)
	for import_node in entry_ast.imports {
		if len(import_node.segments) != 1 || len(import_node.members) != 0 {
			continue
		}
		candidate := import_node.segments[0]
		if _, present := module_asts[candidate]; !present {
			continue
		}
		append(&names, candidate)
	}
	return names[:]
}

// collect_whole_module_const_records carries the consts the entrypoint references
// through a WHOLE-MODULE user import — each `module.NAME` member-expr where
// `module` is a whole-module-imported sibling user module and NAME resolves to a
// module-level `let` in that module's AST. Each carried const lands as a `function
// NAME const` record (the v15 imported-const carry form) bearing the SEAM module's
// span, so emit_functions appends a self-contained record the runtime resolves by
// the bare name lower_whole_module_refs lowers the reference to. The carried const's
// value and declared type come straight from the seam AST's `let`, so the §26
// handle KIND (AtlasHandle / SoundHandle / MeshHandle / TextureHandle) is exactly
// what the source declared — never inferred or hardcoded.
//
// Each (module, NAME) pair carries AT MOST ONCE even if referenced many times (the
// dungeon draws three sprites off `assets.dungeon_atlas`), de-duplicated by name in
// reference-discovery order. A reference whose NAME is not a module-level let in the
// seam (it might be an extern accessor, a type) carries no const record — the v6 fn
// carry / v15 decl carry own those member kinds; this carries only consts. A nil/
// empty module_asts (the single-source path) carries nothing.
collect_whole_module_const_records :: proc(entry_ast: Ast, module_asts: map[string]Ast) -> []Function_Record {
	if len(module_asts) == 0 {
		return nil
	}
	imports := whole_module_user_imports(entry_ast, module_asts)
	if len(imports) == 0 {
		return nil
	}
	records := make([dynamic]Function_Record, 0, 2, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	// The referenced (module, member) pairs in body source order — the same order
	// collect_whole_module_refs discovers them, so the carried records land
	// deterministically.
	for ref in collect_whole_module_refs(entry_ast, imports) {
		key := whole_module_ref_key(ref.module, ref.member)
		if seen[key] {
			continue
		}
		seen[key] = true
		seam_ast := module_asts[ref.module]
		decl, found := find_let(seam_ast, ref.member)
		if !found {
			// Not a module-level let in the seam — a fn (the v6 carry's job) or a
			// type (the v15 decl carry's job) reached through the whole-module import.
			// This carry owns consts only, so it skips the non-const member.
			continue
		}
		append(&records, Function_Record {
			name        = decl.name,
			kind        = "const",
			params      = nil,
			return_type = decl.type,
			body        = const_body(decl),
			line        = decl.line,
			module      = ref.module,
		})
	}
	return records[:]
}

// Whole_Module_Ref is one `module.NAME` reference found in the entrypoint body — the
// whole-module-imported module name and the member it accesses. The carry reads it to
// carry the const; the lowering reads the same shape to rewrite the member-expr.
Whole_Module_Ref :: struct {
	module: string,
	member: string,
}

// whole_module_ref_key joins a (module, member) pair into the dedup key the carry
// keys on — `module\x00member`, the NUL separator keeping two distinct pairs from
// colliding on a shared substring (neither a module nor a member can carry NUL).
whole_module_ref_key :: proc(module: string, member: string) -> string {
	return strings.concatenate({module, "\x00", member}, context.temp_allocator)
}

// collect_whole_module_refs walks every body in the entrypoint AST (behaviors, fns,
// lets) for `module.NAME` member-expr references where `module` is a whole-module-
// imported user module in `imports`. The result is in declaration source order then
// body source order — a pure function of the AST, never a map iteration. A name not
// in `imports` is left alone (it is a real field access or another module's
// reference). Duplicates are NOT de-duplicated here — the carry de-dups by key, and
// the lowering rewrites every occurrence.
collect_whole_module_refs :: proc(entry_ast: Ast, imports: []string) -> []Whole_Module_Ref {
	refs := make([dynamic]Whole_Module_Ref, 0, 4, context.temp_allocator)
	for behavior in entry_ast.behaviors {
		collect_refs_in_statements(&refs, behavior.step.body, imports)
	}
	for fn in entry_ast.fns {
		collect_refs_in_statements(&refs, fn.body, imports)
	}
	for decl in entry_ast.lets {
		collect_refs_in_expr(&refs, decl.value, imports)
	}
	return refs[:]
}

// collect_refs_in_statements walks a statement sequence for whole-module refs in
// every expression position (assert/let values, return values, if conditions and
// nested bodies).
collect_refs_in_statements :: proc(refs: ^[dynamic]Whole_Module_Ref, body: []Statement, imports: []string) {
	for stmt in body {
		switch s in stmt {
		case Assert_Node:
			collect_refs_in_expr(refs, s.expr, imports)
		case Let_Node:
			collect_refs_in_expr(refs, s.value, imports)
		case Return_Node:
			collect_refs_in_expr(refs, s.value, imports)
		case If_Node:
			collect_refs_in_expr(refs, s.cond, imports)
			collect_refs_in_statements(refs, s.body, imports)
		}
	}
}

// collect_refs_in_expr recurses an expression for whole-module member references.
// A `module.NAME` member-expr whose receiver is a bare name in `imports` is one
// reference; every other arm recurses into its children. The walk mirrors emit_expr's
// node arms so no expression position is missed.
collect_refs_in_expr :: proc(refs: ^[dynamic]Whole_Module_Ref, expr: Expr, imports: []string) {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
		// Leaves carry no nested expression.
	case ^Member_Expr:
		if name, is_name := e.receiver.(^Name_Expr); is_name && slice.contains(imports, name.name) {
			append(refs, Whole_Module_Ref{module = name.name, member = e.member})
			return
		}
		collect_refs_in_expr(refs, e.receiver, imports)
	case ^Call_Expr:
		collect_refs_in_expr(refs, e.callee, imports)
		for arg in e.args {
			collect_refs_in_expr(refs, arg, imports)
		}
	case ^Variant_Expr:
		for arg in e.payload {
			collect_refs_in_expr(refs, arg, imports)
		}
		for field in e.fields {
			collect_refs_in_expr(refs, field.value, imports)
		}
	case ^Record_Expr:
		for field in e.fields {
			collect_refs_in_expr(refs, field.value, imports)
		}
	case ^List_Expr:
		for element in e.elements {
			collect_refs_in_expr(refs, element, imports)
		}
	case ^Lambda_Expr:
		collect_refs_in_expr(refs, e.body, imports)
	case ^Unary_Expr:
		collect_refs_in_expr(refs, e.operand, imports)
	case ^Binary_Expr:
		collect_refs_in_expr(refs, e.lhs, imports)
		collect_refs_in_expr(refs, e.rhs, imports)
	case ^With_Expr:
		collect_refs_in_expr(refs, e.base, imports)
		for field in e.fields {
			collect_refs_in_expr(refs, field.value, imports)
		}
	case ^Match_Expr:
		collect_refs_in_expr(refs, e.scrutinee, imports)
		for arm in e.arms {
			collect_refs_in_expr(refs, arm.body, imports)
		}
	case ^Tuple_Expr:
		for element in e.elements {
			collect_refs_in_expr(refs, element, imports)
		}
	case ^If_Expr:
		collect_refs_in_expr(refs, e.cond, imports)
		collect_refs_in_expr(refs, e.then_branch, imports)
		collect_refs_in_expr(refs, e.else_branch, imports)
	case ^Stub_Expr:
		if e.has_fallback {
			collect_refs_in_expr(refs, e.fallback, imports)
		}
	}
}

// concat_function_records appends one Function_Record slice after another into a
// fresh temp-allocated slice — the v6 brace-group carry records first, then the v17
// whole-module const carries, so [functions] lists the brace-group seam carries
// (the level seam's `terrain`) ahead of the whole-module carries (the assets seam's
// handles) in a fixed, deterministic order. Both inputs are already source-ordered,
// so the concatenation is byte-stable.
concat_function_records :: proc(first: []Function_Record, second: []Function_Record) -> []Function_Record {
	out := make([dynamic]Function_Record, 0, len(first) + len(second), context.temp_allocator)
	append(&out, ..first)
	append(&out, ..second)
	return out[:]
}

// ── the bare-name lowering (the v6 qualified→bare rewrite) ────────────────

// Whole_Module_Lower_Error is the lowering's closed refusal set. None is the clean
// outcome; Bare_Name_Collision is the v6 disambiguation friction — a whole-module
// const's bare name collides with an own-module declaration, so lowering it would
// put two [functions] records under one bare name. The build refuses rather than
// shipping an ambiguous artifact; the colliding name rides the verdict so the
// refusal is actionable.
Whole_Module_Lower_Error :: enum {
	None,
	Bare_Name_Collision,
}

// Whole_Module_Lower_Verdict carries the lowering's refusal arm plus the colliding
// bare name (set only on Bare_Name_Collision), so the caller names what to repair.
Whole_Module_Lower_Verdict :: struct {
	err:  Whole_Module_Lower_Error,
	name: string,
}

// lower_whole_module_refs rewrites every `module.NAME` member-expr in the entrypoint
// AST's behavior/fn/let bodies to a BARE `Name_Expr{NAME}`, IN PLACE — the v6
// qualified→bare lowering extended to the whole-module import form. After the
// rewrite a behavior body reads the carried handle const by its bare name, exactly
// as the runtime's bare-name lookup resolves it; no runtime special-case is needed.
// Mutating the AST is sound at emit: emit is terminal (typecheck/contracts/flatten
// already ran over the pre-lowered AST), and emit_tree_artifact re-parses a fresh
// AST per build call, so the double-build determinism holds.
//
// COLLISION GUARD (the v6 disambiguation): a whole-module const is lowered to its
// bare name only when no own-module declaration (a top-level fn or module-level let)
// already binds that name. A collision is surfaced as Bare_Name_Collision — the
// build refuses, never silently picking one of two records under one bare name.
// nil/empty module_asts (the single-source path) and an entrypoint with no whole-
// module import leave the AST untouched.
lower_whole_module_refs :: proc(entry_ast: ^Ast, module_asts: map[string]Ast) -> Whole_Module_Lower_Verdict {
	if len(module_asts) == 0 {
		return Whole_Module_Lower_Verdict{}
	}
	imports := whole_module_user_imports(entry_ast^, module_asts)
	if len(imports) == 0 {
		return Whole_Module_Lower_Verdict{}
	}
	// The collision guard: an own-module fn or let name that equals a referenced
	// whole-module const's bare name would make the lowered bare name ambiguous.
	own_names := entrypoint_own_decl_names(entry_ast^)
	for ref in collect_whole_module_refs(entry_ast^, imports) {
		// Only a const reference collides — a member that is a fn/type is not lowered
		// to a [functions] const, so the guard checks the const carry's surface only.
		seam_ast := module_asts[ref.module]
		if _, found := find_let(seam_ast, ref.member); !found {
			continue
		}
		if slice.contains(own_names, ref.member) {
			return Whole_Module_Lower_Verdict{err = .Bare_Name_Collision, name = ref.member}
		}
	}
	for &behavior in entry_ast.behaviors {
		lower_refs_in_statements(behavior.step.body, imports, module_asts)
	}
	for &fn in entry_ast.fns {
		lower_refs_in_statements(fn.body, imports, module_asts)
	}
	for &decl in entry_ast.lets {
		lower_ref_in_expr(&decl.value, imports, module_asts)
	}
	return Whole_Module_Lower_Verdict{}
}

// entrypoint_own_decl_names returns the entrypoint module's own bare binding names —
// every top-level fn name and module-level let name. The collision guard checks a
// whole-module const's bare name against this set, so a lowered bare name never
// shadows or duplicates an own declaration. Walked by index (never a map).
entrypoint_own_decl_names :: proc(ast: Ast) -> []string {
	names := make([dynamic]string, 0, len(ast.fns) + len(ast.lets), context.temp_allocator)
	for fn in ast.fns {
		append(&names, fn.name)
	}
	for decl in ast.lets {
		append(&names, decl.name)
	}
	return names[:]
}

// lower_refs_in_statements rewrites whole-module refs in every expression position
// of a statement sequence, in place — the lowering twin of collect_refs_in_statements.
lower_refs_in_statements :: proc(body: []Statement, imports: []string, module_asts: map[string]Ast) {
	for &stmt in body {
		switch &s in stmt {
		case Assert_Node:
			lower_ref_in_expr(&s.expr, imports, module_asts)
		case Let_Node:
			lower_ref_in_expr(&s.value, imports, module_asts)
		case Return_Node:
			lower_ref_in_expr(&s.value, imports, module_asts)
		case If_Node:
			lower_ref_in_expr(&s.cond, imports, module_asts)
			lower_refs_in_statements(s.body, imports, module_asts)
		}
	}
}

// lower_ref_in_expr rewrites an expression slot in place: a `module.NAME` member-expr
// whose receiver is a whole-module-imported user module and whose NAME is a const in
// that module is REPLACED by a bare `Name_Expr{NAME}`; every other arm recurses into
// its children. The walk mirrors collect_refs_in_expr so the lowering covers exactly
// the positions the carry discovered. Only a const-resolving member is lowered: a
// member that is a fn/type stays a member-expr (the v6 fn carry / v15 decl carry own
// those — they are reached by their own brace-group route, not lowered here).
lower_ref_in_expr :: proc(slot: ^Expr, imports: []string, module_asts: map[string]Ast) {
	switch e in slot^ {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
		// Leaves carry no nested expression.
	case ^Member_Expr:
		if name, is_name := e.receiver.(^Name_Expr); is_name && slice.contains(imports, name.name) {
			seam_ast := module_asts[name.name]
			if _, found := find_let(seam_ast, e.member); found {
				// The lowered node is emit-only (emit_expr writes `node name NAME 0`
				// and never serializes the class), so the class is informational; a
				// handle const's bare name is a snake_case value reference.
				lowered := new(Name_Expr, context.temp_allocator)
				lowered.name = e.member
				lowered.class = .Snake_Case
				slot^ = lowered
				return
			}
		}
		lower_ref_in_expr(&e.receiver, imports, module_asts)
	case ^Call_Expr:
		lower_ref_in_expr(&e.callee, imports, module_asts)
		for &arg in e.args {
			lower_ref_in_expr(&arg, imports, module_asts)
		}
	case ^Variant_Expr:
		for &arg in e.payload {
			lower_ref_in_expr(&arg, imports, module_asts)
		}
		for &field in e.fields {
			lower_ref_in_expr(&field.value, imports, module_asts)
		}
	case ^Record_Expr:
		for &field in e.fields {
			lower_ref_in_expr(&field.value, imports, module_asts)
		}
	case ^List_Expr:
		for &element in e.elements {
			lower_ref_in_expr(&element, imports, module_asts)
		}
	case ^Lambda_Expr:
		lower_ref_in_expr(&e.body, imports, module_asts)
	case ^Unary_Expr:
		lower_ref_in_expr(&e.operand, imports, module_asts)
	case ^Binary_Expr:
		lower_ref_in_expr(&e.lhs, imports, module_asts)
		lower_ref_in_expr(&e.rhs, imports, module_asts)
	case ^With_Expr:
		lower_ref_in_expr(&e.base, imports, module_asts)
		for &field in e.fields {
			lower_ref_in_expr(&field.value, imports, module_asts)
		}
	case ^Match_Expr:
		lower_ref_in_expr(&e.scrutinee, imports, module_asts)
		for &arm in e.arms {
			lower_ref_in_expr(&arm.body, imports, module_asts)
		}
	case ^Tuple_Expr:
		for &element in e.elements {
			lower_ref_in_expr(&element, imports, module_asts)
		}
	case ^If_Expr:
		lower_ref_in_expr(&e.cond, imports, module_asts)
		lower_ref_in_expr(&e.then_branch, imports, module_asts)
		lower_ref_in_expr(&e.else_branch, imports, module_asts)
	case ^Stub_Expr:
		if e.has_fallback {
			lower_ref_in_expr(&e.fallback, imports, module_asts)
		}
	}
}
