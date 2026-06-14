# Changelog

All notable changes to funpack are documented here.

This file is maintained automatically by the release workflow: every push to
`main` derives the next semver from the conventional-commit history and prepends
a version block here in the `chore(release)` commit. Edit older entries by hand
only — the newest block is generated.

## [0.4.0] - 2026-06-14

### Features
- feat(funpack): Cobra-shaped CLI framework replacing the per-verb dispatch (cdac685)

## [0.3.0] - 2026-06-14

### Features
- feat(funpack): `funpack version` verb embedding the release VERSION mirror (5bf7974)

### Other
- docs(docs): regenerate CLAUDE.md for prove plugin v4.2.1 (9df4af4)

## [0.2.0] - 2026-06-14

### Features
- feat(funpack): structured fix-criteria diagnostics for test/check/build (34aa95c)
- feat(funpack): fmt --check prints a unified diff (cb261bd)

### Fixes
- fix(funpack): anchor every diagnostic arm on a real source position (d7e10d0)

## [0.1.0] - 2026-06-13

Initial tagged release: the funpack compiler/toolchain (`funpack`) and the
runtime (`funpack-live`), with the native-matrix release build and Homebrew tap.
