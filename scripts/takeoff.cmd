@echo off
rem Double-click launcher for takeoff.ps1 (external side).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0takeoff.ps1" %*
pause
