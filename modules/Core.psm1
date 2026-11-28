# Núcleo: ambiente, sessão, registro, log, formatação e execução de programas nativos.
# Nada aqui desenha cabeçalhos ou faz perguntas; isso fica em Console.psm1.

$script:SnakeOptimizerBuild = "1.9.19"

# A trava dos arquivos de estado (Invoke-SnakeOptimizerStateLock): uma por sessão do Windows.
$script:SnakeOptimizerStateLockName = "Local\SnakeOptimizer.State"

# O build do Windows, lido uma vez (Get-SnakeOptimizerWindowsBuild).
$script:SnakeOptimizerWindowsBuild = 0
$script:SnakeOptimizerSession = $null
$script:SnakeOptimizerLastMaintenance = $null
$script:SnakeOptimizerLogPath = $null
$script:SnakeOptimizerLoggingActive = $false
# Transcript (console) ou Gui (o host da janela grava o log); Start-SnakeOptimizerLogging escolhe.
$script:SnakeOptimizerLogMode = ""

# Limites de Get-SnakeOptimizerDiskSpaceLevel. Na unidade do Windows, o que conta é o espaço que ele precisa para se
# atualizar (de 6 a 11 GB numa atualização de versão, mais no Windows 11): abaixo de 10 GB livres é "Critical"; abaixo de
# 20 GB, "Low". Nas outras unidades, a proporção: abaixo de 5% livres é "Critical"; abaixo de 10%, "Low".
$script:SnakeOptimizerCriticalDiskBytes = 10GB
$script:SnakeOptimizerLowDiskBytes = 20GB
$script:SnakeOptimizerLowDiskPercent = 10


# ---------------------------------------------------------------------------
# Versão e pasta de dados
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerBuild {
    return $script:SnakeOptimizerBuild
}


function Test-SnakeOptimizerGuiMode {
    # Verdadeiro dentro da janela: o executor das ações define $global:SnakeOptimizerGuiMode. A leitura não falha quando a
    # variável não existe (console), nem sob Set-StrictMode.
    $variable = Get-Variable -Name SnakeOptimizerGuiMode -Scope Global -ErrorAction SilentlyContinue

    return ($null -ne $variable -and [bool]$variable.Value)
}


function Get-SnakeOptimizerDataPath {
    # Local persistente para logs, backups de ajustes e relatórios (por usuário elevado).
    $root = Join-Path $env:LOCALAPPDATA "SnakeOptimizer"

    if (-not (Test-Path -LiteralPath $root)) {
        [void](New-Item -Path $root -ItemType Directory -Force)
    }

    return $root
}


# ---------------------------------------------------------------------------
# Arquivos de estado (JSON na pasta de dados)
# ---------------------------------------------------------------------------
# A janela, a ação em andamento (outro runspace do mesmo processo), o monitor na bandeja e a tarefa agendada leem e
# gravam os mesmos arquivos. Três regras evitam perder dados:
#   - gravar é atômico: um arquivo temporário com nome único e a troca pelo Windows (File.Replace), que guarda a versão
#     anterior em ".bak"; nunca há um instante em que o arquivo não existe;
#   - ler distingue "não existe" de "não deu para ler": um arquivo estragado volta do ".bak" (e a cópia estragada fica
#     guardada ao lado); um arquivo preso por outro processo faz a gravação desistir, em vez de gravar quase nada por cima;
#   - quem lê, altera e grava faz isso dentro da trava (Invoke-SnakeOptimizerStateLock).

function Open-SnakeOptimizerNamedMutex {
    <#
    Um mutex com nome que a janela elevada e a não elevada do mesmo usuário (e o monitor, nunca elevado) compartilham.
    Quem cria dá acesso total ao usuário (a conta elevada e a comum têm o mesmo SID). Quem chega depois num processo de
    nível de integridade menor (o monitor, quando foi a janela elevada que criou o mutex) não pode pedir acesso total:
    o Windows recusa "escrever para cima". Esse abre só com Synchronize e Modify, o que basta para esperar e soltar.
    $null quando nada deu certo.
    #>
    param ([Parameter(Mandatory)][string]$Name)

    try {
        $security = New-Object System.Security.AccessControl.MutexSecurity
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($user, [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
        $createdNew = $false
        return (New-Object System.Threading.Mutex($false, $Name, [ref]$createdNew, $security))
    }
    catch {
        # Existe e foi criado por um processo elevado (acesso total recusado), ou o sistema não tem essas permissões.
    }

    try {
        return [System.Threading.Mutex]::OpenExisting($Name, [System.Security.AccessControl.MutexRights]"Synchronize, Modify")
    }
    catch {
        # Não existe, ou a versão do .NET não tem esta forma de abrir.
    }

    try {
        return (New-Object System.Threading.Mutex($false, $Name))
    }
    catch {
        return $null
    }
}


function Invoke-SnakeOptimizerStateLock {
    # Roda o bloco com a trava dos arquivos de estado: um mutex com nome, da sessão do Windows, que a conta elevada e a
    # não elevada do mesmo usuário conseguem abrir. A trava é reentrante (uma função que já a tem pode chamar outra que
    # também a pede). Sem conseguir a trava em 5 segundos, segue sem ela: atrasar é aceitável, travar o SnakeOptimizer não.
    # As variáveis daqui têm nomes próprios: o bloco enxerga as da função que o chamou e não deve confundi-las com estas.
    param (
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $stateLockMutex = $null
    $stateLockOwned = $false

    try {
        $stateLockMutex = Open-SnakeOptimizerNamedMutex -Name $script:SnakeOptimizerStateLockName

        if ($null -ne $stateLockMutex) {
            try { $stateLockOwned = $stateLockMutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $stateLockOwned = $true }
        }

        return (& $ScriptBlock)
    }
    finally {
        if ($stateLockOwned) { $stateLockMutex.ReleaseMutex() }
        if ($null -ne $stateLockMutex) { $stateLockMutex.Dispose() }
    }
}


function Read-SnakeOptimizerStateFile {
    <#
    Lê um arquivo de estado JSON. Devolve Status e Document:
      Missing    - não existe: comece do zero (a gravação atômica nunca deixa o arquivo sumir; se ele não está lá, nunca
                   foi gravado ou alguém o apagou de propósito, e a cópia anterior não volta);
      Ok         - lido;
      Recovered  - o arquivo estava estragado e a cópia anterior (.bak) foi lida; o estragado fica guardado como
                   ".corrompido-<data>";
      Unreadable - existe, mas não deu para ler (preso por outro programa, sem permissão): quem grava deve desistir.
    Um arquivo estragado sem cópia anterior também é guardado ao lado e conta como Missing.
    #>
    param (
        [Parameter(Mandatory)][string]$Path
    )

    $backup = "$Path.bak"

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [PSCustomObject]@{ Status = "Missing"; Document = $null }
    }

    $text = $null

    # Outro processo pode estar no meio da troca do arquivo: tenta de novo algumas vezes antes de desistir.
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
            break
        }
        catch [System.IO.FileNotFoundException] {
            return (Read-SnakeOptimizerStateFile -Path $Path)
        }
        catch {
            if ($attempt -eq 4) { return [PSCustomObject]@{ Status = "Unreadable"; Document = $null } }
            Start-Sleep -Milliseconds (40 * $attempt)
        }
    }

    $document = ConvertFrom-SnakeOptimizerStateText -Text $text

    if ($null -ne $document) { return [PSCustomObject]@{ Status = "Ok"; Document = $document } }

    # Estragado (truncado, vazio, outro formato): guarda a cópia para quem quiser recuperar à mão e tenta a anterior.
    try {
        $stamp = (Get-Date).ToString("yyyyMMddHHmmss", [System.Globalization.CultureInfo]::InvariantCulture)
        Move-Item -LiteralPath $Path -Destination "$Path.corrompido-$stamp" -Force -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{ Status = "Unreadable"; Document = $null }
    }

    Remove-SnakeOptimizerOldCorruptCopies -Path $Path

    $fromBackup = ConvertFrom-SnakeOptimizerStateText -Path $backup

    if ($null -ne $fromBackup) {
        # A cópia anterior volta para o lugar do arquivo: quem lê primeiro quase nunca é quem grava (a janela, o Início, a
        # página), e sem isso a leitura seguinte veria o arquivo como inexistente, e a gravação seguinte trocaria a cópia
        # boa por uma quase vazia (o histórico de mudanças perderia o desfazer de vez).
        try {
            [System.IO.File]::Copy($backup, $Path, $false)
        }
        catch {
            Write-Verbose "Não foi possível repor a cópia de $($Path): $($_.Exception.Message)"
        }

        return [PSCustomObject]@{ Status = "Recovered"; Document = $fromBackup }
    }

    return [PSCustomObject]@{ Status = "Missing"; Document = $null }
}


function Remove-SnakeOptimizerOldCorruptCopies {
    # Guarda só as três cópias estragadas mais recentes de um arquivo de estado (".corrompido-<data>"): elas existem para
    # quem quiser recuperar algo à mão, e um arquivo que estraga sempre não pode encher a pasta.
    param ([Parameter(Mandatory)][string]$Path)

    try {
        $folder = Split-Path -Path $Path -Parent
        $name = Split-Path -Path $Path -Leaf
        $copies = @(Get-ChildItem -LiteralPath $folder -Filter "$name.corrompido-*" -File -ErrorAction Stop | Sort-Object -Property Name -Descending)

        foreach ($old in @($copies | Select-Object -Skip 3)) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Verbose "Cópias estragadas de $($Path): $($_.Exception.Message)"
    }
}


function ConvertFrom-SnakeOptimizerStateText {
    # O JSON de um texto (ou de um arquivo, com -Path), ou $null se não for um JSON com conteúdo.
    param (
        [AllowNull()][string]$Text = $null,
        [string]$Path = ""
    )

    try {
        if ($Path) {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
            $Text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        }

        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

        $document = $Text | ConvertFrom-Json -ErrorAction Stop

        # Uma lista JSON vazia é um conteúdo válido; $null não.
        if ($null -eq $document -and $Text.Trim() -ne "[]") { return $null }
        if ($Text.Trim() -eq "[]") { return , @() }

        return $document
    }
    catch {
        return $null
    }
}


function Write-SnakeOptimizerStateFile {
    # Grava o texto (UTF-8 com BOM, como o Set-Content do Windows PowerShell) de forma atômica: escreve um temporário com
    # nome único na mesma pasta e troca pelo arquivo, guardando o anterior em ".bak". Lança erro se não conseguir.
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $temporary = "$Path.$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"

    try {
        [System.IO.File]::WriteAllText($temporary, $Text, (New-Object System.Text.UTF8Encoding($true)))

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Path, "$Path.bak", $true)
        }
        else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}


function Write-SnakeOptimizerStateJson {
    # Write-SnakeOptimizerStateFile de um objeto. Uma lista continua lista no JSON mesmo com um item só (-AsList).
    param (
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$InputObject,
        [int]$Depth = 6,
        [switch]$AsList
    )

    $json = $(if ($AsList) { ConvertTo-Json -InputObject @($InputObject) -Depth $Depth } else { ConvertTo-Json -InputObject $InputObject -Depth $Depth })

    # Uma lista vazia vira "" no ConvertTo-Json do Windows PowerShell.
    if ($AsList -and [string]::IsNullOrWhiteSpace($json)) { $json = "[]" }

    Write-SnakeOptimizerStateFile -Path $Path -Text $json
}


# ---------------------------------------------------------------------------
# Preferências do SnakeOptimizer (settings.json)
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerSettingsPath {
    return (Join-Path (Get-SnakeOptimizerDataPath) "settings.json")
}


function Get-SnakeOptimizerSettings {
    # Todas as preferências como hashtable. Arquivo ausente ou ilegível = nenhuma preferência (um arquivo estragado volta
    # da cópia anterior, ver Read-SnakeOptimizerStateFile). -Status devolve também o estado da leitura, para quem vai gravar.
    param ([switch]$Status)

    $settings = @{}
    $read = [PSCustomObject]@{ Status = "Unreadable"; Document = $null }

    try {
        $read = Read-SnakeOptimizerStateFile -Path (Get-SnakeOptimizerSettingsPath)

        if ($null -ne $read.Document) {
            foreach ($property in $read.Document.PSObject.Properties) {
                $settings[[string]$property.Name] = $property.Value
            }
        }
    }
    catch {
        $settings = @{}
    }

    if ($Status) { return [PSCustomObject]@{ Status = $read.Status; Settings = $settings } }

    return $settings
}


function Get-SnakeOptimizerSetting {
    param (
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    $settings = Get-SnakeOptimizerSettings

    if ($settings.ContainsKey($Name) -and $null -ne $settings[$Name]) {
        return $settings[$Name]
    }

    return $Default
}


function Get-SnakeOptimizerLastCheckup {
    # Quando o Verificar o PC rodou pela última vez (a preferência LastCheckup, gravada no fim dele), ou $null. O Início e
    # o monitor contam essa data como um cuidado com o PC, assim como a última manutenção. -Strict: preferências que
    # existem, mas não puderam ser lidas, são um erro, e não "nunca verificou".
    param ([switch]$Strict)

    $read = Get-SnakeOptimizerSettings -Status

    if ($Strict -and [string]$read.Status -eq "Unreadable") { throw "As preferências do SnakeOptimizer existem, mas não puderam ser lidas." }

    $value = $(if ($read.Settings.ContainsKey("LastCheckup") -and $null -ne $read.Settings["LastCheckup"]) { $read.Settings["LastCheckup"] } else { "" })

    if ($value -is [datetime]) { return $value }

    $when = [datetime]::MinValue

    if ([string]$value -and [datetime]::TryParse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$when)) {
        return $when
    }

    return $null
}


