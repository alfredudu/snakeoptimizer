# Ferramentas de suporte da Snake Tech: os reparos que o técnico mais usa no dia a dia e que não existiam no SnakeOptimizer.
#
#   Invoke-SnakeOptimizerOfficeRepair     - Microsoft Office: limpar cache, redefinir login/ativação, reparo rápido e online
#   Invoke-SnakeOptimizerPrintSpoolerReset - destrava a fila de impressão (para o Spooler, apaga os trabalhos presos, religa)
#   Invoke-SnakeOptimizerStoreReset       - limpa o cache da Microsoft Store (wsreset)
#   Invoke-SnakeOptimizerTimeSync         - acerta a data e a hora pelo servidor de horário
#   Invoke-SnakeOptimizerProxyReset       - tira um proxy travado (do usuário e do WinHTTP)
#
# Todas seguem o padrão das outras ações: explicam o que vão fazer, perguntam antes de mexer e devolvem um
# SnakeOptimizer.Result com -PassThru.


# ---------------------------------------------------------------------------
# Auxiliares
# ---------------------------------------------------------------------------

function Exit-SnakeOptimizerToolEarly {
    # Encerra a ação com um resultado (Skipped/Failed) e o devolve com -PassThru.
    param (
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet("Ok", "Skipped", "Warning", "Failed")][string]$Kind,
        [string]$Detail = "",
        [switch]$PassThru
    )

    $result = New-SnakeOptimizerResult -Kind $Kind -Detail $Detail -Title $Title
    if ($PassThru) { $result }
    Exit-SnakeOptimizerAction -Result $result
}


function Test-SnakeOptimizerToolUserContext {
    # Ações que mexem no perfil do usuário (HKCU, %LOCALAPPDATA%) não podem rodar elevadas com outra conta: mexeriam no
    # perfil do administrador, não no de quem usa o PC. Devolve $true quando pode seguir.
    if (-not (Test-SnakeOptimizerUserContextMismatch)) { return $true }

    $interactiveUser = Get-SnakeOptimizerInteractiveUser
    Write-SnakeOptimizerStatus -Type Warning -Message "O SnakeOptimizer está elevado com outra conta, não a de $interactiveUser. Esta ação mexe no perfil do usuário: abra o SnakeOptimizer logado como ele."
    return $false
}


function Clear-SnakeOptimizerToolFolder {
    # Apaga o conteúdo de uma pasta (não a pasta). Devolve quantos itens saíram e quantos ficaram (em uso).
    param ([Parameter(Mandatory)][string]$Path)

    $removed = 0
    $kept = 0

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Removed = 0; Kept = 0; Exists = $false }
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        try {
            Remove-SnakeOptimizerItem -Path $item.FullName
            $removed++
        }
        catch {
            $kept++
        }
    }

    return [PSCustomObject]@{ Removed = $removed; Kept = $kept; Exists = $true }
}


# ---------------------------------------------------------------------------
# Microsoft Office
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerOfficeInstall {
    # O Office Clique para Executar (Microsoft 365, 2016 a 2024) e o caminho do OfficeClickToRun.exe. Kind: ClickToRun,
    # Msi (Office antigo, instalado por .msi) ou None.
    $configPath = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
    $exe = Join-Path $env:CommonProgramFiles "Microsoft Shared\ClickToRun\OfficeClickToRun.exe"

    if ((Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $exe)) {
        $config = Get-ItemProperty -LiteralPath $configPath -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            Kind     = "ClickToRun"
            Exe      = $exe
            Products = ([string]$config.ProductReleaseIds) -replace ',', ', '
            Version  = [string]$config.VersionToReport
            Platform = $(if ([string]$config.Platform) { [string]$config.Platform } else { "x64" })
            Culture  = $(if ([string]$config.ClientCulture) { [string]$config.ClientCulture } else { "pt-br" })
        }
    }

    foreach ($root in "HKLM:\SOFTWARE\Microsoft\Office", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office") {
        foreach ($version in "16.0", "15.0", "14.0") {
            if (Test-Path -LiteralPath "$root\$version\Common\InstallRoot") {
                return [PSCustomObject]@{ Kind = "Msi"; Exe = ""; Products = "Office $version (MSI)"; Version = $version; Platform = ""; Culture = "" }
            }
        }
    }

    return [PSCustomObject]@{ Kind = "None"; Exe = ""; Products = ""; Version = ""; Platform = ""; Culture = "" }
}


