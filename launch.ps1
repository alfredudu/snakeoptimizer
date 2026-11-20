#requires -Version 5.1
<#
.SYNOPSIS
    SnakeOptimizer - launcher remoto. Baixa (ou atualiza) o SnakeOptimizer e abre a interface ou roda uma acao.

.DESCRIPTION
    Feito para ser chamado direto da internet, sem instalar nada antes:

        irm https://raw.githubusercontent.com/alfredudu/snakeoptimizer/main/launch.ps1 | iex

    Com parametros (abrir ja numa otimizacao especifica, rodar so a checagem etc.):

        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/alfredudu/snakeoptimizer/main/launch.ps1))) -Action performance.boost

    Ou, mantendo o "irm | iex", por variaveis de ambiente (util em RMM que so aceita uma linha):

        $env:SO_ACTION = 'cleanup.quick'; irm <url>/launch.ps1 | iex

    O pacote fica em %ProgramData%\SnakeOptimizer\app (ou %LOCALAPPDATA% sem Administrador) e e baixado de novo a cada
    execucao (use -NoUpdate para reaproveitar a copia local).

.PARAMETER Mode
    Gui     - abre a janela (padrao).
    Console - abre o menu de texto no terminal atual.
    Check   - verificacao rapida, so leitura. Codigo de saida: 0 ok, 1 atencao, 2 critico, 3 nao avaliado. Ideal p/ RMM.
    Report  - gera o relatorio HTML/TXT (em -ReportDirectory, ou %ProgramData%\SnakeOptimizer\reports).
    Run     - modo silencioso para RMM: roda as tarefas de -Task sem perguntar nada. Exige Administrador/SYSTEM.
              Codigo de saida: 0 ok, 1 alertas, 2 falha, 3 sem Administrador, 4 tarefa desconhecida.

.PARAMETER Task
    So no modo Run: tarefas separadas por virgula. ponto-restauracao, limpeza-rapida, winsxs, dism, sfc, dism-sfc,
    atualizacoes, fila-impressao, hora, dns, rede, verificar. Ex.: $env:SO_MODE='Run'; $env:SO_TASK='limpeza-rapida,dns'; irm <url> | iex

.PARAMETER Action
    So no modo Gui: o item que a janela executa ao abrir. Exemplos: maintenance.recommended, performance.boost,
    cleanup.quick, repair.dism-sfc, network.repair, updates.winget. Lista completa: -ListActions.

.PARAMETER Page
    So no modo Gui: pagina inicial (home, maintenance, diagnostics, security, cleanup, performance, repair, updates,
    software, network, tweaks, personalize, app).

.PARAMETER InUserSession
    Para RMM que roda como SYSTEM (sessao 0, sem tela): abre a janela na sessao do usuario logado, via tarefa agendada
    temporaria. E ativado sozinho quando o launcher percebe que esta como SYSTEM no modo Gui.

.PARAMETER Json
    So no modo Check: saida em JSON.

.PARAMETER Source
    URL do .zip do SnakeOptimizer. Padrao: o zip da branch principal do repositorio no GitHub.

.PARAMETER Sha256
    Hash SHA-256 esperado do .zip. Se informado e nao bater, nada e executado.
#>
[CmdletBinding()]
param (
    [ValidateSet("Gui", "Console", "Check", "Report", "Run")]
    [string]$Mode = $(if ($env:SO_MODE) { $env:SO_MODE } else { "Gui" }),

    [string]$Action = $env:SO_ACTION,

    [string]$Task = $env:SO_TASK,

    [string]$Page = $env:SO_PAGE,

    [switch]$InUserSession,

    [switch]$Json,

    [string]$ReportDirectory,

    [string]$Source = $env:SO_SOURCE,

    [string]$Sha256 = $env:SO_SHA256,

    [switch]$NoUpdate,

    [switch]$ListActions
)

# ---------------------------------------------------------------------------------------------------------------------
# Configuracao: ajuste aqui para o seu repositorio (ou servidor proprio).
# ---------------------------------------------------------------------------------------------------------------------
$Repository = "alfredudu/snakeoptimizer"
$Branch = "main"
$AppName = "SnakeOptimizer"

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # a barra de progresso deixa o Invoke-WebRequest do PS 5.1 muito lento

