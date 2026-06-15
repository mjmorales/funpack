// The .gen.fun canonical seam emitter: the pure in-memory-model → source-TEXT
// serializer that produces the @doc-headed, formatter-canonical, diffable byte
// shape every downstream authoring-source bake reuses (levels §17, assets §19,
// netcode/save seams). It takes an explicit Seam model and writes the exact
// committed-exemplar bytes — file-leading @doc, the import list, then the
// @doc-headed `data`/`extern fn` declarations in declaration order, blank-line
// separated. The byte target is the committed exemplar
// examples/arena/gen/arena.gen.fun.
//
// DISTINCT FROM emit.odin: that file is the binary artifact serializer (the
// runtime loads its bytes). This file is source TEXT a human reads and a parser
// re-ingests — the §17 schema/seam/behavior seam joins the source set and rides
// lex → parse → gates like any .fun. The two never share code: one emits the
// v1 artifact byte format, the other emits canonical funpack surface syntax.
//
// PURITY (spec §09, §29): emission is a pure function of the model. The model
// carries every layout decision explicitly (declaration order, per-record
// single-line vs aligned-multiline), so the emitter never iterates a map and
// never reads a clock, a path, or host bytes. Two emissions of the same model
// are byte-identical: the aligned-field column is a deterministic function of
// the longest field name, and every list walks in slice order.
package funpack

import "core:strings"

// Seam is the in-memory model of one .gen.fun authoring seam: the file-leading
// @doc, the ordered import list, and the ordered @doc-headed declarations. It is
// the explicit byte contract — the upstream baker (a .flvl resolver, an asset
// importer) fills this struct and the emitter renders it. Order is significant:
// imports and declarations emit in slice order, so a deterministic baker yields
// deterministic bytes.
Seam :: struct {
	// doc is the file-leading @doc string content (the text inside @doc("…"),
	// unescaped). It always heads the file; a seam without a leading doc is not
	// formatter-canonical.
	doc:          string,
	// imports are the `import <path>.{members}` lines in declaration order. The
	// first is the engine import (engine.<mod>.{…}); the rest are schema-module
	// imports (a seam imports schema modules only, §17).
	imports:      []Seam_Import,
	// declarations are the @doc-headed `data`/`extern fn` declarations in
	// declaration order — the canonical layout a downstream parser re-ingests.
	declarations: []Seam_Decl,
}

// Seam_Import is one `import <path>.{members}` line: the dotted module path and
// the brace member list, both pre-resolved by the baker to their final tokens.
Seam_Import :: struct {
	// path is the dotted module path before the brace list, e.g. "engine.world"
	// or "arena_world".
	path:    string,
	// members are the imported names in declaration order, joined with ", " in
	// the `{…}` brace list.
	members: []string,
}

// Seam_Decl is one @doc-headed top-level declaration: either a `data` record or
// an `extern fn`. The variant is the declaration kind; doc heads every one.
Seam_Decl :: struct {
	// doc is the declaration's @doc string content (text inside @doc("…")).
	doc:  string,
	// kind is the declaration body — a data record or an extern fn.
	kind: Seam_Decl_Kind,
}

// Seam_Decl_Kind is the closed set of .gen.fun declaration bodies: a `data`
// record, an `extern fn`, or a typed `let` constant. Adding a kind is a
// deliberate seam-grammar change — Seam_Let joined for the §18 §3 tilemap
// layer's TilemapHandle constant (the assets.gen.fun handle-constant mold).
Seam_Decl_Kind :: union {
	Seam_Data,
	Seam_Extern_Fn,
	Seam_Let,
}

// Seam_Data is a `data Name { … }` record. `multiline` selects the layout the
// baker chose: false emits the single-line `data Name { f: T, g: U }` form,
// true emits the aligned-multiline form (two-space indent, one field per line,
// types column-aligned). The layout is an explicit model property, not an
// inferred width heuristic, so the byte contract is stable regardless of field
// count or name length.
Seam_Data :: struct {
	name:      string,
	fields:    []Seam_Field,
	multiline: bool,
}

// Seam_Field is one `name: Type` field inside a data record. Type carries the
// final rendered type token (e.g. "Ref[Player]", "[Spawn]", "ArenaTurret").
Seam_Field :: struct {
	name: string,
	type: string,
}

// Seam_Extern_Fn is an `extern fn name() -> RetType` declaration: the seam's
// symbol-table and spawn-list accessors the behavior module calls.
Seam_Extern_Fn :: struct {
	name:        string,
	return_type: string,
}

// Seam_Let is a `let name: Type = value` module-level constant — the typed
// handle constant a bake binds (the §19 asset seam's `let dungeon:
// TilesetHandle = TilesetHandle{name: "dungeon"}` mold; the §18 §3 level
// seam's TilemapHandle layer constant). value carries the final rendered
// initializer token, pre-resolved by the baker.
Seam_Let :: struct {
	name:  string,
	type:  string,
	value: string,
}

