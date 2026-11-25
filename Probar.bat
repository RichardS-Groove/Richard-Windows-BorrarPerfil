@echo off
rem Prueba completa con un usuario de prueba (zzPruebaBorrado). No toca usuarios reales.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prueba-completa.ps1"
pause
