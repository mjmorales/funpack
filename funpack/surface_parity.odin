// Surface-parity gate — lives in the SDL-free `funpack` compiler package that
// already OWNS the surface dump (surface_dump.odin) and reads the
// stdlib/engine/*.fun signature files from disk (golden_fmt_test.odin).
//
// THE DRIFT CLASS THIS CATCHES. The version-string corpus-pin check compares
// VERSION STRINGS and content hashes of the committed corpus against a regen of
// the same .fun/spec sources. It is structurally blind to an INTERNAL
// .fun-vs-compiler divergence at the SAME version: the docs/.fun and the
// compiler can both report the same version, yet the compiler's typecheck
// allow-list (surface.odin) rejects surface the stdlib/engine/*.fun signature
// files advertise — code written exactly to the documented surface fails to
// compile. No version comparison can see that. This gate is the content-level
// check the version check cannot be: it diffs the .fun signature files against
// the compiler's AUTHORITATIVE surface dump and fails on a divergence, naming
// the diverging symbol and its direction.
//
// THE SOURCE OF TRUTH. Per ADR stdlib-surface-source-of-truth-parity-restore the
// spec and the .fun signature files ARE the source of truth; surface.odin must
// conform. The HARMFUL direction is therefore "the .fun advertise X that the
// compiler dump LACKS" — an author reads X in the docs, writes it, and the
// compiler rejects it (the canonical break: a documented Color-palette member
// the compiler rejects). The OTHER direction (the dump recognizes X that no .fun
// advertises) is a softer drift — a usable surface that is undocumented — and is
// reported too, so an undocumented compiler surface is also visible.
//
// THE GRANULARITY. The two sources render full signature strings differently
// (`extern fn count(self: View[T]) -> Int` in .fun, `fn(_) -> Int` in the dump),
// so a byte-for-byte signature comparison would be all false positives. The gate
// compares at the granularity where drift is MEANINGFUL and the two
// representations normalize to a common key: per-module declared NAMES, enum
// BARE-VARIANT SETS (the Color palette is the canonical example), and struct-payload
// VARIANT names plus their FIELD names (Color::Rgb{r,g,b}). Free-function and
// receiver-method SIGNATURE TEXT is intentionally out of scope (documented in
// EXCLUDED_SURFACE).
//
// HOW IT SOURCES THE DUMP. The gate runs INSIDE the toolchain: the compiler model
// is built LIVE in-memory from build_surface_dump() (surface_dump.odin) — no JSON
// fixture, no temp build, no introspect subprocess, no serialize/deserialize hop.
// Diffing the in-memory tables directly (no wire round-trip) is strictly more
// faithful than diffing a committed dump fixture, and needs no freshness-pin to
// keep a fixture in step with the compiler.
//
// THE CORPUS ARM. Surface drift has two doc sources (the .fun files AND the docs
// corpus). The corpus lives in the FUNPACK_LIVE cmd subtree, unreachable from this
// SDL-free package; corpus↔.fun drift is covered separately by the corpus-pin test
// (regenerate-through-the-same-extractor + byte-compare), since the corpus engine
// sections are VERBATIM .fun declaration text parsed by the IDENTICAL grammar. So
// this gate runs the .fun arm only — the two together cover both doc sources with
// no redundant second parse.
//
// ODIN-FIRST NOTE. core:text/regex covers the four .fun head-match patterns
// (Multiline anchor, optional capture group, word boundaries — all supported). A
// hand-rolled scanner is used instead because the brace-balanced split/match scans
// are already pure index scans needing no regex, the funpack package's
// lexer/parser are themselves hand-rolled index scans (the idiom), and a scanner
// avoids a per-call regex-VM allocation — keeping the gate a deterministic pure
// walk like the dump it diffs.
package funpack

import "core:slice"
import "core:strings"

