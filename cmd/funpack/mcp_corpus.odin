package main

import "core:encoding/json"

CORPUS_KIND_SPEC :: "spec"
CORPUS_KIND_ENGINE :: "engine"
CORPUS_KIND_PLUGIN :: "plugin"

corpus_kind_valid :: proc(k: string) -> bool {
	return k == CORPUS_KIND_SPEC || k == CORPUS_KIND_ENGINE || k == CORPUS_KIND_PLUGIN
}

Corpus_Section :: struct {
	anchor: string `json:"anchor"`,
	kind:   string `json:"kind"`,
	title:  string `json:"title"`,
	text:   string `json:"text"`,
	source: string `json:"source"`,
}

Corpus_Source_Record :: struct {
	root:         string `json:"root"`,
	kind:         string `json:"kind"`,
	ref:          string `json:"ref"`,
	sections:     int `json:"sections"`,
	content_hash: string `json:"content_hash"`,
}

Corpus_Manifest :: struct {
	spec_ref:        string `json:"spec_ref"`,
	funpack_version: string `json:"funpack_version"`,
	sources:         []Corpus_Source_Record `json:"sources"`,
	total_sections:  int `json:"total_sections"`,
}

CORPUS_SPEC_JSON :: #load("mcp/corpus/spec.json", string)
CORPUS_ENGINE_JSON :: #load("mcp/corpus/engine.json", string)
CORPUS_PLUGIN_JSON :: #load("mcp/corpus/plugin.json", string)

CORPUS_MANIFEST_JSON :: #load("mcp/corpus/manifest.json", string)

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

load_manifest :: proc(allocator := context.allocator) -> (manifest: Corpus_Manifest, ok: bool) {
	m: Corpus_Manifest
	if err := json.unmarshal_string(CORPUS_MANIFEST_JSON, &m, allocator = allocator); err != nil {
		return {}, false
	}
	return m, true
}

corpus_by_kind :: proc(sections: []Corpus_Section, kind: string, allocator := context.allocator) -> []Corpus_Section {
	out := make([dynamic]Corpus_Section, 0, len(sections), allocator)
	for s in sections {
		if s.kind == kind {
			append(&out, s)
		}
	}
	return out[:]
}

manifest_count_by_kind :: proc(m: Corpus_Manifest, allocator := context.allocator) -> map[string]int {
	counts := make(map[string]int, 3, allocator)
	for src in m.sources {
		counts[src.kind] += src.sections
	}
	return counts
}
