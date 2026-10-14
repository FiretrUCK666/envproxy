@echo off
title EnvProxy Menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0envproxy.ps1" -Menu
echo.
pause
