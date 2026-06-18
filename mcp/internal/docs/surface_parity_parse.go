// Surface-parity parsers: reduce the three sources (the compiler dump, the .fun
// signature files, the docs corpus) to a common SurfaceModel for DiffSurfaces.
//
// The dump is authoritative JSON parsed directly. The .fun files and the corpus
// sections both carry the SAME funpack declaration grammar — the corpus engine
// sections are the verbatim .fun declaration text (signature + @doc) distilled by
// gencore — so they share ONE declaration parser (parseFunDeclSource), keyed off
// the module the source belongs to. There is no second grammar to keep in sync.
package docs

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// DumpSurface mirrors the `funpack introspect` JSON (funpack/surface_dump.odin
// Surface_Dump). Only the sections the parity gate compares are decoded; the
// signature/method sections are read for their NAMES but their rendered
// signature strings are intentionally not modeled (see excludedSurface).
type DumpSurface struct {
	SchemaVersion int `json:"schema_version"`
	Modules       []struct {
		Path  string `json:"path"`
		Decls []struct {
			Name string `json:"name"`
			Kind string `json:"kind"`
		} `json:"decls"`
	} `json:"modules"`
	Reexports []struct {
		Module string `json:"module"`
		Name   string `json:"name"`
		Owner  string `json:"owner"`
	} `json:"reexports"`
	EnumVariants []struct {
		TypeName string   `json:"type_name"`
		Variants []string `json:"variants"`
	} `json:"enum_variants"`
	StructVariants []struct {
		TypeName string `json:"type_name"`
		Variant  string `json:"variant"`
		Fields   []struct {
			Name string `json:"name"`
			Type string `json:"type"`
		} `json:"fields"`
	} `json:"struct_variants"`
}

// ParseDumpModel decodes the `funpack introspect` JSON into the normalized
// SurfaceModel. The dump is the AUTHORITATIVE side: its module decls, enum
// variant sets, and struct-payload variants+fields are the compiler's enforced
// surface verbatim.
func ParseDumpModel(raw []byte) (*SurfaceModel, error) {
	var d DumpSurface
	if err := json.Unmarshal(raw, &d); err != nil {
		return nil, fmt.Errorf("parse introspect dump: %w", err)
	}
	m := newSurfaceModel()
	// First pass: record each module's own Type_Name decls, and build a global
	// name -> isType index so a re-export can be classified as a type or not.
	ownerIsType := map[string]bool{}
	for _, mod := range d.Modules {
		types := map[string]bool{}
		for _, decl := range mod.Decls {
			// Only Type_Name decls are modeled at module granularity (see
			// ModuleTypes); Func/Value placement does not normalize across sources.
			if decl.Kind == "Type_Name" {
				types[decl.Name] = true
				ownerIsType[decl.Name] = true
			}
		}
		m.ModuleTypes[mod.Path] = types
	}
	// Second pass: a re-exported TYPE is genuinely importable from the
	// re-exporting module (engine.ui re-exports View from engine.world), so fold
	// it into that module's type set — otherwise a doc source that imports the
	// re-exported type reads as docs-ahead falsely. Re-exported functions/values
	// (to_fixed, map) are not types and do not affect ModuleTypes.
	for _, rx := range d.Reexports {
		if !ownerIsType[rx.Name] {
			continue
		}
		if m.ModuleTypes[rx.Module] == nil {
			m.ModuleTypes[rx.Module] = map[string]bool{}
		}
		m.ModuleTypes[rx.Module][rx.Name] = true
	}
	for _, e := range d.EnumVariants {
		set := map[string]bool{}
		for _, v := range e.Variants {
			set[v] = true
		}
		m.EnumBareVariants[e.TypeName] = set
	}
	for _, s := range d.StructVariants {
		if m.StructVariants[s.TypeName] == nil {
			m.StructVariants[s.TypeName] = map[string]bool{}
		}
		m.StructVariants[s.TypeName][s.Variant] = true
		fields := map[string]bool{}
		for _, f := range s.Fields {
			fields[f.Name] = true
		}
		m.StructVariantFields[s.TypeName+"::"+s.Variant] = fields
	}
	return m, nil
}

// FunSource is one .fun signature file: its engine.<module> path and its full
// text. The caller derives the module from the filename (input.fun ->
// engine.input) so the model's module keys match the dump's.
type FunSource struct {
	// Module is the dotted module path, e.g. "engine.input".
	Module string
	// Text is the full .fun file content.
	Text string
}

