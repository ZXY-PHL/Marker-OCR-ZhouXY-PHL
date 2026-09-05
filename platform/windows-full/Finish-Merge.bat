@echo off
set "BUNDLE=%~dp0"
"%BUNDLE%runtime\pwsh\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BUNDLE%Finish-Merge.ps1" %*
if errorlevel 1 pause
