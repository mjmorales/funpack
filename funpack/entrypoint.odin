// The emit-facing entrypoint selection: the runtime wiring a pipeline carries
// no configuration for (spec §07 §1 — wiring lives in the entrypoint, never the
// pipeline) is parsed by the ONE §14 entrypoints production
// (parse_entrypoints_fcfg, project.odin, over the shared lex_fcfg config
// lexer). This file owns only what the artifact's [entrypoint] section needs
// beyond that grammar (docs/artifact-format.md §15): selecting the single
// entrypoint the v1 artifact carries, and converting the `60hz` tick token to
// its integer Hz. There is no second entrypoints reader — a grammar change
// lands in the shared production and every consumer follows. Reference
// validation against the checked source (§07) is validate_entrypoints'
// job; stage_emit runs it between the parse and this selection.
//
// The selection is pure over the config text: it derives no value from a
// clock, a path, or a host byte. There are no multi-rate ticks (§07 §1), so
// the entrypoint carries one Hz.
package funpack

import "core:strconv"
import "core:strings"

// Entrypoint_Config is the resolved [entrypoint] record (docs/artifact-format.md
// §15): the entrypoint block label, the root pipeline whose flattened order the
// artifact carries, the fixed tick rate in integer Hz, and the bindings fn whose
// resolved table the artifact's [bindings] section carries.
Entrypoint_Config :: struct {
	name:     string,
	pipeline: string,
	tick_hz:  int,
	bindings: string,
}

// select_entrypoint selects the wiring the artifact's [entrypoint 1] section
// carries from the parsed §14 entrypoints. The v1 artifact carries exactly one
// entrypoint record and there is no selection mechanism, so a config declaring
// more than one block rejects with the dedicated Multiple_Entrypoints arm —
// never a silent first-block pick. A tick whose digits do not parse as an
// integer rate (`60khz` passes the grammar's `hz`-suffix check but is not a
// rate) rejects as malformed.
select_entrypoint :: proc(parsed: Entrypoints) -> (config: Entrypoint_Config, err: Entrypoints_Error) {
	if len(parsed.entrypoints) != 1 {
		return Entrypoint_Config{}, .Multiple_Entrypoints
	}
	block := parsed.entrypoints[0]
	hz, ok := parse_tick_hz(block.tick)
	if !ok {
		return Entrypoint_Config{}, .Malformed_Entrypoints_Fcfg
	}
	return Entrypoint_Config{
			name = block.name,
			pipeline = block.pipeline,
			tick_hz = hz,
			bindings = block.bindings,
		},
		.None
}

// parse_tick_hz extracts the integer Hz from a `Nhz` tick token (`60hz` → 60).
// The tick rate is a fixed integer Hz (docs/artifact-format.md §15); a token
// without the `hz` suffix or with a non-integer rate is rejected. This is the
// single tick converter — the emit selection and the Index Contract lift both
// route through it.
parse_tick_hz :: proc(text: string) -> (hz: int, ok: bool) {
	digits := strings.trim_suffix(text, "hz")
	if digits == text {
		return 0, false
	}
	return strconv.parse_int(digits)
}
