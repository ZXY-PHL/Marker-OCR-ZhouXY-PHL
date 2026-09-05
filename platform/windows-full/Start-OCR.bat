@echo off
set "BUNDLE=%~dp0"
"%BUNDLE%runtime\pwsh\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BUNDLE%Start-OCR.ps1" %*
if errorlevel 1 pause
