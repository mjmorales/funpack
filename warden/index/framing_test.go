package index

import (
	"strings"
	"testing"
)

func TestSpineStreamSplitsTwoRecords(t *testing.T) {
	// Two project lines separated by LF split into two Records — the
	// whole-stream NDJSON spine, one object per line.
	stream := projectLine + "\n" + projectLine + "\n"
	recs, err := DecodeStream(strings.NewReader(stream))
	if err != nil {
		t.Fatalf("expected a clean two-record stream, got %v", err)
	}
	if len(recs) != 2 {
		t.Fatalf("expected 2 records, got %d", len(recs))
	}
	for i, rec := range recs {
		if rec.Kind != RecordKindProject {
			t.Fatalf("record %d: expected RecordKindProject, got %v", i, rec.Kind)
		}
	}
}

func TestSpineStreamToleratesTrailingLF(t *testing.T) {
	// A single record with a trailing LF (the per-record line terminator) is one
	// record, not a record plus a blank line — the trailing LF is tolerated.
	recs, err := DecodeStream(strings.NewReader(projectLine + "\n"))
	if err != nil {
		t.Fatalf("expected a trailing LF to be tolerated, got %v", err)
	}
	if len(recs) != 1 {
		t.Fatalf("expected 1 record, got %d", len(recs))
	}
}

func TestSpineStreamWithoutTrailingLF(t *testing.T) {
	// A final record with no trailing LF still decodes — the LF is a terminator,
	// not a requirement on the last line.
	recs, err := DecodeStream(strings.NewReader(projectLine))
	if err != nil {
		t.Fatalf("expected a record without a trailing LF to decode, got %v", err)
	}
	if len(recs) != 1 {
		t.Fatalf("expected 1 record, got %d", len(recs))
	}
}

func TestSpineStreamBlankLineIsError(t *testing.T) {
	// A blank line between records is a STREAM ERROR — the producer emits
	// exactly one object per line and never a blank line, so a blank line is a
	// non-conforming producer, not a skipped line.
	stream := projectLine + "\n\n" + projectLine + "\n"
	_, err := DecodeStream(strings.NewReader(stream))
	if err == nil {
		t.Fatal("expected a blank line to be a stream error, got nil")
	}
	if !strings.Contains(err.Error(), "blank line") {
		t.Fatalf("expected a blank-line error, got %q", err.Error())
	}
}

func TestSpineStreamPropagatesVersionMismatch(t *testing.T) {
	// A version-mismatched line anywhere in the stream aborts the whole stream
	// with the fix-it — decode is fail-fast, never a partially-decoded index.
	bad := strings.Replace(projectLine, `"schema_version":2`, `"schema_version":7`, 1)
	stream := projectLine + "\n" + bad + "\n"
	_, err := DecodeStream(strings.NewReader(stream))
	if err == nil {
		t.Fatal("expected the version mismatch to abort the stream, got nil")
	}
	if !strings.Contains(err.Error(), "rebuild with a matching funpack") {
		t.Fatalf("expected the fix-it to propagate through the stream, got %q", err.Error())
	}
}