function Set-SnakeOptimizerSetting {
    # Grava uma preferência (valor simples, hashtable ou lista) sem perder as outras. Falha em silêncio: uma
    # preferência que não pôde ser salva nunca deve interromper uma ação.
    param (
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Value
    )

    try {
        return [bool](Invoke-SnakeOptimizerStateLock -ScriptBlock {
                $current = Get-SnakeOptimizerSettings -Status

                # Sem conseguir ler o que já está gravado, gravar agora apagaria as outras preferências.
                if ($current.Status -eq "Unreadable") { return $false }

                $settings = $current.Settings
                $settings[$Name] = $Value

                $ordered = [ordered]@{}
                foreach ($key in ($settings.Keys | Sort-Object)) { $ordered[$key] = $settings[$key] }

                Write-SnakeOptimizerStateJson -Path (Get-SnakeOptimizerSettingsPath) -InputObject $ordered -Depth 5
                return $true
            })
    }
    catch {
        return $false
    }
}


# ---------------------------------------------------------------------------
# Privilégios e sessão
# ---------------------------------------------------------------------------

function Test-SnakeOptimizerAdministrator {
    # Se não for possível verificar (sistema que não é Windows, identidade indisponível), vale "não é administrador":
    # é o lado seguro, e as ações que exigem elevação recusam em vez de falhar no meio.
    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}


function ConvertTo-SnakeOptimizerCommandLineArgument {
    # Protege um valor para a linha de comando do Windows (regras do CommandLineToArgvW). Sem isso, um caminho que
    # termina em barra invertida ("C:\Relatorios\") faz a barra escapar a aspa final e engole os argumentos seguintes.
    param (
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')

    return '"' + $escaped + '"'
}


function Restart-SnakeOptimizerAsAdministrator {
    # Relança o script do console como Administrador (UAC) e encerra esta instância.
    param (
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [string[]]$ExtraArguments = @()
    )

    if (Test-SnakeOptimizerAdministrator) {
        return
    }

    # Sem o cabeçalho (ele limparia a tela de quem digitou o comando num terminal) e sem o "Sem privilégios" vermelho:
    # só o que vai acontecer e o que fazer.
    # Aberto pelo SnakeOptimizer-Console.cmd, quem pausa no fim é o .cmd (uma pausa só). A janela nova, elevada, não tem o
    # .cmd em volta: a marca sai do ambiente antes de abri-la, para ela mesma pausar.
    $fromCmd = ($env:SNAKEOPTIMIZER_FROM_CMD -eq "1")
    Remove-Item -Path Env:SNAKEOPTIMIZER_FROM_CMD -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "  O SnakeOptimizer precisa da permissão de Administrador para cuidar do PC." -ForegroundColor Yellow
    Write-Host "  Clique em Sim no aviso do Windows: o SnakeOptimizer continua numa janela nova." -ForegroundColor Cyan
    Write-Host ""

    Start-Sleep -Seconds 2

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Host "  Não foi possível identificar o caminho do script principal." -ForegroundColor Red
        Write-Host "  Execute o SnakeOptimizer a partir de um arquivo .ps1 salvo." -ForegroundColor Yellow
        Write-Host ""
        if (-not $fromCmd) { Wait-SnakeOptimizerKey }
        exit 1
    }

    # Reabre com o mesmo PowerShell que está em uso (Windows PowerShell 5.1 ou PowerShell 7).
    $hostExecutable = (Get-Process -Id $PID).Path

    if ([string]::IsNullOrWhiteSpace($hostExecutable)) {
        $hostExecutable = "powershell.exe"
    }

    $argumentText = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

    if (@($ExtraArguments).Count -gt 0) {
        $argumentText += " " + (@($ExtraArguments) -join " ")
    }

    try {
        Start-Process -FilePath $hostExecutable -ArgumentList $argumentText -Verb RunAs
    }
    catch {
        # UAC recusado ou bloqueado por política: não há o que fazer além de avisar. O código de saída diz que nada foi
        # feito (um script que chamou o SnakeOptimizer-Console.cmd não deve achar que o relatório saiu).
        Write-Host "  Sem a permissão de Administrador, o SnakeOptimizer não pode continuar no terminal." -ForegroundColor Red
        Write-Host "  Abra o SnakeOptimizer-Console.cmd de novo e clique em Sim no aviso do Windows." -ForegroundColor Yellow
        Write-Host ""
        if (-not $fromCmd) { Wait-SnakeOptimizerKey }
        exit 1
    }

    exit 0
}


function Get-SnakeOptimizerSessionShellUser {
    <#
    A conta dona do Explorador (explorer.exe) nesta sessão do Windows, como "DOMINIO\conta"; "" sem leitura (o Explorador
    não está aberto, a consulta falhou). É quem está usando o PC nesta sessão, também por Área de Trabalho Remota: o
    Win32_ComputerSystem.UserName diz só quem está no console (na frente do monitor), outra pessoa ou ninguém.
    #>
    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $shell = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe' AND SessionId = $sessionId" -ErrorAction Stop) | Select-Object -First 1

        if ($null -eq $shell) { return "" }

        $owner = Invoke-CimMethod -InputObject $shell -MethodName GetOwner -ErrorAction Stop
        $user = [string](Get-SnakeOptimizerJsonValue -Object $owner -Name "User" -Default "")
        $domain = [string](Get-SnakeOptimizerJsonValue -Object $owner -Name "Domain" -Default "")

        if ([int](Get-SnakeOptimizerJsonValue -Object $owner -Name "ReturnValue" -Default 1) -ne 0 -or [string]::IsNullOrWhiteSpace($user)) { return "" }

        return $(if ([string]::IsNullOrWhiteSpace($domain)) { $user.Trim() } else { "$($domain.Trim())\$($user.Trim())" })
    }
    catch {
        return ""
    }
}


function Get-SnakeOptimizerInteractiveUser {
    # Quem está usando o PC: o dono do Explorador desta sessão (vale também na Área de Trabalho Remota) e, sem ele, quem
    # está no console. "" sem leitura.
    $shellUser = Get-SnakeOptimizerSessionShellUser

    if (-not [string]::IsNullOrWhiteSpace($shellUser)) { return $shellUser }

    try {
        $interactiveUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName

        if (-not [string]::IsNullOrWhiteSpace($interactiveUser)) {
            return $interactiveUser.Trim()
        }
    }
    catch {
        # Informação auxiliar; não bloqueia a execução.
    }

    return ""
}


function Test-SnakeOptimizerUserContextMismatch {
    # Verdadeiro quando o SnakeOptimizer foi elevado com outra conta que não a do usuário logado.
    # Nesse caso, HKCU, %LOCALAPPDATA% e Downloads pertencem ao administrador, não ao usuário interativo.
    $interactiveUser = Get-SnakeOptimizerInteractiveUser

    if ([string]::IsNullOrWhiteSpace($interactiveUser)) {
        return $false
    }

    try {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        return -not $currentUser.Equals($interactiveUser, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}


function Test-SnakeOptimizerLaptop {
    # O chassi decide primeiro (SMBIOS ChassisTypes): portátil é notebook; gabinete de mesa não é, mesmo com "bateria" (um
    # nobreak USB aparece como bateria no Windows). Só com o chassi desconhecido a bateria desempata.
    $portableTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $desktopTypes = @(3, 4, 5, 6, 7, 13, 15, 16, 17, 23, 24, 25, 28, 29, 34, 35, 36)

    try {
        $chassis = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })

        if (@($chassis | Where-Object { $portableTypes -contains $_ }).Count -gt 0) { return $true }
        if (@($chassis | Where-Object { $desktopTypes -contains $_ }).Count -gt 0) { return $false }
    }
    catch {
        # Segue para a bateria.
    }

    try {
        return (@(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0)
    }
    catch {
        # Sem informação: assume desktop.
        return $false
    }
}


function Test-SnakeOptimizerOnBattery {
    # $true quando o notebook está funcionando na bateria (BatteryStatus 1 = descarregando, 4 = baixa, 5 = crítica).
    # Desktop, tomada conectada e falha na consulta dão $false: na dúvida, o SnakeOptimizer não atrapalha o usuário.
    try {
        $batteries = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        return (@($batteries | Where-Object { [int]$_.BatteryStatus -in 1, 4, 5 }).Count -gt 0)
    }
    catch {
        return $false
    }
}


function Test-SnakeOptimizerMeteredConnection {
    <#
    $true quando a conexão com a internet é limitada (o Windows a trata como plano de dados: celular roteado, chip,
    rede marcada como limitada nas Configurações), ou quando o plano está perto do limite, acabou ou em roaming. O próprio
    Windows não baixa atualizações sozinho numa conexão assim; quem baixa pelo SnakeOptimizer fica sabendo antes. Sem a
    informação (Windows sem a API, consulta que falhou), $false: na dúvida, o SnakeOptimizer não atrapalha.
    #>
    try {
        $network = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime]
        $connection = $network::GetInternetConnectionProfile()

        if ($null -eq $connection) { return $false }

        $cost = $connection.GetConnectionCost()

        return ([string]$cost.NetworkCostType -in @("Fixed", "Variable") -or [bool]$cost.ApproachingDataLimit -or [bool]$cost.OverDataLimit -or [bool]$cost.Roaming)
    }
    catch {
        return $false
    }
}


function Get-SnakeOptimizerSystemDriveFreeBytes {
    # Espaço livre na unidade do Windows, em bytes; -1 quando não for possível saber.
    try {
        $root = [IO.Path]::GetPathRoot($env:SystemRoot)
        return [int64](New-Object System.IO.DriveInfo $root).AvailableFreeSpace
    }
    catch {
        return -1
    }
}


function Get-SnakeOptimizerSystemDriveSpace {
    # Espaço livre e total da unidade do Windows, em bytes; $null quando não for possível ler.
    try {
        $root = [IO.Path]::GetPathRoot($env:SystemRoot)

        if ([string]::IsNullOrWhiteSpace($root)) {
            return $null
        }

        $drive = New-Object System.IO.DriveInfo $root

        return [PSCustomObject]@{
            FreeBytes  = [int64]$drive.AvailableFreeSpace
            TotalBytes = [int64]$drive.TotalSize
        }
    }
    catch {
        return $null
    }
}


function Format-SnakeOptimizerPreciseBytes {
    # O espaço livre com duas casas ("446,30 GB"): no antes e depois, os três algarismos de Format-SnakeOptimizerBytes
    # mostrariam "446 GB" e "446 GB" para uma limpeza de 100 MB.
    param ([int64]$Bytes)

    $culture = [Globalization.CultureInfo]::GetCultureInfo("pt-BR")
    if ($Bytes -ge 1GB) { return "$(([double]$Bytes / 1GB).ToString('N2', $culture)) GB" }
    return "$(([double]$Bytes / 1MB).ToString('N0', $culture)) MB"
}


function Format-SnakeOptimizerFreeSpaceText {
    # "45,20 GB livres (9% do disco)": o espaço livre com a proporção do disco, para o antes e depois.
    param (
        [int64]$FreeBytes,
        [int64]$TotalBytes = 0
    )

    $text = "$(Format-SnakeOptimizerPreciseBytes -Bytes $FreeBytes) livres"
    if ($TotalBytes -gt 0) { $text += " ($([int][Math]::Round($FreeBytes * 100.0 / $TotalBytes))% do disco)" }
    return $text
}


function Format-SnakeOptimizerSpaceDelta {
    # "+1,8 GB" / "-300 MB"; menos de 1 MB conta como "sem mudança".
    param ([int64]$Delta)

    if ([Math]::Abs($Delta) -lt 1MB) { return "sem mudança" }
    return "$(if ($Delta -gt 0) { '+' } else { '-' })$(Format-SnakeOptimizerBytes -Bytes ([Math]::Abs($Delta)))"
}


function Get-SnakeOptimizerSpaceLogPath {
    return (Join-Path (Get-SnakeOptimizerDataPath) "espaco-historico.json")
}


