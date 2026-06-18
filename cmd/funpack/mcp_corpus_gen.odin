// The docs-corpus generator core. It runs the three file-driven extractors against
// the in-repo source trees and assembles the corpus IN MEMORY (the per-kind section
// slices plus the content-derived manifest); it performs NO filesystem WRITES —
// persisting the shards is the caller's job (the gen-corpus subcommand,
// cli_mcp_gen_corpus.odin). That split lets the pin test (mcp_corpus_pin_test.odin)
// regenerate through THIS SAME core and byte-compare against the committed shards,
// so generation and drift-detection share ONE extraction path with no second,
// divergent extractor to keep in sync.
//
// THE THREE EXTRACTORS:
//   - extract_spec    : heading-split spec/NN-*.md prose (fence-aware splitter)
//   - extract_engine  : decl-split stdlib/engine/*.fun, pairing each decl with its
//                       immediately-preceding @doc PROSE line. CRITICAL: the engine
//                       corpus's searchable payload is that @doc PROSE — the
//                       compiler's surface_dump_json carries ZERO doc text, so it
//                       CANNOT source engine.json; the .fun files are the only prose
//                       source (DOCS-GEN decision). surface_dump_json stays the
//                       surface-PARITY ground truth (funpack/surface_parity.odin),
//                       a separate concern from this corpus.
//   - extract_plugin  : heading-split plugins/funpack/skills/**/*.md
//
// THE PROVENANCE (DOCS-GEN decision): funpack_version comes from the in-process
// compile-time constant funpack.funpack_version() — the generator IS funpack, so
// there is no `funpack version` subprocess. spec_ref is the single residual shell
// (git describe), and it lives ONLY in the subcommand (cli_mcp_gen_corpus.odin),
// passed IN to generate_corpus — this pure core never shells out, so the pin test
// and the SDL-free floor never invoke git.
//
// ODIN-FIRST NOTE: core:text/regex covers the four anchored head-match patterns,
// but each is a trivial line-anchored prefix/suffix match; a hand-rolled index scan
// is used instead (the idiom the funpack lexer/parser and
// surface_parity.odin already follow) — it avoids a per-call regex-VM allocation
// and keeps the generator a deterministic pure walk. SHA-256 is core:crypto/sha2;
// hex is core:encoding/hex; JSON is core:encoding/json — no hand-roll.
package main

import "../../funpack"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Corpus_Roots holds the resolved absolute source directories for one generation
// run. spec_md / engine_fun / plugin_dir are the three extractor inputs; spec_ref is
// the git-describe value the SUBCOMMAND computed and passes in (the pure core never
// shells out — see the package doc).
Corpus_Roots :: struct {
	spec_md:     string, // <repo>/spec (NN-*.md prose)
	engine_fun:  string, // <repo>/stdlib/engine (*.fun signatures)
	plugin_dir:  string, // <repo>/plugins/funpack (authoring skills root)
	spec_ref:    string, // git describe value, computed by the caller (gated to the subcommand)
}

// Corpus_Result is one generation run's output, held in memory. The same
// Corpus_Roots content yields a byte-identical result (deterministic walk, sorted
// file order, no clock).
Corpus_Result :: struct {
	spec:     []Corpus_Section,
	engine:   []Corpus_Section,
	plugin:   []Corpus_Section,
	manifest: Corpus_Manifest,
}

