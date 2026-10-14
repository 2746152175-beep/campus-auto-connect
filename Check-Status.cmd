@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0campus-login.ps1" -Mode Status
pause
