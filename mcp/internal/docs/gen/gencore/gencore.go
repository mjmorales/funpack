// Package gencore is the reusable core of the docs-corpus generator.
//
// The `gen` command (../) is a thin filesystem wrapper around Generate; the
// corpus pin check (internal/docs/corpus_pin_test.go) imports this same core so
// drift detection regenerates through the identical extraction path the
// committed corpus was built with — there is no second, divergent extractor to
// keep in sync. Generate returns the corpus in memory (per-kind sections plus a
// manifest); writing the shards and manifest to disk is the caller's job
// (WriteShard / WriteJSON), so a test can regenerate without mutating the repo.
package gencore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/mjmorales/funpack/mcp/internal/docs"
)

// Roots holds the resolved absolute source directories for one generation run.
type Roots struct {
	SpecDir   string // funpack-spec repo root
	SpecMD    string // funpack-spec/spec (NN-*.md prose)
	EngineFun string // funpack-spec/stdlib/engine (*.fun signatures)
	PluginDir string // <repo>/plugins/funpack (authoring skills)
}

// Result is one generation run's output, held in memory. Spec/Engine/Plugin are
// the per-kind shards (marshaled to corpus/<kind>.json); Manifest is the
// content-derived audit record (marshaled to manifest.json). Reproducible: the
// same Roots content yields a byte-identical Result.
type Result struct {
	Spec     []docs.Section
	Engine   []docs.Section
	Plugin   []docs.Section
	Manifest docs.Manifest
}

// ResolveRoots locates the generator's source directories relative to moduleRoot
// (the mcp/ module root), with FUNPACK_SPEC_DIR overriding the spec sibling-repo
// default (<repo>/../funpack-spec). It stats each source root and errors when
// one is missing, so a misconfigured FUNPACK_SPEC_DIR fails loudly rather than
// emitting an empty corpus.
func ResolveRoots(moduleRoot string) (Roots, error) {
	repoRoot := filepath.Dir(moduleRoot) // <repo>/ (mcp/ sits at repo root)

	specDir := os.Getenv("FUNPACK_SPEC_DIR")
	if specDir == "" {
		specDir = filepath.Join(repoRoot, "..", "funpack-spec")
	}
	specDir, err := filepath.Abs(specDir)
	if err != nil {
		return Roots{}, err
	}

	r := Roots{
		SpecDir:   specDir,
		SpecMD:    filepath.Join(specDir, "spec"),
		EngineFun: filepath.Join(specDir, "stdlib", "engine"),
		PluginDir: filepath.Join(repoRoot, "plugins", "funpack"),
	}
	for _, p := range []string{r.SpecMD, r.EngineFun, r.PluginDir} {
		if _, err := os.Stat(p); err != nil {
			return Roots{}, fmt.Errorf("source root missing: %s (%w)", p, err)
		}
	}
	return r, nil
}

// Generate runs the three extractors against r and assembles the in-memory
// Result, including the content-derived manifest. It performs no filesystem
// writes — the caller decides where (or whether) to persist the shards.
func Generate(r Roots) (Result, error) {
	specSecs, specHash, err := extractSpec(r.SpecMD)
	if err != nil {
		return Result{}, fmt.Errorf("extract spec: %w", err)
	}
	engineSecs, engineHash, err := extractEngine(r.EngineFun)
	if err != nil {
		return Result{}, fmt.Errorf("extract engine: %w", err)
	}
	pluginSecs, pluginHash, err := extractPlugin(r.PluginDir)
	if err != nil {
		return Result{}, fmt.Errorf("extract plugin: %w", err)
	}

	specRef := gitDescribe(r.SpecDir)
	funVersion := funpackVersion()

	manifest := docs.Manifest{
		SpecRef:        specRef,
		FunpackVersion: funVersion,
		TotalSections:  len(specSecs) + len(engineSecs) + len(pluginSecs),
		Sources: []docs.SourceRecord{
			{Root: "funpack-spec/spec", Kind: docs.KindSpec, Ref: specRef, Sections: len(specSecs), ContentHash: specHash},
			{Root: "funpack-spec/stdlib/engine", Kind: docs.KindEngine, Ref: specRef, Sections: len(engineSecs), ContentHash: engineHash},
			{Root: "plugins/funpack", Kind: docs.KindPlugin, Ref: funVersion, Sections: len(pluginSecs), ContentHash: pluginHash},
		},
	}
	return Result{Spec: specSecs, Engine: engineSecs, Plugin: pluginSecs, Manifest: manifest}, nil
}

