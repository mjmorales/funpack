package qoi

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// header builds a valid 14-byte QOI header for a width*height RGBA image. The
// tests assemble a body of hand-chosen ops after it, so each op is exercised in
// isolation against the runtime's encode contract (4-channel, sRGB).
func header(width, height uint32) []byte {
	h := make([]byte, headerSize)
	copy(h[0:4], magic[:])
	binary.BigEndian.PutUint32(h[4:8], width)
	binary.BigEndian.PutUint32(h[8:12], height)
	h[12] = 4 // channels: RGBA (the runtime's RGBA32 capture)
	h[13] = 0 // colorspace: sRGB with linear alpha
	return h
}

// stream concatenates a header for pixelCount pixels (laid out 1xN), the body
// chunks, and the mandatory 8-byte end marker into a complete QOI byte stream.
func stream(pixelCount int, body ...byte) []byte {
	var buf bytes.Buffer
	buf.Write(header(uint32(pixelCount), 1))
	buf.Write(body)
	buf.Write(endMarker[:])
	return buf.Bytes()
}

// rgba is a tight {r,g,b,a,...} expectation the tests compare the decoded buffer
// against byte-for-byte.
func rgba(samples ...uint8) []byte { return samples }

// assertDecode decodes a complete stream and asserts the RGBA buffer equals want
// exactly — a wrong byte is a wrong image, so the comparison is total.
func assertDecode(t *testing.T, name string, data, want []byte) {
	t.Helper()
	got, h, err := Decode(data)
	if err != nil {
		t.Fatalf("%s: decode error: %v", name, err)
	}
	if int(h.Width)*int(h.Height)*4 != len(want) {
		t.Fatalf("%s: header declares %dx%d (%d bytes), want %d", name, h.Width, h.Height, int(h.Width)*int(h.Height)*4, len(want))
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("%s: decoded RGBA mismatch\n got: %v\nwant: %v", name, got, want)
	}
}

// TestDecodeOpRGBA proves QOI_OP_RGBA reads a full RGBA sample verbatim — the op
// that seeds an arbitrary first pixel the other ops then diff against.
func TestDecodeOpRGBA(t *testing.T) {
	// One QOI_OP_RGBA pixel: (10, 20, 30, 200).
	data := stream(1, opRGBA, 10, 20, 30, 200)
	assertDecode(t, "op_rgba", data, rgba(10, 20, 30, 200))
}

// TestDecodeOpRGB proves QOI_OP_RGB sets R/G/B and carries alpha from the previous
// pixel (which starts at the spec's opaque-black seed, alpha 255).
func TestDecodeOpRGB(t *testing.T) {
	// One QOI_OP_RGB pixel: (100, 110, 120) with alpha inherited (255 seed).
	data := stream(1, opRGB, 100, 110, 120)
	assertDecode(t, "op_rgb", data, rgba(100, 110, 120, 255))
}

// TestDecodeOpRun proves QOI_OP_RUN repeats the previous pixel run+1 times. The
// seed pixel (opaque black) is repeated, so a bare run of 3 yields three black
// opaque pixels — the run-length bias (-1) is the assertion.
func TestDecodeOpRun(t *testing.T) {
	// QOI_OP_RUN with the low 6 bits = 2 → run length 3 (bias -1) of the seed.
	data := stream(3, opRun|0x02)
	assertDecode(t, "op_run", data, rgba(
		0, 0, 0, 255,
		0, 0, 0, 255,
		0, 0, 0, 255,
	))
}

// TestDecodeOpIndex proves QOI_OP_INDEX recalls a previously-seen pixel from the
// 64-entry running array by its hash position. Pixel 1 is written via RGBA and
// auto-indexed; pixel 2 is a fresh RGBA; pixel 3 recalls pixel 1 by its index.
func TestDecodeOpIndex(t *testing.T) {
	first := pixel{r: 10, g: 20, b: 30, a: 200}
	idx := first.indexPosition()
	// pixel0: RGBA (10,20,30,200) → indexed at idx
	// pixel1: RGBA (40,50,60,70)  → a different sample
	// pixel2: INDEX idx           → recalls pixel0
	data := stream(3,
		opRGBA, 10, 20, 30, 200,
		opRGBA, 40, 50, 60, 70,
		opIndex|byte(idx),
	)
	assertDecode(t, "op_index", data, rgba(
		10, 20, 30, 200,
		40, 50, 60, 70,
		10, 20, 30, 200,
	))
}

