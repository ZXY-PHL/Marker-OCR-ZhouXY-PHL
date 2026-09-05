@echo off
set "BUNDLE=%~dp0"
"%BUNDLE%runtime\pwsh\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BUNDLE%Check-Environment.ps1"
pause
