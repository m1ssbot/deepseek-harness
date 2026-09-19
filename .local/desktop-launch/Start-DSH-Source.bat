@echo off
chcp 65001 >nul
title DeepSeek Harness (source)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-dsh-source.ps1"
set EXITCODE=%ERRORLEVEL%
if not "%EXITCODE%"=="0" (
  echo.
  echo Process exited with code %EXITCODE%.
  pause
)
exit /b %EXITCODE%
