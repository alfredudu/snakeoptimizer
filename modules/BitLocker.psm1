# ---------------------------------------------------------------------------
# Chave de recuperação do BitLocker e o cofre externo (Nextcloud)
# ---------------------------------------------------------------------------
# Por que um cofre fora do PC: quando o BitLocker pede a chave (troca de placa-mãe, atualização da BIOS, TPM zerado), o
# PC não abre, e uma cópia guardada nele mesmo não adianta. A chave vai para fora assim:
#   - Cofre (Nextcloud): um link de compartilhamento de pasta do tipo "Solicitar arquivos" (file drop): quem tem o link
#     só consegue mandar arquivos, nunca ver nem baixar os de outros PCs. Cada PC manda um .txt com o nome dele e a data.
#     O link (e a senha do link, se houver) fica em %ProgramData%\SnakeOptimizer\cofre.json, cifrado pelo Windows (DPAPI
#     da máquina) e só com Administradores e SYSTEM. Nunca no GitHub.
#   - Arquivo: um .txt salvo onde a pessoa escolher (pendrive, pasta de rede).
# A manutenção automática (tarefa "cofre-bitlocker") manda de novo só quando a chave muda (outra chave, outro disco).

$script:SnakeOptimizerVaultEntropy = "SnakeOptimizer.Vault"


function Get-SnakeOptimizerBitLockerVaultPath {
    $root = Join-Path $env:ProgramData "SnakeOptimizer"
    if (-not (Test-Path -LiteralPath $root)) { [void](New-Item -Path $root -ItemType Directory -Force) }
    return (Join-Path $root "cofre.json")
}


function Protect-SnakeOptimizerVaultText {
    param ([string]$Text)

    if (-not $Text) { return "" }
    Add-Type -AssemblyName System.Security
    $bytes = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Text), [Text.Encoding]::UTF8.GetBytes($script:SnakeOptimizerVaultEntropy), [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($bytes)
}


function Unprotect-SnakeOptimizerVaultText {
    param ([string]$Protected)

    if (-not $Protected) { return "" }
    Add-Type -AssemblyName System.Security
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Protected), [Text.Encoding]::UTF8.GetBytes($script:SnakeOptimizerVaultEntropy), [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Text.Encoding]::UTF8.GetString($bytes)
}


function Get-SnakeOptimizerBitLockerVaultConfig {
    # O cofre deste PC: Url e Password já decifrados, Enabled, LastSent (texto ISO) e Fingerprint (da última chave enviada).
    $config = [PSCustomObject]@{ Enabled = $false; Url = ""; Password = ""; LastSent = ""; Fingerprint = "" }

    try {
        $state = Read-SnakeOptimizerStateFile -Path (Get-SnakeOptimizerBitLockerVaultPath)
        if ($null -eq $state.Document) { return $config }
        $document = $state.Document

        $config.Enabled = [bool](Get-SnakeOptimizerJsonValue -Object $document -Name "Enabled" -Default $false)
        $config.Url = Unprotect-SnakeOptimizerVaultText -Protected ([string](Get-SnakeOptimizerJsonValue -Object $document -Name "UrlProtected" -Default ""))
        $config.Password = Unprotect-SnakeOptimizerVaultText -Protected ([string](Get-SnakeOptimizerJsonValue -Object $document -Name "PasswordProtected" -Default ""))
        $config.LastSent = [string](Get-SnakeOptimizerJsonValue -Object $document -Name "LastSent" -Default "")
        $config.Fingerprint = [string](Get-SnakeOptimizerJsonValue -Object $document -Name "Fingerprint" -Default "")
    }
    catch {
        Write-Verbose "Cofre: $($_.Exception.Message)"
    }

    return $config
}


