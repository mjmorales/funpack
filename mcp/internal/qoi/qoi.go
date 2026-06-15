// Package qoi decodes the QOI ("Quite OK Image") lossless format into RGBA8.
//
// It exists because the §28 screenshot command returns its captured frame as
// base64-QOI (the runtime's Odin-first encoder, core:image/qoi — Go's stdlib has
// no QOI codec and the module takes no third-party dep). The MCP screenshot tool
// decodes that payload here, then re-encodes to PNG for an MCP image content block
// the model can visually inspect. This decoder is the symmetric inverse of the
// runtime's encode: a correct round-trip is the contract, since a wrong decode is a
// wrong image the model would trust.
//
// The implementation follows the QOI spec (qoiformat.org) exactly: a 14-byte
// header, a stream of the six chunk ops (QOI_OP_RGB, QOI_OP_RGBA, QOI_OP_INDEX,
// QOI_OP_DIFF, QOI_OP_LUMA, QOI_OP_RUN), a 64-entry running pixel index, and an
// 8-byte end marker. Decode always materializes 4-channel RGBA8 regardless of the
// header's channel byte (QOI's ops carry full RGBA state internally; the channel
// byte is informational), matching the runtime's 4-channel RGBA32 capture.
package qoi

import (
	"encoding/binary"
	"fmt"
)

// magic is the QOI header's fixed 4-byte signature, "qoif".
var magic = [4]byte{'q', 'o', 'i', 'f'}

// endMarker is the QOI stream's fixed 8-byte terminator (seven 0x00 then 0x01).
var endMarker = [8]byte{0, 0, 0, 0, 0, 0, 0, 1}

// Chunk-tag constants from the QOI spec. The four single-byte-prefix ops are
// identified by their full byte; the four 2-bit-prefix ops by their top two bits.
const (
	opRGB   = 0xFE // 11111110: full RGB, alpha unchanged
	opRGBA  = 0xFF // 11111111: full RGBA
	opIndex = 0x00 // 00xxxxxx: index into the running array
	opDiff  = 0x40 // 01xxxxxx: small per-channel diff
	opLuma  = 0x80 // 10xxxxxx: luma-based diff
	opRun   = 0xC0 // 11xxxxxx: run of the previous pixel

	tagMask = 0xC0 // mask isolating the 2-bit tag of the prefix ops
)

// headerSize is the QOI header length: 4 magic + 4 width + 4 height + 1 channels
// + 1 colorspace.
const headerSize = 14

// Header is the decoded QOI file header. Channels and Colorspace are carried for
// callers that want them, but Decode always emits 4-channel RGBA8.
type Header struct {
	Width      uint32
	Height     uint32
	Channels   uint8 // 3 (RGB) or 4 (RGBA) — informational; decode is always RGBA8
	Colorspace uint8 // 0 = sRGB with linear alpha, 1 = all channels linear
}

// pixel is one RGBA8 sample. The decoder threads it as the running "previous
// pixel" state every op mutates, and hashes it into the 64-entry index.
type pixel struct {
	r, g, b, a uint8
}

// indexPosition is QOI's hash of a pixel into its 64-entry running array:
// (r*3 + g*5 + b*7 + a*11) mod 64.
func (p pixel) indexPosition() int {
	return int(p.r*3+p.g*5+p.b*7+p.a*11) % 64
}

// DecodeHeader parses and validates a QOI header from the front of data. It is the
// cheap pre-flight Decode runs before walking the chunk stream.
func DecodeHeader(data []byte) (Header, error) {
	if len(data) < headerSize {
		return Header{}, fmt.Errorf("qoi: truncated header: have %d bytes, need %d", len(data), headerSize)
	}
	if data[0] != magic[0] || data[1] != magic[1] || data[2] != magic[2] || data[3] != magic[3] {
		return Header{}, fmt.Errorf("qoi: bad magic: %q, want %q", data[0:4], magic)
	}
	h := Header{
		Width:      binary.BigEndian.Uint32(data[4:8]),
		Height:     binary.BigEndian.Uint32(data[8:12]),
		Channels:   data[12],
		Colorspace: data[13],
	}
	if h.Channels != 3 && h.Channels != 4 {
		return Header{}, fmt.Errorf("qoi: invalid channels byte %d, want 3 or 4", h.Channels)
	}
	if h.Colorspace != 0 && h.Colorspace != 1 {
		return Header{}, fmt.Errorf("qoi: invalid colorspace byte %d, want 0 or 1", h.Colorspace)
	}
	return h, nil
}

