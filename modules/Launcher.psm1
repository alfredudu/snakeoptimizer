# O próprio SnakeOptimizer no Windows: ícone, identidade na barra de tarefas e os atalhos (.lnk) que abrem a janela.
# O trabalho de baixo nível (COM e API do shell) fica em Shell.psm1; aqui estão as decisões: o que o atalho executa,
# qual ícone usa e onde é criado.

$script:SnakeOptimizerAppId = "SnakeOptimizer.App"
$script:SnakeOptimizerAppRoot = Split-Path -Parent $PSScriptRoot
$script:SnakeOptimizerShortcutFileName = "SnakeOptimizer.lnk"
# Quem, além das contas de confiança, pode alterar os arquivos do SnakeOptimizer (lido uma vez: Get-SnakeOptimizerAppFolderWriters).
$script:SnakeOptimizerAppFolderWriters = $null
# Se a janela está com a conta de outro Administrador (uma consulta ao WMI; o resumo é refeito a cada troca de tema).
$script:SnakeOptimizerAccountMismatch = $null


function Get-SnakeOptimizerAppRoot {
    # Pasta onde o SnakeOptimizer está instalado (a que contém SnakeOptimizer.Gui.ps1, modules, assets...).
    return $script:SnakeOptimizerAppRoot
}


function Test-SnakeOptimizerIconFile {
    # Confere o cabeçalho de um arquivo .ico (reservado 0, tipo 1 = ícone, ao menos uma imagem). Pega o arquivo vazio,
    # cortado por um download interrompido ou que não é um ícone; o Windows mostraria um ícone em branco.
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $stream = [System.IO.File]::OpenRead($Path)

        try {
            $header = New-Object byte[] 6

            if ($stream.Read($header, 0, 6) -ne 6) {
                return $false
            }
        }
        finally {
            $stream.Dispose()
        }

        return ($header[0] -eq 0 -and $header[1] -eq 0 -and $header[2] -eq 1 -and $header[3] -eq 0 -and ($header[4] -ne 0 -or $header[5] -ne 0))
    }
    catch {
        return $false
    }
}


function Get-SnakeOptimizerIconPath {
    # Caminho do ícone (assets\SnakeOptimizer.ico) ou $null se o arquivo não estiver na pasta ou não for um ícone válido.
    param (
        [string]$Root = (Get-SnakeOptimizerAppRoot)
    )

    $path = Join-Path (Join-Path $Root "assets") "SnakeOptimizer.ico"

    if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Test-SnakeOptimizerIconFile -Path $path)) {
        return $path
    }

    return $null
}


