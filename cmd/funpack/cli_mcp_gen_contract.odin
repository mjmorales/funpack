package main

import "../../cli"
import "core:fmt"
import "core:os"

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

MCP_CONTRACT_SOURCE_REL :: "contract/funpack-api.json"

MCP_CONTRACT_ODIN_OUT_REL :: "funpack/api_contract.gen.odin"

cli_run_mcp_gen_contract :: proc(inv: ^cli.Cli_Invocation) -> int {
	repo_root := corpus_repo_root()
	contract_path := corpus_join({repo_root, MCP_CONTRACT_SOURCE_REL})
	out_path := corpus_join({repo_root, MCP_CONTRACT_ODIN_OUT_REL})

	contract_bytes, read_err := os.read_entire_file_from_path(contract_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("mcp gen-contract: read %s: %v", contract_path, read_err)
		return 1
	}

	source, gen_ok := generate_contract_odin(string(contract_bytes))
	if !gen_ok {
		fmt.eprintfln("mcp gen-contract: failed to generate from %s — verify it is a valid contract", contract_path)
		return 1
	}

	if err := os.write_entire_file(out_path, transmute([]u8)source); err != nil {
		fmt.eprintfln("mcp gen-contract: write %s: %v", out_path, err)
		return 1
	}

	fmt.eprintfln("mcp gen-contract: wrote %s (%d bytes)", out_path, len(source))
	return 0
}