function Get-SnakeOptimizerSpaceLog {
    <#
    O histórico de espaço das limpezas e otimizações rodadas sozinhas (fora do Otimizar, que tem o próprio histórico):
    At, Title, FreeBefore, FreeAfter, TotalBytes e Reported (o que a ação contou como liberado; $null quando ela não
    conta). Da mais recente para a mais antiga; vazio quando não há ou não dá para ler.
    #>
    try {
        $state = Read-SnakeOptimizerStateFile -Path (Get-SnakeOptimizerSpaceLogPath)
        if ($null -eq $state.Document) { return @() }

        return @(
            foreach ($row in @($state.Document)) {
                try {
                    [PSCustomObject]@{
                        At         = [datetime]::Parse([string]$row.At, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                        Title      = [string]$row.Title
                        FreeBefore = [int64]$row.FreeBefore
                        FreeAfter  = [int64]$row.FreeAfter
                        TotalBytes = [int64](Get-SnakeOptimizerJsonValue -Object $row -Name "TotalBytes" -Default 0)
                        Reported   = $(if ($null -ne (Get-SnakeOptimizerJsonValue -Object $row -Name "Reported")) { [int64]$row.Reported } else { $null })
                    }
                }
                catch { }
            }
        )
    }
    catch {
        return @()
    }
}


function Add-SnakeOptimizerSpaceLogEntry {
    # Grava o antes e depois de uma ação no histórico de espaço (as últimas 60). Devolve $true se gravou.
    param (
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After,
        $Reported = $null
    )

    try {
        $entry = [ordered]@{
            At         = (Get-Date).ToString("o", [Globalization.CultureInfo]::InvariantCulture)
            Title      = $Title
            FreeBefore = [int64]$Before.FreeBytes
            FreeAfter  = [int64]$After.FreeBytes
            TotalBytes = [int64]$After.TotalBytes
            Reported   = $(if ($null -ne $Reported) { [int64]$Reported } else { $null })
        }

        $rows = @(
            $entry
            foreach ($old in @(Get-SnakeOptimizerSpaceLog | Select-Object -First 59)) {
                [ordered]@{
                    At = $old.At.ToString("o", [Globalization.CultureInfo]::InvariantCulture); Title = $old.Title
                    FreeBefore = $old.FreeBefore; FreeAfter = $old.FreeAfter; TotalBytes = $old.TotalBytes; Reported = $old.Reported
                }
            }
        )

        Write-SnakeOptimizerStateJson -Path (Get-SnakeOptimizerSpaceLogPath) -InputObject $rows -AsList
        return $true
    }
    catch {
        return $false
    }
}


function Get-SnakeOptimizerDiskSpaceLevel {
    <#
    Classifica o espaço livre de uma unidade com uma regra só, usada pela tela inicial, pela lista de discos e pela
    checagem da Manutenção. Na unidade do Windows, em gigabytes, e não em proporção: "Critical" = menos de 10 GB livres
    (pouco para uma atualização de versão do Windows) e "Low" = menos de 20 GB. Uma proporção acusaria um disco de 2 TB
    com 150 GB livres e deixaria passar um de 64 GB com 7 GB. Numa unidade que não é a do sistema (-System $false), os
    gigabytes não valem (um pen drive de 8 GB com 4 GB livres não está em perigo): "Critical" é menos de 5% livres e
    "Low", menos de 10%. "Ok" nos demais casos; sem dados válidos (valor negativo ou nulo), "Unknown".
    #>
    param (
        [object]$FreeBytes,
        [object]$TotalBytes,
        [bool]$System = $true
    )

    # Um valor que não é número deixa o padrão (livre desconhecido = -1, total desconhecido = 0): TryParse zera a saída
    # quando falha, e "0 bytes livres" seria lido como disco crítico.
    $free = [double]-1
    $total = [double]0
    $parsed = [double]0
    $style = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    if ($null -ne $FreeBytes -and [double]::TryParse(([string]$FreeBytes), $style, $culture, [ref]$parsed)) { $free = $parsed }
    if ($null -ne $TotalBytes -and [double]::TryParse(([string]$TotalBytes), $style, $culture, [ref]$parsed)) { $total = $parsed }

    if ($free -lt 0) { return "Unknown" }

    if ($System) {
        if ($free -lt $script:SnakeOptimizerCriticalDiskBytes) { return "Critical" }
        if ($free -lt $script:SnakeOptimizerLowDiskBytes) { return "Low" }
        return "Ok"
    }

    if ($total -le 0) { return "Unknown" }
    if ((($free * 100) / $total) -lt 5) { return "Critical" }
    if ((($free * 100) / $total) -lt $script:SnakeOptimizerLowDiskPercent) { return "Low" }

    return "Ok"
}


function Get-SnakeOptimizerRegistryWindowsBuild {
    # A build pelo Registro (CurrentBuildNumber), sem o WMI; 0 sem leitura.
    $value = Get-SnakeOptimizerRegistryValueOrNull -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name "CurrentBuildNumber"
    $parsed = 0

    if ($null -ne $value -and [int]::TryParse(([string]$value).Trim(), [ref]$parsed) -and $parsed -gt 0) { return $parsed }

    return 0
}


function Get-SnakeOptimizerWindowsBuild {
    # O build não muda com o SnakeOptimizer aberto: a primeira leitura fica guardada (a lista de ajustes pergunta uma vez por
    # ajuste, e cada pergunta era uma consulta ao Windows).
    if ($script:SnakeOptimizerWindowsBuild -gt 0) { return $script:SnakeOptimizerWindowsBuild }

    try {
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $build = [int]$operatingSystem.BuildNumber
    }
    catch {
        $build = Get-SnakeOptimizerRegistryWindowsBuild
        if ($build -le 0) { $build = [int][Environment]::OSVersion.Version.Build }
    }

    if ($build -gt 0) { $script:SnakeOptimizerWindowsBuild = $build }

    return $build
}


function Test-SnakeOptimizerWindows11 {
    return (Get-SnakeOptimizerWindowsBuild) -ge 22000
}


function Get-SnakeOptimizerWindowsName {
    # "Microsoft Windows 11 Pro" vira "Windows 11 Pro". Em alguns PCs atualizados do 10 para o 11 o nome ainda diz
    # "Windows 10"; a build decide. A tela inicial, o Diagnóstico e o relatório mostram este mesmo nome.
    param (
        [AllowEmptyString()][string]$Caption = "",
        [int]$Build = 0
    )

    $name = ([string]$Caption -replace '^\s*Microsoft\s+', '').Trim()

    if ($Build -ge 22000) { $name = $name -replace '\bWindows 10\b', 'Windows 11' }

    return $name
}


function Get-SnakeOptimizerWindowsDisplayVersion {
    # A versão de mercado (24H2, 23H2...): DisplayVersion desde o 20H2; antes, ReleaseId (2004, 1909...). "" sem leitura.
    try {
        $current = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop

        return [string](Get-SnakeOptimizerJsonValue -Object $current -Name "DisplayVersion" -Default (Get-SnakeOptimizerJsonValue -Object $current -Name "ReleaseId" -Default ""))
    }
    catch {
        return ""
    }
}


function Get-SnakeOptimizerSessionInfo {
    param (
        [switch]$Refresh
    )

    if ($null -ne $script:SnakeOptimizerSession -and -not $Refresh) {
        return $script:SnakeOptimizerSession
    }

    $build = 0
    $windowsLabel = "Windows"
    $caption = ""

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $build = [int]$os.BuildNumber
        $windowsLabel = if ($build -ge 22000) { "Windows 11" } else { "Windows 10" }
        $caption = Get-SnakeOptimizerWindowsName -Caption ([string](Get-SnakeOptimizerJsonValue -Object $os -Name "Caption" -Default "")) -Build $build
    }
    catch {
        # Sem o WMI (o serviço parado ou com defeito), a build ainda vem do Registro: sem ela, o Início não saberia o
        # suporte do Windows. O nome completo fica de fora.
        $build = Get-SnakeOptimizerRegistryWindowsBuild
        if ($build -gt 0) { $windowsLabel = $(if ($build -ge 22000) { "Windows 11" } else { "Windows 10" }) }
    }

    # Sem a versão, o cartão mostra só o nome e a build.
    $version = Get-SnakeOptimizerWindowsDisplayVersion

    try {
        $script:SnakeOptimizerSession = [PSCustomObject]@{
            IsAdmin        = Test-SnakeOptimizerAdministrator
            User           = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            UserMismatch   = Test-SnakeOptimizerUserContextMismatch
            IsLaptop       = Test-SnakeOptimizerLaptop
            WindowsLabel   = $windowsLabel
            WindowsBuild   = $build
            WindowsName    = $caption
            WindowsVersion = $version
        }
    }
    catch {
        # As informações de sessão são auxiliares; nunca devem impedir a exibição de uma tela.
        $script:SnakeOptimizerSession = [PSCustomObject]@{
            IsAdmin        = $false
            User           = $env:USERNAME
            UserMismatch   = $false
            IsLaptop       = $false
            WindowsLabel   = $windowsLabel
            WindowsBuild   = $build
            WindowsName    = $caption
            WindowsVersion = $version
        }
    }

    return $script:SnakeOptimizerSession
}


# ---------------------------------------------------------------------------
# Ambiente e log
# ---------------------------------------------------------------------------

function Set-SnakeOptimizerConsoleEncoding {
    # Garante melhor exibição de acentos no Windows PowerShell 5.1 e em consoles legados.
    try {
        $utf8Encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
        # As duas propriedades já trocam a página de código do console (SetConsoleCP e SetConsoleOutputCP), o que o
        # chcp 65001 fazia de novo.
        [Console]::InputEncoding = $utf8Encoding
        [Console]::OutputEncoding = $utf8Encoding
        $global:OutputEncoding = $utf8Encoding
    }
    catch {
        # Não bloqueia a execução caso o console não permita alteração de encoding.
    }
}


function Enable-SnakeOptimizerTls12 {
    # O Windows PowerShell 5.1 em alguns sistemas só negocia TLS 1.0/1.1, que os servidores atuais recusam.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # Sem a enumeração (ambientes antigos): segue com o padrão do sistema.
    }
}


function Test-SnakeOptimizerTcpConnection {
    # Abre e fecha uma conexão TCP. Mostra se a internet responde mesmo quando o ping (ICMP) é bloqueado.
    # Nunca lança erro: tempo esgotado, recusa ou nome inválido dão $false.
    param (
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [ValidateRange(1, 65535)]
        [int]$Port = 443,

        [ValidateRange(100, 30000)]
        [int]$TimeoutMilliseconds = 2000
    )

    $client = New-Object System.Net.Sockets.TcpClient

    try {
        $attempt = $client.BeginConnect($ComputerName, $Port, $null, $null)

        if (-not $attempt.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }

        $client.EndConnect($attempt)

        return [bool]$client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}


function Test-SnakeOptimizerDnsResolution {
    # Verdadeiro se o nome vira ao menos um endereço IP. Nunca lança erro: nome inexistente ou DNS fora do ar dão $false.
    param (
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        return (@([System.Net.Dns]::GetHostAddresses($Name)).Count -gt 0)
    }
    catch {
        return $false
    }
}


function Initialize-SnakeOptimizerEnvironment {
    Set-SnakeOptimizerConsoleEncoding
    Enable-SnakeOptimizerTls12
}


function Get-SnakeOptimizerGuiHostUI {
    # A interface do host da janela (SnakeOptimizer.GuiHostUI), que grava o log das ações; $null fora da janela.
    if (-not (Test-SnakeOptimizerGuiMode)) { return $null }

    $variable = Get-Variable -Name SnakeOptimizerGuiHost -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $variable -or $null -eq $variable.Value) { return $null }

    try { return $variable.Value.GuiUI } catch { return $null }
}


function Start-SnakeOptimizerLogging {
    <#
    Abre o log da sessão em %LOCALAPPDATA%\SnakeOptimizer\logs (os 20 mais recentes ficam). Idempotente: chamar de novo com o
    log ativo não abre um segundo. No console, é o transcript do PowerShell; na janela, o próprio host grava cada linha
    que as ações escrevem, com a hora: o transcript não vê o que passa pelo host da janela, e o log ficava vazio.
    #>
    if ($script:SnakeOptimizerLoggingActive) {
        return $true
    }

    try {
        $logDirectory = Join-Path (Get-SnakeOptimizerDataPath) "logs"

        if (-not (Test-Path -LiteralPath $logDirectory)) {
            [void](New-Item -Path $logDirectory -ItemType Directory -Force)
        }

        # Mantém apenas os 20 logs mais recentes.
        Get-ChildItem -LiteralPath $logDirectory -Filter "snakeoptimizer-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 20 |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $script:SnakeOptimizerLogPath = Join-Path $logDirectory ("snakeoptimizer-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
        $gui = Get-SnakeOptimizerGuiHostUI

        if ($null -ne $gui -and $null -ne $gui.PSObject.Methods["OpenLog"]) {
            $header = "SnakeOptimizer Build $($script:SnakeOptimizerBuild) - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $env:COMPUTERNAME - PowerShell $($PSVersionTable.PSVersion)"
            if (-not $gui.OpenLog($script:SnakeOptimizerLogPath, $header)) { throw "o log não pôde ser aberto" }
            $script:SnakeOptimizerLogMode = "Gui"
        }
        else {
            [void](Start-Transcript -Path $script:SnakeOptimizerLogPath -Force)
            $script:SnakeOptimizerLogMode = "Transcript"
        }

        $script:SnakeOptimizerLoggingActive = $true
        return $true
    }
    catch {
        $script:SnakeOptimizerLogPath = $null
        return $false
    }
}


function Stop-SnakeOptimizerLogging {
    try {
        if ($script:SnakeOptimizerLoggingActive) {
            if ($script:SnakeOptimizerLogMode -eq "Gui") {
                $gui = Get-SnakeOptimizerGuiHostUI
                if ($null -ne $gui) { $gui.CloseLog() }
            }
            else {
                [void](Stop-Transcript)
            }
        }
    }
    catch {
        # O log pode não estar ativo.
    }

    $script:SnakeOptimizerLoggingActive = $false
}


function Get-SnakeOptimizerLogPath {
    return $script:SnakeOptimizerLogPath
}


function Get-SnakeOptimizerLatestLogFile {
    # O log mais recente da pasta de logs (a janela e as ações gravam logs em sessões separadas, então o caminho em
    # memória não serve para a janela). $null quando ainda não há nenhum.
    try {
        $directory = Join-Path (Get-SnakeOptimizerDataPath) "logs"

        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            return $null
        }

        $latest = Get-ChildItem -LiteralPath $directory -Filter "snakeoptimizer-*.log" -File -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -eq $latest) { return $null }

        return $latest.FullName
    }
    catch {
        return $null
    }
}