// TestDecodeOpDiff proves QOI_OP_DIFF applies three 2-bit per-channel diffs (each
// biased by -2) to the previous pixel, leaving alpha unchanged. From a known RGBA
// seed, a diff of (+1, 0, -1) lands the exact next pixel.
func TestDecodeOpDiff(t *testing.T) {
	// pixel0: RGBA (50, 50, 50, 255)
	// pixel1: DIFF dr=+1 (bits 11→3-2), dg=0 (bits 10→2-2), db=-1 (bits 01→1-2)
	diff := byte(opDiff) | (3 << 4) | (2 << 2) | 1
	data := stream(2,
		opRGBA, 50, 50, 50, 255,
		diff,
	)
	assertDecode(t, "op_diff", data, rgba(
		50, 50, 50, 255,
		51, 50, 49, 255,
	))
}

// TestDecodeOpLuma proves QOI_OP_LUMA applies a green-relative diff: green is
// biased by -32, red and blue are (green diff) plus their own -8-biased nibble.
// From a known seed, a luma chunk lands the exact next pixel, alpha unchanged.
func TestDecodeOpLuma(t *testing.T) {
	// pixel0: RGBA (80, 80, 80, 255)
	// LUMA: dg = (low6=34) - 32 = +2
	//       dr = dg + (hi nibble=10 → 10-8=+2) = +4
	//       db = dg + (lo nibble=6  → 6-8=-2)  = 0
	b1 := byte(opLuma) | 34 // dg = +2
	b2 := byte(10<<4) | 6   // dr-dg = +2, db-dg = -2
	data := stream(2,
		opRGBA, 80, 80, 80, 255,
		b1, b2,
	)
	assertDecode(t, "op_luma", data, rgba(
		80, 80, 80, 255,
		84, 82, 80, 255,
	))
}

// TestDecodeAllOpsInOneStream proves the six ops compose in a single stream the
// way a real QOI body does — index/diff/luma/run all reference the running state
// the prior ops mutated, so a correct decode requires every op's state threading.
func TestDecodeAllOpsInOneStream(t *testing.T) {
	// p0 RGBA (10,20,30,255)              → seed
	// p1 RGB  (100,110,120)               → alpha inherited 255
	// p2 DIFF (+1,+1,+1)                  → (101,111,121,255)
	// p3 LUMA dg=+0, dr=+0, db=+0         → (101,111,121,255) (no-op diff)
	// p4 RUN  length 2                    → repeats p3 twice
	// p5 INDEX of p0                      → recalls (10,20,30,255)
	p0 := pixel{r: 10, g: 20, b: 30, a: 255}
	lumaNoop1 := byte(opLuma) | 32 // dg = 0
	lumaNoop2 := byte(8<<4) | 8    // dr-dg = 0, db-dg = 0
	data := stream(7,
		opRGBA, 10, 20, 30, 255,
		opRGB, 100, 110, 120,
		byte(opDiff)|(3<<4)|(3<<2)|3, // +1,+1,+1
		lumaNoop1, lumaNoop2,
		opRun|0x01, // run length 2
		opIndex|byte(p0.indexPosition()),
	)
	assertDecode(t, "all_ops", data, rgba(
		10, 20, 30, 255,
		100, 110, 120, 255,
		101, 111, 121, 255,
		101, 111, 121, 255,
		101, 111, 121, 255,
		101, 111, 121, 255,
		10, 20, 30, 255,
	))
}

// TestDecodeRejectsBadMagic proves a stream whose signature is not "qoif" is a
// decode error, never a silently-misparsed frame.
func TestDecodeRejectsBadMagic(t *testing.T) {
	data := stream(1, opRGBA, 1, 2, 3, 4)
	data[0] = 'x'
	if _, _, err := Decode(data); err == nil {
		t.Fatal("decode accepted a stream with bad magic")
	}
}

// TestDecodeRejectsTruncatedBody proves a stream that ends before its declared
// pixel count is filled is a decode error — a partial frame is never returned.
func TestDecodeRejectsTruncatedBody(t *testing.T) {
	// Header claims 4 pixels, body supplies only 1.
	data := stream(4, opRGBA, 1, 2, 3, 4)
	if _, _, err := Decode(data); err == nil {
		t.Fatal("decode accepted a stream that under-fills its pixel count")
	}
}

// TestDecodeRejectsMissingEndMarker proves a stream that fills its pixels but is
// not terminated by the 8-byte end marker is a decode error.
func TestDecodeRejectsMissingEndMarker(t *testing.T) {
	var buf bytes.Buffer
	buf.Write(header(1, 1))
	buf.Write([]byte{opRGBA, 1, 2, 3, 4})
	// No end marker appended.
	if _, _, err := Decode(buf.Bytes()); err == nil {
		t.Fatal("decode accepted a stream with no end marker")
	}
}

// TestDecodeRunOverrunRejected proves a run that would write past the declared
// pixel count is rejected rather than overflowing the output buffer.
func TestDecodeRunOverrunRejected(t *testing.T) {
	// Header claims 2 pixels; a run of length 5 overruns.
	data := stream(2, opRun|0x04)
	if _, _, err := Decode(data); err == nil {
		t.Fatal("decode accepted a run that overruns the pixel count")
	}
}
