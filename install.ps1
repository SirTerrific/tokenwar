<#
.SYNOPSIS
    tokenwar installer for Windows (PowerShell).

.DESCRIPTION
    tokenwar's installer is install.sh, and it already does the right thing on
    Windows: it clones the repo, writes a statusLine that names bash.exe by full
    Windows path, and wires the shell functions into ~/.bashrc for Git Bash.

    This script does NOT reimplement any of that -- it locates Git Bash, hands the
    real installer your flags, and then adds only what Bash cannot reach:

      - a `tokenwar` function in your PowerShell $PROFILE
      - bin\ on your user PATH, so tokenwar.cmd works from Command Prompt too

    Run it from PowerShell. Git Bash users can keep using install.sh directly.

.PARAMETER WithPlugins
    Install and enable the four Claude Code plugins.

.PARAMETER WithRtk
    Install the RTK binary. On Windows, prefer installing rtk yourself
    (winget/scoop/cargo) and letting tokenwar find it on PATH.

.PARAMETER WithPxpipe
    Install the pinned pxpipe-proxy npm package.

.PARAMETER WithGraphify
    Install graphify (via uv tool, pipx or pip) and register its skill.

.PARAMETER WithOpenwiki
    Install the pinned OpenWiki npm package. Never initializes a repository.

.PARAMETER WithCopilot
    Wire the stack into GitHub Copilot CLI, when that CLI is installed.

.PARAMETER All
    All of the above.

.PARAMETER SkipProfile
    Do not touch $PROFILE or PATH; only run the Bash installer.

.EXAMPLE
    .\install.ps1 -All
#>
[CmdletBinding()]
param(
    [switch]$WithPlugins,
    [switch]$WithRtk,
    [switch]$WithPxpipe,
    [switch]$WithGraphify,
    [switch]$WithOpenwiki,
    [switch]$WithCopilot,
    [switch]$All,
    [switch]$SkipProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TwBegin = '# >>> tokenwar shell integration >>>'
$TwEnd = '# <<< tokenwar shell integration <<<'
$TwDir = if ($env:TOKENWAR_DIR) { $env:TOKENWAR_DIR } else { Join-Path $env:USERPROFILE '.claude\skills\tokenwar' }

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "!! $Message" -ForegroundColor Yellow }

function Find-GitBash {
    if ($env:TOKENWAR_BASH -and (Test-Path -LiteralPath $env:TOKENWAR_BASH)) { return $env:TOKENWAR_BASH }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    # Never fall back to System32\bash.exe -- that is the WSL launcher, a wholly
    # different environment that cannot see the Windows-side install.
    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch '\\System32\\' } |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    return $null
}

$bash = Find-GitBash
if (-not $bash) {
    throw 'No Git Bash found. Install Git for Windows (https://git-scm.com/download/win), then re-run. Override with $env:TOKENWAR_BASH.'
}
Write-Step "Using bash at $bash"

# -- 1. delegate to the real installer --------------------------------
$flags = @()
if ($All) { $flags += '--all' }
else {
    if ($WithPlugins) { $flags += '--with-plugins' }
    if ($WithRtk) { $flags += '--with-rtk' }
    if ($WithPxpipe) { $flags += '--with-pxpipe' }
    if ($WithGraphify) { $flags += '--with-graphify' }
    if ($WithOpenwiki) { $flags += '--with-openwiki' }
    if ($WithCopilot) { $flags += '--with-copilot' }
}

$localInstaller = Join-Path $PSScriptRoot 'install.sh'
if (Test-Path -LiteralPath $localInstaller) {
    Write-Step 'Running install.sh from this checkout'
    & $bash (& $bash -c "cygpath -u '$localInstaller'") @flags
} else {
    Write-Step 'Fetching and running install.sh'
    $remote = 'https://raw.githubusercontent.com/SirTerrific/tokenwar/main/install.sh'
    & $bash -c "curl -fsSL '$remote' | bash -s -- $($flags -join ' ')"
}
if ($LASTEXITCODE -ne 0) { throw "install.sh failed with exit code $LASTEXITCODE" }

if ($SkipProfile) {
    Write-Step 'Skipping $PROFILE and PATH wiring (-SkipProfile)'
    return
}

# -- 2. user PATH -----------------------------------------------------
# PATH first, on purpose. It is the mechanism that actually delivers the command
# -- to PowerShell AND to Command Prompt, which has no profile to wire. The
# $PROFILE function below is a convenience on top, and it must never be able to
# stop this from happening.
$binDir = Join-Path $TwDir 'bin'
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($null -eq $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $binDir) {
    Write-Step "Adding $binDir to your user PATH"
    $newPath = if ($userPath.TrimEnd(';')) { "$($userPath.TrimEnd(';'));$binDir" } else { $binDir }
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
} else {
    Write-Step 'bin already on your user PATH'
}

# -- 3. PowerShell profile (best effort) ------------------------------
# Mirrors the ~/.bashrc block install.sh writes. Idempotent: an existing block is
# replaced, never duplicated.
#
# Best effort because $PROFILE is not always writable. With OneDrive Known Folder
# Move redirecting Documents, `New-Item -ItemType Directory` REPORTS SUCCESS and
# creates nothing -- the next write then dies on a path that was never made. So
# verify the directory exists rather than trusting the return, and treat failure
# as a warning: PATH above already gives the user the command.
$profileWired = $false
try {
    $profileDir = Split-Path -Parent $PROFILE
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Test-Path -LiteralPath $profileDir)) {
        throw "profile directory could not be created: $profileDir"
    }

    $existing = @(Get-Content -LiteralPath $PROFILE -ErrorAction SilentlyContinue)
    $kept = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($line in $existing) {
        if ($line -eq $TwBegin) { $inBlock = $true; continue }
        if ($line -eq $TwEnd) { $inBlock = $false; continue }
        if (-not $inBlock) { $kept.Add($line) }
    }

    # Point at the .cmd, not a .ps1. Windows PowerShell's default ExecutionPolicy
    # is Restricted, which blocks .ps1 files outright; .cmd is not
    # policy-controlled and runs identically from PowerShell. Shipping a
    # tokenwar.ps1 in bin/ was worse than useless: PATH resolution prefers .ps1
    # over .cmd, so it shadowed the working entry point with one that could not run.
    $shim = Join-Path $TwDir 'bin\tokenwar.cmd'
    $block = @(
        $TwBegin,
        "function tokenwar { & '$shim' @args }",
        $TwEnd
    )
    Set-Content -LiteralPath $PROFILE -Value ($kept + $block) -Encoding UTF8
    Write-Step "Wired the tokenwar function into $PROFILE"
    $profileWired = $true
} catch {
    Write-Warn "Could not write $PROFILE ($($_.Exception.Message))."
    Write-Warn 'Skipped -- tokenwar still works: bin\ is on your PATH.'
}

Write-Host ''
Write-Host 'tokenwar installed.' -ForegroundColor Green
Write-Host ''
if ($profileWired) {
    Write-Host 'Open a new PowerShell window (or run  . $PROFILE ) then:'
} else {
    Write-Host 'Open a new PowerShell or Command Prompt window, then:'
}
Write-Host '  tokenwar status'
Write-Host '  tokenwar check'
Write-Host ''
Write-Host 'Restart Claude Code to load the plugins and the status bar.'
