package index

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
)

// DecodeStream is the whole-stream spine: it splits the NDJSON emission funpack
// produces per build (spec §29 §2: one JSON object per line, emitted
// whole-stream, never an incremental delta) into per-line Records, running the
// version gate and kind dispatch on each. The producer emits EXACTLY one object
// + one LF per record and never a blank line, so a blank line in the stream is a
// STREAM ERROR (a corrupt or non-conforming producer), not a skipped line. A
// trailing LF after the final record is tolerated — it is the per-record line
// terminator, not a blank record. Decode is fail-fast: the first
// version-mismatch, unknown-kind, or framing error aborts the whole stream, so a
// partially-decoded index is never returned (the contract is exact-match
// whole-stream).
func DecodeStream(r io.Reader) ([]Record, error) {
	records := make([]Record, 0)
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), maxLineBytes)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := bytes.TrimRight(sc.Bytes(), "\r")
		if len(bytes.TrimSpace(line)) == 0 {
			return nil, fmt.Errorf("index contract: blank line at line %d — the producer emits exactly one object per line, never a blank line", lineNo)
		}
		// bufio.Scanner reuses its buffer across Scan calls, so the per-line
		// slice must be copied before it is retained in a Record.
		buf := make([]byte, len(line))
		copy(buf, line)
		rec, err := DecodeLine(buf)
		if err != nil {
			return nil, fmt.Errorf("index contract: line %d: %w", lineNo, err)
		}
		records = append(records, rec)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("index contract: stream read failed: %w", err)
	}
	return records, nil
}

// maxLineBytes caps a single NDJSON line — a generous ceiling well above any
// real project record, sized so a malformed unterminated stream fails with a
// clear scanner error instead of unbounded memory growth.
const maxLineBytes = 16 * 1024 * 1024
