# Changelog

All notable changes to funpack-mcp.

## [0.2.0] - 2026-06-15

### Features
- feat(mcp): bundle funpack-mcp into the plugin (.mcp.json + wrapper) + serve schema preflight (357853c)
- feat(mcp): §28 inspect-group tools (signals/pipeline/trace/diff/replay_behavior/draw_list/screenshot) (ed8e7b0)
- feat(mcp): attach supervisor uses --port-file poll + --token-file (no TOCTOU, token off env) (1302543)
- feat(runtime): §28 introspect surface ruling — implement despawn, drop inspect-bare/paused/reload_result (c3c94b8)
- feat(funpack): report §28 introspect-schema in `funpack version` (f566d2a)
- feat(mcp): §28 control tools (inject/set/spawn/emit/reload/branch/checkout) (e954e3b)
- feat(mcp): session reaper + concurrency cap + cleanup (9e685b8)
- feat(mcp): §28 time tools (load/run/pause/step/rewind/reset/status) (7190fa3)
- feat(mcp): §28 self-heal tools (capture_test + audit) (284088a)
- feat(mcp): Session.Call — shared §28 request/await primitive (49371ac)
- feat(mcp): test tool (structured pass/fail summary) (c2457fc)
- feat(mcp): session registry + start/end/list tools (2ee090d)
- feat(mcp): warden_* index-query tools (b5ed3a1)
- feat(mcp): build/export/check/fmt tools (bdd4bb8)
- feat(mcp): funpackexec RunInDir — cwd-targeted funpack invocation (dcae68e)
- feat(mcp): supervised funpack attach session (spawn+dial+handshake+demux) (8668f5d)
- feat(mcp): docs_search tool (ranked hits + corpus version) (bc68212)
- feat(mcp): funpack exec wrapper (structured stdout/stderr/exit) (12f7c1c)
- feat(mcp): query-shape ranking (symbols vs passages) (c9e31fc)
- feat(mcp): §28 async event demux (response correlation + event channel) (d28e31b)
- feat(mcp): §28 handshake + auth + version negotiate (ac64d39)
- feat(mcp): funpack resolver + version --json preflight (5beaa05)
- feat(mcp): docs symbol table extractor (exact+fuzzy) (aef7921)
- feat(mcp): corpus snapshot pin check (drift gate) (416995f)
- feat(mcp): §28 NDJSON envelope codec (exact-match, versioned) (2954d20)
- feat(mcp): passage fuzzy index (BM25 over prose) (2cf7fce)
- feat(mcp): docs_get tool (anchor → section) (766e9ed)
- feat(mcp): contract generator + generated Go API + sync tests (37fafe6)
- feat(mcp): docs corpus regen pipeline + loader + manifest (0c36164)
- feat(mcp): uniform error envelope + secret-safe logging (a9cceaa)

### Other
- docs(mcp): comment-audit — drop stale build-process anchors (8a590cf)

## [0.1.0] - 2026-06-15

### Features
- feat(mcp): scaffold Go MCP dev server (6987758)
