@echo off
setlocal

:: TideStone Auto-Dev Launcher
:: Double-click this file to start autonomous CC development loop.
:: Must have Git for Windows (bash) and Claude Code installed.

:: Auto-detect: script is in .asdf/, project is parent
set "SCRIPT_DIR=%~dp0"
for %%A in ("%SCRIPT_DIR%..") do set "PROJECT_DIR=%%~fA"

cd /d "%PROJECT_DIR%"

:: Find bash (try multiple known locations)
set "BASH="
for %%d in (
    "C:\Program Files\Git\bin"
    "C:\Program Files\Git\usr\bin"
    "C:\Program Files (x86)\Git\bin"
    "C:\Program Files (x86)\Git\usr\bin"
    "%LocalAppData%\Programs\Git\bin"
) do (
    if exist "%%~d\bash.exe" set "BASH=%%~d\bash.exe"
)
:: Also check PATH
if "%BASH%"=="" (
    where bash >nul 2>&1 && set "BASH=bash"
)
if "%BASH%"=="" (
    echo [ERROR] bash.exe not found.
    echo   Checked: C:\Program Files\Git\bin\bash.exe
    echo   Checked: C:\Program Files\Git\usr\bin\bash.exe
    echo   Please install Git for Windows:
    echo   https://git-scm.com/download/win
    pause
    exit /b 1
)
echo Found bash: %BASH%

:: Inject Git usr/bin into PATH so bash can find date/cat/rm/sleep/mktemp
for %%f in ("%BASH%") do set "GIT_USR_BIN=%%~dpf"
if exist "%GIT_USR_BIN%date.exe" (
    set "PATH=%GIT_USR_BIN%;%PATH%"
    echo Added to PATH: %GIT_USR_BIN%
)

:: Also add mingw64/bin for gcc
set "MINGW_BIN=C:\Users\A\AppData\Local\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.MSVCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin"
if exist "%MINGW_BIN%\gcc.exe" (
    set "PATH=%MINGW_BIN%;%PATH%"
    echo Added to PATH: mingw64 gcc
)

:: Check run-loop.sh
if not exist "%SCRIPT_DIR%\run-loop.sh" (
    echo [ERROR] run-loop.sh not found in %SCRIPT_DIR%
    pause
    exit /b 1
)

:: Check auto-prompt.md
if not exist "%SCRIPT_DIR%\auto-prompt.md" (
    echo [ERROR] auto-prompt.md not found in %SCRIPT_DIR%
    pause
    exit /b 1
)

echo.
echo ============================================================
echo   TideStone - Autonomous Dev Mode
echo   Project: %PROJECT_DIR%
echo   Started: %date% %time%
echo   Press Ctrl+C to stop at any time
echo ============================================================
echo.

:: Hand off to bash loop script
"%BASH%" "%SCRIPT_DIR%/run-loop.sh"

echo.
echo Autonomous session ended.
echo   Done tasks:    type "%SCRIPT_DIR%\task-done.txt"
echo   Blocked tasks: type "%SCRIPT_DIR%\task-blocked.txt"
echo   Full log:      type "%SCRIPT_DIR%\auto-log.txt"
echo.
pause
endlocal
