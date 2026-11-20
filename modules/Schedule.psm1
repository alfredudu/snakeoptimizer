# Manutenção agendada: uma tarefa do Agendador de Tarefas do Windows que, uma vez por mês, faz só o que é seguro
# sem ninguém olhando (limpa os temporários do usuário com mais de 7 dias e salva um relatório). É opcional, começa
# desligada e some com um clique.
#
# Decisões de segurança:
#   - A tarefa roda SEM privilégios de Administrador, só com o usuário logado. Uma tarefa elevada que executa um
#     script numa pasta que o próprio usuário pode alterar (Downloads, Área de Trabalho) seria um atalho para qualquer
#     programa comum ganhar privilégios; sem elevação esse risco não existe, e não há pedido de UAC que travaria
#     uma tarefa em segundo plano.
#   - Não esvazia a Lixeira, não repara, não atualiza e não muda ajustes: isso exige a sua decisão na hora.

$script:SnakeOptimizerSchedulePath = "\SnakeOptimizer\"
$script:SnakeOptimizerScheduleName = "Manutencao-Mensal"
$script:SnakeOptimizerScheduleDays = @(1, 15, 28)
$script:SnakeOptimizerScheduleHour = 12

# Na execução agendada, só sai dos temporários o que está lá há mais tempo que isto (a Limpeza de Disco do Windows também
# usa 7 dias).
$script:SnakeOptimizerScheduleTempDays = 7

# Resultados do Agendador que não são falha: 0 (terminou bem), 0x41300 (pronta), 0x41301 (em execução), 0x41302
# (desativada) e 0x41303 (ainda não executou).
$script:SnakeOptimizerScheduleOkResults = @(0, 267008, 267009, 267010, 267011)


# ---------------------------------------------------------------------------
# A tarefa
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerScheduleUser {
    # Quem vai executar a tarefa: o usuário que está usando o PC. Se o SnakeOptimizer foi elevado com outra conta, é o
    # usuário logado que importa (é a Área de Trabalho e os temporários dele que a limpeza deve tratar).
    $interactive = Get-SnakeOptimizerInteractiveUser

    if (-not [string]::IsNullOrWhiteSpace($interactive)) {
        return $interactive
    }

    try {
        return [Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return ""
    }
}


function Get-SnakeOptimizerScheduleCommand {
    <#
    O programa e os argumentos que a tarefa executa: o mesmo PowerShell do SnakeOptimizer.cmd, com o script do terminal. No
    Windows 11 (build 22000 em diante), o Terminal do Windows pode ser o programa padrão de console, e ele ignora o
    -WindowStyle Hidden: a janela apareceria todo mês, e fechá-la pararia a limpeza. Lá o PowerShell é aberto pelo
    console clássico sem janela (conhost.exe --headless), quando ele existe.
    #>
    param (
        [string]$Root = (Get-SnakeOptimizerAppRoot),
        [int]$Build = (Get-SnakeOptimizerWindowsBuild),
        [AllowEmptyString()][string]$SystemRoot = $env:SystemRoot
    )

    $script = Join-Path $Root "SnakeOptimizer.Console.ps1"

    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "O arquivo SnakeOptimizer.Console.ps1 não foi encontrado em '$Root'. Extraia a pasta inteira do SnakeOptimizer antes de agendar."
    }

    $powershell = Get-SnakeOptimizerPowerShellPath
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $(ConvertTo-SnakeOptimizerCommandLineArgument -Value $script) -Action ScheduledMaintenance"
    $conhost = $(if (-not [string]::IsNullOrWhiteSpace($SystemRoot)) { Join-Path (Join-Path $SystemRoot "System32") "conhost.exe" } else { "" })

    if ($Build -ge 22000 -and $conhost -and (Test-Path -LiteralPath $conhost -PathType Leaf)) {
        return [PSCustomObject]@{
            Executable       = $conhost
            Arguments        = "--headless $(ConvertTo-SnakeOptimizerCommandLineArgument -Value $powershell) $arguments"
            WorkingDirectory = $Root
        }
    }

    return [PSCustomObject]@{
        Executable       = $powershell
        Arguments        = $arguments
        WorkingDirectory = $Root
    }
}


function New-SnakeOptimizerScheduleTaskXml {
    <#
    O XML da tarefa (esquema do Agendador de Tarefas): todo mês no dia escolhido, às 12h, com o usuário logado e sem
    elevação. Se o PC estiver desligado na hora, roda assim que for possível; não começa na bateria e para se passar
    a usar a bateria. A primeira execução é a partir de amanhã, para não disparar na hora em que é criada.
    #>
    param (
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$UserId,

        [ValidateRange(1, 28)]
        [int]$DayOfMonth = 1,

        [datetime]$Start = ((Get-Date).Date.AddDays(1).AddHours($script:SnakeOptimizerScheduleHour))
    )

    $escape = { param ($text) [System.Security.SecurityElement]::Escape($text) }
    $startBoundary = $Start.ToString("yyyy-MM-dd'T'HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    $months = (@("January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December") | ForEach-Object { "<$_ />" }) -join ""
    $description = "Manutenção mensal do SnakeOptimizer: limpa os temporários do usuário com mais de 7 dias e salva um relatório. Não esvazia a Lixeira nem altera o sistema. Para remover, use o SnakeOptimizer (Manutenção > Manutenção agendada) ou apague esta tarefa."

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>SnakeOptimizer</Author>
    <Description>$(& $escape $description)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByMonth>
        <DaysOfMonth><Day>$DayOfMonth</Day></DaysOfMonth>
        <Months>$months</Months>
      </ScheduleByMonth>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(& $escape $UserId)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>true</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $escape $Executable)</Command>
      <Arguments>$(& $escape $Arguments)</Arguments>
      <WorkingDirectory>$(& $escape $WorkingDirectory)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}


