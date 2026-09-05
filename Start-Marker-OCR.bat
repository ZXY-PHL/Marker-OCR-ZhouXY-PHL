@echo off
setlocal
set "ROOT=%~dp0"
set "PYTHON=%ROOT%..\Marker-OCR-Portable\runtime\python\python.exe"
if not exist "%PYTHON%" set "PYTHON=python"
"%PYTHON%" "%ROOT%app\marker_ocr.py" %*
exit /b %errorlevel%
