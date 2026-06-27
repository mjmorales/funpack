package cli

import "core:fmt"

Cli_Args_Kind :: enum {
	Arbitrary,
	None,
	Exact,
	Minimum,
	Maximum,
	Range,
}

Cli_Args :: struct {
	kind: Cli_Args_Kind,
	min:  int,
	max:  int,
}

// contextless: an arity spec must be buildable at global scope, where Odin's implicit context is absent.
cli_no_args :: proc "contextless" () -> Cli_Args {
	return Cli_Args{kind = .None}
}

cli_exact_args :: proc "contextless" (n: int) -> Cli_Args {
	return Cli_Args{kind = .Exact, min = n, max = n}
}

cli_minimum_args :: proc "contextless" (n: int) -> Cli_Args {
	return Cli_Args{kind = .Minimum, min = n}
}

cli_maximum_args :: proc "contextless" (n: int) -> Cli_Args {
	return Cli_Args{kind = .Maximum, max = n}
}

cli_range_args :: proc "contextless" (lo: int, hi: int) -> Cli_Args {
	return Cli_Args{kind = .Range, min = lo, max = hi}
}

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

cli_plural_args :: proc(n: int) -> string {
	return "arg" if n == 1 else "args"
}