// Surface_Model is the normalized, source-agnostic projection of an engine
// surface that the two sources (the compiler dump, the .fun signature files) are
// each reduced to so they can be diffed on a common key. Every field is a
// deterministic set keyed by name — no signature strings, no source-specific
// spelling — so equality is meaningful across the two.
Surface_Model :: struct {
	// module_types maps a dotted module path (engine.render) to the set of TYPE
	// names it declares (Draw, Color, Flip, Align, Font). ONLY type declarations
	// (the dump's .Type_Name kind; the .fun's enum/extern type/data) are modeled
	// here — NOT free functions or values. Type names normalize 1:1 across both
	// sources, whereas a function's PLACEMENT differs structurally between them:
	// the dump splits free functions from receiver/static/associated methods,
	// while a .fun file declares both as top-level `extern fn`. Diffing function
	// names at module-decl granularity is therefore all false positives. Function/
	// value parity is in EXCLUDED_SURFACE; the divergence-relevant signal at this
	// granularity is TYPE presence (Font/Shape3/Volume/PathOp are the residuals).
	module_types:          map[string]map[string]bool,
	// enum_bare_variants maps an enum type name (Color) to its set of bare (no
	// payload) variant names (White, Black, …). The canonical Color-palette example.
	enum_bare_variants:    map[string]map[string]bool,
	// struct_variants maps an enum type name (Color) to the set of its
	// struct-payload variant names (Rgb). Draw -> {Rect, Text, Camera, Sprite}.
	struct_variants:       map[string]map[string]bool,
	// struct_variant_fields maps "Type::Variant" (Color::Rgb) to the set of its
	// field names (r, g, b). Field TYPES are not compared (the two sources spell
	// types differently); field NAMES normalize cleanly.
	struct_variant_fields: map[string]map[string]bool,
}

// new_surface_model returns a model with all four sets allocated on alloc. The
// caller owns the maps and the per-key inner maps (built lazily as symbols land).
new_surface_model :: proc(alloc := context.allocator) -> Surface_Model {
	return Surface_Model {
		module_types          = make(map[string]map[string]bool, alloc),
		enum_bare_variants    = make(map[string]map[string]bool, alloc),
		struct_variants       = make(map[string]map[string]bool, alloc),
		struct_variant_fields = make(map[string]map[string]bool, alloc),
	}
}

// Direction names which side of a parity diff advertises a symbol the other
// lacks. A closed enum so a finding's direction is exhaustively switchable.
Direction :: enum {
	// Docs_Ahead_Of_Compiler is the HARMFUL direction of a same-version surface
	// divergence: a .fun signature file advertises a symbol the compiler dump does
	// NOT admit. An author writes the documented symbol and the compiler rejects it.
	Docs_Ahead_Of_Compiler,
	// Compiler_Ahead_Of_Docs is the softer direction: the compiler dump admits a
	// symbol no .fun advertises — a usable but undocumented surface.
	Compiler_Ahead_Of_Docs,
}

// Parity_Kind names the surface granularity a finding is at — the closed set of
// comparison axes (module decl, enum bare variant, struct variant, struct field).
Parity_Kind :: enum {
	Module_Type,
	Enum_Variant,
	Struct_Variant,
	Struct_Field,
}

// parity_kind_label renders a Parity_Kind as a stable lower-kebab token used in
// finding messages and (kind, symbol) sort order, so the failure text and any
// assertion read deterministically.
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

// Finding is one named parity divergence: WHAT diverged (the symbol), at WHICH
// granularity, in WHICH direction, and from WHICH doc source (the .fun files). It
// carries everything the failure message needs to be actionable without
// re-deriving it — a future same-version surface divergence is named here, not
// discovered at a call site.
Finding :: struct {
	kind:      Parity_Kind,
	// direction is which side is ahead (see Direction).
	direction: Direction,
	// source is the doc-side source that produced this finding: ".fun". Empty for a
	// compiler-ahead finding (the doc side is what's missing).
	source:    string,
	// symbol is the fully-qualified diverging symbol, e.g. "engine.render::Align"
	// (module decl), "Color::Yellow" (enum variant), "Draw::Line" (struct variant),
	// "Color::Rgb.r" (struct field).
	symbol:    string,
}