function Save-SnakeOptimizerBitLockerVaultConfig {
    # Grava o cofre (link e senha cifrados) e deixa o arquivo só com Administradores e SYSTEM.
    param ([Parameter(Mandatory)]$Config)

    $path = Get-SnakeOptimizerBitLockerVaultPath
    $document = [ordered]@{
        Enabled           = [bool]$Config.Enabled
        UrlProtected      = (Protect-SnakeOptimizerVaultText -Text ([string]$Config.Url))
        PasswordProtected = (Protect-SnakeOptimizerVaultText -Text ([string]$Config.Password))
        LastSent          = [string]$Config.LastSent
        Fingerprint       = [string]$Config.Fingerprint
    }

    Write-SnakeOptimizerStateJson -Path $path -InputObject $document

    foreach ($file in @($path, "$path.bak")) {
        if (Test-Path -LiteralPath $file) {
            [void](Invoke-SnakeOptimizerCapture -FilePath "icacls.exe" -Arguments @($file, "/inheritance:r", "/grant:r", "*S-1-5-32-544:F", "/grant:r", "*S-1-5-18:F", "/Q"))
        }
    }
}


function ConvertFrom-SnakeOptimizerNextcloudShareUrl {
    <#
    O endereço do servidor e o código (token) de um link de compartilhamento do Nextcloud:
    "https://nuvem.exemplo.com.br/s/AbC123" ou "https://nuvem.exemplo.com.br/index.php/s/AbC123" (e o mesmo dentro de uma
    subpasta, como "/nextcloud/s/..."). $null quando o texto não é um link desses.
    #>
    param ([AllowEmptyString()][string]$Url)

    $text = ([string]$Url).Trim()
    if ($text -notmatch '^(?<base>https://[^\s?#]+?)(/index\.php)?/s/(?<token>[A-Za-z0-9]+)/?(\?.*)?$') { return $null }

    return [PSCustomObject]@{ Base = $Matches['base'].TrimEnd('/'); Token = $Matches['token'] }
}


function Get-SnakeOptimizerBitLockerKeys {
    <#
    As chaves de recuperação (senha numérica de 48 dígitos) de cada unidade com BitLocker: MountPoint, Status (o estado
    do volume), Protection, Id (o identificador da chave, que a tela azul do BitLocker mostra) e Password. Exige
    Administrador. Devolve Available = $false quando o Windows não tem o BitLocker ou não respondeu.
    #>
    $result = [PSCustomObject]@{ Available = $false; Problem = ""; Volumes = @() }

    try {
        $volumes = @(Get-BitLockerVolume -ErrorAction Stop)
        $result.Available = $true
    }
    catch {
        $result.Problem = $(if (-not (Test-SnakeOptimizerAdministrator)) { "é preciso abrir como Administrador" } else { "o Windows não respondeu sobre o BitLocker ($($_.Exception.Message))" })
        return $result
    }

    $result.Volumes = @(foreach ($volume in ($volumes | Sort-Object MountPoint)) {
            $keys = @(@(Get-SnakeOptimizerJsonValue -Object $volume -Name "KeyProtector" -Default @()) | Where-Object { $null -ne $_ -and [string]$_.KeyProtectorType -eq "RecoveryPassword" -and $_.RecoveryPassword })

            [PSCustomObject]@{
                MountPoint = [string]$volume.MountPoint
                Status     = [string]$volume.VolumeStatus
                Protection = [string]$volume.ProtectionStatus
                Encrypted  = ([string]$volume.VolumeStatus -ne "FullyDecrypted")
                Keys       = @($keys | ForEach-Object { [PSCustomObject]@{ Id = ([string]$_.KeyProtectorId).Trim('{', '}'); Password = [string]$_.RecoveryPassword } })
            }
        })

    return $result
}


function Get-SnakeOptimizerBitLockerStatusText {
    param ([string]$Status, [string]$Protection)

    $state = switch ($Status) {
        "FullyEncrypted" { "criptografado" }
        "FullyDecrypted" { "sem criptografia" }
        "EncryptionInProgress" { "criptografando" }
        "EncryptionSuspended" { "criptografia pausada" }
        "DecryptionInProgress" { "descriptografando" }
        "DecryptionSuspended" { "descriptografia pausada" }
        default { "estado desconhecido" }
    }

    if ($Status -ne "FullyDecrypted" -and [string]$Protection -in @("Off", "0")) { $state += ", proteção suspensa" }

    return $state
}


function Get-SnakeOptimizerBitLockerFingerprint {
    # Um resumo (SHA-256) das chaves de agora, para saber se mudaram desde o último envio. Não dá para voltar às chaves.
    param ([AllowEmptyCollection()][object[]]$Volumes = @())

    $text = (@(foreach ($volume in $Volumes) { foreach ($key in @($volume.Keys)) { "$($volume.MountPoint)|$($key.Id)|$($key.Password)" } }) | Sort-Object) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()

    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace("-", "") }
    finally { $sha.Dispose() }
}


