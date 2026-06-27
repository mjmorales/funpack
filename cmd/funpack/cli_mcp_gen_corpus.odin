package main

import "../../cli"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

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

cli_run_mcp_gen_corpus :: proc(inv: ^cli.Cli_Invocation) -> int {
	// Stays on the heap (default context.allocator): the ~520K corpus overruns the default scratch temp arena.
	repo_root := corpus_repo_root()
	roots := Corpus_Roots {
		spec_md    = corpus_join({repo_root, "spec"}),
		engine_fun = corpus_join({repo_root, "stdlib", "engine"}),
		plugin_dir = corpus_join({repo_root, "plugins", "funpack"}),
		spec_ref   = corpus_git_describe(repo_root),
	}

	result, gen_ok := generate_corpus(roots)
	if !gen_ok {
		fmt.eprintfln(
			"mcp gen-corpus: failed to generate corpus — verify the source roots exist: %s, %s, %s",
			roots.spec_md,
			roots.engine_fun,
			roots.plugin_dir,
		)
		return 1
	}

	corpus_dir := corpus_join({repo_root, "cmd", "funpack", "mcp", "corpus"})
	if err := os.make_directory_all(corpus_dir); err != nil && !os.is_dir(corpus_dir) {
		fmt.eprintfln("mcp gen-corpus: mkdir %s: %v", corpus_dir, err)
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

	fmt.eprintfln(
		"mcp gen-corpus: spec=%d engine=%d plugin=%d (spec ref %s, %s)",
		len(result.spec),
		len(result.engine),
		len(result.plugin),
		result.manifest.spec_ref,
		result.manifest.funpack_version,
	)
	return 0
}

corpus_write_shard :: proc(corpus_dir, name: string, sections: []Corpus_Section) -> bool {
	path := corpus_join({corpus_dir, name})
	return corpus_write_value(path, sections)
}

corpus_write_value :: proc(path: string, v: any) -> bool {
	data, marshal_ok := marshal_corpus_json(v)
	if !marshal_ok {
		fmt.eprintfln("mcp gen-corpus: marshal %s failed", path)
		return false
	}
	if err := os.write_entire_file(path, transmute([]u8)data); err != nil {
		fmt.eprintfln("mcp gen-corpus: write %s: %v", path, err)
		return false
	}
	return true
}

corpus_git_describe :: proc(dir: string, allocator := context.allocator) -> string {
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