// generate_corpus runs the three extractors against r and assembles the in-memory
// result including the content-derived manifest. ok=false when a source root is
// unreadable (so a misconfigured root fails loudly rather than emitting an empty
// corpus). No filesystem writes. Allocated in `allocator`.
generate_corpus :: proc(r: Corpus_Roots, allocator := context.allocator) -> (result: Corpus_Result, ok: bool) {
	spec_secs, spec_ok := extract_markdown_tree(r.spec_md, r.spec_md, CORPUS_KIND_SPEC, allocator)
	if !spec_ok {
		return {}, false
	}
	engine_secs, engine_ok := extract_engine(r.engine_fun, allocator)
	if !engine_ok {
		return {}, false
	}
	plugin_root := corpus_join({r.plugin_dir, "skills"}, allocator)
	plugin_secs, plugin_ok := extract_markdown_tree(plugin_root, r.plugin_dir, CORPUS_KIND_PLUGIN, allocator)
	if !plugin_ok {
		return {}, false
	}

	fun_version := funpack.funpack_version()
	// The per-source records live in an explicitly-allocated slice (NOT a slice
	// literal): a slice-literal initializer is backed by transient storage that is
	// freed when this proc returns, leaving manifest.sources dangling — a later
	// marshal would read freed memory. make() on `allocator` gives the slice the
	// result's lifetime.
	sources := make([]Corpus_Source_Record, 3, allocator)
	sources[0] = Corpus_Source_Record {
		root         = "spec",
		kind         = CORPUS_KIND_SPEC,
		ref          = r.spec_ref,
		sections     = len(spec_secs),
		content_hash = hash_corpus_sections(spec_secs, allocator),
	}
	sources[1] = Corpus_Source_Record {
		root         = "stdlib/engine",
		kind         = CORPUS_KIND_ENGINE,
		ref          = r.spec_ref,
		sections     = len(engine_secs),
		content_hash = hash_corpus_sections(engine_secs, allocator),
	}
	sources[2] = Corpus_Source_Record {
		root         = "plugins/funpack",
		kind         = CORPUS_KIND_PLUGIN,
		ref          = fun_version,
		sections     = len(plugin_secs),
		content_hash = hash_corpus_sections(plugin_secs, allocator),
	}
	manifest := Corpus_Manifest {
		spec_ref        = r.spec_ref,
		funpack_version = fun_version,
		total_sections  = len(spec_secs) + len(engine_secs) + len(plugin_secs),
		sources         = sources,
	}
	return Corpus_Result {
			spec = spec_secs,
			engine = engine_secs,
			plugin = plugin_secs,
			manifest = manifest,
		},
		true
}

// hash_corpus_sections is the content hash over the sections' anchors and text:
// SHA-256 over each section's anchor + NUL + text + NUL, hex-encoded. A content
// change between regens shows up
// in the manifest's per-source content_hash, so the pin test names WHICH root
// drifted. core:crypto/sha2 + core:encoding/hex (Odin-first; no hand-roll).
hash_corpus_sections :: proc(sections: []Corpus_Section, allocator := context.allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	nul := [1]u8{0}
	for s in sections {
		sha2.update(&ctx, transmute([]u8)s.anchor)
		sha2.update(&ctx, nul[:])
		sha2.update(&ctx, transmute([]u8)s.text)
		sha2.update(&ctx, nul[:])
	}
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, digest[:])
	encoded, _ := hex.encode(digest[:], allocator)
	return string(encoded)
}

// marshal_corpus_json renders a value exactly as the committed corpus files are
// written: 2-space-indented pretty JSON with a trailing newline. Byte-comparing
// this against a committed file IS the corpus drift test, and this marshaler is the
// sole canonical producer of those bytes — the pin test regenerates through it and
// compares against what it last wrote, so the only byte-exactness requirement is
// this producer against itself. Allocated in `allocator`.
marshal_corpus_json :: proc(v: any, allocator := context.allocator) -> (out: string, ok: bool) {
	bytes, err := json.marshal(v, {pretty = true, use_spaces = true, spaces = 2}, allocator)
	if err != nil {
		return "", false
	}
	b := strings.builder_make(allocator)
	strings.write_bytes(&b, bytes)
	strings.write_byte(&b, '\n')
	return strings.to_string(b), true
}

// --- spec / plugin extraction ------------------------------------------------

// extract_markdown_tree is the shared heading-splitter for the prose corpora
// (spec/, plugin skills/). walk_root is the directory walked; anchor_base is the
// directory anchors/sources
// are made relative to (so plugin anchors keep the skills/… prefix). Files are
// walked in sorted path order for determinism. ok=false when the tree is
// unreadable. Allocated in `allocator`.
extract_markdown_tree :: proc(
	walk_root, anchor_base: string,
	kind: string,
	allocator := context.allocator,
) -> (sections: []Corpus_Section, ok: bool) {
	if !os.is_dir(walk_root) {
		return nil, false
	}
	paths := make([dynamic]string, 0, 64, allocator)
	walker := os.walker_create(walk_root)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, ".md") {
			continue
		}
		append(&paths, strings.clone(info.fullpath, allocator))
	}
	if _, err := os.walker_error(&walker); err != nil {
		return nil, false
	}
	slice.sort(paths[:])

	out := make([dynamic]Corpus_Section, 0, 256, allocator)
	for path in paths {
		raw, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil {
			return nil, false
		}
		source := corpus_rel(anchor_base, path, allocator)
		split_headings(string(raw), source, kind, &out, allocator)
	}
	return out[:], true
}

