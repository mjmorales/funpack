// Acceptance-criterion adjudication: the seam where warden decides whether a
// task's `criterion` is EARNED rather than self-attested (spec §29 §4 — "keep
// agents on track" backstop for "drifts from operator intent", and §29 §4's
// "Acceptance criteria are earned, not self-attested"). warden reaches funpack
// ONLY over the §29 process boundary — it spawns the CLI and reads structured
// output — and NEVER links the compiler or the grammar, so adjudication carries
// no governance dependency on the engine. It also NEVER writes source (§29 §3:
// the agent is the sole writer); it only invokes and reads.
//
// §29 §4 names three verdict shapes for a criterion; this seam implements them
// as two source families:
//
//   - PRIMARY — "a named `test` passes": warden runs `funpack test` in the
//     target project tree as a subprocess and maps its exit code to a verdict.
//     This is a DIFFERENT exit contract from `funpack build` (classify.go) — the
//     test verb has a legitimate exit-1 tier (assertions failed), so it is
//     modeled here as its own classifier rather than reusing or bending the
//     build classifier, whose exit 1 is a contract violation.
//   - STRUCTURAL — "a structural gate clears" and "a `@gtag` query returns the
//     expected cardinality": warden reads the SAME decoded `project` record the
//     index decoder produces (index.ProjectRecord) and evaluates a predicate
//     over project.gate_results (a gate family cleared) or project.tag_registry
//     (a tag-membership / cardinality assertion). No subprocess re-run — the
//     structural fact already lives in the contract funpack emitted.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"

	"github.com/mjmorales/funpack/warden/index"
)

// Verdict is warden's closed enum over the outcome of adjudicating one
// acceptance criterion. It is the shared vocabulary all three §29 §4 verdict
// sources resolve into — the `funpack test` exit contract and the structural
// predicates over the decoded `project` record all collapse to exactly these
// three states, so a downstream consumer (the task DB, an operator report) reads
// one enum regardless of which source produced it.
//
// The zero value is deliberately VerdictUnknown (NOT Verified): a source returns
// the zero value only on its failure arm, paired with a non-nil error, so a
// caller that ignores the error and consumes the Verdict gets an explicitly
// unresolved value rather than a false pass. There is no default-into-verified
// path anywhere in this seam.
type Verdict int

const (
	// VerdictUnknown is the zero value: the criterion was not adjudicated to a
	// defined outcome. It is what a source returns alongside an error, and is
	// never a result a caller should treat as a pass.
	VerdictUnknown Verdict = iota
	// VerdictVerified: the criterion is earned — the named test's assertions all
	// passed, the gate family cleared, or the tag predicate held.
	VerdictVerified
	// VerdictFailed: the criterion was checked and did NOT hold — the test's
	// assertions failed, the gate family did not clear, or the tag predicate was
	// not satisfied. This is a checked negative, distinct from VerdictUnknown.
	VerdictFailed
	// VerdictError: the criterion could not be checked because the check itself
	// could not run to a conclusion — a `funpack test` compile error (exit 2)
	// means the project never reached the assertion stage, so neither pass nor
	// fail is defined. The criterion's status is undetermined, not failed.
	VerdictError
)

// String renders a verdict for operator-facing task-state messages. It is
// exhaustive over the closed enum; an out-of-range value (only reachable by
// constructing a Verdict directly) renders explicitly rather than panicking.
func (v Verdict) String() string {
	switch v {
	case VerdictUnknown:
		return "unknown"
	case VerdictVerified:
		return "verified"
	case VerdictFailed:
		return "failed"
	case VerdictError:
		return "error"
	default:
		return fmt.Sprintf("Verdict(%d)", int(v))
	}
}

// TestResult is the raw, uninterpreted outcome of one `funpack test` spawn — the
// adjudication-side twin of InvokeBuild's BuildResult. The three captures are
// kept distinct because classification reads only ExitCode while the diagnostic
// and the pass/fail line live in Stderr/Stdout: Stdout carries funpack test's
// "N passed, M failed" line, Stderr carries the compile diagnostic on an exit-2,
// and ExitCode is the raw code with NO verdict applied here.
type TestResult struct {
	Stdout   []byte
	Stderr   []byte
	ExitCode int
}

