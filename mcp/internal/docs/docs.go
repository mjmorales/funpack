// Package docs is the committed funpack documentation corpus and its loader.
//
// The corpus is GENERATED, not authored: `task docs-regen` (the generator at
// ./gen) extracts spec sections, engine.* signatures, and plugin-authoring
// references into ./corpus/*.json plus ./manifest.json, all committed to the
// repo. At runtime the loader reads those files through go:embed, so the binary
// is self-contained — it never touches the in-repo spec sources or any
// other filesystem path. The symbol-table, passage-index, and docs MCP tools
// build on Load/LoadManifest.
package docs

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"
)

// Kind is the closed set of corpus source categories. A section belongs to
// exactly one kind; the generator never mints a kind outside this enum, and a
// consumer can switch over it exhaustively.
type Kind string

const (
	// KindSpec is a heading-delimited passage from the in-repo spec/ prose
	// (spec/NN-*.md), anchored as "<file>#<heading-slug>".
	KindSpec Kind = "spec"
	// KindEngine is a single engine.* declaration (a function, type, data,
	// enum, or constant) distilled from a stdlib/engine/*.fun signature file,
	// anchored as "engine/<module>#<decl-name>".
	KindEngine Kind = "engine"
	// KindPlugin is a heading-delimited passage from the funpack plugin's
	// authoring skills/references, anchored as "<relpath>#<heading-slug>".
	KindPlugin Kind = "plugin"
)

// Valid reports whether k is one of the closed Kind values.
func (k Kind) Valid() bool {
	switch k {
	case KindSpec, KindEngine, KindPlugin:
		return true
	default:
		return false
	}
}

// Section is one indexable unit of documentation. Anchor is stable across
// regenerations of the same source content (slug-derived, never positional), so
// downstream indices can key on it.
type Section struct {
	// Anchor uniquely identifies the section within the corpus and is stable
	// across regen. Format depends on Kind (see the Kind constants).
	Anchor string `json:"anchor"`
	// Kind is the source category.
	Kind Kind `json:"kind"`
	// Title is the human-readable heading or declaration name.
	Title string `json:"title"`
	// Text is the section body: prose for spec/plugin, the signature plus its
	// @doc line for engine.
	Text string `json:"text"`
	// Source is the corpus-relative source path the section came from, for
	// provenance and manifest cross-reference.
	Source string `json:"source"`
}

// Corpus is the full loaded documentation set, sections grouped by no
// particular order beyond the generator's deterministic emission order.
type Corpus struct {
	Sections []Section `json:"sections"`
}

// ByKind returns the sections of a single kind, preserving corpus order.
func (c *Corpus) ByKind(k Kind) []Section {
	out := make([]Section, 0, len(c.Sections))
	for _, s := range c.Sections {
		if s.Kind == k {
			out = append(out, s)
		}
	}
	return out
}

// SourceRecord captures the provenance of one extracted source root: the git
// ref or version it was read at and how many sections it yielded.
type SourceRecord struct {
	// Root is the logical source root (e.g. "spec",
	// "stdlib/engine", "plugins/funpack").
	Root string `json:"root"`
	// Kind is the corpus kind this root feeds.
	Kind Kind `json:"kind"`
	// Ref is a version stamp for the root: the spec git ref for spec/engine
	// sources, the funpack version, or empty when not applicable.
	Ref string `json:"ref,omitempty"`
	// Sections is the number of sections extracted from this root.
	Sections int `json:"sections"`
	// ContentHash is a hex SHA-256 over the concatenated section anchors+text
	// from this root, so a content change between regens is detectable.
	ContentHash string `json:"content_hash"`
}

// Manifest records how and from what the committed corpus was generated. It is
// the audit trail a stale-corpus check reads to decide whether a
// regen is due. Every field is content-derived, so re-running the generator
// against the same sources reproduces the manifest byte-for-byte (no timestamp,
// no machine path) — a clean git diff means the corpus is current.
type Manifest struct {
	// SpecRef is `git -C $FUNPACK_SPEC_DIR describe --tags --always` at
	// generation time.
	SpecRef string `json:"spec_ref"`
	// FunpackVersion is the first line of `funpack version` at generation time.
	FunpackVersion string `json:"funpack_version"`
	// Sources is the per-root provenance, one entry per extracted source root.
	Sources []SourceRecord `json:"sources"`
	// TotalSections is the corpus-wide section count.
	TotalSections int `json:"total_sections"`
}

// CountByKind tallies sources' sections grouped by kind.
func (m *Manifest) CountByKind() map[Kind]int {
	out := map[Kind]int{}
	for _, s := range m.Sources {
		out[s.Kind] += s.Sections
	}
	return out
}

//go:embed corpus/*.json manifest.json
var embedded embed.FS

const (
	corpusDir    = "corpus"
	manifestPath = "manifest.json"
)

// Load reads and merges every committed corpus shard into one Corpus. The shard
// files are read in sorted filename order for deterministic section ordering.
func Load() (*Corpus, error) {
	entries, err := fs.ReadDir(embedded, corpusDir)
	if err != nil {
		return nil, fmt.Errorf("docs: read corpus dir: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)

	corpus := &Corpus{}
	for _, name := range names {
		raw, err := embedded.ReadFile(corpusDir + "/" + name)
		if err != nil {
			return nil, fmt.Errorf("docs: read corpus shard %s: %w", name, err)
		}
		var shard []Section
		if err := json.Unmarshal(raw, &shard); err != nil {
			return nil, fmt.Errorf("docs: parse corpus shard %s: %w", name, err)
		}
		corpus.Sections = append(corpus.Sections, shard...)
	}
	return corpus, nil
}

// LoadManifest reads and parses the committed corpus manifest.
func LoadManifest() (*Manifest, error) {
	raw, err := embedded.ReadFile(manifestPath)
	if err != nil {
		return nil, fmt.Errorf("docs: read manifest: %w", err)
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("docs: parse manifest: %w", err)
	}
	return &m, nil
}
