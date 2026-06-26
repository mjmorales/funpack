// The [functions]-section serializer of the artifact emitter
// (docs/artifact-format.md §9): module fns, module-level consts, and the
// bindings/setup heads, normalized into one Function_Record order grouped by
// KIND. The function-record model is a self-contained concern, distinct from the
// type schema and the wiring sections.
package funpack

import "core:strings"

// ───────────────────────────────────────────────────────────────────────────
// [functions] — pure helpers, module constants, bindings/setup heads
// (docs/artifact-format.md §9)
// ───────────────────────────────────────────────────────────────────────────

// emit_functions writes one record per module-level fn, module-level `let`
// (a `const`), the `bindings()` fn, and the `setup()` fn. Each record carries
// its signature, a `body_count` of top-level statement subtrees, and the span;
// the `param` lines and the body `node` run (§2.7) follow. Records are grouped
// by KIND in the fixed order fn-helpers → const → bindings → startup, each group
// in source-declaration order — the deterministic order
// (docs/artifact-format.md §9) the golden fixture and the runtime's positional
// reader both rely on. The §17 cross-module imported_fns are appended AFTER the
// entrypoint module's own records (in import-then-member declaration order), so a
// multi-module game's [functions] is self-contained: the Rigged draw body's seam
// calls resolve to a carried record. Each carried record carries its OWN seam
// module in its span (record.module), so the span keys to the seam, not the
// entrypoint. imported_fns is empty for a single-module game — its bytes are
// unchanged.
emit_functions :: proc(b: ^strings.Builder, ast: Ast, module: string, imported_fns: []Function_Record) {
	records := function_records(ast, module)
	emit_header(b, "functions", len(records) + len(imported_fns))
	for record in records {
		emit_function_record(b, record)
	}
	for record in imported_fns {
		emit_function_record(b, record)
	}
}

// Function_Record is one [functions] entry, normalized across the four kinds a
// function record carries: a top-level fn, a module-level const (`let`), the
// bindings head, and the setup head. kind is the artifact KIND token; params is
// empty for a const; body is the top-level statement subtrees (a const/bindings/
// setup body is a single `return` statement); line is the source line for the
// span. module is the §15 module the record's span keys to — the entrypoint module
// for an own record, the SEAM module for a §17 cross-module imported_fns record —
// so a multi-module game's span points at the originating module. The §05 §2 hole
// trio (holed/has_fallback/fallback) mirrors Fn_Node: a holed record's body is
// empty and its artifact body run is the single `stub` node instead
// (docs/artifact-format.md §2.7, schema v7), so the fallback approximation
// reaches the runtime and a bare hole fails closed live.
Function_Record :: struct {
	name:         string,
	kind:         string,
	params:       []Param_Decl,
	return_type:  Type_Ref,
	body:         []Statement,
	line:         int,
	module:       string,
	holed:        bool,
	has_fallback: bool,
	fallback:     Expr,
}

// function_records collects the module's fns and module-level `let` constants
// into the [functions] order: grouped by KIND (fn-helper → const → bindings →
// startup), each group in source-declaration order (docs/artifact-format.md §9).
// The `bindings`/`setup` fns are ordinary fns whose names select the
// `bindings`/`startup` KIND, so they sort into their own trailing groups; every
// other fn is a `fn` helper, the consts come from the separate `let` slice. Every
// record's span keys to `module` — the module that DECLARED these decls.
function_records :: proc(ast: Ast, module: string) -> []Function_Record {
	records := make([dynamic]Function_Record, 0, len(ast.fns) + len(ast.lets), context.temp_allocator)
	append_fn_records(&records, ast, "fn", module)
	for decl in ast.lets {
		append(&records, Function_Record{
			name        = decl.name,
			kind        = "const",
			params      = nil,
			return_type = decl.type,
			body        = const_body(decl),
			line        = decl.line,
			module      = module,
		})
	}
	append_fn_records(&records, ast, "bindings", module)
	append_fn_records(&records, ast, "startup", module)
	return records[:]
}

// append_fn_records appends the module fns whose KIND matches `kind`, in source-
// declaration order — the helper-fn, bindings, and startup groups of the
// [functions] order (docs/artifact-format.md §9). ast.fns is already in source
// order, so each group's relative order is preserved. An `extern fn` is skipped: it
// carries no body the runtime can interpret (its implementation is the engine's),
// so it is never an executable [functions] record. Every appended record's span
// keys to `module`.
append_fn_records :: proc(records: ^[dynamic]Function_Record, ast: Ast, kind: string, module: string) {
	for fn in ast.fns {
		if fn.is_extern {
			continue
		}
		if function_kind(fn.name) != kind {
			continue
		}
		append(records, Function_Record{
			name         = fn.name,
			kind         = kind,
			params       = fn.params,
			return_type  = fn.return_type,
			body         = fn.body,
			line         = fn.line,
			module       = module,
			holed        = fn.holed,
			has_fallback = fn.has_fallback,
			fallback     = fn.fallback,
		})
	}
}

// function_kind maps a fn name to its artifact KIND (docs/artifact-format.md
// §9): the §23 `bindings()` head is `bindings`, the §06 `setup()` Startup head
// is `startup`, every other top-level fn is a plain `fn` helper.
function_kind :: proc(name: string) -> string {
	switch name {
	case "bindings":
		return "bindings"
	case "setup":
		return "startup"
	}
	return "fn"
}

// const_body wraps a module-level `let`'s initializer as a single `return`
// statement so a const's body serializes through the same statement-subtree
// path as a fn body (docs/artifact-format.md §9: a const initializer is a single
// top-level `return` subtree, body_count 1).
const_body :: proc(decl: Let_Decl_Node) -> []Statement {
	body := make([]Statement, 1, context.temp_allocator)
	body[0] = Return_Node{value = decl.value}
	return body
}

// emit_function_record writes one [functions] record: the `function` lead line
// (name, KIND, param_count, return type, body_count, span), then the `param`
// lines and the body `node` run (§2.7). body_count is the count of top-level
// statement subtrees, one per source statement line — a §05 §2 holed record's
// body is the single `stub` subtree, so its body_count is 1 (schema v7). The
// span's module is the record's own (record.module) — the entrypoint module for
// an own record, the seam module for a §17 carried record.
emit_function_record :: proc(b: ^strings.Builder, record: Function_Record) {
	strings.write_string(b, "function ")
	strings.write_string(b, record.name)
	strings.write_byte(b, ' ')
	strings.write_string(b, record.kind)
	strings.write_byte(b, ' ')
	strings.write_int(b, len(record.params))
	strings.write_string(b, " return:")
	strings.write_string(b, type_ref_string(record.return_type))
	strings.write_byte(b, ' ')
	strings.write_int(b, executable_body_count(record.holed, record.body))
	strings.write_string(b, " span:")
	strings.write_string(b, record.module)
	strings.write_byte(b, ':')
	strings.write_int(b, record.line)
	emit_line(b, "")
	for param in record.params {
		emit_line(b, "param ", param.name, " ", type_ref_string(param.type))
	}
	emit_executable_body(b, record.holed, record.has_fallback, record.fallback, record.body)
}
