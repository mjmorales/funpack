// The `funpack mcp gen-corpus` dev-time subcommand — the Odin re-home of the
// deleted Go `go run ./internal/docs/gen` (gen/main.go). It is a thin filesystem
// wrapper around generate_corpus (mcp_corpus_gen.odin): it resolves the in-repo
// source roots (spec/, stdlib/engine/, plugins/funpack/), computes spec_ref via the
// SINGLE residual git shell (the one place git is touched — never the server, never
// the SDL-free floor), runs the pure generator core, and persists the four committed
// artifacts under cmd/funpack/mcp/corpus/. Those bytes are committed and embedded by
// mcp_corpus.odin's #load, so the binary never reads the sources at runtime.
//
// PROVENANCE GATING (DOCS-GEN decision): this is the ONLY file that shells out
// (corpus_git_describe via core:sys/posix.popen). The generator core and the loader
// are pure / IO-read-only; isolating the git dependency here keeps the server and
// the test floor shell-free. funpack_version comes from the in-process constant
// inside generate_corpus, NOT a subprocess — the generator IS funpack.
//
// DEV-ONLY: this regenerates committed source under the working tree; it is invoked
// by `task docs-regen` (cmd/funpack/Taskfile.yml) and by a maintainer after a spec /
// .fun / skill edit, then the regenerated shards are committed. It is NOT a runtime
// path. Exit 0 on success, 1 on a resolve/generate/write failure (stderr-reported;
// stdout stays clean for the MCP discipline the parent verb holds).
package main

import "../../cli"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// build_mcp_gen_corpus_command declares `funpack mcp gen-corpus` — the dev-time
// corpus regenerator hung under the `mcp` parent verb (build_mcp_command). No
// positionals and no flags: the source roots are resolved from the in-repo layout
// relative to the running binary's repo. Mirrors the build_run/attach_command
// declaration shape.
build_mcp_gen_corpus_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "gen-corpus",
			short = "Regenerate the committed docs corpus shards (dev-time)",
			long = "Regenerate the committed funpack docs-corpus shards (mcp/corpus/{spec,engine,plugin}.json + manifest.json) by walking the in-repo spec/ prose, stdlib/engine/*.fun @doc signatures, and plugins/funpack skills. A dev-time tool: it writes committed source under the working tree, then the regenerated shards are committed. The MCP server embeds those committed bytes via #load and never reads the sources at runtime. spec_ref is stamped from `git describe --tags --always --abbrev=0` (the single residual git shell, isolated to this subcommand); funpack_version is the in-process build constant.",
			args = cli.cli_no_args(),
			run = cli_run_mcp_gen_corpus,
		},
		allocator,
	)
}

// cli_run_mcp_gen_corpus is the gen-corpus handler: resolve roots → generate →
// persist. Diagnostics go to stderr; the success summary goes to stderr too (stdout
// is reserved for the MCP JSON-RPC writer the parent verb owns). Returns 0 on
// success, 1 on any failure.
cli_run_mcp_gen_corpus :: proc(inv: ^cli.Cli_Invocation) -> int {
	// The whole run allocates on the HEAP (context.allocator), not the temp arena:
	// the corpus is ~520K of section strings AND the marshal renders another ~520K
	// over the same allocator, which overruns the default scratch temp arena. The
	// generated result holds slices into its own heap allocations; the process exits
	// after the write, so the per-run leak is bounded and harmless for a dev tool.
	repo_root := corpus_repo_root()
	roots := Corpus_Roots {
		spec_md    = corpus_join({repo_root, "spec"}),
		engine_fun = corpus_join({repo_root, "stdlib", "engine"}),
		plugin_dir = corpus_join({repo_root, "plugins", "funpack"}),
		spec_ref   = corpus_git_describe(repo_root),
	}

	result, gen_ok := generate_corpus(roots)
	if !gen_ok {
		fmt.eprintf(
			"mcp gen-corpus: failed to generate corpus — verify the source roots exist: %s, %s, %s\n",
			roots.spec_md,
			roots.engine_fun,
			roots.plugin_dir,
		)
		return 1
	}

	corpus_dir := corpus_join({repo_root, "cmd", "funpack", "mcp", "corpus"})
	if err := os.make_directory_all(corpus_dir); err != nil && !os.is_dir(corpus_dir) {
		fmt.eprintf("mcp gen-corpus: mkdir %s: %v\n", corpus_dir, err)
		return 1
	}

	if !corpus_write_shard(corpus_dir, "spec.json", result.spec) {
		return 1
	}
	if !corpus_write_shard(corpus_dir, "engine.json", result.engine) {
		return 1
	}
	if !corpus_write_shard(corpus_dir, "plugin.json", result.plugin) {
		return 1
	}
	if !corpus_write_value(corpus_join({corpus_dir, "manifest.json"}), result.manifest) {
		return 1
	}

	fmt.eprintf(
		"mcp gen-corpus: spec=%d engine=%d plugin=%d (spec ref %s, %s)\n",
		len(result.spec),
		len(result.engine),
		len(result.plugin),
		result.manifest.spec_ref,
		result.manifest.funpack_version,
	)
	return 0
}

