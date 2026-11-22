@echo off
rem Double-click entry for the interactive menu (menu.ps1). Kept ASCII-only.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0menu.ps1"
if errorlevel 1 pause