# ---------------------------------------------------------------------------
# Registro
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerRegistryValueOrNull {
    param (
        [string]$Path,
        [string]$Name
    )

    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch {
        return $null
    }
}


function Set-SnakeOptimizerRegistryDWord {
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$Value
    )

    # -ErrorAction Stop: com a preferência padrão (Continue), um "acesso negado" só escreveria um erro e quem chamou
    # seguiria como se o valor tivesse sido gravado (anotando no Histórico e guardando backup de algo que não mudou).
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -Path $Path -Force -ErrorAction Stop)
    }

    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop)
}


function Set-SnakeOptimizerRegistryBinary {
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [byte[]]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -Path $Path -Force -ErrorAction Stop)
    }

    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType Binary -Force -ErrorAction Stop)
}


function Get-SnakeOptimizerRegistryValueKind {
    # O tipo de um valor de registro, como o Windows o guarda (DWord, QWord, String, ExpandString, MultiString, Binary...),
    # ou "" quando o valor não existe ou não pôde ser lido.
    param (
        [string]$Path,
        [string]$Name
    )

    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop

        if (@($key.GetValueNames()) -notcontains $Name) {
            return ""
        }

        return [string]$key.GetValueKind($Name)
    }
    catch {
        return ""
    }
}


function Set-SnakeOptimizerRegistryValue {
    # Grava um valor com o tipo dado (o de Get-SnakeOptimizerRegistryValueKind), para devolver um valor ao que era: um texto
    # volta como texto, não como número. Tipos que o PowerShell não grava (None, Unknown) voltam como binário.
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Kind,

        [AllowNull()]
        $Value
    )

    if ($Kind -eq "DWord") {
        $data = [int]$Value
    }
    elseif ($Kind -eq "QWord") {
        $data = [int64]$Value
    }
    elseif ($Kind -eq "MultiString") {
        $data = [string[]]@($Value | Where-Object { $null -ne $_ })
    }
    elseif ($Kind -eq "String" -or $Kind -eq "ExpandString") {
        $data = [string]$Value
    }
    else {
        $Kind = "Binary"
        $data = [byte[]]@($Value | Where-Object { $null -ne $_ })
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -Path $Path -Force -ErrorAction Stop)
    }

    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $data -PropertyType $Kind -Force -ErrorAction Stop)
}


function Get-SnakeOptimizerRegistryValues {
    # Todos os valores nomeados de uma chave (nome -> valor), na ordem do registro. Chave ausente ou sem acesso = vazio.
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $values = [ordered]@{}

    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop

        foreach ($name in $key.GetValueNames()) {
            if (-not [string]::IsNullOrEmpty($name)) {
                $values[$name] = $key.GetValue($name)
            }
        }
    }
    catch {
        # Sem a chave, não há valores.
    }

    return $values
}


function Remove-SnakeOptimizerRegistryValue {
    # Remove um valor de registro. Só "a chave ou o valor já não existem" não é erro: sem permissão, o valor continua lá e
    # quem chamou precisa saber (desfazer um ajuste não pode dizer que voltou ao original sem ter voltado).
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $key = Get-Item -LiteralPath $Path -ErrorAction Stop

    if (@($key.GetValueNames()) -notcontains $Name) {
        return
    }

    Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
}


function Test-SnakeOptimizerRegistryKey {
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    return [bool](Test-Path -LiteralPath $Path -PathType Container)
}


function Set-SnakeOptimizerRegistryKeyDefault {
    # Cria a chave (e as de cima) e define o valor padrão dela como texto.
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Value = ""
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -Path $Path -Force -ErrorAction Stop)
    }

    Set-ItemProperty -LiteralPath $Path -Name "(default)" -Value $Value -ErrorAction Stop
}


function Remove-SnakeOptimizerRegistryKey {
    # Remove a chave com tudo o que há dentro; com -OnlyIfEmpty, só se não tiver subchaves nem valores. Chave ausente não é erro.
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$OnlyIfEmpty
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    if ($OnlyIfEmpty) {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $hasValues = @($key.GetValueNames() | Where-Object { -not [string]::IsNullOrEmpty($_) }).Count -gt 0

        if ($hasValues -or $key.SubKeyCount -gt 0) {
            return
        }
    }

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}


# ---------------------------------------------------------------------------
# Formatação
# ---------------------------------------------------------------------------

# Os números do SnakeOptimizer saem como no português do Brasil (vírgula decimal), qualquer que seja o idioma do Windows: o
# texto em volta é sempre em português. Sem isto, o PowerShell escreve "8.23 GB" ao montar um texto com "$(...)".
# Montado na primeira vez que é usado (Get-SnakeOptimizerNumberFormat).
$script:SnakeOptimizerNumberFormat = $null


function Get-SnakeOptimizerNumberFormat {
    if ($null -eq $script:SnakeOptimizerNumberFormat) {
        $format = [System.Globalization.NumberFormatInfo]::InvariantInfo.Clone()
        $format.NumberDecimalSeparator = ","
        $format.NumberGroupSeparator = "."
        $script:SnakeOptimizerNumberFormat = $format
    }

    return $script:SnakeOptimizerNumberFormat
}


function Format-SnakeOptimizerBytes {
    <#
    Texto legível para tamanhos, como o Explorador mostra: três algarismos significativos e vírgula decimal ("8,23 GB",
    "47,6 GB", "476 GB", "1,5 GB"). Valores nulos, inválidos ou <= 0 viram $ZeroText.
    #>
    param (
        [object]$Bytes,
        [string]$ZeroText = "0 B"
    )

    try {
        $value = [double]$Bytes
    }
    catch {
        return $ZeroText
    }

    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0) {
        return $ZeroText
    }

    $units = @("B", "KB", "MB", "GB", "TB", "PB")
    $index = 0

    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }

    if ($index -eq 0) {
        return "$([Math]::Round($value, 0)) B"
    }

    # Duas casas abaixo de 10, uma abaixo de 100, nenhuma daí para cima. O arredondamento pode cruzar a faixa (9,996 vira
    # 10,00): a conta é refeita com uma casa a menos. E 1023,7 KB arredondaria para "1024 KB": vira "1 MB".
    $digits = $(if ($value -lt 10) { 2 } elseif ($value -lt 100) { 1 } else { 0 })
    $rounded = [Math]::Round($value, $digits)

    if ($digits -gt 0 -and $rounded -ge [Math]::Pow(10, 3 - $digits)) {
        $digits--
        $rounded = [Math]::Round($value, $digits)
    }

    if ($rounded -ge 1024 -and $index -lt ($units.Count - 1)) {
        $index++
        $digits = 2
        $rounded = [Math]::Round($value / 1024, $digits)
    }

    $pattern = $(if ($digits -gt 0) { "0." + ("#" * $digits) } else { "0" })

    return "$($rounded.ToString($pattern, (Get-SnakeOptimizerNumberFormat))) $($units[$index])"
}


function Format-SnakeOptimizerNumber {
    # "12.345", "4,5", "3,69": um número com os separadores do português do Brasil, até $Decimals casas (zeros à direita
    # somem). Montar o texto com "$(...)" escreveria "4.5" e "12345".
    param (
        [Parameter(Mandatory)][double]$Value,
        [ValidateRange(0, 6)][int]$Decimals = 0
    )

    $pattern = "#,##0" + $(if ($Decimals -gt 0) { "." + ("#" * $Decimals) } else { "" })

    return $Value.ToString($pattern, (Get-SnakeOptimizerNumberFormat))
}


function Format-SnakeOptimizerDateTime {
    # "21/10/2026 21:40" (ou outro padrão, como "dd/MM"), sempre com barras e dois pontos: num padrão de data, "/" e ":"
    # viram os separadores do idioma do Windows (pontos no alemão, por exemplo), e o texto em volta é em português.
    param (
        [Parameter(Mandatory)][datetime]$When,
        [string]$Pattern = "dd/MM/yyyy HH:mm"
    )

    return $When.ToString($Pattern, [System.Globalization.CultureInfo]::InvariantCulture)
}


function Format-SnakeOptimizerCount {
    # "1 etapa", "3 etapas", "0 etapas", "12.345 itens": a quantidade (com o separador de milhar do português) e a palavra
    # no singular ou no plural certo, em vez de "etapa(s)".
    param (
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$One,
        [Parameter(Mandatory)][string]$Many
    )

    return "$(Format-SnakeOptimizerNumber -Value $Count) $(if ($Count -eq 1) { $One } else { $Many })"
}


function Join-SnakeOptimizerList {
    # "C:", "C: e D:", "C:, D: e E:": uma enumeração como se escreve em português.
    param (
        [AllowEmptyCollection()][string[]]$Items = @()
    )

    $list = @($Items | Where-Object { -not [string]::IsNullOrEmpty($_) })

    if ($list.Count -le 1) { return ($list -join "") }

    return (($list[0..($list.Count - 2)] -join ", ") + " e " + $list[$list.Count - 1])
}


function Join-SnakeOptimizerShortList {
    # Como Join-SnakeOptimizerList, mas curta para caber na faixa de resultado: até Limit nomes, todos; com mais, os três
    # primeiros e quantos faltam ("Git, VLC, Zoom e mais 4").
    param (
        [AllowEmptyCollection()][string[]]$Items = @(),
        [ValidateRange(4, 100)][int]$Limit = 4
    )

    $list = @($Items | Where-Object { -not [string]::IsNullOrEmpty($_) })

    if ($list.Count -le $Limit) { return (Join-SnakeOptimizerList -Items $list) }

    return "$($list[0..2] -join ', ') e mais $(Format-SnakeOptimizerNumber -Value ($list.Count - 3))"
}


function Get-SnakeOptimizerSelectionQuestion {
    # A confirmação de uma lista marcada: "Remover Clipchamp?", "Remover Clipchamp e Mapas?" (até três nomes, que a janela
    # mostra na própria pergunta) ou "Remover os 5 aplicativos marcados?". Many é a palavra no plural, masculina.
    param (
        [Parameter(Mandatory)][string]$Verb,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Many,
        [int]$Limit = 3
    )

    if ($Names.Count -le $Limit) {
        return "$Verb $(Join-SnakeOptimizerList -Items $Names)?"
    }

    return "$Verb os $($Names.Count) $Many marcados?"
}


function Get-SnakeOptimizerErrorCode {
    <#
    O código de um erro do Windows, como "0x80073CFA": o primeiro que aparece na mensagem ou, na falta dele, o HResult da
    exceção. Os HResult genéricos do .NET e do PowerShell (0x80131500, 0x80131501, 0x80131509, 0x80131600) não dizem nada
    sobre a causa e ficam de fora. Vazio quando não há código.
    #>
    param (
        [string]$Message,
        [int]$HResult = 0
    )

    $match = [regex]::Match([string]$Message, '0x[0-9A-Fa-f]{8}')

    if ($match.Success) {
        return "0x" + $match.Value.Substring(2).ToUpperInvariant()
    }

    if ($HResult -lt 0 -and $HResult -notin @(-2146233088, -2146233087, -2146233079, -2146232832)) {
        return ("0x{0:X8}" -f $HResult)
    }

    return ""
}


function Format-SnakeOptimizerRelativeTime {
    # "há 3 dias", "há 2 horas", "agora há pouco": mostra quando algo aconteceu sem obrigar a pessoa a fazer a conta.
    # Um horário até um dia no futuro (fuso, relógio um pouco adiantado) conta como "agora há pouco"; mais que isso, a data
    # foi gravada com o relógio errado, e o texto diz "com data no futuro" em vez de fingir que foi agora.
    param (
        [Parameter(Mandatory)]
        [datetime]$When,

        [datetime]$Now = (Get-Date)
    )

    $span = $Now - $When

    if ($span.TotalDays -le -1) { return "com data no futuro" }

    if ($span.TotalMinutes -lt 1) { return "agora há pouco" }

    if ($span.TotalHours -lt 1) {
        $amount = [int][Math]::Floor($span.TotalMinutes)
        $unit = @("minuto", "minutos")
    }
    elseif ($span.TotalDays -lt 1) {
        $amount = [int][Math]::Floor($span.TotalHours)
        $unit = @("hora", "horas")
    }
    elseif ($span.TotalDays -lt 30) {
        $amount = [int][Math]::Floor($span.TotalDays)
        $unit = @("dia", "dias")
    }
    elseif ($span.TotalDays -lt 365) {
        $amount = [int][Math]::Floor($span.TotalDays / 30)
        $unit = @("mês", "meses")
    }
    else {
        $amount = [int][Math]::Floor($span.TotalDays / 365)
        $unit = @("ano", "anos")
    }

    $word = if ($amount -eq 1) { $unit[0] } else { $unit[1] }

    return "há $amount $word"
}


function Format-SnakeOptimizerDuration {
    param (
        [TimeSpan]$Span
    )

    # O relógio pode ser ajustado durante uma etapa longa; duração negativa não faz sentido.
    if ($Span.Ticks -lt 0) { $Span = [TimeSpan]::Zero }

    # Arredondada antes de escolher o formato: 59,6 segundos é "1min 00s", e não "60s".
    $Span = [TimeSpan]::FromSeconds([Math]::Round($Span.TotalSeconds))

    if ($Span.TotalHours -ge 1) { return ("{0}h {1:00}min" -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes) }
    if ($Span.TotalMinutes -ge 1) { return ("{0}min {1:00}s" -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds) }
    return ("{0}s" -f [int]$Span.TotalSeconds)
}


# ---------------------------------------------------------------------------
# Seleção por números ("1,3,5-7")
# ---------------------------------------------------------------------------

