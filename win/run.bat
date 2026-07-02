@echo off
REM ===========================================================================
REM  AI-VL - RUN  (double-click)  -  always in phone mode (HTTPS)
REM  Starts iacore (:8001) + backend over HTTPS (:8443) serving the frontend,
REM  with a self-signed cert, to use the PHONE as the camera.
REM  Auto-elevates to administrator to open the port in the Firewall.
REM  Requires install.bat to have been run first.
REM ===========================================================================
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permissions ^(for the firewall^)...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo   AI-VL : run (HTTPS for the phone)
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"
set "RC=%errorlevel%"

echo.
if %RC% neq 0 (
    echo *** Could not start ^(code %RC%^). Check the messages above. ***
    echo     If dependencies are missing, run install.bat first.
)
echo.
pause
endlocal
