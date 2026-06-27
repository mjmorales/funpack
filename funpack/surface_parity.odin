package funpack

import "core:slice"
import "core:strings"

Surface_Model :: struct {
	module_types:          map[string]map[string]bool,
	enum_bare_variants:    map[string]map[string]bool,
	struct_variants:       map[string]map[string]bool,
	struct_variant_fields: map[string]map[string]bool,
}

new_surface_model :: proc(alloc := context.allocator) -> Surface_Model {
	return Surface_Model {
		module_types          = make(map[string]map[string]bool, alloc),
		enum_bare_variants    = make(map[string]map[string]bool, alloc),
		struct_variants       = make(map[string]map[string]bool, alloc),
		struct_variant_fields = make(map[string]map[string]bool, alloc),
	}
}

Direction :: enum {
	Docs_Ahead_Of_Compiler,
	Compiler_Ahead_Of_Docs,
}

Parity_Kind :: enum {
	Module_Type,
	Enum_Variant,
	Struct_Variant,
	Struct_Field,
}

parity_kind_label :: proc(k: Parity_Kind) -> string {
	switch k {
	case .Module_Type:
		return "module-type"
	case .Enum_Variant:
		return "enum-variant"
	case .Struct_Variant:
		return "struct-variant"
	case .Struct_Field:
		return "struct-field"
	}
	return "?"
}

Finding :: struct {
	kind:      Parity_Kind,
	direction: Direction,
	source:    string,
	symbol:    string,
}

finding_string :: proc(f: Finding, alloc := context.allocator) -> string {
	src := f.source
	if src == "" {
		src = "docs"
	}
	kind := parity_kind_label(f.kind)
	switch f.direction {
	case .Docs_Ahead_Of_Compiler:
		return strings.concatenate(
			{"[", kind, "] ", src, " advertises \"", f.symbol, "\" which the compiler dump (funpack introspect) does NOT admit"},
			alloc,
		)
	case .Compiler_Ahead_Of_Docs:
		return strings.concatenate(
			{"[", kind, "] the compiler dump admits \"", f.symbol, "\" which the docs do NOT advertise"},
			alloc,
		)
	}
	return strings.concatenate({"[", kind, "] ", src, ": \"", f.symbol, "\""}, alloc)
}

@(rodata)
EXCLUDED_SURFACE := []string {
	"free-function and value decls and their signatures (only TYPE decls are compared at module granularity)",
	"receiver/static/associated method signatures and their receiver binding",
	"combinator signatures (call-site-inferred; surfaced with a marker but not signature-compared)",
	"struct-variant field TYPES (field NAMES are compared; types are not)",
	"tuple-payload enum variants (matched structurally; the dump enumerates only bare variants)",
	"generic (type-parameterized) enums and all their variants (structurally matched; absent from the dump's enum_variants)",
}

Residual_Over_Declare :: struct {
	kind:   Parity_Kind,
	symbol: string,
	reason: string,
}

RESIDUAL_TRACKER_TASK :: "residual-fun-over-declares-vs--mqjrunkb"

