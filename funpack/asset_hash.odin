// Asset content hasher for the §2 bake rule: an asset's content hash is
// H(source bytes + importer version + dependency hashes). The hash is the
// asset's identity in the manifest and the cache key for its baked output,
// so the rule is pinned: the SAME inputs yield the SAME hash anywhere
// (reproducible across machines), and the dependency order is significant
// (an atlas hashing over [image, palette] differs from [palette, image]).
//
// Odin-first: the digest is core:crypto/sha2 (the shipped SHA-256), not a
// custom hasher. The framing below is the only custom part — SHA-256 has no
// notion of "fields", so a naive concatenation would let "ab"+"c" collide
// with "a"+"bc". Each field is length-prefixed so the boundary between
// source bytes, importer version, and each dep hash is unambiguous and the
// canonical byte stream is injective in its inputs.
package funpack

import "core:crypto/sha2"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:strings"

// HASH_PREFIX is the algorithm tag the manifest writes ahead of the hex
// digest (`sha256:3f9a1c2e…`). The hasher emits this exact form so a hash
// it computes is byte-comparable against a `hash =` value the manifest
// already carries — one canonical string shape, no separate parse step.
HASH_PREFIX :: "sha256:"

// asset_content_hash computes an asset's §2 content hash as the
// canonical-form string `sha256:<hex>`. The inputs are folded in a fixed
// order — source bytes, then importer version, then each dependency hash
// in the given slice order — each length-prefixed so the field boundaries
// are unambiguous. Determinism: identical inputs always produce the
// identical string. Order sensitivity: reordering dep_hashes changes the
// canonical byte stream and therefore the hash.
//
// The result string is allocated on `allocator` — an EXPLICIT, overridable
// lifetime choice (a hardcoded allocator would force every persistent caller to
// clone the hash out of scratch). It defaults to
// context.temp_allocator (the subsystem's scratch-by-default convention: a hash
// is computed during a temp-scoped bake and cloned into persistent storage by
// baked_node), so a transient caller passes nothing; a PERSISTENT caller (the
// emit-side image bake) passes its own allocator and the hash needs no clone-out.
// Only the returned string rides `allocator`; the intermediate hex digest is
// scratch on the temp allocator.
asset_content_hash :: proc(
	source_bytes: []byte,
	importer_version: string,
	dep_hashes: []string,
	allocator := context.temp_allocator,
) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)

	// Each field is length-prefixed with a fixed-width little-endian u64 so
	// the concatenation is injective: the prefix tells the boundary between
	// fields apart regardless of their content, so no field rearrangement of
	// the same total bytes can collide with another.
	hash_field(&ctx, source_bytes)
	hash_field(&ctx, transmute([]byte)importer_version)
	// The dep count is folded in too, so an empty dep list and a list whose
	// single element is empty bytes do not produce the same stream.
	hash_u64(&ctx, u64(len(dep_hashes)))
	for dep in dep_hashes {
		hash_field(&ctx, transmute([]byte)dep)
	}

	digest: [32]byte
	sha2.final(&ctx, digest[:])
	hex_digest := hex.encode(digest[:], context.temp_allocator)
	return strings.concatenate({HASH_PREFIX, string(hex_digest)}, allocator)
}

// hash_field folds one variable-length field into the digest, prefixed with
// its byte length, so a reader of the canonical stream can always tell where
// one field ends and the next begins (length-prefixed framing).
hash_field :: proc(ctx: ^sha2.Context_256, data: []byte) {
	hash_u64(ctx, u64(len(data)))
	sha2.update(ctx, data)
}

// hash_u64 folds a fixed-width little-endian u64 into the digest — the
// length prefix and dep-count framing. Fixed width and fixed endianness keep
// the byte stream identical on every platform (§2 reproducibility).
hash_u64 :: proc(ctx: ^sha2.Context_256, value: u64) {
	buf: [8]byte
	_ = endian.put_u64(buf[:], .Little, value)
	sha2.update(ctx, buf[:])
}
