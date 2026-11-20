@echo off
rem SnakeOptimizer (Snake Tech) - abre sempre a versao mais nova, ja como Administrador.
rem Copie este arquivo para a Area de Trabalho, um pendrive ou a pasta de ferramentas: ele nao precisa do resto da pasta.
rem Cada vez que abre, baixa o SnakeOptimizer atualizado do GitHub (alfredudu/snakeoptimizer) e abre a janela.
setlocal

rem Sem Administrador: pede a permissao (aviso do Windows) e reabre este mesmo arquivo elevado.
net session >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ComSpec -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs" >nul 2>&1
    exit /b 0
)

rem O PowerShell de 64 bits mesmo quando aberto por um programa de 32 bits.
set "SO_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "SO_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

echo Abrindo o SnakeOptimizer (baixando a versao mais nova)...
"%SO_PS%" -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; irm https://raw.githubusercontent.com/alfredudu/snakeoptimizer/main/launch.ps1 | iex"
if errorlevel 1 (
    echo.
    echo Nao foi possivel abrir o SnakeOptimizer. Confira a internet e tente de novo.
    pause
)

endlocal
exit /b 0