// InvokeTest spawns `<binary> test` with treeDir as the subprocess working
// directory and captures stdout and stderr into separate buffers — the spawn
// primitive for the PRIMARY (named-test) verdict source. funpack resolves its
// project root from the process working directory (read_project(".") in
// main.odin's run_test_verb), so treeDir becomes the subprocess cwd, exactly the
// wiring InvokeBuild uses for the build verb.
//
// A non-zero funpack exit is NOT an error here — it is a normal, captured
// outcome (the test verb's exit 1 and exit 2 are both contract tiers), so err is
// nil and TestResult.ExitCode holds the code. A non-nil error means the spawn
// itself could not run to a recorded exit (binary unspawnable, treeDir missing)
// — a distinct failure mode from "funpack test ran and returned non-zero".
func InvokeTest(binary, treeDir string) (TestResult, error) {
	cmd := exec.Command(binary, "test")
	cmd.Dir = treeDir

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	runErr := cmd.Run()

	result := TestResult{
		Stdout: stdout.Bytes(),
		Stderr: stderr.Bytes(),
	}

	if runErr == nil {
		// Clean spawn, exit 0: all assertions passed.
		return result, nil
	}

	// A non-zero exit surfaces as *exec.ExitError carrying the recorded code:
	// the test verb's 1 (assertions failed) and 2 (compile error) are both
	// captured outcomes, not spawn failures, so this returns nil error.
	var exitErr *exec.ExitError
	if errors.As(runErr, &exitErr) {
		result.ExitCode = exitErr.ExitCode()
		return result, nil
	}

	// Anything else (binary not found/executable, cwd missing, signal kill) is a
	// genuine spawn failure: the subprocess never produced a recorded exit code.
	return result, fmt.Errorf("warden: funpack test spawn failed: %w", runErr)
}

// ErrTestContractViolation is the typed sentinel for a `funpack test` exit code
// outside the §29 §4 / main.odin contract's three tiers {0, 1, 2}. Callers match
// it with errors.Is to distinguish "the test verb honored the contract" (a
// defined Verdict, nil error) from "the spawned binary did not honor the test
// exit contract at all" (VerdictUnknown, this error). The wrapping
// TestContractViolation carries the offending code and stderr.
var ErrTestContractViolation = errors.New("warden: funpack test exit code violates the §29 §4 contract")

// TestContractViolation is the rich error returned for an off-contract test exit
// code. It wraps ErrTestContractViolation (so errors.Is matches) and carries the
// raw ExitCode plus the captured Stderr verbatim — Stderr is passed through for
// the operator message, never interpreted here.
type TestContractViolation struct {
	ExitCode int
	Stderr   []byte
}

func (e *TestContractViolation) Error() string {
	return fmt.Sprintf(
		"%v: got exit %d (the test verb returns 0 all-pass, 1 assertions-failed, or 2 compile-error; any other code is off-contract): stderr=%q",
		ErrTestContractViolation, e.ExitCode, string(e.Stderr),
	)
}

// Unwrap exposes the sentinel so errors.Is(err, ErrTestContractViolation)
// matches.
func (e *TestContractViolation) Unwrap() error { return ErrTestContractViolation }

// AdjudicateTestExit maps a raw `funpack test` exit code to a Verdict per the
// §29 §4 named-test contract (confirmed against funpack/main.odin's
// run_test_verb / project_test_exit_code):
//
//   - 0 = all assertions passed  → VerdictVerified
//   - 1 = some assertions failed → VerdictFailed
//   - 2 = compile error          → VerdictError (the project never reached the
//     assertion stage, so the criterion is undetermined, not failed)
//
// It is a PURE function of (exitCode, stderr): it reads no clock, no
// environment, and no filesystem, so the same inputs always yield the same
// verdict and it is unit-testable against synthetic codes. This is a SEPARATE
// classifier from the build verb's Classify (classify.go): the test verb's exit
// 1 is a legitimate tier (assertions failed), whereas the build verb's exit 1 is
// a contract violation — the two exit contracts are NOT interchangeable, so they
// are modeled independently rather than one bending the other.
//
// The switch is exhaustive over the contract's three valid codes; every other
// code falls to the contract-violation arm, returning VerdictUnknown (NOT a
// defined verdict) and a *TestContractViolation. stderr is carried through into
// the violation error untouched, never parsed.
func AdjudicateTestExit(exitCode int, stderr []byte) (Verdict, error) {
	switch exitCode {
	case 0:
		return VerdictVerified, nil
	case 1:
		return VerdictFailed, nil
	case 2:
		return VerdictError, nil
	default:
		return VerdictUnknown, &TestContractViolation{ExitCode: exitCode, Stderr: stderr}
	}
}

