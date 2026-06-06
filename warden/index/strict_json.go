package index

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// decodeStrict decodes one JSON object into dst with DisallowUnknownFields, so
// an over-shaped record (a key dst's struct does not name) is a FAILURE rather
// than a silently-dropped field. This is the over-shape half of the Index
// Contract's exact-match discipline (spec §29 §2): a record carrying a field the
// consumer does not know is a contract skew, refused here. The under-shape half
// — a MISSING required field — is enforced by the per-record decoders'
// required-field validation, since encoding/json cannot distinguish an absent
// key from a zero value. A trailing token after the object (a second JSON value
// on the line) is also a failure: the transport is exactly one object per line.
func decodeStrict(line []byte, dst any) error {
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return fmt.Errorf("index contract: strict decode failed: %w", err)
	}
	if dec.More() {
		return fmt.Errorf("index contract: trailing data after JSON object on line")
	}
	return nil
}
