# Gerenciar o que abre junto com o Windows, sem sair do SnakeOptimizer. Desativar aqui é exatamente o que o Gerenciador de
# Tarefas e as Configurações fazem, então o item continua listado neles e pode ser reativado em qualquer lugar:
# - chaves Run e pastas Inicializar: o valor binário de 12 bytes em StartupApproved (a entrada Run e o atalho ficam
#   intactos; nada é apagado);
# - aplicativos da Store (Teams, Spotify, WhatsApp...): o State da tarefa de inicialização do pacote (1 = desativado
#   pela pessoa, 2 = ativado), como as Configurações gravam;
# - tarefas agendadas de outros fabricantes que só rodam ao entrar no Windows ou ao ligar o PC: desativadas no
#   Agendador de Tarefas, de onde também podem ser reativadas.
# Depois de cada mudança, o estado é lido de novo no Windows: só conta como feito o que o Windows manteve. A lista mostra
# só o que o SnakeOptimizer consegue mudar agora (veja Set-SnakeOptimizerStartupItems); o texto na tela fica curto de propósito.

$script:SnakeOptimizerStartupTaskSource = "Tarefa agendada"
$script:SnakeOptimizerStartupAppSource = "Aplicativo da Store"


function New-SnakeOptimizerStartupApprovedValue {
    # Os 12 bytes de StartupApproved: primeiro byte 02 = ativado; 03 = desativado, seguido da hora (FILETIME, 8 bytes)
    # em que foi desativado.
    param (
        [Parameter(Mandatory)]
        [bool]$Enabled,

        [datetime]$At = [datetime]::UtcNow
    )

    $bytes = New-Object byte[] 12

    if ($Enabled) {
        $bytes[0] = 2
        return , $bytes
    }

    $bytes[0] = 3
    $stamp = [BitConverter]::GetBytes([int64]$At.ToUniversalTime().ToFileTimeUtc())

    for ($i = 0; $i -lt 8; $i++) {
        $bytes[4 + $i] = $stamp[$i]
    }

    return , $bytes
}