// corpus_repo_root resolves the monorepo root from the running binary's working
// directory. The gen-corpus tool runs at the repo root (the Taskfile invokes it
// there), so cwd IS the repo root. Falling back to "." when the working directory
// cannot be read keeps the resolve total. Allocated in `allocator`.
corpus_repo_root :: proc(allocator := context.allocator) -> string {
	cwd, err := os.get_working_directory(allocator)
	if err != nil || cwd == "" {
		return strings.clone(".", allocator)
	}
	return cwd
}

// corpus_write_shard marshals one per-kind section slice to corpus_dir/name as
// 2-space-indented JSON with a trailing newline — the gencore.WriteShard mirror.
// Returns false (stderr-reported) on marshal or write failure.
corpus_write_shard :: proc(corpus_dir, name: string, sections: []Corpus_Section) -> bool {
	path := corpus_join({corpus_dir, name})
	return corpus_write_value(path, sections)
}

// corpus_write_value marshals v to path as the committed-corpus JSON form
// (marshal_corpus_json) and writes it. Marshals on the HEAP (not the temp arena) —
// a single shard is up to ~290K, which overruns the default scratch temp arena.
// Returns false (stderr-reported) on failure.
corpus_write_value :: proc(path: string, v: any) -> bool {
	data, marshal_ok := marshal_corpus_json(v)
	if !marshal_ok {
		fmt.eprintf("mcp gen-corpus: marshal %s failed\n", path)
		return false
	}
	if err := os.write_entire_file(path, transmute([]u8)data); err != nil {
		fmt.eprintf("mcp gen-corpus: write %s: %v\n", path, err)
		return false
	}
	return true
}

// corpus_git_describe returns the nearest release tag reachable from HEAD via
// `git -C <dir> describe --tags --always --abbrev=0`, or "unknown" on any failure —
// the gencore.gitDescribe mirror. --abbrev=0 drops the commit-distance suffix so the
// ref stays byte-stable across dev commits between releases (the manifest is
// byte-pinned). THE SINGLE RESIDUAL SHELL: core:sys/posix.popen runs git and reads
// its stdout; this is the only subprocess in the whole corpus subsystem, isolated to
// this dev subcommand so the server and the SDL-free floor never shell out.
// Allocated in `allocator`.
corpus_git_describe :: proc(dir: string, allocator := context.allocator) -> string {
	// `cd <dir> && git describe …` so the describe runs against the repo at dir
	// without relying on git -C parsing of a quoted path. dir is the resolved repo
	// root (no shell metacharacters in a path under the working tree).
	cmd := strings.concatenate(
		{"cd ", dir, " && git describe --tags --always --abbrev=0 2>/dev/null"},
		context.temp_allocator,
	)
	ccmd := strings.clone_to_cstring(cmd, context.temp_allocator)
	stream := posix.popen(ccmd, "r")
	if stream == nil {
		return strings.clone("unknown", allocator)
	}
	defer posix.pclose(stream)

	b := strings.builder_make(context.temp_allocator)
	buf: [256]u8
	for {
		n := posix.fread(raw_data(buf[:]), 1, len(buf), stream)
		if n == 0 {
			break
		}
		strings.write_bytes(&b, buf[:n])
		if n < len(buf) {
			break
		}
	}
	out := strings.trim_space(strings.to_string(b))
	if out == "" {
		return strings.clone("unknown", allocator)
	}
	return strings.clone(out, allocator)
}