function ConvertTo-SnakeOptimizerSelectionIndexes {
    # Aceita "1,3,5", "1 3 5", "2-4" e combinações ("1, 3-5"). Vírgula, ponto e vírgula e espaço separam itens.
    # Lança erro com mensagem clara se algo for inválido. Os limites são validados antes de expandir intervalos,
    # para que "1-999999999" não consuma memória. Só dígitos 0-9: [int] não converte dígitos de outros alfabetos.
    param (
        [string]$InputText,
        [int]$Maximum
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) {
        return @()
    }

    if ($Maximum -lt 1) {
        throw "Não há itens para escolher."
    }

    # "3 - 5" vira "3-5" antes de separar por espaços.
    $normalized = [regex]::Replace($InputText, "\s*-\s*", "-")
    $segments = @($normalized -split "[,;\s]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($segments.Count -eq 0) {
        return @()
    }

    $indexes = New-Object System.Collections.Generic.List[int]

    foreach ($part in $segments) {
        if ($part -match "^([0-9]{1,9})-([0-9]{1,9})$") {
            $first = [int]$Matches[1]
            $last = [int]$Matches[2]

            if ($first -gt $last) {
                throw "O intervalo '$part' está invertido."
            }

            $values = @($first, $last)
            $expand = $true
        }
        elseif ($part -match "^[0-9]{1,9}$") {
            $values = @([int]$part)
            $expand = $false
        }
        else {
            throw "'$part' não é um número nem um intervalo válido."
        }

        foreach ($value in $values) {
            if ($value -lt 1 -or $value -gt $Maximum) {
                throw "O número $value está fora da lista (1 a $Maximum)."
            }
        }

        if ($expand) {
            $values = $values[0]..$values[1]
        }

        foreach ($value in $values) {
            if (-not $indexes.Contains($value)) {
                $indexes.Add($value)
            }
        }
    }

    return @($indexes)
}


# ---------------------------------------------------------------------------
# Programas nativos
# ---------------------------------------------------------------------------

function Invoke-SnakeOptimizerNative {
    <#
    Executa um programa nativo mostrando a saída na tela e sem devolver linhas ao pipeline.
    Na interface gráfica não há console visível: stdout e stderr são capturados e escritos linha a linha,
    na ordem em que chegam. Lança erro se o código de saída for diferente de zero (exceto com -IgnoreExitCode).
    Com -PassThru devolve o código de saída.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [switch]$IgnoreExitCode,

        [switch]$PassThru
    )

    # Um programa que não existe não pode parecer um sucesso: com $ErrorActionPreference = Continue (o padrão da janela
    # e do console), o "não reconhecido" do PowerShell não interrompe a função e o código de saída ficaria 0.
    if ($null -eq (Get-Command -Name $FilePath -ErrorAction SilentlyContinue)) {
        throw "O programa '$FilePath' não foi encontrado neste PC."
    }

    # Sem isto, o código de uma chamada anterior pareceria ser o deste programa se ele nem chegasse a definir um.
    $global:LASTEXITCODE = 0

    if (Test-SnakeOptimizerGuiMode) {
        # Ferramentas que gravam em UTF-16 (SFC) deixam caracteres nulos entre as letras; eles são removidos.
        $progress = @{ Last = -1.0 }

        Read-SnakeOptimizerProcessLines -FilePath $FilePath -Arguments $Arguments | ForEach-Object {
            $line = ([string]$_) -replace "`0", ""

            if (Test-SnakeOptimizerEchoLine -Line $line -State $progress) { Write-Host $line }
        }
    }
    else {
        & $FilePath @Arguments | Out-Host
    }

    $exitCode = $LASTEXITCODE

    if (-not $IgnoreExitCode -and $null -ne $exitCode -and $exitCode -ne 0) {
        throw "Comando '$FilePath $($Arguments -join ' ')' finalizou com código $exitCode."
    }

    if ($PassThru) {
        return $exitCode
    }
}


function Get-SnakeOptimizerProgressPercent {
    <#
    O percentual de uma linha de progresso do DISM ("[====    25.0%    ====]"), do SFC ("Verification 25% complete."
    / "Verificação 25% concluída.") ou do winget ("  ████▒▒▒▒  40%" e "  ████▒▒▒▒  512 KB / 1.50 MB"), ou $null quando a
    linha é outra coisa. Reconhece só esses formatos: o que não for reconhecido continua aparecendo inteiro.
    #>
    param ([string]$Line)

    if ([string]::IsNullOrEmpty($Line)) { return $null }

    $number = $null

    if ($Line -match '^\s*\[[=\s]*([0-9]{1,3}(?:[.,][0-9]+)?)%[=\s]*\]\s*$') {
        $number = $Matches[1]
    }
    elseif ($Line -match '^\s*[^0-9%]{1,60}?([0-9]{1,3})%\s+(?:complete|completo|conclu\S*|done)\.?\s*$') {
        $number = $Matches[1]
    }
    elseif ($Line -match '^[\s\x08]*[\u2588\u2593\u2592\u2591]+[\s\x08]+([0-9]{1,3})%\s*$') {
        $number = $Matches[1]
    }
    elseif ($Line -match '^[\s\x08]*[\u2588\u2593\u2592\u2591]+[\s\x08]+([0-9]+(?:[.,][0-9]+)?)\s*(B|KB|MB|GB)\s*/\s*([0-9]+(?:[.,][0-9]+)?)\s*(B|KB|MB|GB)\s*$') {
        # Download do winget: tamanho baixado / tamanho total.
        $units = @{ B = 1.0; KB = 1024.0; MB = 1048576.0; GB = 1073741824.0 }
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $done = [double]::Parse(($Matches[1] -replace ',', '.'), $culture) * $units[$Matches[2].ToUpperInvariant()]
        $total = [double]::Parse(($Matches[3] -replace ',', '.'), $culture) * $units[$Matches[4].ToUpperInvariant()]

        if ($total -le 0) { return $null }

        return [math]::Min(100.0, [math]::Round($done / $total * 100, 1))
    }

    if ($null -eq $number) { return $null }

    $value = [double]::Parse(($number -replace ',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)

    if ($value -gt 100) { return $null }

    return $value
}


function Test-SnakeOptimizerProgressStepShown {
    # Barras de progresso chegam uma linha por atualização (dezenas por etapa). Na tela basta uma a cada 10 pontos:
    # a primeira, o 100% e a de uma nova etapa (quando o percentual volta a baixar). Last guarda a última exibida.
    param (
        [Parameter(Mandatory)]
        [double]$Percent,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $last = [double]$State.Last

    $show = ($last -lt 0) -or ($Percent -lt $last) -or ($Percent -ge ($last + 10)) -or ($Percent -ge 100 -and $last -lt 100)

    if ($show) { $State.Last = $Percent }

    return $show
}


function Test-SnakeOptimizerEchoLine {
    <#
    Se uma linha da saída de um programa aparece na tela. Os quadros do indicador de espera do winget ("-", "\", "|", "/")
    nunca aparecem; barras de progresso aparecem uma a cada 10 pontos (Test-SnakeOptimizerProgressStepShown); o resto sempre.
    State é o mesmo @{ Last = -1.0 } durante toda a execução do programa.
    #>
    param (
        [string]$Line,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # Os quadros do indicador são curtos; as linhas de verdade quase nunca.
    if ($Line.Length -le 8 -and $Line -match '^[\s\x08]*[-\\|/][\s\x08]*$') { return $false }

    # Linhas em branco: o DISM e o SFC mandam uma ou duas junto com cada atualização da barra. As atualizações escondidas
    # (Test-SnakeOptimizerProgressStepShown) deixavam as delas na tela, 15 a 20 linhas vazias entre um percentual e o
    # seguinte. Durante uma barra nenhuma aparece; fora dela, várias seguidas viram uma.
    if ($Line -match '^[\s\x08]*$') {
        if ([bool]$State.InBar -or [bool]$State.Blank) { return $false }

        $State.Blank = $true
        return $true
    }

    $percent = $null

    # A maioria das linhas não tem "%" nem " / ": nem chama o reconhecedor.
    if ($Line.Contains("%") -or $Line.Contains(" / ")) { $percent = Get-SnakeOptimizerProgressPercent -Line $Line }

    if ($null -eq $percent) {
        $State.InBar = $false
        $State.Blank = $false
        return $true
    }

    $State.InBar = $true
    $show = Test-SnakeOptimizerProgressStepShown -Percent $percent -State $State
    if ($show) { $State.Blank = $false }

    return $show
}


function Select-SnakeOptimizerLegacyEncoding {
    <#
    Entre as duas páginas antigas do Windows, a que o programa usou: o DISM escreve na OEM (850 no Brasil) e o CHKDSK na
    ANSI (1252). Lidos na página errada, os acentos viram outros símbolos ("Estágio" vira "Estßgio", "concluídos" vira
    "concluÝdos"). Decodifica o trecho nas duas e fica com a que tem mais letras acentuadas do português e menos símbolos
    soltos; no empate, a OEM.
    #>
    param (
        [Parameter(Mandatory)][byte[]]$Buffer,
        [int]$Offset = 0,
        [int]$Count = -1
    )

    if ($Count -lt 0) { $Count = $Buffer.Length - $Offset }

    $oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)

    if ($oem.CodePage -eq $ansi.CodePage) { return $oem }

    # Minúscula acentuada vale mais que maiúscula: o primeiro acento do CHKDSK costuma ser o "é" de "arquivos é NTFS",
    # que na OEM vira "Ú", também uma letra; com o mesmo peso dava empate e a OEM (errada para o CHKDSK) ganhava.
    $lower = "áàâãéêíóôõúüçñ"
    $upper = "ÁÀÂÃÉÊÍÓÔÕÚÜÇÑ"
    $score = {
        param ($text)
        $value = 0
        foreach ($char in $text.ToCharArray()) {
            if ([int]$char -lt 0x80) { continue }
            if ($lower.IndexOf($char) -ge 0) { $value += 3 }
            elseif ($upper.IndexOf($char) -ge 0) { $value += 1 }
            else { $value -= 1 }
        }
        $value
    }

    $oemScore = & $score ($oem.GetString($Buffer, $Offset, $Count))
    $ansiScore = & $score ($ansi.GetString($Buffer, $Offset, $Count))

    if ($ansiScore -gt $oemScore) { return $ansi }
    return $oem
}


function Read-SnakeOptimizerProcessLines {
    <#
    Executa um programa nativo e devolve a saída linha a linha, enquanto ela chega, terminando uma linha tanto no "\n"
    quanto no "\r" sozinho. O pipe do PowerShell (& programa | ForEach-Object) só entrega uma linha no "\n": o SFC, que
    reescreve "Verificação 9% concluída." no mesmo lugar com "\r", ficava sem nada na tela por 20 minutos e soltava
    tudo de uma vez no fim. A codificação vem dos primeiros bytes: UTF-16 (o SFC gravando num pipe), UTF-8 (winget), a
    OEM (DISM) ou a ANSI (CHKDSK), escolhida por Select-SnakeOptimizerLegacyEncoding. O que sai no stderr vem depois, ao
    terminar, decodificado do mesmo jeito. Deixa o código de saída em $LASTEXITCODE.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$Arguments = @()
    )

    $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $command.Source
    $info.Arguments = (@($Arguments | ForEach-Object {
                $text = [string]$_
                if ($text -eq "" -or $text -match '[\s"]') { '"' + ($text -replace '"', '\"') + '"' } else { $text }
            }) -join " ")
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($info)

    try {
        # O stderr é lido em paralelo: um programa que enche esse pipe sem ninguém ler ficaria parado.
        # Em bytes, para decodificar como a saída normal (UTF-8, OEM ou ANSI), e não na página padrão do .NET.
        $errorBytes = New-Object System.IO.MemoryStream
        $errorCopy = $process.StandardError.BaseStream.CopyToAsync($errorBytes)
        $stream = $process.StandardOutput.BaseStream
        $buffer = New-Object byte[] 4096
        $chars = New-Object char[] 8192
        $decoder = $null
        $first = $true
        $line = New-Object System.Text.StringBuilder
        $previous = [char]0

        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $offset = 0

            if ($first) {
                $first = $false

                # UTF-16: metade dos bytes é zero (texto latino). O BOM, se vier, sai.
                $zeros = 0
                for ($i = 1; $i -lt $count; $i += 2) { if ($buffer[$i] -eq 0) { $zeros++ } }

                if ($count -ge 2 -and $zeros -ge [Math]::Floor($count / 4)) {
                    $decoder = [System.Text.Encoding]::Unicode.GetDecoder()
                    if ($buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) { $offset = 2 }
                }
            }

            if ($null -eq $decoder) {
                # Fora do UTF-16, a codificação só se decide no primeiro trecho com acento: UTF-8 quando ele é UTF-8 válido
                # (winget e programas novos), senão a página OEM do Windows (DISM, CHKDSK; a 850 no Brasil). O console
                # da janela pode estar em UTF-8 enquanto o DISM escreve em OEM: perguntar ao console quebrava os acentos.
                $high = $false
                for ($i = $offset; $i -lt $count; $i++) { if ($buffer[$i] -ge 0x80) { $high = $true; break } }

                if ($high) {
                    try {
                        [void](New-Object System.Text.UTF8Encoding ($false, $true)).GetCharCount($buffer, $offset, $count - $offset)
                        $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
                    }
                    catch {
                        $decoder = (Select-SnakeOptimizerLegacyEncoding -Buffer $buffer -Offset $offset -Count ($count - $offset)).GetDecoder()
                    }
                }
            }

            if ($null -eq $decoder) {
                # Só ASCII até aqui: igual em qualquer codificação.
                $decoded = [System.Text.Encoding]::ASCII.GetChars($buffer, $offset, $count - $offset, $chars, 0)
            }
            else {
                $decoded = $decoder.GetChars($buffer, $offset, $count - $offset, $chars, 0)
            }

            for ($i = 0; $i -lt $decoded; $i++) {
                $char = $chars[$i]

                if ($char -eq "`r" -or $char -eq "`n") {
                    # "\r\n" é uma quebra só.
                    if (-not ($char -eq "`n" -and $previous -eq "`r")) {
                        $line.ToString()
                        [void]$line.Clear()
                    }
                }
                elseif ($char -ne [char]0) {
                    [void]$line.Append($char)
                }

                $previous = $char
            }
        }

        if ($line.Length -gt 0) { $line.ToString() }

        $process.WaitForExit()

        [void]$errorCopy.Wait()
        $raw = $errorBytes.ToArray()
        $errorText = ""

        if ($raw.Length -gt 0) {
            $zeros = 0
            for ($i = 1; $i -lt $raw.Length; $i += 2) { if ($raw[$i] -eq 0) { $zeros++ } }

            if ($raw.Length -ge 2 -and $zeros -ge [Math]::Floor($raw.Length / 4)) { $errorText = [System.Text.Encoding]::Unicode.GetString($raw) }
            else {
                try { $errorText = (New-Object System.Text.UTF8Encoding ($false, $true)).GetString($raw) }
                catch { $errorText = (Select-SnakeOptimizerLegacyEncoding -Buffer $raw).GetString($raw) }
            }
        }

        foreach ($errorLine in ($errorText.TrimStart([char]0xFEFF) -split "\r?\n")) {
            if ($errorLine.Length -gt 0) { $errorLine }
        }

        $global:LASTEXITCODE = $process.ExitCode
    }
    finally {
        # Se quem lê parar no meio (o pipeline foi interrompido), o programa não fica rodando sozinho.
        if (-not $process.HasExited) {
            try { $process.Kill() } catch { Write-Verbose "Encerrar $($FilePath): $($_.Exception.Message)" }
        }

        $process.Dispose()
    }
}


function Invoke-SnakeOptimizerCapture {
    <#
    Executa um programa nativo e devolve ExitCode, Lines e Text. Com -Echo as linhas também aparecem na tela
    enquanto chegam, o que evita uma janela parada durante comandos demorados (CHKDSK, DISM). Linhas e Text trazem
    tudo; só a tela resume as barras de progresso (Test-SnakeOptimizerProgressStepShown).
    Com -ProgressActivity, o percentual das linhas de progresso (DISM, SFC: Get-SnakeOptimizerProgressPercent) vai também para
    a barra de progresso (na janela, a barra enche e o texto ao lado diz "62% · ..."), a cada ponto inteiro.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [switch]$Echo,

        [string]$ProgressActivity = "",

        # O que vem depois do percentual no texto da barra.
        [string]$ProgressStatus = "não feche o SnakeOptimizer até terminar"
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $progress = @{ Last = -1.0; Bar = -1 }

    # Um programa que não existe não pode parecer um sucesso: com $ErrorActionPreference = Continue (o padrão da janela
    # e do console), o "não reconhecido" do PowerShell não interrompe a função e o código de saída ficaria 0.
    if ($null -eq (Get-Command -Name $FilePath -ErrorAction SilentlyContinue)) {
        throw "O programa '$FilePath' não foi encontrado neste PC."
    }

    $global:LASTEXITCODE = 0

    Read-SnakeOptimizerProcessLines -FilePath $FilePath -Arguments $Arguments | ForEach-Object {
        $line = ([string]$_) -replace "`0", ""
        $lines.Add($line)

        if ($Echo -and (Test-SnakeOptimizerEchoLine -Line $line -State $progress)) {
            Write-Host $line
        }

        if ($ProgressActivity -and ($line.Contains("%") -or $line.Contains(" / "))) {
            $percent = Get-SnakeOptimizerProgressPercent -Line $line

            if ($null -ne $percent -and [int][Math]::Floor($percent) -ne [int]$progress.Bar) {
                $progress.Bar = [int][Math]::Floor($percent)
                Write-Progress -Activity $ProgressActivity -Status "$($progress.Bar)% · $ProgressStatus" -PercentComplete $progress.Bar
            }
        }
    }

    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Lines    = @($lines)
        Text     = ($lines -join "`n")
    }
}


function Get-SnakeOptimizerPathStats {
    <#
    Percorre um arquivo ou pasta sem seguir atalhos de pasta (junções e links simbólicos), que poderiam levar a
    outras pastas, a ciclos ou a contar duas vezes o mesmo conteúdo. Devolve Size (bytes), Files e Newest (data
    de alteração mais recente). Itens ilegíveis são ignorados: o resultado é uma estimativa.
    -ExcludeShellMetadata ignora desktop.ini e Thumbs.db, que não são conteúdo do usuário.
    #>
    param (
        [string]$Path,
        [switch]$ExcludeShellMetadata
    )

    $stats = [PSCustomObject]@{
        Size   = [int64]0
        Files  = [int64]0
        Newest = [datetime]::MinValue
    }

    $addFile = {
        param ($file)

        if ($ExcludeShellMetadata -and $file.Name -in @("desktop.ini", "Thumbs.db")) {
            return
        }

        $stats.Size += [int64]$file.Length
        $stats.Files++

        if ($file.LastWriteTime -gt $stats.Newest) {
            $stats.Newest = $file.LastWriteTime
        }
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $stats
    }

    try {
        $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop

        if (-not $root.PSIsContainer) {
            & $addFile $root
            return $stats
        }

        $pending = New-Object System.Collections.Generic.Stack[string]
        $pending.Push($root.FullName)

        while ($pending.Count -gt 0) {
            $current = $pending.Pop()

            try {
                $directory = New-Object System.IO.DirectoryInfo -ArgumentList $current

                foreach ($entry in $directory.EnumerateFileSystemInfos()) {
                    try {
                        if ($entry -is [System.IO.DirectoryInfo]) {
                            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                                $pending.Push($entry.FullName)
                            }
                        }
                        else {
                            & $addFile $entry
                        }
                    }
                    catch {
                        # Item removido ou inacessível durante a leitura.
                    }
                }
            }
            catch {
                # Pasta inacessível: segue com as demais.
            }
        }
    }
    catch {
        # Caminho inacessível: devolve o que foi somado.
    }

    return $stats
}


