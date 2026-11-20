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
    Install   - instala no PC: copia fixa em %ProgramData%\SnakeOptimizer, tarefa "Atualizador" (SYSTEM, ao ligar o PC e a
                cada 6 horas: baixa a versao nova sozinha) e atalhos na Area de Trabalho publica e no Menu Iniciar.
    Update    - o que o Atualizador roda: so baixa se houver commit novo; com o SnakeOptimizer aberto, deixa para depois.
    Uninstall - remove o Atualizador, a manutencao automatica, os atalhos e a copia instalada (relatorios e historico ficam).

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
    [ValidateSet("Gui", "Console", "Check", "Report", "Run", "Install", "Update", "Uninstall")]
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

$TaskPath = "\SnakeOptimizer\"
$UpdaterTask = "Atualizador"
# O que a ultima instalacao fez (Updated, UpToDate, InUse, Offline, Local) e o commit publicado.
$UpdateInfo = @{ Outcome = ""; Commit = $null; AgentsStopped = $false; AgentRestarted = $false }

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
    # Sem Administrador num PC com o SnakeOptimizer instalado: usa a copia instalada (o Atualizador a mantem em dia).
    $machine = Join-Path $env:ProgramData $AppName
    if (Test-Path -LiteralPath (Join-Path $machine "app\$AppName.Gui.ps1")) { return $machine }
    return (Join-Path $env:LOCALAPPDATA $AppName)
}

function Get-RemoteCommit {
    # O ultimo commit publicado na branch (uma consulta leve a API do GitHub). $null sem internet ou com o limite estourado.
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/commits/$Branch" -UseBasicParsing -TimeoutSec 15 `
            -Headers @{ "User-Agent" = "$AppName-launcher"; "Accept" = "application/vnd.github+json" }
        if (-not $r.sha) { return $null }
        return [PSCustomObject]@{
            Sha     = [string]$r.sha
            Date    = [string]$r.commit.committer.date
            Message = (([string]$r.commit.message) -split "`n")[0].Trim()
        }
    }
    catch { return $null }
}

function Get-InstalledVersionPath([string]$Root) { return (Join-Path $Root "versao-instalada.json") }