// finding_string renders one finding as the actionable line the failure message
// prints.
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

// EXCLUDED_SURFACE documents the surface the gate intentionally does NOT compare,
// each with a one-line WHY so the exclusion is auditable rather than a silent
// hole. These are NOT divergences — they are comparison axes deliberately left
// out because the two sources cannot normalize to a common key there.
@(rodata)
EXCLUDED_SURFACE := []string {
	// Free-FUNCTION and VALUE decls (engine.math.clamp/pi, engine.ui.button): NOT
	// compared at the module-decl granularity at all — and not by signature. The
	// dump splits free functions from receiver/static/associated methods, while a
	// .fun file declares both as top-level `extern fn`; so a function-name diff at
	// module granularity reports every receiver method (Input.pressed, View.count,
	// Sound.gain) as docs-ahead. Only TYPE decls (enum/extern type/data <->
	// Type_Name) normalize 1:1 across both sources, so only types are compared at
	// module granularity (see module_types). Function PRESENCE is implicitly covered
	// where a function returns/consumes a compared type; its rendered SIGNATURE is
	// never compared (that would mean re-implementing the compiler's type printer).
	"free-function and value decls and their signatures (only TYPE decls are compared at module granularity)",
	// Receiver/static/associated method signatures (View.count, Sound.gain): same
	// spelling mismatch as free functions, plus the dump keys methods off a receiver
	// type the .fun expresses as a `self:` parameter. Method NAMES are not in the
	// doc-side model, so receiver-method parity is out of scope until a method-aware
	// doc projection exists.
	"receiver/static/associated method signatures and their receiver binding",
	// Combinator typing (engine.list.fold/map/filter, prelude.or_else): the dump
	// OMITS these from `signatures` entirely (surface_signatures returns found =
	// false) because their type is inferred at the call site, not fixed. There is no
	// signature to compare, by the compiler's own design.
	"combinator signatures (call-site-inferred; the dump omits them by design)",
	// Field TYPES of struct-payload variants (Color::Rgb.r: Fixed): the dump renders
	// the checker Type, the .fun renders the surface type token; field NAMES
	// normalize cleanly and ARE compared, field types are not (same type-printer-
	// parity problem as signatures).
	"struct-variant field TYPES (field NAMES are compared; types are not)",
	// Tuple-payload enum variants (a non-generic enum's `Name(T)` variant): the
	// dump's enum_variants section carries only BARE variants; a tuple-payload
	// variant is matched structurally at the call site, not enumerated in a probe
	// table. Comparing them would report every tuple variant as docs-ahead.
	"tuple-payload enum variants (matched structurally; the dump enumerates only bare variants)",
	// GENERIC enums (Option[T], Result[T,E]) wholesale: the dump never enumerates a
	// generic enum's variants in enum_variants (they are structurally matched, so
	// Option::None / Result::Ok have no probe-table row). The whole enum is excluded
	// — its variants are not compared in either direction.
	"generic (type-parameterized) enums and all their variants (structurally matched; absent from the dump's enum_variants)",
}

// Residual_Over_Declare is one allow-listed known-residual over-declaration: a
// symbol the .fun advertises that the compiler dump does NOT yet admit on the
// clean tree, BUT which is a tracked compiler GAP rather than a fresh regression.
// Each carries the WHY and (shared) tracker so the hole is audited, not silent.
Residual_Over_Declare :: struct {
	// kind/symbol match a Finding's kind/symbol exactly — the allow-list is keyed
	// by (kind, symbol).
	kind:   Parity_Kind,
	symbol: string,
	// reason is the one-line WHY this over-declaration is currently expected.
	reason: string,
}

