package config

// Config is the resolved funpack-mcp runtime configuration, sourced (in
// precedence order) from CLI flags, FUNPACK_MCP_* env vars, an optional config
// file, then defaults.
type Config struct {
	Log LogConfig `mapstructure:"log"`
}

// LogConfig controls structured logging. Logs always go to stderr — stdout is
// reserved for the MCP stdio transport's JSON-RPC frames.
type LogConfig struct {
	Level  string `mapstructure:"level"`
	Format string `mapstructure:"format"`
}
