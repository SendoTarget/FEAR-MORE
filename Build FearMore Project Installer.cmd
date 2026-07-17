@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\public\Build-FearMorePublicProject.ps1" %*
set "FearMoreExitCode=%ERRORLEVEL%"
if "%FearMoreExitCode%"=="0" exit /b 0
echo.
echo FearMore could not build the Project Installer.
echo The error above lists the missing or changed local prerequisite.
echo See docs\project-installer.md for the complete builder checklist.
pause
exit /b %FearMoreExitCode%
