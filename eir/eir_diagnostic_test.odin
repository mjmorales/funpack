package eir

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(private = "file")
diag :: proc(severity: Severity, rule, message: string) -> Diagnostic {
	related := make([]Related_Location, 1, context.temp_allocator)
	related[0] = Related_Location{file = "b.odin", line = 30, col = 1, note = "clone site 2 of 3"}
	return Diagnostic {
		file = "a.odin",
		line = 10,
		col = 2,
		severity = severity,
		rule = rule,
		message = message,
		related = related,
	}
}

@(test)
test_diag_human_gnu_format :: proc(t: ^testing.T) {
	diags := []Diagnostic{diag(.Warning, "dup", "duplicated proc_lit, 3 sites, dedup 24")}
	human := render_diagnostics_human(diags, context.temp_allocator)
	expected :=
		"a.odin:10:2: warning: duplicated proc_lit, 3 sites, dedup 24 [dup]\n" +
		"b.odin:30:1: note: clone site 2 of 3\n" +
		"\n" +
		"1 warning\n"
	testing.expect_value(t, human, expected)
}

@(test)
test_diag_summary_tally :: proc(t: ^testing.T) {
	diags := []Diagnostic {
		diag(.Error, "dup", "e"),
		diag(.Warning, "near", "w1"),
		diag(.Warning, "dead", "w2"),
	}
	human := render_diagnostics_human(diags, context.temp_allocator)
	testing.expect(t, strings.has_suffix(human, "\n1 error, 2 warnings\n"), "the summary tallies errors then warnings, pluralized")

	warns_only := render_diagnostics_human([]Diagnostic{diag(.Warning, "dead", "w")}, context.temp_allocator)
	testing.expect(t, strings.has_suffix(warns_only, "\n1 warning\n"), "a single warning is not pluralized and omits the error category")
}

@(test)
test_diag_no_findings :: proc(t: ^testing.T) {
	empty := []Diagnostic{}

	human := render_diagnostics_human(empty, context.temp_allocator)
	testing.expect_value(t, human, "no findings\n")

	body := render_diagnostics_json(empty, context.temp_allocator)
	testing.expect(t, strings.contains(body, "\"diagnostics\":[]"), "an empty set's JSON must carry an empty diagnostics array")

	report: Diagnostics_Report
	err := json.unmarshal_string(body, &report, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "the empty JSON must still parse into Diagnostics_Report")
	testing.expect_value(t, len(report.diagnostics), 0)
}

@(test)
test_diag_json_byte_stable_and_valid :: proc(t: ^testing.T) {
	diags := []Diagnostic{diag(.Error, "dup", "duplicated for, 2 sites, dedup 30")}

	first := render_diagnostics_json(diags, context.temp_allocator)
	second := render_diagnostics_json(diags, context.temp_allocator)
	testing.expect(t, first == second, "the diagnostic JSON must be byte-stable across renders")

	report: Diagnostics_Report
	err := json.unmarshal_string(first, &report, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "the JSON must parse into Diagnostics_Report")
	testing.expect_value(t, report.schema_version, DIAGNOSTIC_REPORT_SCHEMA_VERSION)
	testing.expect_value(t, len(report.diagnostics), 1)
	if len(report.diagnostics) == 1 {
		d := report.diagnostics[0]
		testing.expect_value(t, d.file, "a.odin")
		testing.expect_value(t, d.line, 10)
		testing.expect_value(t, d.col, 2)
		testing.expect_value(t, d.severity, "error")
		testing.expect_value(t, d.rule, "dup")
		testing.expect_value(t, len(d.related), 1)
		if len(d.related) == 1 {
			testing.expect_value(t, d.related[0].file, "b.odin")
			testing.expect_value(t, d.related[0].note, "clone site 2 of 3")
		}
	}
}

@(test)
test_diag_severity_label :: proc(t: ^testing.T) {
	testing.expect_value(t, severity_label(.Error), "error")
	testing.expect_value(t, severity_label(.Warning), "warning")
	testing.expect_value(t, severity_label(.Note), "note")
}
