package funpack

import (
	"sort"

	"github.com/mjmorales/funpack/mcp/internal/contract"
)

// Schema-compat status values — the classification of one schema's resolved
// version against this MCP build's supported range. A small closed set so a
// diagnostic surface (health.funpack_compat) and a reader can switch on it.
const (
	SchemaOK      = "ok"      // got is inside [Min, Max]
	SchemaAhead   = "ahead"   // got > Max: the compiler is newer than this MCP gates
	SchemaBehind  = "behind"  // got < Min: the compiler is older than this MCP needs
	SchemaUngated = "ungated" // no Supported entry: forward-compatible, never blocks
)

// SchemaStatus classifies one schema the resolved funpack reports against the
// MCP build's compat window. Got is the compiler's schema version; Min/Max are the
// supported window (0/0 when ungated).
type SchemaStatus struct {
	Schema string `json:"schema" jsonschema:"schema name (artifact, index, introspect)"`
	Got    int    `json:"got" jsonschema:"schema version the resolved compiler reports"`
	Min    int    `json:"min" jsonschema:"minimum schema version this MCP build supports (0 when ungated)"`
	Max    int    `json:"max" jsonschema:"maximum schema version this MCP build supports (0 when ungated)"`
	Status string `json:"status" jsonschema:"ok | ahead | behind | ungated"`
}

// SchemaCompat is the advisory per-schema compatibility report of a resolved
// funpack against contract.Supported. It replaces the former hard preflight GATE
// as the way skew is surfaced: Compatible is false when any gated schema is ahead
// or behind, but that no longer refuses the server — it drives a diagnostic.
type SchemaCompat struct {
	Compatible bool           `json:"compatible" jsonschema:"true when every gated schema sits inside its supported window"`
	Schemas    []SchemaStatus `json:"schemas" jsonschema:"per-schema compatibility, sorted by schema name"`
}

// CheckSchemaCompat classifies every schema the binary reports against
// contract.Supported. A schema with no Supported entry is ungated (forward-
// compatible — a newer funpack that adds a schema this build never heard of does
// not count as incompatible). Schemas are returned sorted by name for a stable
// diagnostic. Compatible is true iff no gated schema is ahead or behind.
func CheckSchemaCompat(b Binary) SchemaCompat {
	names := make([]string, 0, len(b.Version.Schemas))
	for name := range b.Version.Schemas {
		names = append(names, name)
	}
	sort.Strings(names)

	out := SchemaCompat{Compatible: true, Schemas: make([]SchemaStatus, 0, len(names))}
	for _, name := range names {
		got := b.Version.Schemas[name]
		want, gated := contract.Supported[name]
		st := SchemaStatus{Schema: name, Got: got}
		switch {
		case !gated:
			st.Status = SchemaUngated
		case got < want.Min:
			st.Min, st.Max, st.Status = want.Min, want.Max, SchemaBehind
			out.Compatible = false
		case got > want.Max:
			st.Min, st.Max, st.Status = want.Min, want.Max, SchemaAhead
			out.Compatible = false
		default:
			st.Min, st.Max, st.Status = want.Min, want.Max, SchemaOK
		}
		out.Schemas = append(out.Schemas, st)
	}
	return out
}