// corpus_rel returns path relative to base. filepath.rel already yields
// '/'-separated segments on the POSIX targets funpack builds for (no slash
// normalization needed). Both inputs are absolute, so the rel is the source's
// corpus-relative anchor path.
corpus_rel :: proc(base, path: string, allocator := context.allocator) -> string {
	rel, err := filepath.rel(base, path, allocator)
	if err != nil {
		return strings.clone(path, allocator)
	}
	return rel
}

// corpus_join joins path elements, discarding filepath.join's allocator-error
// return so a struct-field initializer or single-value context can use the path
// directly (filepath.join is not #optional_allocator_error). Allocated in
// `allocator`.
corpus_join :: proc(elems: []string, allocator := context.allocator) -> string {
	joined, _ := filepath.join(elems, allocator)
	return joined
}

// split_headings turns one markdown document into heading-delimited sections,
// appending them to out. Anchors are "<source>#<slug>"; a duplicate slug WITHIN a
// file is suffixed "-2", "-3", … so
// anchors stay unique and stable per content. A heading inside a ```-fenced code
// block is NOT a split point. An organizational parent heading whose only content
// is its subheadings (empty body) is skipped — each child heading is its own
// section.
split_headings :: proc(
	content, source, kind: string,
	out: ^[dynamic]Corpus_Section,
	allocator := context.allocator,
) {
	slug_counts := make(map[string]int, 32, context.temp_allocator)
	cur_title: string
	cur_body := make([dynamic]string, 0, 64, context.temp_allocator)
	in_fence := false

	lines := strings.split(content, "\n", context.temp_allocator)
	for line in lines {
		if strings.has_prefix(strings.trim_space(line), "```") {
			in_fence = !in_fence
			append(&cur_body, line)
			continue
		}
		if !in_fence {
			if title, is_heading := parse_heading(line); is_heading {
				flush_heading_section(cur_title, &cur_body, source, kind, &slug_counts, out, allocator)
				cur_title = title
				continue
			}
		}
		append(&cur_body, line)
	}
	flush_heading_section(cur_title, &cur_body, source, kind, &slug_counts, out, allocator)
}

// flush_heading_section emits the accumulated heading + body as one section into
// out, then clears the body — the split_headings `flush` step as a top-level proc
// (Odin nested procs do not capture, so the state is threaded explicitly). A section
// with an empty title (preamble before the first heading) or
// an empty body (an organizational parent heading) is skipped. The slug is
// deduped within the file via slug_counts ("-2", "-3", …).
flush_heading_section :: proc(
	cur_title: string,
	cur_body: ^[dynamic]string,
	source, kind: string,
	slug_counts: ^map[string]int,
	out: ^[dynamic]Corpus_Section,
	allocator := context.allocator,
) {
	if cur_title == "" {
		return
	}
	text := strings.trim_space(strings.join(cur_body[:], "\n", context.temp_allocator))
	clear(cur_body)
	if text == "" {
		return
	}
	slug := corpus_slugify(cur_title, context.temp_allocator)
	slug_counts[slug] += 1
	if n := slug_counts[slug]; n > 1 {
		slug = strings.concatenate({slug, "-", int_to_string(n, context.temp_allocator)}, context.temp_allocator)
	}
	append(out, Corpus_Section {
		anchor = strings.concatenate({source, "#", slug}, allocator),
		kind = kind,
		title = strings.clone(cur_title, allocator),
		text = strings.clone(text, allocator),
		source = strings.clone(source, allocator),
	})
}