// emit_gen_fun renders a Seam to canonical .gen.fun source bytes, matching the
// committed exemplar byte-for-byte. Layout: the file-leading @doc line, then the
// import block, then each @doc-headed declaration, with a single blank line
// separating the import block from the first declaration and between every
// adjacent declaration. The output ends in exactly one trailing newline. The
// returned string is allocated in `allocator`.
emit_gen_fun :: proc(seam: Seam, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	emit_seam_doc(&b, seam.doc)
	for imp in seam.imports {
		emit_seam_import(&b, imp)
	}
	for decl in seam.declarations {
		// Blank line before every declaration — the same separator the import
		// block gets, so the first declaration is offset from the imports and
		// every adjacent pair is offset from each other.
		strings.write_string(&b, "\n")
		emit_seam_decl(&b, decl)
	}
	return strings.to_string(b)
}

// emit_seam_doc writes one `@doc("…")` line. The content is written verbatim
// (the baker pre-escapes any embedded quote/backslash), matching the exemplar's
// single-line doc form.
emit_seam_doc :: proc(b: ^strings.Builder, doc: string) {
	strings.write_string(b, "@doc(\"")
	strings.write_string(b, doc)
	strings.write_string(b, "\")\n")
}

// emit_seam_import writes one `import <path>.{m0, m1, …}` line: the dotted path,
// then the brace member list joined with ", ".
emit_seam_import :: proc(b: ^strings.Builder, imp: Seam_Import) {
	strings.write_string(b, "import ")
	strings.write_string(b, imp.path)
	strings.write_string(b, ".{")
	for member, i in imp.members {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, member)
	}
	strings.write_string(b, "}\n")
}

// emit_seam_decl writes one @doc-headed declaration: the doc line, then the
// data record or extern fn body per its kind.
emit_seam_decl :: proc(b: ^strings.Builder, decl: Seam_Decl) {
	emit_seam_doc(b, decl.doc)
	switch body in decl.kind {
	case Seam_Data:
		emit_seam_data(b, body)
	case Seam_Extern_Fn:
		emit_seam_extern_fn(b, body)
	case Seam_Let:
		emit_seam_let(b, body)
	}
}

// emit_seam_let writes `let name: Type = value` on one line — the typed handle
// constant a bake binds (the assets/tilemap handle mold).
emit_seam_let :: proc(b: ^strings.Builder, decl: Seam_Let) {
	strings.write_string(b, "let ")
	strings.write_string(b, decl.name)
	strings.write_string(b, ": ")
	strings.write_string(b, decl.type)
	strings.write_string(b, " = ")
	strings.write_string(b, decl.value)
	strings.write_string(b, "\n")
}

// emit_seam_data writes a `data` record in the layout its `multiline` flag
// selects: the single-line `data Name { f: T, g: U }` form, or the
// aligned-multiline form (two-space indent, one field per line, the type column
// aligned to the longest field name).
emit_seam_data :: proc(b: ^strings.Builder, data: Seam_Data) {
	if data.multiline {
		emit_seam_data_multiline(b, data)
	} else {
		emit_seam_data_inline(b, data)
	}
}

// emit_seam_data_inline writes `data Name { f: T, g: U }` on one line — fields
// comma-and-space separated, a single space inside each brace.
emit_seam_data_inline :: proc(b: ^strings.Builder, data: Seam_Data) {
	strings.write_string(b, "data ")
	strings.write_string(b, data.name)
	strings.write_string(b, " { ")
	for field, i in data.fields {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		strings.write_string(b, field.type)
	}
	strings.write_string(b, " }\n")
}

// emit_seam_data_multiline writes the aligned-multiline record: `data Name {` on
// its own line, then each field two-space indented as `name:<pad>Type` with the
// type column aligned to the longest field name, then a `}` on its own line. The
// pad after a field's colon is (longest_name_len - this_name_len + 1) spaces, so
// every type starts at the same column (two-space indent + longest name + one
// space).
emit_seam_data_multiline :: proc(b: ^strings.Builder, data: Seam_Data) {
	strings.write_string(b, "data ")
	strings.write_string(b, data.name)
	strings.write_string(b, " {\n")
	longest := longest_field_name_len(data.fields)
	for field in data.fields {
		strings.write_string(b, "  ")
		strings.write_string(b, field.name)
		strings.write_string(b, ":")
		// One space minimum after the colon, plus padding so this field's type
		// starts at the longest-name column.
		pad := longest - len(field.name) + 1
		for _ in 0 ..< pad {
			strings.write_string(b, " ")
		}
		strings.write_string(b, field.type)
		strings.write_string(b, "\n")
	}
	strings.write_string(b, "}\n")
}

// longest_field_name_len returns the byte length of the longest field name, the
// alignment anchor for the multiline data layout. Zero for an empty record.
longest_field_name_len :: proc(fields: []Seam_Field) -> int {
	longest := 0
	for field in fields {
		if len(field.name) > longest {
			longest = len(field.name)
		}
	}
	return longest
}

// emit_seam_extern_fn writes `extern fn name() -> RetType` on one line — the
// seam's no-arg symbol-table/spawn-list accessors.
emit_seam_extern_fn :: proc(b: ^strings.Builder, fn: Seam_Extern_Fn) {
	strings.write_string(b, "extern fn ")
	strings.write_string(b, fn.name)
	strings.write_string(b, "() -> ")
	strings.write_string(b, fn.return_type)
	strings.write_string(b, "\n")
}
