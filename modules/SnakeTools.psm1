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


function Start-SnakeOptimizerOfficeUpdate {
    # Pede ao Clique para Executar que procure e instale a atualização, mostrando o andamento. -ForceAppShutdown: fecha o
    # Office para aplicar já (usado depois de fechar com a pessoa); sem ele, a atualização espera o Office ser fechado.
    param ([switch]$ForceAppShutdown)

    $client = Join-Path $env:CommonProgramFiles "Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    if (-not (Test-Path -LiteralPath $client)) { throw "OfficeC2RClient.exe não encontrado: a instalação do Office está quebrada." }

    $arguments = @("/update", "user", "displaylevel=True", "forceappshutdown=$(if ($ForceAppShutdown) { 'True' } else { 'False' })")
    Write-SnakeOptimizerCommand -Command "OfficeC2RClient.exe $($arguments -join ' ')"
    Start-Process -FilePath $client -ArgumentList $arguments -ErrorAction Stop
}


function Clear-SnakeOptimizerTeamsCache {
    # Teams novo (pacote MSTeams) e clássico (%APPDATA%\Microsoft\Teams). Só caches: conversas, arquivos e login ficam na
    # nuvem e voltam sozinhos. Resolve Teams travado, tela branca, sem notificações e foto/status desatualizados.
    $running = @(Get-Process -Name "ms-teams", "Teams" -ErrorAction SilentlyContinue)

    if ($running.Count -gt 0) {
        if (-not (Confirm-SnakeOptimizerAction "O Teams está aberto. Fechar o Teams agora?" -DefaultKey S -YesLabel "Fechar o Teams" -NoLabel "Cancelar")) {
            return $null
        }

        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    $classic = Join-Path $env:APPDATA "Microsoft\Teams"
    $targets = @(
        @{ Label = "Teams novo"; Path = Join-Path $env:LOCALAPPDATA "Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams" }
    )
    foreach ($folder in "Cache", "blob_storage", "databases", "GPUCache", "IndexedDB", "Local Storage", "tmp", "Code Cache", "Service Worker") {
        $targets += @{ Label = "Teams clássico ($folder)"; Path = Join-Path $classic $folder }
    }

    $total = 0
    $kept = 0
    $found = $false

    foreach ($target in $targets) {
        $result = Clear-SnakeOptimizerToolFolder -Path $target.Path
        if (-not $result.Exists) { continue }

        $found = $true
        $total += $result.Removed
        $kept += $result.Kept
        Write-SnakeOptimizerKeyValue -Label $target.Label -Value "$($result.Removed) itens apagados$(if ($result.Kept) { ", $($result.Kept) em uso" })" -LabelWidth 38
    }

    return [PSCustomObject]@{ Found = $found; Removed = $total; Kept = $kept }
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

    # Do mais leve ao mais pesado. Nenhuma opção daqui apaga perfis do Outlook nem documentos; a remoção completa é outra
    # ação (Remover o Office por completo).
    $c2r = ($office.Kind -eq "ClickToRun")
    $options = @()

    if ($c2r) {
        $options += @{ Key = "1"; Label = "Atualizar o Office"; Description = "Baixa e instala a versão mais nova. Não fecha nada: o Office atualiza quando for fechado."; Accent = $true }
    }

    $options += @{ Key = "2"; Label = "Limpar cache do Office"; Description = "Travamentos ao abrir, suplementos com erro, Centro de Carregamento com falha. Rápido."; Accent = (-not $c2r) }

    if ($c2r) {
        $options += @{ Key = "3"; Label = "Office com problema ou não atualiza"; Description = "Fecha o Office, limpa o cache, reinicia o serviço do Office e força a atualização." }
    }

    $options += @{ Key = "4"; Label = "Redefinir login e ativação"; Description = "Produto não licenciado, conta errada, loop de login. Pede o login de novo no próximo uso." }

    if ($c2r) {
        $options += @{ Key = "5"; Label = "Reparo rápido"; Description = "Conserta arquivos do Office sem internet. Leva poucos minutos." }
        $options += @{ Key = "6"; Label = "Reparo online"; Description = "Reinstala o Office pela internet: resolve quase tudo. Leva de 15 a 40 minutos." }
    }
    else {
        Write-SnakeOptimizerStatus -Type Info -Message "Office instalado por MSI (versão antiga): atualização e reparo ficam em Programas e Recursos > Office > Alterar > Reparar."
    }

    $options += @{ Key = "7"; Label = "Limpar cache do Teams"; Description = "Teams travado, tela branca, sem notificações. Conversas e arquivos não são afetados." }
    $options += @{ Key = "X"; Label = "Cancelar"; Exit = $true }

    $answer = Read-SnakeOptimizerChoice -Message "O que fazer no Office?" -Options $options -DefaultKey "X" -ShowMenu `
        -TextPrompt "Opção (número, X = cancelar; ENTER = cancelar)"

    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "X" -or $answer -eq "0") {
        Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "cancelado pelo usuário" -PassThru:$PassThru
        return
    }

    # Cache e login ficam no perfil do usuário.
    if ($answer -in "2", "3", "4", "7" -and -not (Test-SnakeOptimizerToolUserContext)) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "elevado com outra conta" -PassThru:$PassThru
        return
    }

    # Atualizar não fecha nada (o Office termina de atualizar quando a pessoa fecha); o cache do Teams fecha só o Teams.
    if ($answer -notin "1", "7" -and -not (Close-SnakeOptimizerOfficeApps)) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Os programas do Office continuam abertos; nada foi alterado."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "Office aberto" -PassThru:$PassThru
        return
    }

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title

    try {
        switch ($answer) {
            "1" {
                Write-SnakeOptimizerSection -Title "Atualizando o Office"
                Start-SnakeOptimizerOfficeUpdate -ForceAppShutdown:$false
                Write-SnakeOptimizerStatus -Type Success -Message "Atualização iniciada: o Office mostra o andamento. Se algum programa do Office estiver aberto, ele pede para fechar no fim."
                $final = New-SnakeOptimizerResult -Kind Ok -Detail "atualização iniciada" -Title $title
            }
            "3" {
                Write-SnakeOptimizerSection -Title "Limpando o cache do Office"
                $cache = Clear-SnakeOptimizerOfficeCache

                Write-SnakeOptimizerSection -Title "Reiniciando o serviço do Office"
                $service = Get-Service -Name "ClickToRunSvc" -ErrorAction SilentlyContinue

                if ($null -eq $service) {
                    Write-SnakeOptimizerStatus -Type Warning -Message "O serviço Clique para Executar não existe: a instalação está quebrada. Use o Reparo online ou Remover o Office por completo."
                    $final = New-SnakeOptimizerResult -Kind Warning -Detail "serviço ClickToRunSvc ausente" -Title $title
                    break
                }

                if ($service.StartType -eq "Disabled") {
                    Set-Service -Name "ClickToRunSvc" -StartupType Automatic -ErrorAction Stop
                    Write-SnakeOptimizerStatus -Type Info -Message "O serviço do Office estava desativado (isso impede as atualizações); foi religado."
                }

                Restart-Service -Name "ClickToRunSvc" -Force -ErrorAction Stop
                Write-SnakeOptimizerStatus -Type Success -Message "Serviço do Office reiniciado (cache: $($cache.Removed) itens apagados)."

                Write-SnakeOptimizerSection -Title "Forçando a atualização"
                Start-SnakeOptimizerOfficeUpdate -ForceAppShutdown:$true
                Write-SnakeOptimizerStatus -Type Success -Message "Atualização iniciada. Se ela falhar de novo, use o Reparo online; se nem ele resolver, Remover o Office por completo (os perfis do Outlook são mantidos)."
                $final = New-SnakeOptimizerResult -Kind Ok -Detail "cache limpo, serviço reiniciado, atualização iniciada" -Title $title
            }
            "2" {
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
            "4" {
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
            "7" {
                Write-SnakeOptimizerSection -Title "Limpando o cache do Teams"
                $teams = Clear-SnakeOptimizerTeamsCache

                if ($null -eq $teams) {
                    Write-SnakeOptimizerStatus -Type Warning -Message "O Teams continua aberto; nada foi alterado."
                    $final = New-SnakeOptimizerResult -Kind Skipped -Detail "Teams aberto" -Title $title
                }
                elseif (-not $teams.Found) {
                    Write-SnakeOptimizerStatus -Type Info -Message "Nenhum cache do Teams foi encontrado para este usuário."
                    $final = New-SnakeOptimizerResult -Kind Skipped -Detail "Teams não encontrado" -Title $title
                }
                elseif ($teams.Kept -gt 0) {
                    Write-SnakeOptimizerStatus -Type Warning -Message "Cache do Teams limpo em parte: $($teams.Removed) itens apagados, $($teams.Kept) em uso."
                    $final = New-SnakeOptimizerResult -Kind Warning -Detail "$($teams.Kept) itens em uso" -Title $title
                }
                else {
                    Write-SnakeOptimizerStatus -Type Success -Message "Cache do Teams limpo ($($teams.Removed) itens). Abra o Teams de novo; o primeiro carregamento demora um pouco mais."
                }
            }
            { $_ -in "5", "6" } {
                $repairType = $(if ($answer -eq "5") { "QuickRepair" } else { "FullRepair" })
                $label = $(if ($answer -eq "5") { "Reparo rápido" } else { "Reparo online" })

                if ($answer -eq "6") {
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
# Remoção completa do Office (para reinstalar do zero)
# ---------------------------------------------------------------------------

function Remove-SnakeOptimizerOfficeUserSettings {
    # Limpa as configurações do Office do usuário (login, licença, caches, opções) MAS mantém o que dá trabalho refazer:
    # perfis e contas do Outlook (chaves "Outlook"), assinaturas padrão (Common\MailSettings) e a faixa de opções
    # personalizada (*.officeUI). O que impede reinstalar o Office fica em HKLM e nos serviços, não aqui.
    param (
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Done,
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Failed
    )

    $walk = {
        param ($Path, $Relative)

        foreach ($child in @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue)) {
            $rel = $(if ($Relative) { "$Relative\$($child.PSChildName)" } else { $child.PSChildName })

            # Mantidos inteiros.
            if ($rel -match '^(\d+\.\d+\\)?Outlook$' -or $rel -match '^\d+\.\d+\\Common\\MailSettings$') { continue }

            # Contêm algo mantido: desce e limpa o resto.
            if ($rel -match '^\d+\.\d+$' -or $rel -match '^\d+\.\d+\\Common$') { & $walk $child.PSPath $rel; continue }

            try { Remove-Item -LiteralPath $child.PSPath -Recurse -Force -ErrorAction Stop; $Done.Add("HKCU\...\Office\$rel") }
            catch { $Failed.Add("HKCU\...\Office\$rel") }
        }
    }

    $root = "HKCU:\Software\Microsoft\Office"
    if (Test-Path -LiteralPath $root) { & $walk $root "" }

    $local = Join-Path $env:LOCALAPPDATA "Microsoft\Office"
    foreach ($item in @(Get-ChildItem -LiteralPath $local -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.officeUI" })) {
        try { Remove-SnakeOptimizerItem -Path $item.FullName; $Done.Add($item.FullName) } catch { $Failed.Add("$($item.FullName) ($($_.Exception.Message))") }
    }
}


function Get-SnakeOptimizerOutlookDataFiles {
    # Arquivos de dados do Outlook (.pst/.ost) nos lugares de costume. Só lista: nunca são apagados.
    $places = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\Outlook"),
        (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Arquivos do Outlook"),
        (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Outlook Files")
    )

    foreach ($place in $places) {
        Get-ChildItem -LiteralPath $place -Include *.pst, *.ost -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { [PSCustomObject]@{ Path = $_.FullName; SizeMB = [math]::Round($_.Length / 1MB, 1) } }
    }
}


function Get-SnakeOptimizerOfficeBackupItems {
    # O que vai para o backup das personalizações: chaves de registro e pastas, com o destino de volta na restauração.
    [PSCustomObject]@{
        Registry = @(
            [PSCustomObject]@{ Key = "HKCU\Software\Microsoft\Office\16.0\Outlook"; File = "outlook-16.0.reg" },
            [PSCustomObject]@{ Key = "HKCU\Software\Microsoft\Office\15.0\Outlook"; File = "outlook-15.0.reg" },
            [PSCustomObject]@{ Key = "HKCU\Software\Microsoft\Office\Outlook"; File = "outlook-geral.reg" },
            [PSCustomObject]@{ Key = "HKCU\Software\Microsoft\Office\16.0\Common\MailSettings"; File = "assinatura-padrao.reg" }
        )
        Folders = @(
            [PSCustomObject]@{ Name = "Assinaturas"; Path = (Join-Path $env:APPDATA "Microsoft\Signatures"); Filter = "*" },
            [PSCustomObject]@{ Name = "Modelos"; Path = (Join-Path $env:APPDATA "Microsoft\Templates"); Filter = "*" },
            [PSCustomObject]@{ Name = "Dicionario"; Path = (Join-Path $env:APPDATA "Microsoft\UProof"); Filter = "*" },
            [PSCustomObject]@{ Name = "Regras e formularios"; Path = (Join-Path $env:APPDATA "Microsoft\Outlook"); Filter = "*" },
            [PSCustomObject]@{ Name = "Autocompletar"; Path = (Join-Path $env:LOCALAPPDATA "Microsoft\Outlook\RoamCache"); Filter = "Stream_Autocomplete*" },
            [PSCustomObject]@{ Name = "Faixa de opcoes"; Path = (Join-Path $env:LOCALAPPDATA "Microsoft\Office"); Filter = "*.officeUI" }
        )
    }
}


function Backup-SnakeOptimizerOfficeProfile {
    # Guarda, na pasta de dados do próprio usuário (só ele e os administradores leem), tudo o que dá trabalho refazer:
    # perfis do Outlook, assinaturas, modelos, dicionário, regras, autocompletar e faixa de opções. Os .pst/.ost não são
    # copiados (podem ter dezenas de GB e não são apagados); ficam listados no manifesto. Devolve a pasta do backup.
    param ([switch]$IncludeUser)

    $root = Join-Path (Get-SnakeOptimizerDataPath) "backups"
    $backup = Join-Path $root ("office-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null

    # Guarda só os 5 mais recentes.
    Get-ChildItem -LiteralPath $root -Directory -Filter "office-*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
        Select-Object -Skip 5 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $manifest = [ordered]@{
        Computer = $env:COMPUTERNAME
        User     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Sid      = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Date     = (Get-Date).ToString("s")
        Products = (Get-SnakeOptimizerOfficeInstall).Products
        IncludesUser = [bool]$IncludeUser
    }

    if ($IncludeUser) {
        $items = Get-SnakeOptimizerOfficeBackupItems

        # Registro completo do usuário (para consulta) e, separado, só o que a restauração importa.
        & reg.exe export "HKCU\Software\Microsoft\Office" (Join-Path $backup "hkcu-office-completo.reg") /y *> $null
        foreach ($entry in $items.Registry) {
            if (Test-Path -LiteralPath "Registry::$($entry.Key)") { & reg.exe export $entry.Key (Join-Path $backup $entry.File) /y *> $null }
        }

        foreach ($folder in $items.Folders) {
            if (-not (Test-Path -LiteralPath $folder.Path)) { continue }
            $target = Join-Path $backup "arquivos\$($folder.Name)"

            # Arquivos até 50 MB (o que passa disso nesta lista não é personalização). LiveContent são temas e modelos que a
            # Microsoft baixa de novo sozinha.
            foreach ($file in @(Get-ChildItem -LiteralPath $folder.Path -Filter $folder.Filter -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -le 50MB -and $_.Extension -notin ".pst", ".ost" -and $_.FullName -notlike "*\LiveContent\*" })) {
                $dest = Join-Path $target $file.FullName.Substring($folder.Path.Length).TrimStart('\')
                New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
            }
        }

        $outlook = "HKCU:\Software\Microsoft\Office\16.0\Outlook"
        $manifest.DefaultProfile = (Get-ItemProperty -LiteralPath $outlook -Name DefaultProfile -ErrorAction SilentlyContinue).DefaultProfile
        $manifest.Profiles = @(Get-ChildItem -LiteralPath "$outlook\Profiles" -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
        $manifest.DataFiles = @(Get-SnakeOptimizerOutlookDataFiles)
    }

    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backup "manifest.json") -Encoding UTF8
    return $backup
}


function Remove-SnakeOptimizerOfficeEverything {
    # Faz a remoção em si. Devolve a lista do que saiu e do que falhou. -IncludeUser: também o perfil do usuário (HKCU e
    # AppData), só quando o SnakeOptimizer roda com a conta de quem usa o PC.
    param ([switch]$IncludeUser)

    $done = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    # 1. Processos do Office e do Clique para Executar.
    Write-Progress -Activity "Removendo o Office" -Status "encerrando os processos"
    $processes = "OfficeClickToRun", "OfficeC2RClient", "integratord", "AppVShNotify", "firstrun", "WINWORD", "EXCEL", "POWERPNT", "OUTLOOK",
        "ONENOTE", "MSACCESS", "MSPUB", "VISIO", "WINPROJ", "lync", "osppsvc"
    Get-Process -Name $processes -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # O setup.exe só quando for o do Office (outro instalador aberto não é encerrado).
    Get-Process -Name "setup" -ErrorAction SilentlyContinue | Where-Object { $_.Path -match '(?i)Microsoft Office|ClickToRun' } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # 2. Serviços (o script original tinha "osppsvcose", dois nomes colados: nenhum dos dois era removido).
    Write-Progress -Activity "Removendo o Office" -Status "removendo os serviços"
    foreach ($name in "ClickToRunSvc", "OfficeSvc", "osppsvc", "ose", "ose64") {
        if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { continue }
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $name *> $null
        if ($LASTEXITCODE -eq 0) { $done.Add("serviço $name") } else { $failed.Add("serviço $name") }
    }

    # 3. Tarefas agendadas: só as da pasta do Office da Microsoft (o original apagava qualquer tarefa com "Office" no nome).
    Write-Progress -Activity "Removendo o Office" -Status "removendo as tarefas agendadas"
    foreach ($task in @(Get-ScheduledTask -TaskPath "\Microsoft\Office\*" -ErrorAction SilentlyContinue)) {
        try { Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop; $done.Add("tarefa $($task.TaskPath)$($task.TaskName)") }
        catch { $failed.Add("tarefa $($task.TaskName)") }
    }

    # 4. Pastas e atalhos.
    $folders = @(
        "$env:ProgramFiles\Microsoft Office", "${env:ProgramFiles(x86)}\Microsoft Office",
        "$env:ProgramFiles\Microsoft Office 15", "${env:ProgramFiles(x86)}\Microsoft Office 15",
        "$env:ProgramFiles\Microsoft Office 16", "${env:ProgramFiles(x86)}\Microsoft Office 16",
        "$env:CommonProgramFiles\Microsoft Shared\ClickToRun", "${env:CommonProgramFiles(x86)}\Microsoft Shared\ClickToRun",
        "$env:CommonProgramFiles\Microsoft Shared\Office16", "${env:CommonProgramFiles(x86)}\Microsoft Shared\Office16",
        "$env:CommonProgramFiles\Microsoft Shared\OfficeSoftwareProtectionPlatform",
        "$env:ProgramData\Microsoft\ClickToRun", "$env:ProgramData\Microsoft\Office",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Office Tools"
    )
    $startMenu = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
    $shortcuts = @(Get-ChildItem -LiteralPath "$env:PUBLIC\Desktop", $startMenu -Filter *.lnk -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^(Word|Excel|PowerPoint|Outlook|OneNote|Access|Publisher|Project|Visio|Skype for Business)( \d+)?$' })

    foreach ($path in @($folders) + @($shortcuts | ForEach-Object { $_.FullName })) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { continue }
        Write-Progress -Activity "Removendo o Office" -Status "apagando $path"
        try { Remove-SnakeOptimizerItem -Path $path; $done.Add($path) } catch { $failed.Add("$path ($($_.Exception.Message))") }
    }

    # 5. Registro.
    Write-Progress -Activity "Removendo o Office" -Status "limpando o registro"
    # Em HKLM\...\Office ficam também os suplementos de OUTROS programas (Teams no Outlook, Adobe Acrobat, antivírus):
    # Office\<Outlook|Excel|Word|...>\Addins. Esses ficam, para continuarem funcionando no Office novo; o resto sai.
    # Uma parte que o Windows não deixa apagar (permissão) não impede a reinstalação: vira "sobra", sem pedir reinício.
    $leftover = New-Object System.Collections.Generic.List[string]
    foreach ($key in "HKLM:\SOFTWARE\Microsoft\Office", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office") {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $removedHere = 0
        foreach ($child in @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
            $targets = @($child.PSPath)
            if (@(Get-ChildItem -LiteralPath $child.PSPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "Addins" }).Count -gt 0) {
                # O aplicativo tem suplementos: só o que não é Addins sai.
                $targets = @(Get-ChildItem -LiteralPath $child.PSPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -ne "Addins" } | ForEach-Object { $_.PSPath })
            }
            foreach ($target in $targets) {
                try { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop; $removedHere++ }
                catch { $leftover.Add((Convert-Path -LiteralPath $target -ErrorAction SilentlyContinue)) }
            }
        }
        if ($removedHere -gt 0) { $done.Add("$key (sem os suplementos de outros programas)") }
    }

    foreach ($key in "HKLM:\SOFTWARE\Microsoft\AppVISV", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\AppVISV", "HKLM:\SYSTEM\CurrentControlSet\Services\ClickToRunSvc") {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        try { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop; $done.Add($key) } catch { $leftover.Add($key) }
    }

    if ($IncludeUser) {
        Write-Progress -Activity "Removendo o Office" -Status "limpando as configurações do usuário (o Outlook fica)"
        Remove-SnakeOptimizerOfficeUserSettings -Done $done -Failed $failed
    }

    # Entradas de "Programas e Recursos": só as da Microsoft (o original pegava qualquer programa com "Project" ou "Visio").
    $officeName = '^Microsoft (Office|365|Visio|Project|OneNote)\b'
    $uninstall = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    foreach ($entry in @(Get-ItemProperty -Path $uninstall -ErrorAction SilentlyContinue | Where-Object { [string]$_.DisplayName -match $officeName -or $_.PSChildName -match '0FF1CE' })) {
        try { Remove-Item -LiteralPath $entry.PSPath -Recurse -Force -ErrorAction Stop; $done.Add("desinstalação: $($entry.DisplayName)") } catch { $failed.Add("desinstalação: $($entry.DisplayName)") }
    }

    foreach ($entry in @(Get-ItemProperty -Path "HKLM:\SOFTWARE\Classes\Installer\Products\*" -ErrorAction SilentlyContinue | Where-Object { [string]$_.ProductName -match $officeName })) {
        try { Remove-Item -LiteralPath $entry.PSPath -Recurse -Force -ErrorAction Stop; $done.Add("instalador: $($entry.ProductName)") } catch { $failed.Add("instalador: $($entry.ProductName)") }
    }

    Write-Progress -Activity "Removendo o Office" -Completed
    return [PSCustomObject]@{ Done = $done; Failed = $failed; Leftover = $leftover }
}


function Invoke-SnakeOptimizerOfficeRemoval {
    param ([switch]$PassThru)

    $title = "Remover o Office por completo"
    Enter-SnakeOptimizerAction -Title $title

    if (-not (Test-SnakeOptimizerElevation -Reason "Remover o Office exige privilégios de Administrador.")) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Failed -Detail "sem privilégios de Administrador" -PassThru:$PassThru
        return
    }

    $office = Get-SnakeOptimizerOfficeInstall
    Write-SnakeOptimizerSection -Title "Office encontrado"
    Write-SnakeOptimizerKeyValue -Label "Produtos" -Value $(if ($office.Products) { $office.Products } else { "nenhum registrado (pode haver restos de uma instalação quebrada)" }) -LabelWidth 18

    # As configurações do usuário só são limpas com a conta dele: elevado com outra conta, sairiam as do administrador.
    $includeUser = -not (Test-SnakeOptimizerUserContextMismatch)
    if (-not $includeUser) {
        Write-SnakeOptimizerStatus -Type Warning -Notice -Message "Elevado com outra conta: as configurações do Office do usuário logado não serão limpas, só a instalação."
    }

    Write-SnakeOptimizerSection -Title "O que será feito"
    Write-SnakeOptimizerStatus -Type Warning -Notice -Message "O Office será APAGADO deste PC (programas, serviços, tarefas, registro e atalhos). Use quando o Office está quebrado e o reparo online não resolveu, ou antes de instalar outra versão."
    if ($includeUser) {
        Write-SnakeOptimizerStatus -Type Info -Notice -Message "Ficam: perfis e contas do Outlook, assinaturas, modelos, dicionário, regras, faixa de opções, arquivos .pst/.ost e documentos. Saem: login, licença, caches e opções do Office deste usuário."
        Write-SnakeOptimizerStatus -Type Info -Notice -Message "Antes de remover, um backup dessas personalizações é salvo. Se algo faltar depois, use Restaurar backup do Office."
    }
    Write-SnakeOptimizerStatus -Type Info -Notice -Message "Tenha em mãos a conta Microsoft ou a chave do Office para reinstalar. Ao terminar, reinicie o PC antes de instalar de novo."

    if (-not (Confirm-SnakeOptimizerAction "Remover o Office por completo?" -DefaultKey N)) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "cancelado pelo usuário" -PassThru:$PassThru
        return
    }

    if (-not (Confirm-SnakeOptimizerAction "Confirma? Não dá para desfazer: o Office terá de ser instalado de novo." -DefaultKey N -YesLabel "Sim, remover o Office" -NoLabel "Cancelar")) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "cancelado pelo usuário" -PassThru:$PassThru
        return
    }

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title -Data @{ RebootRequired = $true }

    try {
        Write-SnakeOptimizerSection -Title "Backup"
        $backup = Backup-SnakeOptimizerOfficeProfile -IncludeUser:$includeUser
        Write-SnakeOptimizerKeyValue -Label "Backup salvo em" -Value $backup -LabelWidth 22

        Write-SnakeOptimizerSection -Title "Removendo"
        $result = Remove-SnakeOptimizerOfficeEverything -IncludeUser:$includeUser

        foreach ($item in $result.Done) { Write-SnakeOptimizerCommand -Command "removido: $item" }

        Write-Host ""
        # Sobras no registro (o Windows não deixou apagar): não atrapalham a reinstalação nem pedem reinício.
        if (@($result.Leftover).Count -gt 0) {
            Write-SnakeOptimizerStatus -Type Info -Notice -Message "Ficou no registro, sem efeito na reinstalação (o Windows não deixou apagar): $(@($result.Leftover) -join '; ')."
        }

        if ($result.Failed.Count -gt 0) {
            Write-SnakeOptimizerStatus -Type Warning -Message "$($result.Done.Count) itens removidos; $($result.Failed.Count) não saíram (em uso ou sem permissão): $($result.Failed -join '; '). Reinicie o PC e rode de novo para terminar."
            $final = New-SnakeOptimizerResult -Kind Warning -Detail "$($result.Failed.Count) itens não removidos" -Title $title -Data @{ RebootRequired = $true }
        }
        elseif ($result.Done.Count -eq 0 -and @($result.Leftover).Count -gt 0) {
            Write-SnakeOptimizerStatus -Type Success -Message "O Office já não está no PC; só ficaram as sobras de registro acima, que não atrapalham. Pode instalar o Office de novo."
            $final = New-SnakeOptimizerResult -Kind Ok -Detail "Office já removido; pode instalar de novo" -Title $title
        }
        elseif ($result.Done.Count -eq 0) {
            Write-SnakeOptimizerStatus -Type Info -Message "Não havia nada do Office para remover."
            $final = New-SnakeOptimizerResult -Kind Skipped -Detail "nada para remover" -Title $title
        }
        else {
            Write-SnakeOptimizerStatus -Type Success -Message "Office removido ($($result.Done.Count) itens). Reinicie o PC antes de instalar o Office de novo."
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "A remoção falhou: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


function Invoke-SnakeOptimizerOfficeRestore {
    # Devolve as personalizações de um backup feito pela remoção do Office. Nada é sobrescrito: só volta o que falta, e os
    # perfis do Outlook só são importados se não existirem (ou se a pessoa pedir para mesclar).
    param ([switch]$PassThru)

    $title = "Restaurar backup do Office"
    Enter-SnakeOptimizerAction -Title $title

    if (-not (Test-SnakeOptimizerToolUserContext)) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "elevado com outra conta" -PassThru:$PassThru
        return
    }

    $backups = @(Get-ChildItem -LiteralPath (Join-Path (Get-SnakeOptimizerDataPath) "backups") -Directory -Filter "office-*" -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "manifest.json") } | Sort-Object Name -Descending | Select-Object -First 9)

    if ($backups.Count -eq 0) {
        Write-SnakeOptimizerStatus -Type Info -Message "Nenhum backup do Office encontrado para este usuário. O backup é criado por Remover o Office por completo."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "nenhum backup" -PassThru:$PassThru
        return
    }

    $options = @()
    $index = 0
    foreach ($backup in $backups) {
        $index++
        $info = Get-Content -LiteralPath (Join-Path $backup.FullName "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $profiles = $(if ($info.Profiles) { "perfis: $(@($info.Profiles) -join ', ')" } else { "sem perfis do Outlook" })
        $options += @{ Key = "$index"; Label = ([datetime]$info.Date).ToString("dd/MM/yyyy HH:mm"); Description = "$($info.Products) | $profiles"; Accent = ($index -eq 1) }
    }
    $options += @{ Key = "X"; Label = "Cancelar"; Exit = $true }

    $answer = Read-SnakeOptimizerChoice -Message "Qual backup restaurar?" -Options $options -DefaultKey "1" -ShowMenu -TextPrompt "Opção (número, X = cancelar; ENTER = o mais recente)"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "1" }
    if ($answer -eq "X") {
        Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "cancelado pelo usuário" -PassThru:$PassThru
        return
    }

    $source = $backups[[int]$answer - 1].FullName
    $manifest = Get-Content -LiteralPath (Join-Path $source "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($manifest.Sid -and $manifest.Sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        Write-SnakeOptimizerStatus -Type Error -Message "Este backup é de outra conta ($($manifest.User)). Restaure logado com ela."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "backup de outra conta" -PassThru:$PassThru
        return
    }

    if (-not $manifest.IncludesUser) {
        Write-SnakeOptimizerStatus -Type Info -Message "Este backup só tem o registro da máquina (foi feito elevado com outra conta): não há personalizações para restaurar."
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "backup sem dados do usuário" -PassThru:$PassThru
        return
    }

    if (-not (Close-SnakeOptimizerOfficeApps)) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Skipped -Detail "Office continua aberto" -PassThru:$PassThru
        return
    }

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title
    $restored = 0
    $kept = 0

    try {
        # 1. Perfis do Outlook: reg import mescla (não apaga nada do que existe).
        Write-SnakeOptimizerSection -Title "Perfis do Outlook"
        $items = Get-SnakeOptimizerOfficeBackupItems
        $current = @(Get-ChildItem -LiteralPath "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles" -ErrorAction SilentlyContinue)
        $import = ($current.Count -eq 0)

        if (-not $import) {
            Write-SnakeOptimizerStatus -Type Info -Message "Este usuário já tem perfis do Outlook: $(($current | ForEach-Object { $_.PSChildName }) -join ', ')."
            $import = Confirm-SnakeOptimizerAction "Mesclar com os perfis do backup? (nada é apagado, mas contas iguais são substituídas pelas do backup)" -DefaultKey N
        }

        if ($import) {
            foreach ($entry in $items.Registry) {
                $file = Join-Path $source $entry.File
                if (-not (Test-Path -LiteralPath $file)) { continue }
                Invoke-SnakeOptimizerNative -FilePath "reg.exe" -Arguments @("import", $file)
                Write-SnakeOptimizerCommand -Command "importado: $($entry.Key)"
            }
            Write-SnakeOptimizerStatus -Type Success -Message "Perfis do Outlook importados$(if ($manifest.DefaultProfile) { " (padrão: $($manifest.DefaultProfile))" })."
        }
        else {
            Write-SnakeOptimizerStatus -Type Info -Message "Perfis atuais mantidos."
        }

        # 2. Arquivos: só os que faltam.
        Write-SnakeOptimizerSection -Title "Personalizações"
        foreach ($folder in $items.Folders) {
            $from = Join-Path $source "arquivos\$($folder.Name)"
            if (-not (Test-Path -LiteralPath $from)) { continue }

            $count = 0
            foreach ($file in @(Get-ChildItem -LiteralPath $from -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                $dest = Join-Path $folder.Path $file.FullName.Substring($from.Length).TrimStart('\')
                if (Test-Path -LiteralPath $dest) { $kept++; continue }
                New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $dest -ErrorAction Stop
                $count++
            }

            $restored += $count
            Write-SnakeOptimizerKeyValue -Label $folder.Name -Value $(if ($count) { "$count arquivos devolvidos" } else { "já estava tudo lá" }) -LabelWidth 22
        }

        # 3. Arquivos de dados: só confere se continuam no lugar (nunca foram apagados nem copiados).
        $dataFiles = @($manifest.DataFiles | Where-Object { $_ })
        if ($dataFiles.Count -gt 0) {
            Write-SnakeOptimizerSection -Title "Arquivos de dados do Outlook"
            $missing = 0
            foreach ($data in $dataFiles) {
                $exists = Test-Path -LiteralPath $data.Path
                if (-not $exists) { $missing++ }
                Write-SnakeOptimizerKeyValue -Label $(if ($exists) { "ok" } else { "SUMIU" }) -Value "$($data.Path) ($($data.SizeMB) MB)" -LabelWidth 8
            }
            if ($missing -gt 0) { Write-SnakeOptimizerStatus -Type Warning -Message "$missing arquivo(s) de dados não estão mais no lugar: o Outlook vai pedir para localizá-los ou recriar." }
        }

        Write-Host ""
        Write-SnakeOptimizerStatus -Type Success -Message "Restauração concluída: $restored arquivos devolvidos, $kept já existiam (mantidos). Abra o Outlook para conferir."
        $final = New-SnakeOptimizerResult -Kind Ok -Detail "$restored arquivos devolvidos$(if ($import) { ', perfis importados' })" -Title $title
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "A restauração falhou: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


# ---------------------------------------------------------------------------
# Fila de impressão
# ---------------------------------------------------------------------------

function Invoke-SnakeOptimizerPrintSpoolerReset {
    # -Unattended: sem a pergunta (modo silencioso do RMM).
    param ([switch]$PassThru, [switch]$Unattended)

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

    if (-not $Unattended -and -not (Confirm-SnakeOptimizerAction "Destravar a fila de impressão agora?" -DefaultKey S)) {
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


# ---------------------------------------------------------------------------
# DNS (rápido, sem derrubar a conexão)
# ---------------------------------------------------------------------------

function Invoke-SnakeOptimizerDnsFlush {
    # Só limpa os caches de nomes e endereços: não libera o IP nem reseta o Winsock, então não derruba a conexão (nem o
    # agente do RMM). Para o reparo completo, use Reparar rede e DNS.
    param ([switch]$PassThru)

    $title = "Limpar cache de DNS e ARP"
    Enter-SnakeOptimizerAction -Title $title

    if (-not (Test-SnakeOptimizerElevation -Reason "Limpar o cache ARP exige privilégios de Administrador.")) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Failed -Detail "sem privilégios de Administrador" -PassThru:$PassThru
        return
    }

    $steps = @(
        (Invoke-SnakeOptimizerNetworkCommand -Title "Limpar cache DNS" -FilePath "ipconfig.exe" -Arguments @("/flushdns")),
        (Invoke-SnakeOptimizerNetworkCommand -Title "Limpar cache ARP" -FilePath "netsh.exe" -Arguments @("interface", "ip", "delete", "arpcache")),
        (Invoke-SnakeOptimizerNetworkCommand -Title "Registrar o PC no DNS" -FilePath "ipconfig.exe" -Arguments @("/registerdns"))
    )
    Write-Progress -Activity "Reparando a rede" -Completed

    $failed = @($steps | Where-Object { $_.Kind -eq "Failed" })
    $final = $(if ($failed.Count -eq 0) { New-SnakeOptimizerResult -Kind Ok -Title $title } else { New-SnakeOptimizerResult -Kind Warning -Detail "$($failed.Count) comando(s) falharam" -Title $title })

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


# ---------------------------------------------------------------------------
# Modo silencioso (RMM)
# ---------------------------------------------------------------------------

# Só entram aqui ações que rodam inteiras sem perguntar nada e que são seguras sem ninguém olhando. A ordem da lista é a
# ordem recomendada quando várias são pedidas juntas.
$script:SnakeOptimizerUnattendedTasks = [ordered]@{
    "ponto-restauracao" = @{ Label = "Criar ponto de restauração"; Command = "Invoke-SnakeOptimizerRestorePoint"; Arguments = @{ Embedded = $true } }
    "limpeza-rapida"    = @{ Label = "Limpeza rápida (temporários e caches; não esvazia a Lixeira)"; Command = "Invoke-SnakeOptimizerQuickCleanup"; Arguments = @{ Embedded = $true; SkipRecycleBin = $true } }
    "limpeza-avancada"  = @{ Label = "Limpeza avançada segura (logs do Windows, instaladores de drivers dos fabricantes e lixeiras de contas que não existem mais)"; Command = "Invoke-SnakeOptimizerAdvancedCleanup"; Arguments = @{ Embedded = $true; Unattended = $true } }
    "winsxs"            = @{ Label = "Limpar componentes do Windows (WinSxS)"; Command = "Invoke-SnakeOptimizerComponentCleanup"; Arguments = @{ Embedded = $true } }
    "dism"              = @{ Label = "DISM: verificar e restaurar a imagem do Windows"; Command = "Invoke-SnakeOptimizerDism"; Arguments = @{ Embedded = $true } }
    "sfc"               = @{ Label = "SFC: verificar arquivos do sistema"; Command = "Invoke-SnakeOptimizerSfc"; Arguments = @{ Embedded = $true } }
    "dism-sfc"          = @{ Label = "Reparar o Windows (DISM + SFC)"; Command = "Invoke-SnakeOptimizerDismAndSfc"; Arguments = @{ Embedded = $true } }
    "atualizacoes"      = @{ Label = "Instalar as atualizações do Windows (sem prévias, versão nova nem drivers opcionais; não reinicia)"; Command = "Install-SnakeOptimizerPendingUpdates"; Arguments = @{ Embedded = $true; NoOptionalDrivers = $true } }
    "fila-impressao"    = @{ Label = "Destravar a fila de impressão"; Command = "Invoke-SnakeOptimizerPrintSpoolerReset"; Arguments = @{ Unattended = $true } }
    "hora"              = @{ Label = "Acertar data e hora"; Command = "Invoke-SnakeOptimizerTimeSync"; Arguments = @{} }
    "dns"               = @{ Label = "Limpar cache de DNS e ARP (não derruba a conexão)"; Command = "Invoke-SnakeOptimizerDnsFlush"; Arguments = @{} }
    "rede"              = @{ Label = "Reparo completo de rede (derruba a conexão por instantes; pede reiniciar)"; Command = "Invoke-SnakeOptimizerNetworkRepair"; Arguments = @{ Embedded = $true; Force = $true } }
    "discos"            = @{ Label = "Inventário de discos: % usado de cada unidade, modelo, serial, saúde e SMART (salva .txt em %ProgramData%\SnakeOptimizer\reports)"; Command = "Invoke-SnakeOptimizerUnattendedDiskInventory"; Arguments = @{} }
    "verificar"         = @{ Label = "Verificar o PC e salvar o relatório (em %ProgramData%\SnakeOptimizer\reports)"; Command = "Invoke-SnakeOptimizerUnattendedReport"; Arguments = @{} }
}

# Onde o modo silencioso deixa o histórico e os relatórios: %ProgramData%, que a manutenção automática (SYSTEM), o RMM e
# a janela (Administrador) enxergam igual. O launcher tranca a pasta para só Administradores alterarem.
$script:SnakeOptimizerAutoRoot = Join-Path $env:ProgramData "SnakeOptimizer"
$script:SnakeOptimizerAutoHistoryMax = 60

# Os dois roteiros da manutenção automática. Leve: o de todo dia, rápido e sem nada que derrube a conexão. Completo: o
# semanal, com ponto de restauração antes e os reparos do Windows.
$script:SnakeOptimizerAutoPlans = [ordered]@{
    leve     = @{ Name = "Manutencao-Diaria"; Label = "leve"; Tasks = "limpeza-rapida,dns,atualizacoes,verificar" }
    completa = @{ Name = "Manutencao-Semanal"; Label = "completa"; Tasks = "ponto-restauracao,limpeza-rapida,limpeza-avancada,winsxs,dism-sfc,atualizacoes,hora,dns,discos,verificar" }
}
$script:SnakeOptimizerAutoTaskPath = "\SnakeOptimizer\"


function Invoke-SnakeOptimizerUnattendedReport {
    # Tarefa "verificar": o relatório completo (o mesmo de Relatórios), salvo onde a janela e o técnico encontram.
    $title = "Verificar o PC"
    try {
        $report = Export-SnakeOptimizerReport -Directory (Join-Path $script:SnakeOptimizerAutoRoot "reports")
        Write-SnakeOptimizerStatus -Type Success -Message "Relatório salvo em: $($report.Html)"
        return (New-SnakeOptimizerResult -Kind Ok -Detail "relatório salvo" -Title $title -Data @{ Report = [string]$report.Html })
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível salvar o relatório: $($_.Exception.Message)"
        return (New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title)
    }
}


# ---------------------------------------------------------------------------
# Inventário completo de discos (volumes com % de uso, discos físicos, SMART e TRIM)
# ---------------------------------------------------------------------------

function Format-SnakeOptimizerUsageBar {
    # "[██████████░░░░░░░░░░]" com o uso em 20 casas.
    param ([double]$Percent, [int]$Width = 20)

    $filled = [int][Math]::Round([Math]::Max(0, [Math]::Min(100, $Percent)) / 100 * $Width)
    return "[" + ([string][char]0x2588 * $filled) + ([string][char]0x2591 * ($Width - $filled)) + "]"
}


function Get-SnakeOptimizerDiskInventory {
    <#
    Tudo dos discos numa leitura só: o computador, o TRIM, cada volume com letra (tamanho, livre, % usado, nível) e cada
    disco físico (modelo, serial, firmware, tipo, barramento, estado, partida/sistema, formato provável, contadores SMART
    e os alertas da Saúde dos discos). Os contadores fora do possível (adaptadores USB) ficam de fora, como na Saúde.
    #>
    $cim = { param ($class) try { Get-CimInstance -ClassName $class -ErrorAction Stop | Select-Object -First 1 } catch { $null } }
    $computer = & $cim "Win32_ComputerSystem"
    $bios = & $cim "Win32_BIOS"

    $trim = "não informado"
    try {
        $query = @(& fsutil.exe behavior query DisableDeleteNotify 2>$null) -join "`n"
        if ($query -match 'NTFS DisableDeleteNotify\s*=\s*0') { $trim = "ligado" }
        elseif ($query -match 'NTFS DisableDeleteNotify\s*=\s*1') { $trim = "DESLIGADO" }
    }
    catch { }

    # Partições: a letra de cada volume e o disco onde ela fica.
    $diskByLetter = @{}
    try {
        foreach ($p in @(Get-Partition -ErrorAction Stop)) {
            $l = [string]$p.DriveLetter
            if ($l -match '^[A-Za-z]$') { $diskByLetter[$l.ToUpperInvariant()] = [string]$p.DiskNumber }
        }
    }
    catch { }

    $systemLetter = ([string]$env:SystemDrive).TrimEnd(':', '\').ToUpperInvariant()
    $volumes = @()
    try {
        foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { [string]$_.DriveLetter -match '^[A-Za-z]$' -and $_.Size -gt 0 } | Sort-Object DriveLetter)) {
            $letter = ([string]$v.DriveLetter).ToUpperInvariant()
            $size = [double]$v.Size
            $free = [double]$v.SizeRemaining
            $used = [Math]::Round((($size - $free) / $size) * 100, 1)
            $volumes += [PSCustomObject]@{
                Letter     = "$($letter):"
                Label      = [string]$v.FileSystemLabel
                FileSystem = [string]$v.FileSystem
                Size       = $size
                Free       = $free
                Used       = $used
                Disk       = $(if ($diskByLetter.ContainsKey($letter)) { $diskByLetter[$letter] } else { "" })
                System     = ($letter -eq $systemLetter)
                Level      = (Get-SnakeOptimizerDiskSpaceLevel -FreeBytes $free -TotalBytes $size -System ($letter -eq $systemLetter))
            }
        }
    }
    catch { }

    $logical = @{}
    try { foreach ($d in @(Get-Disk -ErrorAction Stop)) { $logical[[string]$d.Number] = $d } } catch { }

    $disks = @()
    $physical = @()
    try { $physical = @(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    $physical = @($physical | Sort-Object @{ Expression = { $n = 0; if ([int]::TryParse([string]$_.DeviceId, [ref]$n)) { $n } else { [int]::MaxValue } } })

    foreach ($pd in $physical) {
        $number = [string]$pd.DeviceId
        $type = Get-SnakeOptimizerDiskTypeText -Disk $pd
        $bus = [string]$pd.BusType
        $counter = $null
        try { $counter = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        $field = { param ($name) if ($counter -and $counter.PSObject.Properties[$name]) { $counter.$name } else { $null } }

        $t = & $field "Temperature"
        $h = & $field "PowerOnHours"
        $w = & $field "Wear"
        $wear = $(if ($null -ne $w -and [double]$w -ge 0 -and [double]$w -le 100) { [int]$w } else { $null })
        if ($type -notin @("SSD", "NVMe") -and $wear -eq 0) { $wear = $null }
        $bytesRead = & $field "BytesRead"
        $bytesWritten = & $field "BytesWritten"

        $format = switch -Regex ($bus) {
            '^NVMe$' { "M.2 ou placa PCIe (NVMe)"; break }
            '^SATA$' { "SATA (2,5`", 3,5`" ou M.2 SATA)"; break }
            '^USB$' { "externo (USB)"; break }
            '^(RAID|SAS|SCSI)$' { "atrás de controladora $bus"; break }
            default { "não informado" }
        }

        $disk = [PSCustomObject]@{
            Number                 = $number
            Name                   = ([string]$pd.FriendlyName).Trim()
            Serial                 = ([string]$pd.SerialNumber).Trim().TrimEnd('.')
            Manufacturer           = ([string]$pd.Manufacturer).Trim()
            Firmware               = ([string]$pd.FirmwareVersion).Trim()
            Size                   = $pd.Size
            Type                   = $type
            Bus                    = $bus
            Format                 = $format
            HealthStatus           = $pd.HealthStatus
            OperationalStatus      = @(@($pd.OperationalStatus) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            Boot                   = $(if ($logical.ContainsKey($number)) { [bool]$logical[$number].IsBoot } else { $null })
            SystemDisk             = $(if ($logical.ContainsKey($number)) { [bool]$logical[$number].IsSystem } else { $null })
            Partitions             = $(if ($logical.ContainsKey($number)) { $logical[$number].NumberOfPartitions } else { $null })
            Volumes                = @($volumes | Where-Object { $_.Disk -eq $number })
            Temperature            = $(if ($null -ne $t -and [double]$t -ge 1 -and [double]$t -le 127) { [int]$t } else { $null })
            PowerOnHours           = $(if ($null -ne $h -and [double]$h -gt 0 -and [double]$h -lt 150000) { [int64]$h } else { $null })
            Wear                   = $wear
            ReadErrorsTotal        = & $field "ReadErrorsTotal"
            WriteErrorsTotal       = & $field "WriteErrorsTotal"
            ReadErrorsUncorrected  = & $field "ReadErrorsUncorrected"
            WriteErrorsUncorrected = & $field "WriteErrorsUncorrected"
            PowerCycles            = & $field "PowerCycleCount"
            StartStopCycles        = & $field "StartStopCycleCount"
            BytesRead              = $(if ($bytesRead -and [double]$bytesRead -gt 0) { $bytesRead } else { $null })
            BytesWritten           = $(if ($bytesWritten -and [double]$bytesWritten -gt 0) { $bytesWritten } else { $null })
        }
        $disk | Add-Member -NotePropertyName Notes -NotePropertyValue @(Get-SnakeOptimizerDiskHealthNotes -Disk $disk)
        $disks += $disk
    }

    return [PSCustomObject]@{
        Date         = Get-Date
        ComputerName = $env:COMPUTERNAME
        Manufacturer = $(if ($computer) { ([string]$computer.Manufacturer).Trim() } else { "" })
        Model        = $(if ($computer) { ([string]$computer.Model).Trim() } else { "" })
        BiosSerial   = $(if ($bios) { ([string]$bios.SerialNumber).Trim() } else { "" })
        Trim         = $trim
        Volumes      = @($volumes)
        Disks        = @($disks)
        TotalSize    = [double](@($disks | ForEach-Object { [double]$_.Size }) | Measure-Object -Sum).Sum
    }
}


function Get-SnakeOptimizerDiskVolumeText {
    # "56% usado · 410 GB livres de 930 GB · FURY · NTFS".
    param ([Parameter(Mandatory)]$Volume)

    $parts = @("$([Math]::Round($Volume.Used))% usado","$(Format-SnakeOptimizerBytes -Bytes $Volume.Free) livres de $(Format-SnakeOptimizerBytes -Bytes $Volume.Size)")
    if ($Volume.Label) { $parts += $Volume.Label }
    if ($Volume.FileSystem) { $parts += $Volume.FileSystem }
    return ($parts -join " · ")
}


function Get-SnakeOptimizerDiskInventoryLines {
    # O inventário em texto (para o arquivo .txt e para o RMM).
    param ([Parameter(Mandatory)]$Inventory)

    $na = { param ($v) if ($null -eq $v -or [string]$v -eq "") { "não informado" } else { [string]$v } }
    $yesNo = { param ($v) if ($null -eq $v) { "não informado" } elseif ($v) { "sim" } else { "não" } }
    $line = "=" * 64
    $out = New-Object System.Collections.Generic.List[string]
    $kv = { param ($label, $value) $out.Add(("{0,-24}: {1}" -f $label, $value)) }

    $out.Add($line); $out.Add("SNAKE TECH - INVENTÁRIO DE DISCOS (SnakeOptimizer)"); $out.Add($line)
    & $kv "Computador" $Inventory.ComputerName
    & $kv "Fabricante / modelo" "$($Inventory.Manufacturer) $($Inventory.Model)".Trim()
    & $kv "Serial da BIOS" (& $na $Inventory.BiosSerial)
    & $kv "Data" ($Inventory.Date.ToString("dd/MM/yyyy HH:mm:ss"))
    & $kv "TRIM (NTFS)" $Inventory.Trim
    & $kv "Discos físicos" @($Inventory.Disks).Count
    & $kv "Capacidade total" (Format-SnakeOptimizerBytes -Bytes $Inventory.TotalSize)
    foreach ($kind in "NVMe", "SSD", "HDD", "USB") {
        $count = @($Inventory.Disks | Where-Object { $_.Type -eq $kind -or ($kind -eq "USB" -and $_.Bus -eq "USB" -and $_.Type -ne "USB") }).Count
        if ($count -gt 0) { & $kv "  $kind" $count }
    }

    $out.Add(""); $out.Add("UNIDADES"); $out.Add("-" * 64)
    foreach ($v in $Inventory.Volumes) {
        $out.Add(("{0,-3} {1} {2}" -f $v.Letter, (Format-SnakeOptimizerUsageBar -Percent $v.Used), (Get-SnakeOptimizerDiskVolumeText -Volume $v)))
    }

    foreach ($d in $Inventory.Disks) {
        $out.Add(""); $out.Add($line); $out.Add("DISCO $($d.Number) - $($d.Name)"); $out.Add($line)
        & $kv "Tipo" $d.Type
        & $kv "Interface / formato" "$($d.Bus) · $($d.Format)"
        & $kv "Capacidade" (Format-SnakeOptimizerBytes -Bytes $d.Size)
        & $kv "Fabricante" (& $na $d.Manufacturer)
        & $kv "Serial" (& $na $d.Serial)
        & $kv "Firmware" (& $na $d.Firmware)
        & $kv "Estado" "$(Get-SnakeOptimizerDiskHealthStatusText -Status $d.HealthStatus) ($(($d.OperationalStatus) -join ', '))"
        & $kv "Disco de partida" (& $yesNo $d.Boot)
        & $kv "Disco do sistema" (& $yesNo $d.SystemDisk)
        & $kv "Partições" (& $na $d.Partitions)
        & $kv "Unidades" $(if ($d.Volumes.Count) { ($d.Volumes | ForEach-Object { "$($_.Letter) $([Math]::Round($_.Used))%" }) -join ", " } else { "nenhuma com letra" })
        $smart = @($d.Temperature, $d.Wear, $d.PowerOnHours, $d.PowerCycles, $d.ReadErrorsTotal, $d.WriteErrorsTotal, $d.ReadErrorsUncorrected, $d.WriteErrorsUncorrected) | Where-Object { $null -ne $_ }
        if (@($smart).Count -eq 0) {
            & $kv "SMART" "não lido (exige Administrador; discos USB e RAID nem sempre informam)"
        }
        else {
            & $kv "Temperatura" $(if ($null -ne $d.Temperature) { "$($d.Temperature) °C" } else { "não informada" })
            & $kv "Desgaste" $(if ($d.Type -eq "HDD") { "não se aplica (HDD)" } elseif ($null -ne $d.Wear) { "$($d.Wear)% da vida útil" } else { "não informado" })
            & $kv "Horas ligado" (& $na $d.PowerOnHours)
            & $kv "Ligações (power cycles)" (& $na $d.PowerCycles)
            & $kv "Erros de leitura" "$(& $na $d.ReadErrorsTotal) (não corrigidos: $(& $na $d.ReadErrorsUncorrected))"
            & $kv "Erros de escrita" "$(& $na $d.WriteErrorsTotal) (não corrigidos: $(& $na $d.WriteErrorsUncorrected))"
        }
        if ($d.BytesRead) { & $kv "Total lido" (Format-SnakeOptimizerBytes -Bytes $d.BytesRead) }
        if ($d.BytesWritten) { & $kv "Total gravado" (Format-SnakeOptimizerBytes -Bytes $d.BytesWritten) }
        foreach ($n in $d.Notes) { $out.Add("ALERTA: $n") }
    }

    $out.Add(""); $out.Add($line)
    return $out.ToArray()
}


function Save-SnakeOptimizerDiskInventory {
    # Grava o .txt: em %ProgramData%\SnakeOptimizer\reports com Administrador (onde o RMM e a manutenção automática
    # guardam), senão na pasta de relatórios do usuário. Devolve o caminho.
    param ([Parameter(Mandatory)]$Inventory)

    $folder = $(if (Test-SnakeOptimizerAdministrator) { Join-Path $script:SnakeOptimizerAutoRoot "reports" } else { Join-Path (Get-SnakeOptimizerDataPath) "reports" })
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    $path = Join-Path $folder "DISCOS-$($Inventory.ComputerName)-$($Inventory.Date.ToString('yyyyMMdd-HHmm')).txt"
    Set-Content -LiteralPath $path -Value (Get-SnakeOptimizerDiskInventoryLines -Inventory $Inventory) -Encoding UTF8

    # Só os 10 mais novos.
    Get-ChildItem -LiteralPath $folder -Filter "DISCOS-*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue
    return $path
}


function Get-SnakeOptimizerDiskInventoryResult {
    # A faixa de resultado: discos com alerta e unidades com pouco espaço.
    param ([Parameter(Mandatory)]$Inventory, [string]$Title, [hashtable]$Data = @{})

    $problems = @()
    foreach ($d in @($Inventory.Disks | Where-Object { $_.Notes.Count -gt 0 })) { $problems += "disco $($d.Number) ($($d.Name)) com alerta" }
    foreach ($v in @($Inventory.Volumes | Where-Object { $_.Level -in "Low", "Critical" })) { $problems += "$($v.Letter) com $([Math]::Round($v.Used))% usado" }
    if ($Inventory.Trim -eq "DESLIGADO" -and @($Inventory.Disks | Where-Object { $_.Type -in "SSD", "NVMe" }).Count -gt 0) { $problems += "TRIM desligado com SSD" }

    if ($problems.Count -gt 0) { return (New-SnakeOptimizerResult -Kind Warning -Detail ($problems -join "; ") -Title $Title -Data $Data) }
    return (New-SnakeOptimizerResult -Kind Ok -Detail "$(@($Inventory.Disks).Count) discos e $(@($Inventory.Volumes).Count) unidades sem alerta" -Title $Title -Data $Data)
}


function Show-SnakeOptimizerDiskInventory {
    $title = "Inventário completo de discos"
    Enter-SnakeOptimizerAction -Title $title

    Write-SnakeOptimizerStatus -Type Running -Notice -Message "Lendo discos, unidades e contadores SMART..."
    $inv = Get-SnakeOptimizerDiskInventory

    if (@($inv.Disks).Count -eq 0 -and @($inv.Volumes).Count -eq 0) {
        Write-SnakeOptimizerStatus -Type Warning -Message "O Windows não respondeu com os discos. Tente de novo; se continuar, reinicie o PC."
        Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Failed -Detail "discos não lidos" -Title $title)
        return
    }

    Write-SnakeOptimizerSection -Title "Unidades (espaço usado)"
    foreach ($v in $inv.Volumes) {
        $level = switch ($v.Level) { "Critical" { "Bad" } "Low" { "Warn" } default { "Normal" } }
        Write-SnakeOptimizerKeyValue -Label "$($v.Letter) $(Format-SnakeOptimizerUsageBar -Percent $v.Used)" -Value (Get-SnakeOptimizerDiskVolumeText -Volume $v) -LabelWidth 26 -Level $level
    }

    Write-SnakeOptimizerSection -Title "Resumo"
    Write-SnakeOptimizerKeyValue -Label "Discos físicos" -Value "$(@($inv.Disks).Count) · $(Format-SnakeOptimizerBytes -Bytes $inv.TotalSize) no total"
    Write-SnakeOptimizerKeyValue -Label "TRIM (SSD)" -Value $inv.Trim -Level $(if ($inv.Trim -eq "DESLIGADO") { "Warn" } else { "Normal" })
    Write-SnakeOptimizerKeyValue -Label "Computador" -Value "$($inv.Manufacturer) $($inv.Model) · serial $($inv.BiosSerial)"

    foreach ($d in $inv.Disks) {
        $status = Get-SnakeOptimizerDiskHealthStatusText -Status $d.HealthStatus
        Write-SnakeOptimizerSection -Title "Disco $($d.Number): $($d.Name) ($($d.Type), $(Format-SnakeOptimizerBytes -Bytes $d.Size))"
        Write-SnakeOptimizerKeyValue -Label "Estado" -Value $status -Level $(switch ($status) { "Saudável" { "Ok" } "Atenção" { "Warn" } "Com defeito" { "Bad" } default { "Normal" } })
        Write-SnakeOptimizerKeyValue -Label "Unidades" -Value $(if ($d.Volumes.Count) { ($d.Volumes | ForEach-Object { "$($_.Letter) $([Math]::Round($_.Used))% usado" }) -join ", " } else { "nenhuma com letra" })
        Write-SnakeOptimizerKeyValue -Label "Interface" -Value "$($d.Bus) · $($d.Format)"
        Write-SnakeOptimizerKeyValue -Label "Serial / firmware" -Value "$(if ($d.Serial) { $d.Serial } else { '-' }) / $(if ($d.Firmware) { $d.Firmware } else { '-' })"
        if ($d.Boot -or $d.SystemDisk) { Write-SnakeOptimizerKeyValue -Label "Papel" -Value "disco do Windows (partida/sistema)" }
        Write-SnakeOptimizerKeyValue -Label "Temperatura" -Value $(if ($null -ne $d.Temperature) { "$($d.Temperature) °C" } else { $null })
        Write-SnakeOptimizerKeyValue -Label "Desgaste" -Value $(if ($d.Type -eq "HDD") { $null } elseif ($null -ne $d.Wear) { "$($d.Wear)% da vida útil" } else { $null })
        Write-SnakeOptimizerKeyValue -Label "Horas ligado" -Value $(if ($null -ne $d.PowerOnHours) { "$(Format-SnakeOptimizerNumber -Value ([double]$d.PowerOnHours)) h" } else { $null })
        if ($null -ne $d.ReadErrorsTotal -or $null -ne $d.WriteErrorsTotal) {
            Write-SnakeOptimizerKeyValue -Label "Erros" -Value "leitura $([string]$d.ReadErrorsTotal), escrita $([string]$d.WriteErrorsTotal)"
        }
        if ($d.BytesWritten) { Write-SnakeOptimizerKeyValue -Label "Total gravado" -Value (Format-SnakeOptimizerBytes -Bytes $d.BytesWritten) }
        foreach ($n in $d.Notes) { Write-SnakeOptimizerStatus -Type Warning -Message "$n." }
    }

    $data = @{}
    try {
        $path = Save-SnakeOptimizerDiskInventory -Inventory $inv
        Write-Host ""
        Write-SnakeOptimizerKeyValue -Label "Inventário salvo" -Value $path
        $data.Report = $path
    }
    catch {
        Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível salvar o arquivo: $($_.Exception.Message)"
    }

    if (-not (Test-SnakeOptimizerAdministrator)) {
        Write-SnakeOptimizerStatus -Type Info -Notice -Message "Sem Administrador, temperatura, desgaste e erros podem não aparecer."
    }

    Exit-SnakeOptimizerAction -Result (Get-SnakeOptimizerDiskInventoryResult -Inventory $inv -Title $title -Data $data)
}


function Invoke-SnakeOptimizerUnattendedDiskInventory {
    # Tarefa "discos" do modo silencioso: o inventário no console (o RMM guarda a saída) e no .txt.
    $title = "Inventário de discos"
    try {
        $inv = Get-SnakeOptimizerDiskInventory
        Get-SnakeOptimizerDiskInventoryLines -Inventory $inv | ForEach-Object { Write-Host $_ }
        $path = Save-SnakeOptimizerDiskInventory -Inventory $inv
        Write-SnakeOptimizerStatus -Type Success -Message "Inventário de discos salvo em: $path"
        return (Get-SnakeOptimizerDiskInventoryResult -Inventory $inv -Title $title -Data @{ Report = $path })
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível fazer o inventário de discos: $($_.Exception.Message)"
        return (New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title)
    }
}


function Get-SnakeOptimizerAutoHistoryPath {
    return (Join-Path $script:SnakeOptimizerAutoRoot "historico-automatico.json")
}


function Get-SnakeOptimizerAutoHistory {
    # As execuções do modo silencioso (manutenção automática ou RMM), da mais nova para a mais antiga.
    $path = Get-SnakeOptimizerAutoHistoryPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    try { return @(Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return @() }
}


function Add-SnakeOptimizerAutoHistory {
    param ([Parameter(Mandatory)]$Entry)

    try {
        if (-not (Test-Path -LiteralPath $script:SnakeOptimizerAutoRoot)) { New-Item -ItemType Directory -Path $script:SnakeOptimizerAutoRoot -Force | Out-Null }
        $all = @(@($Entry) + @(Get-SnakeOptimizerAutoHistory) | Select-Object -First $script:SnakeOptimizerAutoHistoryMax)
        $json = ConvertTo-Json -InputObject $all -Depth 5
        [IO.File]::WriteAllText((Get-SnakeOptimizerAutoHistoryPath), $json, (New-Object Text.UTF8Encoding($false)))
    }
    catch {
        Write-Verbose "Histórico: $($_.Exception.Message)"
    }
}


function Get-SnakeOptimizerUnattendedTasks {
    foreach ($key in $script:SnakeOptimizerUnattendedTasks.Keys) {
        [PSCustomObject]@{ Task = $key; Descricao = $script:SnakeOptimizerUnattendedTasks[$key].Label }
    }
}


function Invoke-SnakeOptimizerUnattendedRun {
    <#
    Roda uma ou mais tarefas sem perguntas ("limpeza-rapida,dns,fila-impressao") e devolve o código de saída para o RMM:
    0 tudo certo (ou nada a fazer), 1 terminou com alertas, 2 alguma falhou, 4 tarefa desconhecida. Com mais de uma tarefa,
    elas rodam na ordem da lista acima, não na ordem digitada: o ponto de restauração vem sempre antes dos reparos.
    #>
    param ([Parameter(Mandatory)][string]$Task)

    $requested = @($Task -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Select-Object -Unique)
    $unknown = @($requested | Where-Object { -not $script:SnakeOptimizerUnattendedTasks.Contains($_) })

    if ($requested.Count -eq 0 -or $unknown.Count -gt 0) {
        if ($unknown.Count -gt 0) { Write-Host "Tarefa desconhecida: $($unknown -join ', ')" -ForegroundColor Red }
        Write-Host "Tarefas disponíveis: $(@($script:SnakeOptimizerUnattendedTasks.Keys) -join ', ')" -ForegroundColor Yellow
        return 4
    }

    $ordered = @($script:SnakeOptimizerUnattendedTasks.Keys | Where-Object { $requested -contains $_ })
    $summary = @()
    $worst = 0
    $runStarted = Get-Date
    $reportPath = ""
    $reboot = $false

    foreach ($key in $ordered) {
        $definition = $script:SnakeOptimizerUnattendedTasks[$key]
        $started = Get-Date

        try {
            $result = Invoke-SnakeOptimizerNestedAction -Command $definition.Command -Arguments $definition.Arguments
        }
        catch {
            Write-SnakeOptimizerStatus -Type Error -Message "$($definition.Label): $($_.Exception.Message)"
            $result = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message
        }

        $code = switch ($result.Kind) { "Warning" { 1 } "Failed" { 2 } default { 0 } }
        if ($code -gt $worst) { $worst = $code }

        $needsReboot = [bool]($result.Data -and $result.Data.RebootRequired)
        if ($needsReboot) { $reboot = $true }
        if ($result.Data -and $result.Data.Report) { $reportPath = [string]$result.Data.Report }

        $summary += [PSCustomObject]@{
            Tarefa    = $key
            Resultado = $result.Status
            Tempo     = "{0:mm\:ss}" -f ((Get-Date) - $started)
            Reiniciar = $(if ($needsReboot) { "sim" } else { "" })
        }
    }

    Write-Host ""
    Write-Host "Resumo do SnakeOptimizer (modo silencioso)" -ForegroundColor Cyan
    $summary | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host "Código de saída: $worst (0 ok, 1 alertas, 2 falha)"

    # O histórico que a tela "Manutenção automática" mostra (só com Administrador/SYSTEM, que podem gravar em ProgramData).
    if (Test-SnakeOptimizerAdministrator) {
        Add-SnakeOptimizerAutoHistory -Entry ([ordered]@{
                At      = $runStarted.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
                Minutes = [math]::Round(((Get-Date) - $runStarted).TotalMinutes, 1)
                Tasks   = ($ordered -join ",")
                Code    = $worst
                Reboot  = $reboot
                Report  = $reportPath
                Items   = @($summary | ForEach-Object { [ordered]@{ Tarefa = $_.Tarefa; Resultado = [string]$_.Resultado } })
            })
    }

    return $worst
}


# ---------------------------------------------------------------------------
# Manutenção automática (tarefas do Agendador como SYSTEM)
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerAutoTaskCommand {
    <#
    O que a tarefa roda: o launcher mais novo do GitHub no modo silencioso (cada execução já pega as correções da
    semana). Sem internet, roda a cópia que está em %ProgramData%\SnakeOptimizer\app. A confiança é a mesma do RMM: o
    repositório do GitHub (proteja a conta com 2FA).
    #>
    param ([Parameter(Mandatory)][string]$Tasks)

    $repo = Get-SnakeOptimizerRepository
    $url = "https://raw.githubusercontent.com/$repo/main/launch.ps1"
    $local = Join-Path $script:SnakeOptimizerAutoRoot "app\SnakeOptimizer.Console.ps1"

    $script = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
        "`$s = `$null; try { `$s = Invoke-RestMethod -Uri '$url' -UseBasicParsing } catch { }; " +
        "if (`$s) { & ([scriptblock]::Create(`$s)) -Mode Run -Task '$Tasks' } else { & '$local' -Action Run -Task '$Tasks' }; " +
        "exit `$LASTEXITCODE"

    return [PSCustomObject]@{
        Executable = (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
        Arguments  = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$script`""
    }
}


function Register-SnakeOptimizerAutoTask {
    # Cria (ou troca) uma tarefa: SYSTEM, elevada, sem janela. Não começa na bateria; com o PC desligado na hora, roda
    # quando ele ligar. Uma execução não começa em cima da outra.
    param (
        [Parameter(Mandatory)][string]$Plan,
        [Parameter(Mandatory)][System.DayOfWeek[]]$Days,
        [Parameter(Mandatory)][datetime]$At
    )

    $definition = $script:SnakeOptimizerAutoPlans[$Plan]
    $command = Get-SnakeOptimizerAutoTaskCommand -Tasks $definition.Tasks

    $action = New-ScheduledTaskAction -Execute $command.Executable -Argument $command.Arguments
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Days -At $At
    $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    $description = "SnakeOptimizer (Snake Tech): manutenção $($definition.Label) automática ($($definition.Tasks)). Não reinicia o PC. Para remover: SnakeOptimizer > Manutenção > Manutenção automática."

    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description
    [void](Register-ScheduledTask -TaskPath $script:SnakeOptimizerAutoTaskPath -TaskName $definition.Name -InputObject $task -Force -ErrorAction Stop)
}


function Unregister-SnakeOptimizerAutoTask {
    param ([Parameter(Mandatory)][string]$Plan)

    $name = $script:SnakeOptimizerAutoPlans[$Plan].Name
    if (Get-ScheduledTask -TaskPath $script:SnakeOptimizerAutoTaskPath -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskPath $script:SnakeOptimizerAutoTaskPath -TaskName $name -Confirm:$false -ErrorAction Stop
    }
}


function Get-SnakeOptimizerAutoStatus {
    # Situação das duas tarefas: existe, ligada, próxima e última execução.
    foreach ($plan in $script:SnakeOptimizerAutoPlans.Keys) {
        $definition = $script:SnakeOptimizerAutoPlans[$plan]
        $task = Get-ScheduledTask -TaskPath $script:SnakeOptimizerAutoTaskPath -TaskName $definition.Name -ErrorAction SilentlyContinue
        $info = $(if ($task) { Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue } else { $null })
        $days = $(if ($task) { @($task.Triggers | ForEach-Object { $_.DaysOfWeek }) } else { @() })

        [PSCustomObject]@{
            Plan      = $plan
            Label     = $definition.Label
            Installed = [bool]$task
            Enabled   = [bool]($task -and $task.State -ne "Disabled")
            NextRun   = $(if ($info -and $info.NextRunTime -and $info.NextRunTime.Year -gt 2000) { $info.NextRunTime } else { $null })
            LastRun   = $(if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime } else { $null })
            Days      = $days
        }
    }
}


function Get-SnakeOptimizerAutoPlanName {
    # "leve", "completa" ou "manual/RMM", pela lista de tarefas de uma execução.
    param ([string]$Tasks)

    foreach ($plan in $script:SnakeOptimizerAutoPlans.Keys) {
        $planTasks = @($script:SnakeOptimizerAutoPlans[$plan].Tasks -split ',')
        $ordered = @($script:SnakeOptimizerUnattendedTasks.Keys | Where-Object { $planTasks -contains $_ }) -join ","
        if ($ordered -eq $Tasks) { return $script:SnakeOptimizerAutoPlans[$plan].Label }
    }

    return "manual/RMM"
}


function Show-SnakeOptimizerAutoMaintenance {
    param ([switch]$PassThru)

    $title = "Manutenção automática"
    Enter-SnakeOptimizerAction -Title $title

    if (-not (Test-SnakeOptimizerElevation -Reason "A manutenção automática exige privilégios de Administrador.")) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Failed -Detail "sem privilégios de Administrador" -PassThru:$PassThru
        return
    }

    $light = $script:SnakeOptimizerAutoPlans.leve.Tasks
    $full = $script:SnakeOptimizerAutoPlans.completa.Tasks
    Write-SnakeOptimizerStatus -Type Info -Message "Roda sozinho, em segundo plano, como o sistema: sem janela e sem perguntas. Nunca reinicia o PC (avisa no histórico quando precisa). No notebook, só na tomada."
    Write-SnakeOptimizerKeyValue -Label "Leve (diária)" -Value "limpeza rápida, cache DNS, atualizações do Windows e relatório" -LabelWidth 22
    Write-SnakeOptimizerKeyValue -Label "Completa (semanal)" -Value "ponto de restauração, limpeza, limpeza avançada segura, WinSxS, DISM + SFC, atualizações, hora, DNS, discos e relatório" -LabelWidth 22

    # Situação atual.
    Write-SnakeOptimizerSection -Title "Agendamento"
    $status = @(Get-SnakeOptimizerAutoStatus)
    $dayNames = @{ Sunday = "dom"; Monday = "seg"; Tuesday = "ter"; Wednesday = "qua"; Thursday = "qui"; Friday = "sex"; Saturday = "sáb" }

    foreach ($item in $status) {
        $value = $(if (-not $item.Installed) { "desligada" }
            elseif (-not $item.Enabled) { "desativada no Agendador de Tarefas" }
            else {
                $daysText = $(if (@($item.Days).Count -ge 7) { "todo dia" } else { (@($item.Days | ForEach-Object { $dayNames[[string]$_] }) -join ", ") })
                "ligada ($daysText)$(if ($item.NextRun) { "; próxima: $(Format-SnakeOptimizerDateTime -When $item.NextRun)" })"
            })
        Write-SnakeOptimizerKeyValue -Label "Manutenção $($item.Label)" -Value $value -LabelWidth 22
    }

    # As últimas execuções (da manutenção automática e do RMM).
    $history = @(Get-SnakeOptimizerAutoHistory | Select-Object -First 7)
    if ($history.Count -gt 0) {
        Write-SnakeOptimizerSection -Title "Últimas execuções"
        foreach ($run in $history) {
            $when = $(try { (Get-Date ([datetime]::Parse($run.At, [Globalization.CultureInfo]::InvariantCulture))).ToString("dd/MM HH:mm") } catch { $run.At })
            $outcome = $(switch ([int]$run.Code) { 0 { "tudo certo" } 1 { "com alertas" } default { "com falha" } })
            $problems = @($run.Items | Where-Object { $_.Resultado -notmatch '^OK' } | ForEach-Object { $_.Tarefa })
            $text = "$(Get-SnakeOptimizerAutoPlanName -Tasks $run.Tasks) · $outcome$(if ($problems) { " ($($problems -join ', '))" }) · $($run.Minutes) min$(if ($run.Reboot) { ' · PEDE REINÍCIO' })"
            Write-SnakeOptimizerKeyValue -Label $when -Value $text -LabelWidth 12 -Level $(if ([int]$run.Code -ge 2) { "Warn" } else { "Normal" })
        }

        $lastReport = @($history | Where-Object { $_.Report } | Select-Object -First 1)
        if ($lastReport) { Write-SnakeOptimizerKeyValue -Label "Último relatório" -Value $lastReport[0].Report -LabelWidth 22 }
    }
    else {
        Write-SnakeOptimizerStatus -Type Info -Message "Ainda não houve nenhuma execução automática neste PC."
    }

    Write-Host ""
    $options = @(
        @{ Key = "1"; Label = "Ligar: leve de segunda a sábado + completa no domingo"; Description = "Recomendado. Leve às 12h; completa no domingo às 12h (com o PC desligado, roda quando ligar)."; Accent = $true },
        @{ Key = "2"; Label = "Ligar só a leve, todo dia"; Description = "Limpeza, DNS, atualizações e relatório todo dia às 12h." },
        @{ Key = "3"; Label = "Ligar só a completa, uma vez por semana"; Description = "Domingo às 12h." },
        @{ Key = "4"; Label = "Rodar a leve agora"; Description = "Para testar: roda em segundo plano e aparece aqui nas últimas execuções quando terminar." },
        @{ Key = "5"; Label = "Desligar a manutenção automática"; Description = "Remove as tarefas. O histórico e os relatórios ficam." },
        @{ Key = "X"; Label = "Voltar"; Exit = $true }
    )

    $answer = Read-SnakeOptimizerChoice -Message "O que fazer?" -Options $options -DefaultKey "X" -ShowMenu -TextPrompt "Opção (número, X = voltar)"

    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "X") {
        Exit-SnakeOptimizerAction -Result $null
        return
    }

    $noon = (Get-Date).Date.AddHours(12)
    $all = [System.DayOfWeek[]]@(0..6)
    $weekdays = [System.DayOfWeek[]]@(1..6)

    try {
        switch ($answer) {
            "1" {
                Register-SnakeOptimizerAutoTask -Plan leve -Days $weekdays -At $noon
                Register-SnakeOptimizerAutoTask -Plan completa -Days ([System.DayOfWeek[]]@([System.DayOfWeek]::Sunday)) -At $noon
                $final = New-SnakeOptimizerResult -Kind Ok -Detail "leve de segunda a sábado e completa no domingo, às 12h" -Title $title
            }
            "2" {
                Register-SnakeOptimizerAutoTask -Plan leve -Days $all -At $noon
                Unregister-SnakeOptimizerAutoTask -Plan completa
                $final = New-SnakeOptimizerResult -Kind Ok -Detail "leve todo dia, às 12h" -Title $title
            }
            "3" {
                Register-SnakeOptimizerAutoTask -Plan completa -Days ([System.DayOfWeek[]]@([System.DayOfWeek]::Sunday)) -At $noon
                Unregister-SnakeOptimizerAutoTask -Plan leve
                $final = New-SnakeOptimizerResult -Kind Ok -Detail "completa no domingo, às 12h" -Title $title
            }
            "4" {
                $name = $script:SnakeOptimizerAutoPlans.leve.Name
                if (-not (Get-ScheduledTask -TaskPath $script:SnakeOptimizerAutoTaskPath -TaskName $name -ErrorAction SilentlyContinue)) {
                    Write-SnakeOptimizerStatus -Type Warning -Message "A manutenção leve não está ligada: ligue (opção 1 ou 2) e depois rode."
                    $final = New-SnakeOptimizerResult -Kind Skipped -Detail "manutenção leve não está ligada" -Title $title
                }
                else {
                    Start-ScheduledTask -TaskPath $script:SnakeOptimizerAutoTaskPath -TaskName $name -ErrorAction Stop
                    Write-SnakeOptimizerStatus -Type Success -Message "Manutenção leve iniciada em segundo plano. Leva de 5 a 30 minutos (mais se houver atualização). Abra esta tela depois para ver o resultado."
                    $final = New-SnakeOptimizerResult -Kind Ok -Detail "manutenção leve iniciada em segundo plano" -Title $title
                }
            }
            "5" {
                foreach ($plan in $script:SnakeOptimizerAutoPlans.Keys) { Unregister-SnakeOptimizerAutoTask -Plan $plan }
                Write-SnakeOptimizerStatus -Type Success -Message "Manutenção automática desligada. Nada mais roda sozinho."
                $final = New-SnakeOptimizerResult -Kind Ok -Detail "desligada" -Title $title
            }
        }

        if ($answer -in "1", "2", "3") {
            Write-SnakeOptimizerStatus -Type Success -Message "Manutenção automática ligada: $($final.Detail). Ela baixa o SnakeOptimizer atualizado a cada execução."
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível mudar o agendamento: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


# ---------------------------------------------------------------------------
# Instalação no PC e atualização automática do próprio SnakeOptimizer
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerPublishedCommit {
    # O último commit publicado na branch principal do GitHub (Sha, Date, Message), ou $null.
    try {
        Enable-SnakeOptimizerTls12
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$(Get-SnakeOptimizerRepository)/commits/main" -UseBasicParsing -TimeoutSec 15 `
            -Headers @{ "User-Agent" = "SnakeOptimizer/$(Get-SnakeOptimizerBuild)"; "Accept" = "application/vnd.github+json" } -ErrorAction Stop
        $date = $null
        try { $date = ([datetime]::Parse([string]$r.commit.committer.date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime() } catch { }
        return [PSCustomObject]@{ Sha = [string]$r.sha; Date = $date; Message = (([string]$r.commit.message) -split "`n")[0].Trim() }
    }
    catch { return $null }
}


function Get-SnakeOptimizerInstallState {
    # A instalação em %ProgramData%\SnakeOptimizer: cópia, versão anotada, Atualizador e atalhos.
    $root = $script:SnakeOptimizerAutoRoot
    $version = $null
    try { $version = Get-Content -LiteralPath (Join-Path $root "versao-instalada.json") -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { }

    $task = Get-ScheduledTask -TaskPath $script:SnakeOptimizerAutoTaskPath -TaskName "Atualizador" -ErrorAction SilentlyContinue
    $info = $(if ($task) { Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue } else { $null })
    $log = Join-Path $root "atualizador.log"

    return [PSCustomObject]@{
        Root      = $root
        AppExists = (Test-Path -LiteralPath (Join-Path $root "app\SnakeOptimizer.Gui.ps1"))
        Launcher  = (Join-Path $root "launch.ps1")
        Version   = $version
        Updater   = [bool]$task
        Enabled   = [bool]($task -and $task.State -ne "Disabled")
        LastRun   = $(if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime } else { $null })
        NextRun   = $(if ($info -and $info.NextRunTime -and $info.NextRunTime.Year -gt 2000) { $info.NextRunTime } else { $null })
        LogLines  = @($(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Encoding UTF8 -Tail 5 -ErrorAction SilentlyContinue }))
        Running   = (Get-SnakeOptimizerAppRoot).TrimEnd("\") -ieq (Join-Path $root "app")
    }
}


function Invoke-SnakeOptimizerLauncherMode {
    # Roda o launcher (o desta cópia) em outro PowerShell, mostrando a saída: -Mode Install/Uninstall.
    param ([Parameter(Mandatory)][ValidateSet("Install", "Uninstall")][string]$Mode)

    $launcher = Join-Path (Get-SnakeOptimizerAppRoot) "launch.ps1"
    if (-not (Test-Path -LiteralPath $launcher)) { throw "O launcher (launch.ps1) não está na pasta $(Get-SnakeOptimizerAppRoot)." }

    $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $output = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher -Mode $Mode -NoUpdate 2>&1
    foreach ($line in @($output)) {
        $text = ([string]$line) -replace '^\[SnakeOptimizer\]\s*', ''
        if ($text.Trim()) { Write-SnakeOptimizerStatus -Type Info -Notice -Message $text }
    }
    return $LASTEXITCODE
}


function Show-SnakeOptimizerInstallation {
    <#
    Versão nova e instalação no PC. O SnakeOptimizer não é um serviço do Windows de verdade (é PowerShell, e um serviço
    não mostra janela): a instalação deixa uma cópia fixa em %ProgramData%, a tarefa "Atualizador" (SYSTEM, ao ligar o PC
    e a cada 6 horas), que faz o papel do serviço, e atalhos que abrem como Administrador e conferem a versão antes de abrir.
    #>
    param ([switch]$PassThru)

    $title = "Versão nova e instalação no PC"
    Enter-SnakeOptimizerAction -Title $title

    Write-Host "  Confere no GitHub a última versão publicada e mostra se este PC tem o SnakeOptimizer instalado com atualização automática." -ForegroundColor DarkGray
    Write-Host ""

    $state = Get-SnakeOptimizerInstallState
    $published = Get-SnakeOptimizerPublishedCommit

    Write-SnakeOptimizerSection -Title "Versões"
    if ($published) {
        $when = $(if ($published.Date) { Format-SnakeOptimizerDateTime -When $published.Date } else { "" })
        Write-SnakeOptimizerKeyValue -Label "Publicada no GitHub" -Value "$($published.Sha.Substring(0, 7)) · $when · $($published.Message)" -LabelWidth 22
    }
    else {
        Write-SnakeOptimizerKeyValue -Label "Publicada no GitHub" -Value "não foi possível consultar agora (internet ou limite do GitHub)" -LabelWidth 22 -Level "Warn"
    }

    $installedSha = $(if ($state.Version -and $state.Version.Sha) { [string]$state.Version.Sha } else { "" })
    if ($state.AppExists) {
        $installedText = $(if ($installedSha) { "$($installedSha.Substring(0, 7)) · baixada em $(try { Format-SnakeOptimizerDateTime -When ([datetime]::Parse($state.Version.InstalledAt, [Globalization.CultureInfo]::InvariantCulture)) } catch { $state.Version.InstalledAt })" } else { "versão não anotada (instalada por um launcher antigo)" })
        Write-SnakeOptimizerKeyValue -Label "Neste PC" -Value $installedText -LabelWidth 22
    }
    else {
        Write-SnakeOptimizerKeyValue -Label "Neste PC" -Value "não instalado (só a cópia aberta agora, em $(Get-SnakeOptimizerAppRoot))" -LabelWidth 22
    }

    $upToDate = [bool]($published -and $installedSha -and $installedSha -eq $published.Sha)
    $newer = [bool]($published -and $state.AppExists -and -not $upToDate)

    Write-SnakeOptimizerSection -Title "Atualização automática"
    if ($state.Updater) {
        $value = $(if (-not $state.Enabled) { "desativado no Agendador de Tarefas" } else { "ligado (ao ligar o PC e a cada 6 horas)$(if ($state.LastRun) { "; última: $(Format-SnakeOptimizerDateTime -When $state.LastRun)" })" })
        Write-SnakeOptimizerKeyValue -Label "Atualizador" -Value $value -LabelWidth 22 -Level $(if ($state.Enabled) { "Normal" } else { "Warn" })
        foreach ($line in $state.LogLines) { Write-SnakeOptimizerStatus -Type Info -Notice -Message $line }
    }
    else {
        Write-SnakeOptimizerKeyValue -Label "Atualizador" -Value "desligado" -LabelWidth 22
    }

    Write-Host ""
    if ($upToDate) {
        Write-SnakeOptimizerStatus -Type Success -Message "A cópia instalada é a versão mais nova publicada."
    }
    elseif ($newer -and $state.Updater) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Há versão nova. O Atualizador troca sozinho quando o SnakeOptimizer estiver fechado (em até 6 horas ou ao ligar o PC). Ou feche esta janela e abra pelo atalho: ele atualiza antes de abrir."
    }
    elseif ($newer) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Há versão nova. Feche e abra de novo pelo link ou pelo Abrir-SnakeOptimizer.cmd (eles baixam a mais nova), ou instale no PC para atualizar sozinho."
    }

    if ($state.Running -and $newer) {
        Write-SnakeOptimizerStatus -Type Info -Notice -Message "Esta janela está aberta a partir da cópia instalada: a troca acontece depois que ela fechar."
    }

    $options = @(
        @{ Key = "1"; Label = $(if ($state.Updater) { "Reinstalar / reparar a instalação" } else { "Instalar no PC com atualização automática" }); Accent = (-not $state.Updater)
            Description = "Cópia fixa em $($state.Root), tarefa Atualizador (SYSTEM, ao ligar o PC e a cada 6 horas), ícone na bandeja (perto do relógio) e atalhos na Área de Trabalho e no Menu Iniciar para todos os usuários." },
        @{ Key = "2"; Label = "Desinstalar do PC"; Description = "Remove o Atualizador, a manutenção automática e os atalhos. Os relatórios e o histórico ficam; a pasta do app sai quando o SnakeOptimizer estiver fechado." },
        @{ Key = "X"; Label = "Voltar"; Exit = $true }
    )

    $answer = Read-SnakeOptimizerChoice -Message "O que fazer?" -Options $options -DefaultKey "X" -ShowMenu -TextPrompt "Opção (número, X = voltar)"

    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "X") {
        $final = $(if ($upToDate) { New-SnakeOptimizerResult -Kind Ok -Detail "versão mais nova" -Title $title }
            elseif ($newer) { New-SnakeOptimizerResult -Kind Warning -Detail "há versão nova publicada" -Title $title }
            else { $null })
        if ($PassThru) { $final }
        Exit-SnakeOptimizerAction -Result $final
        return
    }

    if (-not (Test-SnakeOptimizerElevation -Reason "Instalar e desinstalar exigem privilégios de Administrador.")) {
        Exit-SnakeOptimizerToolEarly -Title $title -Kind Failed -Detail "sem privilégios de Administrador" -PassThru:$PassThru
        return
    }

    try {
        if ($answer -eq "1") {
            Write-SnakeOptimizerStatus -Type Running -Notice -Message "Instalando..."
            $code = Invoke-SnakeOptimizerLauncherMode -Mode Install
            $final = $(if ($code -eq 0) { New-SnakeOptimizerResult -Kind Ok -Detail "instalado com atualização automática" -Title $title }
                else { New-SnakeOptimizerResult -Kind Failed -Detail "a instalação não terminou (veja acima)" -Title $title })
        }
        else {
            if (-not (Confirm-SnakeOptimizerAction -Message "Desinstalar o SnakeOptimizer deste PC (Atualizador, manutenção automática e atalhos)?" -DefaultKey N)) {
                $final = New-SnakeOptimizerResult -Kind Skipped -Detail "nada mudou" -Title $title
            }
            else {
                [void](Invoke-SnakeOptimizerLauncherMode -Mode Uninstall)
                $final = New-SnakeOptimizerResult -Kind Ok -Detail "desinstalado" -Title $title
            }
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível: $($_.Exception.Message)"
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message -Title $title
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Result $final
}


Export-ModuleMember -Function *-SnakeOptimizer*
