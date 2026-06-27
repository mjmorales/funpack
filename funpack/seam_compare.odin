package funpack

import "core:os"

Seam_Compare_Error :: enum {
	None,
	Stale_Seam,
	Missing_Seam,
}

compare_seam :: proc(emitted: string, committed_path: string) -> Seam_Compare_Error {
	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		return .Missing_Seam
	}
	if string(committed_bytes) != emitted {
		return .Stale_Seam
	}
	return .None
}