function Set-SnakeOptimizerStartupItemEnabled {
    # Liga ou desliga um item (objeto de Get-SnakeOptimizerStartupItems). Itens de todos os usuários pedem Administrador.
    param (
        [Parameter(Mandatory)]
        $Item,

        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    if ($Item.Scope -eq "Machine" -and -not (Test-SnakeOptimizerAdministrator)) {
        throw "este item vale para todos os usuários e exige Administrador"
    }

    # Elevado com outra conta, o HKCU, a pasta Inicializar e as tarefas "da própria conta" são os dessa conta, não os da
    # pessoa logada: mudar ali seria mexer no perfil errado.
    if ($Item.Scope -eq "User" -and (Test-SnakeOptimizerStartupOtherAccount)) {
        throw "este item vale só para uma conta, e o SnakeOptimizer está elevado com outra conta"
    }

    if ([string]$Item.Source -eq $script:SnakeOptimizerStartupTaskSource) {
        $taskPath = [string](Get-SnakeOptimizerJsonValue -Object $Item -Name "TaskPath" -Default "\")
        $taskName = [string](Get-SnakeOptimizerJsonValue -Object $Item -Name "TaskName" -Default $Item.Name)

        if ($Enabled) { [void](Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop) }
        else { [void](Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop) }

        return
    }

    if ([string]$Item.Source -eq $script:SnakeOptimizerStartupAppSource) {
        $path = [string]$Item.ApprovedPath

        if (-not (Test-SnakeOptimizerStartupAppPath -Path $path)) {
            throw "não foi possível localizar onde o Windows guarda o estado deste item"
        }

        # Confere antes de gravar: a tarefa pode ter sumido (o aplicativo foi desinstalado) ou passado para uma política
        # (3 e 4), que só o administrador muda; gravar por cima disso seria um ajuste de mentira.
        $current = Get-SnakeOptimizerRegistryValueOrNull -Path $path -Name "State"

        if ($null -eq $current) { throw "o Windows não tem mais este item" }
        if (-not ($current -is [int]) -or @(0, 1, 2) -notcontains [int]$current) { throw "uma política do Windows controla este item" }

        # 1 = desativado pela pessoa, o mesmo que o Gerenciador de Tarefas grava: o aplicativo não consegue se religar
        # sozinho. 2 = ativado.
        Set-SnakeOptimizerRegistryDWord -Path $path -Name "State" -Value $(if ($Enabled) { 2 } else { 1 })

        return
    }

    if ([string]::IsNullOrWhiteSpace($Item.ApprovedPath)) {
        throw "não foi possível localizar onde o Windows guarda o estado deste item"
    }

    Set-SnakeOptimizerRegistryBinary -Path $Item.ApprovedPath -Name $Item.Name -Value (New-SnakeOptimizerStartupApprovedValue -Enabled $Enabled)
}


function Test-SnakeOptimizerStartupAppPath {
    # Se o caminho é a chave de uma tarefa de inicialização de aplicativo da Store (SystemAppData\<família>\<tarefa>) da
    # conta. O Histórico de mudanças guarda o caminho num arquivo que qualquer programa da conta grava: só isto é aceito.
    param ([AllowEmptyString()][string]$Path)

    $root = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\"
    $text = [string]$Path

    if (-not $text.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

    return ($text.Substring($root.Length) -match '^[^\\]+\\[^\\]+$')
}


function Test-SnakeOptimizerStartupOtherAccount {
    # Se o SnakeOptimizer está elevado com uma conta diferente da que está logada no Windows.
    try {
        return [bool](Get-SnakeOptimizerJsonValue -Object (Get-SnakeOptimizerSessionInfo) -Name "UserMismatch" -Default $false)
    }
    catch {
        return $false
    }
}


function Get-SnakeOptimizerStartupItemEnabled {
    <#
    Lê no Windows se um item está ligado, procurando só ele: a tarefa pelo caminho e pelo nome (duas tarefas podem ter o
    mesmo nome em pastas diferentes), o aplicativo da Store pela chave da tarefa dele e os demais pelo valor deles em
    StartupApproved (as pastas Inicializar do usuário e de todos os usuários têm a mesma origem, "Pasta Inicializar").
    $null quando não dá para ler.
    #>
    param (
        [Parameter(Mandatory)]
        $Item
    )

    if ([string]$Item.Source -eq $script:SnakeOptimizerStartupTaskSource) {
        $taskPath = [string](Get-SnakeOptimizerJsonValue -Object $Item -Name "TaskPath" -Default "\")
        $taskName = [string](Get-SnakeOptimizerJsonValue -Object $Item -Name "TaskName" -Default $Item.Name)

        try {
            $task = @(Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop) | Select-Object -First 1
        }
        catch {
            return $null
        }

        if ($null -eq $task) {
            return $null
        }

        return ([string]$task.State -ne "Disabled")
    }

    # Aplicativo da Store: o State da tarefa (2 = ativado, 4 = ativado por política; o resto não abre).
    if ([string]$Item.Source -eq $script:SnakeOptimizerStartupAppSource) {
        if (-not (Test-SnakeOptimizerStartupAppPath -Path ([string]$Item.ApprovedPath))) { return $null }

        $state = Get-SnakeOptimizerRegistryValueOrNull -Path ([string]$Item.ApprovedPath) -Name "State"

        if (-not ($state -is [int])) { return $null }

        return (@(2, 4) -contains [int]$state)
    }

    if ([string]::IsNullOrWhiteSpace([string]$Item.ApprovedPath)) {
        return $null
    }

    # Sem valor em StartupApproved, o Windows considera o item ligado; primeiro byte ímpar = desligado.
    $approved = Get-SnakeOptimizerRegistryValues -Path $Item.ApprovedPath
    $name = [string]$Item.Name

    if (-not $approved.Contains($name)) {
        return $true
    }

    $bytes = @($approved[$name])

    return -not ($bytes.Count -gt 0 -and ([int]$bytes[0] -band 1) -eq 1)
}


function Get-SnakeOptimizerStartupAccountKind {
    <#
    De quem é uma conta de tarefa agendada (o dono da tarefa ou o usuário de um gatilho de logon): "Current" (a conta
    que roda o SnakeOptimizer), "Other" (outra pessoa deste PC ou do domínio: SID S-1-5-21-...) ou "Shared" (vazio, SYSTEM,
    serviços, grupos como Usuários).
    #>
    param (
        [AllowEmptyString()][string]$Account,
        [AllowEmptyString()][string]$User,
        [AllowEmptyString()][string]$Sid
    )

    $text = ([string]$Account).Trim()

    if (-not $text) { return "Shared" }

    if (($Sid -and $text -eq $Sid) -or ($User -and ($text -eq $User -or $text.EndsWith("\$User", [System.StringComparison]::OrdinalIgnoreCase)))) {
        return "Current"
    }

    $accountSid = $text

    if ($text -notmatch '^S-1-[0-9-]+$') {
        try {
            $accountSid = (New-Object System.Security.Principal.NTAccount -ArgumentList $text).Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            $accountSid = ""
        }
    }

    if ($accountSid -like "S-1-5-21-*") {
        return $(if ($Sid -and $accountSid -eq $Sid) { "Current" } else { "Other" })
    }

    return "Shared"
}


function Get-SnakeOptimizerStartupTasks {
    <#
    As tarefas agendadas que não são do Windows e rodam ao entrar no Windows (gatilho de logon) ou ao ligar o PC (gatilho
    de inicialização), no formato dos itens de Get-SnakeOptimizerStartupItems, com TaskPath e TaskName. Sem acesso ao
    Agendador, nenhuma. Ficam de fora:
    - as da pasta \Microsoft\: são do próprio Windows;
    - as que também rodam em outros horários (todo dia, a cada hora...), como a maioria dos atualizadores: desativar a
      tarefa pararia tudo, não só a inicialização, e o programa deixaria de se atualizar. Já desativadas, continuam na
      lista, para poderem ser reativadas (também pelo Histórico de mudanças);
    - as de outra pessoa do PC (dona da tarefa ou única conta dos gatilhos de logon): mexer seria mudar o perfil dela;
    - as que abrem um arquivo que com certeza não existe mais: não abrem nada.
    Gatilhos desligados não contam.
    #>
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop)
    }
    catch {
        return @()
    }

    $user = [string]$env:USERNAME
    $sid = ""

    try { $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $sid = "" }

    $items = @()

    foreach ($task in $tasks) {
        if ($null -eq $task) { continue }

        $path = [string]$task.TaskPath

        if ($path -like "\Microsoft\*") { continue }

        $atStart = @()
        $otherTriggers = 0
        $othersOnly = $true

        foreach ($trigger in @($task.Triggers | Where-Object { $null -ne $_ })) {
            if (-not [bool](Get-SnakeOptimizerJsonValue -Object $trigger -Name "Enabled" -Default $true)) { continue }

            $class = ""
            try { $class = [string]$trigger.CimClass.CimClassName } catch { $class = "" }

            if ($class -ne "MSFT_TaskLogonTrigger" -and $class -ne "MSFT_TaskBootTrigger") {
                $otherTriggers++
                continue
            }

            $atStart += $trigger

            # Um gatilho de logon só de outra pessoa não abre nada quando esta conta entra.
            $triggerUser = [string](Get-SnakeOptimizerJsonValue -Object $trigger -Name "UserId" -Default "")

            if ($class -eq "MSFT_TaskBootTrigger" -or (Get-SnakeOptimizerStartupAccountKind -Account $triggerUser -User $user -Sid $sid) -ne "Other") {
                $othersOnly = $false
            }
        }

        if ($atStart.Count -eq 0 -or $othersOnly) { continue }

        $state = [string]$task.State

        if ($otherTriggers -gt 0 -and $state -ne "Disabled") { continue }

        $owner = ""
        try { $owner = [string]$task.Principal.UserId } catch { $owner = "" }
        $ownerKind = Get-SnakeOptimizerStartupAccountKind -Account $owner -User $user -Sid $sid

        if ($ownerKind -eq "Other") { continue }

        $action = @($task.Actions | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string](Get-SnakeOptimizerJsonValue -Object $_ -Name "Execute" -Default "")) }) | Select-Object -First 1
        $execute = $(if ($null -ne $action) { ([string]$action.Execute).Trim() } else { "" })
        $command = $(if ($null -ne $action) { ("$execute $([string](Get-SnakeOptimizerJsonValue -Object $action -Name 'Arguments' -Default ''))").Trim() } else { "" })

        if ($execute -and (Test-SnakeOptimizerStartupTargetMissing -Command ('"' + $execute.Trim('"') + '"'))) { continue }

        # Tarefa da própria conta: a pessoa consegue ligar e desligar sem Administrador; as demais pedem.
        $scope = $(if ($ownerKind -eq "Current") { "User" } else { "Machine" })

        $items += [PSCustomObject]@{
            Name = [string]$task.TaskName; Source = $script:SnakeOptimizerStartupTaskSource; Enabled = ($state -ne "Disabled")
            Command = $command; Scope = $scope; ApprovedPath = ""; TaskPath = $path; TaskName = [string]$task.TaskName
        }
    }

    return @($items)
}