function ConvertTo-SnakeOptimizerBitLockerKeyText {
    # O conteúdo do .txt: de que PC é, quando foi lido e a chave de cada unidade.
    param ([AllowEmptyCollection()][object[]]$Volumes = @())

    $serial = ""
    $model = ""
    $domain = ""
    try { $serial = ([string](Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop | Select-Object -First 1).SerialNumber).Trim() } catch { }
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1
        $model = ("$($computer.Manufacturer) $($computer.Model)").Trim()
        $domain = [string]$computer.Domain
    }
    catch { }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Chaves de recuperação do BitLocker")
    $lines.Add("")
    $lines.Add("Computador : $env:COMPUTERNAME")
    if ($domain) { $lines.Add("Domínio    : $domain") }
    if ($model) { $lines.Add("Modelo     : $model") }
    if ($serial) { $lines.Add("Serial     : $serial") }
    $lines.Add("Lido em    : $(Format-SnakeOptimizerDateTime -When (Get-Date) -Pattern 'dd/MM/yyyy HH:mm')")
    $lines.Add("")

    foreach ($volume in $Volumes) {
        foreach ($key in @($volume.Keys)) {
            $lines.Add("Unidade $($volume.MountPoint) ($(Get-SnakeOptimizerBitLockerStatusText -Status $volume.Status -Protection $volume.Protection))")
            $lines.Add("  Identificação da chave : $($key.Id)")
            $lines.Add("  Chave de recuperação   : $($key.Password)")
            $lines.Add("")
        }
    }

    $lines.Add("Na tela azul do BitLocker, confira se os primeiros caracteres da identificação são os mesmos e digite a chave de recuperação.")
    $lines.Add("Gerado pelo SnakeOptimizer.")

    return ($lines -join "`r`n")
}


function Get-SnakeOptimizerBitLockerFileName {
    $name = ([string]$env:COMPUTERNAME) -replace '[^A-Za-z0-9._-]', '_'
    return "$name`_$((Get-Date).ToString('yyyy-MM-dd_HHmm', [System.Globalization.CultureInfo]::InvariantCulture))_BitLocker.txt"
}


function Send-SnakeOptimizerNextcloudFile {
    <#
    Manda um texto como arquivo para a pasta de um link de compartilhamento do Nextcloud (WebDAV público:
    PUT <servidor>/public.php/webdav/<arquivo>, usuário = o código do link, senha = a do link ou vazia). Devolve Sent e
    Problem; nunca lança erro.
    #>
    param (
        [Parameter(Mandatory)][string]$Url,
        [AllowEmptyString()][string]$Password = "",
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Text
    )

    $share = ConvertFrom-SnakeOptimizerNextcloudShareUrl -Url $Url
    if ($null -eq $share) { return [PSCustomObject]@{ Sent = $false; Problem = "o link não parece um compartilhamento do Nextcloud (https://servidor/s/codigo)" } }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $target = "$($share.Base)/public.php/webdav/$([Uri]::EscapeDataString($FileName))"
        $request = [System.Net.HttpWebRequest]::Create($target)
        $request.Method = "PUT"
        $request.Timeout = 30000
        $request.ContentType = "text/plain; charset=utf-8"
        $request.UserAgent = "SnakeOptimizer"
        $request.Headers.Add("X-Requested-With", "XMLHttpRequest")
        $request.Headers.Add("Authorization", "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($share.Token):$Password")))

        $bytes = (New-Object Text.UTF8Encoding $true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes($Text)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }

        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        $response.Dispose()

        if ($code -ge 200 -and $code -lt 300) { return [PSCustomObject]@{ Sent = $true; Problem = "" } }
        return [PSCustomObject]@{ Sent = $false; Problem = "o servidor respondeu $code" }
    }
    catch [System.Net.WebException] {
        # Guardado antes do switch: dentro dele, $_ passa a ser o código.
        $failure = $_.Exception
        $reason = $(if ($failure.InnerException -and $failure.InnerException.Message) { $failure.InnerException.Message } else { $failure.Message })
        $code = $(if ($failure.Response) { [int]$failure.Response.StatusCode } else { 0 })
        $problem = switch ($code) {
            401 { "o servidor recusou o acesso: confira o link (ele pode ter sido apagado) e a senha do link" }
            403 { "o link não permite enviar arquivos: no Nextcloud, compartilhe a pasta com Solicitar arquivos (ou Permitir envio)" }
            404 { "o link não existe mais ou expirou" }
            0 { "sem conexão com o servidor ($reason)" }
            default { "o servidor respondeu $code" }
        }
        return [PSCustomObject]@{ Sent = $false; Problem = $problem }
    }
    catch {
        return [PSCustomObject]@{ Sent = $false; Problem = $_.Exception.Message }
    }
}