function Write-Step([string]$Text, [string]$Color = "Cyan") { Write-Host "[$AppName] $Text" -ForegroundColor $Color }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsSystem {
    return ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18")
}

function Get-WindowsPowerShellPath {
    # Sempre o Windows PowerShell 5.1 de 64 bits: muitos agentes de RMM sao de 32 bits, e o PowerShell de 32 bits leria
    # outra parte do registro. O Sysnative so existe para processos de 32 bits e leva ao System32 de verdade.
    $sysnative = Join-Path $env:SystemRoot "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $sysnative) { return $sysnative }
    return (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
}

function Get-InstallRoot {
    if (Test-IsAdmin) { return (Join-Path $env:ProgramData $AppName) }
    return (Join-Path $env:LOCALAPPDATA $AppName)
}

function Protect-InstallRoot {
    # %ProgramData% deixa qualquer usuario criar e alterar arquivos nas pastas novas. Como a manutencao automatica roda
    # o que esta aqui como SYSTEM, a pasta fica so com Administradores e SYSTEM alterando; os usuarios so leem.
    param ([string]$Root)

    if (-not (Test-IsAdmin) -or $Root -notlike "$env:ProgramData*") { return }

    try {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
        $none = [System.Security.AccessControl.PropagationFlags]::None
        foreach ($sid in "S-1-5-18", "S-1-5-32-544") {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($sid)), "FullControl", $inherit, $none, "Allow")))
        }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545")), "ReadAndExecute", $inherit, $none, "Allow")))
        Set-Acl -LiteralPath $Root -AclObject $acl
    }
    catch {
        Write-Step "Nao foi possivel proteger a pasta $Root ($($_.Exception.Message))." Yellow
    }
}