function Get-SnakeOptimizerOfficeProcesses {
    $names = "WINWORD", "EXCEL", "POWERPNT", "OUTLOOK", "ONENOTE", "MSACCESS", "MSPUB", "VISIO", "WINPROJ", "lync", "OfficeClickToRun_UI"
    return @(Get-Process -Name $names -ErrorAction SilentlyContinue)
}


function Close-SnakeOptimizerOfficeApps {
    # Pede para fechar os programas do Office abertos (podem ter documentos sem salvar). Devolve $true quando nenhum ficou aberto.
    $open = @(Get-SnakeOptimizerOfficeProcesses)

    if ($open.Count -eq 0) { return $true }

    $names = ($open | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ", "
    Write-SnakeOptimizerStatus -Type Warning -Notice -Message "Programas do Office abertos: $names. Salve os documentos antes de continuar."

    if (-not (Confirm-SnakeOptimizerAction "Fechar os programas do Office agora?" -DefaultKey N -YesLabel "Fechar o Office" -NoLabel "Cancelar")) {
        return $false
    }

    # Primeiro pede para fechar (o programa pode perguntar se quer salvar); o que não fechar em 15 segundos é encerrado.
    foreach ($process in $open) { try { [void]$process.CloseMainWindow() } catch { } }

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and @(Get-SnakeOptimizerOfficeProcesses).Count -gt 0) { Start-Sleep -Milliseconds 500 }

    @(Get-SnakeOptimizerOfficeProcesses) | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    return (@(Get-SnakeOptimizerOfficeProcesses).Count -eq 0)
}


function Clear-SnakeOptimizerOfficeCache {
    # Cache de suplementos (Wef) e o cache de documentos do Office (OfficeFileCache). Resolve travamento ao abrir, suplemento
    # que não carrega e o "Centro de Carregamento" com erro de sincronização.
    $office = Join-Path $env:LOCALAPPDATA "Microsoft\Office"
    $targets = @(
        @{ Label = "Cache de suplementos (Wef)"; Path = Join-Path $office "16.0\Wef" },
        @{ Label = "Cache de documentos (OfficeFileCache)"; Path = Join-Path $office "16.0\OfficeFileCache" },
        @{ Label = "Cache de documentos (Office 2013)"; Path = Join-Path $office "15.0\OfficeFileCache" }
    )

    $total = 0
    $kept = 0

    foreach ($target in $targets) {
        $result = Clear-SnakeOptimizerToolFolder -Path $target.Path
        if (-not $result.Exists) { continue }

        $total += $result.Removed
        $kept += $result.Kept
        Write-SnakeOptimizerKeyValue -Label $target.Label -Value "$($result.Removed) itens apagados$(if ($result.Kept) { ", $($result.Kept) em uso" })" -LabelWidth 38
    }

    return [PSCustomObject]@{ Removed = $total; Kept = $kept }
}