// HashSections is the content hash over the sections' anchors and text, exported
// so the pin check can recompute a source's hash directly when asserting a
// mutated manifest is detected as drift. A content change between regens shows
// up in the manifest's per-source hash.
func HashSections(sections []docs.Section) string {
	h := sha256.New()
	for _, s := range sections {
		h.Write([]byte(s.Anchor))
		h.Write([]byte{0})
		h.Write([]byte(s.Text))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

// MarshalJSON renders v exactly as the committed corpus files are written:
// indented two spaces with a trailing newline. Byte-comparing this against a
// committed file is the corpus-shard drift test.
func MarshalJSON(v any) ([]byte, error) {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}
	return append(data, '\n'), nil
}

// WriteShard writes one per-kind section slice to corpusDir/name.
func WriteShard(corpusDir, name string, sections []docs.Section) error {
	return WriteJSON(filepath.Join(corpusDir, name), sections)
}

// WriteJSON writes v as indented JSON with a trailing newline, so the committed
// corpus diffs cleanly line-by-line.
func WriteJSON(path string, v any) error {
	data, err := MarshalJSON(v)
	if err != nil {
		return fmt.Errorf("marshal %s: %w", path, err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// --- spec extraction ---------------------------------------------------------

var headingRe = regexp.MustCompile(`^(#{1,3})\s+(.+?)\s*$`)

// extractSpec walks spec/NN-*.md and emits one Section per H1/H2/H3 heading,
// the body running until the next same-or-shallower heading. Headings inside
// fenced code blocks are ignored. Returns the sections and a content hash.
func extractSpec(dir string) ([]docs.Section, string, error) {
	return extractMarkdownTree(dir, dir, docs.KindSpec, func(rel string) bool {
		return strings.HasSuffix(rel, ".md")
	})
}

// --- plugin extraction -------------------------------------------------------

// extractPlugin walks the plugin's skills tree and emits one Section per heading
// in every SKILL.md and references/*.md, anchored by repo-relative path.
func extractPlugin(dir string) ([]docs.Section, string, error) {
	skillsRoot := filepath.Join(dir, "skills")
	return extractMarkdownTree(skillsRoot, dir, docs.KindPlugin, func(rel string) bool {
		return strings.HasSuffix(rel, ".md")
	})
}

// extractMarkdownTree is the shared heading-splitter for prose corpora. walkRoot
// is the directory walked; anchorBase is the directory anchors/sources are made
// relative to (so plugin anchors keep the skills/... prefix).
func extractMarkdownTree(walkRoot, anchorBase string, kind docs.Kind, include func(rel string) bool) ([]docs.Section, string, error) {
	var paths []string
	err := filepath.WalkDir(walkRoot, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, relErr := filepath.Rel(walkRoot, p)
		if relErr != nil {
			return relErr
		}
		if include(filepath.ToSlash(rel)) {
			paths = append(paths, p)
		}
		return nil
	})
	if err != nil {
		return nil, "", err
	}
	sort.Strings(paths)

	var sections []docs.Section
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			return nil, "", err
		}
		rel, err := filepath.Rel(anchorBase, p)
		if err != nil {
			return nil, "", err
		}
		source := filepath.ToSlash(rel)
		sections = append(sections, splitHeadings(string(raw), source, kind)...)
	}
	return sections, HashSections(sections), nil
}

// splitHeadings turns one markdown document into heading-delimited sections.
// Anchors are "<source>#<slug>"; a duplicate slug within a file is suffixed
// "-2", "-3", … so anchors stay unique and stable per content.
func splitHeadings(content, source string, kind docs.Kind) []docs.Section {
	lines := strings.Split(content, "\n")
	var sections []docs.Section
	slugCounts := map[string]int{}

	var curTitle string
	var curBody []string
	inFence := false

	flush := func() {
		if curTitle == "" {
			return
		}
		text := strings.TrimSpace(strings.Join(curBody, "\n"))
		curBody = nil
		// Skip an organizational parent heading whose only content is its
		// subheadings — it carries no searchable passage of its own, and each
		// child heading is emitted as its own section.
		if text == "" {
			return
		}
		slug := slugify(curTitle)
		slugCounts[slug]++
		if n := slugCounts[slug]; n > 1 {
			slug = fmt.Sprintf("%s-%d", slug, n)
		}
		sections = append(sections, docs.Section{
			Anchor: source + "#" + slug,
			Kind:   kind,
			Title:  curTitle,
			Text:   text,
			Source: source,
		})
	}

	for _, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "```") {
			inFence = !inFence
			curBody = append(curBody, line)
			continue
		}
		if !inFence {
			if m := headingRe.FindStringSubmatch(line); m != nil {
				flush()
				curTitle = m[2]
				continue
			}
		}
		curBody = append(curBody, line)
	}
	flush()
	return sections
}

// --- engine extraction -------------------------------------------------------

var (
	docLineRe  = regexp.MustCompile(`^@doc\("(.*)"\)\s*$`)
	declHeadRe = regexp.MustCompile(`^(extern\s+fn|fn|extern\s+type|data|enum|let)\s+([A-Za-z_][A-Za-z0-9_]*)`)
)

// extractEngine reads stdlib/engine/*.fun and emits one Section per declaration
// (fn, extern fn, extern type, data, enum, let), pairing each with its
// immediately-preceding @doc line. The signature is the declaration head; a
// non-extern fn's body is dropped so the section carries the signature, not the
// implementation.
func extractEngine(dir string) ([]docs.Section, string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, "", err
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".fun") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	var sections []docs.Section
	for _, name := range files {
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, "", err
		}
		module := strings.TrimSuffix(name, ".fun")
		source := "engine/" + name
		sections = append(sections, splitEngineFile(string(raw), module, source)...)
	}
	return sections, HashSections(sections), nil
}

