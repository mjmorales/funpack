// The corpus-pin drift gate — the single shared-extractor-path guarantee: it
// regenerates the corpus IN MEMORY through the SAME generate_corpus extractors the
// committed shards were built with, and byte/hash-compares against the
// #load-embedded committed bytes. A drift — a spec edit, an engine signature
// change, a plugin skill rewrite, or a stale checkout — fails here, forcing
// `task docs-regen` + recommit. There is no second, divergent extractor to keep in
// sync (the one-extraction-path-shared-by-gen-and-pin design).
//
// HERMETIC SKIP: when the in-repo source trees are unavailable (a checkout without
// spec/stdlib/plugins, or an env without the fixture), the regen-driven tests SKIP
// loudly rather than asserting against an empty (falsely-clean) corpus — drift can
// only be asserted where the sources exist (the surface_parity_test.odin / golden
// SKIP protocol). The mutated-hash negative control runs ALWAYS (it needs only the
// embedded manifest), so the drift-detection LOGIC is guarded even in a hermetic
// environment.
//
// PROVENANCE ISOLATION: spec_ref (git describe) is environment-dependent, so the
// pin compares CONTENT (the per-source content_hash and the shard bytes), and
// regenerates the manifest with the committed manifest's spec_ref injected — so the
// manifest comparison isolates a content/version drift from the ambient git tag.
// These tests are define-free (the loader + generator are; see mcp_corpus.odin), so
// they run on the default `odin test .` floor.
package main

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// CORPUS_PIN_REPO_ROOT_REL is the repo root relative to this package dir. cmd/funpack
// sits two levels below the monorepo root, so #directory/../.. is the root the source
// trees (spec/, stdlib/engine/, plugins/funpack/) live under.
CORPUS_PIN_REPO_ROOT_REL :: ".."

