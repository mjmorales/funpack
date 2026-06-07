package main

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/mjmorales/funpack/warden/index"
)

// writeStubTestFunpack writes a shell stub standing in for the funpack binary's
// `test` verb: it echoes a pass/fail line plus its working directory to stdout, a
// marker to stderr, and exits with exitCode — the FUNPACK_BIN seam the
// adjudication spawn path runs over without a funpack-spec dependency. Echoing
// `pwd` proves InvokeTest set the subprocess cwd to the supplied tree, mirroring
// writeStubFunpack's build-verb stub.
func writeStubTestFunpack(t *testing.T, exitCode int) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "funpack-test-stub")
	script := "#!/bin/sh\n" +
		"echo \"funpack test: stub verb=$1 cwd=$(pwd)\"\n" +
		"echo \"funpack test: stub diagnostic\" 1>&2\n" +
		"exit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write test stub: %v", err)
	}
	return path
}

// TestAdjudicateTestExit pins the §29 §4 named-test exit contract: each synthetic
// code maps to its verdict tier with no subprocess. The three valid codes are the
// three Verdict members (0→verified, 1→failed, 2→error); the exit-1 tier is the
// case that proves this classifier is NOT the build classifier — exit 1 is a
// legitimate FAILED verdict here, never a contract violation. Any other code is a
// contract violation mapping to VerdictUnknown, never coerced into a verdict.
func TestAdjudicateTestExit(t *testing.T) {
	tests := []struct {
		name      string
		exitCode  int
		want      Verdict
		violation bool // true => expect a *TestContractViolation, not a defined verdict
	}{
		{name: "exit 0 all-pass is Verified", exitCode: 0, want: VerdictVerified},
		{name: "exit 1 assertions-failed is Failed (NOT a violation, unlike build)", exitCode: 1, want: VerdictFailed},
		{name: "exit 2 compile-error is Error", exitCode: 2, want: VerdictError},
		{name: "exit 3 (any other code) is a contract violation", exitCode: 3, violation: true},
		{name: "a negative/signal-style code is a contract violation", exitCode: -1, violation: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			stderr := []byte("synthetic test diagnostic")
			got, err := AdjudicateTestExit(tc.exitCode, stderr)

			if tc.violation {
				if err == nil {
					t.Fatalf("exit %d must be a contract violation, got verdict %v with nil error", tc.exitCode, got)
				}
				if !errors.Is(err, ErrTestContractViolation) {
					t.Fatalf("exit %d: error %v does not wrap ErrTestContractViolation", tc.exitCode, err)
				}
				if got != VerdictUnknown {
					t.Fatalf("exit %d was coerced into %v — it must surface as VerdictUnknown + violation", tc.exitCode, got)
				}
				var cv *TestContractViolation
				if !errors.As(err, &cv) {
					t.Fatalf("exit %d: error %v is not a *TestContractViolation", tc.exitCode, err)
				}
				if cv.ExitCode != tc.exitCode {
					t.Errorf("TestContractViolation.ExitCode = %d, want %d", cv.ExitCode, tc.exitCode)
				}
				if !bytes.Equal(cv.Stderr, stderr) {
					t.Errorf("TestContractViolation.Stderr = %q, want passthrough %q", cv.Stderr, stderr)
				}
				return
			}

			if err != nil {
				t.Fatalf("exit %d: unexpected error %v", tc.exitCode, err)
			}
			if got != tc.want {
				t.Fatalf("exit %d: verdict = %v, want %v", tc.exitCode, got, tc.want)
			}
		})
	}
}

// TestAdjudicateTestExitDivergesFromBuildClassify is the regression guard for the
// "do not reuse/bend the build Classify" constraint: the SAME exit code (1) means
// FAILED for the test verb but a contract VIOLATION for the build verb. The two
// classifiers must disagree on this code — if they ever agree, one has been bent
// to the other's contract.
func TestAdjudicateTestExitDivergesFromBuildClassify(t *testing.T) {
	testVerdict, testErr := AdjudicateTestExit(1, nil)
	if testErr != nil {
		t.Fatalf("test verb exit 1 must be a clean Failed verdict, got error %v", testErr)
	}
	if testVerdict != VerdictFailed {
		t.Fatalf("test verb exit 1 = %v, want VerdictFailed", testVerdict)
	}

	_, buildErr := Classify(1, nil)
	if buildErr == nil {
		t.Fatal("build verb exit 1 must be a contract violation — the two exit contracts must not be interchangeable")
	}
	if !errors.Is(buildErr, ErrContractViolation) {
		t.Fatalf("build verb exit 1 error %v does not wrap ErrContractViolation", buildErr)
	}
}