function Send-SnakeOptimizerBitLockerToVault {
    <#
    Manda as chaves para o cofre configurado e guarda quando e qual chave foi. -OnlyIfChanged (a manutenção
    automática): não manda de novo uma chave igual à última enviada. Devolve Kind (Ok, Skipped, Failed) e Detail.
    #>
    param (
        [AllowEmptyCollection()][object[]]$Volumes = @(),
        [switch]$OnlyIfChanged
    )

    $config = Get-SnakeOptimizerBitLockerVaultConfig

    if (-not $config.Enabled -or -not $config.Url) { return [PSCustomObject]@{ Kind = "Skipped"; Detail = "cofre não configurado neste PC" } }

    $withKeys = @($Volumes | Where-Object { @($_.Keys).Count -gt 0 })
    if ($withKeys.Count -eq 0) { return [PSCustomObject]@{ Kind = "Skipped"; Detail = "nenhuma unidade com chave de recuperação" } }

    $fingerprint = Get-SnakeOptimizerBitLockerFingerprint -Volumes $withKeys

    if ($OnlyIfChanged -and $config.Fingerprint -eq $fingerprint) {
        return [PSCustomObject]@{ Kind = "Skipped"; Detail = "a chave é a mesma já guardada no cofre" }
    }

    $sent = Send-SnakeOptimizerNextcloudFile -Url $config.Url -Password $config.Password -FileName (Get-SnakeOptimizerBitLockerFileName) -Text (ConvertTo-SnakeOptimizerBitLockerKeyText -Volumes $withKeys)

    if (-not $sent.Sent) { return [PSCustomObject]@{ Kind = "Failed"; Detail = "não foi para o cofre: $($sent.Problem)" } }

    $config.Fingerprint = $fingerprint
    $config.LastSent = (Get-Date).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
    Save-SnakeOptimizerBitLockerVaultConfig -Config $config

    return [PSCustomObject]@{ Kind = "Ok"; Detail = "chave guardada no cofre" }
}


