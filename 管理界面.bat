@echo off
chcp 65001 >nul
pushd "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CD%\AutoCut-Manager.ps1"
popd
