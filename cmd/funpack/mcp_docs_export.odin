package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

DOCS_EXPORT_HOME_SUBDIR :: ".funpack"

DOCS_EXPORT_DOCS_SEGMENT :: "docs"

DOCS_EXPORT_SENTINEL :: ".complete"

docs_export_root :: proc(manifest: Corpus_Manifest, allocator := context.allocator) -> (root: string, ok: bool) {
	home := os.get_env("HOME", allocator)
	if strings.trim_space(home) == "" {
		return "", false
	}
	version := docs_normalize_version(manifest.funpack_version)
	if version == "" {
		version = "unknown"
	}
	return corpus_join({home, DOCS_EXPORT_HOME_SUBDIR, DOCS_EXPORT_DOCS_SEGMENT, version}, allocator), true
}

mcp_materialize_docs_projection :: proc(allocator := context.allocator) -> (root: string, ok: bool) {
	root, ok = docs_export_default(allocator)
	if !ok {
		fmt.eprintln(
			"funpack mcp: on-disk docs projection not materialized (no writable ~/.funpack home); docs_search/docs_get still serve from the embedded corpus",
		)
	}
	return root, ok
}

docs_export_default :: proc(allocator := context.allocator) -> (root: string, ok: bool) {
	manifest, _ := load_manifest(allocator)
	resolved, have_root := docs_export_root(manifest, allocator)
	if !have_root {
		return "", false
	}
	if _, write_ok := docs_export_into(resolved, allocator); !write_ok {
		return "", false
	}
	return resolved, true
}

docs_export_into :: proc(root: string, allocator := context.allocator) -> (wrote: bool, ok: bool) {
	manifest, _ := load_manifest(allocator)
	version := docs_normalize_version(manifest.funpack_version)
	if version == "" {
		version = "unknown"
	}
	sections, parsed := load_corpus(allocator)
	if !parsed {
		return false, false
	}
	return docs_export_write(root, version, sections, allocator)
}

docs_export_write :: proc(
	root, version: string,
	sections: []Corpus_Section,
	allocator := context.allocator,
) -> (wrote: bool, ok: bool) {
	sentinel := corpus_join({root, DOCS_EXPORT_SENTINEL}, allocator)
	if existing, read_err := os.read_entire_file_from_path(sentinel, allocator); read_err == nil {
		if strings.trim_space(string(existing)) == version {
			return false, true
		}
	}

	if err := os.make_directory_all(root); err != nil && !os.is_dir(root) {
		return false, false
	}

	groups := docs_export_group(sections, allocator)
	for g in groups {
		path := corpus_join({root, g.source}, allocator)
		dir := filepath.dir(path)
		if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
			return false, false
		}
		body := docs_export_render_file(sections, g, allocator)
		if err := os.write_entire_file(path, transmute([]u8)body); err != nil {
			return false, false
		}
	}

	if err := os.write_entire_file(sentinel, transmute([]u8)version); err != nil {
		return false, false
	}
	return true, true
}

Docs_Export_Group :: struct {
	source:  string,
	indices: [dynamic]int,
}

docs_export_group :: proc(sections: []Corpus_Section, allocator := context.allocator) -> []Docs_Export_Group {
	groups := make([dynamic]Docs_Export_Group, 0, 64, allocator)
	pos := make(map[string]int, 64, allocator)
	for s, i in sections {
		if idx, seen := pos[s.source]; seen {
			append(&groups[idx].indices, i)
			continue
		}
		pos[s.source] = len(groups)
		g := Docs_Export_Group {
			source  = s.source,
			indices = make([dynamic]int, 0, 8, allocator),
		}
		append(&g.indices, i)
		append(&groups, g)
	}
	return groups[:]
}

docs_export_render_file :: proc(
	sections: []Corpus_Section,
	g: Docs_Export_Group,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "<!-- funpack docs projection — source: ")
	strings.write_string(&b, g.source)
	strings.write_string(&b, " -->\n\n")
	for idx, n in g.indices {
		s := sections[idx]
		if n > 0 {
			strings.write_string(&b, "\n")
		}
		strings.write_string(&b, "<!-- anchor: ")
		strings.write_string(&b, s.anchor)
		strings.write_string(&b, " | kind: ")
		strings.write_string(&b, s.kind)
		strings.write_string(&b, " -->\n## ")
		strings.write_string(&b, s.title)
		strings.write_string(&b, "\n\n")
		strings.write_string(&b, s.text)
		if !strings.has_suffix(s.text, "\n") {
			strings.write_string(&b, "\n")
		}
	}
	return strings.to_string(b)
}
