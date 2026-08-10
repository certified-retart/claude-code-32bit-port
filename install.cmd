@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ClaudeCode-x86.ps1" -AddToPath
if errorlevel 1 (
  echo.
  echo Installation failed. Review the error above.
  pause
  exit /b 1
)
echo.
echo Installation complete. Open a new Command Prompt and run: claude-x86
pause

