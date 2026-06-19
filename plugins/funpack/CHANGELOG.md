# Changelog

All notable changes to the funpack Claude Code plugin.

## [0.7.1] - 2026-06-19

### Fixes
- fix(mcp): launch the MCP server through a deterministic resolver (e41d85f)

## [0.7.0] - 2026-06-19

### Features
- feat: add funpack:ctl skill for funpack binary install/update/rollback (cf3d632)

## [0.6.1] - 2026-06-19

### Other
- refactor(funpack): prune unusable engine.render::Font over-declaration (5088890)

## [0.6.0] - 2026-06-18

### Features
- feat(plugin): rewire MCP bundling to the native funpack mcp verb (4cc1b2a)
- feat(mcp): screenshot present-boundary refusal + surface-parity gate (03e409f)

## [0.5.1] - 2026-06-16

### Fixes
- fix(plugin): funpack-mcp launcher resolves the compiler zero-config (3dcf26c)

## [0.5.0] - 2026-06-16

### Features
- feat: engine.input dpad() 2D source — Pad_Quad runtime source kind (4283620)

### Fixes
- fix(plugin): rename funpack:mcp skill to funpack:funpack-mcp + from-zero install fix (4cef250)

## [0.4.0] - 2026-06-16

### Features
- feat: engine.input pad/mouse sources, diagnostics, and MCP resolver fixes (mario friction) (3c7bcaf)

### Other
- refactor: vendor funpack-spec into the monorepo (b392d66)

## [0.3.0] - 2026-06-15

### Features
- feat(plugin): funpack:mcp skill — install/update/uninstall the MCP binary into persistent storage (a8c3864)

## [0.2.0] - 2026-06-15

### Features
- feat(plugin): reshape funpack authoring surface onto the MCP (delete ops commands, repoint skills) (707edca)
- feat(mcp): bundle funpack-mcp into the plugin (.mcp.json + wrapper) + serve schema preflight (357853c)
