@echo off
rem build.cmd - compile Logonoff sans MSYS2 (toolchain de l'installeur Amalgame).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1"
pause
