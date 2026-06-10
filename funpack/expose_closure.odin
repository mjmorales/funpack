// The §30 §6 / §27 §2 EXPOSURE closure check: an @expose'd declaration may
// reference only exposed, primitive, or stdlib types in its public signature
// surface — a reference to a non-@expose'd USER type is a compile error naming
// BOTH ends (the exposed declaration and the unexposed type). The generated
// external contract (`<name>.api.gen.fun` for a package, `<game>.modapi.gen.fun`
// for a mod surface) is the transitive closure of @expose (§27 §2), so an open
// signature would name a type the contract cannot carry; the check refuses it
// at the source instead of generating a contract with a dangling name. The
// future modapi/api seam generator reads the SAME closure this file gates — the
// closure is gated once here, and the generator can assume every exposed
// signature is closed.
//
// WHERE THE CHECK RUNS — declaring-project-side, per module, inside
// stage_typecheck_indexed (after import/env resolution, before body typing,
// beside the other signature-level membership rules: layer registry,
// @migrate admissibility, @index paths). §27 §2's normative text states the
// closure as a property of the exposed surface itself ("an exposed declaration
// may reference only exposed, primitive, or stdlib types"), so it is checked
// where the @expose markers live — the package's (or modapi-bearing game's)
// own build — never consumer-side at import resolution. The consumer-side §30
// §6 gate (module_export_importable) stays purely the import-visibility
// predicate; this check is its dual on the declaring side.
//
// CLOSURE ≠ IMPORTABILITY: the closure consults the exposure FLAG, not the
// two-boundary importability predicate. A within-project sibling type is
// importable without @expose (§15 §4 public-by-default), yet an exposed
// signature referencing it still violates the closure — contract membership
// and import visibility are different facts, and the contract spans the whole
// project's exposed set regardless of which module a type lives in.
//
// WHAT THE CLOSURE SPANS — the public signature surface of every declaration
// kind the external contract can carry (the export-participating kinds of
// collect_module_exports, plus the §27 §2 read-only query): fn/query params
// and return types, data/thing/signal field types, enum variant payload types,
// and a module-level let's declared type. Field DEFAULTS are expressions, not
// signature surface — the generated contract is declarations only (§27 §2).
// Behaviors, pipelines, and tests do not participate: they are unexportable at
// the resolution layer (a behavior is reached through its pipeline, never an
// importable name), and the §27 §2 pipeline-SLOT exposure is the modapi
// generator's concern over stage names, which carry no type references. Only
// USER-declared types participate — a builtin/prelude name (Int, Fixed), a
// stdlib import (engine.*), and a generic head (View, Ref, Option) are always
// admissible in an exposed signature.
//
// DETERMINISM: declarations walk in the Ast's source-ordered declaration
// sequence (like release_holed_decl), and within one declaration the signature
// walks in declared order (params left-to-right then return; fields in order;
// variants in order), so a multi-violation module always names the same first
// offender, and that offender matches index order.
package funpack

// Expose_Closure_Verdict names BOTH ends of the first exposure-closure
// violation in one module — the repo's named-offender refusal discipline
// (Build_Verdict.offender, Gate_Verdict.declaration), doubled because a
// closure violation is an EDGE: declaration is the @expose'd declaration
// whose signature is open, type_name the non-@expose'd user type it
// references. Both are "" exactly when violation is false.
Expose_Closure_Verdict :: struct {
	declaration: string, // the @expose'd declaration — the exposed end
	type_name:   string, // the non-@expose'd user type it references — the unexposed end
	violation:   bool,
}

// check_expose_closure is the typecheck seam: the closed Type_Error projection
// of expose_closure_verdict (the stage_gates/gate_verdict split), so
// stage_typecheck_indexed composes it with or_return while the named-both-ends
// diagnostic stays reachable through the verdict function for the refusal line.
check_expose_closure :: proc(ast: Ast, bindings: Bindings, index: Module_Index) -> Type_Error {
	if expose_closure_verdict(ast, bindings, index).violation {
		return .Expose_Closure_Violation
	}
	return .None
}

// expose_closure_verdict walks one module's @expose'd declarations in the
// Ast's source-ordered declaration sequence and returns the first signature
// reference to a non-@expose'd user type, naming both ends. A module with no
// @expose'd declaration passes vacuously (a game with no packages and no mods
// writes zero @expose, §30 §6 — the walk never consults a flag it lacks).
// The switch is total over Ast_Decl_Kind, so a new declaration kind is a
// visible compile gap here, never a silently-unwalked signature surface.
expose_closure_verdict :: proc(ast: Ast, bindings: Bindings, index: Module_Index) -> Expose_Closure_Verdict {
	local := local_type_exposure(ast)
	for ref in ast.decls {
		switch ref.kind {
		case .Data:
			decl := ast.datas[ref.index]
			if decl.exposed {
				if name, open := fields_unexposed_ref(decl.fields, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, violation = true}
				}
			}
		case .Thing:
			decl := ast.things[ref.index]
			if decl.exposed {
				if name, open := fields_unexposed_ref(decl.fields, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, violation = true}
				}
			}
		case .Signal:
			decl := ast.signals[ref.index]
			if decl.exposed {
				if name, open := fields_unexposed_ref(decl.fields, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, violation = true}
				}
			}
		case .Enum:
			decl := ast.enums[ref.index]
			if decl.exposed {
				if name, open := variants_unexposed_ref(decl.variants, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, violation = true}
				}
			}
		case .Fn:
			decl := ast.fns[ref.index]
			if decl.exposed {
				if name, open := signature_unexposed_ref(decl.params, decl.return_type, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, violation = true}
				}
			}
		case .Query:
			decl := ast.queries[ref.index]
			if decl.exposed {
				if name, open := signature_unexposed_ref(decl.params, decl.return_type, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, violation = true}
				}
			}
		case .Let:
			decl := ast.lets[ref.index]
			if decl.exposed {
				if name, open := type_ref_unexposed(decl.type, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, violation = true}
				}
			}
		case .Behavior, .Pipeline, .Test:
			// Outside the closure: unexportable at the resolution layer (see the
			// file header) — a behavior is reached through its pipeline, a pipeline
			// declares stage names only, and the parser attaches no @expose to a
			// test block.
		}
	}
	return Expose_Closure_Verdict{}
}