// parse_heading reports whether line is an ATX H1/H2/H3 heading ("# ", "## ",
// "### ") and returns its trimmed title — the `^(#{1,3})\s+(.+?)\s*$` match.
// Leading whitespace is NOT allowed before the hashes (line-anchored at column 0).
parse_heading :: proc(line: string) -> (title: string, ok: bool) {
	hashes := 0
	for hashes < len(line) && hashes < 4 && line[hashes] == '#' {
		hashes += 1
	}
	if hashes < 1 || hashes > 3 {
		return "", false
	}
	if hashes >= len(line) || (line[hashes] != ' ' && line[hashes] != '\t') {
		return "", false
	}
	rest := strings.trim_space(line[hashes:])
	if rest == "" {
		return "", false
	}
	return rest, true
}

// --- engine extraction -------------------------------------------------------

// extract_engine reads stdlib/engine/*.fun in sorted filename order and emits one
// section per declaration, each paired with its immediately-preceding @doc PROSE
// line. ok=false when the directory is unreadable. Allocated in `allocator`.
extract_engine :: proc(dir: string, allocator := context.allocator) -> (sections: []Corpus_Section, ok: bool) {
	if !os.is_dir(dir) {
		return nil, false
	}
	paths := make([dynamic]string, 0, 32, allocator)
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, ".fun") {
			continue
		}
		append(&paths, strings.clone(info.fullpath, allocator))
	}
	if _, err := os.walker_error(&walker); err != nil {
		return nil, false
	}
	slice.sort(paths[:])

	out := make([dynamic]Corpus_Section, 0, 320, allocator)
	for path in paths {
		raw, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil {
			return nil, false
		}
		base := path[strings.last_index_byte(path, '/') + 1:]
		module := strings.trim_suffix(base, ".fun")
		source := strings.concatenate({"engine/", base}, allocator)
		split_engine_file(string(raw), module, source, &out, allocator)
	}
	return out[:], true
}

// split_engine_file turns one .fun signature file into per-declaration sections. The
// anchor is "engine/<module>#<decl-name>"; a name repeated within a module (UFCS
// overloads
// on different self types) is suffixed. Each decl pairs with its immediately-
// preceding @doc line; any non-doc, non-decl line clears a dangling @doc so it
// never attaches to the wrong declaration.
split_engine_file :: proc(
	content, module, source: string,
	out: ^[dynamic]Corpus_Section,
	allocator := context.allocator,
) {
	lines := strings.split(content, "\n", context.temp_allocator)
	name_counts := make(map[string]int, 64, context.temp_allocator)
	pending_doc: string

	i := 0
	for i < len(lines) {
		trimmed := strings.trim_space(lines[i])
		if doc, is_doc := parse_doc_line(trimmed); is_doc {
			pending_doc = corpus_unescape_doc(doc, context.temp_allocator)
			i += 1
			continue
		}
		if name, is_decl := parse_decl_head(trimmed); is_decl {
			sig, consumed := engine_signature(lines, i, context.temp_allocator)
			i += consumed
			anchor_name := corpus_slugify(name, context.temp_allocator)
			name_counts[anchor_name] += 1
			if n := name_counts[anchor_name]; n > 1 {
				anchor_name = strings.concatenate(
					{anchor_name, "-", int_to_string(n, context.temp_allocator)},
					context.temp_allocator,
				)
			}
			text := sig
			if pending_doc != "" {
				text = strings.concatenate({pending_doc, "\n\n", sig}, context.temp_allocator)
			}
			append(out, Corpus_Section {
				anchor = strings.concatenate({"engine/", module, "#", anchor_name}, allocator),
				kind = CORPUS_KIND_ENGINE,
				title = strings.concatenate({module, ".", name}, allocator),
				text = strings.clone(text, allocator),
				source = strings.clone(source, allocator),
			})
			pending_doc = ""
			i += 1
			continue
		}
		if trimmed != "" {
			pending_doc = ""
		}
		i += 1
	}
}

