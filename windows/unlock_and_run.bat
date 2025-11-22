@echo off
TITLE EzPartyPH Setup Launcher

:: 1. CHECK ADMIN
net session >nul 2>&1
if %errorLevel% == 0 (
    echo [INFO] Admin privileges detected.
) else (
    echo [ERROR] Please Right-Click this file and 'Run as Administrator'.
    pause
    exit
)

:: 2. SET DIRECTORY TO SCRIPT LOCATION
cd /d "%~dp0"

:: 3. UNLOCK & RUN
:: It asks for permission (Set-ExecutionPolicy).
:: Once you type 'A', it immediately runs 'setup.ps1'.
echo.
echo Launching Setup...
echo.

PowerShell -NoExit -Command "Write-Host 'Requesting Permission Change...' -ForegroundColor Cyan; Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser; Clear-Host; Write-Host 'Permission Granted. Starting Script...' -ForegroundColor Green; & '.\windows_setup.ps1'"