// RESIDUAL_TRACKER_TASK is the scrum task that owns shrinking the allow-list as
// each residual surface is restored in surface.odin. Named here (not embedded
// per-entry) because every entry shares it: the residuals are one class of
// compiler gap, tracked as one cross-team reconciliation task.
RESIDUAL_TRACKER_TASK :: "residual-fun-over-declares-vs--mqjrunkb"

// RESIDUAL_OVER_DECLARES is the EXPLICIT, AUDITED allow-list of known .fun
// over-declarations the compiler dump does not yet admit on the clean tree. The
// gate passes a Docs_Ahead_Of_Compiler finding ONLY if it is listed here; any
// over-declaration NOT on this list is a fresh same-version surface divergence
// and FAILS the gate, named. Per ADR stdlib-surface-source-of-truth-parity-restore
// each entry is a compiler GAP to be restored (or a deliberate prune) at the
// source — tracked by RESIDUAL_TRACKER_TASK. As a restore lands, the dump grows
// to admit the symbol and the matching entry MUST be removed; the no-stale test
// (test_no_stale_residual_allow_list_entry) asserts every allow-listed symbol is
// still a live divergence, so a stale entry fails loud rather than masking a real
// divergence.
//
// SCOPE NOTE: these residuals live in surface.odin and the runtime interpreter;
// devtools owns only the gate that makes them visible. The list is the inventory
// the tracker task drains.
@(rodata)
RESIDUAL_OVER_DECLARES := []Residual_Over_Declare {
	// --- Whole-type gaps: a type the .fun/spec declares that the compiler does not
	// recognize at all (absent from the dump). Each is one .Module_Type entry; the
	// type's variants are SUBSUMED (not separately allow-listed) by the
	// variant-finding subsumption in diff_surfaces. Restoring the type's wiring in
	// surface.odin removes the entry.

	// render.fun declares Font (extern type) which is not in the compiler's
	// engine.render type decls. (Align is now admitted — readmitted by story
	// mechanical-variant-readmit — so it left this list.)
	{.Module_Type, "engine.render::Font", "extern Font type unimplemented in surface.odin"},
	// geom.fun's §03 vector-path geometry (Sketch builder + Path/PathOp) is wholly
	// unimplemented; Draw::Fill/Stroke (which name a Sketch) are the dependent render
	// gap below.
	{.Module_Type, "engine.geom::Sketch", "vector-path geometry unimplemented in surface.odin (engine.geom)"},
	{.Module_Type, "engine.geom::Path", "vector-path geometry unimplemented in surface.odin (engine.geom)"},
	{.Module_Type, "engine.geom::PathOp", "vector-path geometry unimplemented in surface.odin (engine.geom)"},
	// level.fun's §-level streaming surface (LevelHandle + Load/Unload outcomes +
	// trigger Volume) is wholly unimplemented in surface.odin.
	{.Module_Type, "engine.level::LevelHandle", "level-streaming surface unimplemented in surface.odin (engine.level)"},
	{.Module_Type, "engine.level::Load", "level-streaming surface unimplemented in surface.odin (engine.level)"},
	{.Module_Type, "engine.level::Unload", "level-streaming surface unimplemented in surface.odin (engine.level)"},
	{.Module_Type, "engine.level::Volume", "level-streaming surface unimplemented in surface.odin (engine.level)"},
	// model.fun's 3D modeling surface (Shape3 collision + the Anchors/Length/Solid
	// rig data) is wholly unimplemented in surface.odin.
	{.Module_Type, "engine.model::Shape3", "3D modeling surface unimplemented in surface.odin (engine.model)"},
	{.Module_Type, "engine.model::Anchors", "3D modeling surface unimplemented in surface.odin (engine.model)"},
	{.Module_Type, "engine.model::Length", "3D modeling surface unimplemented in surface.odin (engine.model)"},
	{.Module_Type, "engine.model::Solid", "3D modeling surface unimplemented in surface.odin (engine.model)"},
	// nav3.fun's whole 3D navigation surface is unimplemented (the 2D engine.nav IS
	// implemented); engine.nav's NavHandle handle type is also not in the dump.
	{.Module_Type, "engine.nav3::Nav3", "3D navigation surface unimplemented in surface.odin (engine.nav3)"},
	{.Module_Type, "engine.nav3::NavError3", "3D navigation surface unimplemented in surface.odin (engine.nav3)"},
	{.Module_Type, "engine.nav3::NavHandle3", "3D navigation surface unimplemented in surface.odin (engine.nav3)"},
	{.Module_Type, "engine.nav3::Path3", "3D navigation surface unimplemented in surface.odin (engine.nav3)"},
	{.Module_Type, "engine.nav::NavHandle", "baked-nav handle type unimplemented in surface.odin (engine.nav)"},
	// core.fun's TickRate config type is declared but not admitted.
	{.Module_Type, "engine.core::TickRate", "tick-rate config type unimplemented in surface.odin (engine.core)"},
	// ui.fun's Choice type is declared but not admitted.
	{.Module_Type, "engine.ui::Choice", "UI choice type unimplemented in surface.odin (engine.ui)"},
	// world.fun's Id/Owned handle types are declared but not admitted (the
	// implemented world surface is View/Ref/Spawn/Despawn).
	{.Module_Type, "engine.world::Id", "world handle type unimplemented in surface.odin (engine.world)"},
	{.Module_Type, "engine.world::Owned", "world handle type unimplemented in surface.odin (engine.world)"},

	// --- Per-variant gaps: a type the compiler DOES recognize, but missing specific
	// variants the .fun/spec declares. These are NOT subsumed (the type exists), so
	// each missing variant is allow-listed individually.

	// render.fun declares the full §20 Draw command set; the compiler admits only
	// Rect/Text/Camera/Sprite. Line/Fill/Stroke (the vector-path commands, which
	// name a geom Sketch) are unimplemented in surface.odin's struct_payload arms.
	{.Struct_Variant, "Draw::Line", "vector-path draw command unimplemented in surface.odin (depends on engine.geom)"},
	{.Struct_Variant, "Draw::Fill", "vector-path draw command unimplemented in surface.odin (depends on engine.geom)"},
	{.Struct_Variant, "Draw::Stroke", "vector-path draw command unimplemented in surface.odin (depends on engine.geom)"},
	// NOTE: the full physical-key alphabet (Key:: B,C,E–L,N–V,X,Y,Z + Escape/Shift/
	// Tab), both extra local-player slots (PlayerId::P3/P4), and the full skeletal
	// Bone/Slot taxonomy (named joints + numbered Joint0–7 / Slot0–3) were all
	// readmitted into surface.odin by story mechanical-variant-readmit, so they are
	// now in parity and left this list. Only the feature-subsystem gaps above
	// (vector-path Draw commands, and the whole-type render/geom/level/model/nav3/
	// nav/core/ui/world subsystems) remain residual.
}