function Get-SnakeOptimizerStartupPublisher {
    # Quem publica o programa de um item (CompanyName do executável): "Google LLC", "Microsoft Corporation". Vazio se não
    # der para saber. Atalhos da pasta Inicializar são seguidos até o programa.
    param ([Parameter(Mandatory)]$Item)

    try {
        $command = [string]$Item.Command

        if ([string]$Item.Source -eq "Pasta Inicializar" -and $command -like "*.lnk") {
            $link = Get-SnakeOptimizerShortcutTarget -Path $command
            $command = $(if ($null -ne $link) { [string]$link.TargetPath } else { "" })
        }

        $path = Get-SnakeOptimizerCommandTargetPath -Command $command

        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return "" }

        return ([string](Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo.CompanyName).Trim()
    }
    catch {
        return ""
    }
}


function Get-SnakeOptimizerStartupAdvice {
    <#
    O conselho que vai na descrição de um item quando a pessoa escolhe o que desativar: "antivírus; deixe ligado", "do
    Windows; melhor deixar ligado" (o programa fica na pasta do Windows) ou "do hardware do PC; na dúvida, deixe ligado"
    (som, touchpad, vídeo: os fabricantes mais comuns). "" para os outros.
    #>
    param ([Parameter(Mandatory)]$Item)

    $publisher = [string](Get-SnakeOptimizerJsonValue -Object $Item -Name "Publisher" -Default "")
    $name = [string](Get-SnakeOptimizerJsonValue -Object $Item -Name "Name" -Default "")
    $who = "$publisher $name"

    if ($who -match '(?i)\b(Avast|AVG|Kaspersky|Norton|NortonLifeLock|Gen Digital|McAfee|ESET|Bitdefender|Avira|Trend Micro|Sophos|Malwarebytes|Panda Security|F-Secure|Webroot)\b') {
        return "antivírus; deixe ligado"
    }

    $windows = $(if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) { $env:WINDIR } else { [string]$env:SystemRoot })
    $command = ([Environment]::ExpandEnvironmentVariables([string](Get-SnakeOptimizerJsonValue -Object $Item -Name "Command" -Default ""))).Trim().TrimStart('"')

    if (-not [string]::IsNullOrWhiteSpace($windows) -and $command.StartsWith($windows.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return "do Windows; melhor deixar ligado"
    }

    if ($publisher -match '(?i)\b(Realtek|Synaptics|ELAN|Intel|NVIDIA|Advanced Micro Devices|AMD|Dolby|Conexant|Cirrus Logic|Waves|Alps)\b') {
        return "do hardware do PC; na dúvida, deixe ligado"
    }

    return ""
}


