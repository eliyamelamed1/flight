@echo off
rem Double-click launcher for landing.ps1 (internal side).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0landing.ps1" %*
pause
