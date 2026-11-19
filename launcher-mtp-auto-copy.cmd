@echo off
setlocal
chcp 65001 >nul

fltmc >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

title MTP Auto Copy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0mtp-auto-copy.ps1"
if errorlevel 1 pause
endlocal
