@echo off
setlocal
set "GUI=%~dp0Store-Gui.ps1"
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

rem ---- arguments given: hand them straight to the console version
if not "%~1"=="" (
  "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
  echo.
  pause
  exit /b
)

rem ---- the window is WPF, which a Server Core install does not have. Asking
rem      PowerShell costs a second of black console on screen before the window
rem      appears, so this just looks for the framework files (instant).
if not exist "%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\WPF\PresentationFramework.dll" if not exist "%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\WPF\PresentationFramework.dll" goto consoleonly
if not exist "%GUI%" goto consoleonly

rem ---- open the window. -WindowStyle Hidden is not enough on Windows 11: the
rem      console is hosted by Windows Terminal, which shows it anyway and leaves
rem      the black box on screen behind the window for the whole session. Windows
rem      10 1809 and newer can start a program with no console at all instead
rem      (conhost --headless), which is what the window uses there.
set "WCONHOST="
set "WBUILD="
for /f "tokens=3" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul') do set "WBUILD=%%a"
if defined WBUILD if %WBUILD% GEQ 17763 if exist "%SystemRoot%\System32\conhost.exe" set "WCONHOST=%SystemRoot%\System32\conhost.exe"

if defined WCONHOST (
  start "" "%WCONHOST%" --headless "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%GUI%"
) else (
  start "" "%PSEXE%" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%GUI%"
)
exit /b 0

:consoleonly
echo.
echo   This Windows cannot open the window (no WPF), so the console version
echo   is starting instead. Downloading works exactly the same.
echo.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
echo.
pause
exit /b 0
