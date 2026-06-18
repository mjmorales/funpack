// In-package tests for the surface-parity gate. In-package (not docs_test) so the
// negative-control and no-stale-allow-list tests can read residualOverDeclares
// and the model internals directly. Unlike corpus_pin_test.go these tests import
// no gencore, so there is no import cycle to avoid.
package docs

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// repoRootForTest resolves the monorepo root from the package test cwd
// (internal/docs): module root is two up, repo root is its parent.
func repoRootForTest(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	moduleRoot := filepath.Clean(filepath.Join(wd, "..", ".."))
	return filepath.Dir(moduleRoot)
}

// loadAllModels loads the three source models the gate compares: the compiler
// dump (from the committed fixture), the .fun signature files, and the corpus.
func loadAllModels(t *testing.T) (compiler, fun, corpus *SurfaceModel) {
	t.Helper()
	compiler, err := CompilerModelFromFixture()
	if err != nil {
		t.Fatalf("compiler model from fixture: %v", err)
	}
	funSources, err := LoadFunSources(repoRootForTest(t))
	if err != nil {
		t.Fatalf("load .fun sources: %v", err)
	}
	fun = ParseFunModel(funSources)
	c, err := Load()
	if err != nil {
		t.Fatalf("load corpus: %v", err)
	}
	corpus = CorpusEngineModel(c)
	return compiler, fun, corpus
}

// TestSurfaceParityGate is the gate proper: against the CURRENT (restored,
// in-parity) surface, the docs corpus and the .fun signature files advertise no
// surface the compiler dump lacks BEYOND the audited residualOverDeclares
// allow-list. A fresh same-version surface divergence — a corpus/.fun symbol the
// compiler rejects, not on the allow-list — fails here, named. This is the check
// the version-string corpus-pin detector cannot be.
func TestSurfaceParityGate(t *testing.T) {
	compiler, fun, corpus := loadAllModels(t)

	blocking := BlockingFindings(corpus, fun, compiler)
	if len(blocking) > 0 {
		t.Errorf("%s", FormatBlockingFindings(blocking))
	}
}

// TestSurfaceParityDetectsSyntheticDivergence is the negative control proving the
// gate is a real DETECTOR, not a no-op: it injects a same-version surface
// divergence into a COPY of the .fun model — a documented enum variant the
// compiler dump does not admit — and asserts the gate (a) FAILS and (b) NAMES the
// injected symbol with the harmful direction. This is the exact shape of the
// canonical break (a documented Color-palette member like Color::Yellow that the
// compiler rejects). It runs hermetically off the committed
// fixture, so it guards the detector logic even without the Odin toolchain.
func TestSurfaceParityDetectsSyntheticDivergence(t *testing.T) {
	compiler, _, corpus := loadAllModels(t)

	cases := []struct {
		name   string
		inject func(m *SurfaceModel)
		symbol string
		kind   ParityKind
	}{
		{
			// The canonical break: the docs advertise a Color palette
			// member the compiler rejects. Color IS a known compiler type, so the
			// finding is at enum-variant granularity (not subsumed).
			name:   "documented enum variant the compiler lacks (the Color-palette shape)",
			inject: func(m *SurfaceModel) { m.EnumBareVariants["Color"]["Chartreuse"] = true },
			symbol: "Color::Chartreuse",
			kind:   KindEnumVariant,
		},
		{
			// A documented struct-payload variant on a known type the compiler
			// rejects (the Draw::Line shape, but with a name not on the allow-list).
			name:   "documented struct variant the compiler lacks",
			inject: func(m *SurfaceModel) { m.StructVariants["Draw"]["Hologram"] = true },
			symbol: "Draw::Hologram",
			kind:   KindStructVariant,
		},
		{
			// A documented TYPE the compiler does not recognize (the Shape3 shape,
			// but a fresh name): reported at module-type granularity.
			name: "documented module type the compiler lacks",
			inject: func(m *SurfaceModel) {
				if m.ModuleTypes["engine.render"] == nil {
					m.ModuleTypes["engine.render"] = map[string]bool{}
				}
				m.ModuleTypes["engine.render"]["Hologram"] = true
			},
			symbol: "engine.render::Hologram",
			kind:   KindModuleType,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Inject into a fresh copy of the .fun model so the synthetic symbol is
			// the ONLY new divergence; the real residuals stay allow-listed.
			mutated := cloneModel(t)
			tc.inject(mutated)

			blocking := BlockingFindings(corpus, mutated, compiler)
			if len(blocking) == 0 {
				t.Fatalf("synthetic divergence %q was NOT detected — the gate is a no-op", tc.symbol)
			}
			var found *Finding
			for i := range blocking {
				if blocking[i].Symbol == tc.symbol {
					found = &blocking[i]
					break
				}
			}
			if found == nil {
				t.Fatalf("gate fired but did not name %q; blocking findings: %v", tc.symbol, blocking)
			}
			if found.Kind != tc.kind {
				t.Errorf("finding kind = %q, want %q", found.Kind, tc.kind)
			}
			if found.Direction != DirDocsAheadOfCompiler {
				t.Errorf("finding direction = %q, want %q", found.Direction, DirDocsAheadOfCompiler)
			}
			if found.Source != ".fun" {
				t.Errorf("finding source = %q, want %q", found.Source, ".fun")
			}
			// The rendered message must name the symbol and the harmful framing.
			msg := FormatBlockingFindings(blocking)
			if !strings.Contains(msg, tc.symbol) {
				t.Errorf("failure message does not name %q:\n%s", tc.symbol, msg)
			}
			if !strings.Contains(msg, "compiler dump") {
				t.Errorf("failure message lacks the compiler-dump framing:\n%s", msg)
			}
		})
	}
}