function Get-SnakeOptimizerStartupEntries {
    # Tudo o que abre com o Windows para a tela Gerenciar inicialização: os itens das chaves Run, das pastas Inicializar e
    # dos aplicativos da Store, as tarefas agendadas de logon e de inicialização e, em cada um, quem publica o programa
    # (Publisher; o dos aplicativos da Store já vem do manifesto do pacote).
    $entries = @(@(Get-SnakeOptimizerStartupItems) + @(Get-SnakeOptimizerStartupTasks) | Where-Object { $null -ne $_ })

    foreach ($entry in $entries) {
        if ([string](Get-SnakeOptimizerJsonValue -Object $entry -Name "Publisher" -Default "")) { continue }

        $entry | Add-Member -NotePropertyName Publisher -NotePropertyValue (Get-SnakeOptimizerStartupPublisher -Item $entry) -Force
    }

    return @($entries)
}


function ConvertTo-SnakeOptimizerStartupUndoItem {
    # O que o Histórico de mudanças guarda de um item para devolvê-lo ao estado de antes (Enabled = como estava).
    param (
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][bool]$Enabled
    )

    return [ordered]@{
        Name         = [string]$Item.Name
        Source       = [string]$Item.Source
        Scope        = [string]$Item.Scope
        ApprovedPath = [string]$Item.ApprovedPath
        TaskPath     = [string](Get-SnakeOptimizerJsonValue -Object $Item -Name "TaskPath" -Default "")
        TaskName     = [string](Get-SnakeOptimizerJsonValue -Object $Item -Name "TaskName" -Default "")
        Enabled      = $Enabled
    }
}


