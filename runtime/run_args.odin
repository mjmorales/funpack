package funpack_runtime

import "core:strconv"

Live_Args :: struct {
	artifact:     string,
	out_override: string,
	seed:         Maybe(i64),
}

parse_live_argv :: proc(args: []string) -> (parsed: Live_Args, ok: bool) {
	positionals := make([dynamic]string, 0, 2, context.temp_allocator)
	i := 1
	for i < len(args) {
		arg := args[i]
		if arg == "--seed" {
			if i + 1 >= len(args) {
				return {}, false
			}
			value, parse_ok := strconv.parse_i64(args[i + 1])
			if !parse_ok {
				return {}, false
			}
			parsed.seed = value
			i += 2
			continue
		}
		append(&positionals, arg)
		i += 1
	}
	if len(positionals) < 1 {
		return {}, false
	}
	parsed.artifact = positionals[0]
	if len(positionals) >= 2 {
		parsed.out_override = positionals[1]
	}
	return parsed, true
}