// Decode decodes a complete QOI byte stream into a tight RGBA8 pixel buffer
// (len == width*height*4, row-major, no padding) plus the parsed header. The
// returned buffer is exactly the shape image.NewRGBA expects for Pix, so the
// caller PNG-encodes it directly. A malformed stream (bad magic/header, a chunk
// that would overrun the declared pixel count, or a body that ends before the
// pixels are filled) is a decode error, never a partial frame.
func Decode(data []byte) ([]byte, Header, error) {
	h, err := DecodeHeader(data)
	if err != nil {
		return nil, Header{}, err
	}

	pixelCount := int(h.Width) * int(h.Height)
	out := make([]byte, pixelCount*4)

	var index [64]pixel
	// QOI seeds the previous pixel to opaque black (0,0,0,255), NOT zero alpha.
	prev := pixel{r: 0, g: 0, b: 0, a: 255}

	pos := headerSize
	body := data
	written := 0

	for written < pixelCount {
		if pos >= len(body) {
			return nil, Header{}, fmt.Errorf("qoi: stream ended at pixel %d of %d", written, pixelCount)
		}
		b1 := body[pos]
		pos++

		switch {
		case b1 == opRGB:
			if pos+3 > len(body) {
				return nil, Header{}, fmt.Errorf("qoi: truncated QOI_OP_RGB at byte %d", pos-1)
			}
			prev.r = body[pos]
			prev.g = body[pos+1]
			prev.b = body[pos+2]
			pos += 3

		case b1 == opRGBA:
			if pos+4 > len(body) {
				return nil, Header{}, fmt.Errorf("qoi: truncated QOI_OP_RGBA at byte %d", pos-1)
			}
			prev.r = body[pos]
			prev.g = body[pos+1]
			prev.b = body[pos+2]
			prev.a = body[pos+3]
			pos += 4

		case b1&tagMask == opIndex:
			// The 6 low bits are an index into the running array. (b1's top two
			// bits are 00 here, since opRGB/opRGBA matched their full byte above.)
			prev = index[b1&0x3F]

		case b1&tagMask == opDiff:
			// Three 2-bit channel diffs, each biased by -2, alpha unchanged.
			dr := int(b1>>4&0x03) - 2
			dg := int(b1>>2&0x03) - 2
			db := int(b1&0x03) - 2
			prev.r = uint8(int(prev.r) + dr)
			prev.g = uint8(int(prev.g) + dg)
			prev.b = uint8(int(prev.b) + db)

		case b1&tagMask == opLuma:
			if pos >= len(body) {
				return nil, Header{}, fmt.Errorf("qoi: truncated QOI_OP_LUMA at byte %d", pos-1)
			}
			b2 := body[pos]
			pos++
			// Green diff is biased by -32; red/blue diffs are relative to green,
			// each biased by -8.
			dg := int(b1&0x3F) - 32
			dr := dg + (int(b2>>4&0x0F) - 8)
			db := dg + (int(b2&0x0F) - 8)
			prev.r = uint8(int(prev.r) + dr)
			prev.g = uint8(int(prev.g) + dg)
			prev.b = uint8(int(prev.b) + db)

		case b1&tagMask == opRun:
			// A run repeats the previous pixel (run length + 1, bias of -1). With
			// opRGB/opRGBA matched by full byte above, the four 2-bit tags
			// (index/diff/luma/run) are exhaustive, so this needs no default arm.
			run := int(b1&0x3F) + 1
			if written+run > pixelCount {
				return nil, Header{}, fmt.Errorf("qoi: QOI_OP_RUN of %d overruns at pixel %d of %d", run, written, pixelCount)
			}
			for i := 0; i < run; i++ {
				writePixel(out, written, prev)
				written++
			}
			// A run carries the SAME previous pixel; it neither re-indexes nor
			// writes a fresh sample beyond the loop above. Continue past the
			// single-pixel write/index the other ops share.
			continue
		}

		// Every non-run op produces exactly one new pixel: index it and emit it.
		index[prev.indexPosition()] = prev
		if written >= pixelCount {
			return nil, Header{}, fmt.Errorf("qoi: chunk overruns the declared %d pixels", pixelCount)
		}
		writePixel(out, written, prev)
		written++
	}

	// The 8-byte end marker must immediately follow the last chunk. A stream that
	// fills its pixels but is missing or mis-terminated is a malformed payload.
	if pos+8 > len(body) {
		return nil, Header{}, fmt.Errorf("qoi: missing 8-byte end marker after pixels")
	}
	for i := 0; i < 8; i++ {
		if body[pos+i] != endMarker[i] {
			return nil, Header{}, fmt.Errorf("qoi: bad end marker at byte %d", pos+i)
		}
	}

	return out, h, nil
}

// writePixel stores one RGBA8 sample at pixel index i into the row-major buffer.
func writePixel(out []byte, i int, p pixel) {
	o := i * 4
	out[o] = p.r
	out[o+1] = p.g
	out[o+2] = p.b
	out[o+3] = p.a
}