function Test-SnakeOptimizerStartupUndoable {
    <#
    Se o desfazer do Histórico de mudanças sabe devolver este item (o de ConvertTo-SnakeOptimizerStartupUndoItem). Chaves Run,
    pastas Inicializar e tarefas, sim; um aplicativo da Store só quando o desfazer (Test-SnakeOptimizerStartupUndoItem) aceitar
    a chave dele. Perguntar ao desfazer, em vez de supor, evita anotar um desfazer que depois falharia.
    #>
    param ([Parameter(Mandatory)]$Undo)

    if ([string]$Undo["Source"] -ne $script:SnakeOptimizerStartupAppSource) { return $true }

    try {
        return [bool](Test-SnakeOptimizerStartupUndoItem -Item ([PSCustomObject]$Undo))
    }
    catch {
        return $false
    }
}


function Get-SnakeOptimizerStartupJournalText {
    # O texto da linha do Histórico de mudanças (Items: Name e Enabled, o estado novo): "Chat desativado", "2 itens
    # desativados: Chat e Nuvem" ou "1 desativado (Chat) e 1 reativado (Antigo)".
    param ([object[]]$Items = @())

    $off = @($Items | Where-Object { -not $_.Enabled } | ForEach-Object { [string]$_.Name })
    $on = @($Items | Where-Object { $_.Enabled } | ForEach-Object { [string]$_.Name })
    $all = @($off) + @($on)

    if ($all.Count -eq 1) { return "$($all[0]) $(if ($on.Count -gt 0) { 'reativado' } else { 'desativado' })" }
    if ($off.Count -gt 0 -and $on.Count -gt 0) { return (Get-SnakeOptimizerStartupChangeText -Off $off -On $on -Names) }

    return "$($all.Count) itens $(if ($on.Count -gt 0) { 'reativados' } else { 'desativados' }): $(Join-SnakeOptimizerList -Items $all)"
}


function Get-SnakeOptimizerStartupFileName {
    # O arquivo que um item abre ("steam.exe"), para a lista dizer o que é quando não se sabe quem publica. "" sem
    # comando e nos atalhos da pasta Inicializar (o nome do item já é o do arquivo).
    param ([Parameter(Mandatory)]$Item)

    $command = ([string](Get-SnakeOptimizerJsonValue -Object $Item -Name "Command" -Default "")).Trim()

    if (-not $command -or [string]$Item.Source -eq "Pasta Inicializar") { return "" }

    $target = Get-SnakeOptimizerCommandTargetPath -Command $command

    if (-not $target) {
        $target = $(if ($command.StartsWith('"')) { ($command.Substring(1) -split '"', 2)[0] } else { ($command -split '\s+', 2)[0] })
    }

    return ([string]($target -split '[\\/]')[-1]).Trim()
}


function Get-SnakeOptimizerStartupOptionText {
    # A descrição curta de um item na lista de marcar: quem publica (ou o arquivo que abre), "todos os usuários" quando
    # vale para o PC inteiro e, quando pedido (-Advice), o conselho de deixar ligado o que é do Windows, de hardware ou
    # antivírus. De onde o item abre (chave Run, pasta, tarefa) fica fora da tela: não ajuda a decidir.
    param (
        [Parameter(Mandatory)]$Item,
        [bool]$IsAdmin = $true,
        [switch]$Advice
    )

    $parts = @()
    $publisher = [string](Get-SnakeOptimizerJsonValue -Object $Item -Name "Publisher" -Default "")

    if ($publisher) { $parts += $publisher }
    else {
        $file = Get-SnakeOptimizerStartupFileName -Item $Item
        if ($file) { $parts += $file }
    }

    if ($Item.Scope -eq "Machine") { $parts += "todos os usuários" }
    if ($Item.Scope -eq "Machine" -and -not $IsAdmin) { $parts += "exige Administrador" }

    if ($Advice) {
        $text = Get-SnakeOptimizerStartupAdvice -Item $Item
        if ($text) { $parts = @($text) + $parts }
    }

    return ($parts -join " · ")
}


function Get-SnakeOptimizerStartupChangeText {
    # "2 desativados e 1 reativado" (com -Names, também os nomes: "2 desativados (A e B) e 1 reativado (C)").
    param (
        [string[]]$Off = @(),
        [string[]]$On = @(),
        [switch]$Names
    )

    $parts = @()

    foreach ($side in @(@{ Items = @($Off | Where-Object { $_ }); One = "desativado"; Many = "desativados" }, @{ Items = @($On | Where-Object { $_ }); One = "reativado"; Many = "reativados" })) {
        if ($side.Items.Count -eq 0) { continue }

        $text = Format-SnakeOptimizerCount -Count $side.Items.Count -One $side.One -Many $side.Many
        if ($Names) { $text += " ($(Join-SnakeOptimizerList -Items $side.Items))" }
        $parts += $text
    }

    return ($parts -join " e ")
}


