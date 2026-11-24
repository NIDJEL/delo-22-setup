@echo off
setlocal
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules;%ProgramFiles%\WindowsPowerShell\Modules"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Install-Delo.ps1" %*
set "SetupExit=%ERRORLEVEL%"
exit /b %SetupExit%