// TestAdjudicateTestExitIsPure asserts the verdict is a deterministic function of
// its inputs alone: repeated calls with the same (exitCode, stderr) yield
// identical verdicts, and stderr content does not change the verdict (it is
// carried into the violation error, never interpreted). This is the property the
// "no governance dependency on a clock or external state" boundary rests on.
func TestAdjudicateTestExitIsPure(t *testing.T) {
	v1, e1 := AdjudicateTestExit(0, []byte("first"))
	v2, e2 := AdjudicateTestExit(0, []byte("second different stderr"))
	if v1 != v2 || e1 != nil || e2 != nil {
		t.Fatalf("AdjudicateTestExit is not pure at exit 0: (%v,%v) vs (%v,%v)", v1, e1, v2, e2)
	}
	if v1 != VerdictVerified {
		t.Fatalf("stderr content leaked into the verdict: got %v, want VerdictVerified", v1)
	}
}

// TestInvokeTestCapturesAndSetsCwd drives the test-verb spawn primitive over the
// committed fixture tree pointed at a stub via the FUNPACK_BIN seam: the stub is
// invoked with the `test` verb, its cwd is the supplied tree, stderr is captured
// separately, and the exit code is recorded raw.
func TestInvokeTestCapturesAndSetsCwd(t *testing.T) {
	tree := minimalTreeDir(t)
	stub := writeStubTestFunpack(t, 0)

	result, err := InvokeTest(stub, tree)
	if err != nil {
		t.Fatalf("unexpected spawn error: %v", err)
	}

	stdout := string(result.Stdout)
	if !strings.Contains(stdout, "verb=test") {
		t.Errorf("stdout missing test verb, got %q", stdout)
	}
	wantCwd := evalSymlinks(t, tree)
	if !strings.Contains(stdout, "cwd="+wantCwd) {
		t.Errorf("subprocess cwd not the tree dir: want cwd=%q in stdout, got %q", wantCwd, stdout)
	}
	if got := string(result.Stderr); !strings.Contains(got, "stub diagnostic") {
		t.Errorf("stderr not captured separately, got %q", got)
	}
	if result.ExitCode != 0 {
		t.Errorf("exit code = %d, want 0", result.ExitCode)
	}
}

// TestInvokeTestCapturesAssertionFailExit covers the test verb's exit-1 tier as a
// CAPTURED outcome, not a spawn error: a non-zero funpack test exit (1 here, the
// assertions-failed tier the build verb never produces) must come back with a nil
// spawn error and ExitCode==1, so the verdict layer — not the spawn layer —
// decides it means FAILED.
func TestInvokeTestCapturesAssertionFailExit(t *testing.T) {
	tree := minimalTreeDir(t)
	stub := writeStubTestFunpack(t, 1)

	result, err := InvokeTest(stub, tree)
	if err != nil {
		t.Fatalf("a non-zero funpack test exit must be a captured outcome, not a spawn error: %v", err)
	}
	if result.ExitCode != 1 {
		t.Errorf("exit code = %d, want 1", result.ExitCode)
	}
}

// TestInvokeTestSpawnFailureIsError covers the genuine-spawn-failure mode: a path
// that does not name an executable yields an error, distinct from "funpack test
// ran and returned non-zero".
func TestInvokeTestSpawnFailureIsError(t *testing.T) {
	tree := minimalTreeDir(t)
	_, err := InvokeTest(filepath.Join(t.TempDir(), "nonexistent-funpack"), tree)
	if err == nil {
		t.Fatal("expected a spawn error for a missing binary, got nil")
	}
}

