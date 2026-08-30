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

Pick the shell you actually live in — both end at the same installed state.

### From PowerShell

```powershell
.\install.ps1 -All
```

`install.ps1` does **not** reimplement the installer. It locates Git Bash, hands
`install.sh` your flags, and then adds only what Bash cannot reach: a `tokenwar`
function in your `$PROFILE`, and `bin\` on your user PATH so `tokenwar` also
resolves from Command Prompt. Pass `-SkipProfile` to leave `$PROFILE` and PATH
alone.

```powershell
. $PROFILE      # or open a new window
tokenwar status
tokenwar check
```

### From Git Bash

```bash
curl -fsSL https://raw.githubusercontent.com/SirTerrific/tokenwar/main/install.sh | bash -s -- --all
source ~/.bashrc
tokenwar status
tokenwar check
```

Restart Claude Code to load the plugins and the status bar.

### Uninstall

```powershell
.\uninstall.ps1
```

Removes the `$PROFILE` block and the PATH entry, then delegates to
`uninstall.sh` for the statusLine, the `~/.bashrc` block and the install
directory. As upstream, it leaves the six tools themselves installed.

## Running tokenwar outside Git Bash

The engine is Bash, so every entry point ends up calling the same
`scripts/tokenwar.sh`:

| Shell | Entry point | Wired by |
| ----- | ----------- | -------- |
| Git Bash | `tokenwar` shell function | `install.sh` (`~/.bashrc`) |
| PowerShell | `bin\tokenwar.cmd` on PATH, plus a `$PROFILE` function | `install.ps1` |
| Command Prompt | `bin\tokenwar.cmd` on PATH | `install.ps1` |

**There is deliberately no `bin\tokenwar.ps1`.** Windows PowerShell defaults to an
ExecutionPolicy of Restricted, which refuses to run `.ps1` files at all — and PATH
resolution prefers `.ps1` over `.cmd`, so shipping one shadowed the entry point
that works with one that could not run. A `.cmd` is not policy-controlled and
behaves identically when called from PowerShell.

The same policy applies to `install.ps1` itself. If yours is restrictive:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -All
```

The shim finds `bash.exe` this way — `$env:TOKENWAR_BASH`, then the usual
Git for Windows locations, then PATH, deliberately skipping
`System32\bash.exe` (that is the WSL launcher, a different environment that
cannot see this install). Override the install location with
`$env:TOKENWAR_DIR`.

The `.ps1` files are kept **ASCII-only** on purpose: Windows PowerShell 5.1
reads a `.ps1` without a BOM using the ANSI codepage, so a single UTF-8
character inside a double-quoted string decodes into stray bytes and breaks
parsing outright. A test enforces this.

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
node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).statusLine)' < ~/.claude/settings.json
echo '{}' | bash ~/.claude/skills/tokenwar/scripts/tokenwar-statusline.sh
```

The redirect is deliberate: it lets the shell resolve the path, so no MSYS path is
handed to node — which, being a native Windows binary, cannot open one. Passing
`~/.claude/settings.json` to node as a string fails with a bare `ENOENT` here.

**`USER: unbound variable`.** An old checkout. `$USER` is empty under Git Bash;
current tokenwar falls back to `$USERNAME`.

**Scripts fail with `$'\r': command not found`.** CRLF in the checkout. Confirm
and fix:

```bash
grep -rlU $'\r' --include='*.sh' --include='*.bats' .
git add --renormalize .
```

**`tokenwar` is not a command after installing.** In Git Bash, reload the shell
(`source ~/.bashrc`) or open a new window. In PowerShell or Command Prompt, open a
new window — PATH changes only reach new processes.

**`install.ps1` warns it could not write `$PROFILE`.** Expected on machines where
OneDrive Known Folder Move redirects `Documents`: `New-Item -ItemType Directory`
reports success there and creates nothing, so the profile path never
materialises. The install continues on purpose — `bin\` is on your PATH, which is
what actually delivers the `tokenwar` command to both PowerShell and Command
Prompt. The `$PROFILE` function is only a convenience. Check where PowerShell
expects it, and whether that directory is real:

```powershell
$PROFILE
Test-Path (Split-Path -Parent $PROFILE)
```

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
