@echo off
rem Double-click launcher for landing.ps1 (internal side).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\landing.ps1" %*
pause
