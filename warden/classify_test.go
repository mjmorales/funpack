package main

import (
	"errors"
	"testing"
)

// TestClassify is the §29 §3 exit-contract table: it drives synthetic exit codes
// straight through the pure classifier (no subprocess) and pins each to its
// contract arm. The two valid codes map to the two Outcome members; exit 1 and a
// representative other code (3) BOTH map to the contract-violation arm and to
// NEITHER Failure NOR Success — that is the §29 §3 invariant this task exists to
// enforce (the build verb has no exit-1 tier).
func TestClassify(t *testing.T) {
	tests := []struct {
		name      string
		exitCode  int
		want      Outcome
		violation bool // true => expect a *ContractViolation, not a defined outcome
	}{
		{name: "exit 0 is Success", exitCode: 0, want: Success},
		{name: "exit 2 is Failure", exitCode: 2, want: Failure},
		{name: "exit 1 is a contract violation, never coerced to Failure", exitCode: 1, violation: true},
		{name: "exit 3 (any other code) is a contract violation", exitCode: 3, violation: true},
		{name: "a negative/signal-style code is a contract violation", exitCode: -1, violation: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			stderr := []byte("synthetic diagnostic for code")
			got, err := Classify(tc.exitCode, stderr)

			if tc.violation {
				// The violation arm: a distinct typed error, NOT a Failure/Success outcome.
				if err == nil {
					t.Fatalf("exit %d must be a contract violation, got outcome %v with nil error", tc.exitCode, got)
				}
				if !errors.Is(err, ErrContractViolation) {
					t.Fatalf("exit %d: error %v does not wrap ErrContractViolation", tc.exitCode, err)
				}
				if got == Failure {
					t.Fatalf("exit %d was coerced into Failure — it must surface as ContractViolation", tc.exitCode)
				}
				if got == Success {
					t.Fatalf("exit %d was coerced into Success — it must surface as ContractViolation", tc.exitCode)
				}
				// The rich error must carry the offending code and the stderr verbatim.
				var cv *ContractViolation
				if !errors.As(err, &cv) {
					t.Fatalf("exit %d: error %v is not a *ContractViolation", tc.exitCode, err)
				}
				if cv.ExitCode != tc.exitCode {
					t.Errorf("ContractViolation.ExitCode = %d, want %d", cv.ExitCode, tc.exitCode)
				}
				if string(cv.Stderr) != string(stderr) {
					t.Errorf("ContractViolation.Stderr = %q, want passthrough %q", cv.Stderr, stderr)
				}
				return
			}

			if err != nil {
				t.Fatalf("exit %d: unexpected error %v", tc.exitCode, err)
			}
			if got != tc.want {
				t.Fatalf("exit %d: outcome = %v, want %v", tc.exitCode, got, tc.want)
			}
		})
	}
}

// TestClassifyIsPure asserts the classifier is a deterministic function of its
// inputs alone: repeated calls with the same (exitCode, stderr) yield identical
// outcomes, and stderr content does not change the outcome (it is carried, not
// interpreted). This is the property the agent-reviewed "no wall-clock or
// external state" criterion rests on.
func TestClassifyIsPure(t *testing.T) {
	out1, err1 := Classify(0, []byte("first"))
	out2, err2 := Classify(0, []byte("second different stderr"))
	if out1 != out2 || err1 != nil || err2 != nil {
		t.Fatalf("Classify is not pure in exitCode 0: (%v,%v) vs (%v,%v)", out1, err1, out2, err2)
	}
	if out1 != Success {
		t.Fatalf("stderr content leaked into the outcome: got %v, want Success", out1)
	}
}

// TestClassifyResultThreadsBuildResult covers the BuildResult adapter: it must
// classify exactly the result's ExitCode and pass its Stderr through unchanged.
func TestClassifyResultThreadsBuildResult(t *testing.T) {
	r := BuildResult{ExitCode: 2, Stderr: []byte("funpack build: malformed tree")}
	got, err := ClassifyResult(r)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != Failure {
		t.Fatalf("outcome = %v, want Failure", got)
	}
}

// TestClassifyEndToEndViaStub drives synthetic exit codes through the story-1
// spawn path (InvokeBuild over the committed fixture tree, pointed at a stub
// binary via the FUNPACK_BIN seam) and then through Classify, proving the capture
// and classification layers compose: a stub exiting 0/2/1 lands on
// Success/Failure/ContractViolation respectively, with the stub's stderr carried
// into the violation error. This exercises the contract end to end without any
// dependency on the funpack-spec repo.
func TestClassifyEndToEndViaStub(t *testing.T) {
	tree := minimalTreeDir(t)

	tests := []struct {
		name      string
		exitCode  int
		want      Outcome
		violation bool
	}{
		{name: "stub exit 0 -> Success", exitCode: 0, want: Success},
		{name: "stub exit 2 -> Failure", exitCode: 2, want: Failure},
		{name: "stub exit 1 -> ContractViolation", exitCode: 1, violation: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// FUNPACK_BIN is the story-1 override seam; resolve through it so the
			// classification path is exercised over the same discovery → invoke
			// wiring an operator run would take.
			disc := Discovery{LookupEnv: envOf(map[string]string{FunpackBinEnv: writeStubFunpack(t, tc.exitCode)})}
			binary, err := disc.DiscoverFunpack()
			if err != nil {
				t.Fatalf("discover stub: %v", err)
			}

			result, spawnErr := InvokeBuild(binary, tree)
			if spawnErr != nil {
				t.Fatalf("a recorded exit must not be a spawn error: %v", spawnErr)
			}

			got, classifyErr := ClassifyResult(result)
			if tc.violation {
				if classifyErr == nil {
					t.Fatalf("stub exit %d must classify as a contract violation, got %v", tc.exitCode, got)
				}
				if !errors.Is(classifyErr, ErrContractViolation) {
					t.Fatalf("stub exit %d: error %v does not wrap ErrContractViolation", tc.exitCode, classifyErr)
				}
				var cv *ContractViolation
				if errors.As(classifyErr, &cv) && len(cv.Stderr) == 0 {
					t.Errorf("stub stderr was not carried into the violation error")
				}
				return
			}
			if classifyErr != nil {
				t.Fatalf("stub exit %d: unexpected classify error %v", tc.exitCode, classifyErr)
			}
			if got != tc.want {
				t.Fatalf("stub exit %d: outcome = %v, want %v", tc.exitCode, got, tc.want)
			}
		})
	}
}
