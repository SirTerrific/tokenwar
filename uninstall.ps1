<#
.SYNOPSIS
    tokenwar uninstaller for Windows (PowerShell).

.DESCRIPTION
    Runs the real uninstaller (uninstall.sh -- it removes the statusLine, the
    ~/.bashrc block and the install directory), then removes what only
    PowerShell knows about: the $PROFILE block and the PATH entry.

    Like uninstall.sh, this leaves the six tools themselves installed.

.EXAMPLE
    .\uninstall.ps1
#>
[CmdletBinding()]
param()

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
    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch '\\System32\\' } |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    return $null
}

# -- 1. PowerShell profile --------------------------------------------
# Done first: the Bash uninstaller deletes the directory the $PROFILE block
# points at, so clearing the block before that keeps the ordering honest.
if (Test-Path -LiteralPath $PROFILE) {
    $existing = @(Get-Content -LiteralPath $PROFILE)
    if ($existing -contains $TwBegin) {
        Write-Step "Removing the tokenwar block from $PROFILE"
        $kept = New-Object System.Collections.Generic.List[string]
        $inBlock = $false
        foreach ($line in $existing) {
            if ($line -eq $TwBegin) { $inBlock = $true; continue }
            if ($line -eq $TwEnd) { $inBlock = $false; continue }
            if (-not $inBlock) { $kept.Add($line) }
        }
        Set-Content -LiteralPath $PROFILE -Value $kept -Encoding UTF8
    }
}

# -- 2. user PATH -----------------------------------------------------
$binDir = Join-Path $TwDir 'bin'
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($userPath -and (($userPath -split ';') -contains $binDir)) {
    Write-Step "Removing $binDir from your user PATH"
    $kept = ($userPath -split ';') | Where-Object { $_ -and $_ -ne $binDir }
    [Environment]::SetEnvironmentVariable('PATH', ($kept -join ';'), 'User')
}

# -- 3. delegate to the real uninstaller ------------------------------
$bash = Find-GitBash
$localUninstaller = Join-Path $TwDir 'uninstall.sh'
if (-not $bash) {
    Write-Warn 'No Git Bash found -- the statusLine, the ~/.bashrc block and the install directory were left in place.'
} elseif (Test-Path -LiteralPath $localUninstaller) {
    Write-Step 'Running uninstall.sh'
    & $bash (& $bash -c "cygpath -u '$localUninstaller'")
} else {
    Write-Warn "uninstall.sh not found at $localUninstaller -- nothing else to remove."
}

Write-Host ''
Write-Host 'tokenwar uninstalled.' -ForegroundColor Green
Write-Host 'Open a new PowerShell window for the PATH change to take effect.'
Write-Host 'Restart Claude Code to drop the status bar.'
