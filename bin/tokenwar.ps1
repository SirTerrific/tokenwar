<#
.SYNOPSIS
    tokenwar launcher for PowerShell.

.DESCRIPTION
    tokenwar's engine is Bash. This shim locates the bash.exe that Git for
    Windows ships and hands the dispatcher every argument unchanged, so
    `tokenwar status` works from PowerShell without opening Git Bash first.

    Override the interpreter with $env:TOKENWAR_BASH, and the install location
    with $env:TOKENWAR_DIR.

.EXAMPLE
    tokenwar status
    tokenwar disable context-mode
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-TokenwarBash {
    if ($env:TOKENWAR_BASH -and (Test-Path -LiteralPath $env:TOKENWAR_BASH)) {
        return $env:TOKENWAR_BASH
    }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    # Last resort: whatever bash is on PATH. Skip the WSL launcher in System32,
    # which is a different environment entirely and cannot run these scripts.
    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch '\\System32\\' } |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    return $null
}

$bash = Find-TokenwarBash
if (-not $bash) {
    Write-Error 'tokenwar: no bash.exe found. Install Git for Windows, or set $env:TOKENWAR_BASH.'
    exit 127
}

$dir = if ($env:TOKENWAR_DIR) { $env:TOKENWAR_DIR } else { Join-Path $env:USERPROFILE '.claude\skills\tokenwar' }
$script = Join-Path $dir 'scripts\tokenwar.sh'
if (-not (Test-Path -LiteralPath $script)) {
    Write-Error "tokenwar: dispatcher not found at '$script'. Set `$env:TOKENWAR_DIR, or reinstall."
    exit 127
}

if ($null -eq $Arguments) { $Arguments = @() }
& $bash $script @Arguments
exit $LASTEXITCODE