// ParseFunModel reduces the .fun signature files to the normalized model. Each
// file contributes its top-level decl names to its module, plus every enum's
// bare and struct-payload variants. Tuple-payload variants (Option::Some(T)) are
// skipped — the dump enumerates only bare variants, so comparing tuple variants
// would report every one as docs-ahead (documented in excludedSurface).
func ParseFunModel(sources []FunSource) *SurfaceModel {
	m := newSurfaceModel()
	for _, src := range sources {
		if m.ModuleTypes[src.Module] == nil {
			m.ModuleTypes[src.Module] = map[string]bool{}
		}
		parseFunDeclSource(src.Text, src.Module, m)
	}
	return m
}

// CorpusEngineModel reduces the committed corpus engine sections to the
// normalized model. Each engine Section's Title is "<module>.<DeclName>" and its
// Text is the verbatim .fun declaration (the @doc line(s) + the signature), so
// the corpus is parsed through the SAME declaration parser as the .fun files —
// keyed by the engine.<module> the section Title names. Reading the corpus from
// the embedded Load() means the gate compares what the MCP actually SERVES, not
// a re-derivation.
func CorpusEngineModel(corpus *Corpus) *SurfaceModel {
	m := newSurfaceModel()
	for _, sec := range corpus.ByKind(KindEngine) {
		module := corpusSectionModule(sec)
		if module == "" {
			continue
		}
		if m.ModuleTypes[module] == nil {
			m.ModuleTypes[module] = map[string]bool{}
		}
		parseFunDeclSource(sec.Text, module, m)
	}
	return m
}

// corpusSectionModule derives the engine.<module> path from an engine section.
// The section Title is "<module>.<DeclName>" (gencore splitEngineFile) and the
// Source is "engine/<module>.fun"; the Source is the robust key (a decl name can
// contain no dot, but a module path is the file stem). Returns "" when the
// source is not the expected engine/<module>.fun shape.
func corpusSectionModule(sec Section) string {
	src := sec.Source // "engine/<module>.fun"
	const prefix = "engine/"
	const suffix = ".fun"
	if !strings.HasPrefix(src, prefix) || !strings.HasSuffix(src, suffix) {
		return ""
	}
	module := src[len(prefix) : len(src)-len(suffix)]
	if module == "" {
		return ""
	}
	return "engine." + module
}

var (
	// funDocLineRe matches a single-line @doc("…") so it can be stripped before
	// variant tokenization (an @doc inside an enum body annotates a variant and
	// must not be mistaken for one).
	funDocLineRe = regexp.MustCompile(`@doc\([^\n]*`)
	// funTypeDeclRe matches a top-level TYPE decl head — `enum`, `extern type`, or
	// `data` and the declared name — capturing the type name. Function (`fn`,
	// `extern fn`) and value (`let`) decls are deliberately NOT matched: only type
	// names are compared at module granularity (see ModuleTypes).
	funTypeDeclRe = regexp.MustCompile(`(?m)^(?:extern\s+type|data|enum)\s+([A-Za-z_][A-Za-z0-9_]*)`)
	// funEnumHeadRe matches an enum head up to its opening brace, capturing the
	// enum name AND (group 2) the optional [T,…] generic param list. A non-empty
	// group 2 marks a GENERIC enum (Option[T], Result[T,E]) — structurally matched
	// at the call site, never enumerated in the dump's enum_variants, so its
	// variants are excluded from the comparison (see excludedSurface).
	funEnumHeadRe = regexp.MustCompile(`\benum\s+([A-Za-z_][A-Za-z0-9_]*)\s*(\[[^\]]*\])?\s*\{`)
	// funFieldRe matches one `name: Type` field inside a struct-payload variant
	// body, capturing the field NAME (the type is not modeled).
	funFieldRe = regexp.MustCompile(`([A-Za-z_][A-Za-z0-9_]*)\s*:`)
)

