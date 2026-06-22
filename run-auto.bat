@echo off
setlocal

:: AutoFish launcher from central root directory.
:: Must have Claude Code, Node.js, and Git for Windows (bash).

set "AUTOFISH_ROOT=%~dp0"
cd /d "%AUTOFISH_ROOT%"

where claude >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Claude Code CLI not found.
    echo   Install: npm install -g @anthropic-ai/claude-code
    echo   Or:     winget install Anthropic.ClaudeCode
    echo   Verify: claude --version
    pause
    exit /b 1
)
echo Claude Code: found

where node >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Node.js not found.
    echo   Install Node.js and verify: node --version
    pause
    exit /b 1
)
echo Node.js: found

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

for %%f in ("%BASH%") do set "GIT_USR_BIN=%%~dpf"
if exist "%GIT_USR_BIN%date.exe" (
    set "PATH=%GIT_USR_BIN%;%PATH%"
    echo Added to PATH: %GIT_USR_BIN%
)

set "MINGW_BIN=C:\Users\A\AppData\Local\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.MSVCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin"
if exist "%MINGW_BIN%\gcc.exe" (
    set "PATH=%MINGW_BIN%;%PATH%"
    echo Added to PATH: mingw64 gcc
)

if not exist "%AUTOFISH_ROOT%run-loop.sh" (
    echo [ERROR] run-loop.sh not found in %AUTOFISH_ROOT%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%auto-prompt.md" (
    echo [ERROR] auto-prompt.md not found in %AUTOFISH_ROOT%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%config.json" (
    echo [ERROR] config.json not found in %AUTOFISH_ROOT%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%PROJECT_SPEC.md" (
    echo [ERROR] PROJECT_SPEC.md not found in %AUTOFISH_ROOT%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%bootstrap-seed.md" (
    echo [ERROR] bootstrap-seed.md not found in %AUTOFISH_ROOT%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%autofish.js" (
    echo [ERROR] autofish.js not found in %AUTOFISH_ROOT%
    pause
    exit /b 1
)

echo.
echo ============================================================
echo   AutoFish - Multi Project Control
echo   Root: %AUTOFISH_ROOT%
echo   Started: %date% %time%
echo ============================================================
echo.

set "AUTOFISH_BASH=%BASH%"
node "%AUTOFISH_ROOT%autofish.js"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo AutoFish session ended. Exit code: %EXIT_CODE%
echo.
pause
endlocal
exit /b %EXIT_CODE%
