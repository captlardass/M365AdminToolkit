@echo off
rem Double-click installer: installs for the current user (no admin), with Start menu and desktop shortcuts.
rem Bypass applies to this process only: files from a downloaded ZIP are still blocked at this point,
rem and the installer unblocks the installed copy so the shortcuts can run it with RemoteSigned.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Toolkit.ps1" -DesktopShortcut -ShowSummary %*
