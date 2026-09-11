@echo off
title EnvProxy Uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0envproxy.ps1" -Uninstall
echo.
pause