// TestAdjudicateTestEndToEndViaStub drives the full primary verdict path —
// discovery (FUNPACK_BIN seam) → InvokeTest → AdjudicateTestResult — over the
// committed fixture tree with a stub binary, proving the spawn and verdict layers
// compose: a stub exiting 0/1/2 lands on Verified/Failed/Error, and an
// off-contract code surfaces as a violation. No funpack-spec dependency.
func TestAdjudicateTestEndToEndViaStub(t *testing.T) {
	tree := minimalTreeDir(t)

	tests := []struct {
		name      string
		exitCode  int
		want      Verdict
		violation bool
	}{
		{name: "stub exit 0 -> Verified", exitCode: 0, want: VerdictVerified},
		{name: "stub exit 1 -> Failed", exitCode: 1, want: VerdictFailed},
		{name: "stub exit 2 -> Error", exitCode: 2, want: VerdictError},
		{name: "stub exit 4 -> violation", exitCode: 4, violation: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			disc := Discovery{LookupEnv: envOf(map[string]string{FunpackBinEnv: writeStubTestFunpack(t, tc.exitCode)})}
			binary, err := disc.DiscoverFunpack()
			if err != nil {
				t.Fatalf("discover stub: %v", err)
			}

			result, spawnErr := InvokeTest(binary, tree)
			if spawnErr != nil {
				t.Fatalf("a recorded exit must not be a spawn error: %v", spawnErr)
			}

			got, verdictErr := AdjudicateTestResult(result)
			if tc.violation {
				if verdictErr == nil {
					t.Fatalf("stub exit %d must adjudicate as a contract violation, got %v", tc.exitCode, got)
				}
				if !errors.Is(verdictErr, ErrTestContractViolation) {
					t.Fatalf("stub exit %d: error %v does not wrap ErrTestContractViolation", tc.exitCode, verdictErr)
				}
				return
			}
			if verdictErr != nil {
				t.Fatalf("stub exit %d: unexpected verdict error %v", tc.exitCode, verdictErr)
			}
			if got != tc.want {
				t.Fatalf("stub exit %d: verdict = %v, want %v", tc.exitCode, got, tc.want)
			}
		})
	}
}

// pongProjectLine is a byte-faithful golden `project` record matching the pong
// shape funpack/index_contract.odin emits (the same fixture the index package's
// decoder tests assert against): all gates passing and the authored ten-tag
// registry. The structural adjudication tests decode it through the real spine →
// project-decode path so they evaluate the same ProjectRecord warden consumes
// from a live stream — never a hand-built struct that could drift from the
// decoded shape.
const pongProjectLine = `{"schema_version":2,` +
	`"entrypoints":[{"name":"main","pipeline":"Pong","tick_hz":60,"bindings":"bindings"}],` +
	`"builds":[{"name":"native","platform":"desktop"}],` +
	`"tag_registry":["game","startup","render","spatial","paddle","ball","input","score","board","event"],` +
	`"capabilities":["Render","Input","State"],` +
	`"pipeline_flattened":[{"ordinal":0,"stage":"startup","behavior":"setup"}],` +
	`"gate_results":[` +
	`{"gate":"Cyclomatic","passed":true},` +
	`{"gate":"Nesting","passed":true},` +
	`{"gate":"Fn_Size","passed":true},` +
	`{"gate":"Arity","passed":true},` +
	`{"gate":"Exhaustiveness","passed":true},` +
	`{"gate":"Duplication","passed":true},` +
	`{"gate":"Effect_Closure","passed":true}]}`

