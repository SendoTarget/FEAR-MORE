@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\runtime\Start-FearMore.ps1" %*
set "FearMoreExitCode=%ERRORLEVEL%"
if "%FearMoreExitCode%"=="0" exit /b 0
echo.
echo FearMore could not start. The error above identifies the missing or changed prerequisite.
echo See docs\playable-build.md in this folder for owner setup and recovery steps.
if not defined FEARMORE_NO_PAUSE pause
exit /b %FearMoreExitCode%