@(rodata)
RESIDUAL_OVER_DECLARES := []Residual_Over_Declare {

	{.Module_Type, "engine.geom::Sketch", "vector-path geometry unimplemented in surface.odin (engine.geom)"},
	{.Module_Type, "engine.geom::Path", "vector-path geometry unimplemented in surface.odin (engine.geom)"},
	{.Module_Type, "engine.geom::PathOp", "vector-path geometry unimplemented in surface.odin (engine.geom)"},
	{.Module_Type, "engine.level::LevelHandle", "level-streaming surface unimplemented in surface.odin (engine.level)"},
	{.Module_Type, "engine.level::Load", "level-streaming surface unimplemented in surface.odin (engine.level)"},
	{.Module_Type, "engine.level::Unload", "level-streaming surface unimplemented in surface.odin (engine.level)"},
	{.Module_Type, "engine.level::Volume", "level-streaming surface unimplemented in surface.odin (engine.level)"},
	{.Module_Type, "engine.model::Shape3", "3D modeling surface unimplemented in surface.odin (engine.model)"},
	{.Module_Type, "engine.model::Anchors", "3D modeling surface unimplemented in surface.odin (engine.model)"},
	{.Module_Type, "engine.model::Length", "3D modeling surface unimplemented in surface.odin (engine.model)"},
	{.Module_Type, "engine.model::Solid", "3D modeling surface unimplemented in surface.odin (engine.model)"},
	{.Module_Type, "engine.nav3::Nav3", "3D navigation surface unimplemented in surface.odin (engine.nav3)"},
	{.Module_Type, "engine.nav3::NavError3", "3D navigation surface unimplemented in surface.odin (engine.nav3)"},
	{.Module_Type, "engine.nav3::NavHandle3", "3D navigation surface unimplemented in surface.odin (engine.nav3)"},
	{.Module_Type, "engine.nav3::Path3", "3D navigation surface unimplemented in surface.odin (engine.nav3)"},
	{.Module_Type, "engine.nav::NavHandle", "baked-nav handle type unimplemented in surface.odin (engine.nav)"},
	{.Module_Type, "engine.core::TickRate", "tick-rate config type unimplemented in surface.odin (engine.core)"},
	{.Module_Type, "engine.ui::Choice", "UI choice type unimplemented in surface.odin (engine.ui)"},
	{.Module_Type, "engine.world::Id", "world handle type unimplemented in surface.odin (engine.world)"},
	{.Module_Type, "engine.world::Owned", "world handle type unimplemented in surface.odin (engine.world)"},

	{.Struct_Variant, "Draw::Line", "vector-path draw command unimplemented in surface.odin (depends on engine.geom)"},
	{.Struct_Variant, "Draw::Fill", "vector-path draw command unimplemented in surface.odin (depends on engine.geom)"},
	{.Struct_Variant, "Draw::Stroke", "vector-path draw command unimplemented in surface.odin (depends on engine.geom)"},
}

Residual_Key :: struct {
	kind:   Parity_Kind,
	symbol: string,
}

residual_allow_set :: proc(alloc := context.allocator) -> map[Residual_Key]bool {
	set := make(map[Residual_Key]bool, len(RESIDUAL_OVER_DECLARES), alloc)
	for r in RESIDUAL_OVER_DECLARES {
		set[Residual_Key{r.kind, r.symbol}] = true
	}
	return set
}

compiler_model_from_dump :: proc(dump: Surface_Dump, alloc := context.allocator) -> Surface_Model {
	m := new_surface_model(alloc)

	owner_is_type := make(map[string]bool, alloc)
	defer delete(owner_is_type)
	for mod in dump.modules {
		types := make(map[string]bool, alloc)
		for decl in mod.decls {
			if decl.kind == .Type_Name {
				types[decl.name] = true
				owner_is_type[decl.name] = true
			}
		}
		m.module_types[mod.path] = types
	}
	for rx in dump.reexports {
		if !owner_is_type[rx.name] {
			continue
		}
		add_to_set(&m.module_types, rx.module, rx.name, alloc)
	}
	for e in dump.enum_variants {
		set := make(map[string]bool, alloc)
		for v in e.variants {
			set[v] = true
		}
		m.enum_bare_variants[e.type_name] = set
	}
	for s in dump.struct_variants {
		add_to_set(&m.struct_variants, s.type_name, s.variant, alloc)
		fields := make(map[string]bool, alloc)
		for f in s.fields {
			fields[f.name] = true
		}
		m.struct_variant_fields[strings.concatenate({s.type_name, "::", s.variant}, alloc)] = fields
	}
	return m
}

Fun_Source :: struct {
	module: string,
	text:   string,
}

parse_fun_model :: proc(sources: []Fun_Source, alloc := context.allocator) -> Surface_Model {
	m := new_surface_model(alloc)
	for src in sources {
		if src.module not_in m.module_types {
			m.module_types[src.module] = make(map[string]bool, alloc)
		}
		parse_fun_decl_source(src.text, src.module, &m, alloc)
	}
	return m
}