function Invoke-SnakeOptimizerInBackground {
    <#
    Roda um bloco em outro runspace e espera por ele em fatias curtas, até $TimeoutSeconds. É para chamadas que podem
    demorar e que o botão Parar não consegue interromper por dentro (por exemplo, a consulta COM do Windows Update): a
    espera aqui continua interrompível, e um bloco que não termina a tempo é abandonado.
    O bloco roda num runspace novo e não enxerga as funções do SnakeOptimizer; os valores entram por -ArgumentList (param).
    Devolve Completed, TimedOut, Output (o que o bloco escreveu) e Error (texto do primeiro erro, ou vazio).
    #>
    param (
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @(),

        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 60
    )

    $shell = [powershell]::Create()
    $finished = $false

    try {
        [void]$shell.AddScript($ScriptBlock.ToString())

        foreach ($argument in $ArgumentList) {
            [void]$shell.AddArgument($argument)
        }

        $handle = $shell.BeginInvoke()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $handle.AsyncWaitHandle.WaitOne(200)) {
            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                return [PSCustomObject]@{ Completed = $false; TimedOut = $true; Output = @(); Error = "" }
            }
        }

        $finished = $true
        $output = @()
        $errorText = ""

        try {
            $output = @($shell.EndInvoke($handle))
        }
        catch {
            $errorText = [string]$_.Exception.Message
        }

        if (-not $errorText -and $shell.Streams.Error.Count -gt 0) {
            $errorText = [string]$shell.Streams.Error[0]
        }

        return [PSCustomObject]@{ Completed = (-not $errorText); TimedOut = $false; Output = @($output); Error = $errorText }
    }
    finally {
        if ($finished) {
            $shell.Dispose()
        }
        else {
            # Tempo esgotado ou interrompido: pede para parar sem esperar (Dispose bloquearia numa chamada COM presa).
            try { [void]$shell.BeginStop($null, $null) } catch { }
        }
    }
}


# Quantos pedidos de "não suspender" estão abertos e em qual thread (Set-SnakeOptimizerKeepAwake).
$script:SnakeOptimizerKeepAwakeDepth = 0
$script:SnakeOptimizerKeepAwakeThread = -1


function Set-SnakeOptimizerThreadExecutionState {
    # Chama o SetThreadExecutionState do Windows. Devolve $false quando a API não está disponível ou recusou o pedido.
    param (
        [Parameter(Mandatory)]
        [bool]$KeepAwake
    )

    try {
        if (-not ("SnakeOptimizer.PowerNative" -as [type])) {
            Add-Type -Namespace SnakeOptimizer -Name PowerNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint flags);
'@ -ErrorAction Stop
        }

        $continuous = [uint32]2147483648
        $systemRequired = [uint32]1

        if ($KeepAwake) {
            $flags = $continuous -bor $systemRequired
        }
        else {
            $flags = $continuous
        }

        return ([SnakeOptimizer.PowerNative]::SetThreadExecutionState($flags) -ne 0)
    }
    catch {
        return $false
    }
}


function Set-SnakeOptimizerKeepAwake {
    <#
    Impede que o Windows suspenda o PC enquanto uma manutenção longa roda (SetThreadExecutionState).
    O pedido vale para a thread atual: chame com -Enabled $false (em um finally) ao terminar.
    Os pedidos se acumulam: o Windows guarda só o último estado da thread, então uma ação longa dentro de outra (o reparo
    dentro do Otimizar) desligaria, ao terminar, o pedido da de fora, e o PC poderia dormir no meio das
    etapas seguintes. Aqui cada -Enabled $true conta um pedido, cada -Enabled $false fecha um, e o PC só volta a poder
    dormir quando o último fecha.
    Retorna $false quando a API não está disponível (e aí o pedido não conta: quem recebeu $false não precisa fechá-lo).
    #>
    param (
        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    # A contagem é da thread que fez os pedidos (o estado do Windows também é): uma ação que começa em outra thread começa
    # do zero, mesmo que a anterior tenha sido interrompida sem fechar o seu pedido.
    $thread = [System.Threading.Thread]::CurrentThread.ManagedThreadId

    if ($script:SnakeOptimizerKeepAwakeThread -ne $thread) {
        $script:SnakeOptimizerKeepAwakeThread = $thread
        $script:SnakeOptimizerKeepAwakeDepth = 0
    }

    if ($Enabled) {
        if ($script:SnakeOptimizerKeepAwakeDepth -gt 0) {
            # Já pedido por uma ação de fora, que continua valendo.
            $script:SnakeOptimizerKeepAwakeDepth++
            return $true
        }

        if (-not (Set-SnakeOptimizerThreadExecutionState -KeepAwake $true)) {
            return $false
        }

        $script:SnakeOptimizerKeepAwakeDepth = 1
        return $true
    }

    if ($script:SnakeOptimizerKeepAwakeDepth -gt 1) {
        # Uma ação de fora ainda precisa do PC acordado.
        $script:SnakeOptimizerKeepAwakeDepth--
        return $true
    }

    $script:SnakeOptimizerKeepAwakeDepth = 0

    return (Set-SnakeOptimizerThreadExecutionState -KeepAwake $false)
}


function Restart-SnakeOptimizerExplorerShell {
    # Configurações do Explorador e da barra de tarefas são recarregadas pelo shell.
    # O Windows relança o shell sozinho (no contexto do usuário). Só abrimos o explorer.exe
    # manualmente se isso não acontecer, porque um explorer iniciado por um processo elevado
    # herda privilégios de Administrador.
    $currentSessionId = (Get-Process -Id $PID).SessionId

    $getSessionExplorer = {
        @(
            Get-Process -Name "explorer" -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -eq $currentSessionId }
        )
    }.GetNewClosure()

    $previousProcessIds = @(& $getSessionExplorer | Select-Object -ExpandProperty Id)

    if ($previousProcessIds.Count -gt 0) {
        & $getSessionExplorer | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # 1) Aguarda o encerramento dos processos antigos.
    $exitDeadline = [DateTime]::UtcNow.AddSeconds(5)
    $stillRunning = $false

    do {
        $stillRunning = @(
            Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $previousProcessIds -contains $_.Id }
        ).Count -gt 0

        if (-not $stillRunning) { break }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $exitDeadline)

    if ($stillRunning) {
        throw "O Explorer do Windows não pôde ser encerrado."
    }

    # 2) Dá tempo ao Windows para relançar o shell automaticamente.
    $autoDeadline = [DateTime]::UtcNow.AddSeconds(6)

    do {
        if (@(& $getSessionExplorer).Count -gt 0) {
            return
        }

        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $autoDeadline)

    # 3) Fallback: inicia manualmente.
    [void](Start-Process -FilePath (Join-Path $env:WINDIR "explorer.exe") -ErrorAction Stop)

    $startupDeadline = [DateTime]::UtcNow.AddSeconds(8)

    do {
        if (@(& $getSessionExplorer).Count -gt 0) {
            return
        }

        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $startupDeadline)

    throw "O Explorer do Windows não reiniciou no tempo esperado."
}