function Get-SnakeOptimizerPowerShellPath {
    # O Windows PowerShell 5.1: o mesmo que os arquivos .cmd usam e que existe em todo Windows 10/11.
    if (-not [string]::IsNullOrEmpty($env:SystemRoot)) {
        $path = $env:SystemRoot
        foreach ($part in "System32", "WindowsPowerShell", "v1.0", "powershell.exe") {
            $path = Join-Path $path $part
        }

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    return "powershell.exe"
}


function Get-SnakeOptimizerLaunchDefinition {
    <#
    Descreve como abrir a janela do SnakeOptimizer: programa, argumentos, pasta de trabalho e ícone. É a mesma linha que o
    SnakeOptimizer.cmd usa; a janela se reabre sozinha como Administrador, então o atalho não precisa pedir isso.
    #>
    param (
        [string]$Root = (Get-SnakeOptimizerAppRoot)
    )

    $guiScript = Join-Path $Root "SnakeOptimizer.Gui.ps1"

    if (-not (Test-Path -LiteralPath $guiScript -PathType Leaf)) {
        throw "O arquivo SnakeOptimizer.Gui.ps1 não foi encontrado em '$Root'. Extraia a pasta inteira do SnakeOptimizer antes de criar o atalho."
    }

    $executable = Get-SnakeOptimizerPowerShellPath
    $icon = Get-SnakeOptimizerIconPath -Root $Root

    # Sem o arquivo do ícone, o atalho mostra o ícone do PowerShell em vez de ficar sem nenhum.
    $iconLocation = "$executable,0"

    if ($null -ne $icon) {
        $iconLocation = "$icon,0"
    }

    return [PSCustomObject]@{
        Executable       = $executable
        Arguments        = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File $(ConvertTo-SnakeOptimizerCommandLineArgument -Value $guiScript)"
        WorkingDirectory = $Root
        IconLocation     = $iconLocation
        HasIcon          = ($null -ne $icon)
        Description      = "SnakeOptimizer - manutenção, reparo e diagnóstico do Windows"
        AppId            = $script:SnakeOptimizerAppId
    }
}


function Get-SnakeOptimizerShortcutLocation {
    # Onde o atalho pode ser criado, na ordem em que aparecem para a pessoa. Só entram pastas que este Windows informa.
    $places = @(
        @{ Id = "Desktop"; Label = "Área de Trabalho" },
        @{ Id = "StartMenu"; Label = "Menu Iniciar" }
    )

    foreach ($place in $places) {
        $folder = Get-SnakeOptimizerSpecialFolder -Name $place.Id

        if ([string]::IsNullOrWhiteSpace($folder)) {
            continue
        }

        [PSCustomObject]@{
            Id     = $place.Id
            Label  = $place.Label
            Folder = $folder
            Path   = Join-Path $folder $script:SnakeOptimizerShortcutFileName
        }
    }
}


function Get-SnakeOptimizerShortcutPlaceText {
    # O lugar do atalho numa frase: "na Área de Trabalho", "no Menu Iniciar".
    param (
        [Parameter(Mandatory)]
        $Place
    )

    switch ([string]$Place.Id) {
        "Desktop"   { return "na Área de Trabalho" }
        "StartMenu" { return "no Menu Iniciar" }
        default     { return "em $($Place.Label)" }
    }
}


function Initialize-SnakeOptimizerAppIdentity {
    # Chamado pela janela antes de aparecer: o processo passa a se chamar SnakeOptimizer para o Windows, e o botão da barra
    # de tarefas deixa de ser agrupado com o PowerShell. Devolve $true se o Windows aceitou.
    return (Set-SnakeOptimizerProcessAppId -AppId $script:SnakeOptimizerAppId)
}


function Set-SnakeOptimizerWindowIdentity {
    # Chamado pela janela depois de criada: o "Fixar na barra de tarefas" passa a abrir o SnakeOptimizer, com o ícone dele.
    param (
        [Parameter(Mandatory)]
        [IntPtr]$Handle,

        [string]$Root = (Get-SnakeOptimizerAppRoot)
    )

    try {
        $launch = Get-SnakeOptimizerLaunchDefinition -Root $Root
    }
    catch {
        return $false
    }

    $command = "$(ConvertTo-SnakeOptimizerCommandLineArgument -Value $launch.Executable) $($launch.Arguments)"

    return (Set-SnakeOptimizerWindowRelaunch -Handle $Handle -AppId $launch.AppId -Command $command -IconResource $launch.IconLocation -DisplayName "SnakeOptimizer")
}


function New-SnakeOptimizerAppShortcut {
    <#
    Cria o atalho do SnakeOptimizer, com o ícone, na Área de Trabalho e/ou no Menu Iniciar. Sem -Location, pergunta onde.
    Se o atalho já existir, é atualizado (por exemplo, depois de mover a pasta do SnakeOptimizer).
    #>
    param (
        [ValidateSet("Desktop", "StartMenu")]
        [string[]]$Location,

        [switch]$Embedded,
        [switch]$PassThru
    )

    $title = "Criar atalho do SnakeOptimizer"

    Enter-SnakeOptimizerAction -Title $title -Embedded:$Embedded

    $result = New-SnakeOptimizerResult -Kind Skipped -Title $title
    $ready = $false

    try {
        $launch = Get-SnakeOptimizerLaunchDefinition
        $places = @(Get-SnakeOptimizerShortcutLocation)

        if ($places.Count -eq 0) {
            throw "O Windows não informou a Área de Trabalho nem o Menu Iniciar deste usuário."
        }

        $ready = $true
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message $_.Exception.Message
        $result = New-SnakeOptimizerResult -Kind Failed -Detail "atalho não criado" -Title $title
    }

    # Elevado com a conta de outro Administrador, a Área de Trabalho e o Menu Iniciar seriam os dessa conta.
    if ($ready -and (Test-SnakeOptimizerUserContextMismatch)) {
        $ready = $false
        Write-SnakeOptimizerStatus -Type Warning -Message "O SnakeOptimizer está aberto com a conta de outro Administrador: o atalho iria para a Área de Trabalho dessa conta. Para criar o atalho na sua conta, $(Get-SnakeOptimizerUnelevatedHint)."
        $result = New-SnakeOptimizerResult -Kind Warning -Detail "com a conta de outro Administrador, o atalho não foi criado" -Title $title
    }

    if ($ready) {
        Show-SnakeOptimizerFolderWritersNotice
    }

    if ($ready) {
        # @($null) teria um item; por isso "sem -Location" é testado pelos parâmetros recebidos.
        if ($PSBoundParameters.ContainsKey("Location")) {
            $chosen = @($Location)
        }
        else {
            $chosen = @(Select-SnakeOptimizerShortcutLocation -Places $places)
        }

        $selected = @($places | Where-Object { $chosen -contains $_.Id })

        if ($selected.Count -eq 0) {
            if ($chosen.Count -eq 0) {
                Write-SnakeOptimizerStatus -Type Info -Message "Nenhum atalho foi criado."
                $result = New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title
            }
            else {
                # Pediram um lugar que este Windows não informou (por exemplo, sem o Menu Iniciar do usuário).
                Write-SnakeOptimizerStatus -Type Error -Message "Este Windows não informou a pasta do lugar pedido para o atalho."
                $result = New-SnakeOptimizerResult -Kind Failed -Detail "o lugar pedido não está disponível neste Windows" -Title $title
            }
        }
        else {
            $result = New-SnakeOptimizerShortcutFiles -Places $selected -Launch $launch
        }
    }

    if ($PassThru) { $result }
    Exit-SnakeOptimizerAction -Embedded:$Embedded -Result $result
}


function Select-SnakeOptimizerShortcutLocation {
    # Pergunta onde criar o atalho. Devolve os Ids escolhidos, ou nada se a pessoa cancelar.
    param (
        [Parameter(Mandatory)]
        [object[]]$Places
    )

    if ($Places.Count -eq 1) {
        return @($Places[0].Id)
    }

    $options = @()
    $position = 0

    # O que cada lugar é, e não a pasta (C:\Users\...\Start Menu\Programs não diz nada a quem não a conhece).
    $about = @{ Desktop = "O ícone fica na tela, junto dos seus arquivos"; StartMenu = "O SnakeOptimizer entra na lista de programas do botão Iniciar" }

    foreach ($place in $Places) {
        $position++
        $description = $(if ($about.ContainsKey([string]$place.Id)) { $about[[string]$place.Id] } else { [string]$place.Folder })
        $options += @{ Key = [string]$position; Label = $place.Label; Description = $description; Accent = ($position -eq 1) }
    }

    $options += @{ Key = "A"; Label = "Os dois"; Description = (@($Places | ForEach-Object { [string]$_.Label }) -join " e ") }
    $options += @{ Key = "0"; Label = "Cancelar"; Exit = $true }

    $answer = Read-SnakeOptimizerChoice -Message "Onde você quer o atalho do SnakeOptimizer?" -Options $options -ShowMenu

    if ($answer -eq "0") {
        return @()
    }

    if ($answer -eq "A") {
        return @($Places | ForEach-Object { $_.Id })
    }

    # Qualquer outra resposta que não seja o número de um lugar da lista é tratada como cancelamento.
    $index = 0

    if ([int]::TryParse([string]$answer, [ref]$index) -and $index -ge 1 -and $index -le $Places.Count) {
        return @($Places[$index - 1].Id)
    }

    return @()
}


function New-SnakeOptimizerShortcutFiles {
    # Grava o atalho em cada lugar escolhido e mostra o resultado. Um lugar com erro não impede os outros.
    param (
        [Parameter(Mandatory)]
        [object[]]$Places,

        [Parameter(Mandatory)]
        $Launch
    )

    $created = 0
    $updated = 0
    $failed = 0
    $appIdMissing = $false
    $createdIds = @()

    foreach ($place in $Places) {
        $existed = Test-Path -LiteralPath $place.Path -PathType Leaf

        try {
            if (-not (Test-Path -LiteralPath $place.Folder -PathType Container)) {
                throw "A pasta '$($place.Folder)' não existe."
            }

            $saved = Save-SnakeOptimizerShortcutFile -Path $place.Path -Target $Launch.Executable -Arguments $Launch.Arguments `
                -WorkingDirectory $Launch.WorkingDirectory -IconLocation $Launch.IconLocation -Description $Launch.Description -AppId $Launch.AppId

            # Proteção contra ransomware ou antivírus podem bloquear a gravação sem o COM reclamar.
            if (-not (Test-Path -LiteralPath $place.Path -PathType Leaf)) {
                throw "o Windows não gravou o arquivo (a proteção contra ransomware ou um antivírus pode ter bloqueado a pasta)."
            }

            $created++
            $createdIds += [string]$place.Id

            if ($existed) { $updated++ }

            $verb = if ($existed) { "atualizado" } else { "criado" }
            Write-SnakeOptimizerStatus -Type Success -Message "Atalho $verb $(Get-SnakeOptimizerShortcutPlaceText -Place $place)."
            Write-Host "      $($place.Path)" -ForegroundColor DarkGray

            if (-not $saved.AppIdSet) { $appIdMissing = $true }
        }
        catch {
            $failed++
            Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível criar o atalho $(Get-SnakeOptimizerShortcutPlaceText -Place $place): $($_.Exception.Message)"
        }
    }

    if ($created -gt 0) {
        Write-Host ""

        # O Explorador guarda o ícone de cada atalho: sem este aviso, um atalho regravado continuaria com o ícone antigo.
        if (Initialize-SnakeOptimizerShellInterop) {
            try { [SnakeOptimizer.ShellIdentity]::RefreshIcons() } catch { Write-Verbose "Ícones: $($_.Exception.Message)" }
        }

        if (-not $Launch.HasIcon) {
            Write-SnakeOptimizerStatus -Type Warning -Message "O arquivo assets\SnakeOptimizer.ico não foi encontrado; o atalho usa o ícone do PowerShell."
        }

        if ($appIdMissing) {
            Write-SnakeOptimizerStatus -Type Warning -Message "O Windows não aceitou o identificador da barra de tarefas: fixado na barra, o atalho pode aparecer como PowerShell."
        }

        # No Windows 11, a opção fica em 'Mostrar mais opções' (Área de Trabalho) ou em 'Mais' (Menu Iniciar). Mover a pasta do SnakeOptimizer quebra o atalho: é criar de novo.
        Write-SnakeOptimizerStatus -Type Info -Message "Para fixar na barra de tarefas: botão direito no atalho, 'Fixar na barra de tarefas' (no Windows 11, dentro de 'Mostrar mais opções' ou de 'Mais')."
    }

    if ($created -eq 0) {
        return (New-SnakeOptimizerResult -Kind Failed -Detail "nenhum atalho criado" -Title "Criar atalho do SnakeOptimizer")
    }

    if ($failed -gt 0) {
        return (New-SnakeOptimizerResult -Kind Warning -Detail "$(Format-SnakeOptimizerCount -Count $created -One 'atalho criado' -Many 'atalhos criados'), $failed com erro" -Title "Criar atalho do SnakeOptimizer")
    }

    # Diz onde o atalho ficou, para a faixa de resultado responder a pergunta "onde ele foi parar?".
    $where = (@($createdIds | ForEach-Object { if ($_ -eq "StartMenu") { "no Menu Iniciar" } else { "na Área de Trabalho" } }) -join " e ")
    $verbDone = $(if ($updated -eq $created) { "atualizado" } elseif ($updated -eq 0) { "criado" } else { "gravado" })

    # Um atalho sem o ícone ou sem o identificador da barra de tarefas funciona, mas não é o que a pessoa espera ver.
    $caveats = @()

    if (-not $Launch.HasIcon) { $caveats += "está com o ícone do PowerShell" }

    if ($appIdMissing) { $caveats += "o botão pode aparecer como PowerShell ao ser fixado na barra de tarefas" }

    if ($caveats.Count -gt 0) {
        return (New-SnakeOptimizerResult -Kind Warning -Detail "atalho $verbDone $where, mas $($caveats -join '; ')" -Title "Criar atalho do SnakeOptimizer")
    }

    # A faixa da janela: o que foi feito no título; onde ficou e como fixar na frase.
    $headline = $(if ($created -gt 1) { "Atalhos $($verbDone)s" } else { "Atalho $verbDone" })
    $pinHint = $(if ($created -gt 1) { "clique num deles com o botão direito" } else { "clique nele com o botão direito" })
    $whereText = $where.Substring(0, 1).ToUpperInvariant() + $where.Substring(1)

    return (Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Ok -Detail "atalho $verbDone $where" -Title "Criar atalho do SnakeOptimizer") `
            -Headline $headline -Note "$whereText. Para fixar na barra de tarefas, $pinHint.")
}


function Get-SnakeOptimizerAppFolderWriters {
    <#
    As contas, além da sua, dos Administradores e do sistema, que podem alterar os arquivos do SnakeOptimizer (a mesma conta do
    agendamento: Get-SnakeOptimizerScheduleUntrustedWriters). A janela roda esses arquivos como Administrador: numa pasta que
    outras contas do PC alteram (C:\SnakeOptimizer criada direto no disco, onde os "Usuários autenticados" podem modificar),
    qualquer uma delas passaria a rodar código como Administrador. Lido uma vez por processo; permissões que não puderam
    ser lidas não entram (não é um alarme).
    #>
    if ($null -ne $script:SnakeOptimizerAppFolderWriters) { return $script:SnakeOptimizerAppFolderWriters }

    $writers = @()

    try {
        if (Get-Command -Name Get-SnakeOptimizerScheduleUntrustedWriters -ErrorAction SilentlyContinue) {
            $writers = @(Get-SnakeOptimizerScheduleUntrustedWriters -Root (Get-SnakeOptimizerAppRoot) | Where-Object { [string]$_ -notmatch '^não foi possível' })
        }
    }
    catch {
        $writers = @()
    }

    $script:SnakeOptimizerAppFolderWriters = $writers
    return $writers
}


function Show-SnakeOptimizerFolderWritersNotice {
    # O aviso de Criar atalho quando outras contas podem alterar os arquivos do SnakeOptimizer (Get-SnakeOptimizerAppFolderWriters).
    $writers = @(Get-SnakeOptimizerAppFolderWriters)

    if ($writers.Count -eq 0) { return }

    Write-SnakeOptimizerStatus -Type Warning -Notice -Message "Outras contas deste PC ($($writers -join ', ')) podem alterar os arquivos do SnakeOptimizer, que roda como Administrador: se mais alguém usa este PC, extraia o SnakeOptimizer de novo em Arquivos de Programas e crie o atalho de lá."
    Write-Host ""
}


function Get-SnakeOptimizerShortcutState {
    # Cada lugar do atalho (Área de Trabalho, Menu Iniciar) com Exists e Current (o atalho abre esta pasta do SnakeOptimizer;
    # um atalho que não pôde ser lido conta como desta pasta, para não acusar à toa).
    $script = Join-Path (Get-SnakeOptimizerAppRoot) "SnakeOptimizer.Gui.ps1"

    foreach ($place in @(Get-SnakeOptimizerShortcutLocation)) {
        $exists = Test-Path -LiteralPath $place.Path -PathType Leaf
        $current = $true

        if ($exists) {
            $target = $null
            try { $target = Get-SnakeOptimizerShortcutTarget -Path $place.Path } catch { $target = $null }

            if ($null -ne $target -and [string]$target.Arguments -and ([string]$target.Arguments).IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                $current = $false
            }
        }

        [PSCustomObject]@{ Id = $place.Id; Label = $place.Label; Path = $place.Path; Exists = $exists; Current = $current }
    }
}


function Show-SnakeOptimizerAbout {
    # Tela "Versão e pastas": o que está aberto, onde está instalado e onde ficam os logs, os relatórios e os atalhos.
    Enter-SnakeOptimizerAction -Title "Versão e pastas"

    $dataPath = Get-SnakeOptimizerDataPath

    Write-SnakeOptimizerSection -Title "SnakeOptimizer"
    Write-SnakeOptimizerKeyValue -Label "Versão" -Value "Build $(Get-SnakeOptimizerBuild)"
    Write-SnakeOptimizerKeyValue -Label "Instalado em" -Value (Get-SnakeOptimizerAppRoot)
    Write-SnakeOptimizerKeyValue -Label "PowerShell" -Value "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-SnakeOptimizerKeyValue -Label "Administrador" -Value $(if (Test-SnakeOptimizerAdministrator) { "Sim" } else { "Não" })

    Write-SnakeOptimizerSection -Title "Pastas"
    Write-SnakeOptimizerKeyValue -Label "Logs e relatórios" -Value $dataPath

    $logPath = Get-SnakeOptimizerLogPath

    if (-not [string]::IsNullOrWhiteSpace($logPath)) {
        Write-SnakeOptimizerKeyValue -Label "Log desta sessão" -Value $logPath
    }

    Write-SnakeOptimizerSection -Title "Atalho"

    $iconMissing = ($null -eq (Get-SnakeOptimizerIconPath))

    if ($iconMissing) {
        Write-SnakeOptimizerStatus -Type Warning -Message "O arquivo assets\SnakeOptimizer.ico não foi encontrado; os atalhos usam o ícone do PowerShell."
    }

    foreach ($place in @(Get-SnakeOptimizerShortcutState)) {
        $text = $(if (-not $place.Exists) { "Sem atalho" } elseif ($place.Current) { "Atalho criado" } else { "Atalho de outra pasta do SnakeOptimizer; crie de novo" })
        Write-SnakeOptimizerKeyValue -Label $place.Label -Value $text
    }

    # É uma tela de leitura: sem problema, não há faixa de resultado; com o ícone faltando, a faixa diz exatamente isso.
    if ($iconMissing) {
        Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Warning -Detail "o ícone assets\SnakeOptimizer.ico não foi encontrado" -Title "Versão e pastas")
    }
    else {
        Exit-SnakeOptimizerAction
    }
}


function Get-SnakeOptimizerAboutPageStatus {
    <#
    O resumo no alto da página Sobre o SnakeOptimizer: a versão, onde o atalho já existe (e se ele abre esta pasta), o ícone,
    se a janela está como Administrador e, quando é o caso, a conta e as permissões da pasta. Cada linha tem Label, Text e
    Level (Normal | Warn | Muted). Só lê o que é local, sem consultar a internet; cada linha que não puder ser lida vira
    "não foi possível ler" sozinha, em vez de derrubar a página.
    #>
    $rows = @()

    try {
        $rows += [PSCustomObject]@{ Label = "Versão"; Text = "Build $(Get-SnakeOptimizerBuild)"; Level = "Normal" }
    }
    catch {
        $rows += [PSCustomObject]@{ Label = "Versão"; Text = "não foi possível ler"; Level = "Muted" }
    }

    try {
        $places = @(Get-SnakeOptimizerShortcutState)
        $with = @($places | Where-Object { $_.Exists -and $_.Current } | ForEach-Object { [string]$_.Label })
        $stale = @($places | Where-Object { $_.Exists -and -not $_.Current } | ForEach-Object { [string]$_.Label })

        if ($places.Count -eq 0) {
            $rows += [PSCustomObject]@{ Label = "Atalho"; Text = "o Windows não informou as pastas do atalho"; Level = "Muted" }
        }
        elseif ($stale.Count -gt 0) {
            # O atalho de uma cópia antiga (outra pasta) abriria a versão velha.
            $rows += [PSCustomObject]@{ Label = "Atalho"; Text = "o de $($stale -join ' e ') abre outra pasta do SnakeOptimizer; use Criar atalho do SnakeOptimizer"; Level = "Warn" }
        }
        elseif ($with.Count -eq 0) {
            $rows += [PSCustomObject]@{ Label = "Atalho"; Text = "ainda não criado; use Criar atalho do SnakeOptimizer"; Level = "Muted" }
        }
        else {
            $rows += [PSCustomObject]@{ Label = "Atalho"; Text = ($with -join " e "); Level = "Normal" }
        }
    }
    catch {
        $rows += [PSCustomObject]@{ Label = "Atalho"; Text = "não foi possível ler"; Level = "Muted" }
    }

    # O ícone na sua própria linha: uma falha ao conferi-lo não vira uma segunda linha "Atalho".
    try {
        if ($null -eq (Get-SnakeOptimizerIconPath)) {
            $rows += [PSCustomObject]@{ Label = "Ícone"; Text = "o arquivo do ícone (assets\SnakeOptimizer.ico) não foi encontrado; extraia a pasta inteira do SnakeOptimizer de novo"; Level = "Warn" }
        }
    }
    catch {
        Write-Verbose "Ícone: $($_.Exception.Message)"
    }

    try {
        # O SnakeOptimizer abre sempre como Administrador; sem ele, a pessoa recusou o aviso do Windows ao abrir.
        if (Test-SnakeOptimizerAdministrator) {
            $rows += [PSCustomObject]@{ Label = "Administrador"; Text = "esta janela está aberta como Administrador"; Level = "Normal" }
        }
        else {
            $rows += [PSCustomObject]@{ Label = "Administrador"; Text = "esta janela está sem Administrador; as ações que alteram o sistema pedem a permissão de novo"; Level = "Warn" }
        }
    }
    catch {
        $rows += [PSCustomObject]@{ Label = "Administrador"; Text = "não foi possível ler"; Level = "Muted" }
    }

    try {
        # Uma consulta só por processo: a conta da janela não muda enquanto ela está aberta.
        if ($null -eq $script:SnakeOptimizerAccountMismatch) { $script:SnakeOptimizerAccountMismatch = [bool](Test-SnakeOptimizerUserContextMismatch) }

        if ($script:SnakeOptimizerAccountMismatch) {
            $rows += [PSCustomObject]@{ Label = "Conta"; Text = "o SnakeOptimizer está aberto com a conta de outro Administrador; atalhos, pastas e o monitor são os dessa conta"; Level = "Warn" }
        }
    }
    catch {
        Write-Verbose "Conta: $($_.Exception.Message)"
    }

    $writers = @(Get-SnakeOptimizerAppFolderWriters)

    if ($writers.Count -gt 0) {
        $rows += [PSCustomObject]@{ Label = "Pasta"; Text = "outras contas deste PC podem alterar os arquivos do SnakeOptimizer; se mais alguém usa o PC, extraia o SnakeOptimizer de novo em Arquivos de Programas"; Level = "Warn" }
    }

    return $rows
}


Export-ModuleMember -Function *
