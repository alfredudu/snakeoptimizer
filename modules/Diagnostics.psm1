# Diagnósticos somente leitura: sistema, discos, dispositivos, eventos e reinício pendente.


function Get-SnakeOptimizerUptimeText {
    # Nullable: o CIM devolve $null quando não sabe a data do boot, e um parâmetro [datetime] comum transformaria isso
    # em "0001-01-01" (ou recusaria o valor), o que gerava um tempo ligado absurdo ou derrubava o relatório.
    param (
        [Nullable[datetime]]$LastBootTime
    )

    if ($null -eq $LastBootTime -or $LastBootTime.Year -lt 2000) {
        return "Desconhecido"
    }

    # Em UTC: a conta com a hora local erra uma hora quando o horário de verão começa ou termina no meio.
    $uptime = (Get-Date).ToUniversalTime() - ([datetime]$LastBootTime).ToUniversalTime()

    # Um boot "no futuro" (relógio atrasado depois de ligar) não tem tempo ligado que se possa dizer.
    if ($uptime.TotalMinutes -lt -5) {
        return "Desconhecido"
    }

    if ($uptime.TotalMinutes -lt 1) {
        return "menos de 1 minuto"
    }

    $parts = @()

    if ($uptime.Days -gt 0) {
        if ($uptime.Days -eq 1) { $parts += "1 dia" } else { $parts += "$($uptime.Days) dias" }
    }

    if ($uptime.Hours -gt 0) {
        if ($uptime.Hours -eq 1) { $parts += "1 hora" } else { $parts += "$($uptime.Hours) horas" }
    }

    if ($uptime.Minutes -gt 0 -or $parts.Count -eq 0) {
        if ($uptime.Minutes -eq 1) { $parts += "1 minuto" } else { $parts += "$($uptime.Minutes) minutos" }
    }

    # "2 dias, 3 horas e 5 minutos".
    return (Join-SnakeOptimizerList -Items $parts)
}


function Get-SnakeOptimizerDiskTypeText {
    param (
        [object]$Disk
    )

    if ($null -eq $Disk) {
        return "Não disponível"
    }

    $busType = ""
    $mediaType = ""

    if ($Disk.PSObject.Properties.Name -contains "BusType" -and $null -ne $Disk.BusType) {
        $busType = $Disk.BusType.ToString()
    }

    if ($Disk.PSObject.Properties.Name -contains "MediaType" -and $null -ne $Disk.MediaType) {
        $mediaType = $Disk.MediaType.ToString()
    }

    if ($busType -match "NVMe") { return "NVMe" }
    if ($mediaType -match "SSD") { return "SSD" }
    if ($mediaType -match "HDD") { return "HDD" }
    if ($busType -match "USB") { return "USB" }
    if ($busType -match "SATA") { return "SATA" }

    if (-not [string]::IsNullOrWhiteSpace($mediaType) -and $mediaType -ne "Unspecified") {
        return $mediaType
    }

    if (-not [string]::IsNullOrWhiteSpace($busType) -and $busType -ne "Unknown") {
        return $busType
    }

    return "Não disponível"
}


function Get-SnakeOptimizerDiskSummary {
    # Só a consulta fica no try: uma falha na conta de uma unidade não pode virar "não foi possível detectar" para todas.
    try {
        $logicalDisks = @(
            Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 3" -ErrorAction Stop |
            Sort-Object DeviceID
        )
    }
    catch {
        return @()
    }

    # Tipo e modelo vêm do disco físico (Get-PhysicalDisk tem MediaType: SSD ou HDD; o Get-Disk não tem). Cada consulta
    # é feita uma vez só: as partições dizem a letra e o número do disco, e o número é o DeviceId do disco físico.
    $diskNumberByLetter = @{}
    $physicalByNumber = @{}

    try {
        foreach ($partition in @(Get-Partition -ErrorAction Stop)) {
            $letter = [string]$partition.DriveLetter

            if ($letter -match '^[A-Za-z]$' -and $null -ne $partition.DiskNumber) {
                $diskNumberByLetter[$letter.ToUpperInvariant()] = [string]$partition.DiskNumber
            }
        }
    }
    catch {
        # Sem partições lidas: tipo e modelo ficam indisponíveis.
    }

    if ($diskNumberByLetter.Count -gt 0) {
        try {
            foreach ($physicalDisk in @(Get-PhysicalDisk -ErrorAction Stop)) {
                $physicalByNumber[[string]$physicalDisk.DeviceId] = $physicalDisk
            }
        }
        catch {
            # Idem: nunca empresta o disco físico de outra unidade.
        }
    }

    # A unidade do Windows segue a regra em gigabytes; as outras, a da porcentagem. Quem mostra a lista (a dica da Limpeza)
    # usa a mesma marca, em vez de comparar a letra de novo.
    $systemDrive = $(if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { "C:" } else { ([string]$env:SystemDrive).TrimEnd("\") })
    $diskSummary = @()

    foreach ($logicalDisk in $logicalDisks) {
        $driveId = [string]$logicalDisk.DeviceID

        # Uma entrada sem letra não teria como ser mostrada; ela não pode derrubar a lista das outras.
        if ([string]::IsNullOrWhiteSpace($driveId)) {
            continue
        }

        $driveLetter = $driveId.TrimEnd(":").ToUpperInvariant()
        $isSystem = ($driveId -eq $systemDrive)
        $disk = $null
        $diskModel = "Não disponível"
        $diskType = "Não disponível"

        # Só o disco desta unidade: associar o primeiro disco físico a todas daria dados errados com vários discos.
        if ($diskNumberByLetter.ContainsKey($driveLetter) -and $physicalByNumber.ContainsKey($diskNumberByLetter[$driveLetter])) {
            $disk = $physicalByNumber[$diskNumberByLetter[$driveLetter]]
        }

        if ($null -ne $disk) {
            if (-not [string]::IsNullOrWhiteSpace([string]$disk.FriendlyName)) {
                $diskModel = ([string]$disk.FriendlyName).Trim()
            }

            $diskType = Get-SnakeOptimizerDiskTypeText -Disk $disk
        }

        $totalBytes = $logicalDisk.Size
        $freeBytes = $logicalDisk.FreeSpace
        $known = ($null -ne $totalBytes -and [double]$totalBytes -gt 0 -and $null -ne $freeBytes)
        $usedBytes = $null
        $usedPercent = $null
        $level = "Unknown"

        # Sem o espaço livre, "0 B livres" e "100% usado" seriam inventados: o uso fica desconhecido.
        $freePercent = $null

        if ($known) {
            $usedBytes = [Math]::Max([double]0, [double]$totalBytes - [double]$freeBytes)

            # O livre arredonda para baixo: "pouco espaço (menos de 10% livre)" não pode dizer "10% livre"; e com espaço
            # livre de verdade, o uso não chega a "100%".
            $freePercent = [int][Math]::Min(100, [Math]::Floor(([Math]::Max([double]0, [double]$freeBytes) / [double]$totalBytes) * 100))
            $usedPercent = 100 - $freePercent
            if ($usedPercent -ge 100 -and [double]$freeBytes -gt 0) { $usedPercent = 99 }

            # Nível ("Ok", "Low", "Critical" ou "Unknown") segue a mesma regra da tela inicial e da Manutenção; numa
            # unidade que não é a do sistema, só a porcentagem conta.
            $level = Get-SnakeOptimizerDiskSpaceLevel -FreeBytes $freeBytes -TotalBytes $totalBytes -System $isSystem
        }

        $diskSummary += [PSCustomObject]@{
            Unidade    = $driveId
            Tipo       = $diskType
            Modelo     = $diskModel
            Total      = Format-SnakeOptimizerBytes -Bytes $totalBytes -ZeroText "Não disponível"
            Livre      = $(if ($known) { Format-SnakeOptimizerBytes -Bytes $freeBytes -ZeroText "0 B" } else { "Não disponível" })
            Usado      = $(if ($known) { Format-SnakeOptimizerBytes -Bytes $usedBytes -ZeroText "0 B" } else { "Não disponível" })
            Uso        = $(if ($null -ne $usedPercent) { "$usedPercent%" } else { "Não disponível" })
            UsoPercent = $usedPercent
            LivrePercent = $freePercent
            Nivel      = $level
            Sistema    = $isSystem
        }
    }

    return @($diskSummary)
}


function Get-SnakeOptimizerDiskSummaryText {
    # Uma unidade numa linha, igual na tela e no relatório: "477 GB livres de 931 GB (49% usado) · NVMe · Samsung SSD 980".
    # Tipo e modelo que o Windows não informou ficam de fora.
    param (
        [Parameter(Mandatory)]
        $Disk
    )

    $text = $(if ($null -ne $Disk.UsoPercent) { "$($Disk.Livre) livres de $($Disk.Total) ($($Disk.UsoPercent)% usado)" } else { "espaço livre desconhecido" })

    foreach ($part in @($Disk.Tipo, $Disk.Modelo)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$part) -and [string]$part -ne "Não disponível") {
            $text += " · $part"
        }
    }

    return $text
}


function Show-SnakeOptimizerDiskSummary {
    # Cada unidade é uma linha "rótulo : valor", que a janela mostra também no resumo (uma tabela ficaria só nos detalhes).
    # -PassThru devolve as letras das unidades com pouco espaço, para a faixa de resultado de quem chama.
    param (
        [switch]$PassThru
    )

    $disks = @(Get-SnakeOptimizerDiskSummary)

    if ($disks.Count -eq 0) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível detectar informações de disco."
        return
    }

    foreach ($disk in $disks) {
        Write-SnakeOptimizerKeyValue -Label $disk.Unidade -Value (Get-SnakeOptimizerDiskSummaryText -Disk $disk)
    }

    $lowDisks = @($disks | Where-Object { $_.Nivel -in @("Low", "Critical") })

    if ($PassThru) {
        foreach ($disk in $lowDisks) { [string]$disk.Unidade }
    }

    if ($lowDisks.Count -eq 0) {
        return
    }

    Write-Host ""

    # As mesmas palavras da tela inicial. No disco do Windows, "quase cheia" abaixo de 10 GB livres e "pouco espaço" abaixo
    # de 20 GB; nas outras unidades, abaixo de 5% e de 10% livres.
    foreach ($disk in $lowDisks) {
        if ($disk.Nivel -eq "Critical") {
            Write-SnakeOptimizerStatus -Type Warning -Message "A unidade $($disk.Unidade) está quase cheia: só $($disk.Livre) livres de $($disk.Total)."
        }
        else {
            $freePercent = Get-SnakeOptimizerJsonValue -Object $disk -Name "LivrePercent" -Default (100 - [int]$disk.UsoPercent)
            Write-SnakeOptimizerStatus -Type Warning -Message "A unidade $($disk.Unidade) está com pouco espaço: $($disk.Livre) livres de $($disk.Total) ($(if ([int]$freePercent -lt 1) { 'menos de 1%' } else { "$freePercent%" }) livre)."
        }
    }

    # A Limpeza trabalha no disco do Windows (temporários, caches); numa unidade de dados ela libera pouco (a Lixeira, a
    # pasta Downloads se ela estiver lá). A marca vem da lista (Sistema), com a mesma regra que decidiu o nível.
    $systemLow = @($lowDisks | Where-Object { [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "Sistema" -Default $false) })
    $otherLow = @($lowDisks | Where-Object { -not [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "Sistema" -Default $false) })

    if ($systemLow.Count -gt 0) {
        Write-SnakeOptimizerStatus -Type Info -Message "Para liberar espaço no disco do Windows, use Limpeza > Limpeza rápida ou Limpeza > Analisar uso de espaço."
    }

    if ($otherLow.Count -gt 0) {
        Write-SnakeOptimizerStatus -Type Info -Message "Em $(Join-SnakeOptimizerList -Items @($otherLow | ForEach-Object { $_.Unidade })), a Limpeza do SnakeOptimizer libera pouco (ela cuida do disco do Windows): mova ou apague arquivos grandes que você não usa."
    }
}


function Get-SnakeOptimizerCimOrNull {
    # Consulta CIM tolerante: uma classe indisponível (máquina virtual, WMI com defeito) não derruba a tela inteira.
    param (
        [Parameter(Mandatory)]
        [string]$ClassName
    )

    try {
        return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
    }
    catch {
        return @()
    }
}


function Get-SnakeOptimizerSecureBootState {
    <#
    O estado do Secure Boot: "On", "Off", "Legacy" (o Windows iniciou no modo BIOS legado), "NoAdmin" (a consulta pediu
    Administrador) ou "Unknown". A tela (Get-SnakeOptimizerSecureBootText) e a auditoria de segurança partem daqui.
    O Registro (SecureBoot\State) é legível sem Administrador; Confirm-SecureBootUEFI fica de reserva e, sem
    Administrador, recusa a consulta (acesso negado), o que antes aparecia como "não suportado" num PC com o Secure Boot
    ligado. Num PC com BIOS legado (sem UEFI) o cmdlet responde que a plataforma não tem suporte.
    #>
    # O tipo de firmware vem antes: com o Windows iniciado no modo BIOS legado, o valor do Secure Boot pode existir (em 0)
    # e "desligado" sugeriria uma opção que não está ao alcance. PEFirmwareType: 1 = BIOS legado, 2 = UEFI. É o modo em
    # que o Windows iniciou, e não o que a placa suporta: muitos PCs têm UEFI desligado (CSM).
    $firmware = Get-SnakeOptimizerRegistryValueOrNull -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "PEFirmwareType"

    if ($null -ne $firmware -and [string]$firmware -eq "1") {
        return "Legacy"
    }

    $state = Get-SnakeOptimizerRegistryValueOrNull -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State" -Name "UEFISecureBootEnabled"

    if ($null -ne $state -and [string]$state -in @("0", "1")) {
        return $(if ([int]$state -eq 1) { "On" } else { "Off" })
    }

    try {
        return $(if (Confirm-SecureBootUEFI -ErrorAction Stop) { "On" } else { "Off" })
    }
    catch {
        if ($_.Exception -is [System.PlatformNotSupportedException]) { return "Legacy" }
        if ($_.Exception -is [System.UnauthorizedAccessException]) { return "NoAdmin" }

        return "Unknown"
    }
}


function Get-SnakeOptimizerSecureBootText {
    # O estado do Secure Boot como a tela Sobre este PC o mostra (Get-SnakeOptimizerSecureBootState).
    switch (Get-SnakeOptimizerSecureBootState) {
        "On" { return "Ativado" }
        "Off" { return "Desativado" }
        "Legacy" { return "Indisponível (o Windows iniciou no modo BIOS legado)" }
        "NoAdmin" { return "Não verificado (requer Administrador)" }
        default { return "Desconhecido" }
    }
}


function Get-SnakeOptimizerMemoryModulesText {
    # "2 × 16 GB" quando os módulos são iguais; "8 GB + 16 GB" quando não são. Sem capacidade informada = $null.
    param (
        [object[]]$Modules = @()
    )

    $sizes = @(
        foreach ($module in @($Modules)) {
            $capacity = [double](Get-SnakeOptimizerJsonValue -Object $module -Name "Capacity" -Default 0)
            if ($capacity -gt 0) { Format-SnakeOptimizerBytes -Bytes $capacity }
        }
    )

    if ($sizes.Count -eq 0) {
        return $null
    }

    if (@($sizes | Select-Object -Unique).Count -eq 1) {
        return "$($sizes.Count) × $($sizes[0])"
    }

    return ($sizes -join " + ")
}


