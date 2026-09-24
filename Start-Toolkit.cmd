@echo off
rem Double-click launcher. RemoteSigned applies to this process only.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Minimized -File "%~dp0Start-Toolkit.ps1"