// cloneModel returns a deep copy of the live .fun model so a test can mutate it
// without affecting the shared maps.
func cloneModel(t *testing.T) *SurfaceModel {
	t.Helper()
	funSources, err := LoadFunSources(repoRootForTest(t))
	if err != nil {
		t.Fatalf("load .fun sources: %v", err)
	}
	// ParseFunModel builds fresh maps each call, so the result is already an
	// independent copy — no shared backing.
	return ParseFunModel(funSources)
}

// TestNoStaleResidualAllowListEntry asserts every residualOverDeclares entry
// corresponds to a divergence that ACTUALLY occurs against the current compiler
// dump. A stale entry — one whose symbol the compiler now admits, or whose name
// drifted — would silently suppress a finding it no longer matches, masking a
// real future divergence. So when a restore lands and the dump grows, the
// matching entry MUST be removed or this fails. This is the mechanism that
// forces the allow-list to SHRINK toward empty as residual-tracker task
// residual-fun-over-declares-vs--mqjrunkb is drained.
func TestNoStaleResidualAllowListEntry(t *testing.T) {
	compiler, fun, corpus := loadAllModels(t)

	// Collect the actual docs-ahead findings from both doc sources.
	docAhead := map[residualKey]bool{}
	for _, f := range DiffSurfaces(fun, compiler, ".fun") {
		if f.Direction == DirDocsAheadOfCompiler {
			docAhead[residualKey{f.Kind, f.Symbol}] = true
		}
	}
	for _, f := range DiffSurfaces(corpus, compiler, "corpus") {
		if f.Direction == DirDocsAheadOfCompiler {
			docAhead[residualKey{f.Kind, f.Symbol}] = true
		}
	}

	for _, r := range residualOverDeclares {
		if !docAhead[residualKey{r.Kind, r.Symbol}] {
			t.Errorf("stale allow-list entry: {%s %q} no longer corresponds to a divergence — "+
				"the compiler dump now admits it (or the symbol name drifted). Remove it from "+
				"residualOverDeclares (tracker %s).", r.Kind, r.Symbol, residualTrackerTask)
		}
	}
}

// TestSurfaceDumpFixtureMatchesLiveBinary is the freshness pin: when the Odin
// toolchain is present it rebuilds funpack, re-runs `funpack introspect`, and
// asserts the committed testdata/introspect.json fixture equals the live output
// byte-for-byte — so a stale fixture (the surface changed but the fixture was not
// regenerated) fails here. Skips cleanly when Odin is absent, keeping the gate's
// other tests hermetic in a Go-only CI lane. Regenerate with `task
// mcp:surface-dump-regen` on a drift.
func TestSurfaceDumpFixtureMatchesLiveBinary(t *testing.T) {
	live, err := BuildLiveIntrospectDump(repoRootForTest(t))
	if err == ErrOdinUnavailable {
		t.Skip("odin toolchain not on PATH — skipping live introspect freshness pin")
	}
	if err != nil {
		t.Fatalf("build live introspect dump: %v", err)
	}
	committed, err := LoadIntrospectFixture()
	if err != nil {
		t.Fatalf("load committed fixture: %v", err)
	}
	if !bytes.Equal(live, committed) {
		t.Errorf("testdata/introspect.json drifted from the live `funpack introspect` output "+
			"(committed %d bytes vs live %d) — regenerate with `task mcp:surface-dump-regen` and recommit",
			len(committed), len(live))
	}
}

// TestSurfaceParityModelsAreNonEmpty guards against a silently-empty model
// (a parser regression or a missing source) reading as falsely in-parity: an
// empty doc or compiler model would make every diff vacuous. Asserts each of the
// three sources yields a non-trivial surface.
func TestSurfaceParityModelsAreNonEmpty(t *testing.T) {
	compiler, fun, corpus := loadAllModels(t)

	checks := []struct {
		name string
		m    *SurfaceModel
	}{{"compiler", compiler}, {".fun", fun}, {"corpus", corpus}}
	for _, c := range checks {
		if len(c.m.ModuleTypes) == 0 {
			t.Errorf("%s model has zero module types — likely a source/parser regression", c.name)
		}
		if len(c.m.EnumBareVariants) == 0 {
			t.Errorf("%s model has zero enum variant sets — likely a source/parser regression", c.name)
		}
	}
	// The Color palette is the canonical example and must be present and full in
	// every source (9 named members + Rgb struct payload), proving the palette
	// restore holds and the parsers see it.
	for _, c := range checks {
		colors := c.m.EnumBareVariants["Color"]
		for _, named := range []string{"White", "Yellow", "Cyan", "Magenta", "Gray"} {
			if !colors[named] {
				t.Errorf("%s model is missing Color::%s — the palette restore regressed or the parser missed it", c.name, named)
			}
		}
		if !c.m.StructVariants["Color"]["Rgb"] {
			t.Errorf("%s model is missing the Color::Rgb struct payload", c.name)
		}
	}
}

// TestExcludedSurfaceIsDocumented guards the audited exclusion list: every comparison
// axis the gate deliberately skips must carry a non-empty WHY, so an exclusion can
// never silently become a coverage hole (and the list stays referenced, not dead).
func TestExcludedSurfaceIsDocumented(t *testing.T) {
	if len(excludedSurface) == 0 {
		t.Fatal("excludedSurface is empty — the gate's intentional exclusions must stay documented and auditable")
	}
	for i, why := range excludedSurface {
		if strings.TrimSpace(why) == "" {
			t.Errorf("excludedSurface[%d] has an empty WHY — every exclusion must state its reason", i)
		}
	}
}