function Reset-SnakeOptimizerOfficeIdentity {
    # Esquece a conta e a ativação guardadas pelo Office deste usuário: no próximo Word/Excel ele pede o login de novo.
    # Resolve "Produto não licenciado", conta errada presa, loop de login e "Falha na ativação".
    $done = @()
    $failed = @()

    $keys = @(
        "HKCU:\Software\Microsoft\Office\16.0\Common\Identity",
        "HKCU:\Software\Microsoft\Office\16.0\Common\Licensing",
        "HKCU:\Software\Microsoft\Office\15.0\Common\Identity"
    )

    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        try { Remove-SnakeOptimizerRegistryKey -Path $key; $done += $key } catch { $failed += $key }
    }

    $folders = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\Office\Licenses"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\Office\16.0\Licensing")
    )

    foreach ($folder in $folders) {
        $result = Clear-SnakeOptimizerToolFolder -Path $folder
        if ($result.Exists) {
            if ($result.Kept -gt 0) { $failed += $folder } else { $done += $folder }
        }
    }

    # Credenciais do Office no Gerenciador de Credenciais ("MicrosoftOffice16_Data:..."), apagadas pelo cmdkey.
    $credentials = @()

    try {
        $listing = @(& cmdkey.exe /list 2>$null)
        foreach ($line in $listing) {
            if ($line -match '(?i)(?:Destino|Target):\s*(?:LegacyGeneric:target=|target=)?(.*MicrosoftOffice1[56].*)$') {
                $credentials += $Matches[1].Trim()
            }
        }
    }
    catch {
        Write-Verbose "cmdkey: $($_.Exception.Message)"
    }

    foreach ($credential in ($credentials | Sort-Object -Unique)) {
        & cmdkey.exe "/delete:$credential" *> $null
        if ($LASTEXITCODE -eq 0) { $done += "credencial $credential" } else { $failed += "credencial $credential" }
    }

    return [PSCustomObject]@{ Done = $done; Failed = $failed; Credentials = $credentials.Count }
}


