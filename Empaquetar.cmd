@echo off
rem Lanza el empaquetador con interfaz. Doble clic y listo; no instala nada.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Empaquetar.ps1"
