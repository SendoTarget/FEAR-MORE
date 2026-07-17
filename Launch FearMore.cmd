@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\runtime\Start-FearMore.ps1" %*
set "FearMoreExitCode=%ERRORLEVEL%"
if not "%FearMoreExitCode%"=="0" echo FearMore launcher failed with exit code %FearMoreExitCode%.
exit /b %FearMoreExitCode%
