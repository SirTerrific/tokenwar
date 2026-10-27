# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/). Dates are commit dates.

## [Unreleased]

### Fixed
- `--version` failures of a provider CLI no longer abort `status`, `check-updates`, `gain`
  (no more `set -o pipefail` side effect from `lib/providers.sh`).
- `install.sh` no longer overwrites an unparseable `settings.json`; it warns and leaves it.
- `uninstall.sh` runs `pxpipe-desktop.sh off` before deleting the install dir, so
  `HTTPS_PROXY` does not stay pointing at a dead proxy.
- `pxpipe-desktop.sh` keeps the user's own proxy / CA settings and restores them on `off`;
  it fails loudly on invalid JSON instead of reporting success.
- `upgrade.sh` no longer prints "Upgrade complete" when the re-check fails.
- `install.sh` / `uninstall.sh` rc-file edits keep symlinks and file mode, and refuse to
  strip a block that has no END marker.
- `check-updates.sh` / `upgrade.sh` detect a dev-built rtk without gawk-only `match()`
  (new helper `tw_rtk_dev_path`).
- `rtk-update.sh` downloads the installer to a file and runs it only if the download succeeded.
- `bundle.sh` treats `toggle.sh` exit 3 (standalone tools) as "manual", not failure.
- `scan`: Claude JSONL usage no longer double-counted per content block; unknown models
  flag the assumed Claude price.
- `gain.sh`: provider rows are labelled as usage, not savings.
- Statusline, `status.sh`, `check.sh` read enabled plugins and the rtk hook the same way
  (`settings.json` + `settings.local.json`).
- `copilot.sh` detects stale skills with `cmp -s`.
- `TOKENWAR_DIR` is honoured by the statusline and rc functions.
- `check.sh`: R5 compares config dirs; R4 renamed "tools installed".

### Added
- `tests/bundle.bats`; more tests for install, uninstall, rtk-update, scan, copilot.
- `CHANGELOG.md`.

### Changed
- OpenWiki CI pin bumped to `openwiki@0.7.2`.

## 2026-10-04 – 2026-10-08
- pxpipe desktop autostart through a Startup shortcut; terminal `claude` via warp.
- Savings priced at current Claude rates; monthly value per tool.
- Always install and upgrade every component at its latest version; `upgrade` re-checks after applying.
- `gain`: context-mode sandbox volume reported, not counted as saved; claude-mem 13+ read from `claude-mem.db`.

## 2026-09
- Added `tokenwar scan` (structured log parser, cache-aware cost model, report history).
- Added graphify as 7th tool, GitHub Copilot CLI as provider, OpenWiki project memory.
- Statusline detects the RTK rewrite hook.

## 2026-08-29 – 2026-08-31
- Windows port: Git Bash engine, PowerShell / cmd entry points, Windows CI, LF enforcement.

## v0.1.0
- Initial release (upstream).