// decodeGoldenProject runs the golden line through the public index decoder the
// way warden consumes a real stream: DecodeStream splits + version-gates + kind-
// classifies, then DecodeProjectRecord runs the exact-match field decode. The
// structural verdict tests adjudicate against THIS decoded record, exercising the
// integrated index contract rather than a bypass.
func decodeGoldenProject(t *testing.T, line string) index.ProjectRecord {
	t.Helper()
	records, err := index.DecodeStream(strings.NewReader(line + "\n"))
	if err != nil {
		t.Fatalf("decode golden stream: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("expected 1 record, got %d", len(records))
	}
	if records[0].Kind != index.RecordKindProject {
		t.Fatalf("expected a project record, got %s", records[0].Kind)
	}
	project, err := index.DecodeProjectRecord(records[0])
	if err != nil {
		t.Fatalf("decode project record: %v", err)
	}
	return project
}

// gateFailingProjectLine is the golden pong line with the Duplication gate flipped
// to passed:false — the structural-FAILED fixture proving AdjudicateGateFamily
// returns VerdictFailed (not an error, not Verified) when the named family did
// not clear.
const gateFailingProjectLine = `{"schema_version":2,` +
	`"entrypoints":[{"name":"main","pipeline":"Pong","tick_hz":60,"bindings":"bindings"}],` +
	`"builds":[{"name":"native","platform":"desktop"}],` +
	`"tag_registry":["game"],` +
	`"capabilities":["Render","Input","State"],` +
	`"pipeline_flattened":[{"ordinal":0,"stage":"startup","behavior":"setup"}],` +
	`"gate_results":[` +
	`{"gate":"Cyclomatic","passed":true},` +
	`{"gate":"Nesting","passed":true},` +
	`{"gate":"Fn_Size","passed":true},` +
	`{"gate":"Arity","passed":true},` +
	`{"gate":"Exhaustiveness","passed":true},` +
	`{"gate":"Duplication","passed":false},` +
	`{"gate":"Effect_Closure","passed":true}]}`

// TestAdjudicateGateFamily covers the structural "a structural gate clears"
// verdict source over a decoded project record: a passing family is Verified, a
// failing family (Duplication in the failing fixture) is Failed. The lookup keys
// on the family, never a positional index.
func TestAdjudicateGateFamily(t *testing.T) {
	allPass := decodeGoldenProject(t, pongProjectLine)
	if v, err := AdjudicateGateFamily(allPass, index.GateFamilyCyclomatic); err != nil || v != VerdictVerified {
		t.Fatalf("a cleared Cyclomatic gate must be Verified, got (%v, %v)", v, err)
	}
	if v, err := AdjudicateGateFamily(allPass, index.GateFamilyDuplication); err != nil || v != VerdictVerified {
		t.Fatalf("a cleared Duplication gate must be Verified, got (%v, %v)", v, err)
	}

	failing := decodeGoldenProject(t, gateFailingProjectLine)
	if v, err := AdjudicateGateFamily(failing, index.GateFamilyDuplication); err != nil || v != VerdictFailed {
		t.Fatalf("an uncleared Duplication gate must be Failed (checked negative), got (%v, %v)", v, err)
	}
	// A sibling family still passes in the same failing record — the predicate is
	// per-family, not whole-vector.
	if v, err := AdjudicateGateFamily(failing, index.GateFamilyNesting); err != nil || v != VerdictVerified {
		t.Fatalf("a sibling cleared gate must still be Verified, got (%v, %v)", v, err)
	}
}

// TestAdjudicateGateFamilyAbsentIsError covers the authoring-error arm: because
// funpack emits the whole gate vector, a family the record does not report can
// only mean the criterion named a family outside the closed set — surfaced as
// VerdictUnknown + ErrGateFamilyAbsent, never coerced into Failed.
func TestAdjudicateGateFamilyAbsentIsError(t *testing.T) {
	project := decodeGoldenProject(t, pongProjectLine)
	v, err := AdjudicateGateFamily(project, index.GateFamily("Nonexistent_Family"))
	if err == nil {
		t.Fatalf("an absent gate family must error, got verdict %v with nil error", v)
	}
	if !errors.Is(err, ErrGateFamilyAbsent) {
		t.Fatalf("error %v does not wrap ErrGateFamilyAbsent", err)
	}
	if v != VerdictUnknown {
		t.Fatalf("an absent family must yield VerdictUnknown, got %v", v)
	}
}

// TestAdjudicateTagCardinality covers the structural "a @gtag query returns the
// expected cardinality" verdict source over a decoded project record's
// tag_registry: present/absent membership and an exact-count predicate, each in
// its holding and not-holding case.
func TestAdjudicateTagCardinality(t *testing.T) {
	project := decodeGoldenProject(t, pongProjectLine) // ten authored tags, each once

	tests := []struct {
		name      string
		predicate TagPredicate
		want      Verdict
	}{
		{name: "present tag is Verified", predicate: TagPredicate{Tag: "paddle", Op: TagPresent}, want: VerdictVerified},
		{name: "missing tag fails a present predicate", predicate: TagPredicate{Tag: "absent_tag", Op: TagPresent}, want: VerdictFailed},
		{name: "absent predicate holds for a missing tag", predicate: TagPredicate{Tag: "absent_tag", Op: TagAbsent}, want: VerdictVerified},
		{name: "absent predicate fails for a present tag", predicate: TagPredicate{Tag: "ball", Op: TagAbsent}, want: VerdictFailed},
		{name: "exact-count 1 holds for a once-registered tag", predicate: TagPredicate{Tag: "score", Op: TagExactCount, Want: 1}, want: VerdictVerified},
		{name: "exact-count 2 fails for a once-registered tag", predicate: TagPredicate{Tag: "score", Op: TagExactCount, Want: 2}, want: VerdictFailed},
		{name: "exact-count 0 holds for a missing tag", predicate: TagPredicate{Tag: "absent_tag", Op: TagExactCount, Want: 0}, want: VerdictVerified},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := AdjudicateTagCardinality(project, tc.predicate)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("predicate %+v: verdict = %v, want %v", tc.predicate, got, tc.want)
			}
		})
	}
}

