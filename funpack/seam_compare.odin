// The byte-exact golden seam-comparison harness: the bake gate that diffs a
// freshly-baked .gen.fun seam against the committed gen/<stem>.gen.fun and makes
// a stale or absent committed seam a build error. It is the third of the four
// shared-bake mechanisms (lore #10) — it consumes the emitter's bytes
// (gen_emit.odin's emit_gen_fun) on one side and the committed exemplar's bytes
// on the other, and reports whether the committed seam is current.
//
// EXIT CONTRACT (mirrors build.odin §29 §3 all-or-nothing): ANY mismatch is an
// exit-2-class build error, never a counted test failure. A committed seam that
// differs from the fresh bake (Stale_Seam) or is absent while its capability is
// ON (Missing_Seam) fails the build the same way a malformed tree or a compile
// floor does — the bake either reproduces every expected seam byte-for-byte or it
// refuses. There is no assertion-failure tier here; a stale seam is a compile
// error, not a test that ran-and-failed.
//
// PURITY (spec §09, §29 §1): the comparison is a pure function of the two byte
// strings. The emitted side is itself a pure function of the seam model
// (gen_emit.odin), and this file only reads the committed bytes off disk and
// compares — it never reads a clock, never writes, and never mutates the tree.
// The same emitted/committed pair always yields the same verdict.
//
// BOUNDARY: this gate compares an ALREADY-EMITTED seam against an ALREADY-DERIVED
// committed path. It does NOT bake the seam (the upstream per-subsystem baker's
// job), does NOT walk the tree to find capabilities (derive_tree_capabilities in
// project.odin already records the expected gen/ paths), and does NOT join the
// committed seam into the source set (the seam-import story). Its single
// responsibility is the byte verdict.
package funpack

import "core:os"

// Seam_Compare_Error is closed with one arm per outcome of comparing a fresh
// bake against its committed seam. None is the only passing arm (the committed
// bytes equal the emitted bytes); Stale_Seam and Missing_Seam are both
// exit-2-class build errors. A new outcome is a deliberate addition here.
Seam_Compare_Error :: enum {
	// None: the committed file exists and its bytes are identical to the freshly
	// emitted seam — the committed seam is current, the bake is a no-op diff.
	None,
	// Stale_Seam: the committed file exists but its bytes differ from the fresh
	// bake — the source changed and the committed seam was not re-baked. A build
	// error: the bake refuses rather than silently shipping a seam the parser
	// would re-ingest as out-of-date typed references.
	Stale_Seam,
	// Missing_Seam: the capability is ON (the authoring directory holds a source)
	// but the expected gen/<stem>.gen.fun is absent — the seam was never baked. A
	// build error distinct from Stale_Seam: nothing committed to diff against, so
	// the verdict names the absent seam, not a byte divergence.
	Missing_Seam,
}

// compare_seam is the harness's pure verdict: it reads the committed seam at
// `committed_path` and compares its bytes against `emitted` (the fresh bake from
// emit_gen_fun). The committed file being absent is Missing_Seam — the caller
// only passes a path for a capability-ON subsystem, so an absent file means the
// expected seam was never baked. A present file whose bytes differ is Stale_Seam.
// Byte-identical bytes are None. ANY non-None verdict is an exit-2-class build
// error (mirrors build.odin's all-or-nothing contract); a stale seam is never a
// counted test failure. The read is the only impurity — given the same committed
// file and the same emitted bytes the verdict is deterministic.
compare_seam :: proc(emitted: string, committed_path: string) -> Seam_Compare_Error {
	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		// The path is only ever passed for a capability-ON subsystem (the tree
		// declared a source that expects this gen/ seam), so an unreadable or
		// absent committed file means the expected seam was never baked.
		return .Missing_Seam
	}
	if string(committed_bytes) != emitted {
		return .Stale_Seam
	}
	return .None
}