function Set-SnakeOptimizerHighPerformancePowerPlan {
    # Ativa o plano Alto desempenho. Devolve $true/$false; com -PassThru, Guid (o plano ativado; vazio no SCHEME_MIN) e
    # Created (se uma cópia nova do plano foi criada agora), ou $null quando nada funcionou.
    param (
        [switch]$ThrowOnFailure,

        # Uma cópia do plano que o SnakeOptimizer já criou antes: se ela ainda existe, é ativada em vez de criar outra (sem
        # isso, cada aplicação deixava mais um "Alto desempenho" na lista de planos).
        [string]$PreferredGuid = "",

        [switch]$PassThru
    )

    $outcome = $null

    if (-not (Get-Command "powercfg.exe" -ErrorAction SilentlyContinue)) {
        if ($ThrowOnFailure) {
            throw "powercfg.exe não foi encontrado."
        }

        if ($PassThru) { return $null }
        return $false
    }

    # GUID do plano Alto desempenho. O fallback SCHEME_MIN é usado somente se necessário.
    $highPerformanceGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    $guidPattern = "[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}"

    $activate = {
        param ([string]$Scheme)
        return ((Invoke-SnakeOptimizerCapture -FilePath "powercfg.exe" -Arguments @("/setactive", $Scheme)).ExitCode -eq 0)
    }

    if ($PreferredGuid -match "^$guidPattern$" -and (& $activate $PreferredGuid)) {
        $outcome = [PSCustomObject]@{ Guid = $PreferredGuid.ToLowerInvariant(); Created = $false }
    }
    elseif (& $activate $highPerformanceGuid) {
        $outcome = [PSCustomObject]@{ Guid = $highPerformanceGuid; Created = $false }
    }
    else {
        # Em algumas instalações o plano pode não estar disponível. Nesse caso, recria a partir do template oficial.
        $duplicate = Invoke-SnakeOptimizerCapture -FilePath "powercfg.exe" -Arguments @("/duplicatescheme", $highPerformanceGuid)

        if ($duplicate.ExitCode -eq 0) {
            $newGuid = [regex]::Match($duplicate.Text, $guidPattern).Value

            if (-not [string]::IsNullOrWhiteSpace($newGuid)) {
                if (& $activate $newGuid) {
                    $outcome = [PSCustomObject]@{ Guid = $newGuid.ToLowerInvariant(); Created = $true }
                }
                else {
                    # Uma cópia que não pôde ser ativada só ocuparia a lista de planos.
                    [void](Invoke-SnakeOptimizerCapture -FilePath "powercfg.exe" -Arguments @("/delete", $newGuid))
                }
            }
        }

        # Fallback conhecido do powercfg: SCHEME_MIN representa o mínimo de economia de energia, ou seja, Alto desempenho.
        if ($null -eq $outcome -and (& $activate "SCHEME_MIN")) {
            $outcome = [PSCustomObject]@{ Guid = ""; Created = $false }
        }
    }

    if ($null -eq $outcome -and $ThrowOnFailure) {
        throw "Não foi possível definir o plano de energia como Alto desempenho."
    }

    if ($PassThru) { return $outcome }

    return ($null -ne $outcome)
}


# ---------------------------------------------------------------------------
# Última manutenção (usada pelo relatório e pela tela inicial)
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerLastMaintenancePath {
    return (Join-Path (Get-SnakeOptimizerDataPath) "last-maintenance.json")
}


function ConvertTo-SnakeOptimizerSnapshotDocument {
    # Uma foto do PC (At, FreeBytes, StartupItems) como dicionário para o JSON; sem foto, $null.
    param ($Snapshot)

    if ($null -eq $Snapshot) {
        return $null
    }

    return [ordered]@{
        At           = ([datetime]$Snapshot.At).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
        FreeBytes    = $Snapshot.FreeBytes
        StartupItems = $Snapshot.StartupItems
    }
}


