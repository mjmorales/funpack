package buildinfo

// Build identity, overridden at link time via
//
//	-ldflags "-X github.com/mjmorales/funpack/mcp/internal/buildinfo.Version=v1.2.3 ..."
//
// and defaulting to dev values for `go run`, `go test`, and unversioned builds.
// Release builds inject the real values.
var (
	Version = "dev"
	Commit  = "none"
	Date    = "unknown"
)