function Invoke-SnakeOptimizerOfficeRepair {
    param ([switch]$PassThru)

    $title = "Reparar o Microsoft Office"
    Enter-SnakeOptimizerAction -Title $title

    if (-not (Test-SnakeOptimizerElevation -Reason "O reparo do Office exige privilégios de Administrador.")) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Failed -Detail "sem privilégios de Administrador" -PassThru:$PassThru
        return
    }

    $office = Get-SnakeOptimizerOfficeInstall

    Write-SnakeOptimizerSection -Title "Office instalado"

    if ($office.Kind -eq "None") {
        Write-SnakeOptimizerStatus -Type Info -Message "Nenhum Microsoft Office foi encontrado neste PC."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "Office não encontrado" -PassThru:$PassThru
        return
    }

    Write-SnakeOptimizerKeyValue -Label "Produtos" -Value $office.Products -LabelWidth 18
    if ($office.Kind -eq "ClickToRun") {
        Write-SnakeOptimizerKeyValue -Label "Versão" -Value $office.Version -LabelWidth 18
        Write-SnakeOptimizerKeyValue -Label "Plataforma" -Value $office.Platform -LabelWidth 18
    }

    $options = @(
        @{ Key = "1"; Label = "Limpar cache do Office"; Description = "Travamentos ao abrir, suplementos com erro, Centro de Carregamento com falha. Rápido."; Accent = $true },
        @{ Key = "2"; Label = "Redefinir login e ativação"; Description = "Produto não licenciado, conta errada, loop de login. Pede o login de novo no próximo uso." }
    )

    if ($office.Kind -eq "ClickToRun") {
        $options += @{ Key = "3"; Label = "Reparo rápido"; Description = "Conserta arquivos do Office sem internet. Leva poucos minutos." }
        $options += @{ Key = "4"; Label = "Reparo online"; Description = "Reinstala o Office pela internet: resolve quase tudo. Leva de 15 a 40 minutos." }
    }
    else {
        Write-SnakeOptimizerStatus -Type Info -Message "Office instalado por MSI (versão antiga): o reparo dos arquivos é feito em Programas e Recursos > Office > Alterar > Reparar."
    }

    $options += @{ Key = "X"; Label = "Cancelar"; Exit = $true }

    $answer = Read-SnakeOptimizerChoice -Message "O que fazer no Office?" -Options $options -DefaultKey "X" -ShowMenu `
        -TextPrompt "Opção (número, X = cancelar; ENTER = cancelar)"

    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "X" -or $answer -eq "0") {
        Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "cancelado pelo usuário" -PassThru:$PassThru
        return
    }

    # Cache e login ficam no perfil do usuário.
    if ($answer -in "1", "2" -and -not (Test-SnakeOptimizerToolUserContext)) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "elevado com outra conta" -PassThru:$PassThru
        return
    }

    if (-not (Close-SnakeOptimizerOfficeApps)) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Os programas do Office continuam abertos; nada foi alterado."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "Office aberto" -PassThru:$PassThru
        return
    }

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title

    try {
        switch ($answer) {
            "1" {
                Write-SnakeOptimizerSection -Title "Limpando o cache do Office"
                $cache = Clear-SnakeOptimizerOfficeCache

                if ($cache.Kept -gt 0) {
                    Write-SnakeOptimizerStatus -Type Warning -Message "Cache limpo: $($cache.Removed) itens apagados; $($cache.Kept) estavam em uso (reinicie o PC e repita se o problema continuar)."
                    $final = New-SnakeOptimizerResult -Kind Warning -Detail "$($cache.Kept) itens em uso" -Title $title
                }
                else {
                    Write-SnakeOptimizerStatus -Type Success -Message "Cache do Office limpo ($($cache.Removed) itens). Abra o Office de novo e teste."
                }
            }
            "2" {
                Write-SnakeOptimizerSection -Title "Redefinindo login e ativação"
                $identity = Reset-SnakeOptimizerOfficeIdentity

                foreach ($item in $identity.Done) { Write-SnakeOptimizerCommand -Command "removido: $item" }

                if ($identity.Failed.Count -gt 0) {
                    Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível remover: $($identity.Failed -join '; ')."
                    $final = New-SnakeOptimizerResult -Kind Warning -Detail "itens não removidos" -Title $title
                }
                elseif ($identity.Done.Count -eq 0) {
                    Write-SnakeOptimizerStatus -Type Info -Message "Não havia login nem ativação guardados para este usuário."
                    $final = New-SnakeOptimizerResult -Kind Skipped -Detail "nada para redefinir" -Title $title
                }
                else {
                    Write-SnakeOptimizerStatus -Type Success -Message "Login e ativação do Office redefinidos. Abra o Word, entre com a conta certa e o Office se ativa sozinho."
                }
            }
            { $_ -in "3", "4" } {
                $repairType = $(if ($answer -eq "3") { "QuickRepair" } else { "FullRepair" })
                $label = $(if ($answer -eq "3") { "Reparo rápido" } else { "Reparo online" })

                if ($answer -eq "4") {
                    Write-SnakeOptimizerStatus -Type Warning -Notice -Message "O reparo online desinstala e reinstala o Office pela internet. Os documentos não são afetados."
                    if (-not (Confirm-SnakeOptimizerAction "Iniciar o reparo online?" -DefaultKey N)) {
                        Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
                        $final = New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title
                        break
                    }
                }

                Write-SnakeOptimizerSection -Title $label
                $arguments = @("scenario=Repair", "platform=$($office.Platform)", "culture=$($office.Culture)", "RepairType=$repairType", "forceappshutdown=True", "DisplayLevel=True")
                Write-SnakeOptimizerCommand -Command "OfficeClickToRun.exe $($arguments -join ' ')"

                Start-Process -FilePath $office.Exe -ArgumentList $arguments -ErrorAction Stop
                Write-SnakeOptimizerStatus -Type Success -Message "$label iniciado: acompanhe na janela do Office que abriu. Ao terminar, abra o Word e teste."
                $final = New-SnakeOptimizerResult -Kind Ok -Detail "$label iniciado" -Title $title
            }
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "O reparo do Office falhou: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


# ---------------------------------------------------------------------------
# Fila de impressão
# ---------------------------------------------------------------------------

function Invoke-SnakeOptimizerPrintSpoolerReset {
    param ([switch]$PassThru)

    $title = "Destravar a fila de impressão"
    Enter-SnakeOptimizerAction -Title $title

    if (-not (Test-SnakeOptimizerElevation -Reason "Destravar a fila de impressão exige privilégios de Administrador.")) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Failed -Detail "sem privilégios de Administrador" -PassThru:$PassThru
        return
    }

    $spoolFolder = Join-Path $env:SystemRoot "System32\spool\PRINTERS"
    $service = Get-Service -Name "Spooler" -ErrorAction SilentlyContinue

    if ($null -eq $service) {
        Write-SnakeOptimizerStatus -Type Error -Message "O serviço Spooler de Impressão não existe neste Windows."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Failed -Detail "Spooler ausente" -PassThru:$PassThru
        return
    }

    $stuck = @(Get-ChildItem -LiteralPath $spoolFolder -File -Force -ErrorAction SilentlyContinue)

    Write-SnakeOptimizerSection -Title "Situação"
    Write-SnakeOptimizerKeyValue -Label "Spooler de Impressão" -Value $(if ($service.Status -eq "Running") { "Em execução" } else { [string]$service.Status }) -Level $(if ($service.Status -eq "Running") { "Normal" } else { "Warn" }) -LabelWidth 26
    Write-SnakeOptimizerKeyValue -Label "Arquivos na fila (spool)" -Value $stuck.Count -Level $(if ($stuck.Count -gt 0) { "Warn" } else { "Normal" }) -LabelWidth 26

    Write-SnakeOptimizerSection -Title "O que será feito"
    Write-SnakeOptimizerCommand -Command "net stop spooler"
    Write-SnakeOptimizerCommand -Command "del /q %SystemRoot%\System32\spool\PRINTERS\*"
    Write-SnakeOptimizerCommand -Command "net start spooler"
    Write-SnakeOptimizerStatus -Type Warning -Notice -Message "Todos os documentos na fila de todas as impressoras serão cancelados."

    if (-not (Confirm-SnakeOptimizerAction "Destravar a fila de impressão agora?" -DefaultKey S)) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "cancelado pelo usuário" -PassThru:$PassThru
        return
    }

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title

    try {
        # Serviços que dependem do Spooler (Fax, por exemplo) param junto; os que estavam rodando voltam no fim.
        $dependents = @($service.DependentServices | Where-Object { $_.Status -eq "Running" } | ForEach-Object { $_.Name })

        Write-Progress -Activity $title -Status "parando o Spooler"
        Stop-Service -Name "Spooler" -Force -ErrorAction Stop
        (Get-Service -Name "Spooler").WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
        Write-SnakeOptimizerStatus -Type Success -Message "Spooler parado."

        Write-Progress -Activity $title -Status "apagando os trabalhos presos"
        $cleared = Clear-SnakeOptimizerToolFolder -Path $spoolFolder
        Write-SnakeOptimizerStatus -Type $(if ($cleared.Kept) { "Warning" } else { "Success" }) -Message "Fila limpa: $($cleared.Removed) arquivos apagados$(if ($cleared.Kept) { ", $($cleared.Kept) em uso" })."

        Write-Progress -Activity $title -Status "religando o Spooler"
        Start-Service -Name "Spooler" -ErrorAction Stop
        foreach ($name in $dependents) { Start-Service -Name $name -ErrorAction SilentlyContinue }
        Write-SnakeOptimizerStatus -Type Success -Message "Spooler religado. Mande imprimir de novo."

        if ($cleared.Kept -gt 0) { $final = New-SnakeOptimizerResult -Kind Warning -Detail "$($cleared.Kept) arquivos em uso" -Title $title }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Falhou: $($_.Exception.Message)"
        # Nunca deixa o PC sem impressão: tenta religar mesmo depois de uma falha.
        Start-Service -Name "Spooler" -ErrorAction SilentlyContinue
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }
    finally {
        Write-Progress -Activity $title -Completed
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


# ---------------------------------------------------------------------------
# Microsoft Store
# ---------------------------------------------------------------------------

function Invoke-SnakeOptimizerStoreReset {
    param ([switch]$PassThru)

    $title = "Redefinir a Microsoft Store"
    Enter-SnakeOptimizerAction -Title $title

    # O cache da Store é do usuário: elevado com outra conta, limparia o do administrador.
    if (-not (Test-SnakeOptimizerToolUserContext)) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "elevado com outra conta" -PassThru:$PassThru
        return
    }

    Write-SnakeOptimizerStatus -Type Info -Notice -Message "Limpa o cache da Microsoft Store (wsreset). Resolve download parado, erro ao instalar e a Store que não abre. Não remove aplicativos."
    Write-SnakeOptimizerCommand -Command "wsreset.exe"

    if (-not (Confirm-SnakeOptimizerAction "Redefinir a Microsoft Store agora?" -DefaultKey S)) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "cancelado pelo usuário" -PassThru:$PassThru
        return
    }

    try {
        Write-Progress -Activity $title -Status "limpando o cache (a Store abre sozinha ao terminar)"
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\wsreset.exe") -PassThru -WindowStyle Hidden -ErrorAction Stop

        if (-not $process.WaitForExit(120000)) {
            Write-SnakeOptimizerStatus -Type Warning -Message "O wsreset ainda está rodando depois de 2 minutos; a Store deve abrir quando ele terminar."
            $final = New-SnakeOptimizerResult -Kind Warning -Detail "wsreset demorou" -Title $title
        }
        else {
            Write-SnakeOptimizerStatus -Type Success -Message "Cache da Microsoft Store limpo. A Store abre sozinha; tente o download de novo."
            $final = New-SnakeOptimizerResult -Kind Ok -Title $title
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Falhou: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }
    finally {
        Write-Progress -Activity $title -Completed
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


# ---------------------------------------------------------------------------
# Data e hora
# ---------------------------------------------------------------------------

function Invoke-SnakeOptimizerTimeSync {
    param ([switch]$PassThru)

    $title = "Acertar data e hora"
    Enter-SnakeOptimizerAction -Title $title

    if (-not (Test-SnakeOptimizerElevation -Reason "Acertar a hora exige privilégios de Administrador.")) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Failed -Detail "sem privilégios de Administrador" -PassThru:$PassThru
        return
    }

    Write-SnakeOptimizerSection -Title "Situação"
    Write-SnakeOptimizerKeyValue -Label "Hora do PC" -Value (Get-Date -Format "dd/MM/yyyy HH:mm:ss") -LabelWidth 22

    $source = ""
    try { $source = ((& w32tm.exe /query /source 2>$null) | Select-Object -First 1).Trim() } catch { }
    if ($source) { Write-SnakeOptimizerKeyValue -Label "Servidor de horário" -Value $source -LabelWidth 22 }

    Write-SnakeOptimizerStatus -Type Info -Notice -Message "Hora errada quebra login no Office/Microsoft 365, sites com HTTPS, VPN e o Windows Update."

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title

    try {
        # O serviço de horário vem desligado em muitos PCs: liga em modo manual (o Windows o inicia quando precisa).
        $service = Get-Service -Name "W32Time" -ErrorAction Stop

        if ($service.StartType -eq "Disabled") {
            Set-Service -Name "W32Time" -StartupType Manual -ErrorAction Stop
            Write-SnakeOptimizerStatus -Type Info -Message "O serviço de horário estava desativado; foi posto em modo manual."
        }

        if ($service.Status -ne "Running") {
            Start-Service -Name "W32Time" -ErrorAction Stop
        }

        Write-Progress -Activity $title -Status "sincronizando com o servidor de horário"
        Write-SnakeOptimizerCommand -Command "w32tm /resync /force"
        $code = Invoke-SnakeOptimizerNative -FilePath "w32tm.exe" -Arguments @("/resync", "/force") -IgnoreExitCode -PassThru

        if ($code -ne 0) {
            # Configuração quebrada ou sem servidor: refaz a configuração (sem trocar o servidor) e tenta de novo.
            Write-SnakeOptimizerCommand -Command "w32tm /config /update"
            [void](Invoke-SnakeOptimizerNative -FilePath "w32tm.exe" -Arguments @("/config", "/update") -IgnoreExitCode -PassThru)
            Start-Sleep -Seconds 2
            $code = Invoke-SnakeOptimizerNative -FilePath "w32tm.exe" -Arguments @("/resync", "/force") -IgnoreExitCode -PassThru
        }

        Write-Host ""
        Write-SnakeOptimizerKeyValue -Label "Hora depois" -Value (Get-Date -Format "dd/MM/yyyy HH:mm:ss") -LabelWidth 22

        if ($code -eq 0) {
            Write-SnakeOptimizerStatus -Type Success -Message "Data e hora sincronizadas."
        }
        else {
            Write-SnakeOptimizerStatus -Type Warning -Message "A sincronização falhou (código $code). Confira a internet e se a porta UDP 123 não está bloqueada pelo firewall."
            $final = New-SnakeOptimizerResult -Kind Warning -Detail "w32tm código $code" -Title $title
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Falhou: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }
    finally {
        Write-Progress -Activity $title -Completed
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


# ---------------------------------------------------------------------------
# Proxy
# ---------------------------------------------------------------------------

function Invoke-SnakeOptimizerProxyReset {
    param ([switch]$PassThru)

    $title = "Remover proxy travado"
    Enter-SnakeOptimizerAction -Title $title

    if (-not (Test-SnakeOptimizerElevation -Reason "Remover o proxy do sistema (WinHTTP) exige privilégios de Administrador.")) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Failed -Detail "sem privilégios de Administrador" -PassThru:$PassThru
        return
    }

    # O proxy do usuário fica no HKCU dele.
    if (-not (Test-SnakeOptimizerToolUserContext)) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "elevado com outra conta" -PassThru:$PassThru
        return
    }

    $settingsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $userProxy = Get-SnakeOptimizerProxySettings
    $winHttp = ""
    try { $winHttp = ((& netsh.exe winhttp show proxy 2>$null) -join " ") -replace '\s+', ' ' } catch { }
    $winHttpDirect = ($winHttp -match '(?i)direct access|acesso direto|sem servidor proxy|no proxy server')

    Write-SnakeOptimizerSection -Title "Situação"
    Write-SnakeOptimizerKeyValue -Label "Proxy do usuário" -Value $(if ($userProxy.Text) { $userProxy.Text } else { "Nenhum" }) -Level $(if ($userProxy.Text) { "Warn" } else { "Normal" }) -LabelWidth 22
    Write-SnakeOptimizerKeyValue -Label "Proxy do sistema" -Value $(if ($winHttpDirect -or -not $winHttp) { "Nenhum (acesso direto)" } else { "Configurado" }) -Level $(if ($winHttpDirect -or -not $winHttp) { "Normal" } else { "Warn" }) -LabelWidth 22

    if (-not $userProxy.Text -and ($winHttpDirect -or -not $winHttp)) {
        Write-SnakeOptimizerStatus -Type Success -Message "Não há proxy configurado; nada a remover."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "sem proxy" -PassThru:$PassThru
        return
    }

    Write-SnakeOptimizerSection -Title "O que será feito"
    Write-SnakeOptimizerCommand -Command "Desligar o proxy manual e o script de configuração automática do usuário"
    Write-SnakeOptimizerCommand -Command "netsh winhttp reset proxy"
    Write-SnakeOptimizerStatus -Type Warning -Notice -Message "Em empresa que exige proxy, a internet para de funcionar depois disso. Use só quando um programa ou vírus deixou um proxy que não deveria existir."

    if (-not (Confirm-SnakeOptimizerAction "Remover o proxy agora?" -DefaultKey N)) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "cancelado pelo usuário" -PassThru:$PassThru
        return
    }

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title

    try {
        # Anota os valores antigos na saída (e no log), para dar para refazer à mão se for preciso.
        $old = Get-ItemProperty -LiteralPath $settingsKey -ErrorAction SilentlyContinue
        Write-SnakeOptimizerCommand -Command "antes: ProxyEnable=$($old.ProxyEnable) ProxyServer=$($old.ProxyServer) AutoConfigURL=$($old.AutoConfigURL)"

        Set-ItemProperty -LiteralPath $settingsKey -Name "ProxyEnable" -Value 0 -Type DWord -ErrorAction Stop
        Remove-SnakeOptimizerRegistryValue -Path $settingsKey -Name "AutoConfigURL"
        Write-SnakeOptimizerStatus -Type Success -Message "Proxy do usuário desligado."

        $code = Invoke-SnakeOptimizerNative -FilePath "netsh.exe" -Arguments @("winhttp", "reset", "proxy") -IgnoreExitCode -PassThru
        if ($code -eq 0) {
            Write-SnakeOptimizerStatus -Type Success -Message "Proxy do sistema (WinHTTP) redefinido."
        }
        else {
            Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível redefinir o proxy do sistema (código $code)."
            $final = New-SnakeOptimizerResult -Kind Warning -Detail "WinHTTP código $code" -Title $title
        }

        Write-SnakeOptimizerStatus -Type Info -Message "Feche e abra o navegador para valer."
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Falhou: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


Export-ModuleMember -Function *-SnakeOptimizer*
