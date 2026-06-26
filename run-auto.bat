@echo off
setlocal EnableDelayedExpansion

:: AutoFish launcher from central root directory.
:: Must have Claude Code, Node.js, and Git for Windows (bash).

for /f %%a in ('echo prompt $E^| cmd') do set "ESC=%%a"
set "C_RESET=%ESC%[0m"
set "C_NOTE=%ESC%[90m"
set "C_RUN=%ESC%[33m"
set "C_KEY=%ESC%[96m"
set "C_WARN=%ESC%[93m"
set "C_ERR=%ESC%[91m"
if defined NO_COLOR (
  set "C_RESET="
  set "C_NOTE="
  set "C_RUN="
  set "C_KEY="
  set "C_WARN="
  set "C_ERR="
)

set "AUTOFISH_ROOT=%~dp0"
cd /d "%AUTOFISH_ROOT%"

echo.
echo %C_KEY%=== Dependency check ===%C_RESET%
echo.
echo %C_NOTE%Checking Claude Code...%C_RESET%
where claude >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo %C_ERR%[ERROR] Claude Code CLI not found.%C_RESET%
    echo %C_NOTE%  Install: npm install -g @anthropic-ai/claude-code%C_RESET%
    echo %C_NOTE%  Or:     winget install Anthropic.ClaudeCode%C_RESET%
    echo %C_NOTE%  Verify: claude --version%C_RESET%
    pause
    exit /b 1
)
echo %C_RUN%  Claude Code: found%C_RESET%

echo %C_NOTE%Checking Node.js...%C_RESET%
where node >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo %C_ERR%[ERROR] Node.js not found.%C_RESET%
    echo %C_NOTE%  Install Node.js and verify: node --version%C_RESET%
    pause
    exit /b 1
)
echo %C_RUN%  Node.js: found%C_RESET%

echo %C_NOTE%Checking Git Bash...%C_RESET%
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
    echo %C_ERR%[ERROR] bash.exe not found.%C_RESET%
    echo %C_NOTE%  Checked: C:\Program Files\Git\bin\bash.exe%C_RESET%
    echo %C_NOTE%  Checked: C:\Program Files\Git\usr\bin\bash.exe%C_RESET%
    echo %C_NOTE%  Please install Git for Windows:%C_RESET%
    echo %C_NOTE%  https://git-scm.com/download/win%C_RESET%
    pause
    exit /b 1
)
echo %C_RUN%  bash: %BASH%%C_RESET%

for %%f in ("%BASH%") do set "GIT_USR_BIN=%%~dpf"
if exist "%GIT_USR_BIN%date.exe" (
    set "PATH=%GIT_USR_BIN%;%PATH%"
    echo %C_NOTE%  PATH+: %GIT_USR_BIN%%C_RESET%
)

set "MINGW_BIN=C:\Users\A\AppData\Local\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.MSVCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin"
if exist "%MINGW_BIN%\gcc.exe" (
    set "PATH=%MINGW_BIN%;%PATH%"
    echo %C_NOTE%  PATH+: mingw64 gcc%C_RESET%
)

echo.
echo %C_KEY%=== AutoFish ===%C_RESET%
echo.
echo %C_NOTE%Root:    %AUTOFISH_ROOT%%C_RESET%
echo %C_NOTE%Started: %date% %time%%C_RESET%

if not exist "%AUTOFISH_ROOT%run-loop.sh" (
    echo %C_ERR%[ERROR] run-loop.sh not found in %AUTOFISH_ROOT%%C_RESET%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%auto-prompt.md" (
    echo %C_ERR%[ERROR] auto-prompt.md not found in %AUTOFISH_ROOT%%C_RESET%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%config.json" (
    echo %C_ERR%[ERROR] config.json not found in %AUTOFISH_ROOT%%C_RESET%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%PROJECT_SPEC.md" (
    echo %C_ERR%[ERROR] PROJECT_SPEC.md not found in %AUTOFISH_ROOT%%C_RESET%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%bootstrap-seed.md" (
    echo %C_ERR%[ERROR] bootstrap-seed.md not found in %AUTOFISH_ROOT%%C_RESET%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%autofish.js" (
    echo %C_ERR%[ERROR] autofish.js not found in %AUTOFISH_ROOT%%C_RESET%
    pause
    exit /b 1
)
if not exist "%AUTOFISH_ROOT%progress-filter.js" (
    echo %C_WARN%[WARN] progress-filter.js not found. AutoFish will fall back to spinner mode.%C_RESET%
)
if not exist "%AUTOFISH_ROOT%harness-check.js" (
    echo %C_WARN%[WARN] harness-check.js not found. Harness supervision will fail if enabled.%C_RESET%
)

echo.
set "AUTOFISH_BASH=%BASH%"
node "%AUTOFISH_ROOT%autofish.js"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo %C_KEY%AutoFish session ended. Exit code: %EXIT_CODE%%C_RESET%
echo.
pause
endlocal
exit /b %EXIT_CODE%
