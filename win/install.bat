@echo off
REM ===========================================================================
REM  AI-VL - INSTALL  (double-click, once, when switching machines)
REM  Installs Python/Bun/Ollama if missing + deps for the 3 repos + the model.
REM  Auto-elevates to administrator because winget needs it to install.
REM  Does NOT touch git: it respects whatever branches/commits you already chose.
REM ===========================================================================
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permissions...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo   AI-VL : installing dependencies
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "RC=%errorlevel%"

echo.
if %RC% neq 0 (
    echo *** There was an error ^(code %RC%^). Check the messages above. ***
) else (
    echo Done. Now double-click run.bat to start everything.
)
echo.
pause
endlocal