function Install-App {
    param ([string]$Root)

    $appDir = Join-Path $Root "app"
    $gui = Join-Path $appDir "$AppName.Gui.ps1"

    if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    Protect-InstallRoot -Root $Root

    if ($NoUpdate -and (Test-Path -LiteralPath $gui)) {
        Write-Step "Usando a copia local em $appDir"
        return $appDir
    }

    $src = $Source
    if ([string]::IsNullOrWhiteSpace($src)) {
        if ($Repository -like "CONFIGURE_*") {
            throw "Configure a variavel `$Repository no launch.ps1 (ou passe -Source <url do zip>)."
        }
        $src = "https://github.com/$Repository/archive/refs/heads/$Branch.zip"
    }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $stage = Join-Path ([IO.Path]::GetTempPath()) "$AppName-$([guid]::NewGuid().ToString('N'))"
    $zip = "$stage.zip"
    $keepStage = $false

    try {
        Write-Step "Baixando $src"
        try {
            Invoke-WebRequest -Uri $src -OutFile $zip -UseBasicParsing
        }
        catch {
            # Sem internet (ou GitHub fora do ar): a copia que ja esta no PC serve.
            if (Test-Path -LiteralPath $gui) {
                Write-Step "Nao foi possivel baixar ($($_.Exception.Message)); usando a copia local." Yellow
                return $appDir
            }
            throw
        }

        if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
            $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            if ($hash -ne $Sha256.Trim().ToUpperInvariant()) {
                throw "SHA-256 nao confere (esperado $Sha256, recebido $hash). Nada foi executado."
            }
            Write-Step "SHA-256 conferido." Green
        }

        Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force

        # O zip da branch vem com uma pasta "repo-branch\"; o de release pode vir sem. Procura onde esta o script da janela.
        $found = Get-ChildItem -LiteralPath $stage -Recurse -Filter "$AppName.Gui.ps1" | Select-Object -First 1
        if (-not $found) { throw "O pacote baixado nao contem $AppName.Gui.ps1." }
        $payload = $found.DirectoryName

        Get-ChildItem -LiteralPath $payload -Recurse -File | Unblock-File

        if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }

        if (Test-Path -LiteralPath $appDir) {
            try { Remove-Item -LiteralPath $appDir -Recurse -Force }
            catch {
                # Uma janela aberta ainda usa a pasta: roda desta copia nova, sem mexer na antiga.
                Write-Step "Versao anterior em uso; executando a partir da copia temporaria." Yellow
                $keepStage = $true
                return $payload
            }
        }

        Move-Item -LiteralPath $payload -Destination $appDir
        return $appDir
    }
    finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (-not $keepStage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-GuiArguments {
    param ([string]$AppDir)

    $guiArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Join-Path $AppDir "$AppName.Gui.ps1")`""
    if ($Page -match '^[a-z]+$') { $guiArgs += " -Page $Page" }
    if ($Action) {
        if ($Action -notmatch '^[a-z0-9][a-z0-9.-]*$') { throw "Acao invalida: '$Action'. Use -ListActions para ver as opcoes." }
        $guiArgs += " -Action $Action"
    }
    return $guiArgs
}

function Start-GuiInUserSession {
    # SYSTEM nao tem area de trabalho visivel. Uma tarefa agendada com o token interativo do usuario logado abre a janela
    # na tela dele (o tecnico ve pelo acesso remoto). RunLevel Highest: se o usuario for administrador, abre elevada.
    param ([string]$AppDir)

    $user = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if (-not $user) {
        # Sessoes RDP nao aparecem em Win32_ComputerSystem: pega o dono do explorer.exe.
        $explorer = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
        if ($explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            if ($owner.User) { $user = "$($owner.Domain)\$($owner.User)" }
        }
    }
    if (-not $user) { throw "Nenhum usuario logado para mostrar a janela. Use -Mode Check ou -Mode Report." }

    $taskName = "$AppName-Launch-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $taskAction = New-ScheduledTaskAction -Execute (Get-WindowsPowerShellPath) -Argument (Get-GuiArguments -AppDir $AppDir)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 5
        Write-Step "Janela aberta na sessao de $user." Green
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------------------------------
try {
    $root = Get-InstallRoot
    $appDir = Install-App -Root $root
    $ps = Get-WindowsPowerShellPath

    if ($ListActions) {
        $nav = Get-Content -LiteralPath (Join-Path $appDir "modules\Navigation.psm1") -Raw -Encoding UTF8
        [regex]::Matches($nav, '-Id "([a-z0-9.-]+)" -Label "([^"]+)"') | ForEach-Object {
            [PSCustomObject]@{ Action = $_.Groups[1].Value; Descricao = $_.Groups[2].Value }
        } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        return
    }

    switch ($Mode) {
        "Gui" {
            if ($InUserSession -or (Test-IsSystem)) {
                Start-GuiInUserSession -AppDir $appDir
            }
            else {
                # A janela se reabre sozinha como Administrador (aviso do UAC) quando necessario.
                Start-Process -FilePath $ps -ArgumentList (Get-GuiArguments -AppDir $appDir) -WindowStyle Hidden
                Write-Step "Abrindo a janela..." Green
            }
        }
        "Console" {
            & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appDir "$AppName.Console.ps1")
        }
        "Check" {
            $checkArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $appDir "$AppName.Console.ps1"), "-Action", "Check")
            if ($Json) { $checkArgs += "-Json" }
            & $ps @checkArgs
            $global:LASTEXITCODE = $LASTEXITCODE
            # Rodando como arquivo (powershell -File launch.ps1), devolve o codigo ao RMM. Via "irm | iex" nao sai, para
            # nao fechar o terminal do tecnico: use "...| iex; exit $LASTEXITCODE".
            if ($PSCommandPath) { exit $global:LASTEXITCODE }
        }
        "Run" {
            # -NonInteractive: se alguma acao tentar perguntar algo, falha na hora em vez de ficar esperando para sempre.
            $runArgs = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $appDir "$AppName.Console.ps1"), "-Action", "Run")
            if ($Task) { $runArgs += @("-Task", $Task) }
            & $ps @runArgs
            $global:LASTEXITCODE = $LASTEXITCODE
            if ($PSCommandPath) { exit $global:LASTEXITCODE }
        }
        "Report" {
            if ([string]::IsNullOrWhiteSpace($ReportDirectory)) { $ReportDirectory = Join-Path $root "reports" }
            & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appDir "$AppName.Console.ps1") -Action Report -ReportDirectory $ReportDirectory
            Write-Step "Relatorios em $ReportDirectory" Green
        }
    }
}
catch {
    Write-Step "Falhou: $($_.Exception.Message)" Red
    $global:LASTEXITCODE = 1
}
finally {
    Remove-Item Env:SO_ACTION, Env:SO_MODE, Env:SO_PAGE, Env:SO_SOURCE, Env:SO_SHA256, Env:SO_TASK -ErrorAction SilentlyContinue
}
