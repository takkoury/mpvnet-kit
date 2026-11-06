@echo off
setlocal
set "KIT_INSTALLER=%~dp0tools\installer.ps1"
if not exist "%KIT_INSTALLER%" goto missing
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%KIT_INSTALLER%"
if errorlevel 1 goto failed
exit /b 0

:missing
call :use-utf8
echo 找不到安装程序。请解压完整的安装包，然后重试。
goto wait-and-exit

:failed
call :use-utf8
echo 安装程序未能启动或运行出错。请将完整安装包解压到可读取的文件夹后重试。

:wait-and-exit
if defined KIT_ORIGINAL_CODE_PAGE chcp %KIT_ORIGINAL_CODE_PAGE% >nul
pause
exit /b 1

:use-utf8
rem Keep each UTF-8 message on one command line for the cmd batch reader.
set "KIT_ORIGINAL_CODE_PAGE="
for /f "tokens=2 delims=:" %%C in ('chcp') do set "KIT_ORIGINAL_CODE_PAGE=%%C"
if defined KIT_ORIGINAL_CODE_PAGE chcp 65001 >nul
exit /b 0
