package funpack

import "core:crypto/sha2"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:strings"

HASH_PREFIX :: "sha256:"

asset_content_hash :: proc(
	source_bytes: []byte,
	importer_version: string,
	dep_hashes: []string,
	allocator := context.temp_allocator,
) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)

	hash_field(&ctx, source_bytes)
	hash_field(&ctx, transmute([]byte)importer_version)
	hash_u64(&ctx, u64(len(dep_hashes)))
	for dep in dep_hashes {
		hash_field(&ctx, transmute([]byte)dep)
	}

	digest: [32]byte
	sha2.final(&ctx, digest[:])
	hex_digest := hex.encode(digest[:], context.temp_allocator)
	return strings.concatenate({HASH_PREFIX, string(hex_digest)}, allocator)
}

hash_field :: proc(ctx: ^sha2.Context_256, data: []byte) {
	hash_u64(ctx, u64(len(data)))
	sha2.update(ctx, data)
}

hash_u64 :: proc(ctx: ^sha2.Context_256, value: u64) {
	buf: [8]byte
	_ = endian.put_u64(buf[:], .Little, value)
	sha2.update(ctx, buf[:])
}
