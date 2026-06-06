// funpack-build exit classification: the deterministic layer that interprets a
// raw subprocess exit code (captured by invoke.go's BuildResult) into warden's
// closed outcome enum per the spec §29 §3 build exit contract. The contract is
// total over exactly two codes — confirmed against funpack/main.odin's
// run_build_verb and funpack/build.odin:
//
//   - 0 = Success: the build wrote BOTH products (the runtime artifact AND the
//     index.ndjson). There is no partial-product tier — a build emits both or
//     none.
//   - 2 = Failure: a malformed §14 tree, ANY compile/gate failure, OR a host IO
//     failure writing the products. All three collapse to one tier because none
//     of them leaves a usable product; a compile error is never a counted
//     failure.
//
// CRITICAL — exit 1 is a CONTRACT VIOLATION, not an outcome. The build verb has
// NO assertion-failure tier (that belongs to the `test` verb), so it never
// returns 1. A 1 — or any code outside {0, 2} — means the spawned binary did not
// honor §29 §3 (wrong binary, a future contract revision, a wrapper leaking its
// own code). warden surfaces that as a distinct typed error rather than coercing
// it into Failure, because silently folding an unknown code into Failure would
// mask a broken contract behind a normal-looking build failure.
package main

import (
	"errors"
	"fmt"
)

// Outcome is warden's closed enum over the §29 §3 `funpack build` exit contract.
// It names exactly the two valid outcomes the contract defines. The zero value is
// deliberately outcomeInvalid (NOT Success): the classifier returns the zero
// value only on the contract-violation arm, paired with a non-nil error, so a
// caller that ignores the error and consumes the Outcome gets an explicitly
// invalid value rather than a false Success. There is no default-into-success
// path anywhere in this package.
type Outcome int

const (
	// outcomeInvalid is the zero value: not a contract outcome. It is what
	// Classify returns alongside a *ContractViolation, and is never a result a
	// caller should act on as if the build had a defined outcome.
	outcomeInvalid Outcome = iota
	// Success is exit 0: the build wrote both products (artifact + index.ndjson).
	Success
	// Failure is exit 2: a malformed §14 tree, a compile/gate failure, or a host
	// IO failure writing the products — the build wrote neither product.
	Failure
)

// String renders the outcome for operator-facing messages. It is exhaustive over
// the closed enum; an out-of-range value (only reachable by constructing an
// Outcome directly, never via Classify) renders explicitly rather than panicking.
func (o Outcome) String() string {
	switch o {
	case outcomeInvalid:
		return "invalid"
	case Success:
		return "success"
	case Failure:
		return "failure"
	default:
		return fmt.Sprintf("Outcome(%d)", int(o))
	}
}

// ErrContractViolation is the typed sentinel for an exit code outside the §29 §3
// build contract's {0, 2}. Callers match it with errors.Is to distinguish "the
// build honored the contract and failed" (Failure, nil error) from "the spawned
// binary did not honor the build exit contract at all" (zero Outcome, this
// error). The wrapping ContractViolation carries the offending code and stderr.
var ErrContractViolation = errors.New("warden: funpack build exit code violates the §29 §3 contract")

// ContractViolation is the rich error returned for an off-contract exit code. It
// wraps ErrContractViolation (so errors.Is matches) and carries the raw ExitCode
// plus the captured Stderr verbatim — Stderr is passed through for the operator
// message, never interpreted here.
type ContractViolation struct {
	ExitCode int
	Stderr   []byte
}

func (e *ContractViolation) Error() string {
	return fmt.Sprintf(
		"%v: got exit %d (the build verb returns only 0 or 2; exit 1 is the test verb's assertion tier and must never reach here): stderr=%q",
		ErrContractViolation, e.ExitCode, string(e.Stderr),
	)
}

// Unwrap exposes the sentinel so errors.Is(err, ErrContractViolation) matches.
func (e *ContractViolation) Unwrap() error { return ErrContractViolation }

// Classify maps a raw `funpack build` exit code to warden's closed Outcome enum
// per the §29 §3 contract. It is a PURE function of (exitCode, stderr): it reads
// no clock, no environment, and no filesystem, so the same inputs always yield
// the same result and it is unit-testable in isolation against synthetic codes.
//
// The switch is exhaustive over the contract's two valid codes; every other code
// — 1 included — falls to the contract-violation arm, returning outcomeInvalid
// (NOT Failure, NOT Success) and a *ContractViolation (which wraps
// ErrContractViolation). The non-nil error is the signal to branch, exactly as
// Go's (value, error) convention requires; the returned outcomeInvalid is the
// explicit "no defined outcome" sentinel. stderr is carried through into the
// violation error untouched, never parsed.
func Classify(exitCode int, stderr []byte) (Outcome, error) {
	switch exitCode {
	case 0:
		return Success, nil
	case 2:
		return Failure, nil
	default:
		return outcomeInvalid, &ContractViolation{ExitCode: exitCode, Stderr: stderr}
	}
}

// ClassifyResult is the convenience adapter that classifies a BuildResult
// captured by InvokeBuild, threading its ExitCode and Stderr into Classify. It
// keeps the two layers composable — invoke.go captures, classify.go interprets —
// without invoke.go taking on any outcome semantics.
func ClassifyResult(r BuildResult) (Outcome, error) {
	return Classify(r.ExitCode, r.Stderr)
}
