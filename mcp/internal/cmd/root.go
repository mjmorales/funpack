package cmd

import (
	"context"
	"fmt"
	"strings"

	"github.com/mjmorales/funpack/mcp/internal/config"
	"github.com/mjmorales/funpack/mcp/internal/logging"
	"github.com/rs/zerolog"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

// envPrefix namespaces every environment override, e.g. FUNPACK_MCP_LOG_LEVEL.
const envPrefix = "FUNPACK_MCP"

type ctxKey int

const loggerKey ctxKey = iota

// loggerFrom retrieves the request-scoped logger PersistentPreRunE installed on
// the command context; subcommands read it instead of constructing their own.
func loggerFrom(ctx context.Context) zerolog.Logger {
	if l, ok := ctx.Value(loggerKey).(zerolog.Logger); ok {
		return l
	}
	return zerolog.Nop()
}

// NewRootCommand assembles the funpack-mcp CLI. The root resolves configuration
// (flags → FUNPACK_MCP_* env → optional config file → defaults) and builds a
// stderr logger in PersistentPreRunE, then hands both to subcommands through the
// command context so each subcommand stays free of viper/zerolog wiring.
func NewRootCommand() *cobra.Command {
	var cfgFile string
	v := viper.New()

	root := &cobra.Command{
		Use:   "funpack-mcp",
		Short: "Model Context Protocol server for the funpack toolchain",
		Long:  "funpack-mcp exposes the funpack toolchain to MCP-aware agents over stdio.",
		// Cobra's own error/usage printing would corrupt the stdio JSON-RPC stream;
		// main.go renders errors to stderr instead.
		SilenceUsage:  true,
		SilenceErrors: true,
		PersistentPreRunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := loadConfig(v, cfgFile)
			if err != nil {
				return err
			}
			logger := logging.New(cmd.ErrOrStderr(), cfg.Log.Level, cfg.Log.Format)
			cmd.SetContext(context.WithValue(cmd.Context(), loggerKey, logger))
			return nil
		},
	}

	flags := root.PersistentFlags()
	flags.StringVar(&cfgFile, "config", "", "config file path (env FUNPACK_MCP_* still applies)")
	flags.String("log-level", "info", "log level: debug, info, warn, error")
	flags.String("log-format", "json", "log format: json or console")

	must(v.BindPFlag("log.level", flags.Lookup("log-level")))
	must(v.BindPFlag("log.format", flags.Lookup("log-format")))

	root.AddCommand(newServeCommand())
	root.AddCommand(newVersionCommand())

	return root
}

// loadConfig layers viper sources into a typed Config. Env keys map dotted config
// paths to underscores, so log.level reads FUNPACK_MCP_LOG_LEVEL.
func loadConfig(v *viper.Viper, cfgFile string) (config.Config, error) {
	v.SetEnvPrefix(envPrefix)
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	v.AutomaticEnv()
	v.SetDefault("log.level", "info")
	v.SetDefault("log.format", "json")

	if cfgFile != "" {
		v.SetConfigFile(cfgFile)
		if err := v.ReadInConfig(); err != nil {
			return config.Config{}, fmt.Errorf("read config %q: %w", cfgFile, err)
		}
	}

	var c config.Config
	if err := v.Unmarshal(&c); err != nil {
		return config.Config{}, fmt.Errorf("decode config: %w", err)
	}
	return c, nil
}

// Execute runs the root command. It is the single process entry point.
func Execute() error {
	return NewRootCommand().ExecuteContext(context.Background())
}

// must converts a wiring error (a BindPFlag failure) into a panic: these fail
// only on programmer mistakes at startup, never on user input.
func must(err error) {
	if err != nil {
		panic(err)
	}
}
