@echo off
title EnvProxy Stop
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0envproxy.ps1" -Stop
echo.
pause
