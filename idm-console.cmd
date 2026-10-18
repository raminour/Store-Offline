@echo off
setlocal EnableDelayedExpansion
title Store-Offline  -  Microsoft Store apps, offline
set "PS1=%~dp0Store-Offline.ps1"

rem ---- find a Windows PowerShell, and fall back to PowerShell 7 when 5.1 is absent
set "PSEXE="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PSEXE for %%P in (powershell.exe) do if not "%%~$PATH:P"=="" set "PSEXE=%%~$PATH:P"
if not defined PSEXE for %%P in (pwsh.exe) do if not "%%~$PATH:P"=="" set "PSEXE=%%~$PATH:P"

if not defined PSEXE (
  echo.
  echo   No PowerShell was found on this machine.
  echo.
  echo   Windows PowerShell 5.1 ships with Windows 8 and newer. On anything
  echo   older, install Windows Management Framework 5.1 and run this again.
  echo.
  pause
  exit /b 1
)

if not exist "%PS1%" (
  echo.
  echo   Store-Offline.ps1 is missing next to this file.
  echo.
  pause
  exit /b 1
)

rem ---- arguments given: run them straight through, then hold the window open
if not "%~1"=="" (
  "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
  echo.
  pause
  exit /b
)

rem ---- no arguments: ask for the app
echo.
echo   Store-Offline   -   Microsoft Store apps, downloaded offline
echo   ==========================================================
echo.
echo   Paste one of these and press Enter:
echo.
echo     a Store link      https://apps.microsoft.com/detail/9NKSQGP7F2NH
echo     a product id      9NKSQGP7F2NH
echo     a name to search  whatsapp
echo.
set "Q="
set /p "Q=  App: "
if "!Q!"=="" exit /b

set "MODE=-Search"
if "!Q:~0,4!"=="http" set "MODE=-Url"
if "!Q:~0,1!"=="9" if not "!Q:~11,1!"=="" if "!Q:~12,1!"=="" set "MODE=-ProductId"

echo.
echo   Reading Store metadata (nothing is downloaded yet) ...
echo.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" !MODE! "!Q!" -List
if errorlevel 1 (
  echo.
  echo   Stopped.
  echo.
  pause
  exit /b
)

echo.
set "GO="
set /p "GO=  Download this (this machine's architecture, x64 first then x86)? [y/N] "
if /i not "!GO!"=="y" (
  echo.
  echo   Cancelled - nothing was downloaded.
  timeout /t 3 >nul
  exit /b
)

echo.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" !MODE! "!Q!" -Extract -Download
echo.
echo   Files are in %~dp0StoreApps
echo.
pause
