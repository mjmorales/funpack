// The shared DIAGNOSTIC surface every eir lint reports through — the one place the
// operator-facing output shape lives, so a new lint inherits the format instead of
// hand-rolling a table. Each lint projects its findings onto []Diagnostic and hands them
// to one of two renderers: a GNU/compiler one-line-per-finding human stream
// (`file:line:col: severity: message [rule]`, the convention go vet / clippy / golangci-lint
// / ruff all share) and a byte-stable unified JSON array. Both are pure functions of the
// diagnostic slice — no map is walked, no input order leaks — so a double render is
// byte-identical, the property the regression tests pin.
//
// A finding is a PRIMARY location plus zero or more RELATED locations. The dup and near
// tiers are multi-site: a clone class is one primary at its highest-leverage site with the
// other sites attached as `note:` lines; a near-miss pair is one primary with its
// counterpart attached. The dead tier is a point finding with no related sites. Folding all
// three onto one shape is what keeps the output uniform across every verb — one format, one
// parser, whatever the lint.
//
// Severity drives both the human label and the summary tally: a bare report emits Warnings,
// the `--baseline` ratchet emits Errors on the offending classes (a gate failure is an
// error, not advice). Related locations are always Notes and never counted — they annotate a
// primary, they are not findings in their own right.
package eir

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// DIAGNOSTIC_REPORT_SCHEMA_VERSION leads the JSON object so a consumer reads the shape
// version before the diagnostics — the self-describing lead every eir report uses.
DIAGNOSTIC_REPORT_SCHEMA_VERSION :: 1

// Severity is the closed set of finding levels. Warning is the report default; Error is the
// gate verdict on regression; Note labels a related location and never counts toward the
// summary. The order is least-to-most severe so a future caller can compare levels.
Severity :: enum {
	Note,
	Warning,
	Error,
}

// Related_Location is one secondary site attached to a primary diagnostic: a `file:line:col`
// point and the note that explains its relation to the primary (e.g. "clone site 2 of 3").
// It renders as a `note:` line under its primary and never tallies as a finding.
Related_Location :: struct {
	file: string,
	line: int,
	col:  int,
	note: string,
}

// Diagnostic is one normalized finding: the primary `file:line:col`, its severity and the
// rule that raised it (the bracketed tag — "dup"/"near"/"dead"), the human message, and the
// related sites that annotate it. Every eir lint projects its findings onto this shape, so
// the renderers never know which lint produced a diagnostic.
Diagnostic :: struct {
	file:     string,
	line:     int,
	col:      int,
	severity: Severity,
	rule:     string,
	message:  string,
	related:  []Related_Location,
}

// render_diagnostics_human renders the diagnostics as a GNU/compiler one-line-per-finding
// stream: each primary on its own `file:line:col: severity: message [rule]` line, each
// related site on a `file:line:col: note: <note>` line beneath it, then a blank line and a
// summary tally. The diagnostics are emitted in the slice's order — each lint sorts them
// before calling (leverage order for dup/near, location order for dead) — so the caller owns
// ordering and this stays presentation-only. An empty slice renders the single "no findings"
// line. Allocated in `allocator`.
render_diagnostics_human :: proc(diags: []Diagnostic, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	errors, warnings := 0, 0
	for d in diags {
		fmt.sbprintfln(&b, "%s:%d:%d: %s: %s [%s]", d.file, d.line, d.col, severity_label(d.severity), d.message, d.rule)
		for r in d.related {
			fmt.sbprintfln(&b, "%s:%d:%d: note: %s", r.file, r.line, r.col, r.note)
		}
		#partial switch d.severity {
		case .Error:
			errors += 1
		case .Warning:
			warnings += 1
		}
	}
	write_diagnostic_summary(&b, errors, warnings)
	return strings.to_string(b)
}

// write_diagnostic_summary writes the closing tally: "no findings" when nothing was raised,
// otherwise a blank separator line then the error/warning counts (each category omitted when
// zero, pluralized). Byte-stable — the same counts always render the same line.
@(private = "file")
write_diagnostic_summary :: proc(b: ^strings.Builder, errors, warnings: int) {
	if errors == 0 && warnings == 0 {
		strings.write_string(b, "no findings\n")
		return
	}
	strings.write_byte(b, '\n')
	wrote := false
	if errors > 0 {
		fmt.sbprintf(b, "%d error%s", errors, plural_suffix(errors))
		wrote = true
	}
	if warnings > 0 {
		if wrote {
			strings.write_string(b, ", ")
		}
		fmt.sbprintf(b, "%d warning%s", warnings, plural_suffix(warnings))
	}
	strings.write_byte(b, '\n')
}

// plural_suffix returns the count-dependent noun suffix: "" for one, "s" otherwise.
@(private = "file")
plural_suffix :: proc(n: int) -> string {
	return "" if n == 1 else "s"
}

// severity_label maps a severity to its lowercase wire/human token — the word that follows
// the colon on a diagnostic line and the value of the JSON `severity` key.
severity_label :: proc(s: Severity) -> string {
	switch s {
	case .Error:
		return "error"
	case .Warning:
		return "warning"
	case .Note:
		return "note"
	}
	return "note"
}

// Diagnostics_Report is the whole --json payload as one marshal-able struct: field order is
// the emitted key order and every field is a scalar or an index-ordered slice (no map), so
// json.marshal over the same diagnostics is byte-identical. It is the report's public schema
// (a consumer unmarshals into it) and is shared by every lint — the single machine surface
// every lint's --json emits.
Diagnostics_Report :: struct {
	schema_version: int,
	diagnostics:    []Diagnostic_Record,
}

// Diagnostic_Record is one finding in the JSON: the primary location, the severity as its
// lowercase string (not the enum's ordinal, so the wire form is self-describing), the rule
// tag, the message, and the related locations. A point finding (dead) carries an empty
// related array.
Diagnostic_Record :: struct {
	file:     string,
	line:     int,
	col:      int,
	severity: string,
	rule:     string,
	message:  string,
	related:  []Related_Location,
}

// render_diagnostics_json renders the diagnostics as one byte-stable JSON object: a compact
// marshal of the ordered Diagnostics_Report (no map anywhere), so a double render over the
// same diagnostics is byte-identical. An empty slice renders an empty `diagnostics` array (a
// JSON slice marshals as `[]`, never `null`). No trailing newline — the caller adds one —
// matching the report --json convention. Allocated in `allocator`.
render_diagnostics_json :: proc(diags: []Diagnostic, allocator := context.allocator) -> string {
	records := make([]Diagnostic_Record, len(diags), context.temp_allocator)
	for d, i in diags {
		records[i] = Diagnostic_Record {
			file     = d.file,
			line     = d.line,
			col      = d.col,
			severity = severity_label(d.severity),
			rule     = d.rule,
			message  = d.message,
			related  = d.related,
		}
	}
	report := Diagnostics_Report {
		schema_version = DIAGNOSTIC_REPORT_SCHEMA_VERSION,
		diagnostics    = records,
	}
	bytes, _ := json.marshal(report, {}, context.temp_allocator)
	return strings.clone(string(bytes), allocator)
}
