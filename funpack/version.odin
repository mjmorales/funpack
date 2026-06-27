package funpack

import "core:fmt"
import "core:strings"

FUNPACK_VERSION_FILE :: #load("../VERSION", string)

INTROSPECT_SCHEMA_VERSION :: 1

funpack_version :: proc() -> string {
	return strings.trim_space(FUNPACK_VERSION_FILE)
}

version_report :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf(
		"funpack %s\n  artifact-schema    v%d\n  index-schema       v%d\n  introspect-schema  v%d\n",
		funpack_version(),
		ARTIFACT_SCHEMA_VERSION,
		INDEX_SCHEMA_VERSION,
		INTROSPECT_SCHEMA_VERSION,
		allocator = allocator,
	)
}

version_report_json :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf(
		`{{"%s":"%s","%s":{{"%s":%d,"%s":%d,"%s":%d}}}}`,
		VERSION_FIELD_VERSION,
		funpack_version(),
		VERSION_FIELD_SCHEMAS,
		SCHEMA_NAME_ARTIFACT,
		ARTIFACT_SCHEMA_VERSION,
		SCHEMA_NAME_INDEX,
		INDEX_SCHEMA_VERSION,
		SCHEMA_NAME_INTROSPECT,
		INTROSPECT_SCHEMA_VERSION,
		allocator = allocator,
	)
}

run_version_verb :: proc(json := false) -> int {
	if json {
		fmt.println(version_report_json(context.temp_allocator))
	} else {
		fmt.print(version_report(context.temp_allocator))
	}
	return 0
}