add_to_set :: proc(outer: ^map[string]map[string]bool, outer_key, key: string, alloc := context.allocator) {
	if outer_key not_in outer^ {
		outer[outer_key] = make(map[string]bool, alloc)
	}
	inner := &outer[outer_key]
	inner[key] = true
}

is_identifier :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	if !is_ident_start(s[0]) {
		return false
	}
	for i in 1 ..< len(s) {
		if !is_ident_char(s[i]) {
			return false
		}
	}
	return true
}

sp_scan_ident :: proc(s: string, i: int) -> (ident: string, next: int) {
	j := i
	for j < len(s) && is_ident_char(s[j]) {
		j += 1
	}
	return s[i:j], j
}

word_at :: proc(s: string, i: int, kw: string) -> bool {
	if i + len(kw) > len(s) {
		return false
	}
	if s[i:i + len(kw)] != kw {
		return false
	}
	if i > 0 && is_ident_char(s[i - 1]) {
		return false
	}
	after := i + len(kw)
	if after < len(s) && is_ident_char(s[after]) {
		return false
	}
	return true
}

skip_ws :: proc(s: string, i: int) -> int {
	j := i
	for j < len(s) && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
		j += 1
	}
	return j
}

at_line_start :: proc(s: string, i: int) -> bool {
	return i == 0 || s[i - 1] == '\n'
}

parse_fun_decl_source :: proc(text, module: string, m: ^Surface_Model, alloc := context.allocator) {
	i := 0
	for i < len(text) {
		if at_line_start(text, i) {
			head_len := 0
			if word_at(text, i, "enum") {
				head_len = len("enum")
			} else if word_at(text, i, "data") {
				head_len = len("data")
			} else if has_extern_type(text, i) {
				head_len = extern_type_len(text, i)
			}
			if head_len > 0 {
				after := skip_ws(text, i + head_len)
				if after < len(text) && is_ident_start(text[after]) {
					name, _ := sp_scan_ident(text, after)
					add_to_set(&m.module_types, module, name, alloc)
				}
			}
		}
		nl := strings.index_byte(text[i:], '\n')
		if nl < 0 {
			break
		}
		i += nl + 1
	}

	clean := strip_doc_lines(text, alloc)
	j := 0
	for j < len(clean) {
		if word_at(clean, j, "enum") {
			after := skip_ws(clean, j + len("enum"))
			if after < len(clean) && is_ident_start(clean[after]) {
				name, np := sp_scan_ident(clean, after)
				k := skip_ws(clean, np)
				generic := false
				if k < len(clean) && clean[k] == '[' {
					generic = true
					close := strings.index_byte(clean[k:], ']')
					if close < 0 {
						j = np
						continue
					}
					k = skip_ws(clean, k + close + 1)
				}
				if k < len(clean) && clean[k] == '{' {
					body_end := match_brace(clean, k)
					if body_end > k {
						if !generic {
							body := clean[k + 1:body_end]
							parse_enum_body(name, body, m, alloc)
						}
						j = body_end + 1
						continue
					}
				}
			}
			j = after
			continue
		}
		j += 1
	}
}

has_extern_type :: proc(s: string, i: int) -> bool {
	return extern_type_len(s, i) > 0
}

extern_type_len :: proc(s: string, i: int) -> int {
	if !word_at(s, i, "extern") {
		return 0
	}
	after := skip_ws(s, i + len("extern"))
	if after == i + len("extern") {
		return 0
	}
	if word_at(s, after, "type") {
		return after + len("type") - i
	}
	return 0
}

strip_doc_lines :: proc(text: string, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	i := 0
	for i < len(text) {
		if i + 5 <= len(text) && text[i:i + 5] == "@doc(" {
			nl := strings.index_byte(text[i:], '\n')
			if nl < 0 {
				break
			}
			i += nl
			continue
		}
		strings.write_byte(&b, text[i])
		i += 1
	}
	return strings.to_string(b)
}

