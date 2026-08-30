@echo off
rem tokenwar launcher for cmd.exe.
rem
rem tokenwar's engine is Bash. This shim finds the bash.exe that Git for Windows
rem ships and hands the dispatcher every argument unchanged, so `tokenwar status`
rem works from a plain Command Prompt without opening Git Bash first.
rem
rem Override the interpreter with TOKENWAR_BASH, and the install location with
rem TOKENWAR_DIR.
setlocal

set "TW_DIR=%TOKENWAR_DIR%"
if not defined TW_DIR set "TW_DIR=%USERPROFILE%\.claude\skills\tokenwar"
set "TW_SCRIPT=%TW_DIR%\scripts\tokenwar.sh"

set "TW_BASH=%TOKENWAR_BASH%"
if not defined TW_BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "TW_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined TW_BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "TW_BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined TW_BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "TW_BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined TW_BASH for %%B in (bash.exe) do if not defined TW_BASH set "TW_BASH=%%~$PATH:B"

if not defined TW_BASH (
    echo tokenwar: no bash.exe found. Install Git for Windows, or set TOKENWAR_BASH. 1>&2
    exit /b 127
)
if not exist "%TW_SCRIPT%" (
    echo tokenwar: dispatcher not found at "%TW_SCRIPT%". Set TOKENWAR_DIR, or reinstall. 1>&2
    exit /b 127
)

"%TW_BASH%" "%TW_SCRIPT%" %*
exit /b %ERRORLEVEL%
