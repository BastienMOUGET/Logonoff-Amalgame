@echo off
rem msi.cmd - construit dist-msi\Logonoff-<version>.msi a partir de dist\ (lancer build.cmd avant).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0packaging\build-msi.ps1"
pause