function Get-SnakeOptimizerMachineModelText {
    <#
    Fabricante e modelo do PC ("Dell Inc. Inspiron 15 3520"), o que um técnico pergunta primeiro (drivers, BIOS,
    garantia), a partir do Win32_ComputerSystem. Os textos de fábrica vazios ("System Product Name", "To Be Filled By
    O.E.M.", o "All Series" das placas ASUS) não dizem nada: sem um modelo de verdade, "" (num PC montado, a placa-mãe
    identifica). A Lenovo põe no Model o tipo da máquina ("20XWCTO1WW") e o nome no SystemFamily ("ThinkPad X1 Carbon
    Gen 9"): os dois aparecem. O fabricante não se repete quando o modelo já começa por ele ("HP Laptop 15").
    #>
    param ($System)

    if ($null -eq $System) { return "" }

    $placeholder = '^(To Be Filled By O\.E\.M\.|System manufacturer|System Product Name|System Version|Default string|O\.E\.M\.|OEM|Not Applicable|Not Specified|None|Unknown|Undefined|All Series|Type1ProductConfigId|Base Board Product Name|x\.x)$'
    $clean = { param ($value) $text = ([string]$value -replace '\s+', ' ').Trim(); $(if ($text -and $text -notmatch $placeholder) { $text } else { "" }) }

    $maker = & $clean (Get-SnakeOptimizerJsonValue -Object $System -Name "Manufacturer" -Default "")
    $model = & $clean (Get-SnakeOptimizerJsonValue -Object $System -Name "Model" -Default "")
    $family = & $clean (Get-SnakeOptimizerJsonValue -Object $System -Name "SystemFamily" -Default "")

    if ($maker -match '^lenovo$') {
        $maker = "Lenovo"
        if ($family -and $family -notmatch '^lenovo$') { $model = $(if ($model -and $model -ne $family) { "$family ($model)" } else { $family }) }
    }

    if (-not $model) { return "" }
    if (-not $maker -or $model.StartsWith($maker, [System.StringComparison]::OrdinalIgnoreCase)) { return $model }

    return "$maker $model"
}


function Show-SnakeOptimizerSystemInfo {
    Enter-SnakeOptimizerAction -Title "Sobre este PC"

    try {
        $baseBoard = Get-SnakeOptimizerCimOrNull -ClassName "Win32_BaseBoard" | Select-Object -First 1
        $bios = Get-SnakeOptimizerCimOrNull -ClassName "Win32_BIOS" | Select-Object -First 1
        $processors = @(Get-SnakeOptimizerCimOrNull -ClassName "Win32_Processor")
        $cpu = $processors | Select-Object -First 1
        $memoryModules = @(Get-SnakeOptimizerCimOrNull -ClassName "Win32_PhysicalMemory")
        $gpuList = @(Get-SnakeOptimizerCimOrNull -ClassName "Win32_VideoController")
        $os = Get-SnakeOptimizerCimOrNull -ClassName "Win32_OperatingSystem" | Select-Object -First 1
        $computerSystem = Get-SnakeOptimizerCimOrNull -ClassName "Win32_ComputerSystem" | Select-Object -First 1

        # RAM: a soma dos módulos; em máquinas virtuais a lista de módulos vem vazia e vale o total do sistema.
        $totalRamBytes = $null

        if ($memoryModules.Count -gt 0) {
            $totalRamBytes = ($memoryModules | Measure-Object -Property Capacity -Sum).Sum
        }

        if ($null -eq $totalRamBytes -or $totalRamBytes -le 0) {
            $totalRamBytes = $(if ($computerSystem) { Get-SnakeOptimizerJsonValue -Object $computerSystem -Name "TotalPhysicalMemory" -Default $null } else { $null })
        }

        $memoryType = "Não disponível"

        if ($memoryModules.Count -gt 0) {
            $memoryType = Convert-SnakeOptimizerMemoryType -Type ([int]$memoryModules[0].SMBIOSMemoryType)
        }

        # ForEach-Object em vez de Select-Object -ExpandProperty: se a propriedade não existir nesta versão do Windows,
        # a tela continua em vez de falhar inteira.
        $configuredSpeeds = @(
            $memoryModules |
            ForEach-Object { $_.ConfiguredClockSpeed } |
            Where-Object { $null -ne $_ -and $_ -gt 0 } |
            Select-Object -Unique
        )

        # MT/s, a unidade que o Gerenciador de Tarefas do Windows 11 passou a usar: é a taxa do nome do módulo (DDR4-3200),
        # não o clock em MHz (a metade dela).
        $ramClockText = $(if ($configuredSpeeds.Count -gt 0) { ($configuredSpeeds -join " / ") + " MT/s" } else { "Desconhecido" })
        $xmpText = Get-SnakeOptimizerExpoXmpStatus -MemoryModules $memoryModules

        # Núcleos e processadores lógicos de todos os processadores (placas com dois soquetes). MaxClockSpeed é a
        # frequência base: o WMI não informa o turbo, e o "clock atual" dele costuma repetir a base, por isso não aparece.
        $coreCount = [int](($processors | ForEach-Object { [int](Get-SnakeOptimizerJsonValue -Object $_ -Name "NumberOfCores" -Default 0) } | Measure-Object -Sum).Sum)
        $threadCount = [int](($processors | ForEach-Object { [int](Get-SnakeOptimizerJsonValue -Object $_ -Name "NumberOfLogicalProcessors" -Default 0) } | Measure-Object -Sum).Sum)
        $coresText = $null

        if ($coreCount -gt 0) {
            $coresText = Format-SnakeOptimizerCount -Count $coreCount -One "núcleo" -Many "núcleos"
            if ($threadCount -gt 0) { $coresText += ", " + (Format-SnakeOptimizerCount -Count $threadCount -One "processador lógico" -Many "processadores lógicos") }
        }

        $baseClock = $(if ($cpu) { [double](Get-SnakeOptimizerJsonValue -Object $cpu -Name "MaxClockSpeed" -Default 0) } else { 0 })
        $baseClockText = $(if ($baseClock -gt 0) { "$(Format-SnakeOptimizerNumber -Value ($baseClock / 1000) -Decimals 2) GHz" } else { $null })

        $validGpus = @(
            $gpuList | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.Name) -and
                $_.Name -notmatch "Microsoft Basic" -and
                $_.Name -notmatch "Remote" -and
                $_.Name -notmatch "Parsec"
            }
        )

        if ($validGpus.Count -eq 0) {
            $validGpus = @($gpuList | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        }

        $lastBootTime = $(if ($os) { $os.LastBootUpTime } else { $null })
        $pcUptimeText = "Desconhecido"
        $lastBootText = "Desconhecido"

        if ($null -ne $lastBootTime) {
            $pcUptimeText = Get-SnakeOptimizerUptimeText -LastBootTime $lastBootTime
            $lastBootText = Format-SnakeOptimizerDateTime -When $lastBootTime
        }

        # Sem nenhuma resposta do WMI, todos os campos viram "Não disponível" e a tela parece só incompleta.
        if (-not $os -and -not $cpu -and -not $baseBoard) {
            Write-SnakeOptimizerStatus -Type Warning -Message "O Windows não respondeu às consultas de hardware (WMI): os dados abaixo estão incompletos. Reiniciar o serviço Instrumentação de Gerenciamento do Windows pode resolver."
        }

        # O mesmo nome e a mesma versão da tela inicial ("Windows 11 Pro", 24H2), e não a legenda do WMI com "Microsoft"
        # nem a versão do núcleo (10.0.26100), que não diz nada a quem usa.
        $build = $(if ($os) { [int](Get-SnakeOptimizerJsonValue -Object $os -Name "BuildNumber" -Default 0) } else { 0 })
        $windowsName = $(if ($os) { Get-SnakeOptimizerWindowsName -Caption ([string](Get-SnakeOptimizerJsonValue -Object $os -Name "Caption" -Default "")) -Build $build } else { "" })
        $computer = $(if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { [Environment]::MachineName } else { $env:COMPUTERNAME })
        $user = $(if ([string]::IsNullOrWhiteSpace($env:USERNAME)) { [Environment]::UserName } else { $env:USERNAME })

        Write-SnakeOptimizerSection -Title "Sistema"
        Write-SnakeOptimizerKeyValue -Label "Computador" -Value $computer
        Write-SnakeOptimizerKeyValue -Label "Usuário" -Value $user

        # Num PC montado, os textos de fábrica ficam vazios e a seção Placa-mãe identifica o PC: a linha não aparece.
        $machine = Get-SnakeOptimizerMachineModelText -System $computerSystem
        if ($machine) { Write-SnakeOptimizerKeyValue -Label "Fabricante e modelo" -Value $machine }

        Write-SnakeOptimizerKeyValue -Label "Windows" -Value $windowsName
        Write-SnakeOptimizerKeyValue -Label "Versão" -Value (Get-SnakeOptimizerWindowsDisplayVersion)
        Write-SnakeOptimizerKeyValue -Label "Build" -Value $(if ($build -gt 0) { $build } else { $null })
        Write-SnakeOptimizerKeyValue -Label "Tempo ligado" -Value $pcUptimeText
        Write-SnakeOptimizerKeyValue -Label "Última inicialização" -Value $lastBootText

        # Um tempo ligado de dias num PC que a pessoa desliga toda noite parece erro: é a Inicialização Rápida.
        if ($null -ne $lastBootTime -and ((Get-Date).ToUniversalTime() - ([datetime]$lastBootTime).ToUniversalTime()).TotalDays -ge 1 -and (Get-SnakeOptimizerFastStartupText) -eq "Ativada") {
            Write-SnakeOptimizerStatus -Type Info -Message "O tempo ligado conta desde o último Reiniciar: com a Inicialização Rápida ligada, Desligar não zera a conta."
        }

        $rebootPending = Test-SnakeOptimizerPendingReboot
        Write-SnakeOptimizerKeyValue -Label "Reinício pendente" -Value $(if ($rebootPending) { "Sim" } else { "Não" }) -Level $(if ($rebootPending) { "Warn" } else { "Normal" })

        Write-SnakeOptimizerSection -Title "Placa-mãe"
        Write-SnakeOptimizerKeyValue -Label "Fabricante" -Value $(if ($baseBoard) { $baseBoard.Manufacturer } else { $null })
        Write-SnakeOptimizerKeyValue -Label "Modelo" -Value $(if ($baseBoard) { $baseBoard.Product } else { $null })

        Write-SnakeOptimizerSection -Title "BIOS e segurança"
        Write-SnakeOptimizerKeyValue -Label "Versão da BIOS" -Value $(if ($bios) { $bios.SMBIOSBIOSVersion } else { $null })
        Write-SnakeOptimizerKeyValue -Label "Secure Boot" -Value (Get-SnakeOptimizerSecureBootText)

        Write-SnakeOptimizerSection -Title "Processador"
        Write-SnakeOptimizerKeyValue -Label "CPU" -Value $(if ($cpu) { ([string]$cpu.Name).Trim() } else { $null })
        Write-SnakeOptimizerKeyValue -Label "Núcleos" -Value $coresText
        Write-SnakeOptimizerKeyValue -Label "Frequência base" -Value $baseClockText

        Write-SnakeOptimizerSection -Title "Memória"
        Write-SnakeOptimizerKeyValue -Label "RAM total" -Value (Format-SnakeOptimizerBytes -Bytes $totalRamBytes -ZeroText "Não disponível")
        Write-SnakeOptimizerKeyValue -Label "Módulos" -Value (Get-SnakeOptimizerMemoryModulesText -Modules $memoryModules)
        Write-SnakeOptimizerKeyValue -Label "Tipo" -Value $memoryType
        Write-SnakeOptimizerKeyValue -Label "Velocidade configurada" -Value $ramClockText
        Write-SnakeOptimizerKeyValue -Label "XMP/EXPO" -Value $xmpText

        # A nota fica junto do valor que ela explica (antes ia para o fim da tela, depois dos discos).
        if ($xmpText -like "Indicativo*" -or $xmpText -like "Velocidade padrão*") {
            Write-SnakeOptimizerStatus -Type Info -Message "XMP/EXPO é deduzido da velocidade em uso; o Windows não informa o perfil escolhido na BIOS."
        }

        Write-SnakeOptimizerSection -Title "Vídeo"

        if ($validGpus.Count -eq 0) {
            Write-SnakeOptimizerKeyValue -Label "GPU" -Value $null
        }

        $gpuNumber = 0

        foreach ($gpu in $validGpus) {
            # Uma linha em branco entre uma placa e outra; depois da última, a próxima seção já abre com a sua.
            if ($gpuNumber -gt 0) { Write-Host "" }
            $gpuNumber++

            $gpuName = ([string]$gpu.Name).Trim()

            if (Test-SnakeOptimizerIntegratedGpu -GpuName $gpuName) {
                $vramText = "Memória compartilhada / GPU integrada"
            }
            else {
                $registryVramBytes = Get-SnakeOptimizerGpuMemoryBytes -GpuName $gpuName

                # AdapterRAM é um valor de 32 bits e satura em 4 GB; o Registro só é consultado primeiro por isso.
                if ($null -ne $registryVramBytes -and $registryVramBytes -gt 0) {
                    $vramText = Format-SnakeOptimizerBytes -Bytes $registryVramBytes -ZeroText "Desconhecido"
                }
                elseif ($null -ne $gpu.AdapterRAM -and [double]$gpu.AdapterRAM -ge 4293918720) {
                    # O valor de 32 bits do WMI para em 4 GB: uma placa de 8 ou 12 GB também aparece assim.
                    $vramText = "4 GB ou mais"
                }
                else {
                    $vramText = Format-SnakeOptimizerBytes -Bytes $gpu.AdapterRAM -ZeroText "Desconhecido"
                }
            }

            Write-SnakeOptimizerKeyValue -Label "GPU" -Value $gpuName
            Write-SnakeOptimizerKeyValue -Label "Memória de vídeo" -Value $vramText
        }

        # O adaptador básico só sobra na lista quando não há outra placa: a de verdade está sem o driver do fabricante
        # (imagem sem aceleração, resolução errada, um monitor só). Um aviso só, mesmo com duas placas sem driver.
        if (@($validGpus | Where-Object { [string]$_.Name -match "Microsoft Basic Display" }).Count -gt 0) {
            Write-SnakeOptimizerStatus -Type Warning -Message "A placa de vídeo está sem o driver do fabricante (o Windows usa o driver básico). Instale-o em Atualizações > Atualizar drivers."
        }

        Write-SnakeOptimizerSection -Title "Discos"
        Show-SnakeOptimizerDiskSummary
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Ocorreu um erro ao ler as informações do sistema: $($_.Exception.Message)"
    }

    Exit-SnakeOptimizerAction
}


function Test-SnakeOptimizerPnpDeviceHasProblem {
    # Um dispositivo tem problema quando o Windows registrou um código de problema ou o estado é Error/Degraded.
    # Status "Unknown" sem código de problema é comum em dispositivos de software e não indica defeito.
    param (
        [Parameter(Mandatory)]
        $Device
    )

    # O mesmo código que a tela mostra (ConfigManagerErrorCode, com Problem de reserva): duas leituras diferentes
    # deixariam um dispositivo na lista com "sem código".
    # Um nome de problema que a tabela não conhece (de uma versão mais nova do Windows) também conta.
    $code = Get-SnakeOptimizerDeviceProblemCode -Device $Device
    $problem = [string](Get-SnakeOptimizerJsonValue -Object $Device -Name "Problem" -Default "")
    $unknownProblem = (-not [string]::IsNullOrWhiteSpace($problem)) -and ($problem -notin @("0", "CM_PROB_NONE"))
    $hasBadStatus = ([string](Get-SnakeOptimizerJsonValue -Object $Device -Name "Status" -Default "")) -in @("Error", "Degraded")

    return (([int]$code -gt 0) -or $unknownProblem -or $hasBadStatus)
}


function Get-SnakeOptimizerDeviceProblemCode {
    # O código do Gerenciador de Dispositivos (28 = driver não instalado...). Get-PnpDevice traz o número em
    # ConfigManagerErrorCode e o nome (CM_PROB_FAILED_INSTALL) em Problem; vale o que vier. Sem código = 0.
    param (
        [Parameter(Mandatory)]
        $Device
    )

    $number = 0
    $raw = [string](Get-SnakeOptimizerJsonValue -Object $Device -Name "ConfigManagerErrorCode" -Default "")

    if ([int]::TryParse($raw, [ref]$number) -and $number -gt 0) {
        return $number
    }

    $problem = [string](Get-SnakeOptimizerJsonValue -Object $Device -Name "Problem" -Default "")

    if ([int]::TryParse($problem, [ref]$number)) {
        return [Math]::Max(0, $number)
    }

    $byName = @{
        CM_PROB_NOT_CONFIGURED = 1; CM_PROB_OUT_OF_MEMORY = 3; CM_PROB_FAILED_START = 10; CM_PROB_NORMAL_CONFLICT = 12
        CM_PROB_NEED_RESTART = 14; CM_PROB_REINSTALL = 18; CM_PROB_REGISTRY = 19; CM_PROB_WILL_BE_REMOVED = 21
        CM_PROB_DISABLED = 22; CM_PROB_DEVICE_NOT_THERE = 24; CM_PROB_FAILED_INSTALL = 28; CM_PROB_HARDWARE_DISABLED = 29
        CM_PROB_FAILED_ADD = 31; CM_PROB_DISABLED_SERVICE = 32; CM_PROB_FAILED_DRIVER_ENTRY = 37
        CM_PROB_DRIVER_FAILED_PRIOR_UNLOAD = 38; CM_PROB_DRIVER_FAILED_LOAD = 39; CM_PROB_DRIVER_SERVICE_KEY_INVALID = 40
        CM_PROB_LEGACY_SERVICE_NO_DEVICES = 41; CM_PROB_DUPLICATE_DEVICE = 42; CM_PROB_FAILED_POST_START = 43
        CM_PROB_HALTED = 44; CM_PROB_PHANTOM = 45; CM_PROB_HELD_FOR_EJECT = 47; CM_PROB_DRIVER_BLOCKED = 48
        CM_PROB_UNSIGNED_DRIVER = 52
    }

    if ($byName.ContainsKey($problem)) {
        return [int]$byName[$problem]
    }

    return 0
}


