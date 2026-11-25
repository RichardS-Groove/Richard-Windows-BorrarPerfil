@echo off
setlocal
chcp 65001 >nul
title Borrar perfil de Windows

rem --- Pedir permisos de administrador si no los tiene
net session >nul 2>&1
if errorlevel 1 (
  echo Pidiendo permisos de administrador...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0borrar-perfil.ps1""

echo ================================================================
echo   BORRAR UN PERFIL DE WINDOWS POR COMPLETO
echo   Paso 1: escanea (no toca nada) y arma el checklist
echo   Paso 2: si confirmas, borra todo y vuelve a escanear
echo ================================================================
echo.
echo Perfiles de esta PC:
powershell -NoProfile -Command "Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | ForEach-Object { '   {0,-28} en uso: {1}' -f (Split-Path $_.LocalPath -Leaf), $_.Loaded }"
echo.
set /p "USUARIO=Nombre del usuario a borrar (tal cual aparece arriba): "
if "%USUARIO%"=="" goto fin

echo.
echo ---------------- PASO 1: ESCANEO ----------------
%PS% -Usuario "%USUARIO%" -Modo Escanear
if errorlevel 1 goto fin

echo.
echo Abro el checklist en el Bloc de notas para que lo revises...
for /f "delims=" %%D in ('dir /b /ad /o-d "%~dp0informes" 2^>nul') do (
  start "" notepad "%~dp0informes\%%D\checklist.md"
  goto :abierto
)
:abierto
echo.
set /p "SEGUIR=Queres BORRAR todo esto? (S/N): "
if /i not "%SEGUIR%"=="S" goto fin
set /p "CUENTA=Borrar tambien la CUENTA de usuario (S/N): "
set "EXTRA="
if /i "%CUENTA%"=="S" set "EXTRA=-BorrarCuenta"

echo.
echo ---------------- PASO 2: BORRADO ----------------
%PS% -Usuario "%USUARIO%" -Modo Borrar %EXTRA%

:fin
echo.
pause
