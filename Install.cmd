@echo off
setlocal
set "KIT_INSTALLER=%~dp0tools\installer.ps1"
if not exist "%KIT_INSTALLER%" goto missing
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%KIT_INSTALLER%"
if errorlevel 1 goto failed
exit /b 0
:missing
echo The installer is missing. Extract the complete package and try again.
pause
exit /b 1
:failed
echo The installer could not start or closed with an error.
echo Extract the complete package into a readable folder and try again.
pause
exit /b 1