// TestAdjudicateTagCardinalityInvalidPredicate covers the malformed-predicate
// arm: an unknown operator and a negative exact-count are both authoring errors
// surfaced as VerdictUnknown + ErrTagPredicateInvalid, never coerced into a
// verdict.
func TestAdjudicateTagCardinalityInvalidPredicate(t *testing.T) {
	project := decodeGoldenProject(t, pongProjectLine)

	cases := []TagPredicate{
		{Tag: "paddle", Op: TagCardinalityUnknown},
		{Tag: "paddle", Op: TagExactCount, Want: -1},
	}
	for _, predicate := range cases {
		v, err := AdjudicateTagCardinality(project, predicate)
		if err == nil {
			t.Fatalf("predicate %+v must error, got verdict %v with nil error", predicate, v)
		}
		if !errors.Is(err, ErrTagPredicateInvalid) {
			t.Fatalf("predicate %+v: error %v does not wrap ErrTagPredicateInvalid", predicate, err)
		}
		if v != VerdictUnknown {
			t.Fatalf("predicate %+v: want VerdictUnknown, got %v", predicate, v)
		}
	}
}

// TestAdjudicateTestLivePong is the live end-to-end seam (skip-gated): it builds
// the funpack binary, runs `funpack test` on a clean copy of the corpus pong
// example, and confirms warden maps the all-pass exit 0 to VerdictVerified. It is
// skipped whenever its preconditions are absent (no funpack-spec checkout, no Go
// toolchain to build funpack, or the build fails) so the unit suite stays
// hermetic over the committed testdata tree; the live AC is driver-verified at
// close regardless.
func TestAdjudicateTestLivePong(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping live funpack test seam in -short mode")
	}

	pongSrc := liveCorpusPong(t)
	if pongSrc == "" {
		t.Skip("funpack-spec pong example not available; live seam skipped")
	}
	binary := liveFunpackBinary(t)
	if binary == "" {
		t.Skip("funpack binary not buildable/available; live seam skipped")
	}

	// Copy the corpus example into a throwaway dir so `funpack test` writes its
	// derived products outside the read-only sibling checkout.
	work := filepath.Join(t.TempDir(), "pong")
	if out, err := exec.Command("cp", "-R", pongSrc, work).CombinedOutput(); err != nil {
		t.Skipf("copy pong corpus failed, skipping live seam: %v: %s", err, out)
	}

	result, err := InvokeTest(binary, work)
	if err != nil {
		t.Fatalf("live funpack test spawn failed: %v", err)
	}
	verdict, err := AdjudicateTestResult(result)
	if err != nil {
		t.Fatalf("live funpack test exit %d is off-contract: %v (stderr: %s)", result.ExitCode, err, result.Stderr)
	}
	if verdict != VerdictVerified {
		t.Fatalf("live pong all-pass must map to Verified, got %v (exit %d, stdout: %s)", verdict, result.ExitCode, result.Stdout)
	}
}

// liveCorpusPong resolves the funpack-spec pong example tree relative to the repo
// checkout, returning "" when the sibling checkout is absent (the skip signal).
func liveCorpusPong(t *testing.T) string {
	t.Helper()
	candidate, err := filepath.Abs(filepath.Join("..", "..", "funpack-spec", "examples", "pong"))
	if err != nil {
		return ""
	}
	if _, statErr := os.Stat(filepath.Join(candidate, "funpack_configs")); statErr != nil {
		return ""
	}
	return candidate
}

// liveFunpackBinary resolves an already-built funpack binary via the FUNPACK_BIN
// override or the conventional in-repo build path, returning "" when none is
// available (the skip signal). It does NOT build funpack itself — the live AC's
// build step is driven by the orchestrator's bash criterion (`task -d funpack
// binary`), so this test only consumes an existing binary.
func liveFunpackBinary(t *testing.T) string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		return ""
	}
	disc := Discovery{RepoRoot: repoRoot}
	binary, discErr := disc.DiscoverFunpack()
	if discErr != nil {
		return ""
	}
	return binary
}
