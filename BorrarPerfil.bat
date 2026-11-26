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

rem --- Menu interactivo numerado de perfiles
set "TEMP_USER=%TEMP%\perfil_elegido_%RANDOM%.txt"
if exist "%TEMP_USER%" del "%TEMP_USER%" 2>nul

powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $perfiles = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | ForEach-Object { Split-Path $_.LocalPath -Leaf } | Where-Object { $_ -notin @('Administrador', 'Administrator', 'Public', 'Default', 'Todos', 'All Users') }); if ($perfiles.Count -eq 0) { Write-Host 'No se encontraron perfiles para borrar.' -ForegroundColor Yellow; exit 0 }; Write-Host ''; Write-Host 'Perfiles disponibles en este equipo:' -ForegroundColor Cyan; for ($i = 0; $i -lt $perfiles.Count; $i++) { $p = $perfiles[$i]; $wmi = Get-CimInstance Win32_UserProfile | Where-Object { (Split-Path $_.LocalPath -Leaf) -ieq $p } | Select-Object -First 1; $enUso = if ($wmi -and $wmi.Loaded) { 'SÍ (en uso)' } else { 'No' }; Write-Host ('  [{0}] {1,-26} (en uso: {2})' -f ($i + 1), $p, $enUso) }; Write-Host '  [0] Salir sin hacer nada'; Write-Host ''; while ($true) { $sel = Read-Host 'Elegí el número del perfil a borrar'; if ($sel -eq '0') { exit 0 }; if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $perfiles.Count) { $elegido = $perfiles[[int]$sel - 1]; [IO.File]::WriteAllText('%TEMP_USER%', $elegido); break }; Write-Host 'Opción no válida, intentá de nuevo.' -ForegroundColor Red } }"

if not exist "%TEMP_USER%" goto fin
set /p "USUARIO="<"%TEMP_USER%"
del "%TEMP_USER%" 2>nul
if "%USUARIO%"=="" goto fin

echo.
echo ================================================================
echo   Perfil seleccionado: %USUARIO%
echo ================================================================

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