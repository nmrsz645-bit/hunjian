@echo off
chcp 65001 >nul
pushd "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CD%\Start-AutoCut.ps1"
popd
echo.
echo Done. Press any key to close.
pause >nul
