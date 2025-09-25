# Repository Guidelines

## Project Structure & Module Organization
- `src/` — app code: Zig (`main.zig`, `core.zig`) and Swift (`tray.swift`, `auth.swift`).
- `build.zig` — Zig build graph; compiles Swift to `.o` and links frameworks.
- `build.zig.zon` — package/dep metadata.
- `test/` — Zig tests entry (`test_all.zig`) referenced by `build.zig`.
- Generated: `zig-out/`, `.zig-cache/`, `macosx-sdks/` (from script) — do not commit.
- Utilities: `update-macosx-sdks.sh`, `README.md`.

## Build, Test, and Development Commands
- `sh update-macosx-sdks.sh` — vendor macOS SDK headers/libs locally (first run or after Xcode updates).
- `zig build` — build and install the `zz` binary into `zig-out`.
- `zig build run -- [args]` — build and run from install dir.
- `zig build -Doptimize=ReleaseFast` — release build.
- `zig build test` — run unit tests (expects `test/test_all.zig`).
- Tip: `zig build --help` shows available steps (e.g., `run`, `test`).

## Coding Style & Naming Conventions
- Zig: use `zig fmt` (4-space indent, no tabs). Files snake_case (`core.zig`); types `PascalCase`; funcs/vars `camelCase`.
- Swift: follow Swift API guidelines; keep file names lowercase to match repo (`tray.swift`).
- Keep modules small; prefer `src/` submodules imported via `@import("file.zig")`.

## Testing Guidelines
- Place tests in `test/test_all.zig` or inline `test {}` blocks in `src/*.zig` imported by `test_all.zig`.
- Name tests descriptively: `test "formats elapsed time" { ... }`.
- Aim to cover core time-tracking logic and file I/O paths.
- Run with `zig build test` locally; keep tests deterministic (no network/UI).

## Commit & Pull Request Guidelines
- Commit messages: imperative, concise, present-tense (e.g., "Add core timer logic").
- PRs: include a summary, testing steps (`zig build run`/`zig build test`), linked issues, and screenshots for tray/UI changes.
- Scope PRs narrowly; avoid committing generated files (`*.o`, `zig-out/`, `.zig-cache/`, `macosx-sdks/`).

## macOS SDK & Linking Notes
- This project links Apple frameworks (AppKit, Foundation, IOKit, etc.) and Swift runtime.
- Adding Swift files: place in `src/` and include in the `swiftc` source list in `build.zig`.
