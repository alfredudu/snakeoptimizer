# Monitor na bandeja: um ícone perto do relógio que fica de olho no PC e avisa quando algo pede atenção.
#
# O monitor é o SnakeOptimizer.Agent.ps1, na pasta do SnakeOptimizer. Ele começa com o Windows (uma entrada em Run, do usuário) e só
# lê: espaço no disco, proteção, reinício pendente, manutenção, suporte do Windows e programas desatualizados. Cada aviso
# aparece no máximo uma vez a cada tanto tempo (veja Get-SnakeOptimizerAgentChecks) e pode ser pausado por 24 horas no menu do
# ícone. Este módulo tem as regras (o que avisar e quando) e o liga/desliga; o script cuida do ícone.

$script:SnakeOptimizerAgentRunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$script:SnakeOptimizerAgentRunName = "SnakeOptimizer Monitor"
# Aviso de memória: acima de quanto (% da RAM em uso) e quantas leituras seguidas já passaram dele.
$script:SnakeOptimizerAgentMemoryLimit = 90
$script:SnakeOptimizerAgentMemoryHigh = 0
# A entrada para todos os usuários, gravada pela instalação no PC (launch.ps1 -Mode Install).
$script:SnakeOptimizerAgentMachineRunKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
# Onde o Gerenciador de Tarefas (aba Inicializar) marca uma entrada de Run como desativada.
$script:SnakeOptimizerAgentApprovedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
$script:SnakeOptimizerAgentStopEvent = "Local\SnakeOptimizer.Agent.Stop"
# Quanto tempo esperar o monitor aparecer depois de pedir a abertura.
$script:SnakeOptimizerAgentStartWaitSeconds = 8


function Get-SnakeOptimizerAgentActionIds {
    # As ações que o monitor pede à janela: as do menu do ícone e as dos avisos. A janela só roda estas quando o pedido
    # chega de outra abertura (Receive-SnakeOptimizerWindowRequest).
    # app.monitor (Configurar o monitor) só mostra a tela de escolha: nada muda sem um clique nela.
    return @("performance.boost", "performance.memory", "performance.processes", "cleanup.quick", "maintenance.checkup", "diagnostics.pending-reboot", "diagnostics.disk-health", "security.status", "diagnostics.windows-support", "updates.winget", "app.monitor")
}


function Get-SnakeOptimizerAgentScriptPath {
    return (Join-Path (Get-SnakeOptimizerAppRoot) "SnakeOptimizer.Agent.ps1")
}


function Get-SnakeOptimizerAgentStopEventName {
    return $script:SnakeOptimizerAgentStopEvent
}


function Get-SnakeOptimizerAgentHost {
    # Quem abre o PowerShell do monitor sem janela: o conhost --headless (Windows 10 1809 ou mais novo). Com o Windows
    # Terminal como terminal padrão (Windows 11), "-WindowStyle Hidden" deixava uma janela preta aberta, e fechá-la
    # derrubava o ícone. Devolve Executable e o prefixo dos argumentos (vazio quando o conhost não serve).
    $conhost = Join-Path $env:SystemRoot "System32\conhost.exe"

    if ([Environment]::OSVersion.Version.Build -ge 17763 -and (Test-Path -LiteralPath $conhost)) {
        return [PSCustomObject]@{ Executable = $conhost; Prefix = "--headless $(ConvertTo-SnakeOptimizerCommandLineArgument -Value (Get-SnakeOptimizerPowerShellPath)) " }
    }

    return [PSCustomObject]@{ Executable = (Get-SnakeOptimizerPowerShellPath); Prefix = "" }
}


function Get-SnakeOptimizerAgentCommandLine {
    # A linha que o Windows roda ao entrar: o PowerShell, sem janela, com o script do monitor.
    $script = Get-SnakeOptimizerAgentScriptPath
    $agentHost = Get-SnakeOptimizerAgentHost

    return "$(ConvertTo-SnakeOptimizerCommandLineArgument -Value $agentHost.Executable) $($agentHost.Prefix)-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File $(ConvertTo-SnakeOptimizerCommandLineArgument -Value $script)"
}


