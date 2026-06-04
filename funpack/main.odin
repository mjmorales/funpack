// funpack — the pure source → artifact compiler. No clock, no DB, no
// network in scope; emits the versioned Index Contract (spec §29).
package funpack

import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 {
		print_usage()
		os.exit(2)
	}
	switch os.args[1] {
	case "test":
		// TODO: feed the §14 project tree's sources here once the
		// grammar parses them; the empty source keeps `funpack test` a
		// runnable no-op until then.
		report, err := run_test_pipeline("")
		if err != .None {
			fmt.eprintfln("funpack test: %v", err)
			os.exit(2)
		}
		fmt.printfln("funpack test: %d passed, %d failed", report.passed, report.failed)
		os.exit(report.exit_code)
	case:
		print_usage()
		os.exit(2)
	}
}

print_usage :: proc() {
	fmt.eprintln("usage: funpack test")
}