// AdjudicateTestResult is the convenience adapter that adjudicates a TestResult
// captured by InvokeTest, threading its ExitCode and Stderr into
// AdjudicateTestExit. It keeps the two layers composable — InvokeTest captures,
// AdjudicateTestExit interprets — without InvokeTest taking on any verdict
// semantics, mirroring ClassifyResult over a BuildResult.
func AdjudicateTestResult(r TestResult) (Verdict, error) {
	return AdjudicateTestExit(r.ExitCode, r.Stderr)
}

// ErrGateFamilyAbsent is the typed sentinel returned when a gate-family
// adjudication names a family the decoded `project` record does not report.
// Because funpack emits the WHOLE gate vector every build (every family appears,
// see index.GateResult), an absent family is never "the source has no gates" — it
// is a criterion naming a family outside the closed producer set, a criterion
// authoring error warden surfaces rather than silently treating as failed.
var ErrGateFamilyAbsent = errors.New("warden: criterion names a gate family the project record does not report")

// AdjudicateGateFamily evaluates the STRUCTURAL "a structural gate clears"
// verdict source (§29 §4) over a decoded `project` record: it looks up the named
// gate family in project.GateResults and returns VerdictVerified when that
// family's structural gate passed, VerdictFailed when it did not. It re-runs
// NOTHING — the gate verdict is a derived field funpack already projected into
// the contract (§29 §1: the structural gates live in funpack, their verdicts
// ride the Index Contract), so warden reads the fact rather than re-deriving it,
// which is exactly the "depends only on the contract, never the grammar" boundary.
//
// The lookup keys on the family (never a positional index) because the whole
// vector is emitted in producer-enum order, not a criterion-chosen order. A
// family the record does not report yields VerdictUnknown + ErrGateFamilyAbsent:
// since every family is always present, absence means the criterion named a
// family outside the closed set, an authoring error surfaced rather than coerced
// into a verdict.
func AdjudicateGateFamily(project index.ProjectRecord, family index.GateFamily) (Verdict, error) {
	for _, result := range project.GateResults {
		if result.Gate == family {
			if result.Passed {
				return VerdictVerified, nil
			}
			return VerdictFailed, nil
		}
	}
	return VerdictUnknown, fmt.Errorf("%w: %q (reported families: %v)", ErrGateFamilyAbsent, family, gateFamiliesOf(project))
}

// gateFamiliesOf lists the gate families a decoded `project` record reports, for
// the ErrGateFamilyAbsent diagnostic. It surfaces WHICH families are present so
// an operator reading the error sees the closed set the criterion's family fell
// outside of, rather than a bare "not found".
func gateFamiliesOf(project index.ProjectRecord) []index.GateFamily {
	families := make([]index.GateFamily, 0, len(project.GateResults))
	for _, result := range project.GateResults {
		families = append(families, result.Gate)
	}
	return families
}

// TagCardinality is the comparison operator a tag-cardinality criterion asserts
// against the count of a tag's presence in project.tag_registry — the closed set
// of predicates the "a `@gtag` query returns the expected cardinality" verdict
// source (§29 §4) supports. It is closed: a criterion's operator is one of these
// three, never an arbitrary expression, keeping adjudication a mechanical
// predicate evaluation rather than a query language.
type TagCardinality int

