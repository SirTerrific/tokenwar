---
type: platform
title: Windows support
description: How tokenwar runs on Windows through Git Bash — OS detection, path and line-ending handling, the PowerShell installer, and known limitations.
tags: [windows, git-bash, msys2, osdetect, install, powershell]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-5745bdc3f982182a15424be8
    resource: repo://docs/windows.md
  - id: openwiki-source-4e57a4160b61e0d1b0509927
    resource: repo://install.ps1
  - id: openwiki-source-03ffc32a0ca502ab67c54b25
    resource: repo://install.sh
  - id: openwiki-source-25ec849fb675ff56e872b106
    resource: repo://scripts/lib/osdetect.sh
  - id: openwiki-source-d14d4a301c3889866a5cef90
    resource: repo://tests/windows.bats
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Windows support

tokenwar runs on Windows through **Git Bash** (the MSYS2 bash shipped with Git
for Windows). The same scripts run on Linux, macOS and Windows; every
Windows-specific branch goes through one library, `scripts/lib/osdetect.sh`, so
the POSIX code path stays unchanged.

User-facing instructions live in `docs/windows.md`; this page explains how the
port works.

## OS detection — `scripts/lib/osdetect.sh`

Under Git Bash `$OSTYPE` reports `cygwin` (MSYS2 is a Cygwin fork), so it cannot
tell Windows apart from a real Cygwin. `tw_is_windows` relies on `uname -s`
(`MINGW*`, `MSYS*`, `CYGWIN*`) and `$OS` (`Windows_NT`) instead. Tests can pin
the answer with `TW_FORCE_OS=windows|posix`. A `TW_OSDETECT_SOURCED` guard makes
re-sourcing a no-op, because several scripts pull the library in transitively.

| Helper | What it isolates |
| ------ | ---------------- |
| `tw_is_windows` | The single "am I on Windows" test |
| `tw_user` | `$USER` is empty under Git Bash; falls back to `$USERNAME` |
| `tw_strip_cr` | Native Windows binaries (e.g. a native `rtk`) emit CRLF; a trailing `\r` would break every version comparison and badge |
| `tw_win_path` | Converts an MSYS path to a Windows path (`cygpath -w`) for native processes |
| `tw_node_path` / `tw_export_node_paths` | Native `node.exe` cannot resolve `/c/Users/...`; paths handed to Node are converted first |
| `tw_bash_path` | Windows path to a `bash.exe` that Claude Code can spawn for the statusline and hooks |
| `tw_config_dir` / `tw_data_dir` | Provider CLIs keep their state under `%APPDATA%` / `%LOCALAPPDATA%` rather than `~/.config` / `~/.local/share` |

`tw_bash_path` tries these in order:

1. `$EXEPATH\bash.exe`, Git for Windows' launcher directory as exposed by MSYS.
2. A fixed list of standard install locations (`TW_WIN_BASH_FALLBACKS`).
3. The bash currently running, translated to a Windows path.

The launcher is preferred because Claude Code spawns the statusline as a native
Windows process, and the stored command must name a `bash.exe` by its Windows
path.

`tw_config_dir` returns the first candidate directory that exists. If none
exists, it returns the platform's conventional location, so callers always have
a path to report.

## Installing from PowerShell — `install.ps1`

`install.ps1` does **not** reimplement the installer. It:

1. Finds Git Bash (`Find-GitBash`): first `$env:TOKENWAR_BASH`, then the usual
   Git for Windows locations. It deliberately skips `System32\bash.exe`, which
   is the WSL launcher, a different environment that cannot see this install.
2. Passes its switches to `install.sh`. There is one switch per flag
   (`-All`, `-WithPlugins`, `-WithRtk`, `-WithPxpipe`, `-WithGraphify`,
   `-WithOpenwiki`, `-WithCopilot`), and a test keeps the two lists in step.
3. Adds `bin\` to the **user** `PATH`. This is what makes `tokenwar` work in
   PowerShell and Command Prompt.
4. Adds a `tokenwar` function to `$PROFILE`, on a best-effort basis. With
   OneDrive Known Folder Move the profile may be impossible to create; in that
   case the installer warns and continues.

`-SkipProfile` leaves both `PATH` and `$PROFILE` untouched.

## Line endings and paths

- `.gitattributes` forces LF on `*.sh` and `*.bats`, so a checkout made with
  `core.autocrlf=true` cannot produce `$'\r': command not found`.
- When MSYS starts a native program, it normally rewrites path-like arguments
  (`/tmp/...` → `C:\...`). Many users set `MSYS_NO_PATHCONV=1`, which turns
  that rewrite off, and the resulting failure is **silent**: the native program
  simply cannot read the file. The scripts therefore never depend on the
  implicit rewrite. Paths sent to `node.exe` and other native tools are
  converted explicitly with `tw_node_path` / `tw_win_path`, so both modes
  behave the same. The suite runs in both modes to enforce this (see below).
- Symlinks: unless Developer Mode or `MSYS=winsymlinks:nativestrict` is on,
  `ln -s` silently creates a copy. That is why `install.sh` does not link the
  `pxpipe` shim into `~/.local/bin` on Windows: npm's prefix is already on
  `PATH`, and the installer copies the shim only when it is not.

## Tool-specific notes

- **RTK**: on Windows, `scripts/rtk-update.sh` installs RTK's official
  `x86_64-pc-windows-msvc` zip. It checks the archive against the release's
  sha256 digest before replacing `rtk.exe` in `~/.local/bin`. A release without
  a digest, or with a mismatched one, is refused.
- **pxpipe**: the terminal and the Claude desktop app are routed differently.
  See [pxpipe integration](../integrations/pxpipe.md).
- **Telemetry**: Codex, opencode and Copilot store their token usage in SQLite.
  The Windows `python3` is usually the Microsoft Store alias, which passes
  `command -v` but cannot run. When that happens, `tw_sqlite_engine` uses Node
  22+ `node:sqlite` instead. See
  [Other providers](../integrations/providers-and-launcher.md).

## Known limitations

- Without a working Python or Node 22+, Codex, opencode and Copilot telemetry is
  reported as `N/A`. tokenwar never substitutes a made-up number.
- `tokenwar upgrade` asks its question through `/dev/tty`. If no terminal is
  available it skips the update rather than guessing; pass `--yes` to update
  anyway.
- Claude Code must be able to launch Git Bash for the status bar and hooks to
  work.

## Tests

`tests/windows.bats` covers the helpers above. It uses `TW_FORCE_OS` to exercise
both branches on any OS, and it checks the real Windows behaviour when the suite
runs on Windows.

On Windows the whole suite runs twice: once normally and once with
`MSYS_NO_PATHCONV=1`. A Linux job also runs through `act`. See
[Test suite and CI](../testing/test-suite-and-ci.md).
