@echo off
rem install.cmd - installe ou met a jour Logonoff (a lancer en administrateur,
rem depuis le dossier dist\ produit par build.cmd / build.sh).
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo [ERREUR] Lancez ce script en tant quadministrateur ^(clic droit, Executer en tant quadministrateur^).
  pause
  exit /b 1
)
if not exist "%~dp0logonoff.exe" (
  echo [ERREUR] logonoff.exe absent de %~dp0
  echo Recompilez ^(build.cmd^) et verifiez que lantivirus ne la pas mis en quarantaine.
  pause
  exit /b 1
)
set "DEST=%ProgramFiles%\Logonoff"

sc query Logonoff >nul 2>&1
if not errorlevel 1 (
  echo Arret du service existant...
  sc stop Logonoff >nul 2>&1
  timeout /t 3 /nobreak >nul
  taskkill /im logonoff.exe /f >nul 2>&1
)

echo Copie vers %DEST% ...
if not exist "%DEST%" mkdir "%DEST%"
xcopy /E /I /Y /Q "%~dp0*" "%DEST%\" >nul
if errorlevel 1 (
  echo [ERREUR] Echec de la copie vers %DEST%.
  pause
  exit /b 1
)
if not exist "%DEST%\logonoff.exe" (
  echo [ERREUR] logonoff.exe na pas ete copie ^(antivirus ?^).
  pause
  exit /b 1
)

sc query Logonoff >nul 2>&1
if errorlevel 1 (
  echo Creation du service...
  sc create Logonoff binPath= "\"%DEST%\logonoff.exe\" --service" start= auto DisplayName= "Logonoff"
  if errorlevel 1 (
    echo [ERREUR] Creation du service impossible.
    pause
    exit /b 1
  )
) else (
  rem Un service "Logonoff" existe deja (eventuellement l'ancienne version C#) :
  rem on le repointe sur le nouvel executable.
  echo Mise a jour du service existant...
  sc config Logonoff binPath= "\"%DEST%\logonoff.exe\" --service" start= auto DisplayName= "Logonoff"
  if errorlevel 1 (
    echo [ERREUR] Mise a jour du service impossible.
    pause
    exit /b 1
  )
)
sc description Logonoff "Temps de presence (ouverture, verrouillage de session) et temps par projet. Interface : http://127.0.0.1:8765" >nul
rem Redemarre automatiquement en cas de plantage.
sc failure Logonoff reset= 86400 actions= restart/5000/restart/5000/restart/60000 >nul
echo Demarrage du service...
sc start Logonoff
if errorlevel 1 echo [ATTENTION] Le service na pas demarre : voir ci-dessus et lObservateur devenements.

rem Raccourci du menu Demarrer (pour tous les utilisateurs) vers linterface.
(
  echo [InternetShortcut]
  echo URL=http://127.0.0.1:8765/
  echo IconFile=%DEST%\logonoff.ico
  echo IconIndex=0
) > "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Logonoff.url"
del "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Logonoff.lnk" >nul 2>&1

echo.
sc query Logonoff | findstr /i "STATE ETAT"
sc qc Logonoff | findstr /i "BINARY_PATH_NAME"
echo Interface : http://127.0.0.1:8765  (menu Demarrer ^> Logonoff)
echo Donnees    : %ProgramData%\Logonoff\logonoff.db
pause
