<h1 align="center">TokenWar</h1>

<p align="center"><img src="docs/logo.png" alt="TokenWar logo" width="160"></p>
<p align="center"><img src="docs/tokenwar-stack.png" alt="TokenWar token-saving stack" width="100%"></p>

[![CI](https://github.com/SirTerrific/tokenwar/actions/workflows/ci.yml/badge.svg)](https://github.com/SirTerrific/tokenwar/actions/workflows/ci.yml)

**Seven complementary token-saving tools plus a shared project-memory layer.**
TokenWar reduces shell output, heavy context, repeated memory, provider payloads,
verbose responses, oversized code, and repository exploration. OpenWiki adds a
durable wiki that lets an entire team reuse the cost of understanding a project.

This fork adds **Windows support** (Git Bash runtime, PowerShell and Command
Prompt entry points) and tracks [upstream](https://github.com/oratelecom/tokenwar).

## Documentation menu

| Page | Use it for |
| --- | --- |
| [Install](docs/installation.md) | Default behavior, `--all`, optional flags, verification |
| [Windows](docs/windows.md) | Git Bash runtime, PowerShell / Command Prompt entry points, limitations |
| [Project memory](docs/project-memory.md) | Graphify + OpenWiki, team workflow, CI, costs and refresh policy |
| [Tool map](docs/tokenwar-tools.md) | What each tool saves and when to use it |
| [Savings](docs/savings.md) | Why the lanes stack and how gains are measured honestly |
| [Commands](docs/operations.md) | Status, gain, doctor, providers and maintenance |
| [Local scan](docs/scan.md) | Log audit, recommendations and break-even method |
| [Copilot](docs/copilot.md) | GitHub Copilot CLI wiring |

## Quick start

Install everything, including Graphify and OpenWiki:

```bash
curl -fsSL https://raw.githubusercontent.com/SirTerrific/tokenwar/main/install.sh | bash -s -- --all
source ~/.bashrc
tokenwar status
tokenwar check
tokenwar gain
```

A bare install is intentionally non-invasive: it installs TokenWar and its shell
integration, but none of the managed tools. See [installation modes](docs/installation.md).

### Windows

Requires [Git for Windows](https://git-scm.com/download/win): its bash is the
engine. From PowerShell, in a clone of this repository:

```powershell
.\install.ps1 -All
```

Or run the `curl … | bash -s -- --all` line above from Git Bash. `install.ps1` is
a thin wrapper: it finds Git Bash, hands `install.sh` your flags, then puts `bin\`
on your PATH so `tokenwar` also works from PowerShell and Command Prompt. The
status bar is a feature of the `claude` terminal CLI; the desktop app does not
draw it. Details, limitations and troubleshooting: [docs/windows.md](docs/windows.md).

## The stack

| Tool | Lane |
| --- | --- |
| caveman | Compact model responses |
| RTK | Compress shell and tool output |
| context-mode | Keep heavy data outside the context window |
| claude-mem | Preserve personal cross-session memory |
| pxpipe | Reduce provider-bound prompt payloads |
| Graphify | Query repository structure instead of repeatedly sweeping files |
| ponytail | Produce smaller code that stays cheaper to read |
| **OpenWiki** | **Create shared, versioned project memory for the whole team** |

OpenWiki is deliberately shown separately from the seven live compression lanes.
It spends tokens to synthesize grounded Markdown, then amortizes that cost across
developers, agents, providers, sessions, onboarding, reviews and incidents.

```text
claude-mem = what my agent learned
OpenWiki   = what the team knows about the project
```

## Recommended project routine

Inside every active, long-lived repository:

```bash
graphify .             # initial structural graph
openwiki --init        # initial grounded project wiki (uses an LLM)

graphify update .      # after code changes; AST update needs no LLM
openwiki --update      # after merges; clean no-op uses no LLM
```

For teams, commit the OpenWiki output and run updates in CI so one generation is
shared by everyone. Details and a CI pattern are in
[Project memory](docs/project-memory.md).

## Commands

```bash
tokenwar status
tokenwar test
tokenwar check
tokenwar gain
tokenwar doctor
tokenwar scan
tokenwar upgrade
```

TokenWar never fabricates savings. Native telemetry is reported where available;
otherwise the result is `N/A` or an explicitly labelled estimate.

## Credits

**Original project — [Ora Studio](https://studio.oratelecom.net) · Ora Telecom.**
TokenWar is their design: the lane thesis, the complementarity rules, the
honest-telemetry stance, and the scripts this fork builds on. Upstream:
[oratelecom/tokenwar](https://github.com/oratelecom/tokenwar).

**Windows port — [Jerome Carbel](https://github.com/SirTerrific) (@SirTerrific).**
This fork adds and maintains Windows support: the Git Bash runtime path, the OS
detection layer, the `node:sqlite` telemetry reader, the PowerShell and Command
Prompt entry points, the `windows-latest` CI job, and `docs/windows.md`.

## License

[MIT](LICENSE) — © 2026 Ora Telecom, © 2026 Jerome Carbel (Windows port).