function Get-SnakeOptimizerDeviceProblemText {
    # O problema de um dispositivo em português, com o código que o Gerenciador de Dispositivos mostra (para quem vai
    # procurar ajuda): "o driver não está instalado (código 28)".
    param (
        [Parameter(Mandatory)]
        $Device
    )

    $code = Get-SnakeOptimizerDeviceProblemCode -Device $Device

    $texts = @{
        1 = "o dispositivo não está configurado corretamente"; 3 = "faltou memória ou o driver está corrompido"
        10 = "o dispositivo não consegue iniciar"; 12 = "falta de recursos livres (conflito com outro dispositivo)"
        14 = "o dispositivo só funciona depois de reiniciar o PC"; 18 = "os drivers precisam ser reinstalados"
        19 = "a configuração no Registro está incompleta ou danificada"; 21 = "o Windows está removendo o dispositivo"
        22 = "desativado"; 24 = "ausente, com defeito ou sem todos os drivers"; 28 = "o driver não está instalado"
        29 = "desativado pelo firmware (BIOS/UEFI)"; 31 = "o Windows não consegue carregar o driver"
        32 = "o serviço do driver está desativado"; 37 = "o driver não conseguiu iniciar"
        38 = "uma cópia anterior do driver ainda está na memória"; 39 = "o driver está corrompido ou ausente"
        40 = "a configuração do driver no Registro está errada"; 41 = "o driver carregou, mas não encontrou o hardware"
        42 = "há um dispositivo duplicado em uso"; 43 = "o Windows parou o dispositivo porque ele informou um problema"
        44 = "um programa ou serviço desligou o dispositivo"; 45 = "o dispositivo não está conectado"
        47 = "preparado para remoção segura e ainda conectado"; 48 = "o driver foi bloqueado por ter problemas conhecidos com o Windows"
        52 = "o Windows não consegue verificar a assinatura digital do driver"
    }

    if ($code -gt 0) {
        $text = $(if ($texts.ContainsKey($code)) { $texts[$code] } else { "problema informado pelo Windows" })
        return "$text (código $code)"
    }

    switch ([string](Get-SnakeOptimizerJsonValue -Object $Device -Name "Status" -Default "")) {
        "Degraded" { return "funcionando com problemas (estado degradado)" }
        default { return "o Windows marca o dispositivo com erro" }
    }
}


function Get-SnakeOptimizerDeviceName {
    # Nome para a pessoa: o nome amigável e, entre parênteses, a categoria em português ("Rede", "Vídeo"...).
    param (
        [Parameter(Mandatory)]
        $Device
    )

    $name = ""

    foreach ($field in @("FriendlyName", "Name", "InstanceId")) {
        $name = ([string](Get-SnakeOptimizerJsonValue -Object $Device -Name $field -Default "")).Trim()
        if ($name) { break }
    }

    if (-not $name) { $name = "Dispositivo sem nome" }

    $classes = @{
        Net = "Rede"; Display = "Vídeo"; MEDIA = "Som e vídeo"; AudioEndpoint = "Áudio"; Bluetooth = "Bluetooth"
        Camera = "Câmera"; Image = "Câmera ou scanner"; USB = "USB"; HIDClass = "Dispositivo de entrada"; Keyboard = "Teclado"
        Mouse = "Mouse"; Monitor = "Monitor"; Printer = "Impressora"; DiskDrive = "Disco"; HDC = "Controladora de disco"
        SCSIAdapter = "Controladora de armazenamento"; System = "Sistema"; Battery = "Bateria"; Biometric = "Biometria"
        SoftwareDevice = "Dispositivo virtual"; Ports = "Portas"; SmartCardReader = "Leitor de cartão"
    }

    $class = ([string](Get-SnakeOptimizerJsonValue -Object $Device -Name "Class" -Default "")).Trim()

    if (-not $class) { return $name }

    $classText = $(if ($classes.ContainsKey($class)) { $classes[$class] } else { $class })

    return "$name ($classText)"
}


function Show-SnakeOptimizerProblemDevices {
    Enter-SnakeOptimizerAction -Title "Dispositivos com problema"

    try {
        # -ErrorAction Stop: na janela, um erro comum da consulta (o serviço do WMI parado) só seria escrito, a lista
        # viria vazia e a tela diria "nenhum dispositivo com problema" sem ter olhado.
        $problemDevices = @(
            Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { Test-SnakeOptimizerPnpDeviceHasProblem -Device $_ }
        )

        # Desativado (código 22, pelo Gerenciador; 29, pelo firmware ou pela BIOS) é uma escolha de alguém, não um defeito:
        # fica numa seção à parte, sem alarme.
        $realProblems = @($problemDevices | Where-Object { (Get-SnakeOptimizerDeviceProblemCode -Device $_) -notin @(22, 29) })
        $disabledDevices = @($problemDevices | Where-Object { (Get-SnakeOptimizerDeviceProblemCode -Device $_) -in @(22, 29) })

        Write-SnakeOptimizerSection -Title "Problemas ativos"

        if ($realProblems.Count -eq 0) {
            Write-SnakeOptimizerStatus -Type Success -Message "Nenhum dispositivo com problema."
        }
        else {
            # Cada dispositivo numa linha de aviso: a janela as mostra no resumo (uma tabela ficaria só nos detalhes). O
            # identificador do Windows vai embaixo, em cinza, para quem precisar pesquisar.
            Write-SnakeOptimizerStatus -Type Warning -Message "$(Format-SnakeOptimizerCount -Count $realProblems.Count -One 'dispositivo' -Many 'dispositivos') com problema ativo:"

            foreach ($device in $realProblems) {
                Write-SnakeOptimizerStatus -Type Warning -Message "$(Get-SnakeOptimizerDeviceName -Device $device): $(Get-SnakeOptimizerDeviceProblemText -Device $device)."

                $instance = [string](Get-SnakeOptimizerJsonValue -Object $device -Name "InstanceId" -Default "")
                if ($instance) { Write-Host "      $instance" -ForegroundColor DarkGray }
            }

            Write-Host ""

            # Código 14: o dispositivo só volta a funcionar depois de reiniciar (o Gerenciador não resolve).
            if (@($realProblems | Where-Object { (Get-SnakeOptimizerDeviceProblemCode -Device $_) -eq 14 }).Count -gt 0) {
                Write-SnakeOptimizerStatus -Type Info -Message "Reinicie o PC: o Windows pede o reinício para terminar de preparar um dispositivo."
            }

            Write-SnakeOptimizerStatus -Type Info -Message "Para tentar resolver, use Reparo > Detectar dispositivos e drivers e depois Atualizações > Atualizar drivers."
            Write-SnakeOptimizerStatus -Type Info -Message "Se continuar, abra Diagnóstico > Gerenciador de Dispositivos, clique com o botão direito no dispositivo e escolha Atualizar driver. Se ele não aparecer lá, ligue Mostrar dispositivos ocultos, no menu Exibir."
        }

        if ($disabledDevices.Count -gt 0) {
            Write-SnakeOptimizerSection -Title "Dispositivos desativados"

            foreach ($device in $disabledDevices) {
                Write-SnakeOptimizerStatus -Type Info -Message (Get-SnakeOptimizerDeviceName -Device $device)
            }

            Write-Host ""
            Write-SnakeOptimizerStatus -Type Info -Message "Dispositivos desativados podem ser intencionais, como uma placa de vídeo integrada desligada de propósito; para religar, use Diagnóstico > Gerenciador de Dispositivos."
        }

        # Sem problema ativo, a dica de onde procurar drivers mais novos (com problema, ela já está no que fazer acima).
        if ($realProblems.Count -eq 0) {
            Write-Host ""
            Write-SnakeOptimizerStatus -Type Info -Message "Isto mostra os dispositivos com erro agora; para procurar drivers mais novos, use Atualizações > Atualizar drivers."
        }

        # A faixa de resultado diz a contagem (a última linha de aviso seria a de um dispositivo qualquer).
        $result = $(if ($realProblems.Count -gt 0) {
                New-SnakeOptimizerResult -Kind Warning -Detail "$(Format-SnakeOptimizerCount -Count $realProblems.Count -One 'dispositivo' -Many 'dispositivos') com problema ativo"
            }
            else {
                New-SnakeOptimizerResult -Kind Ok -Detail "nenhum dispositivo com problema ativo"
            })
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível consultar os dispositivos: $($_.Exception.Message)"
        $result = $null
    }

    Exit-SnakeOptimizerAction -Result $result
}


function Show-SnakeOptimizerDisks {
    Enter-SnakeOptimizerAction -Title "Discos e espaço livre"

    $result = $null

    try {
        Write-SnakeOptimizerSection -Title "Volumes e discos"
        $lowDrives = @(Show-SnakeOptimizerDiskSummary -PassThru)

        # Com uma unidade só, o aviso dela já é a frase da faixa; com várias, a faixa cita todas (e não só a última).
        if ($lowDrives.Count -gt 1) {
            $result = New-SnakeOptimizerResult -Kind Warning -Detail "pouco espaço em $(Join-SnakeOptimizerList -Items $lowDrives)"
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Ocorreu um erro ao consultar informações de disco: $($_.Exception.Message)"
    }

    Exit-SnakeOptimizerAction -Result $result
}


function Get-SnakeOptimizerFastStartupText {
    # A Inicialização Rápida guarda o estado em HiberbootEnabled, que continua em 1 mesmo depois de desligar a
    # hibernação; mas ela usa o arquivo de hibernação, então sem a hibernação não tem efeito.
    $fast = Get-SnakeOptimizerRegistryValueOrNull -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled"

    if ($null -eq $fast -or ([string]$fast -notin @("0", "1"))) {
        return "Desconhecido"
    }

    if ([int]$fast -eq 0) {
        return "Desativada"
    }

    if ((Get-SnakeOptimizerHibernationText) -eq "Desativada") {
        return "Sem efeito: a hibernação está desligada, e a Inicialização Rápida depende dela"
    }

    return "Ativada"
}


function Get-SnakeOptimizerHibernationText {
    # A hibernação (HibernateEnabled): é dela que a Inicialização Rápida depende.
    $hibernate = Get-SnakeOptimizerRegistryValueOrNull -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled"

    switch ([string]$hibernate) {
        "1" { return "Ativada" }
        "0" { return "Desativada" }
        default { return "Desconhecido" }
    }
}


function Show-SnakeOptimizerStartupInfo {
    Enter-SnakeOptimizerAction -Title "Tempo ligado e energia"

    try {
        $os = Get-SnakeOptimizerCimOrNull -ClassName "Win32_OperatingSystem" | Select-Object -First 1
        $lastBootTime = $(if ($os) { $os.LastBootUpTime } else { $null })

        Write-SnakeOptimizerSection -Title "Inicialização"

        if ($null -ne $lastBootTime) {
            Write-SnakeOptimizerKeyValue -Label "Tempo ligado" -Value (Get-SnakeOptimizerUptimeText -LastBootTime $lastBootTime)
            Write-SnakeOptimizerKeyValue -Label "Última inicialização" -Value (Format-SnakeOptimizerDateTime -When $lastBootTime)
        }
        else {
            Write-SnakeOptimizerStatus -Type Warning -Message "Inicialização: desconhecida (o Windows não informou quando o PC foi ligado)."
        }

        $fastStartup = Get-SnakeOptimizerFastStartupText

        Write-SnakeOptimizerSection -Title "Inicialização Rápida"
        Write-SnakeOptimizerKeyValue -Label "Situação" -Value $fastStartup

        if ($fastStartup -eq "Ativada") {
            Write-SnakeOptimizerStatus -Type Info -Message "Com a Inicialização Rápida ligada, desligar o PC não zera o tempo ligado: só Reiniciar faz o Windows começar do zero."
        }

        # O que a pessoa costuma procurar aqui ("o PC demora para ligar"): a causa mais comum são os programas que abrem
        # junto com o Windows.
        Write-SnakeOptimizerStatus -Type Info -Message "Se o PC demora para ligar, veja o que abre junto com o Windows em Desempenho > Gerenciar inicialização."

        Write-SnakeOptimizerSection -Title "Hibernação e modos de energia"
        Write-SnakeOptimizerKeyValue -Label "Hibernação" -Value (Get-SnakeOptimizerHibernationText)

        # A lista de modos de energia (suspensão, hibernação...) é a do powercfg, no idioma do Windows.
        if (Get-Command "powercfg.exe" -ErrorAction SilentlyContinue) {
            Write-Host ""
            $exitCode = Invoke-SnakeOptimizerNative -FilePath "powercfg.exe" -Arguments @("/a") -IgnoreExitCode -PassThru

            if ($exitCode -ne 0) {
                Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível listar os modos de energia (powercfg finalizou com código $exitCode)."
            }
        }
        else {
            Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível listar os modos de energia: powercfg.exe não foi encontrado."
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível ler o tempo ligado e a energia: $($_.Exception.Message)"
    }

    Exit-SnakeOptimizerAction
}


function Test-SnakeOptimizerStartupTargetMissing {
    <#
    Se um item de inicialização abre um arquivo que com certeza não existe mais (num disco fixo): aí nada abre com o
    Windows, e o item não entra na lista (a Limpeza do registro remove as entradas Run quebradas). -Shortcut: Command é
    um atalho (.lnk), e o que conta é o destino dele. Na dúvida (sem caminho completo, rede, pendrive, atalho sem destino
    como os da Store e os anunciados do Windows Installer), o arquivo conta como existente.
    #>
    param (
        [AllowEmptyString()][string]$Command,
        [switch]$Shortcut
    )

    try {
        if ($Shortcut) {
            $link = Get-SnakeOptimizerShortcutTarget -Path $Command
            $target = $(if ($null -ne $link) { [string]$link.TargetPath } else { "" })
        }
        else {
            # Sem aspas, um caminho com espaços sem extensão no fim não é reconhecido: fica como "não sei".
            $target = Get-SnakeOptimizerCommandTargetPath -Command $Command
        }

        if ([string]::IsNullOrWhiteSpace($target)) { return $false }

        # -Wow64: um programa de 32 bits pode ter gravado o caminho de System32 que, para ele, é o SysWOW64.
        return [bool](Test-SnakeOptimizerLocalPathMissing -Path $target -Wow64)
    }
    catch {
        return $false
    }
}


function Get-SnakeOptimizerStartupAppStates {
    <#
    O liga/desliga das tarefas de inicialização de aplicativos empacotados (Store, MSIX) que o Windows já registrou na
    conta: HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\
    <família do pacote>\<TaskId>, DWORD State, com os números de Windows.ApplicationModel.StartupTaskState: 0 desativada
    (pelo próprio aplicativo), 1 desativada pela pessoa (Gerenciador de Tarefas ou Configurações; o aplicativo não
    consegue se religar), 2 ativada, 3 desativada por política, 4 ativada por política. Devolve Family, TaskId, State e
    Path (a chave, como HKCU:\...). Lido pelo .NET, sem o provedor do PowerShell: SystemAppData tem centenas de chaves.
    Sem acesso (ou fora do Windows), nenhuma.
    #>
    $relative = "Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData"
    $states = @()
    $root = $null

    try {
        $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relative)

        if ($null -eq $root) { return @() }

        foreach ($family in @($root.GetSubKeyNames())) {
            $familyKey = $null

            # Uma chave sem permissão de leitura não derruba as outras.
            try {
                $familyKey = $root.OpenSubKey($family)

                if ($null -eq $familyKey) { continue }

                foreach ($taskId in @($familyKey.GetSubKeyNames())) {
                    $taskKey = $null

                    try {
                        $taskKey = $familyKey.OpenSubKey($taskId)

                        if ($null -ne $taskKey -and @($taskKey.GetValueNames()) -contains "State" -and [string]$taskKey.GetValueKind("State") -eq "DWord") {
                            $states += [PSCustomObject]@{ Family = $family; TaskId = $taskId; State = [int]$taskKey.GetValue("State"); Path = "HKCU:\$relative\$family\$taskId" }
                        }
                    }
                    catch {
                        # Sem acesso a esta tarefa: fica de fora.
                    }
                    finally {
                        if ($null -ne $taskKey) { $taskKey.Close() }
                    }
                }
            }
            catch {
                # Sem acesso a este pacote: fica de fora.
            }
            finally {
                if ($null -ne $familyKey) { $familyKey.Close() }
            }
        }
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $root) { $root.Close() }
    }

    return @($states)
}