function ConvertTo-SnakeOptimizerScheduleResultCode {
    # O código de resultado como número sem sinal (o Agendador às vezes o entrega negativo: -196608 é 0xFFFD0000).
    param ($Code)

    $value = [int64]$Code
    if ($value -lt 0) { $value += 4294967296 }

    return $value
}


function ConvertTo-SnakeOptimizerScheduleResultText {
    # O código de resultado da última execução, em português.
    param ($Code)

    if ($null -eq $Code) {
        return ""
    }

    $value = ConvertTo-SnakeOptimizerScheduleResultCode -Code $Code

    switch ($value) {
        0          { return "terminou bem" }
        267009     { return "em execução agora" }
        267011     { return "ainda não executou" }
        267014     { return "foi interrompida" }
        # O código que o PowerShell devolve quando o script passado em -File não existe (o SnakeOptimizer mudou de pasta ou foi
        # apagado).
        4294770688 { return "não encontrou o SnakeOptimizer na pasta de antes" }
        default    { return "terminou com erro (código 0x$($value.ToString('X')))" }
    }
}


function Get-SnakeOptimizerScheduleTaskScript {
    # O script que a tarefa executa: o caminho depois de -File nos argumentos dela, ou "" quando não há como saber.
    param ([string]$Arguments)

    if ($Arguments -match '(?i)(^|\s)-File\s+"([^"]+)"') { return $Matches[2] }
    if ($Arguments -match '(?i)(^|\s)-File\s+([^\s"]+)') { return $Matches[2] }

    return ""
}


function Test-SnakeOptimizerSchedulePathSame {
    # Os dois caminhos levam ao mesmo arquivo? Compara o caminho completo, sem diferenciar maiúsculas (como o Windows).
    param (
        [string]$Path,
        [string]$Other
    )

    try {
        $first = [System.IO.Path]::GetFullPath($Path)
        $second = [System.IO.Path]::GetFullPath($Other)
    }
    catch {
        return $false
    }

    return [string]::Equals($first, $second, [StringComparison]::OrdinalIgnoreCase)
}


function Get-SnakeOptimizerScheduleStatus {
    <#
    O estado da tarefa no Agendador de Tarefas. Installed é falso quando ela não existe (ou quando o Agendador não pôde
    ser consultado; aí QueryFailed é verdadeiro, e a tela não diz "não agendada" sem saber). Day é o dia do mês; LastRun e NextRun são $null quando não houve/não há execução marcada.
    A tarefa guarda o caminho do script; extrair uma versão nova em outra pasta e apagar a antiga a deixa falhando todo
    mês, ainda "ativa" no Agendador. Por isso:
      ScriptPath     - o script que a tarefa executa ("" quando não deu para ler);
      ScriptMissing  - esse script não existe mais (a tarefa vai falhar até ser recriada);
      Stale          - o script é de outra pasta, não do SnakeOptimizer que está aberto;
      LastRunFailed  - o Agendador registrou que a última execução terminou mal (LastResult fora dos códigos normais);
      NeedsAttention - instalada e com algum dos três problemas acima; Problem diz qual, numa frase curta.
    #>
    $status = [PSCustomObject]@{
        Installed      = $false
        Enabled        = $false
        Day            = $null
        LastRun        = $null
        LastResult     = $null
        NextRun        = $null
        ScriptPath     = ""
        ScriptMissing  = $false
        Stale          = $false
        LastRunFailed  = $false
        NeedsAttention = $false
        Problem        = ""
        Owner          = ""
        OtherUser      = $false
        QueryFailed    = $false
    }

    try {
        $task = Get-ScheduledTask -TaskPath $script:SnakeOptimizerSchedulePath -TaskName $script:SnakeOptimizerScheduleName -ErrorAction Stop
    }
    catch {
        # Tarefa que não existe é "não agendada"; o Agendador que não respondeu (serviço parado, acesso negado, RPC
        # indisponível) é não saber, e a tela diz isso em vez de "não agendada".
        $category = [string]$_.CategoryInfo.Category
        $status.QueryFailed = ($category -in @("PermissionDenied", "ResourceUnavailable", "ConnectionError", "OpenError") -or [string]$_.Exception.Message -match '(?i)0x80070005|0x800706BA|0x80070422|access is denied|acesso negado')
        return $status
    }

    if ($null -eq $task) {
        return $status
    }

    $status.Installed = $true
    $status.Enabled = ([string]$task.State -ne "Disabled")

    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.LoadXml([string](Export-ScheduledTask -TaskPath $script:SnakeOptimizerSchedulePath -TaskName $script:SnakeOptimizerScheduleName -ErrorAction Stop))
        $day = $xml.SelectSingleNode("//*[local-name()='DaysOfMonth']/*[local-name()='Day']")

        if ($null -ne $day) { $status.Day = [int]$day.InnerText }

        $arguments = $xml.SelectSingleNode("//*[local-name()='Exec']/*[local-name()='Arguments']")

        if ($null -ne $arguments) { $status.ScriptPath = Get-SnakeOptimizerScheduleTaskScript -Arguments $arguments.InnerText }

        # O SnakeOptimizer usa uma tarefa só por PC (um nome fixo no Agendador), com a conta de quem agendou: a de outra conta
        # limpa os temporários dela, e criar ou remover aqui mexeria no agendamento dela.
        $owner = $xml.SelectSingleNode("//*[local-name()='Principal']/*[local-name()='UserId']")

        if ($null -ne $owner -and -not [string]::IsNullOrWhiteSpace($owner.InnerText)) {
            $status.Owner = ConvertTo-SnakeOptimizerScheduleAccountName -Account $owner.InnerText
            $status.OtherUser = -not (Test-SnakeOptimizerScheduleSameAccount -Account $status.Owner -Other (Get-SnakeOptimizerScheduleUser))
        }
    }
    catch {
        # O dia e o script são informação extra; a tarefa continua instalada.
    }

    if ($status.ScriptPath) {
        $status.ScriptMissing = -not (Test-Path -LiteralPath $status.ScriptPath -PathType Leaf)

        try {
            $root = [string](Get-SnakeOptimizerAppRoot)

            if ($root) {
                $status.Stale = -not (Test-SnakeOptimizerSchedulePathSame -Path $status.ScriptPath -Other (Join-Path $root "SnakeOptimizer.Console.ps1"))
            }
        }
        catch {
            # Sem saber onde o SnakeOptimizer está, não dá para comparar; o script que falta continua sendo conferido acima.
        }
    }

    try {
        $info = Get-ScheduledTaskInfo -TaskPath $script:SnakeOptimizerSchedulePath -TaskName $script:SnakeOptimizerScheduleName -ErrorAction Stop

        # O Agendador usa datas antigas (1999/2000) para "nunca".
        if ($info.LastRunTime -is [datetime] -and $info.LastRunTime.Year -ge 2001) { $status.LastRun = $info.LastRunTime }
        if ($info.NextRunTime -is [datetime] -and $info.NextRunTime.Year -ge 2001) { $status.NextRun = $info.NextRunTime }

        $status.LastResult = $info.LastTaskResult
    }
    catch {
        # Sem os detalhes da execução, mostra só que está agendada.
    }

    if ($null -ne $status.LastRun -and $null -ne $status.LastResult) {
        try {
            $status.LastRunFailed = ((ConvertTo-SnakeOptimizerScheduleResultCode -Code $status.LastResult) -notin $script:SnakeOptimizerScheduleOkResults)
        }
        catch {
            $status.LastRunFailed = $false
        }
    }

    if ($status.ScriptMissing) {
        $status.Problem = "a tarefa usa um SnakeOptimizer que não existe mais; recrie o agendamento"
    }
    elseif ($status.Stale) {
        $status.Problem = "a tarefa usa o SnakeOptimizer de outra pasta; recrie o agendamento"
    }
    elseif ($status.LastRunFailed) {
        $status.Problem = "a última execução $(ConvertTo-SnakeOptimizerScheduleResultText -Code $status.LastResult)"
    }

    $status.NeedsAttention = [bool]$status.Problem

    return $status
}


