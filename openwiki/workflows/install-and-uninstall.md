---
type: workflow
title: Install and uninstall
description: How install.sh and install.ps1 install the stack, which flags do what, how shell and settings wiring stays idempotent, and what uninstall removes and leaves.
tags: [install, uninstall, windows, shell-integration, openwiki]
verified:
  - by: openwiki/0.7.0
    at: 2026-10-05T04:01:37.525Z
sources:
  - id: openwiki-source-4e57a4160b61e0d1b0509927
    resource: repo://install.ps1
  - id: openwiki-source-03ffc32a0ca502ab67c54b25
    resource: repo://install.sh
  - id: openwiki-source-2617925503e63e76fb4bef5a
    resource: repo://uninstall.ps1
  - id: openwiki-source-4ccef873414d626ff66115e6
    resource: repo://uninstall.sh
generated: { by: "claude-code", at: "2026-10-05T04:01:37.525Z" }
---

# Install and uninstall

`install.sh` is the single real installer. `install.ps1` is a thin Windows
wrapper around it. Both are safe to re-run.

## install.sh

Flags (all opt-in; a bare run installs no managed tool):

| Flag | Effect |
|---|---|
| `--with-plugins` | Register the marketplaces, install and enable the 4 Claude Code plugins, write the context-mode routing block into `~/.claude/CLAUDE.md` |
| `--with-rtk` | Install the RTK binary through `scripts/rtk-update.sh` |
| `--with-pxpipe` | `npm install -g` the pinned pxpipe-proxy package |
| `--with-graphify` | Install graphify via `uv tool`, then `pipx`, then `pip`; then run `graphify install` to register the skill |
| `--with-openwiki` | `npm install -g` OpenWiki (Node.js 22+); never runs `openwiki --init` |
| `--with-copilot` | Delegate to `scripts/copilot.sh wire --yes` |
| `--all` | All of the above |

Order of work:

1. `git` and `node` are required. Clone into `~/.claude/skills/tokenwar`, or
   `git pull --ff-only` if it is already a checkout. A non-git directory is moved
   aside to a `.bak-<timestamp>` copy, never deleted.
2. `chmod +x scripts/*.sh`.
3. Patch `~/.claude/settings.json` `statusLine` (timestamped backup first; no-op
   if already wired). On Windows the command names `bash.exe` by full path and
   uses `-c`, because Claude Code spawns it outside Git Bash.
4. Write the shell-integration block into `~/.bashrc` and `~/.zshrc` (create
   `~/.bashrc` if neither exists). The block exports `~/.local/bin`, defines
   `tokenwar()` and `claude()` (via `pxpipe-claude.sh`), and wraps
   `codex`, `gemini`, `kimi`, `opencode` and `copilot` with the launch banner.
5. Opt-in installs run in this order: plugins, RTK, pxpipe, graphify, OpenWiki.
6. RTK's hook is wired (`rtk init -g --auto-patch --hook-only`) when plugins or
   RTK were requested; if opencode is present the RTK opencode plugin is added.
7. Copilot wiring runs last, so it sees tools installed in the same run.

The final message depends on which flags were given, and always recommends
OpenWiki when it is not installed.

## Idempotency

Marked blocks are stripped with awk and rewritten, never appended twice:
the shell block (`# >>> tokenwar shell integration >>>`) and the CLAUDE.md block
(`<!-- >>> tokenwar context-mode routing >>> -->`). Installs of existing tools
are skipped when the binary is already on PATH.

Plugin enabling has an anti-clobber step: the first `claude plugin enable` can
flip implicitly enabled plugins to disabled, so the enabled set is snapshotted
and any dropped id is re-enabled.

## pxpipe on Windows

npm's global bin dir is `<prefix>` on Windows, not `<prefix>/bin`. If pxpipe is
not on PATH after install, the script looks there; it **copies** the shim into
`~/.local/bin` on Windows (MSYS `ln -s` silently copies anyway) and symlinks on
POSIX. It skips the link when source and target are the same file, which would
otherwise create a self-referential symlink.

## install.ps1

Runs under PowerShell, locates Git Bash, and passes the flags through
(`-WithPlugins`, `-WithRtk`, `-WithPxpipe`, `-WithGraphify`, `-WithOpenwiki`,
`-WithCopilot`, `-All`) to `install.sh`. It then adds only what Bash cannot
reach:

1. `bin\` of the install dir on the **user PATH** (done first, so `tokenwar.cmd`
   works in PowerShell and Command Prompt).
2. A `tokenwar` function in `$PROFILE`, pointing at `tokenwar.cmd` rather than a
   `.ps1`, because the default ExecutionPolicy blocks `.ps1` files. This step is
   best effort: a failure to write `$PROFILE` is only a warning.

`-SkipProfile` skips both steps.

## Uninstall

`uninstall.sh` (also curl-pipeable, so it duplicates the OS helpers instead of
sourcing them):

- removes `statusLine` from `settings.json` when it points at
  `tokenwar-statusline.sh` (matched by script name, so the Windows form is
  caught), after a timestamped backup;
- strips the shell block from `~/.bashrc` / `~/.zshrc` and the routing block
  from `~/.claude/CLAUDE.md`;
- deletes the install directory.

It leaves the managed tools themselves (plugins, RTK, pxpipe, graphify, OpenWiki)
installed and prints the commands to remove them.

`uninstall.ps1` first removes the `$PROFILE` block and the PATH entry, then runs
`uninstall.sh` through Git Bash. Without Git Bash it warns and leaves the
statusLine, the `~/.bashrc` block and the install directory in place.

See also: [pxpipe](../integrations/pxpipe.md), [Windows platform](../platform/windows.md),
[upgrade and update check](upgrade-and-update-check.md).