function Get-SnakeOptimizerStartupPackagedApps {
    <#
    Os aplicativos empacotados (Store, MSIX: Teams, Spotify, WhatsApp...) que têm tarefa de inicialização, no formato dos
    itens de Get-SnakeOptimizerStartupItems, com Publisher. ApprovedPath é a chave da tarefa, onde o Windows guarda o State.

    Só entra o que dá para ligar e desligar como as Configurações fazem: a tarefa que o Windows já registrou na conta,
    com State 0, 1 ou 2, de um pacote instalado para a conta que declara essa tarefa no manifesto (uma chave que sobrou
    de um aplicativo desinstalado não entra). State 3 e 4 são de política (quem decide é o administrador) e ficam de
    fora; uma tarefa ainda não registrada (o aplicativo nunca foi aberto) não abre com o Windows e também fica de fora.
    Sem o Get-AppxPackage, nenhum.
    #>
    $items = @()
    $startNames = $null

    foreach ($state in @(Get-SnakeOptimizerStartupAppStates)) {
        if (@(0, 1, 2) -notcontains [int]$state.State) { continue }

        $family = [string]$state.Family
        $cut = $family.LastIndexOf("_")

        if ($cut -lt 1) { continue }

        try {
            $package = @(Get-AppxPackage -Name $family.Substring(0, $cut) -ErrorAction Stop | Where-Object { $null -ne $_ -and [string]$_.PackageFamilyName -eq $family }) | Select-Object -First 1

            if ($null -eq $package) { continue }

            $manifest = Get-AppxPackageManifest -Package ([string]$package.PackageFullName) -ErrorAction Stop
        }
        catch {
            continue
        }

        if ($null -eq $manifest) { continue }

        # A tarefa no manifesto: uap5:StartupTask (ou desktop:StartupTask, nos pacotes de programas clássicos).
        $taskNode = $null

        foreach ($node in @($manifest.SelectNodes("//*[local-name()='Extension'][@Category='windows.startupTask']/*[local-name()='StartupTask']"))) {
            if ([string]$node.GetAttribute("TaskId") -eq [string]$state.TaskId) {
                $taskNode = $node
                break
            }
        }

        if ($null -eq $taskNode) { continue }

        # O nome que o Gerenciador de Tarefas mostra é o DisplayName da tarefa; quando ele é um recurso traduzido
        # (ms-resource:), vale o nome do aplicativo no menu Iniciar e, sem ele, o nome do pacote.
        $name = ([string]$taskNode.GetAttribute("DisplayName")).Trim()

        if ([string]::IsNullOrWhiteSpace($name) -or $name -like "ms-resource:*") {
            if ($null -eq $startNames) {
                $startNames = @{}

                try {
                    foreach ($app in @(Get-StartApps -ErrorAction Stop)) {
                        if ($null -ne $app -and -not [string]::IsNullOrWhiteSpace([string]$app.AppID)) { $startNames[[string]$app.AppID] = [string]$app.Name }
                    }
                }
                catch {
                    # Sem o menu Iniciar, o nome do pacote.
                }
            }

            $application = $taskNode.ParentNode.ParentNode.ParentNode
            $appId = $(if ($application -is [System.Xml.XmlElement]) { "$family!" + [string]$application.GetAttribute("Id") } else { "" })
            $name = $(if ($appId -and $startNames.ContainsKey($appId) -and $startNames[$appId]) { $startNames[$appId] } else { [string]$package.Name })
        }

        $publisherNode = $manifest.SelectSingleNode("//*[local-name()='Properties']/*[local-name()='PublisherDisplayName']")
        $publisher = $(if ($null -ne $publisherNode) { ([string]$publisherNode.InnerText).Trim() } else { "" })

        if ($publisher -like "ms-resource:*") { $publisher = "" }

        $items += [PSCustomObject]@{
            Name = $name; Source = "Aplicativo da Store"; Enabled = ([int]$state.State -eq 2)
            Command = ""; Scope = "User"; ApprovedPath = [string]$state.Path; Publisher = $publisher
        }
    }

    return @($items)
}


function Get-SnakeOptimizerStartupItems {
    <#
    Os programas que abrem junto com o Windows, os mesmos do Gerenciador de Tarefas (Aplicativos de inicialização) e de
    Configurações, Aplicativos, Inicialização: as chaves Run (usuário, todos os usuários e 32 bits), as pastas
    Inicializar (usuário e todos os usuários) e os aplicativos da Store com tarefa de inicialização. Enabled é falso
    para o que foi desativado ali: o Windows mantém o item e só marca o liga/desliga (StartupApproved, primeiro byte
    ímpar = desativado; nos aplicativos da Store, o State da tarefa). Scope: User (só esta conta) ou Machine (todos os
    usuários, pede Administrador); ApprovedPath: onde o Windows guarda o liga/desliga do item.

    Ficam de fora, de propósito:
    - RunOnce: roda uma vez só (em geral, o fim de uma instalação) e não tem liga/desliga; tirar seria apagar, e apagar
      estraga a instalação. O Gerenciador de Tarefas também não mostra.
    - As chaves Run de Policies\Explorer: são de política; o Windows não deixa desativar.
    - Valores vazios ou que não são texto, e o que aponta para um arquivo que com certeza não existe mais: não abrem nada.
    - Num PowerShell de 32 bits num Windows de 64 bits, as chaves Run de todos os usuários: o Windows troca a de 64 bits
      pela de 32 por baixo, e a lista sairia repetida, com o liga/desliga gravado no lugar errado.
    #>
    param (
        # Pastas Inicializar do usuário e de todos os usuários; o padrão são as do Windows.
        [string]$UserFolder = [Environment]::GetFolderPath("Startup"),
        [string]$CommonFolder = [Environment]::GetFolderPath("CommonStartup")
    )

    $approvedRoot = "Microsoft\Windows\CurrentVersion\Explorer\StartupApproved"
    $runKey = "Microsoft\Windows\CurrentVersion\Run"
    $items = @()

    $isDisabled = {
        param ($Approved, $Name)

        if (-not $Approved.Contains($Name)) { return $false }

        $bytes = @($Approved[$Name])

        return ($bytes.Count -gt 0 -and ([int]$bytes[0] -band 1) -eq 1)
    }

    $registrySources = @(
        @{ Source = "Registro (usuário)"; Scope = "User"; Path = "HKCU:\Software\$runKey"; Approved = "HKCU:\Software\$approvedRoot\Run" }
    )

    if (-not (Test-SnakeOptimizerRegistryViewMismatch)) {
        $registrySources += @(
            @{ Source = "Registro (todos os usuários)"; Scope = "Machine"; Path = "HKLM:\SOFTWARE\$runKey"; Approved = "HKLM:\SOFTWARE\$approvedRoot\Run" },
            @{ Source = "Registro (32 bits)"; Scope = "Machine"; Path = "HKLM:\SOFTWARE\WOW6432Node\$runKey"; Approved = "HKLM:\SOFTWARE\$approvedRoot\Run32" }
        )
    }

    foreach ($source in $registrySources) {
        $approved = Get-SnakeOptimizerRegistryValues -Path $source.Approved
        $commands = Get-SnakeOptimizerRegistryValues -Path $source.Path

        foreach ($name in @($commands.Keys)) {
            $command = $commands[$name]

            if (-not ($command -is [string]) -or [string]::IsNullOrWhiteSpace($command)) { continue }
            if (Test-SnakeOptimizerStartupTargetMissing -Command $command) { continue }

            # Command: o que o Windows executa; Scope e ApprovedPath dizem onde o Windows guarda o liga/desliga do item.
            $items += [PSCustomObject]@{
                Name = $name; Source = $source.Source; Enabled = -not (& $isDisabled $approved $name)
                Command = $command; Scope = $source.Scope; ApprovedPath = $source.Approved
            }
        }
    }

    $folders = @(
        @{ Path = $UserFolder; Scope = "User"; Approved = "HKCU:\Software\$approvedRoot\StartupFolder" },
        @{ Path = $CommonFolder; Scope = "Machine"; Approved = "HKLM:\SOFTWARE\$approvedRoot\StartupFolder" }
    )
    $seenFolders = @()

    foreach ($folder in $folders) {
        if ([string]::IsNullOrWhiteSpace($folder.Path) -or -not (Test-Path -LiteralPath $folder.Path -PathType Container)) {
            continue
        }

        # A mesma pasta nos dois lugares entraria duas vezes, cada uma com um liga/desliga.
        $folderKey = $folder.Path.TrimEnd('\', '/')

        if ($seenFolders -contains $folderKey) { continue }

        $seenFolders += $folderKey
        $approved = Get-SnakeOptimizerRegistryValues -Path $folder.Approved

        foreach ($file in @(Get-ChildItem -LiteralPath $folder.Path -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "desktop.ini" })) {
            if ($file.Extension -ieq ".lnk" -and (Test-SnakeOptimizerStartupTargetMissing -Command $file.FullName -Shortcut)) { continue }

            $items += [PSCustomObject]@{
                Name = $file.Name; Source = "Pasta Inicializar"; Enabled = -not (& $isDisabled $approved $file.Name)
                Command = $file.FullName; Scope = $folder.Scope; ApprovedPath = $folder.Approved
            }
        }
    }

    $items += @(Get-SnakeOptimizerStartupPackagedApps)

    return @($items)
}


