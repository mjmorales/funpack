package eir

import "core:encoding/json"
import "core:fmt"
import "core:strings"

DIAGNOSTIC_REPORT_SCHEMA_VERSION :: 1

Severity :: enum {
	Note,
	Warning,
	Error,
}

Related_Location :: struct {
	file: string,
	line: int,
	col:  int,
	note: string,
}

Diagnostic :: struct {
	file:     string,
	line:     int,
	col:      int,
	severity: Severity,
	rule:     string,
	message:  string,
	related:  []Related_Location,
}

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

@(private = "file")
plural_suffix :: proc(n: int) -> string {
	return "" if n == 1 else "s"
}

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

Diagnostics_Report :: struct {
	schema_version: int,
	diagnostics:    []Diagnostic_Record,
}

Diagnostic_Record :: struct {
	file:     string,
	line:     int,
	col:      int,
	severity: string,
	rule:     string,
	message:  string,
	related:  []Related_Location,
}

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