// local_type_exposure maps THIS module's type-position declaration names to
// their @expose flags — the local half of the closure's membership question
// (the cross-module half resolves through bindings + the project index). The
// map is insert-and-lookup only, never iterated (the determinism tripwire).
local_type_exposure :: proc(ast: Ast) -> map[string]bool {
	exposure := make(map[string]bool, context.temp_allocator)
	for decl in ast.datas {
		exposure[decl.name] = decl.exposed
	}
	for decl in ast.enums {
		exposure[decl.name] = decl.exposed
	}
	for decl in ast.things {
		exposure[decl.name] = decl.exposed
	}
	for decl in ast.signals {
		exposure[decl.name] = decl.exposed
	}
	return exposure
}

// signature_unexposed_ref walks a fn/query signature in declared order —
// params left-to-right, then the return type — for the first reference to a
// non-@expose'd user type. An extern or holed fn still carries its full
// signature (params + declared return), so its exposed surface is held to the
// same closure.
signature_unexposed_ref :: proc(
	params: []Param_Decl,
	return_type: Type_Ref,
	local: map[string]bool,
	bindings: Bindings,
	index: Module_Index,
) -> (
	type_name: string,
	open: bool,
) {
	for param in params {
		if name, found := type_ref_unexposed(param.type, local, bindings, index); found {
			return name, true
		}
	}
	return type_ref_unexposed(return_type, local, bindings, index)
}

// fields_unexposed_ref walks a data/thing/signal field list in declared order
// for the first field TYPE referencing a non-@expose'd user type. A field
// DEFAULT is an expression, not signature surface — the generated contract is
// declarations only (§27 §2) — so defaults are deliberately not walked.
fields_unexposed_ref :: proc(
	fields: []Field_Decl,
	local: map[string]bool,
	bindings: Bindings,
	index: Module_Index,
) -> (
	type_name: string,
	open: bool,
) {
	for field in fields {
		if name, found := type_ref_unexposed(field.type, local, bindings, index); found {
			return name, true
		}
	}
	return "", false
}

// variants_unexposed_ref walks an enum's variants in declared order for the
// first payload type referencing a non-@expose'd user type: a tuple payload's
// positional types, then a struct payload's field types (a plain variant
// carries no types). The two payload shapes are disjoint by construction
// (Variant_Payload), so the unused slice is empty and walking both is total.
variants_unexposed_ref :: proc(
	variants: []Variant_Decl,
	local: map[string]bool,
	bindings: Bindings,
	index: Module_Index,
) -> (
	type_name: string,
	open: bool,
) {
	for variant in variants {
		for element in variant.tuple {
			if name, found := type_ref_unexposed(element, local, bindings, index); found {
				return name, true
			}
		}
		if name, found := fields_unexposed_ref(variant.fields, local, bindings, index); found {
			return name, true
		}
	}
	return "", false
}

// type_ref_unexposed walks one syntactic Type_Ref — head first, then its
// generic/list/tuple arguments in order — for the first name that resolves to
// a non-@expose'd user type. The structural heads "[]" (list) and "()" (tuple)
// and the zero-value "" head carry no name to check; their element types still
// walk, so `[Cube]` and `(Rng, Cube)` reach an unexposed Cube.
type_ref_unexposed :: proc(
	ref: Type_Ref,
	local: map[string]bool,
	bindings: Bindings,
	index: Module_Index,
) -> (
	type_name: string,
	open: bool,
) {
	if ref.name != "" && ref.name != "[]" && ref.name != "()" {
		if name_unexposed_user_type(ref.name, local, bindings, index) {
			return ref.name, true
		}
	}
	for arg in ref.args {
		if name, found := type_ref_unexposed(arg, local, bindings, index); found {
			return name, true
		}
	}
	return "", false
}

// name_unexposed_user_type is the closure's membership question for one
// signature name: true exactly when the name resolves to a USER-declared type
// that is not @expose'd. Resolution order mirrors the checker's: this module's
// own type declarations first, then the import bindings — a .Type_Name binding
// whose module is in the project index is a user-module type whose export
// carries the flag (the SAME Module_Export.exposed the §30 §6 import gate
// reads, so the two surfaces can never disagree on what is exposed). Every
// other name — a prelude builtin, a stdlib import (binding module not in the
// user index), a generic head, an unresolved name (the typechecker's own
// Unresolved_Name verdict, never masked by a closure verdict) — is admissible.
name_unexposed_user_type :: proc(name: string, local: map[string]bool, bindings: Bindings, index: Module_Index) -> bool {
	if exposed, declared := local[name]; declared {
		return !exposed
	}
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Type_Name {
		return false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return false
	}
	export, exported := module_export_lookup(entry, name)
	if !exported || export.kind != .Type {
		return false
	}
	return !export.exposed
}