function Format-SnakeOptimizerVaultLastSent {
    param ([AllowEmptyString()][string]$LastSent)

    $at = [datetime]::MinValue
    if (-not $LastSent -or -not [datetime]::TryParse($LastSent, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) { return "nunca" }
    return (Format-SnakeOptimizerDateTime -When $at)
}


function Show-SnakeOptimizerBitLockerKeys {
    <#
    Chave de recuperação do BitLocker: mostra a chave de cada unidade, salva num .txt (pendrive, pasta de rede) e manda
    para o cofre, se ele estiver configurado na área técnica.
    #>
    $title = "Chave de recuperação do BitLocker"
    Enter-SnakeOptimizerAction -Title $title
    $result = $null

    if (-not (Test-SnakeOptimizerElevation -Reason "Ler a chave de recuperação do BitLocker exige privilégios de Administrador.")) {
        Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Failed -Detail "requer Administrador")
        return
    }

    Write-Progress -Activity $title -Status "lendo o BitLocker"
    $read = Get-SnakeOptimizerBitLockerKeys
    Write-Progress -Activity $title -Completed

    if (-not $read.Available) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível ler o BitLocker: $($read.Problem). Esta edição do Windows (Home) pode não ter o BitLocker."
        Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Skipped -Detail "BitLocker não disponível")
        return
    }

    $withKeys = @($read.Volumes | Where-Object { @($_.Keys).Count -gt 0 })
    $encryptedWithout = @($read.Volumes | Where-Object { $_.Encrypted -and @($_.Keys).Count -eq 0 })

    foreach ($volume in $read.Volumes) {
        Write-SnakeOptimizerSection -Title "Unidade $($volume.MountPoint) · $(Get-SnakeOptimizerBitLockerStatusText -Status $volume.Status -Protection $volume.Protection)"

        if (@($volume.Keys).Count -eq 0) {
            if ($volume.Encrypted) { Write-SnakeOptimizerStatus -Type Warning -Message "Criptografada, mas sem chave de recuperação numérica: se o BitLocker pedir a chave, não haverá como abrir." }
            else { Write-SnakeOptimizerKeyValue -Label "Chave" -Value "não tem (unidade sem criptografia)" }
            continue
        }

        foreach ($key in $volume.Keys) {
            Write-SnakeOptimizerKeyValue -Label "Identificação" -Value $key.Id
            Write-SnakeOptimizerKeyValue -Label "Chave de recuperação" -Value $key.Password -Level Ok
        }
    }

    Write-Host ""

    if ($withKeys.Count -eq 0) {
        if ($encryptedWithout.Count -gt 0) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Há unidade criptografada sem chave de recuperação. Crie uma no Painel de Controle, em Criptografia de Unidade de Disco BitLocker > Fazer backup da chave de recuperação."
            $result = New-SnakeOptimizerResult -Kind Warning -Detail "unidade criptografada sem chave de recuperação"
        }
        else {
            Write-SnakeOptimizerStatus -Type Info -Message "Nenhuma unidade usa BitLocker neste PC: não há chave para guardar."
            $result = New-SnakeOptimizerResult -Kind Ok -Detail "nenhuma unidade com BitLocker"
        }

        Exit-SnakeOptimizerAction -Result $result
        return
    }

    $vault = Get-SnakeOptimizerBitLockerVaultConfig
    $vaultReady = ($vault.Enabled -and $vault.Url)

    if ($vaultReady) {
        Write-SnakeOptimizerStatus -Type Info -Notice -Message "Cofre configurado; último envio deste PC: $(Format-SnakeOptimizerVaultLastSent -LastSent $vault.LastSent)."
    }
    else {
        Write-SnakeOptimizerStatus -Type Info -Notice -Message "Guarde a chave fora deste PC: se o BitLocker pedir a chave, o PC não abre e uma cópia guardada nele não ajuda."
    }

    $options = @()
    if ($vaultReady) { $options += @{ Key = "C"; Label = "Enviar para o cofre"; Description = "Manda as chaves para a pasta do Nextcloud configurada na área técnica"; Accent = $true } }
    $options += @{ Key = "S"; Label = "Salvar em arquivo"; Description = "Um .txt na pasta que você escolher (pendrive, pasta de rede); não deixe no próprio PC"; Accent = (-not $vaultReady) }
    $options += @{ Key = "X"; Label = "Fechar"; Exit = $true }

    $done = @()

    while ($true) {
        $answer = Read-SnakeOptimizerChoice -Message "Guardar a chave" -Options $options -DefaultKey "X"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "X") { break }

        if ($answer -eq "C") {
            Write-Progress -Activity $title -Status "enviando para o cofre"
            $sent = Send-SnakeOptimizerBitLockerToVault -Volumes $withKeys
            Write-Progress -Activity $title -Completed

            if ($sent.Kind -eq "Ok") { Write-SnakeOptimizerStatus -Type Success -Message "Chave enviada para o cofre."; $done += "enviada ao cofre" }
            else { Write-SnakeOptimizerStatus -Type Error -Message "A chave $($sent.Detail)." }
        }
        elseif ($answer -eq "S") {
            $folder = Read-SnakeOptimizerText -Message "Pasta onde salvar (ENTER = Área de Trabalho)"
            if (-not $folder) { $folder = [Environment]::GetFolderPath("Desktop") }
            $folder = $folder.Trim('"')

            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                Write-SnakeOptimizerStatus -Type Error -Message "A pasta $folder não existe."
                continue
            }

            $path = Join-Path $folder (Get-SnakeOptimizerBitLockerFileName)
            [IO.File]::WriteAllText($path, (ConvertTo-SnakeOptimizerBitLockerKeyText -Volumes $withKeys), (New-Object Text.UTF8Encoding $true))
            Write-SnakeOptimizerStatus -Type Success -Message "Chave salva em $path."

            $systemRoot = ([string]$env:SystemDrive).TrimEnd('\').ToUpperInvariant()
            if ($path.ToUpperInvariant().StartsWith($systemRoot)) {
                Write-SnakeOptimizerStatus -Type Warning -Message "O arquivo está no próprio PC: copie para fora (pendrive, nuvem) e apague daqui."
            }

            $done += "salva em arquivo"
        }
    }

    $detail = $(if ($done.Count -gt 0) { "chave $(Join-SnakeOptimizerList -Items @($done | Select-Object -Unique))" } else { "chave mostrada" })
    Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Ok -Detail $detail)
}