// splitEngineFile turns one .fun signature file into per-declaration sections.
// The anchor is "engine/<module>#<decl-name>"; a name repeated within a module
// (UFCS overloads on different self types, e.g. axis/empty) is suffixed.
func splitEngineFile(content, module, source string) []docs.Section {
	lines := strings.Split(content, "\n")
	var sections []docs.Section
	nameCounts := map[string]int{}

	var pendingDoc string
	for i := 0; i < len(lines); i++ {
		trimmed := strings.TrimSpace(lines[i])
		if m := docLineRe.FindStringSubmatch(trimmed); m != nil {
			pendingDoc = unescapeDoc(m[1])
			continue
		}
		if m := declHeadRe.FindStringSubmatch(trimmed); m != nil {
			name := m[2]
			sig, consumed := signature(lines, i)
			i += consumed
			anchorName := slugify(name)
			nameCounts[anchorName]++
			if n := nameCounts[anchorName]; n > 1 {
				anchorName = fmt.Sprintf("%s-%d", anchorName, n)
			}
			text := sig
			if pendingDoc != "" {
				text = pendingDoc + "\n\n" + sig
			}
			sections = append(sections, docs.Section{
				Anchor: "engine/" + module + "#" + anchorName,
				Kind:   docs.KindEngine,
				Title:  module + "." + name,
				Text:   text,
				Source: source,
			})
			pendingDoc = ""
			continue
		}
		// Any non-doc, non-decl line (imports, blank, body continuation) clears
		// a dangling @doc so it never attaches to the wrong declaration.
		if trimmed != "" {
			pendingDoc = ""
		}
	}
	return sections
}

// signature returns the declaration signature beginning at lines[start] and the
// count of EXTRA lines consumed past start. For a function (fn / extern fn) the
// body is dropped — the section carries the signature head, not the
// implementation. For a type declaration (data / enum / extern type / let) the
// brace-delimited field or variant list IS the signature and is kept verbatim,
// spanning multiple lines when the type spreads its members.
func signature(lines []string, start int) (string, int) {
	head := strings.TrimSpace(lines[start])
	isFn := strings.HasPrefix(head, "fn ") || strings.HasPrefix(head, "extern fn ")

	if isFn {
		if i := strings.Index(head, "{"); i >= 0 {
			return strings.TrimSpace(head[:i]), 0
		}
		return head, 0
	}

	// Type declaration: if the brace closes on the head line (or there is no
	// brace), the head is the whole signature. Otherwise accumulate lines until
	// braces balance.
	opens := strings.Count(head, "{")
	closes := strings.Count(head, "}")
	if opens == 0 || opens == closes {
		return head, 0
	}
	depth := opens - closes
	collected := []string{head}
	for j := start + 1; j < len(lines); j++ {
		line := lines[j]
		collected = append(collected, line)
		depth += strings.Count(line, "{") - strings.Count(line, "}")
		if depth <= 0 {
			return strings.TrimRight(strings.Join(collected, "\n"), "\n"), j - start
		}
	}
	return strings.Join(collected, "\n"), len(lines) - 1 - start
}

// unescapeDoc reverses the minimal escaping the .fun @doc strings use (\" \\).
func unescapeDoc(s string) string {
	s = strings.ReplaceAll(s, `\"`, `"`)
	s = strings.ReplaceAll(s, `\\`, `\`)
	return s
}

// --- shared helpers ----------------------------------------------------------

var (
	nonSlugRe   = regexp.MustCompile(`[^a-z0-9]+`)
	trimDashRe  = regexp.MustCompile(`^-+|-+$`)
	codeTickRe  = regexp.MustCompile("`")
	multiSpaceR = regexp.MustCompile(`\s+`)
)

// slugify produces a stable lowercase kebab anchor fragment from a heading or
// name. Stable across regen because it depends only on the text content.
func slugify(s string) string {
	s = strings.ToLower(s)
	s = codeTickRe.ReplaceAllString(s, "")
	s = multiSpaceR.ReplaceAllString(s, " ")
	s = nonSlugRe.ReplaceAllString(s, "-")
	s = trimDashRe.ReplaceAllString(s, "")
	if s == "" {
		s = "section"
	}
	return s
}

// gitDescribe returns `git -C <dir> describe --tags --always`, or "unknown" on
// failure (a shallow or detached checkout still yields a short sha).
func gitDescribe(dir string) string {
	out, err := exec.Command("git", "-C", dir, "describe", "--tags", "--always").Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}

// funpackVersion returns the first line of `funpack version`, or "unknown" when
// the binary is not on PATH.
func funpackVersion() string {
	out, err := exec.Command("funpack", "version").Output()
	if err != nil {
		return "unknown"
	}
	first := strings.SplitN(strings.TrimSpace(string(out)), "\n", 2)[0]
	return strings.TrimSpace(first)
}
