@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\runtime\Verify-FearMoreLauncherPackage.ps1" -PackageRoot "%~dp0."
set "FearMoreExitCode=%ERRORLEVEL%"
if "%FearMoreExitCode%"=="0" (
  echo.
  echo FearMore package verification passed.
  if not defined FEARMORE_NO_PAUSE pause
  exit /b 0
)
echo.
echo FearMore package verification failed. Do not launch this copy until the reported file is restored.
if not defined FEARMORE_NO_PAUSE pause
exit /b %FearMoreExitCode%
