@echo off
setlocal
if exist "%~dp0Delo-Setup.exe" (
    "%~dp0Delo-Setup.exe" %*
    exit /b
)
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules;%ProgramFiles%\WindowsPowerShell\Modules"
if "%~1"=="" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Install-Delo.ps1" -Menu
    exit /b
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Install-Delo.ps1" %*
set "SetupExit=%ERRORLEVEL%"
exit /b %SetupExit%
