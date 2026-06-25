// The docs disk-projection materializer — the on-disk, version-keyed mirror of the
// compile-time-embedded docs corpus (mcp_corpus.odin). It exists so an agent can
// TRAVERSE the funpack docs natively (Read/Grep/follow-anchor) the way it traverses
// any source tree, in addition to the in-process docs_search/docs_get tools.
//
// THE WELD (why a PROJECTION, not a separate doc tree): the corpus is the source of
// truth and it is welded to the compiler — it rode into THIS binary via #load, and
// spec/ + stdlib/engine/ never ship to a user's disk. So the on-disk tree is written
// FROM the embedded bytes by the binary itself: it is coherent by construction (it
// cannot describe a different toolchain than the one that wrote it) and version-keyed
// by the manifest's funpack version (the directory segment), so two binaries never
// fight over one tree. This is the disk half of ADR
// docs-corpus-disk-projection-deep-links; load_corpus/load_manifest remain the index.
//
// PURITY IS PRESERVED: this materializer writes files, so it is NOT on the docs_search
// hot path — docs_search stays a pure in-process function of binary + args. The write
// happens ONCE at server startup (mcp_server.odin) and via the explicit
// `funpack mcp docs-export` subcommand, never inside a tool call. Materialization is
// idempotent (a completion sentinel matching the version short-circuits), best-effort
// (a failed write degrades to no on-disk tree — the caller renders hits without the
// `path` field), and byte-deterministic for a fixed corpus.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// DOCS_EXPORT_HOME_SUBDIR is the managed-home subtree the projection lives under,
// joined as <HOME>/.funpack/docs/<version>. ~/.funpack is funpack's managed prefix
// (the same home funpack:ctl manages), so the docs tree sits beside the managed
// binary rather than in a scattered cache.
DOCS_EXPORT_HOME_SUBDIR :: ".funpack"

// DOCS_EXPORT_DOCS_SEGMENT is the fixed path segment under the managed home that
// holds the per-version projection roots (<HOME>/.funpack/docs/<version>).
DOCS_EXPORT_DOCS_SEGMENT :: "docs"

// DOCS_EXPORT_SENTINEL is the completion marker written LAST into a version root; it
// holds the version string. A matching sentinel makes re-export a no-op (the
// idempotence key), and writing it last means a half-written tree (crash mid-export)
// has no sentinel and is re-materialized on the next start rather than trusted.
DOCS_EXPORT_SENTINEL :: ".complete"

// docs_export_root resolves the version-keyed projection root for the embedded corpus:
//   <HOME>/.funpack/docs/<version>
// version is the normalized manifest funpack version (the corpus version key — the
// corpus restamps on every binary version bump, so it uniquely names this binary's
// embedded corpus). ok=false when HOME is unset/empty: there is no managed home to
// write under, so the caller degrades (no on-disk tree, hits omit `path`) rather than
// guessing a path. Allocated in `allocator`.
docs_export_root :: proc(manifest: Corpus_Manifest, allocator := context.allocator) -> (root: string, ok: bool) {
	home := os.get_env("HOME", allocator)
	if strings.trim_space(home) == "" {
		return "", false
	}
	version := docs_normalize_version(manifest.funpack_version)
	if version == "" {
		// A manifest with no version still gets a stable, non-empty segment so the path
		// never collapses to the docs/ parent; "unknown" mirrors corpus_git_describe's
		// fallback token.
		version = "unknown"
	}
	return corpus_join({home, DOCS_EXPORT_HOME_SUBDIR, DOCS_EXPORT_DOCS_SEGMENT, version}, allocator), true
}

// mcp_materialize_docs_projection is the server-startup hook (run_mcp_verb): it writes the
// version-keyed on-disk docs projection (docs_export_default) so an agent can traverse the
// docs natively — Read/Grep/follow the `<!-- anchor: … -->` markers — alongside the
// in-process docs_search/docs_get tools. STARTUP-ONLY and best-effort: a populated version
// tree is a no-op (the sentinel), and a degraded outcome (no HOME, a read-only managed
// home) is reported ONCE to stderr and swallowed. It never aborts the serve loop and is
// never on the docs_search hot path, so docs_search stays a pure in-process function of
// binary + args. The success path is silent (no per-start stderr noise on a healthy host);
// only degradation prints. Returns the resolved root (empty when degraded).
mcp_materialize_docs_projection :: proc(allocator := context.allocator) -> (root: string, ok: bool) {
	root, ok = docs_export_default(allocator)
	if !ok {
		fmt.eprintln(
			"funpack mcp: on-disk docs projection not materialized (no writable ~/.funpack home); docs_search/docs_get still serve from the embedded corpus",
		)
	}
	return root, ok
}

// docs_export_default materializes the embedded corpus to its version-keyed managed-home
// root and returns that root for path rendering. It is the startup/standalone entry: it
// resolves HOME, loads the corpus + manifest, and writes the projection idempotently.
// ok=false means no on-disk tree is available (HOME unresolved, corpus parse failure, or
// a write fault) — the caller proceeds without a `path` field, never aborting. The
// returned root is valid whenever ok is true. Allocated in `allocator`.
docs_export_default :: proc(allocator := context.allocator) -> (root: string, ok: bool) {
	manifest, _ := load_manifest(allocator) // a zero manifest yields the "unknown" version segment
	resolved, have_root := docs_export_root(manifest, allocator)
	if !have_root {
		return "", false
	}
	sections, parsed := load_corpus(allocator)
	if !parsed {
		return "", false
	}
	version := docs_normalize_version(manifest.funpack_version)
	if version == "" {
		version = "unknown"
	}
	if _, wrote_ok := docs_export_write(resolved, version, sections, allocator); !wrote_ok {
		return "", false
	}
	return resolved, true
}

// docs_export_write materializes `sections` to `root`: one Markdown file per section
// source (docs_export_group preserves first-seen source order), each section prefixed
// with a greppable anchor marker (docs_export_render_file). Idempotent: a sentinel
// (root/.complete) holding the same `version` short-circuits to a no-op. The sentinel is
// written LAST so a crash mid-export leaves no sentinel and re-materializes next time.
// Returns wrote=true when it actually rewrote the tree (false on the idempotent skip),
// ok=false on any mkdir/write failure. Allocated in `allocator`.
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

	// mkdir the root up front so a zero-section corpus still produces a valid sentinel-bearing
	// tree (and so the sentinel write below never races a missing parent).
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

// Docs_Export_Group collects the corpus indices that share one source path, in their
// corpus order. One group renders to one on-disk file.
Docs_Export_Group :: struct {
	source:  string,
	indices: [dynamic]int,
}

// docs_export_group buckets sections by their `source` path, preserving the order in
// which each source is first seen and the order of sections within a source. The result
// is deterministic for a fixed corpus, so the materialized bytes are stable across runs.
// Allocated in `allocator`.
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

// docs_export_render_file reconstructs one source's Markdown file: a provenance header
// naming the source, then each section as an HTML-comment ANCHOR MARKER carrying the
// full corpus anchor (the agent greps "<!-- anchor: <id>" to jump to a section) plus the
// title heading and the section body. The marker — not a slug-derived heading — is the
// deep-link target, so it resolves an anchor exactly regardless of how the title slugs.
// No timestamp or machine path, so the bytes are content-stable. Allocated in `allocator`.
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
