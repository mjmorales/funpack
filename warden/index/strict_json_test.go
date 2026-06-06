package index

import (
	"strings"
	"testing"
)

// strictProbe is a minimal struct exercising the strict-decode foundation the
// per-record decoders ride. It names two fields; a line carrying any other key
// is over-shaped and must fail under DisallowUnknownFields.
type strictProbe struct {
	SchemaVersion int    `json:"schema_version"`
	Name          string `json:"name"`
}

func TestSpineStrictDecodeRejectsUnknownField(t *testing.T) {
	// DisallowUnknownFields makes an over-shaped record (a key the target struct
	// does not name) a FAILURE — the over-shape half of the exact-match
	// discipline (spec §29 §2). This is the foundation the per-record decoders
	// build required-field validation on.
	var dst strictProbe
	err := decodeStrict([]byte(`{"schema_version":1,"name":"x","extra":true}`), &dst)
	if err == nil {
		t.Fatal("expected an unknown field to be rejected, got nil")
	}
	if !strings.Contains(err.Error(), "strict decode failed") {
		t.Fatalf("expected a strict-decode error, got %q", err.Error())
	}
}

func TestSpineStrictDecodeAcceptsExactShape(t *testing.T) {
	// A line whose keys exactly match the target struct decodes cleanly — the
	// positive case the over-shape rejection bounds.
	var dst strictProbe
	if err := decodeStrict([]byte(`{"schema_version":1,"name":"x"}`), &dst); err != nil {
		t.Fatalf("expected an exact-shape line to decode, got %v", err)
	}
	if dst.Name != "x" || dst.SchemaVersion != 1 {
		t.Fatalf("decoded values wrong: %+v", dst)
	}
}

func TestSpineStrictDecodeRejectsTrailingData(t *testing.T) {
	// A second JSON value after the object on one line is a failure — the
	// transport is exactly one object per line.
	var dst strictProbe
	err := decodeStrict([]byte(`{"schema_version":1,"name":"x"} {"name":"y"}`), &dst)
	if err == nil {
		t.Fatal("expected trailing data to be rejected, got nil")
	}
	if !strings.Contains(err.Error(), "trailing data") {
		t.Fatalf("expected a trailing-data error, got %q", err.Error())
	}
}
