// The embedded docs-corpus loader — the Odin re-home of the deleted Go
// mcp/internal/docs/docs.go go:embed loader. The committed corpus shards
// (mcp/corpus/{spec,engine,plugin}.json) plus the provenance manifest
// (mcp/corpus/manifest.json) are GENERATED, not authored (mcp_corpus_gen.odin /
// `funpack mcp gen-corpus`), and embedded into the binary at COMPILE time via
// `#load` — the same compile-time byte read funpack/version.odin uses for VERSION
// (no runtime filesystem read, no clock; absolute stdout discipline preserved
// because the server is FUNPACK_LIVE-only in this entry package, never the pure
// compiler subtree). Each shard is parsed ONCE at server init (load_corpus) with
// core:encoding/json into the Section/Manifest structs below. The docs MCP tools
// (docs_get/docs_search) and their ranker are the SEPARATE mcp-docs-search-port
// task; this file delivers only the embed + parse + the typed accessors that task
// builds on (load_corpus / load_manifest / corpus_by_kind / manifest_count_by_kind).
//
// WHY cmd/funpack, NOT the pure funpack package: this loader is part of the
// `funpack mcp` server graph, which the ADR places FUNPACK_LIVE-only in the single
// SDL-linking binary. The loader itself needs only core:encoding/json + #load (no
// SDL, no session_capture_frame), so it compiles in BOTH the stub and FUNPACK_LIVE
// arms of this package — it is define-free here, so its tests run on the default
// `odin test .` floor rather than only under the LIVE arm.
package main

import "core:encoding/json"

// CORPUS_KIND_SPEC / _ENGINE / _PLUGIN are the closed set of corpus source
// categories, as the exact lowercase JSON values the shards carry (mirroring the
// Go docs.Kind const values). A section's `kind` is exactly one of these; the
// generator never mints a kind outside this set, and corpus_kind_valid is the
// exhaustive membership test a consumer guards on.
CORPUS_KIND_SPEC :: "spec"
CORPUS_KIND_ENGINE :: "engine"
CORPUS_KIND_PLUGIN :: "plugin"

// corpus_kind_valid reports whether k is one of the closed corpus-kind values.
// The closed-enum discipline as a value check (the kind is a JSON string, not an
// Odin enum, so the wire value stays exactly "spec"/"engine"/"plugin" — see the
// Corpus_Section doc).
corpus_kind_valid :: proc(k: string) -> bool {
	return k == CORPUS_KIND_SPEC || k == CORPUS_KIND_ENGINE || k == CORPUS_KIND_PLUGIN
}

// Corpus_Section is one indexable unit of documentation — the Odin mirror of the
// Go docs.Section. The json: tags pin the wire key names (snake/lower) so the
// marshaled bytes match the committed shards regardless of the Odin field
// spelling. `kind` is a plain string (not an Odin enum) so the emitted JSON value
// is exactly the lowercase category token; corpus_kind_valid is the closed-set
// guard. Anchor is stable across regen (slug-derived, never positional) so a
// downstream index can key on it.
Corpus_Section :: struct {
	// anchor uniquely identifies the section within the corpus and is stable across
	// regen. Format depends on kind: "<file>#<heading-slug>" for spec/plugin,
	// "engine/<module>#<decl-name>" for engine.
	anchor: string `json:"anchor"`,
	// kind is the source category — one of CORPUS_KIND_*.
	kind:   string `json:"kind"`,
	// title is the human-readable heading or declaration name.
	title:  string `json:"title"`,
	// text is the section body: prose for spec/plugin, the @doc prose plus the
	// signature for engine.
	text:   string `json:"text"`,
	// source is the corpus-relative source path the section came from, for
	// provenance and manifest cross-reference.
	source: string `json:"source"`,
}

// Corpus_Source_Record captures the provenance of one extracted source root — the
// Odin mirror of the Go docs.SourceRecord. content_hash is a hex SHA-256 over the
// root's concatenated section anchors+text (hash_corpus_sections), so a content
// change between regens is detectable at single-root granularity.
Corpus_Source_Record :: struct {
	// root is the logical source root ("spec", "stdlib/engine", "plugins/funpack").
	root:         string `json:"root"`,
	// kind is the corpus kind this root feeds (one of CORPUS_KIND_*).
	kind:         string `json:"kind"`,
	// ref is a version stamp for the root: the spec git ref for spec/engine, the
	// funpack version for plugin.
	ref:          string `json:"ref"`,
	// sections is the number of sections extracted from this root.
	sections:     int `json:"sections"`,
	// content_hash is the hex SHA-256 over this root's section anchors+text.
	content_hash: string `json:"content_hash"`,
}