const (
	// TagCardinalityUnknown is the zero value: not a valid operator. A predicate
	// built with it is rejected by AdjudicateTagCardinality rather than silently
	// treated as one of the defined operators.
	TagCardinalityUnknown TagCardinality = iota
	// TagPresent asserts the tag IS in the registry (membership; count >= 1).
	TagPresent
	// TagAbsent asserts the tag is NOT in the registry (count == 0).
	TagAbsent
	// TagExactCount asserts the tag appears EXACTLY Want times in the registry.
	TagExactCount
)

// String renders a cardinality operator for diagnostics.
func (c TagCardinality) String() string {
	switch c {
	case TagPresent:
		return "present"
	case TagAbsent:
		return "absent"
	case TagExactCount:
		return "exact-count"
	default:
		return "unknown"
	}
}

// TagPredicate is one tag-cardinality criterion: a tag name, the cardinality
// operator to apply, and (for TagExactCount only) the expected count. It is the
// authored shape a structural tag criterion decodes into; AdjudicateTagCardinality
// evaluates it against a decoded `project` record's tag_registry.
type TagPredicate struct {
	// Tag is the @gtag name the predicate queries against the registry.
	Tag string
	// Op is the cardinality comparison (closed enum).
	Op TagCardinality
	// Want is the expected count, read ONLY when Op is TagExactCount; ignored for
	// the present/absent operators.
	Want int
}

// ErrTagPredicateInvalid is the typed sentinel returned when a TagPredicate is
// not evaluable — an unknown operator, or a negative expected count. It is a
// criterion-authoring error (the predicate itself is malformed), distinct from
// the predicate evaluating to VerdictFailed.
var ErrTagPredicateInvalid = errors.New("warden: tag-cardinality predicate is not evaluable")

// AdjudicateTagCardinality evaluates the STRUCTURAL "a `@gtag` query returns the
// expected cardinality" verdict source (§29 §4) over a decoded `project`
// record's tag_registry: it counts the predicate's tag in project.TagRegistry
// and compares that count to the predicate's operator. It re-runs NOTHING — the
// tag registry is an AUTHORED field funpack lifts straight from tags.fcfg into
// the contract (§29 §2, §14 §3), so warden reads the registry and applies the
// predicate rather than re-parsing the config, keeping adjudication on the
// contract side of the §29 boundary.
//
// Returns VerdictVerified when the cardinality predicate holds, VerdictFailed
// when it does not. A malformed predicate (unknown operator, negative Want)
// yields VerdictUnknown + ErrTagPredicateInvalid — an authoring error surfaced
// rather than coerced into a verdict, the same discipline AdjudicateGateFamily
// applies to an absent family.
func AdjudicateTagCardinality(project index.ProjectRecord, predicate TagPredicate) (Verdict, error) {
	count := countTag(project.TagRegistry, predicate.Tag)

	switch predicate.Op {
	case TagPresent:
		return verdictOf(count >= 1), nil
	case TagAbsent:
		return verdictOf(count == 0), nil
	case TagExactCount:
		if predicate.Want < 0 {
			return VerdictUnknown, fmt.Errorf("%w: exact-count Want=%d is negative", ErrTagPredicateInvalid, predicate.Want)
		}
		return verdictOf(count == predicate.Want), nil
	default:
		return VerdictUnknown, fmt.Errorf("%w: unknown cardinality operator %v", ErrTagPredicateInvalid, predicate.Op)
	}
}

// countTag returns how many times tag appears in the registry. The registry is a
// list (index.ProjectRecord.TagRegistry) not a set, so a count — not a boolean —
// is the primitive the cardinality operators all derive from: present is
// count>=1, absent is count==0, exact-count is count==Want.
func countTag(registry []string, tag string) int {
	count := 0
	for _, t := range registry {
		if t == tag {
			count++
		}
	}
	return count
}

// verdictOf maps a satisfied/unsatisfied predicate boolean to the corresponding
// Verdict — the single place a structural predicate's boolean becomes a verdict,
// so VerdictVerified/VerdictFailed are never spelled inline at each call site.
func verdictOf(held bool) Verdict {
	if held {
		return VerdictVerified
	}
	return VerdictFailed
}