function Read-SnakeOptimizerStartupReview {
    <#
    A lista da inicialização (na tela Gerenciar inicialização, -Standalone, e na revisão do Otimizar): uma lista só, com
    o que abre hoje já marcado. Desmarcar desativa, marcar reativa. Antes de mudar, a tela diz o que deixa de abrir e o
    que volta, e pergunta. Devolve as mudanças (Item e Enabled) ou $null
    quando nada muda (a lista cancelada, nenhuma diferença ou a pessoa disse não).
    #>
    param (
        [object[]]$Items = @(),
        [bool]$IsAdmin = $true,
        [switch]$Standalone
    )

    $pool = @($Items)

    # No menu de texto não há o que desmarcar: os números digitados são a lista inteira do que fica marcado. O conselho
    # de deixar ligado o antivírus, o que é do Windows e os drivers vem no próprio item, não numa linha à parte.
    if (Test-SnakeOptimizerGuiPrompts) {
        Write-SnakeOptimizerStatus -Type Info -Message "Marcado abre com o Windows. Desmarque o que não precisa abrir junto."
    }
    else {
        Write-SnakeOptimizerStatus -Type Info -Message "Com * é o que abre hoje. Digite os números de tudo o que deve abrir com o Windows: o que ficar de fora deixa de abrir. P deixa como está."
    }

    $choices = @(
        for ($i = 0; $i -lt $pool.Count; $i++) {
            @{ Key = [string]$i; Label = $pool[$i].Name; Description = (Get-SnakeOptimizerStartupOptionText -Item $pool[$i] -IsAdmin $IsAdmin -Advice:([bool]$pool[$i].Enabled)); Selected = [bool]$pool[$i].Enabled }
        }
    )

    # Sem "Marcar todos": reativaria de uma vez tudo o que a pessoa já tinha desativado. Desmarcar tudo é uma resposta
    # (nada abre com o Windows): a lista volta vazia, e não $null. Na tela avulsa os botões dizem Aplicar e Cancelar; no
    # Otimizar, ficam os do fluxo (desistir pula a etapa).
    $labels = @{}
    if ($Standalone) { $labels = @{ ConfirmLabel = "Aplicar"; CancelLabel = "Cancelar" } }

    $picked = Read-SnakeOptimizerMultiSelect -Message "O que deve abrir junto com o Windows" -Options $choices -NoSelectAll -AllowNone @labels

    if ($null -eq $picked) {
        return $null
    }

    $changes = @(
        for ($i = 0; $i -lt $pool.Count; $i++) {
            $want = (@($picked) -contains [string]$i)
            if ($want -ne [bool]$pool[$i].Enabled) { [PSCustomObject]@{ Item = $pool[$i]; Enabled = $want } }
        }
    )

    if ($changes.Count -eq 0) {
        return $null
    }

    $off = @($changes | Where-Object { -not $_.Enabled } | ForEach-Object { [string]$_.Item.Name })
    $on = @($changes | Where-Object { $_.Enabled } | ForEach-Object { [string]$_.Item.Name })

    Write-Host ""
    if ($off.Count -gt 0) { Write-SnakeOptimizerKeyValue -Label "Deixam de abrir" -Value (Join-SnakeOptimizerList -Items $off) }
    if ($on.Count -gt 0) { Write-SnakeOptimizerKeyValue -Label "Voltam a abrir" -Value (Join-SnakeOptimizerList -Items $on) }
    Write-Host ""

    # Com algo deixando de abrir, a resposta padrão no menu de texto é Não: um número trocado não desativa a lista. Na
    # janela, as caixas marcadas já são a escolha, e o padrão é Sim.
    $default = $(if ($off.Count -gt 0 -and -not (Test-SnakeOptimizerGuiPrompts)) { "N" } else { "S" })

    if (-not (Confirm-SnakeOptimizerAction "Aplicar estas mudanças na inicialização?" -DefaultKey $default)) {
        return $null
    }

    return @($changes)
}