function Get-InstalledVersion([string]$Root) {
    try { return (Get-Content -LiteralPath (Get-InstalledVersionPath $Root) -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-AppProcesses([string]$AppDir) {
    # Janelas e monitores do SnakeOptimizer abertos a partir da pasta instalada (em qualquer sessao).
    $needle = ($AppDir.TrimEnd("\") + "\").ToLowerInvariant()
    try {
        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($needle) })
    }
    catch { return @() }
}

function Write-UpdateLog([string]$Root, [string]$Text) {
    # O registro do Atualizador (as ultimas 200 linhas).
    try {
        $log = Join-Path $Root "atualizador.log"
        $lines = @()
        if (Test-Path -LiteralPath $log) { $lines = @(Get-Content -LiteralPath $log -Encoding UTF8 | Select-Object -Last 199) }
        $lines += "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  $Text"
        Set-Content -LiteralPath $log -Value $lines -Encoding UTF8
    }
    catch { }
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
        $UpdateInfo.Outcome = "Local"
        return $appDir
    }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $src = $Source
    $commit = $null
    if ([string]::IsNullOrWhiteSpace($src)) {
        if ($Repository -like "CONFIGURE_*") {
            throw "Configure a variavel `$Repository no launch.ps1 (ou passe -Source <url do zip>)."
        }
        # O commit mais novo: se a copia instalada ja e ele, nada e baixado (abre mais rapido); se nao, baixa exatamente ele.
        $commit = Get-RemoteCommit
        $UpdateInfo.Commit = $commit
        if ($commit) {
            $installed = Get-InstalledVersion $Root
            if ($installed -and $installed.Sha -eq $commit.Sha -and (Test-Path -LiteralPath $gui) -and [string]::IsNullOrWhiteSpace($Sha256)) {
                Write-Step "Ja esta na versao mais nova ($($commit.Sha.Substring(0, 7)))." Green
                $UpdateInfo.Outcome = "UpToDate"
                return $appDir
            }
            $src = "https://github.com/$Repository/archive/$($commit.Sha).zip"
        }
        else {
            $src = "https://github.com/$Repository/archive/refs/heads/$Branch.zip"
        }
    }

    # O Atualizador (sem ninguem olhando) nao troca a pasta com o SnakeOptimizer aberto: tenta de novo na proxima vez.
    if ($Mode -eq "Update" -and (Test-Path -LiteralPath $gui)) {
        $open = @(Get-AppProcesses $appDir)
        $windows = @($open | Where-Object { $_.CommandLine -notmatch 'Agent\.ps1' })
        if ($windows.Count -gt 0) {
            $UpdateInfo.Outcome = "InUse"
            return $appDir
        }
    }

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
                $UpdateInfo.Outcome = "Offline"
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

        # Restos de trocas anteriores.
        Get-ChildItem -LiteralPath $Root -Directory -Filter "app.old-*" -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

        $inUse = $false
        if (Test-Path -LiteralPath $appDir) {
            $open = @(Get-AppProcesses $appDir)
            $inUse = @($open | Where-Object { $_.CommandLine -notmatch 'Agent\.ps1' }).Count -gt 0
            # So o icone da bandeja usa a pasta: fecha para trocar os arquivos (o launcher o reabre em seguida).
            if (-not $inUse -and $open.Count -gt 0) {
                foreach ($p in $open) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
                $UpdateInfo.AgentsStopped = $true
                Start-Sleep -Seconds 2
            }
        }
        if (-not $inUse -and (Test-Path -LiteralPath $appDir)) {
            # Renomeia antes de apagar: se algo estiver preso, a pasta antiga fica inteira (nunca meio apagada).
            $old = Join-Path $Root "app.old-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            try { Rename-Item -LiteralPath $appDir -NewName (Split-Path $old -Leaf) -ErrorAction Stop }
            catch { $inUse = $true }
            if (-not $inUse) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
        }

        if ($inUse) {
            if ($Mode -eq "Update") { $UpdateInfo.Outcome = "InUse"; return $appDir }
            # Uma janela aberta ainda usa a pasta: roda desta copia nova, sem mexer na antiga.
            Write-Step "Versao anterior em uso; executando a partir da copia temporaria." Yellow
            $UpdateInfo.Outcome = "InUse"
            $keepStage = $true
            return $payload
        }

        Move-Item -LiteralPath $payload -Destination $appDir

        # O launcher fica ao lado da pasta app (o Atualizador e os atalhos o usam) e a versao instalada e anotada.
        try { Copy-Item -LiteralPath (Join-Path $appDir "launch.ps1") -Destination (Join-Path $Root "launch.ps1") -Force -ErrorAction Stop } catch { }
        $record = [ordered]@{
            Sha         = $(if ($commit) { $commit.Sha } else { "" })
            Date        = $(if ($commit) { $commit.Date } else { "" })
            Message     = $(if ($commit) { $commit.Message } else { "" })
            InstalledAt = (Get-Date).ToString("o", [Globalization.CultureInfo]::InvariantCulture)
            Source      = $src
        }
        try { $record | ConvertTo-Json | Set-Content -LiteralPath (Get-InstalledVersionPath $Root) -Encoding UTF8 } catch { }
        $UpdateInfo.Outcome = "Updated"
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

function Get-LoggedOnUser {
    $user = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if (-not $user) {
        # Sessoes RDP nao aparecem em Win32_ComputerSystem: pega o dono do explorer.exe.
        $explorer = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
        if ($explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            if ($owner.User) { $user = "$($owner.Domain)\$($owner.User)" }
        }
    }
    return $user
}

$AgentRunKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
$AgentRunName = "SnakeOptimizer Monitor"

function Get-AgentCommandLine([string]$Root) {
    $agent = Join-Path $Root "app\$AppName.Agent.ps1"
    return "`"$(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$agent`" -Machine"
}

function Start-AgentInUserSession {
    # Abre o icone da bandeja agora na sessao do usuario logado, sem elevacao (o monitor nunca roda como Administrador).
    param ([string]$Root)

    $user = Get-LoggedOnUser
    if (-not $user) { return $false }
    $agent = Join-Path $Root "app\$AppName.Agent.ps1"
    if (-not (Test-Path -LiteralPath $agent)) { return $false }

    $taskName = "$AppName-Monitor-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        $taskAction = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -Argument "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$agent`" -Machine"
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 3
        return $true
    }
    catch { return $false }
    finally { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
}

function Start-GuiInUserSession {
    # SYSTEM nao tem area de trabalho visivel. Uma tarefa agendada com o token interativo do usuario logado abre a janela
    # na tela dele (o tecnico ve pelo acesso remoto). RunLevel Highest: se o usuario for administrador, abre elevada.
    param ([string]$AppDir)

    $user = Get-LoggedOnUser
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

function Register-Updater {
    # Tarefa "Atualizador" (SYSTEM): 3 minutos depois de ligar o PC e a cada 6 horas. Baixa o launcher mais novo do GitHub
    # e roda -Mode Update; sem internet, usa o launcher local (que tambem nao acha nada e sai).
    param ([string]$Root)

    $url = "https://raw.githubusercontent.com/$Repository/$Branch/launch.ps1"
    $local = Join-Path $Root "launch.ps1"
    $inner = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
        "`$s = `$null; try { `$s = Invoke-RestMethod -Uri '$url' -UseBasicParsing } catch { }; " +
        "if (`$s) { & ([scriptblock]::Create(`$s)) -Mode Update } else { & '$local' -Mode Update }; exit `$LASTEXITCODE"

    $taskAction = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$inner`""
    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = "PT3M"
    $triggers = @($boot)
    foreach ($hour in 0, 6, 12, 18) { $triggers += New-ScheduledTaskTrigger -Daily -At ((Get-Date).Date.AddHours($hour)) }
    $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RunOnlyIfNetworkAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $description = "SnakeOptimizer (Snake Tech): mantem a copia instalada em %ProgramData%\SnakeOptimizer na versao mais nova do GitHub. Nao mexe no Windows. Para remover: SnakeOptimizer > Sobre > Instalacao no PC."

    $task = New-ScheduledTask -Action $taskAction -Trigger $triggers -Principal $principal -Settings $settings -Description $description
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $UpdaterTask -InputObject $task -Force | Out-Null
}

function Get-ShortcutPaths {
    return @(
        (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$AppName.lnk"),
        (Join-Path $env:PUBLIC "Desktop\$AppName.lnk")
    )
}

function New-AppShortcuts {
    # Atalhos para todos os usuarios: abrem o launcher instalado como Administrador (ele confere a versao e abre a janela).
    param ([string]$Root)

    $launcher = Join-Path $Root "launch.ps1"
    $icon = Join-Path $Root "app\assets\$AppName.ico"
    $shell = New-Object -ComObject WScript.Shell
    $made = @()

    foreach ($path in Get-ShortcutPaths) {
        try {
            $lnk = $shell.CreateShortcut($path)
            $lnk.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
            $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
            $lnk.WorkingDirectory = $Root
            $lnk.WindowStyle = 7
            $lnk.Description = "SnakeOptimizer (Snake Tech)"
            if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = "$icon,0" }
            $lnk.Save()
            # "Executar como administrador" (o bit 0x20 do byte 0x15 do .lnk).
            $bytes = [IO.File]::ReadAllBytes($path)
            $bytes[0x15] = $bytes[0x15] -bor 0x20
            [IO.File]::WriteAllBytes($path, $bytes)
            $made += $path
        }
        catch { Write-Step "Nao foi possivel criar o atalho $path ($($_.Exception.Message))." Yellow }
    }
    return $made
}

function Install-Machine {
    param ([string]$Root, [string]$AppDir)

    if (-not (Test-IsAdmin)) { throw "Instalar no PC exige Administrador (ou o RMM como SYSTEM)." }
    if ($Root -notlike "$env:ProgramData*") { throw "A instalacao fica em %ProgramData%; rode como Administrador." }

    $installedApp = Join-Path $Root "app"
    if (-not (Test-Path -LiteralPath (Join-Path $installedApp "$AppName.Gui.ps1"))) { throw "A copia em $installedApp nao esta completa." }
    Copy-Item -LiteralPath (Join-Path $installedApp "launch.ps1") -Destination (Join-Path $Root "launch.ps1") -Force

    Register-Updater -Root $Root
    $links = @(New-AppShortcuts -Root $Root)

    # Icone na bandeja (perto do relogio) para todos os usuarios, ao entrar no Windows; e ja abre agora.
    Set-ItemProperty -LiteralPath $AgentRunKey -Name $AgentRunName -Value (Get-AgentCommandLine $Root) -Type String
    $trayNow = Start-AgentInUserSession -Root $Root
    Write-UpdateLog $Root "Instalado (Atualizador e icone da bandeja ligados)."

    Write-Step "Instalado em $Root" Green
    Write-Step "Atualizador: tarefa $TaskPath$UpdaterTask (SYSTEM), ao ligar o PC e a cada 6 horas." Green
    foreach ($l in $links) { Write-Step "Atalho: $l" Green }
    Write-Step "Icone na bandeja: abre com o Windows para todos os usuarios$(if ($trayNow) { '; ja aberto agora' } else { '; aparece no proximo logon' })." Green
    Write-Step "Se o icone estiver escondido: clique na setinha ^ perto do relogio e arraste-o para a barra." Gray
    Write-Step "Para a manutencao diaria/semanal: abra o SnakeOptimizer > Manutencao > Manutencao automatica."
}

function Uninstall-Machine {
    param ([string]$Root)

    if (-not (Test-IsAdmin)) { throw "Desinstalar exige Administrador (ou o RMM como SYSTEM)." }

    foreach ($t in @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Step "Tarefa removida: $($t.TaskName)"
    }
    foreach ($path in Get-ShortcutPaths) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; Write-Step "Atalho removido: $path" }
    }

    Remove-ItemProperty -LiteralPath $AgentRunKey -Name $AgentRunName -ErrorAction SilentlyContinue
    $appDir = Join-Path $Root "app"
    foreach ($p in @(Get-AppProcesses $appDir | Where-Object { $_.CommandLine -match 'Agent\.ps1' })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Write-Step "Icone da bandeja desligado."
    Start-Sleep -Seconds 1
    if (@(Get-AppProcesses $appDir).Count -gt 0) {
        Write-Step "O SnakeOptimizer esta aberto: a pasta $appDir fica. Feche-o e rode a desinstalacao de novo para apaga-la." Yellow
    }
    else {
        foreach ($item in $appDir, (Join-Path $Root "launch.ps1"), (Get-InstalledVersionPath $Root), (Join-Path $Root "atualizador.log")) {
            if (Test-Path -LiteralPath $item) { Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Write-Step "Copia instalada removida. Relatorios e historico ficam em $Root." Green
    }
}

# ---------------------------------------------------------------------------------------------------------------------
try {
    if ($Mode -eq "Uninstall") {
        Uninstall-Machine -Root (Join-Path $env:ProgramData $AppName)
        $global:LASTEXITCODE = 0
        return
    }

    if ($Mode -in "Install", "Update" -and -not (Test-IsAdmin)) {
        Write-Step "O modo $Mode exige Administrador (ou o RMM como SYSTEM)." Red
        $global:LASTEXITCODE = 3
        if ($PSCommandPath) { exit 3 }
        return
    }

    $root = Get-InstallRoot
    # Sem Administrador, a copia instalada em ProgramData e so leitura: usa como esta (o Atualizador a mantem em dia).
    if (-not (Test-IsAdmin) -and $root -like "$env:ProgramData*") { $NoUpdate = $true }
    $appDir = Install-App -Root $root
    # O icone da bandeja foi fechado para trocar os arquivos: volta agora, ja na versao nova.
    if ($UpdateInfo.AgentsStopped) { $UpdateInfo.AgentRestarted = [bool](Start-AgentInUserSession -Root $root) }
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
        "Install" {
            Install-Machine -Root $root -AppDir $appDir
            $global:LASTEXITCODE = 0
        }
        "Update" {
            $short = $(if ($UpdateInfo.Commit) { $UpdateInfo.Commit.Sha.Substring(0, 7) } else { "?" })
            $text = switch ($UpdateInfo.Outcome) {
                "Updated" { "Atualizado para $short ($($UpdateInfo.Commit.Message))." }
                "UpToDate" { "Ja estava na versao mais nova ($short)." }
                "InUse" { "Versao nova $short disponivel, mas o SnakeOptimizer esta aberto: atualiza na proxima vez." }
                "Offline" { "Sem conexao com o GitHub; mantida a copia atual." }
                default { "Nada feito ($($UpdateInfo.Outcome))." }
            }
            if (-not $UpdateInfo.Commit -and $UpdateInfo.Outcome -eq "Updated") { $text = "Atualizado (sem consultar o commit; limite do GitHub)." }
            # O icone da bandeja foi fechado para a troca: volta agora (com a versao nova).
            if ($UpdateInfo.AgentRestarted) { $text += " Icone da bandeja reaberto." }
            Write-UpdateLog $root $text
            Write-Step $text Green
            $global:LASTEXITCODE = $(if ($UpdateInfo.Outcome -in "Updated", "UpToDate") { 0 } else { 1 })
            if ($PSCommandPath) { exit $global:LASTEXITCODE }
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
