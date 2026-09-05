@echo off
setlocal
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0invoke-marker-ocr.ps1" %*
exit /b %ERRORLEVEL%