function Set-SnakeOptimizerStartupItems {
    <#
    Desativa ou reativa o que abre com o Windows: uma lista só, com o que abre hoje já marcado. O que for desmarcado
    deixa de abrir, e o que for marcado volta a abrir. Sozinha, os botões dizem Aplicar e Cancelar; com -Review (a etapa
    do Otimizar), ficam os do fluxo.
    #>
    param (
        [switch]$Review
    )

    $title = "Gerenciar inicialização"

    if ($Review) {
        $title = "Revisar o que abre com o Windows"
    }

    Enter-SnakeOptimizerAction -Title $title

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title

    try {
        Write-Progress -Activity $title -Status "lendo o que abre com o Windows"

        try {
            $items = @(Get-SnakeOptimizerStartupEntries | Sort-Object -Property Name)
        }
        finally {
            Write-Progress -Activity $title -Completed
        }

        # A lista mostra só o que o SnakeOptimizer consegue mudar agora, para nenhuma marca ser de enfeite:
        # - elevado com outra conta, os itens de uma conta só (HKCU, pasta Inicializar, tarefas e aplicativos da conta) são
        #   os dessa conta, não os da pessoa logada: mudar ali seria mexer no perfil errado;
        # - sem Administrador, os de todos os usuários (HKLM, pasta Inicializar comum, tarefas do sistema) não podem ser
        #   gravados.
        # Nos dois casos, uma linha diz o que ficou de fora.
        $isAdmin = Test-SnakeOptimizerAdministrator
        $hidden = ""

        if (Test-SnakeOptimizerStartupOtherAccount) {
            if (@($items | Where-Object { $_.Scope -eq "User" }).Count -gt 0) {
                $hidden = "o SnakeOptimizer está elevado com outra conta"
                $user = [string](Get-SnakeOptimizerJsonValue -Object (Get-SnakeOptimizerSessionInfo) -Name "User" -Default "")
                Write-SnakeOptimizerStatus -Type Warning -Message "O SnakeOptimizer está elevado com outra conta ($user): só aparecem os itens de todos os usuários."
            }

            $items = @($items | Where-Object { $_.Scope -ne "User" })
        }

        if (-not $isAdmin) {
            $machine = @($items | Where-Object { $_.Scope -eq "Machine" }).Count

            if ($machine -gt 0) {
                $hidden = "os itens que abrem com o Windows exigem Administrador"
                Write-SnakeOptimizerStatus -Type Info -Message "$(Format-SnakeOptimizerCount -Count $machine -One 'item de todos os usuários só aparece' -Many 'itens de todos os usuários só aparecem') com o SnakeOptimizer aberto como Administrador."
            }

            $items = @($items | Where-Object { $_.Scope -ne "Machine" })
        }

        if ($items.Count -eq 0) {
            if ($hidden) {
                Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Skipped -Detail $hidden -Title $title)
                return
            }

            Write-SnakeOptimizerStatus -Type Info -Message "Nenhum programa está configurado para abrir junto com o Windows."
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Skipped -Detail "nenhum programa abre com o Windows" -Title $title)
            return
        }

        $enabled = @($items | Where-Object { $_.Enabled })
        $disabled = @($items | Where-Object { -not $_.Enabled })

        # Desativar não remove o programa (ele continua instalado, e o item continua no Gerenciador de Tarefas e em
        # Configurações, Aplicativos, Inicialização, de onde também pode ser reativado); a tela não precisa explicar isso.
        Write-SnakeOptimizerKeyValue -Label "Abrem com o Windows" -Value $enabled.Count
        Write-SnakeOptimizerKeyValue -Label "Desativados" -Value $disabled.Count
        Write-Host ""

        # Uma lista só, com tudo o que abre (ou abria) com o Windows: marcado abre, desmarcado não. Aplicar muda só o
        # que mudou de marca.
        $changes = Read-SnakeOptimizerStartupReview -Items $items -IsAdmin $isAdmin -Standalone:(-not $Review)

        if ($null -eq $changes) {
            Write-SnakeOptimizerStatus -Type Info -Message "Nada foi mudado."
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Skipped -Detail "você não mudou nada" -Title $title)
            return
        }

        $changed = 0
        $problems = @()
        $doneItems = @()
        $changedOff = @()
        $changedOn = @()

        foreach ($change in @($changes)) {
            $item = $change.Item
            $targetEnabled = [bool]$change.Enabled
            $done = $(if ($targetEnabled) { "reativado" } else { "desativado" })

            try {
                Set-SnakeOptimizerStartupItemEnabled -Item $item -Enabled $targetEnabled

                # Confere no Windows se o estado deste item (e não de outro com o mesmo nome) mudou de fato.
                $after = Get-SnakeOptimizerStartupItemEnabled -Item $item

                if ($null -ne $after -and [bool]$after -eq $targetEnabled) {
                    $changed++
                    $undo = ConvertTo-SnakeOptimizerStartupUndoItem -Item $item -Enabled (-not $targetEnabled)
                    $doneItems += [PSCustomObject]@{ Name = [string]$item.Name; Enabled = $targetEnabled; Undo = $undo; Undoable = (Test-SnakeOptimizerStartupUndoable -Undo $undo) }
                    if ($targetEnabled) { $changedOn += [string]$item.Name } else { $changedOff += [string]$item.Name }
                    Write-SnakeOptimizerStatus -Type Success -Message "$($item.Name): $done."
                }
                else {
                    $problems += [PSCustomObject]@{ Name = [string]$item.Name; Detail = "o Windows não manteve a mudança" }
                    Write-SnakeOptimizerStatus -Type Error -Message "$($item.Name): o Windows não manteve a mudança."
                }
            }
            catch {
                $problems += [PSCustomObject]@{ Name = [string]$item.Name; Detail = $_.Exception.Message.TrimEnd('.') }
                Write-SnakeOptimizerStatus -Type Error -Message "$($item.Name): $($_.Exception.Message.TrimEnd('.'))."
            }
        }

        Write-Host ""

        # "desativado" ou "reativado" quando a lista foi de um lado só (sempre, sem -Review); "mudado" quando a revisão
        # desativou uns e reativou outros.
        $sides = @(@($changes) | ForEach-Object { [bool]$_.Enabled } | Select-Object -Unique)
        $done = $(if ($sides.Count -gt 1) { "mudado" } elseif ($sides.Count -eq 1 -and $sides[0]) { "reativado" } else { "desativado" })

        if ($changed -gt 0) {
            # O que o Histórico de mudanças sabe desfazer vai numa linha com o desfazer; o resto (um item que o desfazer
            # recusaria, como um aplicativo da Store fora das chaves conhecidas), numa linha só de registro: um desfazer que
            # deixasse parte para trás diria que voltou tudo sem ter voltado.
            $undoable = @($doneItems | Where-Object { $_.Undoable })
            $plain = @($doneItems | Where-Object { -not $_.Undoable })

            if ($undoable.Count -gt 0) {
                [void](Add-SnakeOptimizerChange -Action "Inicialização" -Text (Get-SnakeOptimizerStartupJournalText -Items $undoable) -Undo @{ Kind = "startup"; Items = @($undoable | ForEach-Object { $_.Undo }) })
            }

            if ($plain.Count -gt 0) {
                [void](Add-SnakeOptimizerChange -Action "Inicialização" -Text (Get-SnakeOptimizerStartupJournalText -Items $plain))
            }

            $when = "Vale a partir da próxima vez que você entrar no Windows"
            Write-SnakeOptimizerStatus -Type Info -Message $(if ($undoable.Count -gt 0) { "$when. Para desfazer, use Manutenção > Histórico de mudanças." } else { "$when." })
        }

        $total = @($changes).Count
        $names = Join-SnakeOptimizerList -Items @($problems | ForEach-Object { $_.Name })

        if ($problems.Count -eq 0) {
            # A faixa diz o que mudou ("2 itens desativados"), em vez de só "Concluído com sucesso". Na janela, o título
            # leva o nome quando é um item só ("Spotify desativado"), e a frase diz quando vale.
            $detail = $(if ($done -eq "mudado") { Get-SnakeOptimizerStartupChangeText -Off $changedOff -On $changedOn } elseif ($changed -eq 1) { "1 item $done" } else { "$changed itens ${done}s" })
            $final = New-SnakeOptimizerResult -Kind Ok -Detail $detail -Title $title
            $headline = $(if ($done -ne "mudado" -and $changed -eq 1) { "$(@($changedOff) + @($changedOn) | Select-Object -First 1) $done" } else { $detail })
            [void](Set-SnakeOptimizerResultView -Result $final -Headline $headline -Note "Vale a partir da próxima vez que você entrar no Windows.")
        }
        elseif ($changed -eq 0) {
            $detail = $(if ($total -eq 1) { "$names não foi ${done}: $($problems[0].Detail)" } else { "nenhum item foi ${done}: $names" })
            $final = New-SnakeOptimizerResult -Kind Failed -Detail $detail -Title $title
        }
        else {
            $verbText = $(if ($problems.Count -eq 1) { "não foi $done" } else { "não foram ${done}s" })
            $final = New-SnakeOptimizerResult -Kind Warning -Detail "$($problems.Count) de $total ${verbText}: $names" -Title $title
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Ocorreu um erro: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    Exit-SnakeOptimizerAction -Result $final
}


Export-ModuleMember -Function *
