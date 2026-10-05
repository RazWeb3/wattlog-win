@echo off
rem wattlog one-click launcher (zero-install).
rem Double-click: interactive menu. Or pass args: wattlog.cmd -Mode charge -Duration 10
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0logger.ps1" %*
