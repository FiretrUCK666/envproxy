@echo off
title EnvProxy Update
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0envproxy.ps1" -Update
echo.
pause