parse_enum_body :: proc(enum_name, body: string, m: ^Surface_Model, alloc := context.allocator) {
	for variant in split_top_level(body, alloc) {
		v := strings.trim_space(variant)
		if v == "" {
			continue
		}
		if brace := strings.index_byte(v, '{'); brace >= 0 {
			vname := strings.trim_space(v[:brace])
			if vname == "" {
				continue
			}
			add_to_set(&m.struct_variants, enum_name, vname, alloc)
			fields := make(map[string]bool, alloc)
			collect_field_names(v[brace:], &fields)
			m.struct_variant_fields[strings.concatenate({enum_name, "::", vname}, alloc)] = fields
			continue
		}
		if strings.index_byte(v, '(') >= 0 {
			continue
		}
		if is_identifier(v) {
			add_to_set(&m.enum_bare_variants, enum_name, v, alloc)
		}
	}
}

collect_field_names :: proc(field_body: string, fields: ^map[string]bool) {
	i := 0
	for i < len(field_body) {
		if is_ident_start(field_body[i]) {
			name, np := sp_scan_ident(field_body, i)
			j := skip_ws(field_body, np)
			if j < len(field_body) && field_body[j] == ':' {
				fields[name] = true
			}
			i = np
			continue
		}
		i += 1
	}
}