function Get-SnakeOptimizerPendingReboot {
    # Retorna uma lista de motivos. Strong = sinal confiável; PendingFileRenameOperations
    # aparece em muitas máquinas sem reinício realmente necessário.
    $reasons = @()

    if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $reasons += [PSCustomObject]@{ Reason = "Uma atualização do Windows termina de instalar no reinício"; Strong = $true }
    }

    # Também da CBS: pacotes instalados que só terminam no reinício, ou um reinício que já começou a ser preparado.
    elseif ((Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending") -or
        (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress")) {
        $reasons += [PSCustomObject]@{ Reason = "Uma atualização do Windows termina de instalar no reinício"; Strong = $true }
    }

    if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $reasons += [PSCustomObject]@{ Reason = "Windows Update: uma atualização instalada espera o reinício"; Strong = $true }
    }

    # Um serviço do Windows Update esperando o reinício para se registrar: sinal fraco (a chave pode sobrar vazia, ou com
    # um item antigo, e um reinício não a limpa sempre). Só com algo dentro.
    if (@(Get-ChildItem -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Services\Pending" -ErrorAction SilentlyContinue).Count -gt 0) {
        $reasons += [PSCustomObject]@{ Reason = "Windows Update: um serviço de atualização espera o reinício para se registrar (sinal fraco)"; Strong = $false }
    }

    # Um instalador de atualização que marcou o volume para terminar no reinício (UpdateExeVolatile com Flags diferente de 0).
    $volatile = Get-SnakeOptimizerRegistryValueOrNull -Path "HKLM:\SOFTWARE\Microsoft\Updates" -Name "UpdateExeVolatile"

    if ($null -ne $volatile -and [string]$volatile -match '^[0-9]+$' -and [int64]$volatile -ne 0) {
        $reasons += [PSCustomObject]@{ Reason = "Um instalador de atualização termina o trabalho no reinício"; Strong = $true }
    }

    $activeName = Get-SnakeOptimizerRegistryValueOrNull -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "ComputerName"
    $pendingName = Get-SnakeOptimizerRegistryValueOrNull -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "ComputerName"

    if (-not [string]::IsNullOrWhiteSpace($activeName) -and -not [string]::IsNullOrWhiteSpace($pendingName) -and $activeName -ne $pendingName) {
        $reasons += [PSCustomObject]@{ Reason = "Renomeação do computador: o nome $pendingName vale depois do reinício"; Strong = $true }
    }

    # Entrar num domínio (ou trocar de domínio) só vale depois do reinício.
    $netlogon = "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon"

    if ((Test-Path -LiteralPath "$netlogon\JoinDomain") -or (Test-Path -LiteralPath "$netlogon\AvoidSpnSet")) {
        $reasons += [PSCustomObject]@{ Reason = "Entrada num domínio: vale depois do reinício"; Strong = $true }
    }

    $fileRename = Get-SnakeOptimizerRegistryValueOrNull -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations"

    if ($null -ne $fileRename -and @($fileRename).Count -gt 0) {
        $reasons += [PSCustomObject]@{ Reason = "Arquivos aguardando substituição no próximo reinício (sinal fraco: aparece em muitos PCs sem que o reinício seja necessário)"; Strong = $false }
    }

    return @($reasons)
}


function Test-SnakeOptimizerPendingReboot {
    return (@(Get-SnakeOptimizerPendingReboot | Where-Object { $_.Strong }).Count -gt 0)
}


function Test-SnakeOptimizerServicingRebootPending {
    <#
    Se a manutenção dos componentes do Windows (CBS) espera um reinício: só aí o DISM recusa a limpeza e o reparo
    (0x800F0806) e o SFC também. Um driver do Windows Update esperando o reinício, um nome novo do PC ou a entrada num
    domínio não atrapalham o DISM e o SFC, e não seguram essas etapas. Pelas chaves da CBS e pelo pending.xml.
    #>
    $cbs = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing"

    # Caminhos montados como texto: o Join-Path recusa (com erro na tela) uma unidade que não existe.
    foreach ($key in @("RebootPending", "PackagesPending", "RebootInProgress")) {
        if (Test-Path -LiteralPath "$cbs\$key" -ErrorAction SilentlyContinue) { return $true }
    }

    $windows = [string]$env:windir
    if ([string]::IsNullOrWhiteSpace($windows)) { return $false }

    return [bool](Test-Path -LiteralPath ($windows.TrimEnd("\") + "\WinSxS\pending.xml") -PathType Leaf -ErrorAction SilentlyContinue)
}


function Get-SnakeOptimizerPendingWindowsUpdates {
    <#
    Atualizações do Windows ainda não instaladas, pela API do Windows Update. Não conta as opcionais (drivers e
    prévias que o Windows só oferece na página de atualizações opcionais): essas não deixam o PC desprotegido.
    A consulta vai até o serviço, então roda em segundo plano com tempo limite, para que o botão Parar continue
    funcionando. Devolve Count e Titles, ou $null quando não foi possível consultar (inclusive por tempo esgotado).
    #>
    param (
        [int]$TimeoutSeconds = 90
    )

    $search = {
        $session = New-Object -ComObject "Microsoft.Update.Session"
        $searcher = $session.CreateUpdateSearcher()

        try {
            $found = $searcher.Search("IsInstalled=0 and IsHidden=0 and BrowseOnly=0")
        }
        catch {
            # Uma versão do Windows que não entenda BrowseOnly (0x80240032, critério inválido) ainda responde à consulta
            # simples. Outro erro (sem internet, serviço parado) sobe: repetir dobraria a espera e contaria as opcionais.
            # O erro do COM chega embrulhado (MethodInvocationException): o código está na exceção de dentro.
            if ([string]$_.Exception.Message -notmatch '80240032' -and $_.Exception.GetBaseException().HResult -ne 0x80240032) { throw }

            $found = $searcher.Search("IsInstalled=0 and IsHidden=0")
        }

        foreach ($update in $found.Updates) {
            [string]$update.Title
        }
    }

    try {
        $run = Invoke-SnakeOptimizerInBackground -ScriptBlock $search -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        return $null
    }

    if (-not $run.Completed) {
        return $null
    }

    $titles = @($run.Output | ForEach-Object { [string]$_ })

    return [PSCustomObject]@{ Count = $titles.Count; Titles = @($titles) }
}


function Show-SnakeOptimizerPendingReboot {
    Enter-SnakeOptimizerAction -Title "Reinício pendente"

    $reasons = @(Get-SnakeOptimizerPendingReboot)
    $result = $null

    if ($reasons.Count -eq 0) {
        Write-SnakeOptimizerStatus -Type Success -Message "Nenhum reinício pendente foi detectado."
        $result = New-SnakeOptimizerResult -Kind Ok -Detail "nenhum reinício pendente"
    }
    else {
        # Os sinais fracos (arquivos esperando substituição, um serviço do Windows Update por registrar) aparecem em quase
        # todo PC e não pedem nada: numa linha só, em vez de um motivo técnico cada um.
        $strong = @($reasons | Where-Object { $_.Strong })
        $weak = @($reasons | Where-Object { -not $_.Strong })

        foreach ($reason in $strong) {
            Write-SnakeOptimizerStatus -Type Warning -Message "$($reason.Reason)."
        }

        if ($weak.Count -gt 0 -and $strong.Count -gt 0) {
            Write-SnakeOptimizerStatus -Type Info -Message "Também há sinais que aparecem em quase todo PC; sozinhos, eles não pedem reinício."
        }

        Write-Host ""

        # Os mesmos motivos já lidos acima: Test-SnakeOptimizerPendingReboot leria o Registro de novo.
        if (@($reasons | Where-Object { $_.Strong }).Count -gt 0) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Reinicie o Windows antes de reparos, CHKDSK e instalações grandes."

            # O ponto de atenção do Início e o aviso do monitor trazem a pessoa aqui: o que resolve é reiniciar, então a
            # tela oferece (com Não como padrão, e sem fechar nada à força), em vez de só explicar.
            try {
                if (Request-SnakeOptimizerRestart -Reason "Reiniciar agora conclui o que está esperando o reinício." -Comment "Reinicialização solicitada pelo SnakeOptimizer (reinício pendente)." -DeclinedMessage "O PC não foi reiniciado. Reinicie quando puder.") {
                    $result = New-SnakeOptimizerResult -Kind Ok -Detail "o Windows está reiniciando"
                }
                else {
                    $result = New-SnakeOptimizerResult -Kind Warning -Detail "reinício pendente; reinicie quando puder"
                }
            }
            catch {
                Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível pedir o reinício: $($_.Exception.Message.TrimEnd('.'))."
                $result = New-SnakeOptimizerResult -Kind Warning -Detail "reinício pendente; reinicie pelo menu Iniciar"
            }
        }
        else {
            Write-SnakeOptimizerStatus -Type Success -Message "Há só sinais que aparecem em quase todo PC: reiniciar não é obrigatório agora."
            $result = New-SnakeOptimizerResult -Kind Ok -Detail "nenhum reinício necessário"
        }
    }

    Exit-SnakeOptimizerAction -Result $result
}


$script:SnakeOptimizerNvmeSource = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SnakeOptimizer
{
    public static class NvmeHealthLog
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle device, uint code, byte[] input, int inputSize, byte[] output, int outputSize, out int returned, IntPtr overlapped);

        // O registro de saúde (SMART / Health Information, página 02h) de um SSD NVMe, pelo driver do próprio Windows
        // (IOCTL_STORAGE_QUERY_PROPERTY com StorageDeviceProtocolSpecificProperty). Exige Administrador.
        public static byte[] Read(int diskNumber)
        {
            using (SafeFileHandle device = CreateFile(@"\\.\PhysicalDrive" + diskNumber, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
            {
                if (device.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }

                // STORAGE_PROPERTY_QUERY (8 bytes) + STORAGE_PROTOCOL_SPECIFIC_DATA (40 bytes) + o registro (512 bytes).
                int size = 8 + 40 + 512;
                byte[] input = new byte[size];
                byte[] output = new byte[size];
                BitConverter.GetBytes(50).CopyTo(input, 0);   // StorageDeviceProtocolSpecificProperty
                BitConverter.GetBytes(0).CopyTo(input, 4);    // PropertyStandardQuery
                BitConverter.GetBytes(3).CopyTo(input, 8);    // ProtocolTypeNvme
                BitConverter.GetBytes(2).CopyTo(input, 12);   // NVMeDataTypeLogPage
                BitConverter.GetBytes(2).CopyTo(input, 16);   // página 02h: SMART / Health Information
                BitConverter.GetBytes(0).CopyTo(input, 20);
                BitConverter.GetBytes(40).CopyTo(input, 24);  // os dados vêm logo depois da estrutura
                BitConverter.GetBytes(512).CopyTo(input, 28);

                int returned;
                if (!DeviceIoControl(device, 0x002D1400, input, size, output, size, out returned, IntPtr.Zero)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }

                // STORAGE_PROTOCOL_DATA_DESCRIPTOR: Version, Size e a mesma estrutura de 40 bytes; os dados ficam em 8 + offset.
                int offset = BitConverter.ToInt32(output, 8 + 16);
                int length = BitConverter.ToInt32(output, 8 + 20);
                if (length < 192 || offset < 0 || 8 + offset + 192 > output.Length) { throw new InvalidOperationException("o disco não devolveu o registro de saúde"); }

                byte[] log = new byte[512];
                Array.Copy(output, 8 + offset, log, 0, Math.Min(512, Math.Min(length, output.Length - 8 - offset)));
                return log;
            }
        }
    }
}
"@


function Get-SnakeOptimizerNvmeHealth {
    <#
    O registro de saúde de um SSD NVMe, lido do próprio disco (o mesmo que o Hard Disk Sentinel e o CrystalDiskInfo usam):
    o contador resumido do Windows (Get-StorageReliabilityCounter) costuma vir sem horas, sem erros e com o desgaste em 0.
    Devolve $null quando não dá (sem Administrador, disco que não é NVMe, controladora que não repassa o pedido).
    #>
    param ([Parameter(Mandatory)][int]$DiskNumber)

    try {
        if (-not ("SnakeOptimizer.NvmeHealthLog" -as [type])) { Add-Type -TypeDefinition $script:SnakeOptimizerNvmeSource -ErrorAction Stop }
        $log = [SnakeOptimizer.NvmeHealthLog]::Read($DiskNumber)
    }
    catch {
        Write-Verbose "NVMe ${DiskNumber}: $($_.Exception.Message)"
        return $null
    }

    # Os contadores são de 128 bits; os 64 de baixo bastam (passam de 9 trilhões).
    $u64 = { param ($at) [double][BitConverter]::ToUInt64($log, $at) }
    $kelvin = [int][BitConverter]::ToUInt16($log, 1)

    # "Unidades de dados" do NVMe: 1000 setores de 512 bytes cada.
    return [PSCustomObject]@{
        CriticalWarning = [int]$log[0]
        Temperature     = $(if ($kelvin -gt 273) { $kelvin - 273 } else { $null })
        AvailableSpare  = [int]$log[3]
        SpareThreshold  = [int]$log[4]
        PercentageUsed  = [int]$log[5]
        BytesRead       = (& $u64 32) * 512000
        BytesWritten    = (& $u64 48) * 512000
        PowerCycles     = (& $u64 112)
        PowerOnHours    = (& $u64 128)
        UnsafeShutdowns = (& $u64 144)
        MediaErrors     = (& $u64 160)
        ErrorLogEntries = (& $u64 176)
    }
}


function Get-SnakeOptimizerNvmeHealthPercent {
    <#
    A saúde estimada de um SSD NVMe em %, no jeito dos programas de diagnóstico: 100 menos a vida útil já usada que o
    próprio disco informa, limitada pela reserva de blocos que sobra (uma reserva baixando é o sinal de que o SSD está
    trocando blocos gastos). O aviso crítico do disco (reserva abaixo do limite, só leitura, falha de mídia) derruba
    para no máximo 10%. É uma estimativa: cada programa usa a sua conta, e os números podem diferir em alguns pontos.
    #>
    param ([Parameter(Mandatory)]$Health)

    # $score, e não $health: no PowerShell $health e $Health são a mesma variável, e apagariam o parâmetro.
    $score = 100 - [Math]::Min(100, [int]$Health.PercentageUsed)
    if ([int]$Health.AvailableSpare -ge 0 -and [int]$Health.AvailableSpare -le 100) { $score = [Math]::Min($score, [int]$Health.AvailableSpare) }
    if (([int]$Health.CriticalWarning -band 0x0D) -ne 0) { $score = [Math]::Min($score, 10) }
    return [int][Math]::Max(0, $score)
}


function Add-SnakeOptimizerNvmeDetails {
    <#
    Completa um disco (de Get-SnakeOptimizerDiskHealth ou do inventário) com o registro de saúde do NVMe: saúde em %,
    reserva, gravado, horas, ligações, desligamentos bruscos e erros de mídia. Os valores do próprio disco valem mais que
    os do contador resumido do Windows. Devolve $true quando leu.
    #>
    param (
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)][string]$Number
    )

    $type = [string](Get-SnakeOptimizerJsonValue -Object $Disk -Name "Type" -Default "")
    $value = 0
    if ($type -ne "NVMe" -or -not [int]::TryParse($Number, [ref]$value)) { return $false }

    $log = Get-SnakeOptimizerNvmeHealth -DiskNumber $value
    if ($null -eq $log) { return $false }

    $set = { param ($name, $new) if ($null -eq $new) { return }; if ($Disk.PSObject.Properties[$name]) { $Disk.$name = $new } else { $Disk | Add-Member -NotePropertyName $name -NotePropertyValue $new } }

    & $set "HealthPercent" (Get-SnakeOptimizerNvmeHealthPercent -Health $log)
    & $set "Wear" ([Math]::Min(100, $log.PercentageUsed))
    & $set "AvailableSpare" $log.AvailableSpare
    & $set "SpareThreshold" $log.SpareThreshold
    & $set "CriticalWarning" $log.CriticalWarning
    & $set "UnsafeShutdowns" $log.UnsafeShutdowns
    & $set "MediaErrors" $log.MediaErrors
    if ($null -ne $log.Temperature -and $log.Temperature -le 127) { & $set "Temperature" $log.Temperature }
    if ($log.PowerOnHours -gt 0) { & $set "PowerOnHours" ([int64]$log.PowerOnHours) }
    if ($log.PowerCycles -gt 0) { & $set "PowerCycles" ([int64]$log.PowerCycles) }
    if ($log.BytesWritten -gt 0) { & $set "BytesWritten" $log.BytesWritten }
    if ($log.BytesRead -gt 0) { & $set "BytesRead" $log.BytesRead }
    if ($Disk.PSObject.Properties["CountersAvailable"]) { $Disk.CountersAvailable = $true }
    return $true
}


function Write-SnakeOptimizerDiskHealthPercentLine {
    # "Saúde: 89% (vida útil usada: 11%)", com a cor pelo número: abaixo de 50% atenção, abaixo de 20% ruim.
    param ([Parameter(Mandatory)]$Disk)

    $percent = Get-SnakeOptimizerJsonValue -Object $Disk -Name "HealthPercent" -Default $null
    if ($null -eq $percent) { return }

    $used = Get-SnakeOptimizerJsonValue -Object $Disk -Name "Wear" -Default $null
    $level = $(if ([int]$percent -lt 20) { "Bad" } elseif ([int]$percent -lt 50) { "Warn" } else { "Ok" })
    Write-SnakeOptimizerKeyValue -Label "Saúde" -Value "$percent%$(if ($null -ne $used) { " (vida útil usada: $used%)" })" -Level $level
}


function Write-SnakeOptimizerDiskNvmeExtraLines {
    # O que só o registro de saúde do NVMe traz: reserva, total gravado, ligações e desligamentos bruscos.
    param ([Parameter(Mandatory)]$Disk)

    $spare = Get-SnakeOptimizerJsonValue -Object $Disk -Name "AvailableSpare" -Default $null
    if ($null -eq $spare) { return }

    $threshold = Get-SnakeOptimizerJsonValue -Object $Disk -Name "SpareThreshold" -Default $null
    $written = Get-SnakeOptimizerJsonValue -Object $Disk -Name "BytesWritten" -Default $null
    $cycles = Get-SnakeOptimizerJsonValue -Object $Disk -Name "PowerCycles" -Default $null
    $unsafe = Get-SnakeOptimizerJsonValue -Object $Disk -Name "UnsafeShutdowns" -Default $null
    $media = Get-SnakeOptimizerJsonValue -Object $Disk -Name "MediaErrors" -Default $null

    Write-SnakeOptimizerKeyValue -Label "Reserva do SSD" -Value "$spare%$(if ($null -ne $threshold) { " (alerta abaixo de $threshold%)" })" -Level $(if ($null -ne $threshold -and [int]$spare -le [int]$threshold) { "Bad" } else { "Normal" })
    if ($written) { Write-SnakeOptimizerKeyValue -Label "Total gravado" -Value (Format-SnakeOptimizerBytes -Bytes ([double]$written)) }
    if ($null -ne $cycles) { Write-SnakeOptimizerKeyValue -Label "Ligações" -Value (Format-SnakeOptimizerNumber -Value ([double]$cycles)) }
    if ($null -ne $unsafe) { Write-SnakeOptimizerKeyValue -Label "Desligamentos bruscos" -Value (Format-SnakeOptimizerNumber -Value ([double]$unsafe)) }
    if ($null -ne $media) { Write-SnakeOptimizerKeyValue -Label "Erros de mídia" -Value (Format-SnakeOptimizerNumber -Value ([double]$media)) -Level $(if ([double]$media -gt 0) { "Warn" } else { "Normal" }) }
}


function Get-SnakeOptimizerDiskHealthStatusText {
    # O estado geral que o Windows dá ao disco (HealthStatus), em português. Vem como nome (Healthy) ou como número (0).
    param (
        $Status
    )

    switch ([string]$Status) {
        { $_ -in @("Healthy", "0") } { return "Saudável" }
        { $_ -in @("Warning", "1") } { return "Atenção" }
        { $_ -in @("Unhealthy", "2") } { return "Com defeito" }
        { $_ -in @("Unknown", "5", "") } { return "Desconhecido" }
        default { return [string]$Status }
    }
}


function Get-SnakeOptimizerDiskHealthNotes {
    # Os alertas de um disco. Temperatura alta: 70 °C num SSD, 55 °C num HD (que trabalha mais frio) e 60 °C quando o
    # Windows não diz o tipo (um HD atrás de um controlador RAID, por exemplo). Desgaste só vale para SSD: num HD o
    # contador fica em zero.
    param (
        [Parameter(Mandatory)]
        $Disk
    )

    # Cada campo pelo nome, com padrão: um disco montado por outra parte (o relatório, um teste) pode não trazer todos.
    $notes = @()
    $type = [string](Get-SnakeOptimizerJsonValue -Object $Disk -Name "Type" -Default "")
    $healthStatus = Get-SnakeOptimizerJsonValue -Object $Disk -Name "HealthStatus" -Default ""
    $wear = Get-SnakeOptimizerJsonValue -Object $Disk -Name "Wear" -Default $null
    $temperature = Get-SnakeOptimizerJsonValue -Object $Disk -Name "Temperature" -Default $null
    $readErrors = Get-SnakeOptimizerJsonValue -Object $Disk -Name "ReadErrorsUncorrected" -Default $null
    $writeErrors = Get-SnakeOptimizerJsonValue -Object $Disk -Name "WriteErrorsUncorrected" -Default $null
    $isHdd = ($type -eq "HDD")
    $isSsd = ($type -in @("SSD", "NVMe"))

    # A previsão de falha do próprio disco (SMART), que o Windows mostra em OperationalStatus: "Predictive Failure", ou 5
    # quando vem como número. É o aviso mais direto de que o disco está no fim, e diz mais que o estado de atenção.
    $predictive = (@(@(Get-SnakeOptimizerJsonValue -Object $Disk -Name "OperationalStatus" -Default @()) | Where-Object { ([string]$_).Trim() -in @("Predictive Failure", "5") }).Count -gt 0)

    if ($predictive) { $notes += "O próprio disco avisa que pode falhar em breve (SMART)" }

    switch (Get-SnakeOptimizerDiskHealthStatusText -Status $healthStatus) {
        "Saudável" { }
        "Desconhecido" { }
        "Atenção" { if (-not $predictive) { $notes += "O Windows marca este disco com estado de atenção" } }
        "Com defeito" { $notes += "O Windows marca este disco como com defeito" }
        default { $notes += "Estado do disco: $healthStatus" }
    }

    if (-not $isHdd -and $null -ne $wear -and [int]$wear -ge 80) {
        $notes += "Desgaste $(if ($isSsd) { 'do SSD' } else { 'do disco' }) em $wear% da vida útil estimada"
    }

    if ($null -ne $temperature -and [int]$temperature -ge $(if ($isHdd) { 55 } elseif ($isSsd) { 70 } else { 60 })) {
        $notes += "Temperatura alta ($temperature °C)"
    }

    # Do registro de saúde do NVMe (Add-SnakeOptimizerNvmeDetails), quando lido.
    $critical = Get-SnakeOptimizerJsonValue -Object $Disk -Name "CriticalWarning" -Default $null
    $spare = Get-SnakeOptimizerJsonValue -Object $Disk -Name "AvailableSpare" -Default $null
    $threshold = Get-SnakeOptimizerJsonValue -Object $Disk -Name "SpareThreshold" -Default $null
    $media = Get-SnakeOptimizerJsonValue -Object $Disk -Name "MediaErrors" -Default $null

    if ($null -ne $critical -and ([int]$critical -band 0x0D) -ne 0) {
        $notes += "O próprio SSD está em alerta crítico (reserva esgotando, só leitura ou falha de mídia)"
    }
    elseif ($null -ne $spare -and $null -ne $threshold -and [int]$threshold -gt 0 -and [int]$spare -le [int]$threshold) {
        $notes += "A reserva de blocos do SSD chegou ao limite ($spare%)"
    }

    if ($null -ne $media -and [double]$media -gt 0) {
        $notes += "O SSD registrou $media erros de mídia (dados que não puderam ser lidos ou gravados)"
    }

    if ($null -ne $readErrors -and [int64]$readErrors -gt 0) {
        $notes += "Erros de leitura não corrigidos: $readErrors"
    }

    if ($null -ne $writeErrors -and [int64]$writeErrors -gt 0) {
        $notes += "Erros de escrita não corrigidos: $writeErrors"
    }

    return @($notes)
}


function Get-SnakeOptimizerDiskHealth {
    $result = @()

    try {
        $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop)
    }
    catch {
        return @()
    }

    # Na ordem do Gerenciamento de Disco (disco 0, 1, 2...): o Windows devolve os discos em qualquer ordem, e a tela
    # mudava de uma vez para outra. Sem número, no fim.
    $physicalDisks = @($physicalDisks | Sort-Object -Property @{ Expression = { $number = 0; if ([int]::TryParse([string](Get-SnakeOptimizerJsonValue -Object $_ -Name "DeviceId" -Default ""), [ref]$number)) { $number } else { [int]::MaxValue } } })

    # As letras de cada disco, numa consulta só (uma por disco custava uma ida ao serviço de armazenamento cada).
    $lettersByDisk = @{}

    try {
        foreach ($partition in @(Get-Partition -ErrorAction Stop)) {
            $letter = [string]$partition.DriveLetter

            if ($letter -match '^[A-Za-z]$' -and $null -ne $partition.DiskNumber) {
                $key = [string]$partition.DiskNumber
                if (-not $lettersByDisk.ContainsKey($key)) { $lettersByDisk[$key] = @() }
                $lettersByDisk[$key] += "$($letter.ToUpperInvariant()):"
            }
        }
    }
    catch {
        # Sem as partições, os discos ficam sem as letras.
    }

    foreach ($physicalDisk in $physicalDisks) {
        $counter = $null

        try {
            $counter = $physicalDisk | Get-StorageReliabilityCounter -ErrorAction Stop
        }
        catch {
            # Alguns discos (USB, virtuais) não expõem contadores de confiabilidade.
        }

        $name = ([string]$physicalDisk.FriendlyName).Trim()
        $field = { param ($property) if ($counter -and $counter.PSObject.Properties[$property]) { $counter.$property } else { $null } }

        # Valores fora do possível são o que alguns adaptadores USB informam quando não sabem: 0 °C sem sensor, 128 ou
        # 255 °C, milhões de horas, desgaste acima de 100%. Mostrá-los seria inventar um dado (e um alerta). Um SSD
        # esquentando de verdade passa dos 100 °C: até 127 vale.
        $rawTemperature = & $field "Temperature"
        $temperature = $(if ($null -ne $rawTemperature -and [double]$rawTemperature -ge 1 -and [double]$rawTemperature -le 127) { [int]$rawTemperature } else { $null })
        $rawHours = & $field "PowerOnHours"
        # Zero hora num disco em uso é o "não sei" do adaptador, não um disco novo.
        $hours = $(if ($null -ne $rawHours -and [double]$rawHours -gt 0 -and [double]$rawHours -lt 150000) { $rawHours } else { $null })
        $rawWear = & $field "Wear"
        $wear = $(if ($null -ne $rawWear -and [double]$rawWear -ge 0 -and [double]$rawWear -le 100) { [int]$rawWear } else { $null })
        $readErrors = & $field "ReadErrorsUncorrected"
        $writeErrors = & $field "WriteErrorsUncorrected"
        $type = Get-SnakeOptimizerDiskTypeText -Disk $physicalDisk

        # Só num SSD o desgaste em zero quer dizer "novo"; num disco de tipo desconhecido, zero é o que um HD informa.
        if ($type -notin @("SSD", "NVMe") -and $wear -eq 0) { $wear = $null }

        # Os contadores só contam como lidos quando trazem algum dado: um objeto vazio (comum em gavetas USB e em
        # controladores RAID) não pode virar "Nenhum alerta".
        $reported = ($null -ne $temperature -or $null -ne $hours -or $null -ne $wear -or ($null -ne $readErrors -and [double]$readErrors -gt 0) -or ($null -ne $writeErrors -and [double]$writeErrors -gt 0))

        # As letras das unidades deste disco: "faça backup deste disco" precisa dizer qual é (C:, D:). Sem o número do
        # disco, nada: um valor vazio não pode virar o disco 0.
        $deviceId = [string](Get-SnakeOptimizerJsonValue -Object $physicalDisk -Name "DeviceId" -Default "")
        $drives = $(if ($deviceId -match '^[0-9]+$' -and $lettersByDisk.ContainsKey($deviceId)) { @($lettersByDisk[$deviceId] | Sort-Object -Unique) } else { @() })

        $disk = [PSCustomObject]@{
            Name                   = $(if ($name) { $name } else { "Disco sem nome" })
            Type                   = $type
            SizeBytes              = $physicalDisk.Size
            HealthStatus           = $physicalDisk.HealthStatus
            OperationalStatus      = @(@(Get-SnakeOptimizerJsonValue -Object $physicalDisk -Name "OperationalStatus" -Default @()) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            Drives                 = @($drives)
            CountersAvailable      = $reported
            Temperature            = $temperature
            Wear                   = $wear
            PowerOnHours           = $hours
            ReadErrorsUncorrected  = $readErrors
            WriteErrorsUncorrected = $writeErrors
        }

        # NVMe: o registro de saúde do próprio SSD (saúde em %, horas, erros), mais completo que o resumo do Windows.
        [void](Add-SnakeOptimizerNvmeDetails -Disk $disk -Number $deviceId)

        $disk | Add-Member -NotePropertyName Notes -NotePropertyValue @(Get-SnakeOptimizerDiskHealthNotes -Disk $disk)
        $result += $disk
    }

    return @($result)
}


function Show-SnakeOptimizerDiskHealth {
    Enter-SnakeOptimizerAction -Title "Saúde dos discos"

    $disks = @(Get-SnakeOptimizerDiskHealth)

    if ($disks.Count -eq 0) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível ler a saúde dos discos: o Windows não respondeu. Tente de novo; se continuar, reinicie o PC."
        Exit-SnakeOptimizerAction
        return
    }

    $isAdmin = Test-SnakeOptimizerAdministrator

    foreach ($disk in $disks) {
        $isHdd = ($disk.Type -eq "HDD")
        $status = Get-SnakeOptimizerDiskHealthStatusText -Status $disk.HealthStatus
        $drives = @(Get-SnakeOptimizerJsonValue -Object $disk -Name "Drives" -Default @())
        $errorText = { param ($value) if ($null -ne $value) { [string][int64]$value } else { "não informado" } }

        Write-SnakeOptimizerSection -Title "$($disk.Name) ($($disk.Type), $(Format-SnakeOptimizerBytes -Bytes $disk.SizeBytes -ZeroText "tamanho desconhecido"))"
        if ($drives.Count -gt 0) { Write-SnakeOptimizerKeyValue -Label "Unidades" -Value ($drives -join ", ") }
        Write-SnakeOptimizerKeyValue -Label "Estado" -Value $status -Level $(switch ($status) { "Saudável" { "Ok" } "Atenção" { "Warn" } "Com defeito" { "Bad" } default { "Normal" } })
        Write-SnakeOptimizerDiskHealthPercentLine -Disk $disk
        Write-SnakeOptimizerKeyValue -Label "Temperatura" -Value $(if ($null -ne $disk.Temperature) { "$($disk.Temperature) °C" } else { $null })
        if ($null -eq (Get-SnakeOptimizerJsonValue -Object $disk -Name "HealthPercent" -Default $null)) {
            Write-SnakeOptimizerKeyValue -Label "Desgaste" -Value $(if ($isHdd) { "Não se aplica (HDD)" } elseif ($null -ne $disk.Wear) { "$($disk.Wear)% da vida útil estimada" } else { $null })
        }
        Write-SnakeOptimizerKeyValue -Label "Horas ligado" -Value $(if ($null -eq $disk.PowerOnHours) { $null } elseif ([double]$disk.PowerOnHours -eq 1) { "1 hora" } else { "$(Format-SnakeOptimizerNumber -Value ([double]$disk.PowerOnHours)) horas" })
        Write-SnakeOptimizerKeyValue -Label "Erros não corrigidos" -Value $(if ($null -ne $disk.ReadErrorsUncorrected -or $null -ne $disk.WriteErrorsUncorrected) { "$(& $errorText $disk.ReadErrorsUncorrected) de leitura, $(& $errorText $disk.WriteErrorsUncorrected) de escrita" } else { $null })
        Write-SnakeOptimizerDiskNvmeExtraLines -Disk $disk

        Write-Host ""

        if ($disk.Notes.Count -gt 0) {
            foreach ($note in $disk.Notes) {
                Write-SnakeOptimizerStatus -Type Warning -Message "$note."
            }

            # Estado ruim, erros ou desgaste: o que fazer antes de qualquer outra coisa é guardar os arquivos.
            if (@($disk.Notes | Where-Object { $_ -notlike "Temperatura*" }).Count -gt 0) {
                Write-SnakeOptimizerStatus -Type Info -Message "Faça backup dos arquivos importantes deste disco$(if ($drives.Count -gt 0) { " ($(Join-SnakeOptimizerList -Items $drives))" })."
            }
            else {
                Write-SnakeOptimizerStatus -Type Info -Message "Confira a ventilação do gabinete ou do notebook."
            }
        }
        elseif ($disk.CountersAvailable) {
            Write-SnakeOptimizerStatus -Type Success -Message "Nenhum alerta para este disco."
        }
        elseif ($status -eq "Desconhecido") {
            Write-SnakeOptimizerStatus -Type Info -Message "Este disco não informou o estado nem os contadores de confiabilidade; não há como avaliá-lo por aqui."
        }
        elseif ($isAdmin) {
            # Sem contadores só o estado geral foi avaliado; "nenhum alerta" prometeria mais do que a leitura fez.
            Write-SnakeOptimizerStatus -Type Info -Message "Este disco não expõe contadores de confiabilidade (comum em discos USB e virtuais); só o estado geral foi avaliado."
        }
        else {
            Write-SnakeOptimizerStatus -Type Info -Message "Os contadores deste disco não puderam ser lidos (exigem Administrador, e discos USB e virtuais nem sempre os têm); só o estado geral foi avaliado."
        }
    }

    Write-Host ""
    Write-SnakeOptimizerStatus -Type Info -Message "Isto lê o que o próprio Windows sabe do disco; o programa do fabricante do disco faz um teste mais completo."

    # A faixa de resultado: quantos discos têm alerta, ou que nenhum tem (e se algum foi avaliado só pelo estado geral).
    $alerted = @($disks | Where-Object { $_.Notes.Count -gt 0 })
    $partial = @($disks | Where-Object { $_.Notes.Count -eq 0 -and -not $_.CountersAvailable })
    $result = $null

    if ($alerted.Count -gt 0) {
        $names = @($alerted | ForEach-Object { $letters = @(Get-SnakeOptimizerJsonValue -Object $_ -Name "Drives" -Default @()); if ($letters.Count -gt 0) { "$($_.Name) ($($letters -join ', '))" } else { $_.Name } })
        $result = New-SnakeOptimizerResult -Kind Warning -Detail "$(Format-SnakeOptimizerCount -Count $alerted.Count -One 'disco' -Many 'discos') com alerta: $(Join-SnakeOptimizerList -Items $names)"
    }
    elseif ($partial.Count -eq 0) {
        $result = New-SnakeOptimizerResult -Kind Ok -Detail "nenhum alerta $(if ($disks.Count -eq 1) { 'no disco' } else { "nos $($disks.Count) discos" })"
    }
    elseif ($partial.Count -lt $disks.Count) {
        $result = New-SnakeOptimizerResult -Kind Ok -Detail "nenhum alerta; $(Format-SnakeOptimizerCount -Count $partial.Count -One 'disco foi avaliado' -Many 'discos foram avaliados') só pelo estado geral"
    }

    Exit-SnakeOptimizerAction -Result $result
}