function ConvertTo-SnakeOptimizerScheduleAccountName {
    # O nome de uma conta ("PC\ana") a partir do que a tarefa guarda, que pode ser o nome ou o SID (S-1-5-21-...).
    param ([AllowEmptyString()][string]$Account)

    $text = $Account.Trim()

    if ($text -match '^S-1-[0-9-]+$') {
        try { return (New-Object System.Security.Principal.SecurityIdentifier $text).Translate([System.Security.Principal.NTAccount]).Value }
        catch { return $text }
    }

    return $text
}


function Test-SnakeOptimizerScheduleSameAccount {
    # Se dois nomes de conta são a mesma conta ("PC\Ana" e "ana" também são; sem saber a conta de um dos lados, sim).
    param ([AllowEmptyString()][string]$Account, [AllowEmptyString()][string]$Other)

    if ([string]::IsNullOrWhiteSpace($Account) -or [string]::IsNullOrWhiteSpace($Other)) { return $true }

    $a = $Account.Trim().ToLowerInvariant()
    $b = $Other.Trim().ToLowerInvariant()

    if ($a -eq $b) { return $true }
    if ($a.Contains('\') -and $b.Contains('\')) { return $false }

    return (($a -split '\\')[-1] -eq ($b -split '\\')[-1])
}


function Get-SnakeOptimizerPathWriteRules {
    # As permissões de um arquivo ou pasta, do jeito que a conferência de quem pode alterá-lo precisa: o dono (Owner e
    # OwnerSid) e cada regra (Identity, Sid, Rights, Allow e InheritOnly, a regra que só vale para o que for criado dentro).
    param ([Parameter(Mandatory)][string]$Path)

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $toSid = {
        param ($identity)
        try { return $identity.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return [string]$identity }
    }

    $rules = @(
        foreach ($rule in @($acl.Access)) {
            [PSCustomObject]@{
                Identity    = [string]$rule.IdentityReference
                Sid         = (& $toSid $rule.IdentityReference)
                Rights      = [int64]$rule.FileSystemRights
                Allow       = ([string]$rule.AccessControlType -eq "Allow")
                InheritOnly = (([int]$rule.PropagationFlags -band 2) -ne 0)
            }
        }
    )

    $ownerSid = ""
    try { $ownerSid = (New-Object System.Security.Principal.NTAccount ([string]$acl.Owner)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $ownerSid = [string]$acl.Owner }

    return [PSCustomObject]@{ Owner = [string]$acl.Owner; OwnerSid = $ownerSid; Rules = $rules }
}


function Get-SnakeOptimizerScheduleUntrustedWriters {
    <#
    Quem, além da conta do agendamento, dos Administradores, do SYSTEM e do TrustedInstaller, pode alterar o que a tarefa
    executa: a pasta do SnakeOptimizer, o script do terminal e os módulos. A tarefa roda esses arquivos todo mês com a conta da
    pessoa; numa pasta que outras contas alteram (C:\SnakeOptimizer criada direto no disco, por exemplo, onde os "Usuários
    autenticados" podem modificar), qualquer conta do PC passaria a rodar código como ela. Devolve os nomes (vazio = só
    contas de confiança); permissões que não puderam ser lidas também entram, como um aviso.
    #>
    param (
        [string]$Root = (Get-SnakeOptimizerAppRoot),
        [string]$User = (Get-SnakeOptimizerScheduleUser)
    )

    # SYSTEM, Administradores e TrustedInstaller.
    $trusted = @("S-1-5-18", "S-1-5-32-544", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464")

    try { $trusted += (New-Object System.Security.Principal.NTAccount $User).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { }

    # Gravar, acrescentar, apagar o que está dentro, apagar, trocar as permissões, tomar posse, e os genéricos de gravação.
    $writeMask = [int64](0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000)

    $modules = Join-Path $Root "modules"
    $paths = @($Root, (Join-Path $Root "SnakeOptimizer.Console.ps1"), $modules) + @(Get-ChildItem -LiteralPath $modules -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $writers = @()

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }

        # Sem conseguir ler as permissões, não dá para dizer que só contas de confiança alteram o arquivo (nas pastas
        # comuns, a conta e os Administradores sempre leem).
        try { $acl = Get-SnakeOptimizerPathWriteRules -Path $path }
        catch {
            $writers += "não foi possível conferir as permissões de $path"
            continue
        }

        if ($acl.OwnerSid -and $trusted -notcontains $acl.OwnerSid -and -not (Test-SnakeOptimizerScheduleSameAccount -Account $acl.Owner -Other $User)) { $writers += $acl.Owner }

        foreach ($rule in @($acl.Rules)) {
            if (-not $rule.Allow -or $rule.InheritOnly) { continue }
            if (([int64]$rule.Rights -band $writeMask) -eq 0) { continue }
            if ($trusted -contains [string]$rule.Sid) { continue }
            if (Test-SnakeOptimizerScheduleSameAccount -Account ([string]$rule.Identity) -Other $User) { continue }

            $writers += [string]$rule.Identity
        }
    }

    return @($writers | Where-Object { $_ } | Select-Object -Unique)
}


function Register-SnakeOptimizerScheduledMaintenance {
    # Cria (ou troca) a tarefa mensal. Devolve um SnakeOptimizer.Result.
    param (
        [Parameter(Mandatory)]
        [ValidateRange(1, 28)]
        [int]$Day
    )

    if (-not (Test-SnakeOptimizerElevation -Reason "Criar a tarefa agendada exige privilégios de Administrador.")) {
        return (New-SnakeOptimizerResult -Kind Failed -Detail "requer Administrador")
    }

    try {
        $user = Get-SnakeOptimizerScheduleUser

        if ([string]::IsNullOrWhiteSpace($user)) {
            throw "Não foi possível descobrir qual usuário está usando o PC."
        }

        $command = Get-SnakeOptimizerScheduleCommand
        $writers = @(Get-SnakeOptimizerScheduleUntrustedWriters -Root $command.WorkingDirectory -User $user)

        if ($writers.Count -gt 0) {
            Write-SnakeOptimizerStatus -Type Error -Message "A pasta do SnakeOptimizer ($($command.WorkingDirectory)) pode ser alterada por outras contas deste PC ($(Join-SnakeOptimizerList -Items $writers)). A tarefa rodaria o que estiver nela todo mês com a conta $user."
            # Mover a pasta de agora não basta: ela leva junto as permissões de onde está.
            Write-SnakeOptimizerStatus -Type Info -Message "Extraia o SnakeOptimizer de novo em Arquivos de Programas (C:\Program Files) e agende de lá."
            return (New-SnakeOptimizerResult -Kind Failed -Detail "a pasta do SnakeOptimizer pode ser alterada por outras contas")
        }

        $xml = New-SnakeOptimizerScheduleTaskXml -Executable $command.Executable -Arguments $command.Arguments -WorkingDirectory $command.WorkingDirectory -UserId $user -DayOfMonth $Day

        [void](Register-ScheduledTask -Xml $xml -TaskPath $script:SnakeOptimizerSchedulePath -TaskName $script:SnakeOptimizerScheduleName -Force -ErrorAction Stop)
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível criar a tarefa agendada: $($_.Exception.Message)"
        return (New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message)
    }

    Write-SnakeOptimizerStatus -Type Success -Message "Manutenção agendada para todo dia $Day, às $($script:SnakeOptimizerScheduleHour)h, com a conta $user."

    return (New-SnakeOptimizerResult -Kind Ok -Detail "agendada para todo dia $Day, às $($script:SnakeOptimizerScheduleHour)h" -Data @{ Day = $Day })
}


function Remove-SnakeOptimizerScheduleFolder {
    # Tira do Agendador de Tarefas a pasta \SnakeOptimizer\, se ela ficou vazia (sem a tarefa, ela só sobraria na lista). Uma
    # pasta com outra tarefa dentro fica; uma falha aqui não muda nada no que a pessoa pediu.
    try {
        $service = New-Object -ComObject "Schedule.Service"
        $service.Connect()
        $folder = $service.GetFolder($script:SnakeOptimizerSchedulePath.TrimEnd('\'))

        if ($folder.GetTasks(1).Count -eq 0 -and $folder.GetFolders(0).Count -eq 0) {
            $service.GetFolder("\").DeleteFolder($script:SnakeOptimizerSchedulePath.Trim('\'), 0)
        }
    }
    catch {
        Write-Verbose "Pasta do Agendador: $($_.Exception.Message)"
    }
}


function Unregister-SnakeOptimizerScheduledMaintenance {
    # Apaga a tarefa. Devolve um SnakeOptimizer.Result.
    if (-not (Test-SnakeOptimizerElevation -Reason "Remover a tarefa agendada exige privilégios de Administrador.")) {
        return (New-SnakeOptimizerResult -Kind Failed -Detail "requer Administrador")
    }

    $task = $null
    $missing = $false

    try {
        $task = Get-ScheduledTask -TaskPath $script:SnakeOptimizerSchedulePath -TaskName $script:SnakeOptimizerScheduleName -ErrorAction Stop
        $missing = ($null -eq $task)
    }
    catch {
        # Só "nenhuma tarefa com esse nome" quer dizer que ela já não existe; outro erro (o serviço parado, acesso negado)
        # segue para a remoção, que diz o motivo.
        $missing = ([string]$_.Exception.Message -match 'MSFT_ScheduledTask|0x80070002|não existe|cannot find|not found')
    }

    if ($missing) {
        # Já removida (pelo Agendador de Tarefas, por exemplo): o que a pessoa queria já está feito.
        Remove-SnakeOptimizerScheduleFolder
        Write-SnakeOptimizerStatus -Type Success -Message "A manutenção agendada já não existia. Nada vai rodar sozinho."
        return (New-SnakeOptimizerResult -Kind Ok -Detail "o agendamento já não existia; nada roda sozinho")
    }

    try {
        Unregister-ScheduledTask -TaskPath $script:SnakeOptimizerSchedulePath -TaskName $script:SnakeOptimizerScheduleName -Confirm:$false -ErrorAction Stop
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível remover a tarefa agendada: $($_.Exception.Message)"
        return (New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message)
    }

    Remove-SnakeOptimizerScheduleFolder
    Write-SnakeOptimizerStatus -Type Success -Message "Manutenção agendada removida. Nada mais vai rodar sozinho."

    return (New-SnakeOptimizerResult -Kind Ok -Detail "agendamento removido; nada mais roda sozinho")
}


# ---------------------------------------------------------------------------
# A execução (chamada pela tarefa, sem ninguém olhando)
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerScheduledRunPath {
    return (Join-Path (Get-SnakeOptimizerDataPath) "scheduled-maintenance.json")
}


function Get-SnakeOptimizerScheduledRun {
    # O registro da última execução automática (quando, quanto liberou, onde está o relatório). $null se nunca rodou.
    try {
        # Um registro estragado volta da cópia anterior (.bak), como os outros arquivos de estado.
        $document = (Read-SnakeOptimizerStateFile -Path (Get-SnakeOptimizerScheduledRunPath)).Document

        if ($null -eq $document) {
            return $null
        }

        return [PSCustomObject]@{
            RunAt      = [datetime]::Parse([string]$document.RunAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            Kind       = [string]$document.Kind
            FreedBytes = [int64]$document.FreedBytes
            Report     = [string]$document.Report
        }
    }
    catch {
        return $null
    }
}


function Clear-SnakeOptimizerScheduledTempFolder {
    <#
    A limpeza de uma pasta de temporários na execução agendada: só o que está lá há mais de 7 dias, como faz a Limpeza
    de Disco do Windows. Sem ninguém olhando, um arquivo recente pode ser de um instalador que espera o PC reiniciar ou
    de um programa aberto que ainda vai lê-lo. A limpeza pedida na hora (Limpeza) continua levando tudo o que não está
    em uso. As travas são as da Limpeza: pasta não localizada, recusada por segurança ou ilegível não é tocada.
    Um item conta como antigo pela última atividade dele, olhando dentro das pastas (Measure-SnakeOptimizerFolderItems): uma
    pasta antiga com um arquivo novo dentro fica. Devolve um SnakeOptimizer.Result com FreedBytes.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,

        [int]$Days = $script:SnakeOptimizerScheduleTempDays
    )

    Write-SnakeOptimizerSection -Title $Title

    $result = $null

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível localizar a pasta a limpar: a variável de ambiente que a indica não está definida."
            $result = New-SnakeOptimizerResult -Kind Failed -Detail "pasta não localizada"
        }
        # As duas pastas daqui vêm das variáveis TEMP: só uma pasta chamada Temp (ou Tmp) é esvaziada, como na limpeza feita
        # na hora. Sem essa trava, uma TEMP apontando para D:\Dados teria tudo o que tem mais de 7 dias apagado todo mês,
        # sem ninguém olhando.
        elseif (-not (Test-SnakeOptimizerTempFolderSafe -Path $Path -RequireTempName)) {
            Write-SnakeOptimizerStatus -Type Error -Message "Pasta recusada por segurança: $Path"
            $result = New-SnakeOptimizerResult -Kind Failed -Detail "pasta recusada por segurança"
        }
        elseif (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Pasta não encontrada: $Path"
            $result = New-SnakeOptimizerResult -Kind Skipped -Detail "pasta não encontrada" -Data @{ FreedBytes = [int64]0 }
        }
        else {
            $listing = Get-SnakeOptimizerFolderListing -Path $Path

            if (-not $listing.Readable) {
                Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível ler a pasta: $($listing.Reason)"
                $result = New-SnakeOptimizerResult -Kind Failed -Detail "pasta ilegível"
            }
            else {
                $entries = @(Measure-SnakeOptimizerFolderItems -Items $listing.Items)
                $old = @(Select-SnakeOptimizerItemsOlderThan -Entries $entries -Cutoff (Get-Date).AddDays(-$Days))

                Write-SnakeOptimizerKeyValue -Label "Pasta" -Value $Path
                Write-SnakeOptimizerKeyValue -Label "Com mais de $Days dias" -Value "$($old.Count) de $(Format-SnakeOptimizerCount -Count $entries.Count -One 'item' -Many 'itens')"

                if ($old.Count -eq 0) {
                    Write-SnakeOptimizerStatus -Type Success -Message "Nada com mais de $Days dias para limpar."
                    $result = New-SnakeOptimizerResult -Kind Ok -Detail "nada com mais de $Days dias" -Data @{ FreedBytes = [int64]0 }
                }
                else {
                    $outcome = Clear-SnakeOptimizerFolderContents -Path $Path -Activity $Title -Entries $old

                    # Itens em uso são esperados; mas se NADA saiu, a limpeza não aconteceu.
                    $nothingRemoved = ($outcome.Removed -eq 0 -and $outcome.Skipped -gt 0)
                    $detail = "liberou $(Format-SnakeOptimizerBytes -Bytes $outcome.Freed)"
                    if ($outcome.Skipped -gt 0) { $detail += "; $($outcome.Skipped) em uso" }
                    if ($nothingRemoved) { $detail = "nenhum item removido; $($outcome.Skipped) em uso" }

                    Write-SnakeOptimizerStatus -Type $(if ($nothingRemoved) { "Warning" } else { "Success" }) -Message "Temporários com mais de $Days dias: $detail."
                    $result = New-SnakeOptimizerResult -Kind $(if ($nothingRemoved) { "Warning" } else { "Ok" }) -Detail $detail -Data @{ FreedBytes = [int64]$outcome.Freed }
                }
            }
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Falha na limpeza ($Title): $($_.Exception.Message)"
        $result = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message
    }

    $result.Etapa = $Title

    return $result
}


function Invoke-SnakeOptimizerScheduledMaintenance {
    <#
    O que a tarefa agendada executa: limpa os temporários do usuário com mais de 7 dias (e os do Windows, se por acaso
    estiver com privilégios de Administrador) e salva o relatório. Nunca pergunta nada, nunca esvazia a Lixeira. Devolve
    um SnakeOptimizer.Result e grava o registro da execução.
    #>
    $runAt = Get-Date
    $parts = @()

    Write-SnakeOptimizerSection -Title "Manutenção agendada"

    # Uma limpeza que lança uma exceção não pode levar junto o relatório e o registro da execução: vira uma parte que falhou.
    try {
        $parts += @(Clear-SnakeOptimizerScheduledTempFolder -Title "Temporários do usuário" -Path (Get-SnakeOptimizerUserTempPath) | Where-Object { $null -ne $_ -and $_.PSObject.TypeNames -contains "SnakeOptimizer.Result" })
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Falha na limpeza dos temporários do usuário: $($_.Exception.Message)"
        $parts += New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title "Temporários do usuário"
    }

    if (Test-SnakeOptimizerAdministrator) {
        try {
            $parts += @(Clear-SnakeOptimizerScheduledTempFolder -Title "Temporários do Windows" -Path (Get-SnakeOptimizerWindowsTempPath) | Where-Object { $null -ne $_ -and $_.PSObject.TypeNames -contains "SnakeOptimizer.Result" })
        }
        catch {
            Write-SnakeOptimizerStatus -Type Error -Message "Falha na limpeza dos temporários do Windows: $($_.Exception.Message)"
            $parts += New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title "Temporários do Windows"
        }
    }

    $freed = [int64]0

    foreach ($part in $parts) {
        $partFreed = Get-SnakeOptimizerResultData -Result $part -Name "FreedBytes"
        if ($null -ne $partFreed) { $freed += [int64]$partFreed }
    }

    $reportPath = ""
    $reportFailed = $false

    try {
        $report = Export-SnakeOptimizerReport
        $html = [string]$report.Html

        # A gravação do relatório não para num erro de disco: o arquivo é conferido aqui, para o registro e o resultado
        # não dizerem "salvo" sobre um relatório que não existe ou ficou vazio.
        $saved = $null
        if (-not [string]::IsNullOrWhiteSpace($html)) { $saved = Get-Item -LiteralPath $html -Force -ErrorAction SilentlyContinue }

        if ($null -eq $saved -or $saved.PSIsContainer -or [int64]$saved.Length -le 0) {
            throw "o arquivo do relatório não foi gravado ($(if ($html) { $html } else { 'sem caminho' }))"
        }

        $reportPath = $html
        Write-SnakeOptimizerStatus -Type Success -Message "Relatório salvo em: $reportPath"
    }
    catch {
        $reportFailed = $true
        Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível salvar o relatório: $($_.Exception.Message)"
    }

    $failed = @($parts | Where-Object { $_.Kind -eq "Failed" })

    if ($failed.Count -eq 0 -and -not $reportFailed) {
        $result = New-SnakeOptimizerResult -Kind Ok -Detail "liberou $(Format-SnakeOptimizerBytes -Bytes $freed)" -Data @{ FreedBytes = $freed; Report = $reportPath }
    }
    elseif ($failed.Count -eq $parts.Count -and $reportFailed) {
        # Nada funcionou: a tarefa termina com código de erro, e o Agendador de Tarefas mostra que falhou.
        $result = New-SnakeOptimizerResult -Kind Failed -Detail "nada foi feito" -Data @{ FreedBytes = $freed; Report = $reportPath }
    }
    else {
        $result = New-SnakeOptimizerResult -Kind Warning -Detail "parte do trabalho falhou" -Data @{ FreedBytes = $freed; Report = $reportPath }
    }

    try {
        $document = [ordered]@{
            RunAt      = $runAt.ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
            Kind       = $result.Kind
            FreedBytes = $freed
            Report     = $reportPath
        }

        # Gravação atômica: a tela pode estar lendo o registro enquanto a tarefa grava.
        Write-SnakeOptimizerStateJson -Path (Get-SnakeOptimizerScheduledRunPath) -InputObject $document
    }
    catch {
        # O registro é um complemento da tela; a limpeza e o relatório já foram feitos.
    }

    $result.Etapa = "Manutenção agendada"

    return $result
}


# ---------------------------------------------------------------------------
# A tela
# ---------------------------------------------------------------------------

function Show-SnakeOptimizerScheduledMaintenance {
    $title = "Manutenção agendada"
    Enter-SnakeOptimizerAction -Title $title

    # Voltar sem escolher só foi olhar: a tela termina sem faixa de resultado. Criar, trocar o dia ou remover dizem o que
    # ficou valendo. Por isso os avisos sobre a tarefa saem como avisos à vista (-Notice), e não como um desfecho.
    $final = $null

    try {
        # Mensagens de informação: na janela elas ficam visíveis no resumo enquanto a pessoa escolhe (a saída completa fica
        # recolhida durante a pergunta). O que roda todo mês, e quando, numa linha: com o PC desligado ao meio-dia, a
        # tarefa roda depois que você entrar no Windows (o Agendador espera uns 10 minutos); Lixeira, reparo, programas e
        # ajustes ficam de fora.
        Write-SnakeOptimizerStatus -Type Info -Message "Uma vez por mês, às $($script:SnakeOptimizerScheduleHour)h (ou depois que você entrar no Windows, se o PC estava desligado), apaga os temporários com mais de $($script:SnakeOptimizerScheduleTempDays) dias e salva um relatório. Nada mais muda; no notebook, só na tomada."

        $status = Get-SnakeOptimizerScheduleStatus
        $recreate = ($status.Installed -and ($status.ScriptMissing -or $status.Stale))

        if ([bool](Get-SnakeOptimizerJsonValue -Object $status -Name "QueryFailed" -Default $false)) {
            Write-SnakeOptimizerKeyValue -Label "Tarefa mensal" -Value "não foi possível consultar o Agendador de Tarefas" -Level Warn
        }
        elseif (-not $status.Installed) {
            Write-SnakeOptimizerKeyValue -Label "Tarefa mensal" -Value "Não agendada"
        }
        else {
            $when = $(if ($null -ne $status.Day) { "todo dia $($status.Day), às $($script:SnakeOptimizerScheduleHour)h" } else { "mensal" })
            $state = $(if (-not $status.Enabled) { "Desligada no Agendador de Tarefas ($when)" } elseif ($status.ScriptMissing) { "Ativa, mas a tarefa não vai funcionar ($when)" } else { "Ativa ($when)" })
            Write-SnakeOptimizerKeyValue -Label "Tarefa mensal" -Value $state -Level $(if (-not $status.Enabled -or $status.ScriptMissing) { "Warn" } else { "Normal" })

            if ($null -ne $status.NextRun) {
                Write-SnakeOptimizerKeyValue -Label "Próxima execução" -Value (Format-SnakeOptimizerDateTime -When $status.NextRun)
            }

            if ($status.OtherUser) {
                Write-SnakeOptimizerKeyValue -Label "Conta" -Value $status.Owner
                # O Windows guarda um agendamento só por PC: criar um aqui substitui o da outra conta, e remover tira o dela.
                Write-SnakeOptimizerStatus -Type Warning -Notice -Message "Este agendamento é da conta $($status.Owner) e limpa os temporários dela: criar ou remover aqui mexe no dela."
            }

            if ($status.ScriptMissing) {
                Write-SnakeOptimizerStatus -Type Warning -Notice -Message "A tarefa roda o SnakeOptimizer de uma pasta que não existe mais ($($status.ScriptPath)). Até ser recriada, ela falha todo mês."
            }
            elseif ($status.Stale) {
                Write-SnakeOptimizerStatus -Type Warning -Notice -Message "A tarefa roda o SnakeOptimizer de outra pasta ($($status.ScriptPath)), não deste. Se aquela pasta for apagada, a tarefa passa a falhar."
            }

            if ($recreate) {
                Write-SnakeOptimizerStatus -Type Info -Message "Para recriar a tarefa com esta pasta do SnakeOptimizer, escolha o dia abaixo."
            }
            elseif (-not $status.Enabled) {
                # Desligada no Agendador (por alguém, ou por um programa de "otimização"): escolher o dia cria a tarefa de
                # novo, já ligada.
                Write-SnakeOptimizerStatus -Type Info -Message "Para religar, escolha o dia abaixo: a tarefa é criada de novo, ligada."
            }
            elseif ($status.ScriptPath -and -not $status.OtherUser) {
                # Uma tarefa criada antes desta conferência, de uma pasta que outras contas alteram, continua rodando o que
                # estiver nela: a tela avisa, e recriar daqui é recusado até o SnakeOptimizer estar numa pasta só da pessoa.
                $writers = @(Get-SnakeOptimizerScheduleUntrustedWriters -Root (Split-Path -Path $status.ScriptPath -Parent))

                if ($writers.Count -gt 0) {
                    Write-SnakeOptimizerStatus -Type Warning -Notice -Message "A pasta que a tarefa roda pode ser alterada por outras contas deste PC ($(Join-SnakeOptimizerList -Items $writers)). Remova o agendamento, ou extraia o SnakeOptimizer de novo em Arquivos de Programas (C:\Program Files) e agende de lá."
                }
            }
        }

        $lastRun = Get-SnakeOptimizerScheduledRun

        # O registro do SnakeOptimizer só existe quando o script chegou a rodar: uma execução que falhou antes disso (o script não
        # existe mais) só aparece no Agendador. Vale a mais nova; e o resultado do Agendador também vale quando diz que a
        # execução terminou mal. A tarefa começa um pouco antes do script: a margem de um minuto separa as duas coisas.
        $fromScheduler = $false

        if ($status.Installed -and $null -ne $status.LastRun) {
            if ($null -eq $lastRun -or $status.LastRun -gt $lastRun.RunAt.AddMinutes(1)) { $fromScheduler = $true }
            elseif ($status.LastRunFailed -and $status.LastRun -ge $lastRun.RunAt.AddMinutes(-1)) { $fromScheduler = $true }
        }

        if ($fromScheduler) {
            Write-SnakeOptimizerKeyValue -Label "Última execução" -Value "$(Format-SnakeOptimizerDateTime -When $status.LastRun), $(ConvertTo-SnakeOptimizerScheduleResultText -Code $status.LastResult)"
        }
        elseif ($null -ne $lastRun) {
            $outcome = $(switch ($lastRun.Kind) { "Warning" { "; terminou com ressalvas" } "Failed" { "; não funcionou" } default { "" } })

            Write-SnakeOptimizerKeyValue -Label "Última execução" -Value "$(Format-SnakeOptimizerDateTime -When $lastRun.RunAt) ($(Format-SnakeOptimizerRelativeTime -When $lastRun.RunAt)), liberou $(Format-SnakeOptimizerBytes -Bytes $lastRun.FreedBytes)$outcome"

            if (-not [string]::IsNullOrWhiteSpace($lastRun.Report)) {
                Write-SnakeOptimizerKeyValue -Label "Relatório" -Value $lastRun.Report
            }
        }
        elseif ($status.Installed) {
            Write-SnakeOptimizerKeyValue -Label "Última execução" -Value "Ainda não executou"
        }

        Write-Host ""

        $options = @()

        foreach ($day in $script:SnakeOptimizerScheduleDays) {
            $current = ($status.Installed -and $status.Day -eq $day)
            $label = $(if ($current) { "Dia $day (atual)" } else { "Dia $day" })

            # O horário e o que acontece com o PC desligado estão na linha do alto: aqui, só o que muda de um dia a outro.
            $description = ""
            if ($current) { $description = $(if ($recreate) { "recria a tarefa com esta pasta do SnakeOptimizer" } else { "o dia de agora; escolher de novo recria a tarefa" }) }

            # Em destaque: o primeiro dia, quando não há tarefa; o dia atual (ou o primeiro, sem dia lido), quando a tarefa
            # precisa ser recriada.
            $accent = ($day -eq $script:SnakeOptimizerScheduleDays[0] -and (-not $status.Installed -or ($recreate -and $null -eq $status.Day))) -or ($current -and $recreate)

            $options += @{
                Key         = "D$day"
                Label       = $label
                Description = $description
                Accent      = $accent
            }
        }

        if ($status.Installed) {
            $options += @{ Key = "R"; Label = "Remover o agendamento"; Description = "a tarefa sai do Agendador de Tarefas; nada mais roda sozinho" }
        }

        $options += @{ Key = "V"; Label = "Voltar"; Exit = $true }

        $message = $(if ($status.Installed) { "Trocar o dia ou remover?" } else { "Em que dia do mês?" })
        $choice = Read-SnakeOptimizerChoice -Message $message -Options $options -DefaultKey "V" -ShowMenu

        Write-Host ""

        # Mexer no agendamento de outra conta só com a confirmação, com Não como padrão.
        if ($choice -match '^D([0-9]+)$|^R$' -and $status.OtherUser) {
            $question = $(if ($choice -eq "R") { "Remover o agendamento da conta $($status.Owner)?" } else { "Substituir o agendamento da conta $($status.Owner) pelo seu?" })

            if (-not (Confirm-SnakeOptimizerAction $question -DefaultKey N)) {
                Write-SnakeOptimizerStatus -Type Info -Message "O agendamento da conta $($status.Owner) ficou como estava."
                $choice = "V"
            }
        }

        if ($choice -match '^D([0-9]+)$') {
            $final = Register-SnakeOptimizerScheduledMaintenance -Day ([int]$Matches[1])
        }
        elseif ($choice -eq "R") {
            $final = Unregister-SnakeOptimizerScheduledMaintenance
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Ocorreu um erro na manutenção agendada: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    Exit-SnakeOptimizerAction -Result $final
}


Export-ModuleMember -Function *