// parseFunDeclSource extracts the module's top-level decl names and every enum's
// variants from one funpack declaration source (a .fun file or a corpus engine
// section's text) into m. Shared by ParseFunModel and CorpusEngineModel so the
// two doc sources are parsed identically.
func parseFunDeclSource(text, module string, m *SurfaceModel) {
	// Top-level TYPE decl names. A corpus engine section carries ONE decl, a .fun
	// file carries many; the same regex covers both. Only type decls are recorded
	// (see ModuleTypes / funTypeDeclRe).
	for _, head := range funTypeDeclRe.FindAllStringSubmatch(text, -1) {
		m.ModuleTypes[module][head[1]] = true
	}
	// Enum variants. Strip single-line @doc annotations first so an annotated
	// variant inside a brace body is tokenized as the variant, not the @doc.
	clean := funDocLineRe.ReplaceAllString(text, "")
	for _, loc := range funEnumHeadRe.FindAllStringSubmatchIndex(clean, -1) {
		name := clean[loc[2]:loc[3]]
		// loc[4] >= 0 iff the generic-param group matched (Option[T]): a generic
		// enum is structurally matched and absent from the dump's enum_variants,
		// so its variants are excluded from the comparison.
		if loc[4] >= 0 {
			continue
		}
		bodyStart := loc[1] - 1 // loc[1] is just past the '{'; back up onto it
		bodyEnd := matchBrace(clean, bodyStart)
		if bodyEnd <= bodyStart {
			continue
		}
		body := clean[bodyStart+1 : bodyEnd]
		parseEnumBody(name, body, m)
	}
}

// parseEnumBody tokenizes one enum body into bare, struct-payload, and (skipped)
// tuple-payload variants, recording the bare/struct variants and struct fields
// into m. Top-level commas separate variants; a brace/paren-balanced scan keeps
// a struct body's internal commas from splitting it.
func parseEnumBody(enumName, body string, m *SurfaceModel) {
	for _, variant := range splitTopLevel(body) {
		variant = strings.TrimSpace(variant)
		if variant == "" {
			continue
		}
		// Struct-payload: `Name { f1: T, f2: T }`.
		if brace := strings.IndexByte(variant, '{'); brace >= 0 {
			vname := strings.TrimSpace(variant[:brace])
			if vname == "" {
				continue
			}
			if m.StructVariants[enumName] == nil {
				m.StructVariants[enumName] = map[string]bool{}
			}
			m.StructVariants[enumName][vname] = true
			fields := map[string]bool{}
			fieldBody := variant[brace:]
			for _, fm := range funFieldRe.FindAllStringSubmatch(fieldBody, -1) {
				fields[fm[1]] = true
			}
			m.StructVariantFields[enumName+"::"+vname] = fields
			continue
		}
		// Tuple-payload: `Name(T)` — skipped (see excludedSurface). The bare-name
		// check below would otherwise mis-record the leading identifier.
		if strings.ContainsRune(variant, '(') {
			continue
		}
		// Bare variant: a plain identifier.
		if isIdentifier(variant) {
			if m.EnumBareVariants[enumName] == nil {
				m.EnumBareVariants[enumName] = map[string]bool{}
			}
			m.EnumBareVariants[enumName][variant] = true
		}
	}
}

// matchBrace returns the index of the '}' that closes the '{' at openIdx,
// honoring nested braces. Returns -1 when unbalanced (a truncated corpus
// section). Parens are not tracked — a struct-variant field list uses braces;
// the only parens in an enum body are tuple-payload variant args, which never
// contain a brace.
func matchBrace(s string, openIdx int) int {
	depth := 0
	for i := openIdx; i < len(s); i++ {
		switch s[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// splitTopLevel splits an enum body on commas that are NOT inside a brace or
// paren group, so a struct-payload variant's internal `f: T, g: T` commas keep
// it as one token.
func splitTopLevel(body string) []string {
	var parts []string
	depth := 0
	start := 0
	for i := 0; i < len(body); i++ {
		switch body[i] {
		case '{', '(':
			depth++
		case '}', ')':
			depth--
		case ',':
			if depth == 0 {
				parts = append(parts, body[start:i])
				start = i + 1
			}
		}
	}
	parts = append(parts, body[start:])
	return parts
}

// isIdentifier reports whether s is a single bare identifier (a bare enum
// variant), rejecting anything with embedded whitespace or punctuation.
func isIdentifier(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		isAlpha := c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
		isDigit := c >= '0' && c <= '9'
		if i == 0 && !isAlpha {
			return false
		}
		if !isAlpha && !isDigit {
			return false
		}
	}
	return true
}