// parse_doc_line reports whether trimmed is a single-line `@doc("...")` annotation
// and returns the inner string — the `^@doc\("(.*)"\)\s*$` match. The whole line
// must be exactly the annotation (the trailing `)` after the closing quote, then
// only whitespace).
parse_doc_line :: proc(trimmed: string) -> (doc: string, ok: bool) {
	if !strings.has_prefix(trimmed, "@doc(\"") {
		return "", false
	}
	if !strings.has_suffix(trimmed, "\")") {
		return "", false
	}
	inner := trimmed[len("@doc(\""):len(trimmed) - len("\")")]
	return inner, true
}

// parse_decl_head reports whether trimmed begins with a stdlib decl keyword
// (extern fn, fn, extern type, data, enum, let) followed by a name, and returns the
// declared name — the
// `^(extern\s+fn|fn|extern\s+type|data|enum|let)\s+([A-Za-z_][A-Za-z0-9_]*)` match.
// The `extern fn`/`extern type` forms must precede the bare `fn` check so `extern
// fn` is not mis-read as a name after `extern`.
parse_decl_head :: proc(trimmed: string) -> (name: string, ok: bool) {
	// The multi-word `extern fn`/`extern type` forms are tried FIRST so `extern fn`
	// is not mis-read as `extern` + the name `fn`. The keyword list is the closed
	// decl-keyword alternation; strip_decl_keyword returns the post-keyword remainder.
	rest, matched := strip_decl_keyword(trimmed)
	if !matched {
		return "", false
	}
	rest = corpus_skip_ws(rest)
	if rest == "" || !corpus_is_ident_start(rest[0]) {
		return "", false
	}
	end := 1
	for end < len(rest) && corpus_is_ident_char(rest[end]) {
		end += 1
	}
	return rest[:end], true
}

// strip_decl_keyword tries each stdlib decl keyword in declHeadRe-alternation order
// (multi-word forms first) and returns the post-keyword remainder on the first
// match. A flat loop over the keyword list rather than an else-if chain keeps each
// match's locals out of the others' scope (no -strict-style shadow).
strip_decl_keyword :: proc(s: string) -> (rest: string, ok: bool) {
	keywords := []string{"extern fn", "extern type", "fn", "data", "enum", "let"}
	for kw in keywords {
		if r, matched := strip_kw(s, kw); matched {
			return r, true
		}
	}
	return s, false
}

// strip_kw matches `kw` at the start of s with a following whitespace separator and
// returns the remainder. A multi-word kw ("extern fn") matches `extern` + any
// run of whitespace + the second word, mirroring the regex's `\s+` between the two
// tokens. The keyword must be followed by whitespace (the decl name is separate),
// so `function` does not match `fn`.
strip_kw :: proc(s, kw: string) -> (rest: string, ok: bool) {
	if sp := strings.index_byte(kw, ' '); sp >= 0 {
		first := kw[:sp]
		second := kw[sp + 1:]
		if !corpus_word_prefix(s, first) {
			return s, false
		}
		after := corpus_skip_ws(s[len(first):])
		if len(after) == len(s) - len(first) {
			return s, false // no whitespace separated the two words
		}
		if !corpus_word_prefix(after, second) {
			return s, false
		}
		tail := after[len(second):]
		if tail == "" || !corpus_is_ws(tail[0]) {
			return s, false
		}
		return tail, true
	}
	if !corpus_word_prefix(s, kw) {
		return s, false
	}
	tail := s[len(kw):]
	if tail == "" || !corpus_is_ws(tail[0]) {
		return s, false
	}
	return tail, true
}

// corpus_word_prefix reports whether s begins with word and the following byte is a
// non-identifier (so `enum` does not match `enumerate`). End-of-string after word
// counts as a boundary.
corpus_word_prefix :: proc(s, word: string) -> bool {
	if !strings.has_prefix(s, word) {
		return false
	}
	if len(s) == len(word) {
		return true
	}
	return !corpus_is_ident_char(s[len(word)])
}

