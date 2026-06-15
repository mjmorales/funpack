package docs

import "testing"

// TestLoadSectionsWellFormed asserts the embedded corpus loads and every
// section satisfies the loader's invariant: a non-empty Anchor, a valid closed
// Kind, and a non-empty Text. Downstream indices key on these, so a malformed
// section is a corpus-generation bug, not a runtime degradation.
func TestLoadSectionsWellFormed(t *testing.T) {
	corpus, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(corpus.Sections) == 0 {
		t.Fatal("Load returned zero sections; corpus is empty — run `task docs-regen`")
	}

	seen := make(map[string]struct{}, len(corpus.Sections))
	for i, s := range corpus.Sections {
		if s.Anchor == "" {
			t.Errorf("section %d (%q): empty Anchor", i, s.Title)
		}
		if !s.Kind.Valid() {
			t.Errorf("section %d (%s): invalid Kind %q", i, s.Anchor, s.Kind)
		}
		if s.Text == "" {
			t.Errorf("section %d (%s): empty Text", i, s.Anchor)
		}
		if _, dup := seen[s.Anchor]; dup {
			t.Errorf("duplicate anchor %q", s.Anchor)
		}
		seen[s.Anchor] = struct{}{}
	}
}

// TestLoadCoversEveryKind asserts the corpus carries sections of all three
// closed kinds — a generation run that silently dropped a source family (spec,
// engine, or plugin) regresses the whole docs-search surface.
func TestLoadCoversEveryKind(t *testing.T) {
	corpus, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	for _, k := range []Kind{KindSpec, KindEngine, KindPlugin} {
		if got := len(corpus.ByKind(k)); got == 0 {
			t.Errorf("kind %q: zero sections", k)
		}
	}
}

// TestLoadManifestRecordsProvenance asserts the manifest parses and records the
// generation provenance the stale-corpus check (a later task) reads: a spec git
// ref, a funpack version, and a per-kind source tally consistent with the
// loaded corpus.
func TestLoadManifestRecordsProvenance(t *testing.T) {
	m, err := LoadManifest()
	if err != nil {
		t.Fatalf("LoadManifest: %v", err)
	}
	if m.SpecRef == "" {
		t.Error("manifest SpecRef is empty")
	}
	if m.FunpackVersion == "" {
		t.Error("manifest FunpackVersion is empty")
	}
	if len(m.Sources) == 0 {
		t.Fatal("manifest records zero sources")
	}

	corpus, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if m.TotalSections != len(corpus.Sections) {
		t.Errorf("manifest TotalSections=%d but corpus has %d sections", m.TotalSections, len(corpus.Sections))
	}
	for k, want := range m.CountByKind() {
		if got := len(corpus.ByKind(k)); got != want {
			t.Errorf("kind %q: manifest tallies %d, corpus has %d", k, want, got)
		}
	}
}

// TestKindValid pins the closed Kind enum: the three named values are valid and
// an unknown value is rejected. A consumer switching over Kind relies on this
// set staying closed.
func TestKindValid(t *testing.T) {
	for _, k := range []Kind{KindSpec, KindEngine, KindPlugin} {
		if !k.Valid() {
			t.Errorf("%q should be a valid Kind", k)
		}
	}
	if Kind("grammar").Valid() {
		t.Error(`Kind("grammar") should be invalid`)
	}
}
