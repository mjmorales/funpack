package cmd

import (
	"errors"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/rs/zerolog"
)

// withFunpackSeam swaps the resolve/preflight seam for the duration of a test and
// restores the production wiring afterward, so each case drives startupPreflight in
// isolation without execing a real funpack binary.
func withFunpackSeam(t *testing.T, resolve func() (funpack.Binary, error), preflight func(funpack.Binary) error) {
	t.Helper()
	origResolve, origPreflight := resolveFunpack, preflightFunpack
	resolveFunpack, preflightFunpack = resolve, preflight
	t.Cleanup(func() { resolveFunpack, preflightFunpack = origResolve, origPreflight })
}

// inRangeBinary is a synthetic funpack whose schemas all sit inside contract.Supported.
func inRangeBinary() funpack.Binary {
	return funpack.Binary{
		Path: "/fake/funpack",
		Version: contract.VersionInfo{
			Version: "v9.9.9",
			Schemas: map[string]int{
				contract.SchemaArtifact: contract.Supported[contract.SchemaArtifact].Min,
				contract.SchemaIndex:    contract.Supported[contract.SchemaIndex].Min,
			},
		},
	}
}

// outOfRangeBinary is a synthetic funpack whose artifact schema is one past the
// supported max, so the real Preflight produces an authentic schema-mismatch error.
func outOfRangeBinary() funpack.Binary {
	return funpack.Binary{
		Path: "/fake/funpack",
		Version: contract.VersionInfo{
			Version: "v9.9.9",
			Schemas: map[string]int{
				contract.SchemaArtifact: contract.Supported[contract.SchemaArtifact].Max + 1,
			},
		},
	}
}

// TestStartupPreflightNotFoundWarnsAndProceeds: a funpack-not-found resolve is
// non-fatal — serve proceeds (docs tools need no funpack), so startupPreflight
// returns nil.
func TestStartupPreflightNotFoundWarnsAndProceeds(t *testing.T) {
	withFunpackSeam(t,
		func() (funpack.Binary, error) { return funpack.Binary{}, funpack.ErrNotFound },
		func(funpack.Binary) error { t.Fatal("preflight must not run when resolve fails"); return nil },
	)

	if err := startupPreflight(zerolog.Nop()); err != nil {
		t.Fatalf("not-found must be non-fatal, got %v", err)
	}
}

// TestStartupPreflightResolveErrorWarnsAndProceeds: a resolvable-but-broken funpack
// (e.g. FUNPACK_BIN not executable) is also non-fatal — warn and serve regardless.
func TestStartupPreflightResolveErrorWarnsAndProceeds(t *testing.T) {
	brokenResolve := errors.New("FUNPACK_BIN is not executable")
	withFunpackSeam(t,
		func() (funpack.Binary, error) { return funpack.Binary{}, brokenResolve },
		func(funpack.Binary) error { t.Fatal("preflight must not run when resolve fails"); return nil },
	)

	if err := startupPreflight(zerolog.Nop()); err != nil {
		t.Fatalf("resolve error must be non-fatal, got %v", err)
	}
}

// TestStartupPreflightInRangeProceeds: a resolvable funpack with in-range schemas
// passes the gate — startupPreflight returns nil and serve binds the transport.
func TestStartupPreflightInRangeProceeds(t *testing.T) {
	bin := inRangeBinary()
	withFunpackSeam(t,
		func() (funpack.Binary, error) { return bin, nil },
		funpack.Preflight, // real preflight against an in-range binary
	)

	if err := startupPreflight(zerolog.Nop()); err != nil {
		t.Fatalf("in-range funpack must pass the gate, got %v", err)
	}
}

// TestStartupPreflightOutOfRangeRefuses: a resolvable funpack with an out-of-range
// schema fails closed — startupPreflight returns the schema-mismatch error so serve
// exits non-zero.
func TestStartupPreflightOutOfRangeRefuses(t *testing.T) {
	bin := outOfRangeBinary()
	withFunpackSeam(t,
		func() (funpack.Binary, error) { return bin, nil },
		funpack.Preflight, // real preflight against an out-of-range binary
	)

	err := startupPreflight(zerolog.Nop())
	if err == nil {
		t.Fatal("out-of-range funpack must refuse startup, got nil error")
	}
}
