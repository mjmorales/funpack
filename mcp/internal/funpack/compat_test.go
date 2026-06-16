package funpack

import (
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/contract"
)

// binWithSchemas builds a synthetic resolved Binary carrying the given schema map,
// so CheckSchemaCompat can be exercised without execing a real funpack.
func binWithSchemas(schemas map[string]int) Binary {
	return Binary{Path: "/fake/funpack", Version: contract.VersionInfo{Version: "9.9.9", Schemas: schemas}}
}

// TestCheckSchemaCompatAllOK: every gated schema sitting inside its supported
// window yields Compatible=true and an ok status per schema.
func TestCheckSchemaCompatAllOK(t *testing.T) {
	got := CheckSchemaCompat(binWithSchemas(map[string]int{
		contract.SchemaArtifact:   contract.Supported[contract.SchemaArtifact].Max,
		contract.SchemaIndex:      contract.Supported[contract.SchemaIndex].Max,
		contract.SchemaIntrospect: contract.Supported[contract.SchemaIntrospect].Max,
	}))
	if !got.Compatible {
		t.Fatalf("all-in-range must be Compatible, got %+v", got)
	}
	for _, s := range got.Schemas {
		if s.Status != SchemaOK {
			t.Errorf("schema %s: want ok, got %s", s.Schema, s.Status)
		}
	}
}

// TestCheckSchemaCompatAheadAndBehind: a compiler newer than Max is "ahead" and one
// older than Min is "behind"; either flips Compatible to false (advisory skew).
func TestCheckSchemaCompatAheadAndBehind(t *testing.T) {
	ahead := CheckSchemaCompat(binWithSchemas(map[string]int{
		contract.SchemaArtifact: contract.Supported[contract.SchemaArtifact].Max + 1,
	}))
	if ahead.Compatible || ahead.Schemas[0].Status != SchemaAhead {
		t.Fatalf("newer-than-Max must be ahead + incompatible, got %+v", ahead)
	}

	behind := CheckSchemaCompat(binWithSchemas(map[string]int{
		contract.SchemaArtifact: contract.Supported[contract.SchemaArtifact].Min - 1,
	}))
	if behind.Compatible || behind.Schemas[0].Status != SchemaBehind {
		t.Fatalf("older-than-Min must be behind + incompatible, got %+v", behind)
	}
}

// TestCheckSchemaCompatUngatedIsForwardCompatible: a schema this build has no
// Supported entry for is ungated — it never marks the compiler incompatible, so a
// future funpack that adds a schema key is accepted.
func TestCheckSchemaCompatUngatedIsForwardCompatible(t *testing.T) {
	got := CheckSchemaCompat(binWithSchemas(map[string]int{"future_schema": 42}))
	if !got.Compatible {
		t.Fatalf("an ungated schema must not flag incompatibility, got %+v", got)
	}
	if got.Schemas[0].Status != SchemaUngated {
		t.Fatalf("want ungated, got %s", got.Schemas[0].Status)
	}
}
