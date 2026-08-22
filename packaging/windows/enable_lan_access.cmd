@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable_lan_access.ps1"
if errorlevel 1 (
  echo Failed to enable LAN access.
) else (
  echo LAN access is enabled.
)
pause