function Get-SnakeOptimizerAgentRunState {
    <#
    Se o monitor começa com o Windows: On; Off (sem a entrada); Elsewhere (a entrada aponta para outra pasta do SnakeOptimizer,
    ou para um script que não existe mais: a pasta mudou de lugar); Disabled (desativado no Gerenciador de Tarefas, aba
    Inicializar: o Windows não roda a entrada).
    #>
    $value = [string](Get-SnakeOptimizerRegistryValueOrNull -Path $script:SnakeOptimizerAgentRunKey -Name $script:SnakeOptimizerAgentRunName)
    $script = Get-SnakeOptimizerAgentScriptPath

    if ([string]::IsNullOrWhiteSpace($value)) {
        # Instalado no PC: a entrada para todos os usuários vale, a não ser que esta conta tenha desligado o monitor.
        # A partir da 1.7 é a tarefa \SnakeOptimizer\Monitor (a marca fica em %ProgramData%\SnakeOptimizer); antes, HKLM\...\Run.
        $machine = [string](Get-SnakeOptimizerRegistryValueOrNull -Path $script:SnakeOptimizerAgentMachineRunKey -Name $script:SnakeOptimizerAgentRunName)
        $machineRoot = Join-Path $env:ProgramData "SnakeOptimizer"
        $byTask = (Test-Path -LiteralPath (Join-Path $machineRoot "monitor-todos-usuarios.flag")) -and $script.StartsWith((Join-Path $machineRoot "app"), [StringComparison]::OrdinalIgnoreCase)
        $byRun = ($machine -and $machine.IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (($byTask -or $byRun) -and (Test-Path -LiteralPath $script -PathType Leaf) -and -not (Test-SnakeOptimizerAgentOptedOut)) {
            return "On"
        }
        return "Off"
    }

    if ($value.IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or -not (Test-Path -LiteralPath $script -PathType Leaf)) {
        return "Elsewhere"
    }

    # O primeiro byte ímpar (03, 07) é "desativado"; par (02, 06) ou sem o valor, "ativado".
    $approved = Get-SnakeOptimizerRegistryValueOrNull -Path $script:SnakeOptimizerAgentApprovedKey -Name $script:SnakeOptimizerAgentRunName

    $first = $(if ($null -ne $approved) { @($approved)[0] } else { $null })

    if ($first -is [byte] -and ($first -band 1) -eq 1) { return "Disabled" }

    return "On"
}


function Test-SnakeOptimizerAgentOptedOut {
    # Se esta conta desligou o monitor (vale contra a entrada do PC, que só um Administrador remove).
    return ([string](Get-SnakeOptimizerSetting -Name "AgentOptOut" -Default "") -eq "1")
}


function Test-SnakeOptimizerAgentEnabled {
    # Se o monitor de fato começa com o Windows (a entrada existe, aponta para esta pasta e não foi desativada).
    return ((Get-SnakeOptimizerAgentRunState) -eq "On")
}


function Get-SnakeOptimizerAgentProcesses {
    # Os processos do monitor que estão rodando agora nesta sessão do Windows (pela linha de comando). Lista vazia se não
    # der para ler. Os monitores de outras contas logadas (troca rápida de usuário) não são deste usuário: ligar, abrir e
    # desligar nunca mexem neles.
    try {
        $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop |
                Where-Object { [string]$_.CommandLine -like "*SnakeOptimizer.Agent.ps1*" -and [int](Get-SnakeOptimizerJsonValue -Object $_ -Name "SessionId" -Default $session) -eq $session })
    }
    catch {
        return @()
    }
}


function Test-SnakeOptimizerAgentStartBlocked {
    # Se o monitor não deve ser ligado nem aberto daqui: com a conta de outro Administrador, ele ficaria no perfil dessa
    # conta. Na janela elevada da própria conta, ele abre sem a elevação (Start-SnakeOptimizerAgent).
    return [bool](Test-SnakeOptimizerUserContextMismatch)
}


