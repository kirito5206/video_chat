@echo off
REM One-click launcher wrapper. Avoids PowerShell execution-policy blocking.
powershell -ExecutionPolicy Bypass -File "%~dp0start.ps1"