// engine_signature returns the declaration signature beginning at lines[start] and
// the count of EXTRA lines consumed past start. For a function (fn / extern fn) the
// body is dropped (the head up to the first `{`). For a type declaration (data /
// enum / extern type / let)
// the brace-delimited field/variant list IS the signature, kept verbatim across
// however many lines the braces span.
engine_signature :: proc(lines: []string, start: int, allocator := context.allocator) -> (sig: string, consumed: int) {
	head := strings.trim_space(lines[start])
	is_fn := strings.has_prefix(head, "fn ") || strings.has_prefix(head, "extern fn ")
	if is_fn {
		if brace := strings.index_byte(head, '{'); brace >= 0 {
			return strings.trim_space(head[:brace]), 0
		}
		return head, 0
	}

	opens := strings.count(head, "{")
	closes := strings.count(head, "}")
	if opens == 0 || opens == closes {
		return head, 0
	}
	depth := opens - closes
	collected := make([dynamic]string, 0, 16, allocator)
	append(&collected, head)
	for j := start + 1; j < len(lines); j += 1 {
		append(&collected, lines[j])
		depth += strings.count(lines[j], "{") - strings.count(lines[j], "}")
		if depth <= 0 {
			joined := strings.join(collected[:], "\n", allocator)
			return strings.trim_right(joined, "\n"), j - start
		}
	}
	return strings.join(collected[:], "\n", allocator), len(lines) - 1 - start
}

// corpus_unescape_doc reverses the minimal escaping the .fun @doc strings use
// (\" → ", \\ → \). Order matters: \" is replaced BEFORE \\, so an escaped backslash
// preceding a quote does not re-trigger the quote unescape. Allocated in `allocator`.
corpus_unescape_doc :: proc(s: string, allocator := context.allocator) -> string {
	a, _ := strings.replace_all(s, "\\\"", "\"", allocator)
	b, _ := strings.replace_all(a, "\\\\", "\\", allocator)
	return b
}

// --- shared helpers ----------------------------------------------------------

// corpus_slugify produces a stable lowercase kebab anchor fragment from a heading
// or name: lowercase, strip backticks, collapse whitespace runs to a single space,
// replace every non-[a-z0-9] run with a
// single dash, trim leading/trailing dashes, and fall back to "section" when empty.
// Stable across regen because it depends only on the text content. Allocated in
// `allocator`.
corpus_slugify :: proc(s: string, allocator := context.allocator) -> string {
	lowered := strings.to_lower(s, context.temp_allocator)
	b := strings.builder_make(allocator)
	prev_dash := false
	for i := 0; i < len(lowered); i += 1 {
		c := lowered[i]
		if c == '`' {
			continue
		}
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			strings.write_byte(&b, c)
			prev_dash = false
		} else {
			// Any non-slug byte (whitespace, punctuation) collapses to a single dash.
			if !prev_dash {
				strings.write_byte(&b, '-')
				prev_dash = true
			}
		}
	}
	slug := strings.trim(strings.to_string(b), "-")
	if slug == "" {
		return strings.clone("section", allocator)
	}
	return strings.clone(slug, allocator)
}

// corpus_skip_ws returns s with leading ASCII whitespace removed.
corpus_skip_ws :: proc(s: string) -> string {
	i := 0
	for i < len(s) && corpus_is_ws(s[i]) {
		i += 1
	}
	return s[i:]
}

// corpus_is_ws reports whether b is an ASCII whitespace byte.
corpus_is_ws :: proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// corpus_is_ident_start reports whether b can begin an identifier ([A-Za-z_]).
corpus_is_ident_start :: proc(b: u8) -> bool {
	return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '_'
}

// corpus_is_ident_char reports whether b can continue an identifier ([A-Za-z0-9_]).
corpus_is_ident_char :: proc(b: u8) -> bool {
	return corpus_is_ident_start(b) || (b >= '0' && b <= '9')
}

// int_to_string renders a small non-negative int as its decimal string — used for
// the slug/name dedup suffix ("-2", "-3"). Allocated in `allocator`.
int_to_string :: proc(n: int, allocator := context.allocator) -> string {
	if n == 0 {
		return strings.clone("0", allocator)
	}
	digits := make([dynamic]u8, 0, 8, context.temp_allocator)
	v := n
	for v > 0 {
		append(&digits, u8('0' + v % 10))
		v /= 10
	}
	b := strings.builder_make(allocator)
	for i := len(digits) - 1; i >= 0; i -= 1 {
		strings.write_byte(&b, digits[i])
	}
	return strings.to_string(b)
}
