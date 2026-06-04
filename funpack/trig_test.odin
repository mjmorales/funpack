package funpack

import "core:testing"

@(test)
test_trig_exact_at_zero :: proc(t: ^testing.T) {
	// Cardinal exactness is structural: the odd polynomial vanishes at
	// zero and the even one yields its unit constant term.
	testing.expect_value(t, fixed_sin(Fixed(0)), Fixed(0))
	testing.expect_value(t, fixed_cos(Fixed(0)), FIXED_ONE)
}

@(test)
test_pi_pinned_bits :: proc(t: ^testing.T) {
	// round(π · 2³²) = 13493037705 — the constant is its own golden bits.
	testing.expect_value(t, PI_FIXED, Fixed(13493037705))
}

@(test)
test_pipeline_trig_golden_values :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert sin(0.0) == 0.0\n" +
		"assert cos(0.0) == 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}
