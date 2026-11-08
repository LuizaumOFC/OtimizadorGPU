@echo off
title Otimizador GPU e Windows
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('%~dp0OtimizadorGPU.ps1',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object{Write-Host ('Linha '+$_.Extent.StartLineNumber+': '+$_.Message)};exit 1}"
if errorlevel 1 (
  echo.
  echo O script tem erro de sintaxe. Envie as linhas acima para mim.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0OtimizadorGPU.ps1"
exit