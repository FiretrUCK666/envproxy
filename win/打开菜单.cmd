@echo off
title EnvProxy Menu
rem Do NOT use %~dp0 here.
rem
rem Measured: in a folder whose name contains & , = ( ; the expansion of %~dp0 is
rem already broken before any quoting can help - it splits at that character, so
rem the shell reports "'D:\R&D\EnvProxy' is not recognized" and the menu never
rem starts. envproxy.ps1 itself runs fine from that same folder, so the only thing
rem broken is this wrapper. That contradicts the promise that the whole folder can
rem be moved or renamed freely.
rem
rem %CD% is the process working directory. On a double-click Windows sets it to
rem the script's own folder, so it is the same information without going through
rem the argument-expansion path. When it does not point at envproxy.ps1 (the user
rem started this from elsewhere) fall back to a plain notification instead of
rem guessing - a wrong guess would run some other copy's menu.
if exist "%CD%\envproxy.ps1" goto run
echo.
echo   Please double-click this file from inside the EnvProxy folder.
echo   This window could not locate envproxy.ps1 next to it.
echo.
pause
exit /b 1

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "envproxy.ps1" -Menu
echo.
pause