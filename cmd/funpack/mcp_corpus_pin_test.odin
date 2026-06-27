package main

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

CORPUS_PIN_REPO_ROOT_REL :: ".."

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

	none := diff_hash_maps(good, good, context.temp_allocator)
	testing.expectf(t, len(none) == 0, "identical hash maps reported %d drift(s)", len(none))
}

@(test)
test_corpus_pin_version_matches_compiler :: proc(t: ^testing.T) {
	committed, manifest_ok := load_manifest(context.temp_allocator)
	testing.expect(t, manifest_ok, "embedded corpus manifest failed to parse")
	if !manifest_ok {
		return
	}

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

diff_hash_maps :: proc(want, got: map[string]string, allocator := context.allocator) -> []string {
	drifted := make([dynamic]string, 0, len(want), allocator)
	for root, w in want {
		if g, present := got[root]; !present || g != w {
			append(&drifted, root)
		}
	}
	return drifted[:]
}

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
