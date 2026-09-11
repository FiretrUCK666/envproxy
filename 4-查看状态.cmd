@echo off
title EnvProxy Status
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0envproxy.ps1" -Status
echo.
pause
