# tokenwar on Windows

tokenwar runs on Windows through **Git Bash** — the MSYS2 bash that ships with
Git for Windows. The scripts are the same ones Linux and macOS run; this page
covers what the platform changes and what it costs you.

## Requirements

| Component | Why | Check |
| --------- | --- | ----- |
| [Git for Windows](https://git-scm.com/download/win) | Provides the bash, coreutils, awk, sed and curl every script uses | `"C:\Program Files\Git\bin\bash.exe" --version` |
| Node 18+ (22+ recommended) | Every script parses JSON with it; 22+ also unlocks the SQLite reader below | `node --version` |
| Claude Code | The four plugins and the status bar | `claude --version` |

Node 22 or newer is worth having: it ships `node:sqlite`, which is how tokenwar
reads Codex and opencode token telemetry when Python is unavailable — the normal
case on Windows (see [Known limitations](#known-limitations)).

## Install

From **Git Bash**, not PowerShell or cmd:

```bash
curl -fsSL https://raw.githubusercontent.com/oratelecom/tokenwar/main/install.sh | bash -s -- --all
```

Then reload the shell and verify:

```bash
source ~/.bashrc
tokenwar status
tokenwar check
```

Restart Claude Code to load the plugins and the status bar.

## What the installer does differently here

**The status bar names bash by its full path.** Claude Code spawns the
`statusLine` command itself, as a native Windows process — outside any Git Bash
session, where a bare `bash` may not resolve and `~` is not expanded by the
caller. So `install.sh` writes:

```json
"statusLine": {
  "type": "command",
  "command": "\"C:\\Program Files\\Git\\bin\\bash.exe\" -c '~/.claude/skills/tokenwar/scripts/tokenwar-statusline.sh'"
}
```

`-c` rather than `-lc`: the bar renders constantly, and everything it needs
(`node`, `claude`, `rtk`) is already on the Windows PATH. The statusline script
also puts `~/.local/bin` on its own PATH, so `rtk` is found even if its installer
did not add it.

**pxpipe is copied, not symlinked.** npm's global bin directory is `<prefix>` on
Windows, not `<prefix>/bin`, and MSYS turns `ln -s` into a silent file *copy*
unless Developer Mode or `MSYS=winsymlinks:nativestrict` is set. The installer
copies deliberately rather than claiming a link it did not make. In practice npm's
prefix is already on PATH, so this path rarely runs at all.

**Line endings are pinned.** `.gitattributes` forces LF on `*.sh` and `*.bats`.
Without it a checkout with `core.autocrlf=true` (the Git for Windows default)
rewrites the scripts to CRLF, and the trailing `\r` breaks the shebang, every
`case` pattern, and every string comparison. If you cloned before this file
existed, run `git add --renormalize .`.

## RTK

A native Windows `rtk` build is the ideal case and needs nothing special:
tokenwar only ever calls it as a command (`rtk gain`, `rtk --version`,
`rtk init -g`). RTK wires its own Claude Code hook, which tokenwar merely
detects.

`--with-rtk` will not pipe a POSIX installer into `sh` on Windows. Install rtk
yourself — `winget`, `scoop`, `cargo`, or the release binary — and tokenwar picks
it up from PATH. `tokenwar upgrade` likewise skips rtk unless it was installed
with `cargo install --path`, so you manage that binary directly.

## Known limitations

**Codex and opencode telemetry needs a real Python or Node 22+.** Both stores are
SQLite. Windows ships a `python3` "app execution alias" that only opens the
Microsoft Store: it satisfies `command -v python3` and fails on every actual run,
so tokenwar probes engines by *running* them and falls back to `node:sqlite`.
With neither available both providers report `N/A` — never a fabricated zero.

**The interactive upgrade prompt needs a terminal.** `tokenwar upgrade` reads
`[y/N]` from `/dev/tty`. Run it from Git Bash, or pass `--yes`.

**Claude Code must be able to run Git Bash.** The status bar and the
`bash ~/.claude/skills/tokenwar/scripts/...` calls in the `/tokenwar` skill both
depend on it.

## Troubleshooting

**The status bar is missing after restarting Claude Code.** Check what got
written, and that it runs:

```bash
node -e 'console.log(JSON.parse(require("fs").readFileSync(process.env.HOME+"/.claude/settings.json","utf8")).statusLine)'
echo '{}' | bash ~/.claude/skills/tokenwar/scripts/tokenwar-statusline.sh
```

**`USER: unbound variable`.** An old checkout. `$USER` is empty under Git Bash;
current tokenwar falls back to `$USERNAME`.

**Scripts fail with `$'\r': command not found`.** CRLF in the checkout. Confirm
and fix:

```bash
grep -rlU $'\r' --include='*.sh' --include='*.bats' .
git add --renormalize .
```

**`tokenwar` is not a command after installing.** Reload the shell
(`source ~/.bashrc`) or open a new Git Bash window.

## Running the tests

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bats tests/
```

The locale is **required**, not cosmetic. Under the default `C` locale, bats on
Windows cannot parse `@test` names containing non-ASCII characters — several here
use an em dash — and reports `bats: unknown test name` for each, silently running
only the ASCII-named subset while still **exiting 0**. The tell is a trailing
`# bats warning: Executed 74 instead of expected 110 tests`. CI sets the locale
for exactly this reason.

`bats` and `shellcheck` install from npm on Windows:

```bash
npm install -g bats shellcheck
```

Expect the suite to take several minutes: process spawning is far slower on
Windows than on Linux, and bats spawns heavily.