function Request-SnakeOptimizerAgentStart {
    # Só pede a abertura do monitor (sem esperar ele aparecer): da janela elevada, pelo atalho entregue ao Explorador, que
    # o abre sem elevação. Uma falha vira um erro em português.
    $agentHost = Get-SnakeOptimizerAgentHost
    $arguments = "$($agentHost.Prefix)-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File $(ConvertTo-SnakeOptimizerCommandLineArgument -Value (Get-SnakeOptimizerAgentScriptPath))"

    try {
        # Instalado no PC: a tarefa do monitor abre na sessão da pessoa, sem elevação e sem o Explorador (que, em alguns
        # PCs, recusa o atalho com "não tem um aplicativo associado").
        $task = Get-ScheduledTask -TaskPath "\SnakeOptimizer\" -TaskName "Monitor" -ErrorAction SilentlyContinue
        if ($null -ne $task -and $task.State -ne "Disabled" -and (Get-SnakeOptimizerAgentScriptPath) -like "$env:ProgramData*") {
            Start-ScheduledTask -InputObject $task -ErrorAction Stop
        }
        elseif (Test-SnakeOptimizerAdministrator) {
            $link = Join-Path (Get-SnakeOptimizerDataPath) "monitor.lnk"
            [void](Save-SnakeOptimizerShortcutFile -Path $link -Target $agentHost.Executable -Arguments $arguments -WorkingDirectory (Get-SnakeOptimizerAppRoot) -Description "Monitor do SnakeOptimizer")
            Start-Process -FilePath "explorer.exe" -ArgumentList "`"$link`"" -ErrorAction Stop
        }
        else {
            Start-Process -FilePath $agentHost.Executable -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop
        }
    }
    catch {
        throw "o Windows não deixou abrir o monitor agora"
    }
}


function Restore-SnakeOptimizerAgentIfMissing {
    <#
    Chamado quando a janela abre: se o monitor está ligado para esta conta mas não está rodando (fechou numa atualização,
    caiu, foi encerrado no Gerenciador de Tarefas), abre de novo, sem esperar. Antes, ele só voltava no próximo logon.
    Devolve se pediu a abertura.
    #>
    # Só pela tarefa do monitor da instalação (\SnakeOptimizer\Monitor, grupo Usuários, sem elevação): o atalho entregue
    # ao Explorador, usado quando a pessoa liga o monitor, mostrava um erro do Windows ("não tem um aplicativo associado")
    # em PCs onde o Explorador não abre o .lnk, e aqui ninguém pediu nada. Sem a tarefa, fica para o próximo logon.
    try {
        if (-not (Test-SnakeOptimizerAgentEnabled)) { return $false }
        if (Test-SnakeOptimizerAgentStartBlocked) { return $false }
        if (@(Get-SnakeOptimizerAgentProcesses).Count -gt 0) { return $false }

        $task = Get-ScheduledTask -TaskPath "\SnakeOptimizer\" -TaskName "Monitor" -ErrorAction SilentlyContinue
        if ($null -eq $task -or $task.State -eq "Disabled") { return $false }

        Start-ScheduledTask -InputObject $task -ErrorAction Stop
        return $true
    }
    catch {
        Write-Verbose "Monitor: $($_.Exception.Message)"
        return $false
    }
}


function Start-SnakeOptimizerAgent {
    <#
    Abre o monitor agora (o próprio script recusa uma segunda cópia) e devolve se ele apareceu em alguns segundos. O monitor
    nunca roda como Administrador: aberto direto da janela elevada, ele herdaria a elevação até o fim da sessão (e o "Abrir
    o SnakeOptimizer" do menu abriria a janela elevada sem perguntar). Por isso, da janela elevada, ele abre por um atalho
    (monitor.lnk, na pasta de dados) entregue ao Explorador, que o abre na sessão da pessoa, sem elevação. Quem chama
    confere Test-SnakeOptimizerAgentStartBlocked. Uma falha ao pedir a abertura vira um erro em português.
    #>
    Request-SnakeOptimizerAgentStart

    # O Explorador abre o atalho por conta própria, um instante depois: confere por alguns segundos se o monitor apareceu e
    # continuou aberto por 2 segundos. Um monitor que abriu elevado (o Explorador não fez a troca) fecha sozinho logo no
    # começo (SnakeOptimizer.Agent.ps1), e aí a tela diz que ele abre com o Windows, e não "ligado".
    $seen = 0

    for ($i = 0; $i -lt ($script:SnakeOptimizerAgentStartWaitSeconds * 2); $i++) {
        if (@(Get-SnakeOptimizerAgentProcesses).Count -gt 0) { $seen++ } else { $seen = 0 }
        if ($seen -ge 4) { return $true }
        Start-Sleep -Milliseconds 500
    }

    return $false
}


function Stop-SnakeOptimizerAgent {
    # Pede ao monitor que feche (pelo evento que ele escuta) e, se ele não fechar em alguns segundos, encerra o processo.
    try {
        $signal = [System.Threading.EventWaitHandle]::OpenExisting($script:SnakeOptimizerAgentStopEvent)
        [void]$signal.Set()
        $signal.Dispose()
    }
    catch {
        Write-Verbose "O monitor não estava escutando: $($_.Exception.Message)"
    }

    for ($i = 0; $i -lt 10; $i++) {
        if (@(Get-SnakeOptimizerAgentProcesses).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }

    foreach ($process in @(Get-SnakeOptimizerAgentProcesses)) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }

    # Um monitor aberto como Administrador não fecha a pedido de uma janela sem elevação: quem chama diz isso.
    return (@(Get-SnakeOptimizerAgentProcesses).Count -eq 0)
}


function Enable-SnakeOptimizerAgent {
    <#
    Grava a entrada em Run (e tira a marca de "desativado" do Gerenciador de Tarefas, se houver) e abre o monitor. Devolve
    "Open" (aberto agora, ou já estava), "Later" (pedido, mas o ícone não apareceu em alguns segundos: abre com o Windows),
    "Blocked" (com a conta de outro Administrador: só fica configurado) ou "StartFailed" (configurado, mas o Windows não
    deixou abrir agora). Sem conseguir gravar a entrada, lança um erro em português e nada muda.
    #>
    if (-not (Test-Path -LiteralPath (Get-SnakeOptimizerAgentScriptPath) -PathType Leaf)) {
        throw "o arquivo SnakeOptimizer.Agent.ps1 não está na pasta do SnakeOptimizer"
    }

    # O Windows não roda uma entrada de Run com 260 caracteres ou mais.
    $line = Get-SnakeOptimizerAgentCommandLine

    if ($line.Length -ge 260) {
        throw "o caminho da pasta do SnakeOptimizer é longo demais para o Windows abrir o monitor sozinho; mova a pasta do SnakeOptimizer para um caminho mais curto"
    }

    # -ErrorAction Stop nos dois: sem ele, uma chave que não pode ser criada só escrevia um erro do Windows (em inglês) na
    # tela, e a gravação seguinte falhava com outro.
    try {
        if (-not (Test-Path -LiteralPath $script:SnakeOptimizerAgentRunKey)) {
            [void](New-Item -Path $script:SnakeOptimizerAgentRunKey -Force -ErrorAction Stop)
        }

        Set-ItemProperty -LiteralPath $script:SnakeOptimizerAgentRunKey -Name $script:SnakeOptimizerAgentRunName -Value $line -Type String -ErrorAction Stop
    }
    catch {
        throw "o Windows não deixou gravar a entrada que faz o monitor abrir com o Windows"
    }

    [void](Set-SnakeOptimizerSetting -Name "AgentOptOut" -Value "")

    # Desativado antes no Gerenciador de Tarefas, o Windows continuaria sem rodar a entrada.
    try { Remove-SnakeOptimizerRegistryValue -Path $script:SnakeOptimizerAgentApprovedKey -Name $script:SnakeOptimizerAgentRunName } catch { Write-Verbose "Marca de inicialização: $($_.Exception.Message)" }

    # Um monitor aberto de outra pasta do SnakeOptimizer (a cópia antiga) seguiria abrindo a janela antiga até sair do Windows.
    $running = @(Get-SnakeOptimizerAgentProcesses)
    $script = Get-SnakeOptimizerAgentScriptPath

    if ($running.Count -gt 0 -and @($running | Where-Object { ([string]$_.CommandLine).IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) { return "Open" }
    if (Test-SnakeOptimizerAgentStartBlocked) { return "Blocked" }
    if ($running.Count -gt 0) { [void](Stop-SnakeOptimizerAgent) }

    try {
        if (Start-SnakeOptimizerAgent) { return "Open" }
    }
    catch {
        return "StartFailed"
    }

    return "Later"
}


function Remove-SnakeOptimizerAgentStaleEntry {
    # Tira a entrada de início quando ela aponta para o script dado (a pasta antiga, que não existe mais). Devolve se tirou.
    param ([Parameter(Mandatory)][string]$ScriptPath)

    $value = [string](Get-SnakeOptimizerRegistryValueOrNull -Path $script:SnakeOptimizerAgentRunKey -Name $script:SnakeOptimizerAgentRunName)

    if ([string]::IsNullOrWhiteSpace($value) -or $value.IndexOf($ScriptPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }

    Remove-SnakeOptimizerRegistryValue -Path $script:SnakeOptimizerAgentRunKey -Name $script:SnakeOptimizerAgentRunName
    return $true
}


function Disable-SnakeOptimizerAgent {
    # Devolve se o monitor fechou (ele pode ter sido aberto como Administrador e não aceitar o pedido desta janela). Sem
    # conseguir remover a entrada em Run, lança um erro em português e não fecha o ícone.
    try {
        Remove-SnakeOptimizerRegistryValue -Path $script:SnakeOptimizerAgentRunKey -Name $script:SnakeOptimizerAgentRunName
    }
    catch {
        throw "o Windows não deixou remover a entrada que faz o monitor abrir com o Windows"
    }

    try { Remove-SnakeOptimizerRegistryValue -Path $script:SnakeOptimizerAgentApprovedKey -Name $script:SnakeOptimizerAgentRunName } catch { Write-Verbose "Marca de inicialização: $($_.Exception.Message)" }

    # Com o SnakeOptimizer instalado no PC, a entrada para todos os usuários continua: esta conta fica de fora.
    [void](Set-SnakeOptimizerSetting -Name "AgentOptOut" -Value "1")

    return (Stop-SnakeOptimizerAgent)
}


# ---------------------------------------------------------------------------
# Regras dos avisos
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerAgentChecks {
    # O que o monitor confere, de quanto em quanto tempo (minutos) e o intervalo mínimo entre dois avisos iguais (horas).
    # Heavy = leitura demorada, feita em segundo plano.
    return @(
        @{ Id = "disk"; EveryMinutes = 15; RepeatHours = 24; Heavy = $false },
        # Saúde dos discos (estado do Windows, erros e desgaste): a cada 6 horas; o aviso se repete a cada 3 dias.
        @{ Id = "diskhealth"; EveryMinutes = 360; RepeatHours = 72; Heavy = $true },
        # Memória: a cada passada do monitor (90 s); só avisa depois de 3 leituras seguidas acima do limite (uns 5 min).
        @{ Id = "memory"; EveryMinutes = 1; RepeatHours = 2; Heavy = $false },
        @{ Id = "reboot"; EveryMinutes = 60; RepeatHours = 24; Heavy = $false },
        @{ Id = "maintenance"; EveryMinutes = 360; RepeatHours = 168; Heavy = $false },
        @{ Id = "protection"; EveryMinutes = 60; RepeatHours = 12; Heavy = $true },
        @{ Id = "windows"; EveryMinutes = 1440; RepeatHours = 168; Heavy = $false },
        @{ Id = "programs"; EveryMinutes = 1440; RepeatHours = 72; Heavy = $true },
        @{ Id = "catalog"; EveryMinutes = 1440; RepeatHours = 0; Heavy = $true }
    )
}


function Get-SnakeOptimizerAgentStatePath {
    return (Join-Path (Get-SnakeOptimizerDataPath) "agent.json")
}


function Read-SnakeOptimizerAgentState {
    # Quando cada conferência rodou e cada aviso apareceu pela última vez ({ Checked = @{id=data}; Shown = @{id=data} }).
    $state = @{ Checked = @{}; Shown = @{} }

    try {
        $document = (Read-SnakeOptimizerStateFile -Path (Get-SnakeOptimizerAgentStatePath)).Document
        if ($null -eq $document) { return $state }

        foreach ($section in @("Checked", "Shown")) {
            $values = Get-SnakeOptimizerJsonValue -Object $document -Name $section -Default $null
            if ($null -eq $values) { continue }

            foreach ($property in $values.PSObject.Properties) {
                $at = [datetime]::MinValue
                if ([datetime]::TryParse([string]$property.Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) {
                    $state[$section][$property.Name] = $at
                }
            }
        }
    }
    catch {
        Write-Verbose "Estado do monitor ilegível: $($_.Exception.Message)"
    }

    return $state
}


function Save-SnakeOptimizerAgentState {
    param ([Parameter(Mandatory)][hashtable]$State)

    try {
        $document = [ordered]@{}

        foreach ($section in @("Checked", "Shown")) {
            $values = [ordered]@{}
            foreach ($key in @($State[$section].Keys | Sort-Object)) { $values[$key] = ([datetime]$State[$section][$key]).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture) }
            $document[$section] = $values
        }

        Write-SnakeOptimizerStateJson -Path (Get-SnakeOptimizerAgentStatePath) -InputObject $document -Depth 4
    }
    catch {
        Write-Verbose "Não foi possível salvar o estado do monitor: $($_.Exception.Message)"
    }
}


function Test-SnakeOptimizerAgentDue {
    # Se já passou o tempo desde a última vez (Last ausente = nunca). Uma data mais de um dia no futuro (o relógio estava
    # adiantado quando ela foi gravada) também conta como "na hora": senão o monitor ficaria calado até lá.
    param (
        $Last,
        [double]$Minutes,
        [datetime]$Now = (Get-Date)
    )

    if ($null -eq $Last -or [datetime]$Last -gt $Now.AddDays(1)) { return $true }

    return (($Now - [datetime]$Last).TotalMinutes -ge $Minutes)
}


function Get-SnakeOptimizerAgentPausedUntil {
    # Até quando os avisos estão pausados, ou $null. A pausa é de 24 horas: um fim mais longe que isso (gravado com o
    # relógio adiantado) não vale, para o monitor não ficar calado por anos.
    param ([datetime]$Now = (Get-Date))

    $until = [string](Get-SnakeOptimizerSetting -Name "AgentPausedUntil" -Default "")
    $at = [datetime]::MinValue

    if ([string]::IsNullOrWhiteSpace($until) -or -not [datetime]::TryParse($until, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) { return $null }

    if ($at -le $Now -or $at -gt $Now.AddHours(25)) { return $null }

    return $at
}


function Test-SnakeOptimizerAgentPaused {
    param ([datetime]$Now = (Get-Date))

    return ($null -ne (Get-SnakeOptimizerAgentPausedUntil -Now $Now))
}


function Set-SnakeOptimizerAgentPause {
    # Pausa os avisos por algumas horas; Hours = 0 retoma.
    param ([int]$Hours = 24)

    $value = $(if ($Hours -gt 0) { (Get-Date).AddHours($Hours).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture) } else { "" })
    [void](Set-SnakeOptimizerSetting -Name "AgentPausedUntil" -Value $value)
}


function Format-SnakeOptimizerAgentPauseEnd {
    # Até quando a pausa vai, como a pessoa diz: "hoje, às 18:40", "amanhã, às 14:30" (uma pausa de 24 horas sempre
    # termina amanhã; "até 14:30" sozinho parecia hoje). Mais longe que isso, com a data: "09/11, às 08:00".
    param (
        [Parameter(Mandatory)][datetime]$Until,
        [datetime]$Now = (Get-Date)
    )

    $time = Format-SnakeOptimizerDateTime -When $Until -Pattern 'HH:mm'

    if ($Until.Date -eq $Now.Date) { return "hoje, às $time" }
    if ($Until.Date -eq $Now.Date.AddDays(1)) { return "amanhã, às $time" }

    return "$(Format-SnakeOptimizerDateTime -When $Until -Pattern 'dd/MM'), às $time"
}


function Get-SnakeOptimizerAgentSortedAlerts {
    # Os avisos abertos na ordem em que o monitor os mostra: os mais graves (Warning) primeiro.
    param ([AllowEmptyCollection()][object[]]$Alerts = @())

    return @(@($Alerts | Where-Object { $null -ne $_ }) | Sort-Object @{ Expression = { if ($_.Level -eq "Warning") { 0 } else { 1 } } })
}


function Get-SnakeOptimizerAgentTooltip {
    <#
    O texto do ícone ao passar o mouse. O Windows corta em 63 caracteres: um texto maior termina em "...".
    Antes da primeira leitura, "conferindo o PC"; com avisos, o mais grave pelo nome e quantos mais há; pausado, até quando.
    #>
    param (
        [AllowEmptyCollection()][object[]]$Alerts = @(),
        [bool]$FirstReading = $true,
        $PausedUntil = $null,
        [datetime]$Now = (Get-Date)
    )

    $sorted = @(Get-SnakeOptimizerAgentSortedAlerts -Alerts $Alerts)

    $text = $(
        if ($null -ne $PausedUntil) { "SnakeOptimizer: avisos pausados até $(Format-SnakeOptimizerAgentPauseEnd -Until ([datetime]$PausedUntil) -Now $Now)" }
        elseif (-not $FirstReading) { "SnakeOptimizer: conferindo o PC..." }
        elseif ($sorted.Count -eq 0) { "SnakeOptimizer: nada pedindo atenção" }
        elseif ($sorted.Count -eq 1) { "SnakeOptimizer: $($sorted[0].Title)" }
        else { "SnakeOptimizer: $($sorted[0].Title) e mais $(Format-SnakeOptimizerCount -Count ($sorted.Count - 1) -One 'aviso' -Many 'avisos')" }
    )

    if ($text.Length -gt 63) { $text = $text.Substring(0, 60).TrimEnd() + "..." }

    return $text
}


function Get-SnakeOptimizerAgentPauseNotice {
    # O balão que confirma a pausa: até quando e como retomar antes.
    param (
        [Parameter(Mandatory)][datetime]$Until,
        [datetime]$Now = (Get-Date)
    )

    return "O SnakeOptimizer volta a avisar $(Format-SnakeOptimizerAgentPauseEnd -Until $Until -Now $Now). Para retomar antes, use o menu do ícone."
}


function New-SnakeOptimizerAgentAlert {
    param (
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Text,
        [string]$Action = "",
        [ValidateSet("Info", "Warning")][string]$Level = "Warning"
    )

    return [PSCustomObject]@{ Id = $Id; Title = $Title; Text = $Text; Action = $Action; Level = $Level }
}


function Get-SnakeOptimizerAgentReading {
    <#
    Lê uma das conferências e devolve o aviso que ela pede, ou $null se está tudo bem. Nunca lança erro: uma leitura que
    falha não avisa nada (o monitor não pode virar uma fonte de alarmes falsos).
    #>
    param ([Parameter(Mandatory)][string]$Id)

    try {
        switch ($Id) {
            "disk" {
                $space = Get-SnakeOptimizerSystemDriveSpace
                if ($null -eq $space) { return $null }

                $level = Get-SnakeOptimizerDiskSpaceLevel -FreeBytes $space.FreeBytes -TotalBytes $space.TotalBytes
                if ($level -notin @("Low", "Critical")) { return $null }

                # O disco pelo nome que a pessoa vê no Explorador (C:), e qual é: o do Windows.
                $drive = $(if ([string]$env:SystemRoot -match '^([A-Za-z]:)') { $Matches[1].ToUpperInvariant() } else { "C:" })

                return (New-SnakeOptimizerAgentAlert -Id "disk" -Title "Pouco espaço no disco $drive" -Text "Restam $(Format-SnakeOptimizerBytes -Bytes $space.FreeBytes) livres no disco do Windows ($drive). Clique para fazer uma limpeza rápida." -Action "cleanup.quick")
            }
            "diskhealth" {
                # Um disco que o Windows marca com problema, ou com erros não corrigidos, saúde baixa ou desgaste alto
                # (as notas da Saúde dos discos). A temperatura sozinha não avisa: ela varia com o uso.
                $bad = @(Get-SnakeOptimizerDiskHealth | Where-Object {
                        ([string]$_.HealthStatus -in @("Warning", "Unhealthy", "1", "2")) -or @(@($_.Notes) | Where-Object { [string]$_ -notlike "Temperatura*" }).Count -gt 0
                    })
                if ($bad.Count -eq 0) { return $null }

                $disk = $bad[0]
                $drives = @(Get-SnakeOptimizerJsonValue -Object $disk -Name "Drives" -Default @())
                $where = $(if ($drives.Count -gt 0) { " ($(Join-SnakeOptimizerList -Items $drives))" } else { "" })
                $note = @(@($disk.Notes) | Where-Object { [string]$_ -notlike "Temperatura*" }) | Select-Object -First 1
                $why = $(if ($note) { " $note." } else { " O Windows marcou o disco com problema." })

                return (New-SnakeOptimizerAgentAlert -Id "diskhealth" -Title "Disco dando sinais de falha" -Text "$($disk.Name)$where.$why Faça backup dos arquivos importantes. Clique para ver." -Action "diagnostics.disk-health")
            }
            "memory" {
                # RAM em uso acima de 90% por alguns minutos seguidos: um pico passageiro (abrir um programa) não avisa.
                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $total = [double]$os.TotalVisibleMemorySize
                if ($total -le 0) { return $null }
                $used = [int][Math]::Round((1 - ([double]$os.FreePhysicalMemory / $total)) * 100)

                if ($used -lt $script:SnakeOptimizerAgentMemoryLimit) { $script:SnakeOptimizerAgentMemoryHigh = 0; return $null }
                $script:SnakeOptimizerAgentMemoryHigh++
                if ($script:SnakeOptimizerAgentMemoryHigh -lt 3) { return $null }

                # O programa que mais ocupa (somando as janelas e abas do mesmo programa, como o Chrome).
                $top = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @("Memory Compression", "System", "Idle", "Registry", "vmmem", "vmmemWSL") } |
                    Group-Object -Property Name | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Bytes = ($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum; Label = (@($_.Group | Where-Object { $_.Description } | Select-Object -First 1).Description) } } |
                    Sort-Object Bytes -Descending | Select-Object -First 1
                $who = $(if ($top) { " O que mais usa: $(if ($top.Label) { $top.Label } else { $top.Name }) ($(Format-SnakeOptimizerBytes -Bytes $top.Bytes))." } else { "" })

                return (New-SnakeOptimizerAgentAlert -Id "memory" -Title "Memória quase cheia ($used%)" -Text "A memória RAM está em $used% faz alguns minutos e o PC pode ficar lento.$who Clique para liberar memória." -Action "performance.memory")
            }
            "reboot" {
                if (-not (Test-SnakeOptimizerPendingReboot)) { return $null }

                return (New-SnakeOptimizerAgentAlert -Id "reboot" -Title "Reinício pendente" -Text "O Windows espera o PC reiniciar para terminar uma atualização ou mudança. Clique para ver o motivo." -Action "diagnostics.pending-reboot" -Level Info)
            }
            "maintenance" {
                # A mesma conta do Início (Get-SnakeOptimizerLastCare): uma data no futuro não cala o lembrete. Registros que
                # existem, mas não puderam ser lidos, não viram "ainda não verificou": sem leitura, sem aviso.
                $latest = $null

                try { $latest = (Get-SnakeOptimizerLastCare -Strict).Latest }
                catch { return $null }

                if ($null -ne $latest -and ((Get-Date) - $latest).TotalDays -lt 30) { return $null }

                # Sem nenhuma verificação ainda, "faz mais de um mês" não seria verdade (como no Início: "ainda não verificado").
                $text = $(if ($null -eq $latest) { "O SnakeOptimizer ainda não verificou este PC. Clique para verificar." } else { "Faz mais de um mês sem verificação. Clique para verificar o PC." })

                return (New-SnakeOptimizerAgentAlert -Id "maintenance" -Title "Hora de cuidar do PC" -Text $text -Action "maintenance.checkup" -Level Info)
            }
            "protection" {
                $protection = Get-SnakeOptimizerSecurityStatus
                if ($null -eq $protection) { return $null }

                $antivirus = $protection.Antivirus

                if ($null -ne $protection.Threats -and @($protection.Threats).Count -gt 0) {
                    return (New-SnakeOptimizerAgentAlert -Id "protection" -Title "Ameaça encontrada" -Text "O antivírus encontrou uma ameaça que ainda está ativa. Clique para ver." -Action "security.status")
                }

                if ($antivirus.Mode -eq "Off") {
                    return (New-SnakeOptimizerAgentAlert -Id "protection" -Title "PC sem antivírus ativo" -Text "Nenhum antivírus está protegendo o PC. Clique para ver." -Action "security.status")
                }

                if ($antivirus.Mode -eq "Active" -and $antivirus.RealTime -eq $false) {
                    return (New-SnakeOptimizerAgentAlert -Id "protection" -Title "Proteção em tempo real desligada" -Text "O Windows Defender não está vigiando os arquivos abertos. Clique para ver." -Action "security.status")
                }

                return $null
            }
            "windows" {
                $support = Get-SnakeOptimizerWindowsSupportStatus
                $issue = Get-SnakeOptimizerWindowsSupportIssue -Status $support

                if ($null -eq $issue -or $support.State -eq "Esu") { return $null }

                # Uma leitura que não confirmou o ESU não vira aviso: o monitor só avisa do que sabe.
                if ($support.State -eq "EsuAvailable" -and -not [bool](Get-SnakeOptimizerJsonValue -Object $support -Name "EsuChecked" -Default $true)) { return $null }

                # Sem atualizações de segurança (o ponto grave da nota) o título diz isso; perto do fim, só "Suporte do Windows".
                $title = $(if ([int]$issue.Weight -ge 20) { "Windows sem atualizações de segurança" } else { "Suporte do Windows" })

                return (New-SnakeOptimizerAgentAlert -Id "windows" -Title $title -Text "$($issue.Text). Clique para ver o que fazer." -Action "diagnostics.windows-support")
            }
            "programs" {
                # Numa conexão limitada (plano de dados) ou na bateria, o monitor não consulta a internet por conta própria.
                if ((Test-SnakeOptimizerMeteredConnection) -or (Test-SnakeOptimizerOnBattery)) { return $null }
                if (-not (Test-SnakeOptimizerWinget)) { return $null }

                $upgrade = Invoke-SnakeOptimizerCapture -FilePath "winget" -Arguments @("upgrade", "--accept-source-agreements")

                if (Test-SnakeOptimizerWingetNoUpgradeOutput -OutputText $upgrade.Text -ExitCode $upgrade.ExitCode) { return $null }

                $count = @(Remove-SnakeOptimizerWingetIgnoredPackages -Packages @(ConvertFrom-SnakeOptimizerWingetTable -Lines $upgrade.Lines)).Count
                if ($count -lt 3) { return $null }

                return (New-SnakeOptimizerAgentAlert -Id "programs" -Title "Programas desatualizados" -Text "$(Format-SnakeOptimizerCount -Count $count -One 'programa tem' -Many 'programas têm') versão nova. Clique para atualizar." -Action "updates.winget" -Level Info)
            }
            "catalog" {
                if ((Test-SnakeOptimizerMeteredConnection) -or (Test-SnakeOptimizerOnBattery)) { return $null }
                if (Test-SnakeOptimizerCatalogStale -Days 7) { [void](Update-SnakeOptimizerCatalog) }
                return $null
            }
        }
    }
    catch {
        Write-Verbose "Monitor, ${Id}: $($_.Exception.Message)"
    }

    return $null
}


function Get-SnakeOptimizerAgentDueChecks {
    # As conferências que já passaram da hora, separadas em leves (rodam na hora) e pesadas (em segundo plano).
    param (
        [Parameter(Mandatory)][hashtable]$State,
        [datetime]$Now = (Get-Date)
    )

    return @(Get-SnakeOptimizerAgentChecks | Where-Object { Test-SnakeOptimizerAgentDue -Last $State.Checked[$_.Id] -Minutes $_.EveryMinutes -Now $Now })
}


function Select-SnakeOptimizerAgentAlerts {
    # Dos avisos lidos, os que podem aparecer agora: não pausados e não repetidos antes do intervalo da conferência.
    param (
        [AllowEmptyCollection()][object[]]$Alerts = @(),
        [Parameter(Mandatory)][hashtable]$State,
        [datetime]$Now = (Get-Date),
        [bool]$Paused = $false
    )

    if ($Paused) { return @() }

    $checks = @{}
    foreach ($check in (Get-SnakeOptimizerAgentChecks)) { $checks[$check.Id] = $check }

    return @(
        foreach ($alert in @($Alerts | Where-Object { $null -ne $_ })) {
            $repeat = $(if ($checks.ContainsKey($alert.Id)) { [double]$checks[$alert.Id].RepeatHours } else { 24 })
            if (Test-SnakeOptimizerAgentDue -Last $State.Shown[$alert.Id] -Minutes ($repeat * 60) -Now $Now) { $alert }
        }
    )
}


# ---------------------------------------------------------------------------
# Tela (Sobre o SnakeOptimizer > Monitor na bandeja)
# ---------------------------------------------------------------------------

function Set-SnakeOptimizerMonitor {
    $title = "Monitor na bandeja"

    Enter-SnakeOptimizerAction -Title $title

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title

    try {
        $runState = Get-SnakeOptimizerAgentRunState
        $enabled = ($runState -eq "On")
        $running = (@(Get-SnakeOptimizerAgentProcesses).Count -gt 0)
        $mismatch = Test-SnakeOptimizerAgentStartBlocked
        $pausedUntil = Get-SnakeOptimizerAgentPausedUntil

        $startText = switch ($runState) {
            "On" { "sim" }
            "Elsewhere" { "não: foi ligado de outra pasta do SnakeOptimizer; Ligar o monitor passa a usar esta" }
            "Disabled" { "não: desligado em Configurações, Aplicativos, Inicialização (ou no Gerenciador de Tarefas); Ligar o monitor religa" }
            default { "não" }
        }

        Write-SnakeOptimizerKeyValue -Label "Começa com o Windows" -Value $startText
        Write-SnakeOptimizerKeyValue -Label "Aberto agora" -Value $(if ($running) { "sim" } else { "não" })
        if ($null -ne $pausedUntil) { Write-SnakeOptimizerKeyValue -Label "Avisos" -Value "pausados até $(Format-SnakeOptimizerAgentPauseEnd -Until $pausedUntil)" }
        Write-Host ""

        # Os avisos: disco enchendo, proteção desligada, reinício ou manutenção faltando, Windows sem suporte e programas
        # desatualizados. Pelo menu do ícone dá para ver os avisos, verificar, acelerar e limpar o PC, ou pausar os avisos.
        Write-SnakeOptimizerStatus -Type Info -Message "O monitor fica perto do relógio e avisa quando o PC precisa de cuidado; nada muda sem você clicar."

        # Com a conta de outro Administrador, ligar gravaria o monitor no perfil dele: não oferece.
        if ($mismatch) {
            Write-SnakeOptimizerStatus -Type Warning -Message "O SnakeOptimizer está aberto com a conta de outro Administrador. Para ligar ou desligar o monitor na sua conta, $(Get-SnakeOptimizerUnelevatedHint)."
        }

        Write-Host ""

        $options = @()

        if ($mismatch) {
            # Só informa.
        }
        elseif ($enabled) {
            $options += @{ Key = "D"; Label = "Desligar o monitor"; Description = "Fecha o ícone e não abre mais com o Windows" }
            if (-not $running) { $options += @{ Key = "A"; Label = "Abrir agora"; Description = "Ele está configurado, mas não está aberto" } }
        }
        else {
            $options += @{ Key = "L"; Label = "Ligar o monitor"; Description = "Abre agora e passa a abrir com o Windows"; Accent = $true }
            if ($running -or $runState -ne "Off") { $options += @{ Key = "D"; Label = "Desligar o monitor"; Description = "Fecha o ícone e tira a entrada que sobrou" } }
        }

        # A pausa (do menu do ícone) também se desfaz daqui.
        if ($null -ne $pausedUntil -and -not $mismatch) {
            $options += @{ Key = "R"; Label = "Retomar os avisos"; Description = "Os avisos voltam na próxima conferência" }
        }

        $options += @{ Key = "X"; Label = "Voltar"; Exit = $true }

        $answer = Read-SnakeOptimizerChoice -Message "O que deseja fazer?" -Options $options -DefaultKey "X" -ShowMenu -TextPrompt "Opção (0 ou Enter = voltar)"

        switch ($answer) {
            "L" {
                $open = Enable-SnakeOptimizerAgent
                [void](Add-SnakeOptimizerChange -Action "Monitor na bandeja" -Text "ligado (abre com o Windows)")

                if ($open -eq "Open") {
                    Write-SnakeOptimizerStatus -Type Success -Message "Monitor ligado; se o ícone não aparecer, ele está na setinha (^) ao lado do relógio."
                    $final = Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Ok -Detail "monitor ligado" -Title $title) `
                        -Headline "Monitor ligado" -Note "Se o ícone não aparecer, ele está na setinha (^) ao lado do relógio."
                }
                elseif ($open -eq "Later") {
                    Write-SnakeOptimizerStatus -Type Success -Message "Monitor ligado; o ícone aparece em instantes ou na próxima entrada no Windows."
                    $final = Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Ok -Detail "monitor ligado; o ícone aparece em instantes ou na próxima entrada no Windows" -Title $title) `
                        -Headline "Monitor ligado" -Note "O ícone aparece em instantes ou na próxima entrada no Windows."
                }
                else {
                    Write-SnakeOptimizerStatus -Type Warning -Message "Monitor ligado, mas o Windows não deixou abri-lo agora: ele abre sozinho na próxima vez que você entrar no Windows."
                    $final = Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Warning -Detail "monitor ligado, mas não abriu agora; abre na próxima entrada no Windows" -Title $title) `
                        -Headline "Monitor ligado, mas não abriu agora" -Note "Ele abre sozinho na próxima vez que você entrar no Windows."
                }
            }
            "D" {
                $closed = Disable-SnakeOptimizerAgent
                [void](Add-SnakeOptimizerChange -Action "Monitor na bandeja" -Text "desligado")

                if ($closed) {
                    Write-SnakeOptimizerStatus -Type Success -Message "Monitor desligado."
                    $final = Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Ok -Detail "monitor desligado" -Title $title) `
                        -Headline "Monitor desligado" -Note $(if ($running) { "O ícone fechou e não abre mais com o Windows." } else { "Ele não abre mais com o Windows." })
                }
                else {
                    Write-SnakeOptimizerStatus -Type Warning -Message "O monitor não abre mais com o Windows, mas o ícone aberto não fechou: feche pelo menu dele, em Fechar o monitor."
                    $final = Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Warning -Detail "o ícone aberto não fechou; feche pelo menu dele" -Title $title) `
                        -Headline "O ícone do monitor não fechou" -Note "Ele não abre mais com o Windows; feche o ícone pelo menu dele, em Fechar o monitor."
                }
            }
            "A" {
                if (Start-SnakeOptimizerAgent) {
                    Write-SnakeOptimizerStatus -Type Success -Message "Monitor aberto; se o ícone não aparecer, ele está na setinha (^) ao lado do relógio."
                    $final = Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Ok -Detail "monitor aberto" -Title $title) `
                        -Headline "Monitor aberto" -Note "Se o ícone não aparecer, ele está na setinha (^) ao lado do relógio."
                }
                else {
                    Write-SnakeOptimizerStatus -Type Warning -Message "O ícone não apareceu agora; ele abre sozinho na próxima entrada no Windows."
                    $final = Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Warning -Detail "o ícone não apareceu agora; abre na próxima entrada no Windows" -Title $title) `
                        -Headline "O ícone não apareceu agora" -Note "Ele abre sozinho na próxima vez que você entrar no Windows."
                }
            }
            "R" {
                Set-SnakeOptimizerAgentPause -Hours 0
                Write-SnakeOptimizerStatus -Type Success -Message "Avisos retomados."
                $final = Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Ok -Detail "avisos retomados" -Title $title) `
                    -Headline "Avisos retomados" -Note "Eles voltam na próxima conferência do monitor."
            }
            default {
                # Voltar sem mudar nada é "Cancelado", como nas outras telas de escolha; com a conta de outro Administrador não
                # havia o que escolher, então é "Nada a fazer", com o motivo.
                if ($mismatch) {
                    $final = New-SnakeOptimizerResult -Kind Skipped -Detail "com a conta de outro Administrador, o monitor só muda com o SnakeOptimizer aberto sem Administrador" -Title $title
                }
                else {
                    $final = New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title
                }
            }
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível mudar o monitor: $($_.Exception.Message.TrimEnd('.'))."
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message.TrimEnd('.') -Title $title
    }

    Exit-SnakeOptimizerAction -Result $final
}


Export-ModuleMember -Function *
