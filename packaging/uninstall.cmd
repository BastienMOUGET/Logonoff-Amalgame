@echo off
rem uninstall.cmd - retire le service Logonoff (a lancer en administrateur).
rem Les donnees (%ProgramData%\Logonoff) sont conservees.
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo Lancez ce script en tant quadministrateur.
  pause
  exit /b 1
)
sc stop Logonoff >nul 2>&1
timeout /t 3 /nobreak >nul
sc delete Logonoff
del "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Logonoff.lnk" >nul 2>&1
del "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Logonoff.url" >nul 2>&1
cd /d "%TEMP%"
rmdir /s /q "%ProgramFiles%\Logonoff"
echo.
echo Logonoff est desinstalle. Les donnees restent dans %ProgramData%\Logonoff
pause
