// Live-build helper for the surface-dump freshness pin: builds a working-tree
// funpack and captures `funpack introspect`, used by the gate's freshness test
// to assert the committed testdata/introspect.json fixture is current. Kept out
// of the hermetic parity-diff path — the diff reads the embedded fixture, this
// only runs when the Odin toolchain is present.
package docs

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
)

// ErrOdinUnavailable is returned by BuildLiveIntrospectDump when the Odin
// toolchain is not on PATH, so the freshness pin can skip cleanly (mirroring the
// corpus pin's skip-when-sources-absent discipline) rather than fail in a
// Go-only CI lane.
var ErrOdinUnavailable = errors.New("odin toolchain not on PATH")

// BuildLiveIntrospectDump compiles cmd/funpack from repoRoot and runs `funpack
// introspect`, returning the dump bytes. The build is the DEFAULT (non-LIVE)
// arm: `funpack introspect` is a pure compiler-side verb projecting the
// surface.odin rodata, byte-identical whether or not the SDL-linking
// FUNPACK_LIVE define is set, so the non-LIVE build avoids the libsdl2 link
// while producing the same dump. Returns ErrOdinUnavailable when odin is not on
// PATH (the caller skips), and a build/run error otherwise.
func BuildLiveIntrospectDump(repoRoot string) ([]byte, error) {
	if _, err := exec.LookPath("odin"); err != nil {
		return nil, ErrOdinUnavailable
	}
	tmp, err := os.MkdirTemp("", "funpack-introspect-pin-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)

	bin := filepath.Join(tmp, "funpack-pin")
	build := exec.Command("odin", "build", "cmd/funpack", "-out:"+bin)
	build.Dir = repoRoot
	if out, err := build.CombinedOutput(); err != nil {
		return nil, &buildError{stage: "odin build cmd/funpack", output: string(out), err: err}
	}

	run := exec.Command(bin, "introspect")
	run.Dir = repoRoot
	out, err := run.Output()
	if err != nil {
		return nil, &buildError{stage: "funpack introspect", output: string(out), err: err}
	}
	return out, nil
}

// buildError carries the failing stage and its output so a freshness-pin failure
// names whether the build or the introspect run broke.
type buildError struct {
	stage  string
	output string
	err    error
}

func (e *buildError) Error() string {
	return e.stage + ": " + e.err.Error() + "\n" + e.output
}

func (e *buildError) Unwrap() error { return e.err }
