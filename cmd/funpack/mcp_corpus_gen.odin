package main

import "../../funpack"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

Corpus_Roots :: struct {
	spec_md:     string,
	engine_fun:  string,
	plugin_dir:  string,
	spec_ref:    string,
}

Corpus_Result :: struct {
	spec:     []Corpus_Section,
	engine:   []Corpus_Section,
	plugin:   []Corpus_Section,
	manifest: Corpus_Manifest,
}

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
	// make() on `allocator`, not a slice literal: a literal's transient backing frees on return, dangling manifest.sources.
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

extract_markdown_tree :: proc(
	walk_root, anchor_base: string,
	kind: string,
	allocator := context.allocator,
) -> (sections: []Corpus_Section, ok: bool) {
	paths, walked := collect_sorted_files(walk_root, ".md", allocator)
	if !walked {
		return nil, false
	}

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

corpus_rel :: proc(base, path: string, allocator := context.allocator) -> string {
	rel, err := filepath.rel(base, path, allocator)
	if err != nil {
		return strings.clone(path, allocator)
	}
	return rel
}

corpus_join :: proc(elems: []string, allocator := context.allocator) -> string {
	joined, _ := filepath.join(elems, allocator)
	return joined
}

corpus_repo_root :: proc(allocator := context.allocator) -> string {
	cwd, err := os.get_working_directory(allocator)
	if err != nil || cwd == "" {
		return strings.clone(".", allocator)
	}
	return cwd
}

collect_sorted_files :: proc(dir, suffix: string, allocator := context.allocator) -> (paths: []string, ok: bool) {
	if !os.is_dir(dir) {
		return nil, false
	}
	collected := make([dynamic]string, 0, 64, allocator)
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, suffix) {
			continue
		}
		append(&collected, strings.clone(info.fullpath, allocator))
	}
	if _, err := os.walker_error(&walker); err != nil {
		return nil, false
	}
	slice.sort(collected[:])
	return collected[:], true
}

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

extract_engine :: proc(dir: string, allocator := context.allocator) -> (sections: []Corpus_Section, ok: bool) {
	paths, walked := collect_sorted_files(dir, ".fun", allocator)
	if !walked {
		return nil, false
	}

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

parse_decl_head :: proc(trimmed: string) -> (name: string, ok: bool) {
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

strip_decl_keyword :: proc(s: string) -> (rest: string, ok: bool) {
	keywords := []string{"extern fn", "extern type", "fn", "data", "enum", "let"}
	for kw in keywords {
		if r, matched := strip_kw(s, kw); matched {
			return r, true
		}
	}
	return s, false
}

strip_kw :: proc(s, kw: string) -> (rest: string, ok: bool) {
	if sp := strings.index_byte(kw, ' '); sp >= 0 {
		first := kw[:sp]
		second := kw[sp + 1:]
		if !corpus_word_prefix(s, first) {
			return s, false
		}
		after := corpus_skip_ws(s[len(first):])
		if len(after) == len(s) - len(first) {
			return s, false
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

corpus_word_prefix :: proc(s, word: string) -> bool {
	if !strings.has_prefix(s, word) {
		return false
	}
	if len(s) == len(word) {
		return true
	}
	return !corpus_is_ident_char(s[len(word)])
}

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

corpus_unescape_doc :: proc(s: string, allocator := context.allocator) -> string {
	a, _ := strings.replace_all(s, "\\\"", "\"", allocator)
	b, _ := strings.replace_all(a, "\\\\", "\\", allocator)
	return b
}

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

corpus_skip_ws :: proc(s: string) -> string {
	i := 0
	for i < len(s) && corpus_is_ws(s[i]) {
		i += 1
	}
	return s[i:]
}

corpus_is_ws :: proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

corpus_is_ident_start :: proc(b: u8) -> bool {
	return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '_'
}

corpus_is_ident_char :: proc(b: u8) -> bool {
	return corpus_is_ident_start(b) || (b >= '0' && b <= '9')
}

int_to_string :: proc(n: int, allocator := context.allocator) -> string {
	buf: [20]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), allocator)
}
