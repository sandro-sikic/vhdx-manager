@echo off
rem Double-click launcher for manager.ps1 (the script asks for admin rights itself).
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%~dp0manager.ps1' -ErrorAction SilentlyContinue"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0manager.ps1"