match_brace :: proc(s: string, open_idx: int) -> int {
	depth := 0
	for i in open_idx ..< len(s) {
		switch s[i] {
		case '{':
			depth += 1
		case '}':
			depth -= 1
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

split_top_level :: proc(body: string, alloc := context.allocator) -> []string {
	parts := make([dynamic]string, 0, 8, alloc)
	depth := 0
	start := 0
	for i in 0 ..< len(body) {
		switch body[i] {
		case '{', '(':
			depth += 1
		case '}', ')':
			depth -= 1
		case ',':
			if depth == 0 {
				append(&parts, body[start:i])
				start = i + 1
			}
		}
	}
	append(&parts, body[start:])
	return parts[:]
}

known_types :: proc(m: Surface_Model, alloc := context.allocator) -> map[string]bool {
	known := make(map[string]bool, alloc)
	for _, types in m.module_types {
		for name in types {
			known[name] = true
		}
	}
	for type_name in m.enum_bare_variants {
		known[type_name] = true
	}
	for type_name in m.struct_variants {
		known[type_name] = true
	}
	return known
}

diff_variant_sets :: proc(
	doc, compiler: map[string]map[string]bool,
	kind: Parity_Kind,
	doc_source: string,
	known_compiler_types: map[string]bool,
	out: ^[dynamic]Finding,
	alloc := context.allocator,
) {
	for type_name, doc_variants in doc {
		if type_name not_in known_compiler_types {
			continue
		}
		comp_variants := compiler[type_name]
		for v in doc_variants {
			if v not_in comp_variants {
				append(out, Finding {
					kind = kind,
					direction = .Docs_Ahead_Of_Compiler,
					source = doc_source,
					symbol = strings.concatenate({type_name, "::", v}, alloc),
				})
			}
		}
	}
	for type_name, comp_variants in compiler {
		doc_variants := doc[type_name]
		for v in comp_variants {
			if v not_in doc_variants {
				append(out, Finding {
					kind = kind,
					direction = .Compiler_Ahead_Of_Docs,
					symbol = strings.concatenate({type_name, "::", v}, alloc),
				})
			}
		}
	}
}

diff_struct_fields :: proc(
	doc, compiler: Surface_Model,
	doc_source: string,
	out: ^[dynamic]Finding,
	alloc := context.allocator,
) {
	for tv, doc_fields in doc.struct_variant_fields {
		comp_fields, both := compiler.struct_variant_fields[tv]
		if !both {
			continue
		}
		for f in doc_fields {
			if f not_in comp_fields {
				append(out, Finding {
					kind = .Struct_Field,
					direction = .Docs_Ahead_Of_Compiler,
					source = doc_source,
					symbol = strings.concatenate({tv, ".", f}, alloc),
				})
			}
		}
		for f in comp_fields {
			if f not_in doc_fields {
				append(out, Finding {
					kind = .Struct_Field,
					direction = .Compiler_Ahead_Of_Docs,
					symbol = strings.concatenate({tv, ".", f}, alloc),
				})
			}
		}
	}
}

finding_less :: proc(a, b: Finding) -> bool {
	if a.kind != b.kind {
		return int(a.kind) < int(b.kind)
	}
	if a.direction != b.direction {
		return int(a.direction) < int(b.direction)
	}
	return a.symbol < b.symbol
}

diff_surfaces :: proc(doc, compiler: Surface_Model, doc_source: string, alloc := context.allocator) -> []Finding {
	findings := make([dynamic]Finding, 0, 32, alloc)

	for module, doc_types in doc.module_types {
		comp_types := compiler.module_types[module]
		for name in doc_types {
			if name not_in comp_types {
				append(&findings, Finding {
					kind = .Module_Type,
					direction = .Docs_Ahead_Of_Compiler,
					source = doc_source,
					symbol = strings.concatenate({module, "::", name}, alloc),
				})
			}
		}
	}
	for module, comp_types in compiler.module_types {
		doc_types := doc.module_types[module]
		for name in comp_types {
			if name not_in doc_types {
				append(&findings, Finding {
					kind = .Module_Type,
					direction = .Compiler_Ahead_Of_Docs,
					symbol = strings.concatenate({module, "::", name}, alloc),
				})
			}
		}
	}

	known := known_types(compiler, alloc)
	defer delete(known)

	diff_variant_sets(doc.enum_bare_variants, compiler.enum_bare_variants, .Enum_Variant, doc_source, known, &findings, alloc)
	diff_variant_sets(doc.struct_variants, compiler.struct_variants, .Struct_Variant, doc_source, known, &findings, alloc)
	diff_struct_fields(doc, compiler, doc_source, &findings, alloc)

	slice.sort_by(findings[:], finding_less)
	return findings[:]
}

blocking_findings :: proc(fun_model, compiler_model: Surface_Model, alloc := context.allocator) -> []Finding {
	allow := residual_allow_set(alloc)
	defer delete(allow)
	fun_findings := diff_surfaces(fun_model, compiler_model, ".fun", alloc)

	blocking := make([dynamic]Finding, 0, 16, alloc)
	seen := make(map[string]bool, alloc)
	defer delete(seen)
	for f in fun_findings {
		if f.direction != .Docs_Ahead_Of_Compiler {
			continue
		}
		if (Residual_Key{f.kind, f.symbol}) in allow {
			continue
		}
		dedupe := strings.concatenate(
			{parity_kind_label(f.kind), "|", finding_string(f, context.temp_allocator), "|", f.symbol, "|", f.source},
			context.temp_allocator,
		)
		if dedupe in seen {
			continue
		}
		seen[dedupe] = true
		append(&blocking, f)
	}
	slice.sort_by(blocking[:], finding_less)
	return blocking[:]
}

format_blocking_findings :: proc(blocking: []Finding, alloc := context.allocator) -> string {
	if len(blocking) == 0 {
		return ""
	}
	b := strings.builder_make(alloc)
	strings.write_string(&b, "surface-parity gate: ")
	strings.write_int(&b, len(blocking))
	strings.write_string(
		&b,
		" divergence(s) where the docs advertise surface the compiler dump (funpack introspect) does NOT admit — a same-version surface divergence:\n",
	)
	for f in blocking {
		strings.write_string(&b, "  - ")
		strings.write_string(&b, finding_string(f, alloc))
		strings.write_byte(&b, '\n')
	}
	strings.write_string(
		&b,
		"Resolve at the source: restore the symbol in surface.odin (per ADR stdlib-surface-source-of-truth-parity-restore the spec/.fun are the source of truth) and the matching runtime interpreter arm, OR (if the symbol is a deliberate cut) prune it from the .fun signature file and regenerate the corpus. ",
	)
	strings.write_string(
		&b,
		"If it is a known compiler gap, add it to RESIDUAL_OVER_DECLARES in surface_parity.odin with a WHY and the tracker task.",
	)
	return strings.to_string(b)
}