# ---------------------------------------------------------------------------
# Saúde da bateria
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerXmlChildNumber {
    # Número de um elemento filho, ignorando o namespace do XML (o relatório do powercfg usa um). Ausente ou texto = $null.
    param (
        [Parameter(Mandatory)]
        $Node,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $child = $Node.SelectSingleNode("*[local-name()='$Name']")

    if ($null -eq $child) {
        return $null
    }

    $parsed = [int64]0

    if ([int64]::TryParse(([string]$child.InnerText).Trim(), [ref]$parsed)) {
        return $parsed
    }

    return $null
}


function Get-SnakeOptimizerXmlChildText {
    param (
        [Parameter(Mandatory)]
        $Node,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $child = $Node.SelectSingleNode("*[local-name()='$Name']")

    if ($null -eq $child) {
        return ""
    }

    return ([string]$child.InnerText).Trim()
}


function New-SnakeOptimizerBatteryReading {
    # Capacidades em mWh, como o Windows informa. Saúde = capacidade atual / capacidade de projeto (no máximo 100%).
    param (
        [string]$Name = "",
        $DesignMwh = $null,
        $FullMwh = $null,
        $Cycles = $null,

        # O relatório marca quando as capacidades não estão em mWh (RelativeCapacity): a saúde continua valendo (é uma
        # razão), mas "Wh" seria um número sem sentido.
        [bool]$Relative = $false
    )

    # 0 e 4294967295 (0xFFFFFFFF) são o que muitos firmwares informam quando não sabem a capacidade: valem como "não
    # informado", senão viram uma saúde de 0% ou uma conta absurda.
    $unknownCapacity = { param ($value) $null -eq $value -or [double]$value -le 0 -or [double]$value -ge 4294967295 }

    if (& $unknownCapacity $DesignMwh) { $DesignMwh = $null }
    if (& $unknownCapacity $FullMwh) { $FullMwh = $null }

    $health = $null

    if ($null -ne $DesignMwh -and $null -ne $FullMwh) {
        # [double] nos dois lados: com um inteiro na frente, o PowerShell escolheria o Min de Int32 e truncaria a conta.
        $health = [int][math]::Min([double]100, [math]::Round(([double]$FullMwh / [double]$DesignMwh) * 100))
    }

    # Muitos notebooks informam 0 ciclos quando o firmware não conta: mostrar "0" seria dizer que a bateria é nova.
    $cycleCount = $null
    $parsedCycles = [int64]0

    if ($null -ne $Cycles -and [int64]::TryParse(([string]$Cycles).Trim(), [ref]$parsedCycles) -and $parsedCycles -gt 0) {
        $cycleCount = $parsedCycles
    }

    return [PSCustomObject]@{
        Name          = $Name
        DesignMwh     = $DesignMwh
        FullMwh       = $FullMwh
        Cycles        = $cycleCount
        HealthPercent = $health
        Relative      = $Relative
    }
}


function ConvertFrom-SnakeOptimizerBatteryReport {
    <#
    Lê o XML de "powercfg /batteryreport /xml" e devolve uma leitura por bateria. Os nomes dos elementos são os do
    relatório (DesignCapacity, FullChargeCapacity, CycleCount) e a busca ignora o namespace. XML inválido lança erro;
    um XML sem baterias devolve lista vazia.
    #>
    param (
        [Parameter(Mandatory, ParameterSetName = "Text")]
        [string]$Text,

        # Com o caminho do arquivo, o próprio XmlDocument lê a codificação declarada (UTF-8 ou UTF-16).
        [Parameter(Mandatory, ParameterSetName = "Path")]
        [string]$Path
    )

    $document = New-Object System.Xml.XmlDocument

    if ($PSCmdlet.ParameterSetName -eq "Path") { $document.Load($Path) }
    else { $document.LoadXml($Text) }

    $readings = @()

    foreach ($node in @($document.SelectNodes("//*[local-name()='Batteries']/*[local-name()='Battery']"))) {
        $name = (Get-SnakeOptimizerXmlChildText -Node $node -Name "Manufacturer")
        $id = (Get-SnakeOptimizerXmlChildText -Node $node -Name "Id")

        # O identificador sozinho já diz o fabricante quando o contém ("SMP-1234"); com duas baterias do mesmo fabricante,
        # ficar só com o fabricante as deixaria iguais. IndexOf em vez de -like: [ ] e * no nome seriam curingas.
        if ($name -and $id) {
            if ($id.IndexOf($name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $name = $id }
            else { $name = "$name $id" }
        }
        elseif (-not $name) { $name = $id }

        $readings += New-SnakeOptimizerBatteryReading `
            -Name $name `
            -DesignMwh (Get-SnakeOptimizerXmlChildNumber -Node $node -Name "DesignCapacity") `
            -FullMwh (Get-SnakeOptimizerXmlChildNumber -Node $node -Name "FullChargeCapacity") `
            -Cycles (Get-SnakeOptimizerXmlChildNumber -Node $node -Name "CycleCount") `
            -Relative ([string](Get-SnakeOptimizerXmlChildText -Node $node -Name "RelativeCapacity") -in @("1", "true"))
    }

    return @($readings)
}


function Get-SnakeOptimizerBatteryWmiReadings {
    # Plano B quando o relatório do powercfg não está disponível: as classes de bateria do WMI (root\wmi).
    $static = @()
    $full = @()
    $cycles = @()

    try {
        $static = @(Get-CimInstance -Namespace "root\wmi" -ClassName "BatteryStaticData" -ErrorAction Stop)
        $full = @(Get-CimInstance -Namespace "root\wmi" -ClassName "BatteryFullChargedCapacity" -ErrorAction Stop)
        $cycles = @(Get-CimInstance -Namespace "root\wmi" -ClassName "BatteryCycleCount" -ErrorAction SilentlyContinue)
    }
    catch {
        return @()
    }

    $readings = @()

    foreach ($entry in $static) {
        $fullEntry = $full | Where-Object { $_.InstanceName -eq $entry.InstanceName } | Select-Object -First 1
        $cycleEntry = $cycles | Where-Object { $_.InstanceName -eq $entry.InstanceName } | Select-Object -First 1

        $readings += New-SnakeOptimizerBatteryReading `
            -Name ([string]$entry.DeviceName) `
            -DesignMwh $entry.DesignedCapacity `
            -FullMwh $(if ($fullEntry) { $fullEntry.FullChargedCapacity } else { $null }) `
            -Cycles $(if ($cycleEntry) { $cycleEntry.CycleCount } else { $null })
    }

    return @($readings)
}


function Get-SnakeOptimizerBatteryReadings {
    <#
    Capacidades das baterias do notebook. Primeiro tenta o relatório do powercfg (arquivo temporário, apagado ao final)
    e, se ele não trouxer baterias, o WMI. Devolve Readings e Source ("powercfg", "wmi" ou "").
    #>
    $readings = @()
    $source = ""

    $reportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("snakeoptimizer-bateria-" + [guid]::NewGuid().ToString("N") + ".xml")

    try {
        $run = Invoke-SnakeOptimizerCapture -FilePath "powercfg.exe" -Arguments @("/batteryreport", "/xml", "/output", $reportPath)

        if ($run.ExitCode -eq 0 -and (Test-Path -LiteralPath $reportPath)) {
            $readings = @(ConvertFrom-SnakeOptimizerBatteryReport -Path $reportPath)
            if ($readings.Count -gt 0) { $source = "powercfg" }
        }
    }
    catch {
        # powercfg ausente, sem permissão ou com XML ilegível: segue para o WMI.
        $readings = @()
    }
    finally {
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    }

    if ($readings.Count -eq 0) {
        $readings = @(Get-SnakeOptimizerBatteryWmiReadings)
        if ($readings.Count -gt 0) { $source = "wmi" }
    }

    return [PSCustomObject]@{ Readings = @($readings); Source = $source }
}


function Get-SnakeOptimizerBatteryAssessment {
    # Regra prática sobre o desgaste: 80% ou mais está bom; de 60% a 79% a autonomia já caiu; abaixo de 60%, vale pensar
    # na troca. Level = Success | Info | Warning (o vocabulário de Write-SnakeOptimizerStatus).
    param (
        $HealthPercent,

        # Qual capacidade faltou, quando a saúde não pôde ser calculada: "design" (a de fábrica) ou "full" (a de hoje).
        [ValidateSet("design", "full")][string]$Missing = "design"
    )

    if ($null -eq $HealthPercent) {
        $what = $(if ($Missing -eq "full") { "a capacidade de hoje" } else { "a capacidade de fábrica" })
        return [PSCustomObject]@{ Level = "Info"; Text = "O Windows não informou $what; não dá para calcular o desgaste." }
    }

    if ([int]$HealthPercent -ge 80) {
        return [PSCustomObject]@{ Level = "Success"; Text = "Bateria em bom estado: segura $HealthPercent% da carga de quando era nova." }
    }

    if ([int]$HealthPercent -ge 60) {
        return [PSCustomObject]@{ Level = "Info"; Text = "Desgaste moderado: segura $HealthPercent% da carga original, então a autonomia já caiu." }
    }

    return [PSCustomObject]@{ Level = "Warning"; Text = "Desgaste alto: segura só $HealthPercent% da carga original. Vale considerar a troca da bateria." }
}


function ConvertTo-SnakeOptimizerBatteryPercent {
    # A carga, de 0 a 100. Alguns drivers informam 255 (ou outro valor fora da faixa) quando não sabem: vira $null.
    param (
        $Value
    )

    $number = 0

    if ($null -ne $Value -and [int]::TryParse(([string]$Value).Trim(), [ref]$number) -and $number -ge 0 -and $number -le 100) {
        return $number
    }

    return $null
}


function Get-SnakeOptimizerBatteryState {
    # Carga e situação atuais, do Win32_Battery (código BatteryStatus: 1 descarregando, 2 na tomada, 3 cheia, 4 baixa,
    # 5 crítica, 6 a 9 carregando, 11 parcialmente carregada). Com duas baterias (alguns ThinkPad), a carga é a média das
    # duas e a situação é a de quem trabalha: carregando ou usando a bateria vence "na tomada". Falha na consulta = $null.
    try {
        $batteries = @(Get-CimInstance -ClassName "Win32_Battery" -ErrorAction Stop | Where-Object { $null -ne $_ })
    }
    catch {
        return $null
    }

    if ($batteries.Count -eq 0) {
        return $null
    }

    $codes = @($batteries | ForEach-Object { [int]$_.BatteryStatus })
    $state = ""

    if (@($codes | Where-Object { $_ -in 6, 7, 8, 9 }).Count -gt 0) { $state = "Carregando" }
    elseif (@($codes | Where-Object { $_ -in 1, 4, 5 }).Count -gt 0) { $state = "Usando a bateria" }
    elseif (@($codes | Where-Object { $_ -in 2, 3, 11 }).Count -gt 0) { $state = "Na tomada" }

    $charges = @($batteries | ForEach-Object { ConvertTo-SnakeOptimizerBatteryPercent -Value $_.EstimatedChargeRemaining } | Where-Object { $null -ne $_ })
    $charge = $(if ($charges.Count -gt 0) { [int][math]::Round((($charges | Measure-Object -Average).Average)) } else { $null })

    # Com duas baterias de tamanhos diferentes, a média simples erra (uma de 23 Wh cheia e uma de 72 Wh em 20% não são
    # 60%): a carga do conjunto é o que resta somado sobre o total somado, quando o Windows informa os dois.
    if ($batteries.Count -gt 1) {
        try {
            $remaining = [double]0
            $full = [double]0
            foreach ($item in @(Get-CimInstance -Namespace "root\wmi" -ClassName "BatteryStatus" -ErrorAction Stop)) { $remaining += [double](Get-SnakeOptimizerJsonValue -Object $item -Name "RemainingCapacity" -Default 0) }
            foreach ($item in @(Get-CimInstance -Namespace "root\wmi" -ClassName "BatteryFullChargedCapacity" -ErrorAction Stop)) { $full += [double](Get-SnakeOptimizerJsonValue -Object $item -Name "FullChargedCapacity" -Default 0) }

            if ($remaining -ge 0 -and $full -gt 0 -and $remaining -le $full * 1.05) {
                $charge = [int][math]::Min(100, [math]::Round(($remaining / $full) * 100))
            }
        }
        catch {
            # Fica a média.
        }
    }

    return [PSCustomObject]@{ ChargePercent = $charge; State = $state; Count = $batteries.Count }
}


function Get-SnakeOptimizerBatteryInfo {
    # Tudo o que a tela e o relatório mostram. Present = $false em desktops e máquinas sem bateria; Ups = $true num
    # computador de mesa em que o Windows vê uma bateria (um nobreak USB): ela não é a bateria de um notebook.
    $state = Get-SnakeOptimizerBatteryState

    if ($null -eq $state) {
        return [PSCustomObject]@{ Present = $false; Ups = $false; State = $null; Readings = @(); Source = "" }
    }

    if (-not (Test-SnakeOptimizerLaptop)) {
        return [PSCustomObject]@{ Present = $false; Ups = $true; State = $null; Readings = @(); Source = "" }
    }

    $found = Get-SnakeOptimizerBatteryReadings

    return [PSCustomObject]@{ Present = $true; Ups = $false; State = $state; Readings = @($found.Readings); Source = $found.Source }
}


function Format-SnakeOptimizerWattHours {
    # mWh em Wh, com uma casa ("45,6 Wh"): uma bateria de 50 Wh perdendo 0,4 Wh não pode parecer igual.
    param ($MilliwattHours)

    if ($null -eq $MilliwattHours) {
        return $null
    }

    return "$(Format-SnakeOptimizerNumber -Value ([math]::Round([double]$MilliwattHours / 1000, 1)) -Decimals 1) Wh"
}


function Show-SnakeOptimizerBatteryHealth {
    Enter-SnakeOptimizerAction -Title "Saúde da bateria"

    # Uma saída só (Exit-SnakeOptimizerAction no fim): sair de dentro do try faria um erro na espera da tecla ser tratado
    # como erro da bateria, com uma segunda espera.
    $result = $null

    try {
        $info = Get-SnakeOptimizerBatteryInfo

        if (-not $info.Present -and [bool](Get-SnakeOptimizerJsonValue -Object $info -Name "Ups" -Default $false)) {
            Write-SnakeOptimizerStatus -Type Info -Message "Este PC se identifica como um computador de mesa: a bateria que o Windows enxerga deve ser a de um nobreak (UPS). O estado dela fica no programa do fabricante do nobreak."
        }
        elseif (-not $info.Present) {
            Write-SnakeOptimizerStatus -Type Info -Message "Este computador não tem bateria (ou o Windows não consegue enxergá-la)."
        }
        else {
            Write-SnakeOptimizerSection -Title "Agora"
            Write-SnakeOptimizerKeyValue -Label "Carga" -Value $(if ($null -ne $info.State.ChargePercent) { "$($info.State.ChargePercent)%" } else { $null })
            Write-SnakeOptimizerKeyValue -Label "Situação" -Value $info.State.State

            $readings = @($info.Readings)

            if ($readings.Count -eq 0) {
                Write-Host ""
                Write-SnakeOptimizerStatus -Type Warning -Message "O Windows não informou a capacidade da bateria. Alguns notebooks não expõem esses dados."
            }
            else {
                $levels = @()

                foreach ($reading in $readings) {
                    $title = "Capacidade"
                    if (-not [string]::IsNullOrWhiteSpace($reading.Name)) { $title += ": $($reading.Name)" }

                    Write-SnakeOptimizerSection -Title $title

                    if (-not [bool](Get-SnakeOptimizerJsonValue -Object $reading -Name "Relative" -Default $false)) {
                        Write-SnakeOptimizerKeyValue -Label "Capacidade de fábrica" -Value (Format-SnakeOptimizerWattHours -MilliwattHours $reading.DesignMwh)
                        Write-SnakeOptimizerKeyValue -Label "Capacidade hoje" -Value (Format-SnakeOptimizerWattHours -MilliwattHours $reading.FullMwh)
                    }

                    Write-SnakeOptimizerKeyValue -Label "Saúde" -Value $(if ($null -ne $reading.HealthPercent) { "$($reading.HealthPercent)%" } else { $null })
                    Write-SnakeOptimizerKeyValue -Label "Ciclos de carga" -Value $(if ($null -ne $reading.Cycles) { Format-SnakeOptimizerNumber -Value ([double]$reading.Cycles) } else { $null })

                    $assessment = Get-SnakeOptimizerBatteryAssessment -HealthPercent $reading.HealthPercent -Missing $(if ($null -ne $reading.DesignMwh -and $null -eq $reading.FullMwh) { "full" } else { "design" })
                    $levels += $assessment.Level

                    Write-Host ""
                    Write-SnakeOptimizerStatus -Type $assessment.Level -Message $assessment.Text
                }

                Write-Host ""
                Write-SnakeOptimizerStatus -Type Info -Message "A bateria perde capacidade com o uso e com o calor; isso é normal. O valor é uma estimativa do próprio Windows."

                # A faixa: o pior veredito entre as baterias. Desgaste moderado ou desconhecido não tem veredito.
                $worst = @($readings | Where-Object { $null -ne $_.HealthPercent } | Sort-Object { [int]$_.HealthPercent } | Select-Object -First 1)

                if ($levels -contains "Warning") {
                    $result = New-SnakeOptimizerResult -Kind Warning -Detail "desgaste alto: a bateria segura só $($worst[0].HealthPercent)% da carga original"
                }
                elseif (@($levels | Where-Object { $_ -ne "Success" }).Count -eq 0) {
                    $result = New-SnakeOptimizerResult -Kind Ok -Detail "bateria em bom estado ($($worst[0].HealthPercent)% da carga de quando era nova)"
                }
            }
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Ocorreu um erro ao consultar a bateria: $($_.Exception.Message)"
        $result = $null
    }

    Exit-SnakeOptimizerAction -Result $result
}


function Get-SnakeOptimizerEventHint {
    param (
        [string]$Provider,
        [int]$Id
    )

    # O NTFS aparece com os dois nomes, conforme a versão do Windows.
    $key = "$(([string]$Provider) -replace '^Microsoft-Windows-Ntfs$', 'Ntfs')|$Id"

    switch -Wildcard ($key) {
        "Microsoft-Windows-Kernel-Power|41"          { return "Reinício inesperado: o PC desligou sem passar pelo Windows (botão de ligar segurado, queda de energia, travamento ou superaquecimento)." }
        "EventLog|6008"                               { return "Reinício inesperado: o Windows não foi desligado direito da última vez (queda de energia, travamento ou botão de ligar segurado)." }
        "Microsoft-Windows-WHEA-Logger|*"             { return "O processador, a memória ou uma placa informou um erro de hardware. Se voltar a acontecer, pode ser calor, uma peça com defeito ou uma configuração acelerada (overclock)." }
        "disk|7"                                      { return "O disco tem uma parte com defeito (setor danificado). Faça backup e veja Diagnóstico > Saúde dos discos." }
        "disk|11"                                     { return "Falha na ligação com o disco (cabo ou controladora). Veja Diagnóstico > Saúde dos discos." }
        "disk|51"                                     { return "O disco demorou a responder. Veja Diagnóstico > Saúde dos discos." }
        "disk|153"                                    { return "O disco precisou repetir uma leitura. Veja Diagnóstico > Saúde dos discos." }
        "Ntfs|55"                                     { return "Corrupção no sistema de arquivos: o Windows achou dados danificados no disco. Use Reparo > Verificar o sistema de arquivos (CHKDSK)." }
        "Ntfs|98"                                     { return "O Windows achou erro na organização do disco. Use Reparo > Verificar o sistema de arquivos (CHKDSK)." }
        "Microsoft-Windows-WER-SystemErrorReporting|1001" { return "Tela azul registrada (o Windows parou com um erro grave e reiniciou). Se voltar a acontecer, use Reparo > Reparar o Windows (DISM + SFC) e Atualizações > Atualizar drivers." }
        "Display|4101"                                { return "O driver de vídeo parou de responder e foi recuperado." }
        "Service Control Manager|700?"                { return "Falha ao iniciar um serviço do Windows." }
        "Service Control Manager|7023"                { return "Um serviço terminou com erro." }
        "Service Control Manager|7031"                { return "Um serviço terminou inesperadamente." }
        "Service Control Manager|7034"                { return "Um serviço terminou inesperadamente." }
        # Erros que quase todo PC registra e que, sem explicação, pareciam defeito: um componente do Windows que demorou
        # a responder (DCOM), uma conexão segura recusada por um site ou serviço (Schannel) e uma atualização que falhou
        # (o Windows Update tenta de novo sozinho).
        "Microsoft-Windows-DistributedCOM|*"          { return "Um componente do Windows (DCOM) não respondeu a tempo ou não pôde iniciar." }
        "Schannel|*"                                  { return "Uma conexão segura (TLS) com um site ou serviço foi recusada." }
        "Microsoft-Windows-WindowsUpdateClient|20"    { return "Uma atualização do Windows não foi instalada." }
        default                                       { return "" }
    }
}


function Get-SnakeOptimizerEventNote {
    # O que vem depois de uma causa conhecida que não pede atenção: quase sempre, que ela é comum e não tem consequência;
    # na atualização que falhou, o que fazer se ela continuar falhando.
    param ([string]$Provider, [int]$Id)

    if ("$Provider|$Id" -eq "Microsoft-Windows-WindowsUpdateClient|20") { return "o Windows tenta de novo; se continuar, use Atualizações > Corrigir o Windows Update" }

    return "comum e quase sempre sem consequência"
}


function Test-SnakeOptimizerEventHintSerious {
    <#
    Se a causa conhecida de um grupo de eventos pede atenção. Serviços que falham ao iniciar ou param (7000 a 7034), o
    driver de vídeo que se recuperou sozinho (4101), o DCOM, as conexões seguras recusadas (Schannel) e a atualização que
    falhou (o Windows Update tenta de novo) aparecem na maioria dos PCs saudáveis: a tela os explica, sem alarme.
    #>
    param (
        [string]$Provider,
        [int]$Id
    )

    if ([string]$Provider -in @("Service Control Manager", "Microsoft-Windows-DistributedCOM", "Schannel", "Microsoft-Windows-WindowsUpdateClient")) { return $false }
    if ([string]$Provider -eq "Display" -and $Id -eq 4101) { return $false }

    return [bool](Get-SnakeOptimizerEventHint -Provider $Provider -Id $Id)
}


function Get-SnakeOptimizerEventCause {
    # O que um grupo de eventos conta como causa, para não contar duas vezes o mesmo acontecimento: um desligamento
    # inesperado registra o Kernel-Power 41 e o EventLog 6008 juntos.
    param ([string]$Provider, [int]$Id)

    if (("$Provider|$Id") -in @("Microsoft-Windows-Kernel-Power|41", "EventLog|6008")) { return "desligamento-inesperado" }

    return "$Provider|$Id"
}


function Get-SnakeOptimizerEventCauseName {
    # O nome curto de uma causa séria, para a frase do veredito ("2 problemas sérios: reinício inesperado e tela azul").
    # Os eventos do mesmo assunto têm o mesmo nome (os quatro do disco são "erro de disco") e contam uma vez.
    param ([string]$Provider, [int]$Id)

    $key = "$(([string]$Provider) -replace '^Microsoft-Windows-Ntfs$', 'Ntfs')|$Id"

    switch -Wildcard ($key) {
        "Microsoft-Windows-Kernel-Power|41" { return "reinício inesperado" }
        "EventLog|6008" { return "reinício inesperado" }
        "Microsoft-Windows-WHEA-Logger|*" { return "erro de hardware" }
        "disk|*" { return "erro de disco" }
        "Ntfs|*" { return "erro no sistema de arquivos" }
        "Microsoft-Windows-WER-SystemErrorReporting|1001" { return "tela azul" }
    }

    return (Get-SnakeOptimizerEventCause -Provider $Provider -Id $Id)
}


function Get-SnakeOptimizerEventProviderText {
    # A origem de um evento sem o prefixo "Microsoft-Windows-", que só alonga a linha ("Kernel-Power", "DistributedCOM").
    param (
        [AllowEmptyString()][string]$Provider = ""
    )

    $text = ($Provider -replace '^Microsoft-Windows-', '').Trim()

    return $(if ($text) { $text } else { "Origem desconhecida" })
}


function Format-SnakeOptimizerEventOccurrences {
    # "1 vez, em 23/10 05:37" ou "3 vezes, a última em 23/10 05:37" (a tela e o relatório usam a mesma frase).
    param (
        [Parameter(Mandatory)]
        $Entry
    )

    $count = [int]$Entry.Count
    $times = $(if ($count -eq 1) { "1 vez" } else { "$(Format-SnakeOptimizerNumber -Value $count) vezes" })

    if (-not ($Entry.Last -is [datetime])) {
        return $times
    }

    $when = Format-SnakeOptimizerDateTime -When $Entry.Last -Pattern "dd/MM HH:mm"

    return $(if ($count -eq 1) { "$times, em $when" } else { "$times, a última em $when" })
}


function ConvertTo-SnakeOptimizerEventSummary {
    <#
    Agrupa os eventos por origem e ID numa passada só: contagem, horário do mais recente e dica. Primeiro vêm os grupos
    com dica (causa conhecida), depois os mais frequentes e, no empate, os mais recentes.
    #>
    param (
        [object[]]$Events,
        [int]$Top = 12
    )

    $byKey = [ordered]@{}

    foreach ($event in @($Events)) {
        if ($null -eq $event) {
            continue
        }

        $id = [int]$event.Id
        $key = "$($event.ProviderName)|$id"
        $entry = $byKey[$key]

        if ($null -eq $entry) {
            $byKey[$key] = [PSCustomObject]@{ Count = 1; Provider = [string]$event.ProviderName; Id = $id; Last = $event.TimeCreated; Hint = "" }
            continue
        }

        $entry.Count++

        if ($event.TimeCreated -gt $entry.Last) {
            $entry.Last = $event.TimeCreated
            $entry.Provider = [string]$event.ProviderName
        }
    }

    $summary = @($byKey.Values)

    foreach ($entry in $summary) {
        $entry.Hint = Get-SnakeOptimizerEventHint -Provider $entry.Provider -Id $entry.Id
        Add-Member -InputObject $entry -NotePropertyName Serious -NotePropertyValue (Test-SnakeOptimizerEventHintSerious -Provider $entry.Provider -Id $entry.Id) -Force
    }

    # Primeiro o que pede atenção, depois o que tem explicação, depois o resto; em cada parte, os mais frequentes.
    return @($summary |
        Sort-Object @{ Expression = { if ($_.Serious) { 0 } elseif ($_.Hint) { 1 } else { 2 } } }, @{ Expression = "Count"; Descending = $true }, @{ Expression = "Last"; Descending = $true } |
        Select-Object -First $Top)
}


function Read-SnakeOptimizerEventLog {
    <#
    Lê um log do Windows com uma consulta XPath, do mais novo para o mais antigo, até MaxEvents registros. Devolve só
    ProviderName, Id e TimeCreated: o Get-WinEvent monta o texto de cada evento (a parte lenta, que consulta as DLLs de
    mensagens de cada origem) mesmo quando ninguém o usa. Log sem eventos devolve lista vazia; falha de leitura é lançada.
    #>
    param (
        [Parameter(Mandatory)][string]$LogName,
        [Parameter(Mandatory)][string]$XPath,
        [int]$MaxEvents = 3000
    )

    $query = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($LogName, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $XPath)
    $query.ReverseDirection = $true

    $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($query)
    $events = New-Object System.Collections.Generic.List[object]

    try {
        while ($events.Count -lt $MaxEvents) {
            $record = $reader.ReadEvent()

            if ($null -eq $record) { break }

            # Cada registro guarda um identificador do Windows: liberado já, e não quando o coletor de lixo passar.
            try {
                $events.Add([PSCustomObject]@{ ProviderName = [string]$record.ProviderName; Id = [int]$record.Id; TimeCreated = $record.TimeCreated; RecordId = $record.RecordId })
            }
            finally {
                $record.Dispose()
            }
        }
    }
    finally {
        $reader.Dispose()
    }

    # Sem a vírgula: com ela, a lista chegava a quem chama como um item só (uma lista dentro da lista), e a tela
    # contava um evento sem nome com o log vazio.
    return $events.ToArray()
}


function Get-SnakeOptimizerRecentCriticalEvents {
    <#
    Eventos de nível Crítico e Erro do log do Sistema nos últimos dias. Log sem eventos devolve lista vazia; qualquer
    outra falha de leitura (serviço do log parado, acesso negado, RPC) é lançada, para quem chama não confundir "não consegui
    ler" com "não há nada".
    #>
    param (
        [int]$Days = 7,

        # Limite de leitura: um log muito barulhento não deve travar a tela. Quem mostra o total avisa se chegou nele.
        [int]$MaxEvents = 3000
    )

    # Nível 1 = Crítico, 2 = Erro; timediff conta, em milissegundos, quanto tempo faz que o evento aconteceu. Do nível
    # Aviso (3), só os que dizem algo do hardware: o disco que repetiu ou não conseguiu paginar (51, 153) e o driver de
    # vídeo que parou e voltou (4101). Sem eles, um disco começando a falhar passava por "nenhum evento".
    $window = [int64]([TimeSpan]::FromDays($Days).TotalMilliseconds)
    $warnings = "(Level=3 and ((Provider[@Name='disk'] and (EventID=51 or EventID=153)) or (Provider[@Name='Display'] and EventID=4101)))"
    $xpath = "*[System[((Level=1 or Level=2) or $warnings) and TimeCreated[timediff(@SystemTime) <= $window]]]"

    # Desembrulha uma lista que chegue dentro de outra (um item só que é a lista inteira).
    $events = @(Read-SnakeOptimizerEventLog -LogName "System" -XPath $xpath -MaxEvents $MaxEvents | ForEach-Object { $_ })

    # Um serviço com defeito pode encher o limite de leitura em poucas horas e empurrar para fora o desligamento
    # inesperado de ontem: com o limite cheio, uma segunda leitura, curta, só das origens que têm causa conhecida.
    if ($events.Count -ge $MaxEvents) {
        $known = "Provider[@Name='Microsoft-Windows-Kernel-Power' or @Name='EventLog' or @Name='Microsoft-Windows-WHEA-Logger' or @Name='disk' or @Name='Ntfs' or @Name='Microsoft-Windows-Ntfs' or @Name='Microsoft-Windows-WER-SystemErrorReporting' or @Name='Display']"
        $knownXPath = "*[System[$known and ((Level=1 or Level=2) or $warnings) and TimeCreated[timediff(@SystemTime) <= $window]]]"
        $seen = @{}

        foreach ($event in $events) {
            $recordId = Get-SnakeOptimizerJsonValue -Object $event -Name "RecordId" -Default $null
            if ($null -ne $recordId) { $seen[[string]$recordId] = $true }
        }

        $extra = @(Read-SnakeOptimizerEventLog -LogName "System" -XPath $knownXPath -MaxEvents 500 | ForEach-Object { $_ } | Where-Object {
                $recordId = Get-SnakeOptimizerJsonValue -Object $_ -Name "RecordId" -Default $null
                $null -eq $recordId -or -not $seen.ContainsKey([string]$recordId)
            })

        $events = @($events) + @($extra)
    }

    return @($events)
}


function Show-SnakeOptimizerCriticalEvents {
    $title = "Eventos críticos (7 dias)"
    Enter-SnakeOptimizerAction -Title $title

    $maxEvents = 3000
    $shownGroups = 12

    # O andamento vai na barra: uma linha "Lendo..." ficaria no resumo depois do fim.
    Write-Progress -Activity $title -Status "lendo os registros de erro do Windows"

    try {
        $events = @(Get-SnakeOptimizerRecentCriticalEvents -Days 7 -MaxEvents $maxEvents | ForEach-Object { $_ })
    }
    catch {
        Write-Progress -Activity $title -Completed
        Write-Host ""
        Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível ler o log do Sistema: $($_.Exception.Message)"
        Write-SnakeOptimizerStatus -Type Info -Message "Isto não quer dizer que não haja eventos. Abra o Visualizador de Eventos (eventvwr.msc) para conferir."
        Exit-SnakeOptimizerAction
        return
    }

    Write-Progress -Activity $title -Completed

    $groups = @(ConvertTo-SnakeOptimizerEventSummary -Events $events -Top ([int]::MaxValue))
    $summary = @($groups | Select-Object -First $shownGroups)
    $result = $null

    Write-Host ""

    if ($summary.Count -eq 0) {
        Write-SnakeOptimizerStatus -Type Success -Message "Nenhum evento crítico ou de erro nos últimos 7 dias."
        $result = New-SnakeOptimizerResult -Kind Ok -Detail "nenhum evento crítico ou de erro nos últimos 7 dias"
    }
    else {
        # Os avisos lidos (disco 51 e 153, vídeo 4101) contam à parte: não são erros.
        $warningCount = @($events | Where-Object { ("$($_.ProviderName)|$($_.Id)") -in @("disk|51", "disk|153", "Display|4101") }).Count
        $errorCount = $events.Count - $warningCount
        $parts = @()
        if ($errorCount -gt 0) { $parts += "$(Format-SnakeOptimizerNumber -Value $errorCount)$(if ($errorCount -eq 1) { ' evento de erro ou crítico' } else { ' eventos de erro ou críticos' })" }
        if ($warningCount -gt 0) { $parts += "$(Format-SnakeOptimizerNumber -Value $warningCount)$(if ($warningCount -eq 1) { ' aviso do disco ou do vídeo' } else { ' avisos do disco ou do vídeo' })" }
        $total = $parts -join " e "
        if ($events.Count -ge $maxEvents) { $total = "Pelo menos $total (limite de leitura)" }

        # O que pede atenção, contado e dito por causa: o desligamento inesperado (41 e 6008 juntos) conta uma vez, e os
        # erros do disco também.
        $causes = @($groups | Where-Object { $_.Serious } | ForEach-Object { Get-SnakeOptimizerEventCauseName -Provider $_.Provider -Id $_.Id } | Select-Object -Unique)

        if ($causes.Count -gt 0) {
            $knownText = "$(Format-SnakeOptimizerCount -Count $causes.Count -One 'problema sério' -Many 'problemas sérios'): $(Join-SnakeOptimizerList -Items $causes)"
            Write-SnakeOptimizerStatus -Type Warning -Message "${knownText}."
            $result = New-SnakeOptimizerResult -Kind Warning -Detail $knownText
        }
        else {
            # Quase todo PC registra erros assim toda semana: sem uma conclusão, "120 erros" faria a pessoa achar que o PC
            # está quebrado.
            $common = "$(if ($events.Count -ge $maxEvents) { 'pelo menos ' } else { '' })$(Format-SnakeOptimizerNumber -Value $events.Count) $(if ($events.Count -eq 1) { 'erro comum' } else { 'erros comuns' }) do Windows"
            Write-SnakeOptimizerStatus -Type Success -Message "Nenhum problema sério nos últimos 7 dias. Os erros abaixo aparecem em quase todo PC e não pedem nada."
            $result = New-SnakeOptimizerResult -Kind Ok -Detail "nenhum problema sério; $common"
        }

        Write-SnakeOptimizerStatus -Type Info -Message "$total nos últimos 7 dias, em $(Format-SnakeOptimizerCount -Count $groups.Count -One 'grupo' -Many 'grupos')."

        # Cada grupo numa linha que a janela também mostra no resumo: o de causa conhecida vira um aviso com a explicação;
        # os outros, uma linha "origem (ID) : quantas vezes". O desligamento inesperado registra dois eventos (Kernel-Power
        # 41 e EventLog 6008): os dois viram uma linha só, com a contagem do que tiver mais registros.
        Write-SnakeOptimizerSection -Title "Eventos por origem"

        $shutdown = @($summary | Where-Object { (Get-SnakeOptimizerEventCause -Provider $_.Provider -Id $_.Id) -eq "desligamento-inesperado" })
        $shutdownShown = $false

        foreach ($item in $summary) {
            $provider = Get-SnakeOptimizerEventProviderText -Provider $item.Provider
            $times = Format-SnakeOptimizerEventOccurrences -Entry $item

            if ($shutdown.Count -gt 1 -and @($shutdown) -contains $item) {
                if ($shutdownShown) { continue }
                $shutdownShown = $true

                $main = @($shutdown | Sort-Object -Property @{ Expression = { [int]$_.Count }; Descending = $true }, @{ Expression = { [int]$_.Id -ne 41 } })[0]
                $ids = @($shutdown | Sort-Object -Property @{ Expression = { [int]$_.Id -ne 41 } } | ForEach-Object { "$(Get-SnakeOptimizerEventProviderText -Provider $_.Provider), ID $($_.Id)" }) -join "; "
                Write-SnakeOptimizerStatus -Type Warning -Message "$((Get-SnakeOptimizerEventHint -Provider 'Microsoft-Windows-Kernel-Power' -Id 41)) $(Format-SnakeOptimizerEventOccurrences -Entry $main) ($ids)."
                continue
            }

            if ($item.Hint -and [bool](Get-SnakeOptimizerJsonValue -Object $item -Name "Serious" -Default $true)) {
                Write-SnakeOptimizerStatus -Type Warning -Message "$($item.Hint) $times ($provider, ID $($item.Id))."
            }
            elseif ($item.Hint) {
                Write-SnakeOptimizerStatus -Type Info -Message "$($item.Hint) $times ($provider, ID $($item.Id)); $(Get-SnakeOptimizerEventNote -Provider $item.Provider -Id $item.Id)."
            }
            else {
                Write-SnakeOptimizerKeyValue -Label "$provider (ID $($item.Id))" -Value $times
            }
        }

        if ($groups.Count -gt $summary.Count) {
            Write-Host ""
            Write-SnakeOptimizerStatus -Type Info -Message "Mais $(Format-SnakeOptimizerCount -Count ($groups.Count - $summary.Count) -One 'grupo menos relevante' -Many 'grupos menos relevantes'); o Visualizador de Eventos (eventvwr.msc) mostra a lista completa."
        }
    }

    Exit-SnakeOptimizerAction -Result $result
}


Export-ModuleMember -Function *