// Residual_Key is the (kind, symbol) lookup key the allow-list is matched on.
Residual_Key :: struct {
	kind:   Parity_Kind,
	symbol: string,
}

// residual_allow_set builds the allow-list as a set for O(1) finding suppression.
// The set is allocated on alloc; the caller owns it.
residual_allow_set :: proc(alloc := context.allocator) -> map[Residual_Key]bool {
	set := make(map[Residual_Key]bool, len(RESIDUAL_OVER_DECLARES), alloc)
	for r in RESIDUAL_OVER_DECLARES {
		set[Residual_Key{r.kind, r.symbol}] = true
	}
	return set
}

// compiler_model_from_dump builds the authoritative Surface_Model directly from
// the LIVE build_surface_dump() struct — no JSON round-trip. The dump is the
// AUTHORITATIVE side: its module decls, enum variant sets, and struct-payload
// variants+fields are the compiler's enforced surface verbatim. Allocated on alloc.
//
// Two-pass module-type folding: pass one records each module's own .Type_Name
// decls and a global name->isType index; pass two folds a re-exported TYPE into
// the re-exporting module's type set (engine.ui re-exports View from
// engine.world) — otherwise a .fun that imports the re-exported type reads as
// docs-ahead falsely. Re-exported functions/values are not types and do not
// affect module_types.
compiler_model_from_dump :: proc(dump: Surface_Dump, alloc := context.allocator) -> Surface_Model {
	m := new_surface_model(alloc)

	owner_is_type := make(map[string]bool, alloc)
	defer delete(owner_is_type)
	for mod in dump.modules {
		types := make(map[string]bool, alloc)
		for decl in mod.decls {
			// Only .Type_Name decls are modeled at module granularity (see
			// module_types); .Func/.Value placement does not normalize across sources.
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

// Fun_Source is one .fun signature file: its engine.<module> path and its full
// text. The caller derives the module from the filename (input.fun ->
// engine.input) so the model's module keys match the dump's.
Fun_Source :: struct {
	module: string,
	text:   string,
}

// parse_fun_model reduces the .fun signature files to the normalized model. Each
// file contributes its top-level type-decl names to its module, plus every enum's
// bare and struct-payload variants. Tuple-payload variants (Option::Some(T)) are
// skipped — the dump enumerates only bare variants, so comparing tuple variants
// would report every one as docs-ahead (documented in EXCLUDED_SURFACE).
// Allocated on alloc; building fresh maps each call means the result is an
// independent copy (the deep-clone the synthetic-injection negative control needs).
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

// add_to_set inserts key into the inner set at outer[outer_key], creating the
// inner map lazily. A free proc because Odin map-index yields a COPY, so a nested
// `outer[k1][k2] = true` cannot mutate in place — the inner map must be taken by
// pointer (&outer[k1]) and written through.
add_to_set :: proc(outer: ^map[string]map[string]bool, outer_key, key: string, alloc := context.allocator) {
	if outer_key not_in outer^ {
		outer[outer_key] = make(map[string]bool, alloc)
	}
	inner := &outer[outer_key]
	inner[key] = true
}

// is_identifier reports whether s is a single bare identifier (a bare enum
// variant), rejecting anything with embedded whitespace or punctuation.
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

// sp_scan_ident reads the identifier starting at i (i must be at an identifier-
// start byte) and returns its text plus the index just past it. Named distinctly
// from the lexer's scan_ident (which tokenizes and would classify keywords) — the
// parity scan wants raw decl/variant/field name text, not a Token.
sp_scan_ident :: proc(s: string, i: int) -> (ident: string, next: int) {
	j := i
	for j < len(s) && is_ident_char(s[j]) {
		j += 1
	}
	return s[i:j], j
}

// word_at reports whether the keyword `kw` occurs at index i with a word boundary
// on both sides (so `enumerate` does not match `enum`) — the `\b` anchor done as
// a pure index check.
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

// skip_ws returns the index of the first non-whitespace byte at or after i.
skip_ws :: proc(s: string, i: int) -> int {
	j := i
	for j < len(s) && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
		j += 1
	}
	return j
}

// at_line_start reports whether index i begins a line (i == 0 or the prior byte
// is a newline) — the (?m)^ anchor used to find top-level type decl heads.
at_line_start :: proc(s: string, i: int) -> bool {
	return i == 0 || s[i - 1] == '\n'
}

// parse_fun_decl_source extracts the module's top-level TYPE decl names and every
// enum's variants from one funpack declaration source into m. A hand-rolled scan
// stands in for the four .fun head-match patterns (see the package ODIN-FIRST NOTE
// for why a scanner over regex).
parse_fun_decl_source :: proc(text, module: string, m: ^Surface_Model, alloc := context.allocator) {
	// Pass A: top-level TYPE decl heads (`^(extern type|data|enum) Name`), line
	// anchored at (?m)^. Only TYPE decls are recorded (see module_types); fn/let
	// are not matched.
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
		// Advance to the next line start.
		nl := strings.index_byte(text[i:], '\n')
		if nl < 0 {
			break
		}
		i += nl + 1
	}

	// Pass B: enum bodies. Strip single-line @doc(...) annotations first so an
	// annotated variant inside a brace body is tokenized as the variant, not the
	// @doc. Then scan every `enum Name [..]? {` head; a
	// non-empty generic-param list marks a GENERIC enum, whose variants are excluded
	// (structurally matched, absent from the dump's enum_variants).
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

// has_extern_type reports whether `extern` + whitespace + `type` begins at i (the
// `extern\s+type` head).
has_extern_type :: proc(s: string, i: int) -> bool {
	return extern_type_len(s, i) > 0
}

// extern_type_len returns the byte length of an `extern <ws> type` head at i (so
// the caller can skip past it to the type name), or 0 when it is not that head.
extern_type_len :: proc(s: string, i: int) -> int {
	if !word_at(s, i, "extern") {
		return 0
	}
	after := skip_ws(s, i + len("extern"))
	if after == i + len("extern") {
		return 0 // `extern` must be followed by whitespace before `type`
	}
	if word_at(s, after, "type") {
		return after + len("type") - i
	}
	return 0
}

// strip_doc_lines removes every single-line `@doc(...)` annotation (to end of
// line) so enum-body tokenization does not mistake a variant's @doc for a
// variant — the `@doc\([^\n]*` strip. Allocated on alloc.
strip_doc_lines :: proc(text: string, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	i := 0
	for i < len(text) {
		if i + 5 <= len(text) && text[i:i + 5] == "@doc(" {
			// Drop to end of line (the [^\n]* of the regex).
			nl := strings.index_byte(text[i:], '\n')
			if nl < 0 {
				break
			}
			i += nl // keep the newline so line structure is preserved
			continue
		}
		strings.write_byte(&b, text[i])
		i += 1
	}
	return strings.to_string(b)
}

// parse_enum_body tokenizes one enum body into bare, struct-payload, and (skipped)
// tuple-payload variants, recording the bare/struct variants and struct fields
// into m. Top-level commas separate variants; a brace/paren-balanced scan keeps a
// struct body's internal commas from splitting it.
parse_enum_body :: proc(enum_name, body: string, m: ^Surface_Model, alloc := context.allocator) {
	for variant in split_top_level(body, alloc) {
		v := strings.trim_space(variant)
		if v == "" {
			continue
		}
		// Struct-payload: `Name { f1: T, f2: T }`.
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
		// Tuple-payload: `Name(T)` — skipped (see EXCLUDED_SURFACE). The bare-name
		// check below would otherwise mis-record the leading identifier.
		if strings.index_byte(v, '(') >= 0 {
			continue
		}
		// Bare variant: a plain identifier.
		if is_identifier(v) {
			add_to_set(&m.enum_bare_variants, enum_name, v, alloc)
		}
	}
}

// collect_field_names records every `name:` field NAME in a struct-variant field
// body into fields (the `([A-Za-z_]\w*)\s*:` capture). Field types are not modeled
// (see EXCLUDED_SURFACE).
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

// match_brace returns the index of the '}' that closes the '{' at open_idx,
// honoring nested braces. Returns -1 when unbalanced (a truncated source). Parens
// are not tracked — a struct-variant field list uses braces; the only parens in an
// enum body are tuple-payload variant args, which never contain a brace.
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

// split_top_level splits an enum body on commas that are NOT inside a brace or
// paren group, so a struct-payload variant's internal `f: T, g: T` commas keep it
// as one token. Allocated on alloc.
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

// known_types returns the set of type names the compiler recognizes anywhere — a
// module type decl, an enum with variants, or a struct-payload owner. Used to
// subsume a docs-ahead variant finding under its type-level finding when the
// compiler does not know the type at all. Allocated on alloc.
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

// diff_variant_sets diffs two type-name -> variant-name-set maps symmetrically,
// emitting one finding per variant ("Color::Yellow") that one side has and the
// other lacks. A docs-ahead variant whose type is NOT in known_compiler_types is
// suppressed — the type-level .Module_Type finding subsumes it.
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
			continue // subsumed by the type-level finding
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

// diff_struct_fields diffs the field-name sets of struct-payload variants present
// in BOTH models, so the comparison reports a field add/drop (Color::Rgb gaining
// or losing a channel) on a variant the two sides agree exists. A variant only one
// side has is already reported at .Struct_Variant; its fields are not re-diffed.
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

// finding_less orders findings deterministically by (kind, direction, symbol) so a
// failure message and any test assertion are stable across runs.
finding_less :: proc(a, b: Finding) -> bool {
	if a.kind != b.kind {
		return int(a.kind) < int(b.kind)
	}
	if a.direction != b.direction {
		return int(a.direction) < int(b.direction)
	}
	return a.symbol < b.symbol
}

// diff_surfaces compares a documentation-side model (the .fun files) against the
// authoritative compiler model and returns every divergence as a Finding, in
// deterministic (kind, direction, symbol)-sorted order. doc_source labels the doc
// side (".fun") on each docs-ahead finding. The diff is symmetric: a symbol the
// docs advertise that the compiler lacks is .Docs_Ahead_Of_Compiler; a symbol the
// compiler admits that the docs lack is .Compiler_Ahead_Of_Docs. Allow-list
// suppression is NOT applied here — that is blocking_findings's job, so a caller
// can inspect the full unfiltered drift. Allocated on alloc.
diff_surfaces :: proc(doc, compiler: Surface_Model, doc_source: string, alloc := context.allocator) -> []Finding {
	findings := make([dynamic]Finding, 0, 32, alloc)

	// Module TYPE decls (.Type_Name only — see module_types).
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

	// known is the set of type names the compiler recognizes AT ALL. A docs-ahead
	// VARIANT finding for a type the compiler does not know is SUBSUMED by the
	// type-level finding.
	known := known_types(compiler, alloc)
	defer delete(known)

	diff_variant_sets(doc.enum_bare_variants, compiler.enum_bare_variants, .Enum_Variant, doc_source, known, &findings, alloc)
	diff_variant_sets(doc.struct_variants, compiler.struct_variants, .Struct_Variant, doc_source, known, &findings, alloc)
	diff_struct_fields(doc, compiler, doc_source, &findings, alloc)

	slice.sort_by(findings[:], finding_less)
	return findings[:]
}

// blocking_findings is the gate's verdict input: every parity finding from the
// .fun doc source, MINUS the suppressions. A .Docs_Ahead_Of_Compiler finding is
// suppressed only if it is on the audited RESIDUAL_OVER_DECLARES allow-list; a
// .Compiler_Ahead_Of_Docs finding is reported but NON-blocking (an undocumented
// compiler surface is a softer drift than a documented-but-rejected one). The
// result is the set of findings that FAIL the gate — a fresh same-version surface
// divergence that nobody allow-listed. Empty result = the surface is in parity
// (modulo the audited residuals). Allocated on alloc.
blocking_findings :: proc(fun_model, compiler_model: Surface_Model, alloc := context.allocator) -> []Finding {
	allow := residual_allow_set(alloc)
	defer delete(allow)
	fun_findings := diff_surfaces(fun_model, compiler_model, ".fun", alloc)

	blocking := make([dynamic]Finding, 0, 16, alloc)
	seen := make(map[string]bool, alloc)
	defer delete(seen)
	for f in fun_findings {
		if f.direction != .Docs_Ahead_Of_Compiler {
			continue // compiler-ahead findings never block
		}
		if (Residual_Key{f.kind, f.symbol}) in allow {
			continue // audited residual
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

// format_blocking_findings renders the gate's failure message: the count, then one
// named line per blocking finding, then the remediation pointer. Returns "" when
// there are no blocking findings. Allocated on alloc.
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
