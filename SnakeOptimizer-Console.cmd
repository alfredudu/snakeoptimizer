@echo off
rem SnakeOptimizer - menu de texto no terminal. Aceita os parametros do script, por exemplo:
rem   SnakeOptimizer-Console.cmd -Action Report -ReportDirectory "D:\Relatorios"
setlocal
rem A pasta de onde o comando foi digitado: um -ReportDirectory relativo vale a partir dela.
set "SNAKEOPTIMIZER_CALLER_DIR=%CD%"
chcp 65001 >nul
cd /d "%~dp0"

rem "-Action Check" (como primeiro argumento) e para tarefas e scripts: nao desbloqueia arquivos, nao pausa e devolve o
rem codigo de saida da verificacao (0 em dia, 1 atencao, 2 critico, 3 nao foi possivel avaliar).
set "SNAKEOPTIMIZER_QUIET="
if /i "%~1"=="-Action" if /i "%~2"=="Check" set "SNAKEOPTIMIZER_QUIET=1"
if /i "%~1"=="-Action:Check" set "SNAKEOPTIMIZER_QUIET=1"

rem Aberto de dentro do zip (o Explorador extrai so este arquivo) ou com a pasta extraida pela metade: avisa e para.
if not exist "%~dp0SnakeOptimizer.Console.ps1" goto faltam
if not exist "%~dp0modules\Modules.psd1" goto faltam

rem Remove a marca de "baixado da internet" dos arquivos extraidos (evita avisos de seguranca).
set "SNAKEOPTIMIZER_ROOT=%~dp0"
if not defined SNAKEOPTIMIZER_QUIET powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:SNAKEOPTIMIZER_ROOT -Recurse -File | Unblock-File" >nul 2>&1

rem O PowerShell de 64 bits: aberto por um programa de 32 bits, o System32 seria trocado pelo SysWOW64 e o
rem PowerShell de 32 bits leria outra parte do registro (inicializacao e ajustes errados). O Sysnative so existe
rem para processos de 32 bits e leva ao System32 de verdade.
set "SNAKEOPTIMIZER_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "SNAKEOPTIMIZER_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

rem SNAKEOPTIMIZER_FROM_CMD: quem pausa no fim, quando algo da errado, e este arquivo (o script nao pausa de novo).
set "SNAKEOPTIMIZER_FROM_CMD=1"
"%SNAKEOPTIMIZER_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0SnakeOptimizer.Console.ps1" %*

set "EXIT_CODE=%ERRORLEVEL%"

if defined SNAKEOPTIMIZER_QUIET (
    endlocal & exit /b %EXIT_CODE%
)

if not "%EXIT_CODE%"=="0" (
    echo.
    echo   O SnakeOptimizer terminou com o codigo %EXIT_CODE%: a mensagem acima diz o motivo.
    pause
)

rem "endlocal & exit" na mesma linha: o valor e lido antes de a variavel ser descartada.
endlocal & exit /b %EXIT_CODE%

:faltam
echo.
echo   Faltam arquivos do SnakeOptimizer nesta pasta.
echo.
echo   Abra o SnakeOptimizer.zip, clique em "Extrair tudo" e depois abra
echo   o SnakeOptimizer-Console.cmd que estiver na pasta nova.
echo.
rem Numa tarefa ou script (-Action Check), sem pausa: o codigo 3 e "nao foi possivel avaliar".
if defined SNAKEOPTIMIZER_QUIET (
    endlocal & exit /b 3
)
pause
endlocal & exit /b 1
