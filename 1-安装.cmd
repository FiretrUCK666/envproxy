@echo off
title EnvProxy Install
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0envproxy.ps1" -Install
echo.
pause