function Invoke-SnakeOptimizerUnattendedBitLockerVault {
    # Tarefa "cofre-bitlocker" (manutenção automática e RMM): manda a chave ao cofre quando ela mudou. Sem cofre
    # configurado ou sem BitLocker, só registra e segue.
    $title = "Guardar a chave do BitLocker no cofre"

    $read = Get-SnakeOptimizerBitLockerKeys
    if (-not $read.Available) { return (New-SnakeOptimizerResult -Kind Skipped -Detail "BitLocker não disponível" -Title $title) }

    $sent = Send-SnakeOptimizerBitLockerToVault -Volumes $read.Volumes -OnlyIfChanged

    switch ($sent.Kind) {
        "Ok" { Write-SnakeOptimizerStatus -Type Success -Message "Chave do BitLocker guardada no cofre." }
        "Failed" { Write-SnakeOptimizerStatus -Type Error -Message "A chave do BitLocker $($sent.Detail)." }
        default { Write-SnakeOptimizerStatus -Type Info -Message "Cofre do BitLocker: $($sent.Detail)." }
    }

    return (New-SnakeOptimizerResult -Kind $sent.Kind -Detail $sent.Detail -Title $title)
}


function Invoke-SnakeOptimizerVaultSetup {
    # A parte do cofre na área técnica (a senha técnica já foi conferida por quem chama).
    while ($true) {
        $config = Get-SnakeOptimizerBitLockerVaultConfig
        $share = ConvertFrom-SnakeOptimizerNextcloudShareUrl -Url $config.Url

        Write-SnakeOptimizerSection -Title "Cofre das chaves do BitLocker"
        Write-SnakeOptimizerKeyValue -Label "Envio" -Value $(if ($config.Enabled -and $config.Url) { "ligado" } else { "desligado" }) -LabelWidth 30
        Write-SnakeOptimizerKeyValue -Label "Servidor" -Value $(if ($share) { $share.Base } else { "(não configurado)" }) -LabelWidth 30
        Write-SnakeOptimizerKeyValue -Label "Senha do link" -Value $(if ($config.Password) { "guardada (cifrada neste PC)" } else { "(sem senha)" }) -LabelWidth 30
        Write-SnakeOptimizerKeyValue -Label "Último envio deste PC" -Value (Format-SnakeOptimizerVaultLastSent -LastSent $config.LastSent) -LabelWidth 30
        Write-Host ""

        $options = @(
            @{ Key = "1"; Label = "Configurar o link do Nextcloud"; Description = "Link de uma pasta compartilhada com Solicitar arquivos (só envio)"; Accent = (-not $config.Url) },
            @{ Key = "2"; Label = "Enviar a chave deste PC agora"; Description = "Testa o link mandando as chaves deste PC" },
            @{ Key = "3"; Label = $(if ($config.Enabled) { "Desligar o envio" } else { "Ligar o envio" }); Description = "Com o envio ligado, a manutenção automática manda a chave quando ela muda" },
            @{ Key = "4"; Label = "Apagar o cofre deste PC"; Description = "Tira o link e a senha deste PC" },
            @{ Key = "X"; Label = "Voltar"; Exit = $true }
        )

        $answer = Read-SnakeOptimizerChoice -Message "Cofre do BitLocker" -Options $options -DefaultKey "X" -ShowMenu -TextPrompt "Opção (número, X = voltar)"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "X") { return }

        try {
            switch ($answer) {
                "1" {
                    Write-SnakeOptimizerStatus -Type Info -Notice -Message "No Nextcloud: crie uma pasta (ex.: Chaves BitLocker), Compartilhar > Compartilhar link > Solicitar arquivos (ou Permitir envio e edição). Quem tem o link só envia; não vê as chaves dos outros PCs."
                    $url = Read-SnakeOptimizerTechnicianField -Label "Link do compartilhamento" -Current $config.Url
                    if ($null -eq (ConvertFrom-SnakeOptimizerNextcloudShareUrl -Url $url)) {
                        Write-SnakeOptimizerStatus -Type Error -Message "Esse link não parece um compartilhamento do Nextcloud (https://servidor/s/codigo)."
                        continue
                    }

                    $secret = ConvertFrom-SnakeOptimizerSecureText -Secure (Read-Host -Prompt "Senha do link (vazio = sem senha ou manter a atual)" -AsSecureString)
                    if ($secret) { $config.Password = $secret }
                    if ($url -ne $config.Url) { $config.Fingerprint = "" }
                    $config.Url = $url
                    $config.Enabled = $true
                    Save-SnakeOptimizerBitLockerVaultConfig -Config $config
                    Write-SnakeOptimizerStatus -Type Success -Message "Cofre salvo. Use Enviar a chave deste PC agora para conferir."
                }
                "2" {
                    if (-not $config.Url) { Write-SnakeOptimizerStatus -Type Warning -Message "Configure o link primeiro."; continue }

                    $read = Get-SnakeOptimizerBitLockerKeys
                    if (-not $read.Available) { Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível ler o BitLocker: $($read.Problem)."; continue }

                    $withKeys = @($read.Volumes | Where-Object { @($_.Keys).Count -gt 0 })

                    if ($withKeys.Count -eq 0) {
                        # Sem chave neste PC, o teste manda um arquivo sem segredo nenhum, só para conferir o link.
                        $test = Send-SnakeOptimizerNextcloudFile -Url $config.Url -Password $config.Password -FileName "$($env:COMPUTERNAME)_teste-do-cofre.txt" -Text "Teste do cofre do SnakeOptimizer em $env:COMPUTERNAME ($(Format-SnakeOptimizerDateTime -When (Get-Date))). Este PC não tem BitLocker."
                        if ($test.Sent) { Write-SnakeOptimizerStatus -Type Success -Message "Link funcionando (este PC não tem BitLocker; foi um arquivo de teste)." }
                        else { Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível enviar: $($test.Problem)." }
                        continue
                    }

                    $wasEnabled = $config.Enabled
                    if (-not $wasEnabled) { $config.Enabled = $true; Save-SnakeOptimizerBitLockerVaultConfig -Config $config }
                    $sent = Send-SnakeOptimizerBitLockerToVault -Volumes $withKeys
                    if (-not $wasEnabled) { $current = Get-SnakeOptimizerBitLockerVaultConfig; $current.Enabled = $false; Save-SnakeOptimizerBitLockerVaultConfig -Config $current }

                    if ($sent.Kind -eq "Ok") { Write-SnakeOptimizerStatus -Type Success -Message "Chave enviada. Confira o arquivo na pasta do Nextcloud." }
                    else { Write-SnakeOptimizerStatus -Type Error -Message "A chave $($sent.Detail)." }
                }
                "3" {
                    $config.Enabled = -not [bool]$config.Enabled
                    Save-SnakeOptimizerBitLockerVaultConfig -Config $config
                    Write-SnakeOptimizerStatus -Type Success -Message $(if ($config.Enabled) { "Envio ligado." } else { "Envio desligado; o link continua guardado." })
                }
                "4" {
                    if (Confirm-SnakeOptimizerAction "Apagar o cofre deste PC?" -DefaultKey N) {
                        $path = Get-SnakeOptimizerBitLockerVaultPath
                        foreach ($file in @($path, "$path.bak")) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
                        Write-SnakeOptimizerStatus -Type Success -Message "Cofre apagado deste PC."
                    }
                }
            }
        }
        catch {
            Write-SnakeOptimizerStatus -Type Error -Message "$($_.Exception.Message)"
        }
    }
}


Export-ModuleMember -Function *
