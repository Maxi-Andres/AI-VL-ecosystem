@echo off
REM ===========================================================================
REM  AI-VL - INSTALAR  (doble clic, una vez, al cambiar de compu)
REM  Instala Python/Bun/Ollama si faltan + dependencias de los 3 repos + modelo.
REM  Se auto-eleva a administrador porque winget lo necesita para instalar.
REM  NO toca git: respeta las ramas/commits que ya elegiste.
REM ===========================================================================
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo   AI-VL : instalando dependencias
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "RC=%errorlevel%"

echo.
if %RC% neq 0 (
    echo *** Hubo un error ^(codigo %RC%^). Revisa los mensajes de arriba. ***
) else (
    echo Listo. Ahora hace doble clic en start.bat para prender todo.
)
echo.
pause
endlocal
