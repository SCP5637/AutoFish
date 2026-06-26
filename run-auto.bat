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

set "BOX_TL=+"
set "BOX_TR=+"
set "BOX_BL=+"
set "BOX_BR=+"
set "BOX_HZ=-"
set "BOX_VT=^|"
set "CHECK=[OK]"
set "CROSS=[XX]"
set "WARN_SYM=/!\"

set "AUTOFISH_ROOT=%~dp0"
cd /d "%AUTOFISH_ROOT%"

echo.
set "P60=                                                            "
set "BH=------------------------------------------------------------"

:: Box header
set "htitle=%BH%"
echo %C_KEY%%BOX_TL%-- Dependency Check %htitle:~0,38%%BOX_TR%%C_RESET%

:: Claude Code
echo %BOX_VT% %C_NOTE%Checking Claude Code...%C_RESET%
where claude >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    set "ctext=%CROSS%  Claude Code CLI not found.%P60%"
    echo %BOX_VT% %C_ERR%!ctext:~0,57!%C_RESET% %BOX_VT%
    echo %BOX_BL%%BH:~0,58%%BOX_BR%
    echo.
    echo %C_NOTE%  Install: npm install -g @anthropic-ai/claude-code%C_RESET%
    echo %C_NOTE%  Or:     winget install Anthropic.ClaudeCode%C_RESET%
    echo %C_NOTE%  Verify: claude --version%C_RESET%
    pause
    exit /b 1
)
set "ctext=%CHECK%  Claude Code%P60%"
echo %BOX_VT% %C_RUN%!ctext:~0,57!%C_RESET% %BOX_VT%

:: Node.js
echo %BOX_VT% %C_NOTE%Checking Node.js...%C_RESET%
where node >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    set "ctext=%CROSS%  Node.js not found.%P60%"
    echo %BOX_VT% %C_ERR%!ctext:~0,57!%C_RESET% %BOX_VT%
    echo %BOX_BL%%BH:~0,58%%BOX_BR%
    echo.
    echo %C_NOTE%  Install Node.js and verify: node --version%C_RESET%
    pause
    exit /b 1
)
set "ctext=%CHECK%  Node.js%P60%"
echo %BOX_VT% %C_RUN%!ctext:~0,57!%C_RESET% %BOX_VT%

:: Git Bash
echo %BOX_VT% %C_NOTE%Checking Git Bash...%C_RESET%
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
    set "ctext=%CROSS%  Git Bash not found.%P60%"
    echo %BOX_VT% %C_ERR%!ctext:~0,57!%C_RESET% %BOX_VT%
    echo %BOX_BL%%BH:~0,58%%BOX_BR%
    echo.
    echo %C_NOTE%  Checked: C:\Program Files\Git\bin\bash.exe%C_RESET%
    echo %C_NOTE%  Checked: C:\Program Files\Git\usr\bin\bash.exe%C_RESET%
    echo %C_NOTE%  Please install Git for Windows:%C_RESET%
    echo %C_NOTE%  https://git-scm.com/download/win%C_RESET%
    pause
    exit /b 1
)
set "ctext=%CHECK%  Git Bash: !BASH!%P60%"
echo %BOX_VT% %C_RUN%!ctext:~0,57!%C_RESET% %BOX_VT%

:: Box footer
echo %BOX_BL%%BH:~0,58%%BOX_BR%

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
echo %C_KEY%%BOX_TL%-- AutoFish %BH:~0,46%%BOX_TR%%C_RESET%
set "ctext=Root:    %AUTOFISH_ROOT%%P60%"
echo %BOX_VT% %C_NOTE%!ctext:~0,57!%C_RESET% %BOX_VT%
set "ctext=Started: %date% %time%%P60%"
echo %BOX_VT% %C_NOTE%!ctext:~0,57!%C_RESET% %BOX_VT%
echo %BOX_BL%%BH:~0,58%%BOX_BR%

echo.
echo %C_KEY%%BOX_TL%-- Required Files %BH:~0,44%%BOX_TR%%C_RESET%
set "MISSING="
for %%f in ("run-loop.sh" "auto-prompt.md" "config.json" "PROJECT_SPEC.md" "bootstrap-seed.md" "autofish.js") do (
    if exist "%AUTOFISH_ROOT%%%~f" (
        set "ctext=%CHECK%  %%~f%P60%"
        echo %BOX_VT% %C_RUN%!ctext:~0,57!%C_RESET% %BOX_VT%
    ) else (
        set "ctext=%CROSS%  %%~f%P60%"
        echo %BOX_VT% %C_ERR%!ctext:~0,57!%C_RESET% %BOX_VT%
        set "MISSING=!MISSING! %%~f"
    )
)
echo %BOX_BL%%BH:~0,58%%BOX_BR%
if defined MISSING (
    echo.
    echo %C_ERR%Missing required files:%C_RESET%!MISSING!
    pause
    exit /b 1
)

echo.
echo %C_KEY%%BOX_TL%-- Optional Files %BH:~0,44%%BOX_TR%%C_RESET%
for %%f in ("progress-filter.js" "harness-check.js") do (
    if exist "%AUTOFISH_ROOT%%%~f" (
        set "ctext=%CHECK%  %%~f%P60%"
        echo %BOX_VT% %C_RUN%!ctext:~0,57!%C_RESET% %BOX_VT%
    ) else (
        set "ctext=%WARN_SYM%  %%~f%P60%"
        echo %BOX_VT% %C_WARN%!ctext:~0,57!%C_RESET% %BOX_VT%
    )
)
echo %BOX_BL%%BH:~0,58%%BOX_BR%

echo.
set "AUTOFISH_BASH=%BASH%"
node "%AUTOFISH_ROOT%autofish.js"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo %C_KEY%%BOX_TL%-- Session Ended %BH:~0,44%%BOX_TR%%C_RESET%
set "ctext=Exit code: %EXIT_CODE%%P60%"
echo %BOX_VT% %C_NOTE%!ctext:~0,57!%C_RESET% %BOX_VT%
echo %BOX_BL%%BH:~0,58%%BOX_BR%
echo.
pause
endlocal
exit /b %EXIT_CODE%
