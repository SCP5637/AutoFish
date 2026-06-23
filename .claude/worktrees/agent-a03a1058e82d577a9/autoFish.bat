@echo off
setlocal
call "%~dp0run-auto.bat" %*
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%
