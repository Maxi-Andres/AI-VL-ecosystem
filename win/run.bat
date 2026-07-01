@echo off
REM ===========================================================================
REM  AI-VL - RUN  (doble clic)  -  siempre en modo celular (HTTPS)
REM  Levanta iacore (:8001) + backend por HTTPS (:8443) sirviendo el frontend,
REM  con un cert autofirmado, para usar el CELULAR como camara.
REM  Se auto-eleva a administrador para abrir el puerto en el Firewall.
REM  Requiere haber corrido install.bat antes.
REM ===========================================================================
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador ^(para el firewall^)...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo   AI-VL : run (HTTPS para el celular)
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"
set "RC=%errorlevel%"

echo.
if %RC% neq 0 (
    echo *** No se pudo levantar ^(codigo %RC%^). Revisa los mensajes de arriba. ***
    echo     Si faltan dependencias, corre install.bat primero.
)
echo.
pause
endlocal
