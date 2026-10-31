@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0OneClick-Paraformer-EmptySpeechRepair.ps1"
set "REPAIR_EXIT=%ERRORLEVEL%"
if not "%REPAIR_EXIT%"=="0" (
  echo.
  echo Repair did not complete. Read the message above and try again.
  pause
)
exit /b %REPAIR_EXIT%
