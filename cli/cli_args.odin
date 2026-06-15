// Positional-argument arity for the CLI framework: the closed Cli_Args_Kind
// validator set (the Cobra ExactArgs / MinimumNArgs / … analogs) plus the
// constructors a command declares its spec with and the pure check cli_parse
// runs after binding flags. Arity is a mechanical count test — pattern, not
// judgment — so it lives wholly on the engine side (design principle §1) and is
// a deterministic function of the positional count alone.
package cli

import "core:fmt"

// Cli_Args_Kind is the closed positional-arity taxonomy. Arbitrary (the zero
// value) accepts any count; None forbids positionals; Exact/Minimum/Maximum/
// Range bound the count against the spec's min/max. A new arity shape is a new
// member here plus its arm in cli_args_check and cli_args_expectation.
Cli_Args_Kind :: enum {
	Arbitrary,
	None,
	Exact,
	Minimum,
	Maximum,
	Range,
}

// Cli_Args is a command's positional-arity spec: the kind plus the bounds it
// reads (min for Exact/Minimum/Range, max for Maximum/Range). The zero value
// {kind = .Arbitrary} accepts any count, so a command that omits the field
// places no positional constraint.
Cli_Args :: struct {
	kind: Cli_Args_Kind,
	min:  int,
	max:  int,
}

// cli_no_args forbids positionals — the spec the argumentless verbs (version,
// test) and the strict warden subcommands (holes, probes, debt, tags, pipeline)
// declare, so a trailing token there is a usage error rather than a silently
// ignored argument.
cli_no_args :: proc() -> Cli_Args {
	return Cli_Args{kind = .None}
}

// cli_exact_args requires exactly n positionals.
cli_exact_args :: proc(n: int) -> Cli_Args {
	return Cli_Args{kind = .Exact, min = n, max = n}
}

// cli_minimum_args requires at least n positionals.
cli_minimum_args :: proc(n: int) -> Cli_Args {
	return Cli_Args{kind = .Minimum, min = n}
}

// cli_maximum_args allows at most n positionals.
cli_maximum_args :: proc(n: int) -> Cli_Args {
	return Cli_Args{kind = .Maximum, max = n}
}

// cli_range_args allows between lo and hi positionals inclusive — the spec
// `warden find` and `warden graph` declare (an optional single positional:
// cli_range_args(0, 1)).
cli_range_args :: proc(lo: int, hi: int) -> Cli_Args {
	return Cli_Args{kind = .Range, min = lo, max = hi}
}

// cli_args_check is the pure arity test: does a positional count of n satisfy
// the spec? Total over the closed kind set, so cli_parse can trust every spec
// adjudicates without a fallthrough.
cli_args_check :: proc(spec: Cli_Args, n: int) -> bool {
	switch spec.kind {
	case .Arbitrary:
		return true
	case .None:
		return n == 0
	case .Exact:
		return n == spec.min
	case .Minimum:
		return n >= spec.min
	case .Maximum:
		return n <= spec.max
	case .Range:
		return n >= spec.min && n <= spec.max
	}
	return false
}

// cli_args_expectation renders the advisory phrase a Bad_Arg_Count error names
// (e.g. "at most 1 arg", "exactly 2 args") so the usage body tells an operator
// the arity rule. Advisory only — the machine contract is the exit code; this
// is the human detail. Deterministic over the spec.
cli_args_expectation :: proc(spec: Cli_Args, allocator := context.allocator) -> string {
	switch spec.kind {
	case .Arbitrary:
		return "any number of args"
	case .None:
		return "no args"
	case .Exact:
		return fmt.aprintf("exactly %d %s", spec.min, cli_plural_args(spec.min), allocator = allocator)
	case .Minimum:
		return fmt.aprintf("at least %d %s", spec.min, cli_plural_args(spec.min), allocator = allocator)
	case .Maximum:
		return fmt.aprintf("at most %d %s", spec.max, cli_plural_args(spec.max), allocator = allocator)
	case .Range:
		return fmt.aprintf("between %d and %d args", spec.min, spec.max, allocator = allocator)
	}
	return ""
}

// cli_plural_args picks "arg"/"args" for a count, so the expectation phrase
// reads naturally ("exactly 1 arg", "exactly 2 args").
cli_plural_args :: proc(n: int) -> string {
	return "arg" if n == 1 else "args"
}