// resolve_corpus_roots resolves the generator's source roots from this checkout,
// mirroring the surface_parity / golden resolver: FUNPACK_CORPUS_ROOT overrides the
// repo root, else #directory/../.. (the worktree-local root). spec_ref is read from
// the committed manifest so a regen reproduces the committed provenance string
// regardless of the ambient git tag (see the package PROVENANCE ISOLATION note).
// ok=false (no warn here; the caller warns+skips) when the trees are absent.
resolve_corpus_roots :: proc(spec_ref: string, allocator := context.allocator) -> (roots: Corpus_Roots, ok: bool) {
	root: string
	if env, has := os.lookup_env("FUNPACK_CORPUS_ROOT", allocator); has && env != "" {
		root = env
	} else {
		joined, _ := filepath.join({#directory, "..", ".."}, allocator)
		root = joined
	}
	r := Corpus_Roots {
		spec_md    = corpus_join({root, "spec"}, allocator),
		engine_fun = corpus_join({root, "stdlib", "engine"}, allocator),
		plugin_dir = corpus_join({root, "plugins", "funpack"}, allocator),
		spec_ref   = spec_ref,
	}
	if !os.is_dir(r.spec_md) || !os.is_dir(r.engine_fun) || !os.is_dir(r.plugin_dir) {
		return {}, false
	}
	return r, true
}

// regen_or_skip resolves the roots and regenerates the corpus in memory, skipping
// (loudly logged) when the source trees are unavailable. The committed manifest's
// spec_ref is threaded into the regen so the manifest comparison is content-only.
regen_or_skip :: proc(t: ^testing.T) -> (result: Corpus_Result, ok: bool) {
	committed, manifest_ok := load_manifest(context.temp_allocator)
	if !manifest_ok {
		testing.expect(t, false, "embedded corpus manifest failed to parse")
		return {}, false
	}
	roots, roots_ok := resolve_corpus_roots(committed.spec_ref, context.temp_allocator)
	if !roots_ok {
		log.warnf(
			"SKIP corpus-pin regen: spec/stdlib/plugins source trees not found — set FUNPACK_CORPUS_ROOT or ensure the in-repo fixture exists",
		)
		return {}, false
	}
	res, gen_ok := generate_corpus(roots, context.temp_allocator)
	if !gen_ok {
		testing.expect(t, false, "corpus regeneration failed against present source trees")
		return {}, false
	}
	return res, true
}

// test_corpus_pin_shards_byte_match is the corpus-pin gate proper: it regenerates
// each per-kind shard through generate_corpus and asserts the marshaled bytes equal
// the #load-embedded committed shard bytes. Drift fails here, naming WHICH shard.
// The embedded constants ARE the committed bytes (#load is a compile-time read), so
// this compares the live extractor output against the snapshot in the binary.
@(test)
test_corpus_pin_shards_byte_match :: proc(t: ^testing.T) {
	res, ok := regen_or_skip(t)
	if !ok {
		return
	}
	expect_shard_matches(t, "spec.json", res.spec, CORPUS_SPEC_JSON)
	expect_shard_matches(t, "engine.json", res.engine, CORPUS_ENGINE_JSON)
	expect_shard_matches(t, "plugin.json", res.plugin, CORPUS_PLUGIN_JSON)
}

// expect_shard_matches marshals the regenerated sections through the canonical
// corpus marshaler and asserts byte-equality with the committed shard bytes.
expect_shard_matches :: proc(t: ^testing.T, name: string, sections: []Corpus_Section, committed: string) {
	got, marshal_ok := marshal_corpus_json(sections, context.temp_allocator)
	testing.expectf(t, marshal_ok, "marshal regenerated %s failed", name)
	if !marshal_ok {
		return
	}
	testing.expectf(
		t,
		got == committed,
		"corpus shard %s drifted from the committed snapshot; run `task docs-regen` and recommit (regenerated %d bytes vs committed %d)",
		name,
		len(got),
		len(committed),
	)
}

// test_corpus_pin_per_source_hashes asserts the regenerated per-source content
// hashes match the committed manifest's, source-by-source — the granular signal
// naming WHICH root drifted (spec/engine/plugin), which the whole-shard byte compare
// alone does not localize. Recomputes each hash from the regenerated sections via
// the live hash_corpus_sections so the assertion exercises the hash function, not a
// value copied out of the manifest.
@(test)
test_corpus_pin_per_source_hashes :: proc(t: ^testing.T) {
	res, ok := regen_or_skip(t)
	if !ok {
		return
	}
	committed, manifest_ok := load_manifest(context.temp_allocator)
	testing.expect(t, manifest_ok, "embedded manifest must parse")
	if !manifest_ok {
		return
	}

	live := make(map[string]string, 3, context.temp_allocator)
	live["spec"] = hash_corpus_sections(res.spec, context.temp_allocator)
	live["stdlib/engine"] = hash_corpus_sections(res.engine, context.temp_allocator)
	live["plugins/funpack"] = hash_corpus_sections(res.plugin, context.temp_allocator)
	for src in committed.sources {
		want := src.content_hash
		got, present := live[src.root]
		testing.expectf(t, present, "committed manifest names source root %q the generator no longer emits", src.root)
		if !present {
			continue
		}
		testing.expectf(
			t,
			got == want,
			"source root %q content hash drifted: regenerated %s, committed %s — run `task docs-regen`",
			src.root,
			got,
			want,
		)
	}
}

// test_corpus_pin_manifest_section_counts asserts the regenerated section counts
// and total match the committed manifest's, per source root. This catches a
// section-count drift (a heading added/removed) the per-source HASH would also flag,
// and additionally a manifest hand-edit of a count the shards alone cannot — without
// depending on the environment-specific spec_ref string.
@(test)
test_corpus_pin_manifest_section_counts :: proc(t: ^testing.T) {
	res, ok := regen_or_skip(t)
	if !ok {
		return
	}
	committed, manifest_ok := load_manifest(context.temp_allocator)
	testing.expect(t, manifest_ok, "embedded manifest must parse")
	if !manifest_ok {
		return
	}

	live_counts := make(map[string]int, 3, context.temp_allocator)
	live_counts["spec"] = len(res.spec)
	live_counts["stdlib/engine"] = len(res.engine)
	live_counts["plugins/funpack"] = len(res.plugin)
	total := 0
	for src in committed.sources {
		want := src.sections
		got := live_counts[src.root]
		testing.expectf(
			t,
			got == want,
			"source root %q section count drifted: regenerated %d, committed %d",
			src.root,
			got,
			want,
		)
		total += want
	}
	testing.expectf(
		t,
		committed.total_sections == total,
		"manifest total_sections %d disagrees with the per-source sum %d",
		committed.total_sections,
		total,
	)
}

// test_corpus_pin_mutated_hash_detected_as_drift is the negative-control unit test:
// it proves the per-source-hash comparison actually FIRES on a mutated hash, so the
// detector is not trivially always-pass. It flips one hex digit of a committed
// source hash in an in-memory copy and asserts the same map-equality the pin check
// runs reports exactly that one mismatch — and that identical maps report none. It
// needs only the embedded manifest, so it runs ALWAYS (even in a hermetic
// environment without the source trees).
@(test)
test_corpus_pin_mutated_hash_detected_as_drift :: proc(t: ^testing.T) {
	committed, manifest_ok := load_manifest(context.temp_allocator)
	testing.expect(t, manifest_ok, "embedded manifest must parse")
	if !manifest_ok {
		return
	}
	testing.expect(t, len(committed.sources) > 0, "committed manifest records zero sources")
	if len(committed.sources) == 0 {
		return
	}

	good := make(map[string]string, len(committed.sources), context.temp_allocator)
	for src in committed.sources {
		good[src.root] = src.content_hash
	}
	mutated := make(map[string]string, len(good), context.temp_allocator)
	for k, v in good {
		mutated[k] = v
	}
	target := committed.sources[0].root
	mutated[target] = flip_first_hex_digit(good[target], context.temp_allocator)
	testing.expect(t, mutated[target] != good[target], "flip_first_hex_digit did not change the hash")

	drifted := diff_hash_maps(good, mutated, context.temp_allocator)
	testing.expectf(t, len(drifted) == 1, "expected exactly one drift, got %d", len(drifted))
	if len(drifted) == 1 {
		testing.expect_value(t, drifted[0], target)
	}

	// Sanity: identical maps report no drift, so the detector is not trivially
	// always-positive.
	none := diff_hash_maps(good, good, context.temp_allocator)
	testing.expectf(t, len(none) == 0, "identical hash maps reported %d drift(s)", len(none))
}

// test_corpus_pin_version_matches_compiler is the release-parity gate (dogfood
// FRICTION F15): the embedded corpus must carry a funpack_version AND it must equal the
// in-process funpack_version() the binary compiles as. The byte/hash pins above isolate
// CONTENT from the version (they inject the committed spec_ref so a regen is
// content-only), so a binary can pass them while embedding a corpus stamped at an OLDER
// version — the silent skew where a binary ships a corpus generated against an earlier
// release (the F15 incident). This asserts the same equality the runtime `health` drift
// detector (docs_detect_drift) computes, turning the silent ship-time lag into a
// `task test` failure so a binary cannot ship
// embedding a corpus from an older version. It needs only the embedded manifest + the
// in-process version, so it runs ALWAYS (no source trees — hermetic-safe, like the
// mutated-hash control), which is what makes it a genuine release gate.
@(test)
test_corpus_pin_version_matches_compiler :: proc(t: ^testing.T) {
	committed, manifest_ok := load_manifest(context.temp_allocator)
	testing.expect(t, manifest_ok, "embedded corpus manifest failed to parse")
	if !manifest_ok {
		return
	}

	// A corpus with an empty funpack_version makes docs_detect_drift report a vacuous
	// no-drift; require the stamp explicitly so a stampless corpus cannot slip the gate.
	testing.expect(
		t,
		strings.trim_space(committed.funpack_version) != "",
		"embedded corpus manifest carries no funpack_version stamp",
	)

	drift := docs_detect_drift(committed, context.temp_allocator)
	testing.expectf(
		t,
		!drift.drift,
		"embedded docs corpus version %q != compiler version %q — this binary would ship a stale corpus; run `task docs-regen` and rebuild so the corpus ships in lockstep with its binary (FRICTION F15)",
		drift.corpus_version,
		drift.compiler_version,
	)
}

// diff_hash_maps returns the roots whose hashes differ between two source-hash maps
// — the comparison the per-source pin performs. A root present in want but missing
// from got is reported too (a dropped source root is drift). Allocated in `allocator`.
diff_hash_maps :: proc(want, got: map[string]string, allocator := context.allocator) -> []string {
	drifted := make([dynamic]string, 0, len(want), allocator)
	for root, w in want {
		if g, present := got[root]; !present || g != w {
			append(&drifted, root)
		}
	}
	return drifted[:]
}

// flip_first_hex_digit returns s with its first hex digit changed, so a content hash
// becomes a different-but-still-hex value. Empty input is returned as-is. Allocated
// in `allocator`.
flip_first_hex_digit :: proc(s: string, allocator := context.allocator) -> string {
	if s == "" {
		return s
	}
	b := strings.builder_make(allocator)
	if s[0] == '0' {
		strings.write_byte(&b, '1')
	} else {
		strings.write_byte(&b, '0')
	}
	strings.write_string(&b, s[1:])
	return strings.to_string(b)
}