function ConvertFrom-SnakeOptimizerSnapshotDocument {
    # O inverso de ConvertTo-SnakeOptimizerSnapshotDocument. Foto ausente ou ilegível = $null (arquivos de versões antigas).
    param ($Document)

    if ($null -eq $Document) {
        return $null
    }

    try {
        $at = [datetime]::Parse([string]$Document.At, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $free = $Document.PSObject.Properties["FreeBytes"]
        $startup = $Document.PSObject.Properties["StartupItems"]

        return [PSCustomObject]@{
            At           = $at
            FreeBytes    = $(if ($null -ne $free -and $null -ne $free.Value) { [int64]$free.Value } else { $null })
            StartupItems = $(if ($null -ne $startup -and $null -ne $startup.Value) { [int]$startup.Value } else { $null })
        }
    }
    catch {
        return $null
    }
}


function Set-SnakeOptimizerLastMaintenance {
    # Guarda em memória e em disco: a janela e as ações rodam em sessões separadas, e o relatório
    # precisa enxergar uma manutenção feita antes de o SnakeOptimizer ser reaberto.
    # Before e After são as fotos do PC no começo e no fim (espaço livre e itens na inicialização); podem faltar.
    param (
        [object[]]$Results,
        [datetime]$StartedAt = (Get-Date),
        $Before = $null,
        $After = $null,

        # Como rodou (optimize; as manutenções da 3.50 e anteriores, quick, full ou deep); vai para o histórico.
        [string]$ProfileId = "",

        # A execução: gravada de novo com o mesmo RunId, a entrada do histórico é substituída, e não repetida.
        [string]$RunId = ""
    )

    $script:SnakeOptimizerLastMaintenance = [PSCustomObject]@{
        StartedAt = $StartedAt
        Results   = @($Results)
        Before    = $Before
        After     = $After
    }

    try {
        $document = [ordered]@{
            StartedAt = $StartedAt.ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
            Before    = (ConvertTo-SnakeOptimizerSnapshotDocument -Snapshot $Before)
            After     = (ConvertTo-SnakeOptimizerSnapshotDocument -Snapshot $After)
            Results   = @(
                foreach ($result in @($Results)) {
                    [ordered]@{
                        Etapa   = [string]$result.Etapa
                        Status  = [string]$result.Status
                        Kind    = [string]$result.Kind
                        Duracao = [string]$result.Duracao
                    }
                }
            )
        }

        Write-SnakeOptimizerStateJson -Path (Get-SnakeOptimizerLastMaintenancePath) -InputObject $document -Depth 4
    }
    catch {
        # O histórico em disco é um complemento; a memória já tem o resultado.
    }

    try {
        $entry = New-SnakeOptimizerMaintenanceHistoryEntry -Results $Results -StartedAt $StartedAt -Before $Before -After $After -ProfileId $ProfileId -RunId $RunId
        # O "gravou?" não sai daqui: no fim do resumo da manutenção ele aparecia na tela como uma linha "True".
        [void](Add-SnakeOptimizerMaintenanceHistory -Entry $entry)
    }
    catch {
        # Idem: o histórico é só um complemento.
    }
}


function Get-SnakeOptimizerLastMaintenance {
    # O registro da última manutenção, ou $null quando não há (ou ele é de outra versão). -Strict: um registro que existe,
    # mas não pôde ser lido (preso por outro programa, sem permissão), lança erro em vez de passar por "nunca rodou".
    param ([switch]$Strict)

    if ($null -ne $script:SnakeOptimizerLastMaintenance) {
        return $script:SnakeOptimizerLastMaintenance
    }

    $state = Read-SnakeOptimizerStateFile -Path (Get-SnakeOptimizerLastMaintenancePath)

    if ($Strict -and [string]$state.Status -eq "Unreadable") {
        throw "Não foi possível ler o registro da última manutenção."
    }

    try {
        $document = $state.Document

        if ($null -eq $document) {
            return $null
        }

        $startedAt = [datetime]::Parse([string]$document.StartedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)

        # Arquivos gravados por versões anteriores não têm Before/After.
        $before = $document.PSObject.Properties["Before"]
        $after = $document.PSObject.Properties["After"]

        return [PSCustomObject]@{
            StartedAt = $startedAt
            Results   = @($document.Results)
            Before    = $(if ($null -ne $before) { ConvertFrom-SnakeOptimizerSnapshotDocument -Document $before.Value } else { $null })
            After     = $(if ($null -ne $after) { ConvertFrom-SnakeOptimizerSnapshotDocument -Document $after.Value } else { $null })
        }
    }
    catch {
        # Arquivo ausente, truncado ou de outra versão: trata como "nunca rodou".
        return $null
    }
}


# ---------------------------------------------------------------------------
# Histórico de manutenções (as últimas, para ver tendências)
# ---------------------------------------------------------------------------

$script:SnakeOptimizerMaintenanceHistoryLimit = 20


function Get-SnakeOptimizerMaintenanceHistoryLimit {
    return [int]$script:SnakeOptimizerMaintenanceHistoryLimit
}


function Get-SnakeOptimizerJsonValue {
    # Lê uma propriedade de um objeto vindo do JSON sem falhar quando ela não existe (modo estrito) ou é nula.
    param (
        $Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}


function Get-SnakeOptimizerMaintenanceHistoryPath {
    return (Join-Path (Get-SnakeOptimizerDataPath) "maintenance-history.json")
}


function New-SnakeOptimizerMaintenanceHistoryEntry {
    # Uma linha do histórico: quando, quanto durou, o perfil, quantas etapas deram certo/ressalva/falha e as fotos do PC.
    param (
        [object[]]$Results,
        [datetime]$StartedAt,
        [datetime]$EndedAt = (Get-Date),
        $Before = $null,
        $After = $null,
        [string]$ProfileId = "",

        # A execução (o Otimizar grava duas vezes a mesma: no fim da parte automática e no fim); "" nas antigas.
        [string]$RunId = ""
    )

    $rows = @($Results | Where-Object { $null -ne $_ })

    $count = {
        param ([string]$Kind)
        @($rows | Where-Object { $null -ne $_.PSObject.Properties["Kind"] -and $_.Kind -eq $Kind }).Count
    }

    $seconds = [int][math]::Max(0, [math]::Round(($EndedAt - $StartedAt).TotalSeconds))

    return [PSCustomObject]@{
        StartedAt       = $StartedAt
        DurationSeconds = $seconds
        ProfileId       = $ProfileId
        RunId           = $RunId
        Ok              = [int](& $count "Ok")
        Warning         = [int](& $count "Warning")
        Failed          = [int](& $count "Failed")
        Skipped         = [int](& $count "Skipped")
        FreeBefore      = $(if ($null -ne $Before) { Get-SnakeOptimizerJsonValue -Object $Before -Name "FreeBytes" } else { $null })
        FreeAfter       = $(if ($null -ne $After) { Get-SnakeOptimizerJsonValue -Object $After -Name "FreeBytes" } else { $null })
        StartupBefore   = $(if ($null -ne $Before) { Get-SnakeOptimizerJsonValue -Object $Before -Name "StartupItems" } else { $null })
        StartupAfter    = $(if ($null -ne $After) { Get-SnakeOptimizerJsonValue -Object $After -Name "StartupItems" } else { $null })
        Steps           = @(
            foreach ($row in $rows) {
                [PSCustomObject]@{
                    Etapa   = [string](Get-SnakeOptimizerJsonValue -Object $row -Name "Etapa" -Default "")
                    Kind    = [string](Get-SnakeOptimizerJsonValue -Object $row -Name "Kind" -Default "")
                    Duracao = [string](Get-SnakeOptimizerJsonValue -Object $row -Name "Duracao" -Default "")
                    FreeBefore = Get-SnakeOptimizerJsonValue -Object $row -Name "FreeBefore"
                    FreeAfter  = Get-SnakeOptimizerJsonValue -Object $row -Name "FreeAfter"
                }
            }
        )
    }
}


function ConvertFrom-SnakeOptimizerMaintenanceHistoryDocument {
    # Uma linha do JSON como entrada do histórico. Linha ilegível = $null; campos que faltam ficam nulos ou zerados.
    param ($Document)

    if ($null -eq $Document) {
        return $null
    }

    try {
        $startedAt = [datetime]::Parse([string](Get-SnakeOptimizerJsonValue -Object $Document -Name "StartedAt"), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)

        $number = {
            param ([string]$Name)
            $value = Get-SnakeOptimizerJsonValue -Object $Document -Name $Name
            if ($null -eq $value) { return $null }
            return [int64]$value
        }

        return [PSCustomObject]@{
            StartedAt       = $startedAt
            DurationSeconds = [int](Get-SnakeOptimizerJsonValue -Object $Document -Name "DurationSeconds" -Default 0)
            ProfileId       = [string](Get-SnakeOptimizerJsonValue -Object $Document -Name "ProfileId" -Default "")
            RunId           = [string](Get-SnakeOptimizerJsonValue -Object $Document -Name "RunId" -Default "")
            Ok              = [int](Get-SnakeOptimizerJsonValue -Object $Document -Name "Ok" -Default 0)
            Warning         = [int](Get-SnakeOptimizerJsonValue -Object $Document -Name "Warning" -Default 0)
            Failed          = [int](Get-SnakeOptimizerJsonValue -Object $Document -Name "Failed" -Default 0)
            Skipped         = [int](Get-SnakeOptimizerJsonValue -Object $Document -Name "Skipped" -Default 0)
            FreeBefore      = (& $number "FreeBefore")
            FreeAfter       = (& $number "FreeAfter")
            StartupBefore   = (& $number "StartupBefore")
            StartupAfter    = (& $number "StartupAfter")
            Steps           = @(
                foreach ($step in @(Get-SnakeOptimizerJsonValue -Object $Document -Name "Steps" -Default @())) {
                    [PSCustomObject]@{
                        Etapa   = [string](Get-SnakeOptimizerJsonValue -Object $step -Name "Etapa" -Default "")
                        Kind    = [string](Get-SnakeOptimizerJsonValue -Object $step -Name "Kind" -Default "")
                        Duracao = [string](Get-SnakeOptimizerJsonValue -Object $step -Name "Duracao" -Default "")
                        FreeBefore = $(if ($null -ne (Get-SnakeOptimizerJsonValue -Object $step -Name "FreeBefore")) { [int64]$step.FreeBefore } else { $null })
                        FreeAfter  = $(if ($null -ne (Get-SnakeOptimizerJsonValue -Object $step -Name "FreeAfter")) { [int64]$step.FreeAfter } else { $null })
                    }
                }
            )
        }
    }
    catch {
        return $null
    }
}


function Get-SnakeOptimizerMaintenanceHistory {
    # As manutenções registradas, da mais recente para a mais antiga (a ordem em que foram gravadas, e não a das datas: com
    # o relógio atrasado, uma manutenção nova teria data "antiga"). Arquivo ausente ou ilegível = lista vazia (um arquivo
    # estragado volta da cópia anterior). -Status devolve também o estado da leitura, para quem vai gravar.
    param ([switch]$Status)

    $read = [PSCustomObject]@{ Status = "Unreadable"; Document = $null }

    try {
        $read = Read-SnakeOptimizerStateFile -Path (Get-SnakeOptimizerMaintenanceHistoryPath)

        if ($null -eq $read.Document) {
            if ($Status) { return [PSCustomObject]@{ Status = $read.Status; Entries = @() } }
            return @()
        }

        $document = $read.Document

        $entries = @(
            foreach ($row in @($document)) {
                $entry = ConvertFrom-SnakeOptimizerMaintenanceHistoryDocument -Document $row
                if ($null -ne $entry) { $entry }
            }
        )

        if ($Status) { return [PSCustomObject]@{ Status = $read.Status; Entries = $entries } }
        return $entries
    }
    catch {
        if ($Status) { return [PSCustomObject]@{ Status = "Unreadable"; Entries = @() } }
        return @()
    }
}


function Add-SnakeOptimizerMaintenanceHistory {
    # Acrescenta uma entrada e mantém só as últimas. Devolve $true se gravou.
    param (
        [Parameter(Mandatory)]
        $Entry
    )

    try {
        return [bool](Invoke-SnakeOptimizerStateLock -ScriptBlock { Save-SnakeOptimizerMaintenanceHistoryEntry -Entry $Entry })
    }
    catch {
        return $false
    }
}


function Save-SnakeOptimizerMaintenanceHistoryEntry {
    # O ler-acrescentar-gravar de Add-SnakeOptimizerMaintenanceHistory (que o faz dentro da trava).
    param (
        [Parameter(Mandatory)]
        $Entry
    )

    try {
        $current = Get-SnakeOptimizerMaintenanceHistory -Status

        # Sem conseguir ler o histórico gravado, gravar agora deixaria só esta entrada.
        if ($current.Status -eq "Unreadable") { return $false }

        # A mesma execução gravada de novo (o Otimizar grava ao fim da parte automática e outra vez no fim) substitui a
        # entrada dela, reconhecida pelo RunId: o histórico não fica com a mesma manutenção duas vezes. Sem RunId (as
        # gravadas por versões anteriores), nada é substituído.
        $runId = [string](Get-SnakeOptimizerJsonValue -Object $Entry -Name "RunId" -Default "")
        $existing = @($current.Entries | Where-Object {
            $null -ne $_ -and ([string]::IsNullOrEmpty($runId) -or [string](Get-SnakeOptimizerJsonValue -Object $_ -Name "RunId" -Default "") -ne $runId)
        })
        # A nova entra na frente e a mais antiga gravada sai: ordenar pela data descartaria a nova se o relógio estivesse
        # atrasado (bateria da placa-mãe fraca, por exemplo), com a gravação dizendo que deu certo.
        $all = @(@($Entry) + $existing | Select-Object -First (Get-SnakeOptimizerMaintenanceHistoryLimit))

        $documents = @(
            foreach ($item in $all) {
                [ordered]@{
                    StartedAt       = ([datetime]$item.StartedAt).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
                    DurationSeconds = $item.DurationSeconds
                    ProfileId       = $item.ProfileId
                    RunId           = [string](Get-SnakeOptimizerJsonValue -Object $item -Name "RunId" -Default "")
                    Ok              = $item.Ok
                    Warning         = $item.Warning
                    Failed          = $item.Failed
                    Skipped         = $item.Skipped
                    FreeBefore      = $item.FreeBefore
                    FreeAfter       = $item.FreeAfter
                    StartupBefore   = $item.StartupBefore
                    StartupAfter    = $item.StartupAfter
                    Steps           = @(
                        foreach ($step in @($item.Steps)) {
                            [ordered]@{ Etapa = $step.Etapa; Kind = $step.Kind; Duracao = $step.Duracao; FreeBefore = (Get-SnakeOptimizerJsonValue -Object $step -Name "FreeBefore"); FreeAfter = (Get-SnakeOptimizerJsonValue -Object $step -Name "FreeAfter") }
                        }
                    )
                }
            }
        )

        # Um único item continua lista no JSON.
        Write-SnakeOptimizerStateJson -Path (Get-SnakeOptimizerMaintenanceHistoryPath) -InputObject $documents -Depth 5 -AsList

        return $true
    }
    catch {
        return $false
    }
}


# ---------------------------------------------------------------------------
# Histórico de mudanças (o diário; o desfazer e a tela ficam em Journal.psm1)
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerChangeJournalPath {
    return (Join-Path (Get-SnakeOptimizerDataPath) "changes.json")
}


function Get-SnakeOptimizerChangeJournalLimit {
    return 200
}


function Get-SnakeOptimizerChanges {
    # As mudanças anotadas, da mais recente para a mais antiga. Arquivo ausente ou ilegível = nenhuma (um arquivo estragado
    # volta da cópia anterior). -Status devolve também o estado da leitura, para quem vai gravar.
    param ([switch]$Status)

    $read = [PSCustomObject]@{ Status = "Unreadable"; Document = $null }
    try { $read = Read-SnakeOptimizerStateFile -Path (Get-SnakeOptimizerChangeJournalPath) } catch { $read = [PSCustomObject]@{ Status = "Unreadable"; Document = $null } }

    $document = $read.Document

    if ($null -eq $document) {
        if ($Status) { return [PSCustomObject]@{ Status = $read.Status; Changes = @() } }
        return @()
    }

    $entries = @(
        foreach ($item in @(Get-SnakeOptimizerJsonValue -Object $document -Name "Changes" -Default @())) {
            $at = [datetime]::MinValue
            $atText = [string](Get-SnakeOptimizerJsonValue -Object $item -Name "At" -Default "")

            if (-not [datetime]::TryParse($atText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) { continue }

            [PSCustomObject]@{
                Id     = [string](Get-SnakeOptimizerJsonValue -Object $item -Name "Id" -Default "")
                At     = $at
                Action = [string](Get-SnakeOptimizerJsonValue -Object $item -Name "Action" -Default "")
                Text   = [string](Get-SnakeOptimizerJsonValue -Object $item -Name "Text" -Default "")
                Undo   = (Get-SnakeOptimizerJsonValue -Object $item -Name "Undo" -Default $null)
                Undone = [bool](Get-SnakeOptimizerJsonValue -Object $item -Name "Undone" -Default $false)
            }
        }
    )

    $sorted = @($entries | Where-Object { $_.Id } | Sort-Object -Property At -Descending)

    if ($Status) { return [PSCustomObject]@{ Status = $read.Status; Changes = $sorted } }
    return $sorted
}


function Save-SnakeOptimizerChanges {
    # Grava a lista inteira (as mais recentes até o limite). Falha em silêncio: o diário nunca interrompe uma ação.
    param (
        [AllowEmptyCollection()][object[]]$Changes = @()
    )

    try {
        $kept = @($Changes | Sort-Object -Property At -Descending | Select-Object -First (Get-SnakeOptimizerChangeJournalLimit))
        $document = [ordered]@{
            Format  = "SnakeOptimizer.Changes"
            Version = 1
            Changes = @($kept | ForEach-Object {
                    [ordered]@{
                        Id     = $_.Id
                        At     = ([datetime]$_.At).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
                        Action = $_.Action
                        Text   = $_.Text
                        Undo   = $_.Undo
                        Undone = [bool]$_.Undone
                    }
                })
        }

        Write-SnakeOptimizerStateJson -Path (Get-SnakeOptimizerChangeJournalPath) -InputObject $document -Depth 8

        return $true
    }
    catch {
        return $false
    }
}


function Add-SnakeOptimizerChange {
    <#
    Anota uma mudança. Action é o nome curto ("Limpeza do registro"); Text, o que mudou ("12 entradas removidas"). Undo
    é $null (não dá para desfazer) ou uma hashtable com Kind e os dados de Undo-SnakeOptimizerChange: registry (File),
    startup (Items), tweak (Id) ou feature (Name, Action). Devolve o Id da mudança ("" se não foi possível anotar).
    #>
    param (
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Text,
        $Undo = $null,
        [datetime]$At = (Get-Date)
    )

    # Anotar nunca interrompe a ação que mudou o PC: qualquer falha aqui só deixa a mudança fora do histórico.
    try {
        $id = [guid]::NewGuid().ToString("N").Substring(0, 12)

        $saved = Invoke-SnakeOptimizerStateLock -ScriptBlock {
            $current = Get-SnakeOptimizerChanges -Status

            # Sem conseguir ler o diário gravado, gravar agora deixaria só esta mudança: as outras perderiam o desfazer.
            if ($current.Status -eq "Unreadable") { return $false }

            $changes = @($current.Changes) + @([PSCustomObject]@{ Id = $id; At = $At; Action = $Action; Text = $Text; Undo = $Undo; Undone = $false })
            return (Save-SnakeOptimizerChanges -Changes $changes)
        }

        if ($saved) { return $id }
    }
    catch {
        Write-Verbose "Histórico de mudanças: $($_.Exception.Message)"
    }

    return ""
}


function Set-SnakeOptimizerChangeUndone {
    param (
        [Parameter(Mandatory)][string]$Id
    )

    [void](Invoke-SnakeOptimizerStateLock -ScriptBlock {
            $current = Get-SnakeOptimizerChanges -Status
            if ($current.Status -eq "Unreadable") { return }

            $changes = @($current.Changes)

            foreach ($change in $changes) {
                if ($change.Id -eq $Id) { $change.Undone = $true }
            }

            [void](Save-SnakeOptimizerChanges -Changes $changes)
        })
}


function Set-SnakeOptimizerChangesUndone {
    # Marca como desfeitas as mudanças ainda ativas de um tipo com um dado valor (por exemplo, o ajuste "explorer.ext"
    # desfeito pela página Ajustes do Windows): elas não aparecem mais para desfazer. Falha em silêncio.
    param (
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    try {
        [void](Invoke-SnakeOptimizerStateLock -ScriptBlock {
                $current = Get-SnakeOptimizerChanges -Status
                if ($current.Status -eq "Unreadable") { return }

                $changes = @($current.Changes)
                $marked = 0

                foreach ($change in $changes) {
                    if ($change.Undone -or $null -eq $change.Undo) { continue }
                    if ([string](Get-SnakeOptimizerJsonValue -Object $change.Undo -Name "Kind" -Default "") -ne $Kind) { continue }
                    if ([string](Get-SnakeOptimizerJsonValue -Object $change.Undo -Name $Key -Default "") -ne $Value) { continue }

                    $change.Undone = $true
                    $marked++
                }

                if ($marked -gt 0) { [void](Save-SnakeOptimizerChanges -Changes $changes) }
            })
    }
    catch {
        Write-Verbose "Histórico de mudanças: $($_.Exception.Message)"
    }
}


function Test-SnakeOptimizerChangeUndoable {
    # Se a mudança tem como ser desfeita agora (tem o modo de desfazer e ainda não foi desfeita).
    param (
        [Parameter(Mandatory)]$Change
    )

    if ($Change.Undone -or $null -eq $Change.Undo) { return $false }

    return -not [string]::IsNullOrWhiteSpace([string](Get-SnakeOptimizerJsonValue -Object $Change.Undo -Name "Kind" -Default ""))
}


function Add-SnakeOptimizerUninstalledProgram {
    # Guarda o nome e o ID de um programa desinstalado pelo SnakeOptimizer, para a busca de restos (os 50 mais recentes).
    param (
        [Parameter(Mandatory)][string]$Name,
        [string]$Id = ""
    )

    try {
        [void](Invoke-SnakeOptimizerStateLock -ScriptBlock {
                $list = @(Get-SnakeOptimizerSetting -Name "UninstalledPrograms" -Default @()) | Where-Object { $null -ne $_ -and [string](Get-SnakeOptimizerJsonValue -Object $_ -Name "Name" -Default "") -ne $Name }
                $list = @([PSCustomObject]@{ Name = $Name; Id = $Id; At = (Get-Date).ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture) }) + @($list) | Select-Object -First 50
                [void](Set-SnakeOptimizerSetting -Name "UninstalledPrograms" -Value @($list))
            })
    }
    catch {
        Write-Verbose "Não foi possível guardar o programa desinstalado: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function *