// Corpus_Manifest records how and from what the committed corpus was generated —
// the Odin mirror of the Go docs.Manifest, the audit trail a stale-corpus check
// reads. Every field is content-derived (no timestamp, no machine path), so
// re-running the generator against the same sources reproduces it byte-for-byte: a
// clean git diff means the corpus is current.
Corpus_Manifest :: struct {
	// spec_ref is the nearest release tag reachable from HEAD at generation time
	// (git describe --tags --always --abbrev=0, gated to the generator). No
	// commit-distance suffix, so it is byte-stable between releases. Informational
	// provenance; content integrity is the per-source content_hash.
	spec_ref:        string `json:"spec_ref"`,
	// funpack_version is the in-process VERSION constant at generation time
	// (funpack_version()) — the generator IS funpack, so no version subprocess.
	funpack_version: string `json:"funpack_version"`,
	// sources is the per-root provenance, one entry per extracted source root.
	sources:         []Corpus_Source_Record `json:"sources"`,
	// total_sections is the corpus-wide section count.
	total_sections:  int `json:"total_sections"`,
}

// CORPUS_SPEC_JSON / _ENGINE_JSON / _PLUGIN_JSON are the committed per-kind shards
// embedded at compile time. A missing shard is a hard compile error by design —
// the generated corpus is the source-of-truth mirror that must exist in the tree
// (the same #load contract funpack/version.odin holds for VERSION). The bytes are
// produced by `funpack mcp gen-corpus` and committed.
CORPUS_SPEC_JSON :: #load("mcp/corpus/spec.json", string)
CORPUS_ENGINE_JSON :: #load("mcp/corpus/engine.json", string)
CORPUS_PLUGIN_JSON :: #load("mcp/corpus/plugin.json", string)

// CORPUS_MANIFEST_JSON is the committed provenance manifest, embedded the same way.
CORPUS_MANIFEST_JSON :: #load("mcp/corpus/manifest.json", string)

// load_corpus parses and merges the three embedded shards into one section slice,
// in the deterministic spec→engine→plugin shard order (the sorted-filename order
// the Go loader used: engine.json, plugin.json, spec.json sort that way on disk,
// but the SECTION order within the merged corpus is not relied on by anchor-keyed
// consumers — anchors are unique). Parsed once at server init. Returns ok=false on
// a malformed shard (a programmer/build error, since the shards are committed and
// the pin test guards them) rather than panicking. Allocated in `allocator`.
load_corpus :: proc(allocator := context.allocator) -> (sections: []Corpus_Section, ok: bool) {
	shards := [3]string{CORPUS_SPEC_JSON, CORPUS_ENGINE_JSON, CORPUS_PLUGIN_JSON}
	out := make([dynamic]Corpus_Section, 0, 700, allocator)
	for shard in shards {
		parsed: []Corpus_Section
		if err := json.unmarshal_string(shard, &parsed, allocator = allocator); err != nil {
			return nil, false
		}
		append(&out, ..parsed)
	}
	return out[:], true
}

// load_manifest parses the embedded provenance manifest. Returns ok=false on a
// malformed manifest (a build error the pin test guards). Allocated in `allocator`.
load_manifest :: proc(allocator := context.allocator) -> (manifest: Corpus_Manifest, ok: bool) {
	m: Corpus_Manifest
	if err := json.unmarshal_string(CORPUS_MANIFEST_JSON, &m, allocator = allocator); err != nil {
		return {}, false
	}
	return m, true
}

// corpus_by_kind returns the sections of a single kind, preserving corpus order —
// the Odin mirror of the Go Corpus.ByKind. The docs_search/docs_get ranker
// (mcp-docs-search-port) reads per-kind partitions through this accessor.
// Allocated in `allocator`.
corpus_by_kind :: proc(sections: []Corpus_Section, kind: string, allocator := context.allocator) -> []Corpus_Section {
	out := make([dynamic]Corpus_Section, 0, len(sections), allocator)
	for s in sections {
		if s.kind == kind {
			append(&out, s)
		}
	}
	return out[:]
}

// manifest_count_by_kind tallies the manifest's per-source section counts grouped
// by kind — the Odin mirror of the Go Manifest.CountByKind. Returns a fixed map
// keyed by the closed kind values; absent kinds read zero. Allocated in `allocator`.
manifest_count_by_kind :: proc(m: Corpus_Manifest, allocator := context.allocator) -> map[string]int {
	counts := make(map[string]int, 3, allocator)
	for src in m.sources {
		counts[src.kind] += src.sections
	}
	return counts
}
