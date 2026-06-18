// The `funpack mcp gen-contract` dev-time subcommand — the Odin re-home of the
// deleted-on-wave-9 Go `go run ./internal/contract/gen -odin-out …` (the Odin half of
// the dual-codegen). It is a thin filesystem wrapper around generate_contract_odin
// (mcp_contract_gen.odin): it reads the in-repo contract/funpack-api.json, runs the
// pure generator core, and writes funpack/api_contract.gen.odin. It mirrors the
// gen-corpus subcommand (cli_mcp_gen_corpus.odin) arm-for-arm.
//
// WHY THIS EXISTS (mcp-rehome-contract-generator): the Go generator is deleted with
// the rest of the mcp/ module on wave-9 (delete-go-module). Without this Odin path,
// the committed funpack/api_contract.gen.odin would be unregenerable after a contract
// edit. This ADDS the Odin regeneration path; it does NOT delete the Go generator.
//
// DEV-ONLY: this regenerates committed source under the working tree; it is invoked
// by a maintainer after a contract/funpack-api.json edit, then the regenerated file
// is committed. It is NOT a runtime path. PURE-CORE / IO-IN-WRAPPER: this subcommand
// owns the two filesystem touches (read the contract, write the generated file); the
// core never touches the filesystem and never shells out (no git — the contract
// carries no provenance ref, unlike the corpus). Exit 0 on success, 1 on a read /
// generate / write failure (stderr-reported; stdout stays clean for the MCP
// discipline the parent verb holds).
package main

import "../../cli"
import "core:fmt"
import "core:os"

// build_mcp_gen_contract_command declares `funpack mcp gen-contract` — the dev-time
// contract regenerator hung under the `mcp` parent verb (build_mcp_command). No
// positionals and no flags: the contract path and the output path are resolved from
// the in-repo layout relative to the running binary's working directory (the repo
// root). Mirrors the build_mcp_gen_corpus_command declaration shape.
build_mcp_gen_contract_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "gen-contract",
			short = "Regenerate funpack/api_contract.gen.odin from contract/funpack-api.json (dev-time)",
			long = "Regenerate the committed funpack/api_contract.gen.odin from contract/funpack-api.json — the API_CONTRACT_VERSION, the `funpack version --json` field/schema-name consts, the §28 envelope/command/event name consts, and the unified TOOL_SPECS table (every §28 command AND every server-native tool). A dev-time tool: it writes committed source under the working tree, then the regenerated file is committed. This is the Odin re-home of the Go contract generator's Odin output, so api_contract.gen.odin stays regenerable after the Go mcp/ module is deleted. Run from the repo root after a contract edit.",
			args = cli.cli_no_args(),
			run = cli_run_mcp_gen_contract,
		},
		allocator,
	)
}

// MCP_CONTRACT_SOURCE_REL is contract/funpack-api.json relative to the repo root (the
// generator's working directory).
MCP_CONTRACT_SOURCE_REL :: "contract/funpack-api.json"

// MCP_CONTRACT_ODIN_OUT_REL is funpack/api_contract.gen.odin relative to the repo root
// — the generated file this subcommand overwrites.
MCP_CONTRACT_ODIN_OUT_REL :: "funpack/api_contract.gen.odin"

// cli_run_mcp_gen_contract is the gen-contract handler: read the contract → generate →
// write the Odin file. Diagnostics and the success summary go to stderr (stdout is
// reserved for the MCP JSON-RPC writer the parent verb owns). Returns 0 on success,
// 1 on any failure. Allocates on the HEAP via the temp arena for the parse tree and
// the rendered source; the process exits after the write, so the per-run leak is
// bounded and harmless for a dev tool.
cli_run_mcp_gen_contract :: proc(inv: ^cli.Cli_Invocation) -> int {
	repo_root := corpus_repo_root()
	contract_path := corpus_join({repo_root, MCP_CONTRACT_SOURCE_REL})
	out_path := corpus_join({repo_root, MCP_CONTRACT_ODIN_OUT_REL})

	contract_bytes, read_err := os.read_entire_file_from_path(contract_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("mcp gen-contract: read %s: %v\n", contract_path, read_err)
		return 1
	}

	source, gen_ok := generate_contract_odin(string(contract_bytes))
	if !gen_ok {
		fmt.eprintf("mcp gen-contract: failed to generate from %s — verify it is a valid contract\n", contract_path)
		return 1
	}

	if err := os.write_entire_file(out_path, transmute([]u8)source); err != nil {
		fmt.eprintf("mcp gen-contract: write %s: %v\n", out_path, err)
		return 1
	}

	fmt.eprintf("mcp gen-contract: wrote %s (%d bytes)\n", out_path, len(source))
	return 0
}
