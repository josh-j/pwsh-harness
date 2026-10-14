@echo off
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo Install PowerShell 7.6 or newer, then open a new terminal. 1>&2
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -File "%~dp0pwsh-harness.ps1" %*
exit /b %errorlevel%
