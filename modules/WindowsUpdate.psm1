# Windows Update dentro do SnakeOptimizer: procurar, escolher, baixar e instalar as atualizações pendentes, com progresso.
#
# Usa a API COM do próprio Windows Update (Microsoft.Update.Session), a mesma de Get-SnakeOptimizerPendingWindowsUpdates. O
# trabalho roda em outro runspace (Invoke-SnakeOptimizerInBackground cuida só da consulta): enquanto ele baixa e instala, a
# tela acompanha o progresso e o botão Parar continua funcionando.
#
# As atualizações opcionais (BrowseOnly: drivers opcionais e prévias) não entram na instalação do Windows: o Windows só
# as oferece na página de atualizações opcionais. Os drivers (Criteria com Type='Driver', em Drivers.psm1) usam a mesma
# busca e a mesma instalação, com os opcionais incluídos e marcados como tal (BrowseOnly).
#
# Quando o Windows Update em si falha (cache corrompido, serviço desativado), Repair-SnakeOptimizerWindowsUpdate refaz o cache
# como manda a Microsoft: para os serviços, põe de lado as pastas Download e DataStore e o catroot2, e liga tudo de novo.


# ---------------------------------------------------------------------------
# Acesso ao Windows Update (código que roda no outro runspace)
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerUpdateComFactoryCode {
    # Cria a sessão do Windows Update e a coleção de atualizações. É um texto para que os testes troquem o Windows
    # Update de verdade por um de mentira, sem mudar o restante do código.
    return @'
@{
    Session       = (New-Object -ComObject "Microsoft.Update.Session" -ErrorAction Stop)
    NewCollection = { New-Object -ComObject "Microsoft.Update.UpdateColl" -ErrorAction Stop }
}
'@
}


function Get-SnakeOptimizerUpdateSessionCode {
    <#
    Abre a sessão do Windows Update ($com e $session), como texto para os dois scripts que rodam no outro runspace. Com o
    componente COM do Windows Update quebrado ou não registrado, New-Object falha e, sem esta parada, o script seguia com
    a sessão nula até "You cannot call a method on a null-valued expression". O erro sai com a marca SnakeOptimizer.SemSessao e o
    código do Windows (0x...) quando houver; Get-SnakeOptimizerWindowsUpdateProblem o traduz para a pessoa.
    #>
    return @'
try {
    $com = & ([scriptblock]::Create($FactoryCode))
    $session = $null
    if ($null -ne $com) { $session = $com.Session }
    if ($null -eq $session) { throw "sem sessão" }
}
catch {
    $sessionCode = 0
    $problem = $_.Exception

    while ($null -ne $problem) {
        $codeMatch = [regex]::Match([string]$problem.Message, '0x[0-9A-Fa-f]{8}')

        if ($codeMatch.Success) { $sessionCode = [Convert]::ToInt32($codeMatch.Value.Substring(2), 16); break }

        # Os HResult genéricos do .NET e do PowerShell não dizem nada sobre a causa.
        if ($problem.HResult -lt 0 -and $problem.HResult -notin @(-2146233088, -2146233087, -2146233079, -2146232832)) { $sessionCode = $problem.HResult; break }

        $problem = $problem.InnerException
    }

    throw ("SnakeOptimizer.SemSessao:0x{0:X8}" -f $sessionCode)
}
'@
}


function Get-SnakeOptimizerUpdateSearchCode {
    <#
    A busca padrão das atualizações, como texto (roda no outro runspace, que não enxerga as funções do SnakeOptimizer). Só um
    Windows Update que não conhece o critério BrowseOnly (WU_E_INVALID_CRITERIA, 0x80240032) ganha a busca sem ele; um
    erro de verdade (sem internet, serviço parado) volta como erro, em vez de virar uma segunda busca que traria também
    os opcionais (prévias e drivers) como se fossem atualizações comuns.
    #>
    return @'
if (-not [string]::IsNullOrEmpty($Criteria)) {
    $found = $searcher.Search($Criteria)
}
else {
    try {
        $found = $searcher.Search("IsInstalled=0 and IsHidden=0 and BrowseOnly=0")
    }
    catch {
        $invalidCriteria = $false
        $problem = $_.Exception

        while ($null -ne $problem) {
            # -2145124302 = 0x80240032 (WU_E_INVALID_CRITERIA).
            if ($problem.HResult -eq -2145124302 -or [string]$problem.Message -match '0x80240032') { $invalidCriteria = $true }
            $problem = $problem.InnerException
        }

        if (-not $invalidCriteria) { throw }

        $found = $searcher.Search("IsInstalled=0 and IsHidden=0")
    }
}
'@
}


function Get-SnakeOptimizerUpdateSearchScript {
    # Com "Stop", o primeiro erro encerra a busca e é ele que volta para a tela (e não um erro posterior, consequência dele).
    $text = @'
param ($FactoryCode, $Criteria)

$ErrorActionPreference = "Stop"

__SESSION__

$searcher = $session.CreateUpdateSearcher()

__SEARCH__

foreach ($update in $found.Updates) {
    $kb = ""

    try {
        $firstKb = @($update.KBArticleIDs) | Select-Object -First 1

        if ($null -ne $firstKb) { $kb = [string]$firstKb }
    }
    catch {
        $kb = ""
    }

    $browseOnly = $false
    try { $browseOnly = [bool]$update.BrowseOnly } catch { $browseOnly = $false }

    # Type 2 = driver (IWindowsDriverUpdate): a classe (Display, Net...) e o aparelho dizem para que ele serve, o que o
    # título ("Intel - System - 10.1.1.44"), muitas vezes repetido para aparelhos diferentes, não diz.
    $driver = $false
    $driverClass = ""
    $driverModel = ""

    try { $driver = ([int]$update.Type -eq 2) } catch { $driver = $false }

    if ($driver) {
        try { $driverClass = [string]$update.DriverClass } catch { $driverClass = "" }
        try { $driverModel = [string]$update.DriverModel } catch { $driverModel = "" }
    }

    # Uma versão nova do Windows (a classificação Upgrades, pelo Id, que não muda com o idioma): o Otimizar a deixa de
    # fora, porque troca o Windows inteiro e leva horas.
    $upgrade = $false

    try {
        foreach ($category in $update.Categories) {
            if ([string]$category.CategoryID -eq "3689bdc8-b205-4af4-8d4a-a63924c5e9d5") { $upgrade = $true }
        }
    }
    catch {
        $upgrade = $false
    }

    # A atualização cumulativa informa como máximo o pacote completo com todas as variantes (dezenas de GB), mas o
    # Windows baixa só a parte que falta (centenas de MB). Acima de 6 GB, fora uma versão nova do Windows, o número não
    # serve para nada: fica 0 ("o Windows calcula na hora").
    $size = [int64]$update.MaxDownloadSize
    if ($size -gt 6GB -and -not $upgrade) { $size = [int64]0 }

    [PSCustomObject]@{
        Id          = [string]$update.Identity.UpdateID
        Title       = [string]$update.Title
        Kb          = $kb
        Size        = $size
        Downloaded  = [bool]$update.IsDownloaded
        BrowseOnly  = $browseOnly
        Driver      = $driver
        DriverClass = $driverClass.Trim()
        DriverModel = $driverModel.Trim()
        Upgrade     = $upgrade
    }
}
'@

    return $text.Replace("__SESSION__", (Get-SnakeOptimizerUpdateSessionCode)).Replace("__SEARCH__", (Get-SnakeOptimizerUpdateSearchCode))
}


function Get-SnakeOptimizerUpdateInstallScript {
    # Procura de novo (primeiro no que o Windows guardou da busca que montou a lista), separa as escolhidas pelo Id, baixa
    # e instala. Escreve o andamento em $State (tabela sincronizada) e nunca lança erro: qualquer falha vai para
    # $State.Error. $State.Done fica verdadeiro ao final.
    # Escolhidas que o Windows deixou de oferecer vão para $State.Missing (Ids) e as que não foram baixadas, para
    # $State.NotDownloaded (Ids): nenhuma some do resumo em silêncio. Junto do texto do erro vai o HRESULT de origem
    # ($State.ErrorHResult), para a tela dizer o código mesmo quando a mensagem não o traz.
    $text = @'
param ($State, $Ids, $FactoryCode, $Criteria)

$ErrorActionPreference = "Stop"

# BeginDownload e BeginInstall mostram o andamento; quando o Windows recusa o próprio pedido assíncrono (o tipo dos
# parâmetros), o método síncrono faz o mesmo sem o andamento. Um erro do Windows Update (0x8024xxxx) ou do Windows
# (0x8007xxxx: serviço parado, disco cheio, sem conexão) não melhora com uma segunda tentativa: volta como erro.
$isUpdateError = {
    param ($exception)

    $current = $exception

    while ($null -ne $current) {
        $code = "{0:X8}" -f [int]$current.HResult
        if (($code.StartsWith("8024") -or $code.StartsWith("8007")) -and $code -ne "80070057") { return $true }
        $current = $current.InnerException
    }

    return $false
}

# Andamento de um trabalho (download ou instalação) para a tela: a atualização da vez, quanto dela já foi, a fase do
# download e, em $State.Finished, cada uma que terminou (com o código do Windows), na hora em que termina.
$track = {
    param ($Progress, $Collection, $Phase, [ref]$Reported)

    $State.Percent = [int]$Progress.PercentComplete
    $index = [int]$Progress.CurrentUpdateIndex
    $State.Index = $index + 1

    try { $State.Current = [string]$Collection.Item($index).Title } catch { }
    try { $State.CurrentPercent = [int]$Progress.CurrentUpdatePercentComplete } catch { $State.CurrentPercent = -1 }

    if ($Phase -eq "Baixando") {
        try {
            $State.Bytes = [int64]$Progress.CurrentUpdateBytesDownloaded
            $State.BytesTotal = [int64]$Progress.CurrentUpdateBytesToDownload
            $State.DownloadPhase = [int]$Progress.CurrentUpdateDownloadPhase
        }
        catch { }
    }

    # As anteriores à da vez já terminaram.
    while ($Reported.Value -lt $index) {
        $code = 0
        try { $code = [int]$Progress.GetUpdateResult($Reported.Value).ResultCode } catch { }
        [void]$State.Finished.Add([PSCustomObject]@{ Phase = $Phase; Title = [string]$Collection.Item($Reported.Value).Title; Code = $code })
        $Reported.Value++
    }
}

# As que terminaram junto com o trabalho (a última, ou todas, sem andamento).
$finish = {
    param ($Result, $Collection, $Phase, $From)

    for ($i = $From; $i -lt $Collection.Count; $i++) {
        $code = 0
        try { $code = [int]$Result.GetUpdateResult($i).ResultCode } catch { }
        [void]$State.Finished.Add([PSCustomObject]@{ Phase = $Phase; Title = [string]$Collection.Item($i).Title; Code = $code })
    }
}

try {
__SESSION__

    $State.Phase = "Procurando"
    $searcher = $session.CreateUpdateSearcher()

    # A busca (Get-SnakeOptimizerUpdateSearchCode) deixa o resultado em $found.
    $runSearch = {
__SEARCH__

        return $found
    }

    # A lista que a pessoa acabou de ver veio de uma busca online, e o Windows guarda o resultado dela: a busca neste PC
    # (Online = falso) acha as mesmas em segundos. Só quando falta alguma escolhida a busca vai ao Windows Update de novo.
    $found = $null

    try {
        $searcher.Online = $false
        $local = & $runSearch
        $localIds = @(foreach ($update in $local.Updates) { [string]$update.Identity.UpdateID })

        if (@(@($Ids) | Where-Object { $localIds -notcontains [string]$_ }).Count -eq 0) { $found = $local }
    }
    catch {
        $found = $null
    }

    if ($null -eq $found) {
        try { $searcher.Online = $true } catch { }
        $found = & $runSearch
    }

    $selected = New-Object System.Collections.ArrayList

    foreach ($update in $found.Updates) {
        if (@($Ids) -contains [string]$update.Identity.UpdateID) {
            [void]$selected.Add($update)
        }
    }

    foreach ($id in @($Ids)) {
        $present = $false

        foreach ($update in $selected) {
            if ([string]$update.Identity.UpdateID -eq [string]$id) { $present = $true; break }
        }

        if (-not $present) {
            [void]$State.Missing.Add([string]$id)
        }
    }

    if ($selected.Count -eq 0) {
        $State.Error = "as atualizações escolhidas não estão mais disponíveis"
        return
    }

    $State.Total = $selected.Count

    foreach ($update in $selected) {
        if (-not $update.EulaAccepted) {
            $update.AcceptEula()
        }
    }

    # Baixar só o que ainda não foi baixado.
    $toDownload = & $com.NewCollection

    foreach ($update in $selected) {
        if (-not $update.IsDownloaded) {
            [void]$toDownload.Add($update)
        }
    }

    if ($toDownload.Count -gt 0) {
        $State.Phase = "Baixando"
        $State.Percent = 0
        $State.Index = 0
        $State.Total = $toDownload.Count
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toDownload

        $job = $null
        $reported = 0

        try { $job = $downloader.BeginDownload($null, $null, $null) } catch { if (& $isUpdateError $_.Exception) { throw }; $job = $null }

        if ($null -ne $job) {
            while (-not $job.IsCompleted) {
                & $track $job.GetProgress() $toDownload "Baixando" ([ref]$reported)
                Start-Sleep -Milliseconds 500
            }

            $downloadResult = $downloader.EndDownload($job)
        }
        else {
            $downloadResult = $downloader.Download()
        }

        & $finish $downloadResult $toDownload "Baixando" $reported

        $State.Percent = 100

        if ([int]$downloadResult.ResultCode -notin 2, 3) {
            # Só os códigos: a frase é montada do lado da tela (Get-SnakeOptimizerUpdateDownloadError), que conhece os erros.
            $State.DownloadCode = [int]$downloadResult.ResultCode
            try { $State.DownloadHResult = [int]$downloadResult.HResult } catch { $State.DownloadHResult = 0 }
            return
        }

        # Com o código 3 o Windows baixou só parte: o que ficou sem baixar não pode ser instalado.
        foreach ($update in $selected) {
            if (-not $update.IsDownloaded) {
                [void]$State.NotDownloaded.Add([string]$update.Identity.UpdateID)
            }
        }
    }

    # Instalar o que está baixado.
    $toInstall = & $com.NewCollection

    foreach ($update in $selected) {
        if ($update.IsDownloaded) {
            [void]$toInstall.Add($update)
        }
    }

    if ($toInstall.Count -eq 0) {
        $State.Error = "nenhuma das atualizações foi baixada, então nada foi instalado"
        return
    }

    $installer = $session.CreateUpdateInstaller()

    # O Windows instala uma coisa de cada vez: se as Configurações (ou o RMM) já estão instalando, espera elas terminarem
    # em vez de falhar com "outra operação em andamento". A tela mostra que está esperando o Windows.
    try {
        while ([bool]$installer.IsBusy) {
            $State.Phase = "EsperandoWindows"
            Start-Sleep -Seconds 2
        }
    }
    catch { }

    $State.Phase = "Instalando"
    $State.Percent = 0
    $State.Index = 0
    $State.Total = $toInstall.Count

    $installer.Updates = $toInstall

    try { $installer.AllowSourcePrompts = $false } catch { }

    $job = $null
    $reported = 0
    $State.Bytes = 0
    $State.BytesTotal = 0

    try { $job = $installer.BeginInstall($null, $null, $null) } catch { if (& $isUpdateError $_.Exception) { throw }; $job = $null }

    if ($null -ne $job) {
        while (-not $job.IsCompleted) {
            & $track $job.GetProgress() $toInstall "Instalando" ([ref]$reported)
            Start-Sleep -Milliseconds 500
        }

        $installResult = $installer.EndInstall($job)
    }
    else {
        $installResult = $installer.Install()
    }

    & $finish $installResult $toInstall "Instalando" $reported

    $State.Percent = 100

    for ($i = 0; $i -lt $toInstall.Count; $i++) {
        $one = $installResult.GetUpdateResult($i)

        [void]$State.Results.Add([PSCustomObject]@{
                Title   = [string]$toInstall.Item($i).Title
                Code    = [int]$one.ResultCode
                HResult = [int]$one.HResult
            })
    }

    $State.RebootRequired = [bool]$installResult.RebootRequired
}
catch {
    $State.Error = [string]$_.Exception.Message

    try {
        $inner = $_.Exception
        while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
        $State.ErrorHResult = [int]$inner.HResult
    }
    catch {
        $State.ErrorHResult = 0
    }
}
finally {
    $State.Done = $true
}
'@

    return $text.Replace("__SESSION__", (Get-SnakeOptimizerUpdateSessionCode)).Replace("__SEARCH__", (Get-SnakeOptimizerUpdateSearchCode))
}


# ---------------------------------------------------------------------------
# Lista, resultados e textos
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerWindowsUpdateHResultText {
    <#
    Uma frase para os códigos de erro mais comuns do Windows Update (os nomes e significados são os da tabela de
    códigos do Windows Update Agent e da página de erros comuns do Windows Update, da Microsoft; os 0x8007xxxx e
    0x800Fxxxx são erros do Windows). "" para os demais. Quando o caminho é refazer o cache do Windows Update ou reparar
    os arquivos do Windows, a frase aponta o item do SnakeOptimizer que faz isso.
    #>
    param ([int]$HResult)

    $cache = "use Atualizações > Corrigir o Windows Update"
    $store = "use Reparo > Reparar o Windows (DISM + SFC)"

    switch ("0x{0:X8}" -f $HResult) {
        "0x80240016" { return "outra instalação estava em andamento ou falta reiniciar o PC" }
        "0x8024200D" { return "a atualização precisa ser baixada de novo; se o erro voltar, $cache" }
        "0x80246007" { return "a atualização não foi baixada; se o erro voltar, $cache" }
        "0x80242006" { return "os dados da atualização guardados no PC estão inválidos; $cache" }
        "0x80248007" { return "falta informação no cache do Windows Update; $cache" }
        "0x8007000D" { return "o que foi baixado veio corrompido; $cache" }
        "0x80246008" { return "o serviço de transferência do Windows (BITS) não respondeu; $cache" }
        "0x80240034" { return "o download falhou (costuma ser download preso na fila ou cache corrompido); $cache" }
        "0x800F0820" { return "a instalação foi cancelada no meio (reinício, desligamento ou outra atualização cumulativa ao mesmo tempo); reinicie e instale de novo, uma ferramenta de cada vez" }
        "0x8024001E" { return "o Windows estava desligando ou o serviço parou" }
        "0x8024000B" { return "a operação foi cancelada" }
        "0x8024001F" { return "sem conexão com a internet" }
        "0x8024402C" { return "não foi possível chegar ao servidor do Windows Update (endereço não encontrado)" }
        "0x80072EFD" { return "não foi possível conectar ao servidor do Windows Update" }
        "0x80072EFE" { return "a conexão com o Windows Update caiu no meio" }
        "0x80072EE2" { return "a conexão com o Windows Update esgotou o tempo" }
        "0x8024401C" { return "o servidor do Windows Update demorou demais para responder" }
        "0x80244017" { return "o servidor recusou o acesso (um proxy ou firewall pode estar bloqueando)" }
        "0x80244018" { return "o servidor recusou o acesso (um proxy ou firewall pode estar bloqueando)" }
        "0x80244022" { return "o servidor do Windows Update está sobrecarregado; tente mais tarde" }
        "0x8024002E" { return "uma política do Windows bloqueia o acesso ao Windows Update" }
        "0x80070422" { return "o serviço Windows Update está desativado; $cache" }
        "0x80070070" { return "falta espaço no disco" }
        "0x80070020" { return "um arquivo estava em uso por outro programa, como um antivírus" }
        "0x80070BC9" { return "o Windows precisa reiniciar para desfazer uma instalação anterior; reinicie o PC e tente de novo" }
        "0x80073712" { return "a imagem do Windows está danificada; $store" }
        "0x80073701" { return "faltam arquivos do Windows de que a atualização precisa; $store" }
        "0x800F081F" { return "faltam arquivos do Windows de que a atualização precisa; $store" }
        "0x800F0831" { return "faltam arquivos do Windows de que a atualização precisa; $store" }
    }

    return ""
}


function Format-SnakeOptimizerUpdateError {
    # "frase — erro 0x80240016", ou só "erro 0x8024XXXX" para um código sem frase. "" sem código.
    param ([int]$HResult)

    if ($HResult -eq 0) { return "" }

    $code = "0x{0:X8}" -f $HResult
    $text = Get-SnakeOptimizerWindowsUpdateHResultText -HResult $HResult

    if ($text) { return "$text — erro $code" }

    return "erro $code"
}


function Get-SnakeOptimizerWindowsUpdateProblem {
    <#
    O motivo de a consulta (ou a instalação) ter falhado, para a pessoa. A mensagem do PowerShell embrulha a do Windows
    ('Exception calling "Search" with "1" argument(s): "Exception from HRESULT: 0x80070422"'): sai o embrulho, e um
    código conhecido vira frase. HResult é o código da exceção de origem: vale quando a mensagem não traz código nenhum
    (uma mensagem do Windows em texto puro), e o código vai junto da frase, para a pessoa poder pesquisá-lo.
    #>
    param (
        [string]$Message,
        [int]$HResult = 0
    )

    $text = ([string]$Message).Trim()

    while ($text -match '^Exception calling "[^"]+" with "[0-9]+" argument\(s\): "(.*)"$') {
        $text = $Matches[1].Trim()
    }

    # A sessão do Windows Update não abriu (Get-SnakeOptimizerUpdateSessionCode): componente COM quebrado, não registrado ou
    # serviço que não responde. A frase diz isso; um código conhecido acrescenta o motivo, e o código vai junto.
    if ($text -match 'SnakeOptimizer\.SemSessao:0x([0-9A-Fa-f]{8})') {
        $sessionCode = [Convert]::ToInt32($Matches[1], 16)
        $base = "o Windows Update não abriu neste PC"

        if ($sessionCode -eq 0) { return "$base (o componente dele não respondeu)" }

        $phrase = Get-SnakeOptimizerWindowsUpdateHResultText -HResult $sessionCode

        return "$base ($(if ($phrase) { $phrase } else { 'o componente dele não respondeu' })) — erro $("0x{0:X8}" -f $sessionCode)"
    }

    if ($text -match '0x([0-9A-Fa-f]{8})') {
        return (Format-SnakeOptimizerUpdateError -HResult ([Convert]::ToInt32($Matches[1], 16)))
    }

    # Os códigos genéricos do .NET e do PowerShell não dizem nada e ficam de fora (Get-SnakeOptimizerErrorCode).
    $code = Get-SnakeOptimizerErrorCode -HResult $HResult

    if ($code) {
        $phrase = Get-SnakeOptimizerWindowsUpdateHResultText -HResult $HResult

        if ($phrase) { return "$phrase — erro $code" }
        if ([string]::IsNullOrWhiteSpace($text)) { return "erro $code" }

        return "$($text.TrimEnd('.')) — erro $code"
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return "o Windows Update devolveu um erro" }

    return $text.TrimEnd(".")
}


function Find-SnakeOptimizerWindowsUpdates {
    <#
    Procura as atualizações pendentes. Devolve Updates (Id, Title, Kb, Size em bytes, Downloaded e BrowseOnly; lista vazia
    = o Windows está em dia) e Problem: "" quando a consulta funcionou, ou o motivo de não ter funcionado (Updates fica
    $null). Criteria troca a busca padrão (por exemplo, só drivers).
    #>
    param (
        [int]$TimeoutSeconds = 300,

        [string]$FactoryCode = (Get-SnakeOptimizerUpdateComFactoryCode),

        [string]$Criteria = ""
    )

    try {
        $run = Invoke-SnakeOptimizerInBackground -ScriptBlock ([scriptblock]::Create((Get-SnakeOptimizerUpdateSearchScript))) -ArgumentList @($FactoryCode, $Criteria) -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        return [PSCustomObject]@{ Updates = $null; Problem = (Get-SnakeOptimizerWindowsUpdateProblem -Message $_.Exception.Message -HResult $_.Exception.HResult) }
    }

    if ($run.TimedOut) {
        $minutes = [int][math]::Ceiling($TimeoutSeconds / 60)
        return [PSCustomObject]@{ Updates = $null; Problem = "o Windows Update não respondeu em $(Format-SnakeOptimizerCount -Count $minutes -One 'minuto' -Many 'minutos')" }
    }

    if (-not $run.Completed) {
        return [PSCustomObject]@{ Updates = $null; Problem = (Get-SnakeOptimizerWindowsUpdateProblem -Message $run.Error) }
    }

    return [PSCustomObject]@{
        Updates = @($run.Output | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) })
        Problem = ""
    }
}


function Get-SnakeOptimizerUpdateOutcome {
    # Traduz o código de resultado do Windows Update (0 e 1 = não terminou, 2 = instalada, 3 = com erros, 4 = falhou,
    # 5 = interrompida), com o código de erro de cada atualização quando houver.
    param (
        [int]$Code,

        [int]$HResult = 0
    )

    $errorText = Format-SnakeOptimizerUpdateError -HResult $HResult

    switch ($Code) {
        2 { return (New-SnakeOptimizerResult -Kind Ok) }
        3 { return (New-SnakeOptimizerResult -Kind Warning -Detail $(if ($errorText) { "instalada com erros: $errorText" } else { "instalada com erros" })) }
        5 { return (New-SnakeOptimizerResult -Kind Failed -Detail "interrompida") }
        { $_ -in 0, 1 } { return (New-SnakeOptimizerResult -Kind Failed -Detail "não foi concluída") }
        default { return (New-SnakeOptimizerResult -Kind Failed -Detail $errorText) }
    }
}


function Get-SnakeOptimizerUpdateDownloadError {
    # O motivo de o download inteiro ter falhado (código 4) ou parado (código 5), com o erro do Windows quando houver.
    param (
        [int]$Code,

        [int]$HResult = 0
    )

    $errorText = Format-SnakeOptimizerUpdateError -HResult $HResult

    if ($Code -eq 5) { return "o download das atualizações foi interrompido" }
    if ($errorText) { return "o download das atualizações falhou: $errorText" }

    return "o download das atualizações falhou"
}


function Get-SnakeOptimizerUpdateRunDetail {
    <#
    A frase do resultado de uma instalação: quantas foram instaladas e o que deu errado. Ok = instaladas sem
    problema, Warned = instaladas com erros, Failed = não instaladas.
    #>
    param (
        [int]$Ok,

        [int]$Warned,

        [int]$Failed
    )

    $total = $Ok + $Warned + $Failed
    $installed = $Ok + $Warned

    if ($installed -eq 0) {
        if ($total -eq 1) { return "a atualização não foi instalada" }

        return "nenhuma das $total atualizações foi instalada"
    }

    if ($Failed -eq 0 -and $Warned -eq 0) {
        return (Format-SnakeOptimizerCount -Count $Ok -One "atualização instalada" -Many "atualizações instaladas")
    }

    $text = "$installed de $total $(if ($installed -eq 1) { 'instalada' } else { 'instaladas' })"

    if ($Warned -gt 0) { $text += " ($Warned com erros)" }
    if ($Failed -eq 1) { $text += "; 1 falhou" }
    elseif ($Failed -gt 1) { $text += "; $Failed falharam" }

    return $text
}


function Get-SnakeOptimizerUpdateTitleById {
    # O título da atualização com o Id dado, na lista que a pessoa viu; sem ela, o próprio Id.
    param (
        [object[]]$Updates,

        [Parameter(Mandatory)]
        [string]$Id
    )

    $match = @($Updates | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1

    if ($null -ne $match -and -not [string]::IsNullOrWhiteSpace([string]$match.Title)) {
        return [string]$match.Title
    }

    return $Id
}


function Get-SnakeOptimizerUpdateSizeText {
    # O tamanho para a pessoa: o Windows informa o máximo que o download pode ter (MaxDownloadSize); com as atualizações
    # expressas ele costuma ser menor, por isso "até".
    param ([Parameter(Mandatory)]$Update)

    if ($Update.Downloaded) { return "já baixada" }
    if ([int64]$Update.Size -gt 0) { return "até $(Format-SnakeOptimizerBytes -Bytes ([int64]$Update.Size))" }

    return "tamanho calculado pelo Windows na hora"
}


function Get-SnakeOptimizerUpdateDownloadText {
    # A linha "A baixar": a soma do que se sabe, avisando quando alguma atualização não tem tamanho informado.
    param ([object[]]$Updates)

    $pending = @($Updates | Where-Object { -not $_.Downloaded })
    if ($pending.Count -eq 0) { return "nada (já estão baixadas)" }

    $bytes = [int64]0
    foreach ($update in $pending) { $bytes += [int64]$update.Size }
    $unknown = @($pending | Where-Object { [int64]$_.Size -le 0 }).Count

    if ($bytes -le 0) { return "tamanho calculado pelo Windows na hora" }
    if ($unknown -gt 0) { return "até $(Format-SnakeOptimizerBytes -Bytes $bytes) + $(Format-SnakeOptimizerCount -Count $unknown -One 'atualização' -Many 'atualizações') com tamanho calculado na hora" }

    return "até $(Format-SnakeOptimizerBytes -Bytes $bytes)"
}


function Request-SnakeOptimizerWindowsUpdateScan {
    <#
    Pede ao Windows a mesma busca do botão "Verificar se há atualizações" das Configurações (UsoClient
    StartInteractiveScan). Assim a tela do Windows Update passa a mostrar o mesmo que o SnakeOptimizer achou, em vez de
    uma verificação antiga. Não espera nem falha: é só um pedido.
    #>
    try { Start-Process -FilePath (Join-Path $env:SystemRoot "System32\UsoClient.exe") -ArgumentList "StartInteractiveScan" -WindowStyle Hidden -ErrorAction Stop }
    catch { Write-Verbose "UsoClient: $($_.Exception.Message)" }
}


function Get-SnakeOptimizerDriverClassText {
    # A classe do driver no Windows Update (a classe de instalação do aparelho) com o nome que a pessoa conhece. Uma classe
    # sem tradução aqui aparece como veio; vazio sem classe.
    param ([string]$Class)

    switch -Regex (([string]$Class).Trim()) {
        '^Display$' { return "vídeo" }
        '^Net$' { return "rede" }
        '^Bluetooth$' { return "Bluetooth" }
        '^(MEDIA|AudioEndpoint|AudioProcessingObject)$' { return "som" }
        '^(Camera|Image)$' { return "câmera" }
        '^USB$' { return "USB" }
        '^(HIDClass|Keyboard|Mouse)$' { return "teclado, mouse ou touchpad" }
        '^System$' { return "sistema" }
        '^Firmware$' { return "firmware (como a BIOS)" }
        '^(Printer|PrintQueue)$' { return "impressora" }
        '^SoftwareComponent$' { return "programa de apoio do aparelho" }
        '^Extension$' { return "extensão de outro driver" }
        '^Biometric$' { return "biometria" }
        '^(SCSIAdapter|HDC|DiskDrive)$' { return "disco" }
        '^Monitor$' { return "monitor" }
        '^SecurityDevices$' { return "segurança (TPM)" }
        '^Sensor$' { return "sensores" }
        '^Battery$' { return "bateria" }
        '^$' { return "" }
    }

    return ([string]$Class).Trim()
}


function Get-SnakeOptimizerDriverPurposeText {
    <#
    Para que serve um driver da lista: "vídeo: Intel(R) UHD Graphics 620", só a classe ou só o aparelho; vazio sem nenhum
    dos dois. Prefix vai na frente quando há texto (" de " para "driver de vídeo: ...").
    #>
    param (
        [Parameter(Mandatory)]$Update,
        [string]$Prefix = ""
    )

    $class = Get-SnakeOptimizerDriverClassText -Class ([string](Get-SnakeOptimizerJsonValue -Object $Update -Name "DriverClass" -Default ""))
    $model = ([string](Get-SnakeOptimizerJsonValue -Object $Update -Name "DriverModel" -Default "")).Trim()

    if ($model.Length -gt 60) { $model = $model.Substring(0, 57) + "..." }

    $text = $(if ($class -and $model) { "${class}: $model" } elseif ($class) { $class } else { $model })

    return $(if ($text) { "$Prefix$text" } else { "" })
}


function Test-SnakeOptimizerFirmwareUpdate {
    # Se a atualização é de firmware (a BIOS/UEFI ou o de um componente): a que não pode ser interrompida de jeito nenhum.
    param ([Parameter(Mandatory)]$Update)

    return ([string](Get-SnakeOptimizerJsonValue -Object $Update -Name "DriverClass" -Default "")).Trim() -eq "Firmware"
}


function Write-SnakeOptimizerFirmwareWarning {
    # Um firmware entre as escolhidas: ele termina no reinício, e faltar energia no meio pode deixar o PC sem ligar.
    param ([AllowEmptyCollection()][object[]]$Updates = @())

    if (@($Updates | Where-Object { Test-SnakeOptimizerFirmwareUpdate -Update $_ }).Count -gt 0) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Há uma atualização de firmware (como a BIOS): ela termina no reinício. Não desligue o PC e, num notebook, deixe-o na tomada."
    }
}


function Write-SnakeOptimizerMeteredWarning {
    # Numa conexão limitada (plano de dados), avisa antes de baixar: o próprio Windows não baixaria sozinho.
    param ([int64]$Bytes = 0)

    if (-not (Test-SnakeOptimizerMeteredConnection)) { return }

    $what = $(if ($Bytes -gt 0) { "baixar até $(Format-SnakeOptimizerBytes -Bytes $Bytes)" } else { "baixar as atualizações" })
    Write-SnakeOptimizerStatus -Type Warning -Message "A conexão com a internet está marcada como limitada (plano de dados): $what pode consumir a sua franquia."
}


function Get-SnakeOptimizerUpdateOptionLabel {
    param ([Parameter(Mandatory)]$Update)

    if ([string]::IsNullOrWhiteSpace($Update.Kb)) {
        return $Update.Title
    }

    if ($Update.Title -match "KB$([regex]::Escape($Update.Kb))") {
        return $Update.Title
    }

    return "$($Update.Title) (KB$($Update.Kb))"
}


function Get-SnakeOptimizerWindowsUpdatePolicy {
    <#
    O que as políticas do Windows dizem sobre o Windows Update. Server: o servidor da empresa (WSUS) de onde as
    atualizações vêm, quando a política está ligada. Blocked: o acesso ao Windows Update desligado, por
    DisableWindowsUpdateAccess (nas duas chaves de política em que o Windows a lê) ou, sem servidor de empresa, por
    DoNotConnectToWindowsUpdateInternetLocations; as duas dão o erro 0x8024002E. Num PC de casa, quem costuma pôr essas
    políticas é um programa bloqueador de atualizações. Sem as chaves (o normal) ou sem leitura, nada.
    #>
    $key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $server = ""
    $blocked = $false

    try {
        $values = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        $au = Get-ItemProperty -LiteralPath "$key\AU" -ErrorAction SilentlyContinue

        if ([string](Get-SnakeOptimizerJsonValue -Object $au -Name "UseWUServer" -Default "0") -eq "1") {
            $server = ([string](Get-SnakeOptimizerJsonValue -Object $values -Name "WUServer" -Default "")).Trim()
        }

        $blocked = ([string](Get-SnakeOptimizerJsonValue -Object $values -Name "DisableWindowsUpdateAccess" -Default "0") -eq "1") -or
            (-not $server -and [string](Get-SnakeOptimizerJsonValue -Object $values -Name "DoNotConnectToWindowsUpdateInternetLocations" -Default "0") -eq "1")

        foreach ($other in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate")) {
            $value = Get-ItemProperty -LiteralPath $other -ErrorAction SilentlyContinue
            if ([string](Get-SnakeOptimizerJsonValue -Object $value -Name "DisableWindowsUpdateAccess" -Default "0") -eq "1") { $blocked = $true }
        }
    }
    catch {
        Write-Verbose "Políticas do Windows Update: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{ Server = $server; Blocked = $blocked }
}


function Write-SnakeOptimizerWindowsUpdatePolicyNote {
    <#
    Quando uma política muda de onde vêm as atualizações, a tela diz isso: é a explicação mais provável de uma consulta
    que falha, e nenhum reparo do SnakeOptimizer a muda. Devolve $true quando escreveu.
    #>
    $policy = Get-SnakeOptimizerWindowsUpdatePolicy
    $who = "Num PC de empresa, fale com o suporte de TI; num PC de casa, um programa bloqueador de atualizações costuma fazer isso: desfaça a configuração por ele."

    if ($policy.Blocked) {
        Write-SnakeOptimizerStatus -Type Info -Message "Uma política do Windows desliga o acesso ao Windows Update neste PC. $who"
        return $true
    }

    if ($policy.Server) {
        Write-SnakeOptimizerStatus -Type Info -Message "Uma política do Windows manda buscar as atualizações num servidor da empresa ($($policy.Server)), e não no Windows Update. $who"
        return $true
    }

    return $false
}


function Get-SnakeOptimizerWindowsUpdateControl {
    <#
    O que, além do acesso ao Windows Update, faz as Configurações dizerem "você está atualizado" enquanto há coisa
    pendente, ou faz a versão nova (25H2, 26H2...) nunca aparecer: atualização automática desligada por política (comum
    quando um RMM assume os patches), versão do Windows travada, atualização de versão bloqueada, adiamento e pausa.
    Devolve uma lista de textos (vazia no normal).
    #>
    $notes = New-Object System.Collections.Generic.List[string]
    $key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

    try {
        $values = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        $au = Get-ItemProperty -LiteralPath "$key\AU" -ErrorAction SilentlyContinue
        $ux = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -ErrorAction SilentlyContinue
        $get = { param ($Object, $Name) [string](Get-SnakeOptimizerJsonValue -Object $Object -Name $Name -Default "") }

        if ((& $get $au "NoAutoUpdate") -eq "1" -or (& $get $au "AUOptions") -eq "1") {
            $notes.Add("Uma política desliga a atualização automática (AU\$(if ((& $get $au 'NoAutoUpdate') -eq '1') { 'NoAutoUpdate=1' } else { 'AUOptions=1' })): o Windows não procura nem baixa sozinho, e as Configurações podem dizer ""atualizado"" com base numa verificação antiga. Costuma ser o RMM ou o antivírus assumindo os patches.")
        }
        elseif ((& $get $au "AUOptions") -eq "2") {
            $notes.Add("Uma política manda o Windows só avisar das atualizações (AUOptions=2): ele não baixa sozinho.")
        }

        if ((& $get $values "TargetReleaseVersion") -eq "1") {
            $notes.Add("Uma política trava o Windows na versão $(& $get $values 'TargetReleaseVersionInfo') ($(& $get $values 'ProductVersion')): a versão nova nunca é oferecida enquanto ela existir.")
        }

        if ((& $get $values "DisableOSUpgrade") -eq "1") {
            $notes.Add("Uma política bloqueia a atualização para a versão nova do Windows (DisableOSUpgrade=1).")
        }

        $defer = & $get $values "DeferFeatureUpdatesPeriodInDays"
        if ($defer -and [int]$defer -gt 0) { $notes.Add("Uma política adia a versão nova do Windows em $defer dias.") }

        $pause = & $get $ux "PauseUpdatesExpiryTime"
        if ($pause) {
            try { $until = [datetime]::Parse($pause, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime() } catch { $until = $null }
            if ($null -eq $until -or $until -gt (Get-Date)) { $notes.Add("As atualizações estão pausadas nas Configurações$(if ($until) { " até $($until.ToString('dd/MM/yyyy'))" }).") }
        }
    }
    catch {
        Write-Verbose "Controle do Windows Update: $($_.Exception.Message)"
    }

    return @($notes)
}


function Write-SnakeOptimizerWindowsUpdateControlNote {
    # Escreve o que Get-SnakeOptimizerWindowsUpdateControl achou. Devolve $true quando escreveu.
    $notes = @(Get-SnakeOptimizerWindowsUpdateControl)
    foreach ($note in $notes) { Write-SnakeOptimizerStatus -Type Warning -Message $note }
    return ($notes.Count -gt 0)
}


function Clear-SnakeOptimizerUpdateTransferQueues {
    <#
    O que deixa um download "baixando para sempre" mesmo com o cache refeito: a fila do BITS (trabalhos presos, de todos
    os usuários) e o cache da Otimização de Entrega (pedaços corrompidos que ela continua oferecendo). Devolve linhas de
    resultado para o resumo. Precisa do BITS ligado, então roda antes de parar os serviços.
    #>
    $rows = @()

    try {
        $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)
        $jobs | Remove-BitsTransfer -ErrorAction SilentlyContinue
        $row = New-SnakeOptimizerResult -Kind Ok -Detail $(if ($jobs.Count) { "$($jobs.Count) downloads presos cancelados" } else { "vazia" })
    }
    catch {
        $row = New-SnakeOptimizerResult -Kind Skipped -Detail "não foi possível ler: $($_.Exception.Message.TrimEnd('.'))"
    }
    $row.Etapa = "Fila de downloads (BITS)"
    $rows += $row

    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        try {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null
            $row = New-SnakeOptimizerResult -Kind Ok -Detail "limpo"
        }
        catch {
            $row = New-SnakeOptimizerResult -Kind Skipped -Detail "não foi possível limpar: $($_.Exception.Message.TrimEnd('.'))"
        }
        $row.Etapa = "Cache da Otimização de Entrega"
        $rows += $row
    }

    return $rows
}


function Write-SnakeOptimizerWindowsUpdateSearchHelp {
    <#
    O que fazer quando a consulta ao Windows Update falha, depois do motivo: a política que muda de onde vêm as
    atualizações, quando há uma; senão, se o motivo não é a conexão nem já diz o caminho, o reparo do Windows Update.
    #>
    param ([string]$Problem)

    if (Write-SnakeOptimizerWindowsUpdatePolicyNote) { return }
    if ($Problem -match 'Corrigir o Windows Update|Reparo >|internet|conectar|conexão|servidor|proxy|firewall|política|espaço') { return }

    # O reparo refaz o cache de atualizações e religa os serviços.
    Write-SnakeOptimizerStatus -Type Info -Message "Se o erro se repetir, use Atualizações > Corrigir o Windows Update."
}


# ---------------------------------------------------------------------------
# Acompanhamento
# ---------------------------------------------------------------------------

function Wait-SnakeOptimizerUpdateJob {
    <#
    Espera o trabalho do outro runspace mostrando o andamento na barra de progresso. Devolve $true se terminou e $false
    se o tempo esgotou. A espera é em fatias de um segundo, então o botão Parar continua valendo; ao ser interrompida, o
    chamador cuida de parar o runspace (o serviço do Windows Update pode continuar a instalar por conta própria).
    #>
    param (
        [Parameter(Mandatory)]
        $Handle,

        [Parameter(Mandatory)]
        $State,

        [int]$TimeoutMinutes = 180
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastKey = ""
    $shown = 0
    $itemKey = ""
    $itemSince = [System.Diagnostics.Stopwatch]::StartNew()

    while ($true) {
        $done = $Handle.AsyncWaitHandle.WaitOne(1000)

        # Cada atualização que terminou vira uma linha no registro, na hora: "Baixada: ...", "Instalada: ...".
        while ($shown -lt $State.Finished.Count) {
            $entry = $State.Finished[$shown]
            $shown++
            $verb = $(if ($entry.Phase -eq "Baixando") { "Baixada" } else { "Instalada" })

            switch ([int]$entry.Code) {
                2 { Write-SnakeOptimizerStatus -Type Success -Message "${verb}: $($entry.Title)" }
                3 { Write-SnakeOptimizerStatus -Type Warning -Message "$verb com ressalvas: $($entry.Title)" }
                5 { Write-SnakeOptimizerStatus -Type Warning -Message "Interrompida: $($entry.Title)" }
                4 { Write-SnakeOptimizerStatus -Type Error -Message "Falhou ($(if ($entry.Phase -eq 'Baixando') { 'download' } else { 'instalação' })): $($entry.Title)" }
                default { }
            }
        }

        if ($done) { break }

        if ($stopwatch.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
            return $false
        }

        if ($State.Phase -in "Baixando", "Instalando") {
            $activity = $(if ($State.Phase -eq "Baixando") { "Baixando as atualizações" } else { "Instalando as atualizações" })

            # Há quanto tempo a atualização da vez está nisso (o "travou?" de quem olha).
            $nowKey = "$($State.Phase)|$($State.Index)"
            if ($nowKey -ne $itemKey) { $itemKey = $nowKey; $itemSince.Restart() }
            $minutes = [int][math]::Floor($itemSince.Elapsed.TotalMinutes)

            $status = "$([math]::Max(1, [int]$State.Index)) de $($State.Total)"
            if (-not [string]::IsNullOrWhiteSpace([string]$State.Current)) { $status += ": $($State.Current)" }

            $detail = @()
            if ($State.Phase -eq "Baixando" -and [int]$State.DownloadPhase -eq 1) { $detail += "preparando o download" }
            elseif ($State.Phase -eq "Baixando" -and [int]$State.DownloadPhase -eq 3) { $detail += "conferindo o arquivo" }
            elseif ($State.Phase -eq "Baixando" -and [int64]$State.BytesTotal -gt 0) {
                $detail += "$(Format-SnakeOptimizerBytes -Bytes ([int64]$State.Bytes) -ZeroText '0 MB') de $(Format-SnakeOptimizerBytes -Bytes ([int64]$State.BytesTotal))"
            }
            if ([int]$State.CurrentPercent -ge 0) { $detail += "$([int]$State.CurrentPercent)% desta" }
            if ($minutes -ge 1) { $detail += "há $minutes min" }
            if ($detail.Count -gt 0) { $status += " · $($detail -join ' · ')" }

            # Parado em 0% muito tempo quase sempre é o Windows montando a atualização cumulativa, não travamento.
            if ($minutes -ge 5 -and [int]$State.CurrentPercent -le 0) { $status += " (o Windows ainda prepara esta; a cumulativa demora)" }

            $key = "$status|$($State.Percent)"
            if ($key -ne $lastKey) {
                $lastKey = $key
                Write-Progress -Activity $activity -Status $status -PercentComplete ([math]::Max(0, [math]::Min(100, [int]$State.Percent)))
            }
        }
        elseif ($State.Phase -eq "EsperandoWindows") {
            if ($lastKey -ne "esperando") {
                $lastKey = "esperando"
                Write-SnakeOptimizerStatus -Type Info -Message "O próprio Windows Update está instalando outras atualizações agora (pelas Configurações). O SnakeOptimizer espera ele terminar e continua sozinho."
                Write-Progress -Activity "Esperando o Windows Update" -Status "o Windows está instalando outras atualizações; acompanhe em Configurações > Windows Update"
            }
        }
        elseif ($lastKey -ne "preparando") {
            $lastKey = "preparando"
            # Antes de baixar, o Windows Update confere de novo as escolhidas, o que pode demorar.
            Write-Progress -Activity "Preparando a instalação" -Status "o Windows Update confere as atualizações escolhidas"
        }
    }

    return $true
}


function Invoke-SnakeOptimizerUpdateInstall {
    <#
    Baixa e instala as atualizações com os Ids dados, no outro runspace, acompanhando o progresso na tela. Devolve o
    estado final: Done, Error, Results (Title, Code, HResult), RebootRequired, TimedOut, Missing (Ids que o Windows
    deixou de oferecer) e NotDownloaded (Ids que não foram baixados).
    #>
    param (
        [Parameter(Mandatory)]
        [string[]]$Ids,

        [string]$FactoryCode = (Get-SnakeOptimizerUpdateComFactoryCode),

        [int]$TimeoutMinutes = 180,

        [string]$Criteria = ""
    )

    $state = [hashtable]::Synchronized(@{
            Phase          = "Preparando"
            Percent        = 0
            Index          = 0
            Total          = 0
            Current        = ""
            CurrentPercent = -1
            Bytes          = [int64]0
            BytesTotal     = [int64]0
            DownloadPhase  = 0
            Finished       = (New-Object System.Collections.ArrayList)
            Error          = ""
            ErrorHResult   = 0
            DownloadCode   = 0
            DownloadHResult = 0
            Done           = $false
            RebootRequired = $false
            Results        = (New-Object System.Collections.ArrayList)
            Missing        = (New-Object System.Collections.ArrayList)
            NotDownloaded  = (New-Object System.Collections.ArrayList)
        })

    $shell = [powershell]::Create()
    $finished = $false
    $timedOut = $false

    try {
        [void]$shell.AddScript((Get-SnakeOptimizerUpdateInstallScript))
        [void]$shell.AddArgument($state)
        [void]$shell.AddArgument($Ids)
        [void]$shell.AddArgument($FactoryCode)
        [void]$shell.AddArgument($Criteria)

        $handle = $shell.BeginInvoke()

        if (Wait-SnakeOptimizerUpdateJob -Handle $handle -State $state -TimeoutMinutes $TimeoutMinutes) {
            $finished = $true
            [void]$shell.EndInvoke($handle)
        }
        else {
            $timedOut = $true
        }
    }
    finally {
        Write-Progress -Activity "Instalando as atualizações" -Completed

        if ($finished) {
            $shell.Dispose()
        }
        else {
            # Interrompido ou sem resposta: pede para parar sem esperar uma chamada COM presa.
            try { [void]$shell.BeginStop($null, $null) } catch { }
        }
    }

    # O texto do erro passa pela mesma tradução da consulta: sem o embrulho do PowerShell, com a frase de um código
    # conhecido e sempre com o código. O download que falhou inteiro só deixa os códigos no estado (DownloadCode
    # diferente de zero).
    $errorText = [string]$state.Error
    if (-not [string]::IsNullOrWhiteSpace($errorText)) { $errorText = Get-SnakeOptimizerWindowsUpdateProblem -Message $errorText -HResult ([int]$state.ErrorHResult) }
    if ([int]$state.DownloadCode -ne 0) { $errorText = Get-SnakeOptimizerUpdateDownloadError -Code ([int]$state.DownloadCode) -HResult ([int]$state.DownloadHResult) }

    return [PSCustomObject]@{
        Done           = [bool]$state.Done
        Error          = $errorText
        Results        = @($state.Results)
        RebootRequired = [bool]$state.RebootRequired
        TimedOut       = $timedOut
        Missing        = @($state.Missing)
        NotDownloaded  = @($state.NotDownloaded)
    }
}


# ---------------------------------------------------------------------------
# Ação
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerUpdateSupportStatus {
    <#
    Até quando este Windows recebe atualizações de segurança (Get-SnakeOptimizerWindowsSupportStatus), para a tela não dizer
    "em dia" a um Windows sem suporte: a versão nova do Windows é opcional no Windows Update e não entra na lista. $null
    quando não foi possível saber.
    #>
    try {
        return (Get-SnakeOptimizerWindowsSupportStatus)
    }
    catch {
        Write-Verbose "Suporte do Windows: $($_.Exception.Message)"
        return $null
    }
}


function Test-SnakeOptimizerWindowsSupportEnded {
    # Verdadeiro quando este Windows não recebe mais atualizações de segurança: fora do suporte, ou só com o ESU, que
    # deu para conferir e não está instalado.
    param ($Status)

    if ($null -eq $Status) { return $false }

    $state = [string](Get-SnakeOptimizerJsonValue -Object $Status -Name "State" -Default "")

    return ($state -eq "Ended" -or ($state -eq "EsuAvailable" -and [bool](Get-SnakeOptimizerJsonValue -Object $Status -Name "EsuChecked" -Default $false)))
}


function Get-SnakeOptimizerSupportEndedText {
    # "o Windows 11 24H2 não recebe mais atualizações de segurança desde 13/10/2026" (sem a data quando ela não é conhecida).
    param ([Parameter(Mandatory)]$Status)

    $product = [string](Get-SnakeOptimizerJsonValue -Object $Status -Name "Product" -Default "")
    if ([string]::IsNullOrWhiteSpace($product)) { $product = "Windows" }

    $text = "o $product não recebe mais atualizações de segurança"
    $end = Get-SnakeOptimizerJsonValue -Object $Status -Name "EndDate" -Default $null

    if ($end -is [datetime]) { $text += " desde $(Format-SnakeOptimizerDateTime -When $end -Pattern 'dd/MM/yyyy')" }

    return $text
}


function Write-SnakeOptimizerUpdateSupportNote {
    <#
    O que a tela de atualizações diz sobre o suporte do Windows. Sem suporte: um aviso (com -NothingPending, no lugar do
    "em dia"), o que fazer e onde ver os detalhes. Perto do fim (ou sem conseguir conferir o ESU): uma linha de informação.
    Devolve $true quando o Windows está sem suporte.
    #>
    param (
        $Status,
        [switch]$NothingPending
    )

    if ($null -eq $Status) { return $false }

    $state = [string](Get-SnakeOptimizerJsonValue -Object $Status -Name "State" -Default "")

    if (Test-SnakeOptimizerWindowsSupportEnded -Status $Status) {
        $ended = Get-SnakeOptimizerSupportEndedText -Status $Status

        if ($NothingPending) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Não há atualizações pendentes, mas $ended."
        }
        else {
            Write-SnakeOptimizerStatus -Type Warning -Notice -Message "$($ended.Substring(0, 1).ToUpperInvariant())$($ended.Substring(1)): instalar as pendentes não muda isso."
        }

        $advice = [string](Get-SnakeOptimizerJsonValue -Object $Status -Name "Advice" -Default "")
        if ($advice) { Write-SnakeOptimizerStatus -Type Info -Message $advice }

        # A edição de longo prazo (LTSC) não recebe a versão nova pelo Windows Update.
        if ([string](Get-SnakeOptimizerJsonValue -Object $Status -Name "Class" -Default "") -ne "Ltsc") {
            Write-SnakeOptimizerStatus -Type Info -Message "Quando houver uma versão nova para este PC, ela aparece em Atualizações > Windows Update, no botão Baixar e instalar."
        }

        Write-SnakeOptimizerStatus -Type Info -Message "Detalhes em Diagnóstico > Suporte do Windows."
        return $true
    }

    if ($state -in @("EndingSoon", "EsuAvailable")) {
        $text = ([string](Get-SnakeOptimizerJsonValue -Object $Status -Name "Text" -Default "")).Trim()
        if ($text) { Write-SnakeOptimizerStatus -Type Info -Message "$text Veja Diagnóstico > Suporte do Windows." }
    }

    return $false
}


function Request-SnakeOptimizerRestartOffer {
    <#
    Oferece reiniciar ali mesmo (Request-SnakeOptimizerRestart, com Não como padrão), quando a tela pede um reinício. Um
    problema ao pedir o reinício não muda o resultado da ação: a tela só diz para reiniciar depois (Fallback).
    #>
    param (
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Comment,
        [Parameter(Mandatory)][string]$DeclinedMessage,
        [string]$Fallback = "Reinicie o PC quando puder."
    )

    try {
        [void](Request-SnakeOptimizerRestart -Reason $Reason -Comment $Comment -DeclinedMessage $DeclinedMessage)
    }
    catch {
        Write-Verbose "Oferta de reinício: $($_.Exception.Message)"
        Write-SnakeOptimizerStatus -Type Info -Message $Fallback
    }
}


function Request-SnakeOptimizerInstallRestart {
    # O reinício que conclui uma instalação (atualizações, drivers). What: o que falta terminar ("as atualizações");
    # Later: a frase de quem não reiniciou agora.
    param (
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string]$Later
    )

    Request-SnakeOptimizerRestartOffer -Reason "Para terminar de instalar $What, o Windows precisa reiniciar." `
        -Comment "Reinicialização solicitada pelo SnakeOptimizer para terminar de instalar $What." `
        -DeclinedMessage "Reinicialização não iniciada. $Later" `
        -Fallback "Reinicie o PC para terminar a instalação."
}


function Confirm-SnakeOptimizerUpdateConditions {
    <#
    Antes de procurar o que instalar pelo Windows Update (atualizações ou drivers): com um reinício pendente ou o
    notebook na bateria, a tela diz por que isso importa (Reboot, Battery) e pergunta, com Não como padrão. $true para
    seguir; $false quando a pessoa desistiu, com o que fazer já escrito. Quem não quis seguir sem reiniciar pode reiniciar
    dali mesmo (Request-SnakeOptimizerRestart, com Não como padrão); Retry é o item para abrir de novo depois.
    #>
    param (
        [Parameter(Mandatory)][string]$Reboot,
        [Parameter(Mandatory)][string]$Battery,
        [string]$Retry = "Atualizações > Instalar atualizações do Windows"
    )

    if (Test-SnakeOptimizerPendingReboot) {
        Write-SnakeOptimizerStatus -Type Warning -Message "Há um reinício pendente. $Reboot"

        if (-not (Confirm-SnakeOptimizerAction -Message "Continuar sem reiniciar?" -DefaultKey "N")) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
            Request-SnakeOptimizerRestartOffer -Reason "Reinicie agora e, depois, abra $Retry de novo." `
                -Comment "Reinicialização solicitada pelo SnakeOptimizer (reinício pendente antes de atualizar)." `
                -DeclinedMessage "Reinicialização não iniciada. Reinicie o PC e tente de novo." `
                -Fallback "Reinicie o PC e tente de novo."
            return $false
        }
    }

    if (Test-SnakeOptimizerOnBattery) {
        Write-SnakeOptimizerStatus -Type Warning -Message "O notebook está na bateria. $Battery"

        if (-not (Confirm-SnakeOptimizerAction -Message "Instalar mesmo assim?" -DefaultKey "N")) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
            Write-SnakeOptimizerStatus -Type Info -Message "Ligue o carregador e tente de novo."
            return $false
        }
    }

    return $true
}


function Get-SnakeOptimizerUpdateRunResult {
    <#
    O desfecho de uma instalação do Windows Update (Invoke-SnakeOptimizerUpdateInstall): a tabela com cada atualização, a
    anotação no Histórico de mudanças e o SnakeOptimizer.Result, com Data.RebootRequired quando alguma instalada pede o
    reinício. Chosen: as atualizações que a pessoa viu (para dar nome às que não chegaram a ser instaladas).
    #>
    param (
        [Parameter(Mandatory)]$Run,
        [AllowEmptyCollection()][object[]]$Chosen = @(),
        [string]$Title = "",
        [string]$SectionTitle = "Resumo"
    )

    $chosen = @($Chosen)
    $final = $null

    if ($run.TimedOut) {
        Write-SnakeOptimizerStatus -Type Warning -Message "O SnakeOptimizer parou de acompanhar depois de muito tempo. O Windows pode continuar instalando: veja o andamento em Atualizações > Windows Update."
        $final = New-SnakeOptimizerResult -Kind Warning -Detail "tempo esgotado; a instalação pode continuar" -Title $Title
    }
    elseif (-not [string]::IsNullOrWhiteSpace($run.Error) -and $run.Results.Count -eq 0) {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível instalar as atualizações: $($run.Error.TrimEnd('.'))."
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $run.Error -Title $Title
    }
    else {
        $results = @()

        foreach ($item in $run.Results) {
            $outcome = Get-SnakeOptimizerUpdateOutcome -Code $item.Code -HResult $item.HResult
            $outcome.Etapa = $item.Title
            $results += $outcome
        }

        # As escolhidas que não chegaram a ser instaladas também entram no resumo, com o nome que a pessoa viu.
        foreach ($id in @($run.NotDownloaded)) {
            $outcome = New-SnakeOptimizerResult -Kind Failed -Detail "não foi baixada"
            $outcome.Etapa = Get-SnakeOptimizerUpdateTitleById -Updates $chosen -Id $id
            $results += $outcome
        }

        foreach ($id in @($run.Missing)) {
            $outcome = New-SnakeOptimizerResult -Kind Failed -Detail "não está mais disponível"
            $outcome.Etapa = Get-SnakeOptimizerUpdateTitleById -Updates $chosen -Id $id
            $results += $outcome
        }

        Write-SnakeOptimizerSection -Title $SectionTitle
        Write-SnakeOptimizerResultTable -Results $results

        $failed = @($results | Where-Object { $_.Kind -eq "Failed" })
        $warned = @($results | Where-Object { $_.Kind -eq "Warning" })

        # O Histórico de mudanças anota o que foi instalado, pelo número KB quando houver (os títulos são longos).
        $installedNames = @(
            foreach ($item in @($run.Results)) {
                if ([int]$item.Code -notin 2, 3) { continue }
                $match = @($chosen | Where-Object { [string]$_.Title -eq [string]$item.Title }) | Select-Object -First 1
                if ($null -ne $match -and $match.Kb) { "KB$($match.Kb)" } else { [string]$item.Title }
            }
        )

        if ($installedNames.Count -gt 0) {
            [void](Add-SnakeOptimizerChange -Action "Atualizações do Windows" -Text "$(Format-SnakeOptimizerCount -Count $installedNames.Count -One 'instalada' -Many 'instaladas'): $(Join-SnakeOptimizerList -Items $installedNames)")
        }

        # "Reinicie para concluir" só faz sentido se alguma foi instalada; sem nenhuma, o motivo de cada uma diz o que fazer.
        $reboot = [bool]$run.RebootRequired -and $failed.Count -lt $results.Count

        $detail = Get-SnakeOptimizerUpdateRunDetail -Ok ($results.Count - $failed.Count - $warned.Count) -Warned $warned.Count -Failed $failed.Count

        # As contas e os motivos, para a faixa da janela (Set-SnakeOptimizerInstallView).
        $data = @{
            RebootRequired = $reboot
            Installed      = ($results.Count - $failed.Count)
            Failed         = $failed.Count
            Warned         = $warned.Count
            Problems       = @(@($failed) + @($warned) | ForEach-Object { [string]$_.Detail } | Where-Object { $_ })
        }

        # Um erro depois de algumas atualizações já terem resultado (por exemplo, ao ler o resultado das outras) deixa o
        # resumo incompleto: ele não pode sumir nem terminar como "Tudo certo".
        $cutShort = -not [string]::IsNullOrWhiteSpace($run.Error)

        if ($cutShort) {
            Write-SnakeOptimizerStatus -Type Error -Message "A instalação foi interrompida por um erro: $($run.Error.TrimEnd('.'))."
            $detail = "$detail; erro durante a instalação: $($run.Error)"
        }

        if ($failed.Count -eq $results.Count) {
            $final = New-SnakeOptimizerResult -Kind Failed -Detail $detail -Title $Title -Data $data
        }
        elseif ($failed.Count -gt 0 -or $warned.Count -gt 0 -or $cutShort) {
            $final = New-SnakeOptimizerResult -Kind Warning -Detail $detail -Title $Title -Data $data
        }
        else {
            $final = New-SnakeOptimizerResult -Kind Ok -Detail $detail -Title $Title -Data $data
        }
    }

    return $final
}


function Get-SnakeOptimizerUpdateFixStep {
    <#
    O item do SnakeOptimizer que resolve um erro do Windows Update, para o botão da faixa: os motivos (Get-SnakeOptimizerWindowsUpdateHResultText)
    já dizem "use Atualizações > Corrigir o Windows Update" ou "use Reparo > Reparar o Windows (DISM + SFC)" quando é o
    caso. Next e Label vazios quando nenhum motivo aponta um item.
    #>
    param ([AllowEmptyCollection()][string[]]$Texts = @())

    $all = (@($Texts) | Where-Object { $_ }) -join " | "

    if ($all -match 'Corrigir o Windows Update') { return [PSCustomObject]@{ Next = "updates.repair"; Label = "Corrigir o Windows Update" } }
    if ($all -match 'Reparar o Windows \(DISM \+ SFC\)') { return [PSCustomObject]@{ Next = "repair.dism-sfc"; Label = "Reparar o Windows" } }

    return [PSCustomObject]@{ Next = ""; Label = "" }
}


function Set-SnakeOptimizerInstallView {
    <#
    A faixa de uma instalação pelo Windows Update (atualizações ou drivers, Get-SnakeOptimizerUpdateRunResult e a dos drivers):
    o título diz quantas foram instaladas; a frase, se falta reiniciar (ou como voltar atrás, nos drivers) ou que o motivo
    de cada falha está no resumo; e, quando um motivo aponta um item do SnakeOptimizer, o botão para ele. Um, Many e None são
    os textos do que foi instalado ("atualização instalada", "atualizações", "Nenhuma atualização instalada"). OkNote: a
    frase de quando deu tudo certo sem reinício. Devolve o próprio resultado.
    #>
    param (
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$One,
        [Parameter(Mandatory)][string]$Many,
        [Parameter(Mandatory)][string]$Noun,
        [Parameter(Mandatory)][string]$None,
        [string]$OkNote = "Não precisa reiniciar.",
        [string]$Each = "cada uma",
        [string]$DoneMany = "instaladas"
    )

    $installed = Get-SnakeOptimizerResultData -Result $Result -Name "Installed"
    if ($null -eq $installed) { return $Result }

    $installed = [int]$installed
    $failed = [int](Get-SnakeOptimizerResultData -Result $Result -Name "Failed")
    $warned = [int](Get-SnakeOptimizerResultData -Result $Result -Name "Warned")
    $total = $installed + $failed
    $reboot = Test-SnakeOptimizerResultFlag -Result $Result -Name "RebootRequired"
    $fix = Get-SnakeOptimizerUpdateFixStep -Texts @(Get-SnakeOptimizerResultData -Result $Result -Name "Problems")

    if ($Result.Kind -eq "Ok") {
        return (Set-SnakeOptimizerResultView -Result $Result -Headline (Format-SnakeOptimizerCount -Count $installed -One $One -Many "$Many") `
                -Note $(if ($reboot) { "Reinicie o PC para terminar a instalação." } else { $OkNote }))
    }

    # O que deu errado, em números: o motivo de cada um fica no resumo, na linha dele.
    $parts = @()
    if ($failed -gt 0) { $parts += $(if ($failed -eq 1) { "1 falhou" } else { "$failed falharam" }) }
    if ($warned -gt 0) { $parts += "$warned com erros" }
    $reason = $(if ($total -eq 1 -or ($failed + $warned) -eq 1) { "o motivo está no resumo" } else { "o motivo de $Each está no resumo" })

    if ($Result.Kind -eq "Failed") {
        return (Set-SnakeOptimizerResultView -Result $Result -Headline $None -Note "$($reason.Substring(0, 1).ToUpper())$($reason.Substring(1))." -Next $fix.Next -NextLabel $fix.Label)
    }

    if ($Result.Kind -eq "Warning" -and $total -gt 0) {
        return (Set-SnakeOptimizerResultView -Result $Result -Headline "$installed de $total $Noun $DoneMany" `
                -Note "$($parts -join ' e '); $reason." -Next $fix.Next -NextLabel $fix.Label)
    }

    return $Result
}


function Set-SnakeOptimizerInstallErrorView {
    # A instalação que nem chegou a dar resultado (o Windows Update recusou antes, sem as contas de Set-SnakeOptimizerInstallView):
    # o título diz que não foi possível instalar, a frase traz o motivo e, quando ele aponta um item, o botão. Devolve o
    # próprio resultado.
    param ([Parameter(Mandatory)]$Result)

    $why = ([string]$Result.Detail).Trim().TrimEnd(".")

    if ($Result.Kind -ne "Failed" -or -not $why -or $null -ne (Get-SnakeOptimizerResultData -Result $Result -Name "Installed")) { return $Result }

    $fix = Get-SnakeOptimizerUpdateFixStep -Texts @($why)

    return (Set-SnakeOptimizerResultView -Result $Result -Headline "Não foi possível instalar" -Note ($why.Substring(0, 1).ToUpper() + $why.Substring(1) + ".") -Next $fix.Next -NextLabel $fix.Label)
}


function Set-SnakeOptimizerUpdateSearchView {
    # A faixa de quando o Windows Update não respondeu à consulta: o título diz isso, a frase traz o motivo e, quando ele
    # aponta um item do SnakeOptimizer, o botão. Devolve o próprio resultado.
    param (
        [Parameter(Mandatory)]$Result,
        [string]$Problem = ""
    )

    $text = ([string]$Problem).Trim().TrimEnd(".")
    $note = $(if ($text) { $text.Substring(0, 1).ToUpper() + $text.Substring(1) + "." } else { "" })
    $fix = Get-SnakeOptimizerUpdateFixStep -Texts @($text)

    return (Set-SnakeOptimizerResultView -Result $Result -Headline "O Windows Update não respondeu" -Note $note -Next $fix.Next -NextLabel $fix.Label)
}


function Test-SnakeOptimizerLatestUpdatesOptIn {
    # "Obtenha as atualizações mais recentes assim que elas estiverem disponíveis" (Configurações > Windows Update) ligado.
    try {
        return ([string](Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name IsContinuousInnovationOptedIn -ErrorAction Stop).IsContinuousInnovationOptedIn -eq "1")
    }
    catch {
        return $false
    }
}


function Install-SnakeOptimizerWindowsUpdates {
    $title = "Instalar atualizações do Windows"

    Enter-SnakeOptimizerAction -Title $title

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title

    try {
        if (-not (Test-SnakeOptimizerElevation -Reason "Instalar atualizações do Windows exige privilégios de Administrador.")) {
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Failed -Detail "requer Administrador" -Title $title)
            return
        }

        if (-not (Confirm-SnakeOptimizerUpdateConditions -Reboot "Reiniciar antes evita que as novas atualizações falhem." -Battery "Atualizar gasta bastante energia e não deve ser interrompido.")) {
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title)
            return
        }

        # O andamento vai para a barra de progresso: uma linha "procurando..." ficaria no resumo depois do fim.
        Write-Progress -Activity "Procurando atualizações" -Status "o Windows Update pode levar alguns minutos para responder"

        # A mesma busca vai para a tela do Windows Update, que passa a refletir o que for achado aqui.
        Request-SnakeOptimizerWindowsUpdateScan

        try {
            $search = Find-SnakeOptimizerWindowsUpdates
        }
        finally {
            Write-Progress -Activity "Procurando atualizações" -Completed
        }

        if ($null -eq $search.Updates) {
            Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível consultar o Windows Update: $($search.Problem)."
            Write-SnakeOptimizerWindowsUpdateSearchHelp -Problem $search.Problem
            Exit-SnakeOptimizerAction -Result (Set-SnakeOptimizerUpdateSearchView -Result (New-SnakeOptimizerResult -Kind Failed -Detail "não foi possível consultar o Windows Update: $($search.Problem)" -Title $title) -Problem $search.Problem)
            return
        }

        $updates = @($search.Updates)

        # A versão nova do Windows é opcional e não entra na lista: num Windows sem suporte, "em dia" seria falso.
        $support = Get-SnakeOptimizerUpdateSupportStatus

        if ($updates.Count -eq 0) {
            if (Test-SnakeOptimizerWindowsSupportEnded -Status $support) {
                [void](Write-SnakeOptimizerUpdateSupportNote -Status $support -NothingPending)
                $ended = New-SnakeOptimizerResult -Kind Warning -Detail "nada pendente, mas este Windows não recebe mais atualizações de segurança" -Title $title
                Exit-SnakeOptimizerAction -Result (Set-SnakeOptimizerResultView -Result $ended -Headline "Este Windows não recebe mais atualizações" `
                        -Note "Não há nada pendente, mas o suporte deste Windows terminou." -Next "diagnostics.windows-support" -NextLabel "Ver o suporte do Windows")
                return
            }

            Write-SnakeOptimizerStatus -Type Success -Message "O Windows está em dia: não há atualizações pendentes."
            [void](Write-SnakeOptimizerUpdateSupportNote -Status $support)
            Write-SnakeOptimizerStatus -Type Info -Message "Drivers ficam em Atualizações > Atualizar drivers."
            Exit-SnakeOptimizerAction -Result (Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Ok -Detail "o Windows está em dia" -Title $title) -Headline "O Windows está em dia" -Note "Não há atualizações pendentes.")
            return
        }

        [void](Write-SnakeOptimizerUpdateSupportNote -Status $support)

        # Explica por que as Configurações podem dizer "atualizado" enquanto a busca direta acha coisas pendentes.
        if (Write-SnakeOptimizerWindowsUpdateControlNote) {
            Write-SnakeOptimizerStatus -Type Info -Message "Por isso o Windows Update das Configurações pode mostrar ""atualizado"": o SnakeOptimizer pergunta direto ao serviço."
        }

        # As opcionais (BrowseOnly) vêm desmarcadas, como no Windows. A exceção espelha as Configurações: com "Obtenha as
        # atualizações mais recentes assim que estiverem disponíveis" ligado, o Windows instala as prévias sozinho, então
        # aqui elas também vêm marcadas (drivers opcionais continuam desmarcados).
        $previewsOn = Test-SnakeOptimizerLatestUpdatesOptIn
        $options = @(
            foreach ($update in $updates) {
                $optional = [bool](Get-SnakeOptimizerJsonValue -Object $update -Name "BrowseOnly" -Default $false)
                $driver = [bool](Get-SnakeOptimizerJsonValue -Object $update -Name "Driver" -Default $false)
                $parts = @()
                if ($optional) { $parts += $(if ($driver) { "opcional" } else { "prévia" }) }
                if ($driver) { $parts += "driver$(Get-SnakeOptimizerDriverPurposeText -Update $update -Prefix ' de ')" }
                $parts += Get-SnakeOptimizerUpdateSizeText -Update $update
                @{ Key = $update.Id; Label = (Get-SnakeOptimizerUpdateOptionLabel -Update $update); Description = ($parts -join " · "); Selected = ((-not $optional) -or ($previewsOn -and -not $driver)) }
            }
        )

        # As prévias desse botão o Windows só oferece para a própria tela, não para outros programas: elas aparecem nas
        # Configurações e não aqui. Os dois usam o mesmo serviço e um não atrapalha o outro.
        if ($previewsOn) {
            Write-SnakeOptimizerStatus -Type Info -Message "O Windows está com ""Obtenha as atualizações mais recentes"" ligado: ele mesmo baixa as prévias do mês (""Atualização Prévia""), que só aparecem em Configurações > Windows Update. Pode deixar os dois rodando: usam o mesmo serviço, e o SnakeOptimizer espera se o Windows estiver instalando."
        }

        if (@($updates | Where-Object { [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "BrowseOnly" -Default $false) }).Count -gt 0) {
            if ($previewsOn) {
                Write-SnakeOptimizerStatus -Type Info -Message "As prévias vêm marcadas porque o Windows está com ""Obtenha as atualizações mais recentes"" ligado (ele também as instala). Drivers opcionais vêm desmarcados."
            }
            else {
                Write-SnakeOptimizerStatus -Type Info -Message "As opcionais (prévias e drivers opcionais) vêm desmarcadas, como no Windows."
            }
        }

        # Na janela, Confirmar só fica disponível com algo marcado: voltar sem escolha é o Cancelar.
        $picked = Read-SnakeOptimizerMultiSelect -Message "Quais atualizações instalar?" -Options $options

        if ($null -eq $picked -or @($picked).Count -eq 0) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title)
            return
        }

        $chosen = @($updates | Where-Object { @($picked) -contains $_.Id })
        $download = [int64]0

        foreach ($pending in @($chosen | Where-Object { -not $_.Downloaded })) {
            $download += [int64]$pending.Size
        }

        $countText = Format-SnakeOptimizerCount -Count $chosen.Count -One "atualização" -Many "atualizações"
        $needsDownload = @($chosen | Where-Object { -not $_.Downloaded }).Count -gt 0

        Write-SnakeOptimizerKeyValue -Label "Atualizações escolhidas" -Value $chosen.Count
        Write-SnakeOptimizerKeyValue -Label "A baixar" -Value (Get-SnakeOptimizerUpdateDownloadText -Updates $chosen)
        Write-SnakeOptimizerFirmwareWarning -Updates $chosen
        if ($needsDownload) { Write-SnakeOptimizerMeteredWarning -Bytes $download }
        # Parado no meio, o Windows pode continuar instalando por conta própria.
        Write-SnakeOptimizerStatus -Type Info -Message "Não desligue o PC durante a instalação."
        Write-Host ""

        $question = $(if ($needsDownload) { "Baixar e instalar ${countText}?" } else { "Instalar ${countText}?" })

        if (-not (Confirm-SnakeOptimizerAction -Message $question -DefaultKey "S")) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title)
            return
        }

        $keepAwake = Set-SnakeOptimizerKeepAwake -Enabled $true

        try {
            $run = Invoke-SnakeOptimizerUpdateInstall -Ids @($chosen | ForEach-Object { $_.Id })
        }
        finally {
            if ($keepAwake) {
                [void](Set-SnakeOptimizerKeepAwake -Enabled $false)
            }
        }

        Write-Host ""

        $final = Get-SnakeOptimizerUpdateRunResult -Run $run -Chosen $chosen -Title $title
        [void](Set-SnakeOptimizerInstallView -Result $final -One "atualização instalada" -Many "atualizações instaladas" -Noun "atualizações" `
                -None $(if ($chosen.Count -eq 1) { "A atualização não foi instalada" } else { "Nenhuma atualização instalada" }))

        [void](Set-SnakeOptimizerInstallErrorView -Result $final)

        if (Test-SnakeOptimizerResultFlag -Result $final -Name "RebootRequired") {
            Request-SnakeOptimizerInstallRestart -What "as atualizações" -Later "As atualizações terminam de instalar quando você reiniciar o PC."
        }
    }
    catch {
        $problem = Get-SnakeOptimizerWindowsUpdateProblem -Message $_.Exception.Message -HResult $_.Exception.HResult
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível instalar as atualizações: $problem."
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $problem -Title $title
    }

    Exit-SnakeOptimizerAction -Result $final
}


function Get-SnakeOptimizerAllUpdatesCriteria {
    # A busca do Otimizar: tudo o que não está instalado nem escondido, inclusive as opcionais (BrowseOnly: prévias e
    # drivers opcionais), que a busca padrão deixa de fora.
    return "IsInstalled=0 and IsHidden=0"
}


function Install-SnakeOptimizerPendingUpdates {
    <#
    A etapa do Windows Update do Otimizar: procura e instala, sem perguntar, as atualizações que o Windows Update oferece e
    os drivers opcionais. Ficam de fora uma versão nova do Windows (troca o Windows inteiro e leva horas), um firmware
    opcional (como a BIOS: só com o Windows pedindo) e as prévias (as opcionais que não são drivers: as atualizações antes
    da hora, que o Otimizar desliga; o que elas trazem chega na atualização normal do mês seguinte). O reinício fica para
    o fim do Otimizar (Data.RebootRequired).
    #>
    param (
        [switch]$Embedded,
        [switch]$PassThru,

        # Manutenção automática: só o que o próprio Windows instalaria sozinho (drivers opcionais ficam de fora).
        [switch]$NoOptionalDrivers
    )

    $title = "Atualizar o Windows"

    Enter-SnakeOptimizerAction -Title $title -Embedded:$Embedded

    $final = $null

    try {
        Write-Progress -Activity "Procurando atualizações" -Status "o Windows Update pode levar alguns minutos para responder"

        # A mesma busca vai para a tela do Windows Update, que passa a refletir o que for achado aqui.
        Request-SnakeOptimizerWindowsUpdateScan

        try {
            # Sem ninguém esperando (a parte automática do Otimizar), a busca tem mais tempo: a primeira num PC que passou
            # meses sem atualizar pode levar mais de 5 minutos. O Parar continua funcionando durante a espera.
            $search = Find-SnakeOptimizerWindowsUpdates -Criteria (Get-SnakeOptimizerAllUpdatesCriteria) -TimeoutSeconds $(if ($Embedded) { 1200 } else { 300 })
        }
        finally {
            Write-Progress -Activity "Procurando atualizações" -Completed
        }

        if ($null -eq $search.Updates) {
            Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível consultar o Windows Update: $($search.Problem)."
            Write-SnakeOptimizerWindowsUpdateSearchHelp -Problem $search.Problem
            $final = New-SnakeOptimizerResult -Kind Failed -Detail "não foi possível consultar o Windows Update: $($search.Problem)" -Title $title
        }
        else {
            $updates = @($search.Updates)
            $upgrades = @($updates | Where-Object { [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "Upgrade" -Default $false) })
            $firmware = @($updates | Where-Object { -not [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "Upgrade" -Default $false) -and [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "BrowseOnly" -Default $false) -and (Test-SnakeOptimizerFirmwareUpdate -Update $_) })
            $previews = @($updates | Where-Object { -not [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "Upgrade" -Default $false) -and [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "BrowseOnly" -Default $false) -and -not [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "Driver" -Default $false) })
            $optionalDrivers = @()
            if ($NoOptionalDrivers) {
                $optionalDrivers = @($updates | Where-Object { [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "BrowseOnly" -Default $false) -and [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "Driver" -Default $false) -and @($firmware) -notcontains $_ })
            }

            $left = @(@($upgrades) + @($firmware) + @($previews) + @($optionalDrivers) | ForEach-Object { [string]$_.Id })
            $chosen = @($updates | Where-Object { $left -notcontains [string]$_.Id })

            # O que fica de fora, numa linha só (o porquê de cada um está no comentário da função).
            $leftNames = @(
                @($upgrades | ForEach-Object { "$($_.Title) (versão nova do Windows)" })
                @($firmware | ForEach-Object { "$($_.Title) (firmware opcional)" })
                @($previews | ForEach-Object { "$(Get-SnakeOptimizerUpdateOptionLabel -Update $_) (prévia)" })
                @($optionalDrivers | ForEach-Object { "$($_.Title) (driver opcional)" })
            )

            if ($leftNames.Count -gt 0) {
                Write-SnakeOptimizerStatus -Type Info -Message "$(if ($leftNames.Count -eq 1) { 'Ficou' } else { 'Ficaram' }) de fora: $(Join-SnakeOptimizerList -Items $leftNames)."
            }

            $support = Get-SnakeOptimizerUpdateSupportStatus

            if ($chosen.Count -eq 0) {
                if (Test-SnakeOptimizerWindowsSupportEnded -Status $support) {
                    [void](Write-SnakeOptimizerUpdateSupportNote -Status $support -NothingPending)
                    $final = New-SnakeOptimizerResult -Kind Warning -Detail "nada pendente, mas este Windows não recebe mais atualizações de segurança" -Title $title
                }
                else {
                    Write-SnakeOptimizerStatus -Type Success -Message "O Windows está em dia: não há atualizações pendentes."
                    [void](Write-SnakeOptimizerUpdateSupportNote -Status $support)
                    $final = New-SnakeOptimizerResult -Kind Ok -Detail "o Windows está em dia" -Title $title
                }
            }
            else {
                [void](Write-SnakeOptimizerUpdateSupportNote -Status $support)

                if (Write-SnakeOptimizerWindowsUpdateControlNote) {
                    Write-SnakeOptimizerStatus -Type Info -Message "Por isso o Windows Update das Configurações pode mostrar ""atualizado"": o SnakeOptimizer pergunta direto ao serviço."
                }

                $download = [int64]0
                foreach ($pending in @($chosen | Where-Object { -not $_.Downloaded })) { $download += [int64]$pending.Size }

                $optional = @($chosen | Where-Object { [bool](Get-SnakeOptimizerJsonValue -Object $_ -Name "BrowseOnly" -Default $false) }).Count
                $countText = Format-SnakeOptimizerCount -Count $chosen.Count -One "atualização" -Many "atualizações"
                if ($optional -gt 0) { $countText += " ($(Format-SnakeOptimizerCount -Count $optional -One 'opcional' -Many 'opcionais'))" }

                # Os nomes aparecem uma vez só, no fim, entre as instaladas.
                Write-SnakeOptimizerKeyValue -Label "A instalar" -Value $countText

                Write-SnakeOptimizerFirmwareWarning -Updates $chosen
                Write-SnakeOptimizerMeteredWarning -Bytes $download
                Write-Host ""

                $run = Invoke-SnakeOptimizerUpdateInstall -Ids @($chosen | ForEach-Object { $_.Id }) -Criteria (Get-SnakeOptimizerAllUpdatesCriteria)

                Write-Host ""
                $final = Get-SnakeOptimizerUpdateRunResult -Run $run -Chosen $chosen -Title $title -SectionTitle "Atualizações instaladas"
            }
        }
    }
    catch {
        $problem = Get-SnakeOptimizerWindowsUpdateProblem -Message $_.Exception.Message -HResult $_.Exception.HResult
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível instalar as atualizações: $problem."
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $problem -Title $title
    }

    if ($PassThru) { $final }
    Exit-SnakeOptimizerAction -Embedded:$Embedded -Result $final
}


# ---------------------------------------------------------------------------
# Corrigir o Windows Update
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerWindowsUpdateServices {
    <#
    Os serviços de que o Windows Update depende, com o tipo de inicialização padrão do Windows. Stop: os que o reparo
    para e liga de novo (na ordem de parar); o orquestrador de atualizações só volta ao padrão se estiver desativado.
    #>
    return @(
        [PSCustomObject]@{ Name = "wuauserv"; Label = "Windows Update"; Default = "Manual"; Stop = $true },
        [PSCustomObject]@{ Name = "bits"; Label = "Serviço de Transferência Inteligente de Plano de Fundo (BITS)"; Default = "Manual"; Stop = $true },
        [PSCustomObject]@{ Name = "cryptsvc"; Label = "Serviços de Criptografia"; Default = "Automatic"; Stop = $true },
        [PSCustomObject]@{ Name = "UsoSvc"; Label = "Orquestrador de atualizações (UsoSvc)"; Default = "Automatic"; Stop = $false }
    )
}


function Get-SnakeOptimizerWindowsUpdateCacheFolders {
    <#
    As pastas que a Microsoft manda pôr de lado para o Windows Update refazer o cache (página de erros comuns do Windows
    Update): os downloads, o banco de dados e o catálogo de assinaturas. Keep: a cópia fica guardada (.bak); os downloads
    são só cache, e a cópia é apagada para não ficar ocupando o disco.
    #>
    $windows = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($windows)) { $windows = [string]$env:windir }
    if ([string]::IsNullOrWhiteSpace($windows)) { $windows = "C:\Windows" }

    return @(
        [PSCustomObject]@{ Name = "Download"; Label = "Downloads do Windows Update"; Path = (Join-Path $windows "SoftwareDistribution\Download"); Keep = $false },
        [PSCustomObject]@{ Name = "DataStore"; Label = "Banco de dados do Windows Update"; Path = (Join-Path $windows "SoftwareDistribution\DataStore"); Keep = $true },
        [PSCustomObject]@{ Name = "catroot2"; Label = "Catálogo de assinaturas do Windows"; Path = (Join-Path $windows "System32\catroot2"); Keep = $true }
    )
}


function Test-SnakeOptimizerWindowsUpdateBusy {
    <#
    Se o Windows Update está instalando alguma coisa agora (IUpdateInstaller.IsBusy). Parar os serviços no meio de uma
    instalação a interromperia. A pergunta vai ao serviço, que pode estar travado (é por isso que a pessoa veio): sem
    resposta em 15 segundos, ou sem leitura, $false.
    #>
    try {
        $run = Invoke-SnakeOptimizerInBackground -ScriptBlock { [bool](New-Object -ComObject "Microsoft.Update.Installer" -ErrorAction Stop).IsBusy } -TimeoutSeconds 15
        return ($run.Completed -and @($run.Output | Where-Object { $_ -eq $true }).Count -gt 0)
    }
    catch {
        return $false
    }
}


function Get-SnakeOptimizerServiceState {
    <#
    Situação, tipo de inicialização e dependentes ligados de um serviço. Missing: o serviço não existe (um script de
    "limpeza" pode tê-lo removido); $null quando o Windows não respondeu.
    #>
    param ([Parameter(Mandatory)][string]$Name)

    try {
        $service = Get-Service -Name $Name -ErrorAction Stop

        return [PSCustomObject]@{
            Name       = $Name
            Missing    = $false
            Status     = [string]$service.Status
            StartType  = [string]$service.StartType
            Dependents = @($service.DependentServices | Where-Object { [string]$_.Status -eq "Running" } | ForEach-Object { [string]$_.Name })
        }
    }
    catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
            return [PSCustomObject]@{ Name = $Name; Missing = $true; Status = ""; StartType = ""; Dependents = @() }
        }

        return $null
    }
}


function Stop-SnakeOptimizerService {
    <#
    Para o serviço (e os que dependem dele) e espera até TimeoutSeconds. $true quando parou. Um serviço "parando" ou
    "iniciando" recusa o pedido de parar: a espera continua e o pedido é repetido, em vez de virar erro; um serviço preso
    não segura a tela para sempre.
    #>
    param (
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ($true) {
        $status = [string](Get-Service -Name $Name -ErrorAction Stop).Status

        if ($status -eq "Stopped") { return $true }

        if ($status -in @("Running", "Paused")) {
            try { Stop-Service -Name $Name -Force -NoWait -ErrorAction Stop } catch { Write-Verbose "Parar ${Name}: $($_.Exception.Message)" }
        }

        if ((Get-Date) -ge $deadline) { return $false }

        Start-Sleep -Milliseconds 500
    }
}


function Start-SnakeOptimizerService {
    param ([Parameter(Mandatory)][string]$Name)

    Start-Service -Name $Name -ErrorAction Stop
}


function Set-SnakeOptimizerServiceStartType {
    param (
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet("Manual", "Automatic")][string]$StartType
    )

    Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
}


function Move-SnakeOptimizerUpdateCacheFolder {
    <#
    Põe uma pasta do cache de lado (Nome.bak), apagando antes a cópia de uma vez anterior. Devolve um SnakeOptimizer.Result:
    Ok (Data.Backup = o caminho da cópia), Skipped (a pasta não existe; ou, com Data.Linked, é atalho para outro lugar)
    ou Failed (em uso, sem permissão). Uma pasta que é atalho (junção, de um programa que mudou o cache de disco) fica
    como está: apagar por ela apagaria o que está do outro lado.
    #>
    param ([Parameter(Mandatory)]$Folder)

    $path = [string]$Folder.Path

    if (-not (Test-Path -LiteralPath $path)) { return (New-SnakeOptimizerResult -Kind Skipped -Detail "a pasta não existia") }

    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop

        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return (New-SnakeOptimizerResult -Kind Skipped -Detail "a pasta aponta para outro lugar e ficou como está" -Data @{ Linked = $true })
        }

        $backupName = "$($Folder.Name).bak"
        $backup = Join-Path (Split-Path -Parent $path) $backupName

        # A cópia de uma vez anterior sai; se ela não sair (em uso, ou é atalho), a nova ganha a data no nome.
        if (Test-Path -LiteralPath $backup) {
            [void](Remove-SnakeOptimizerUpdateCacheBackup -Path $backup)

            if (Test-Path -LiteralPath $backup) {
                $backupName = "$($Folder.Name).bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                $backup = Join-Path (Split-Path -Parent $path) $backupName
            }
        }

        Rename-Item -LiteralPath $path -NewName $backupName -ErrorAction Stop
    }
    catch {
        $reason = $(if ($_.Exception -is [System.IO.IOException]) { "está em uso" } elseif ($_.Exception -is [System.UnauthorizedAccessException]) { "o Windows não deixou mexer" } else { $_.Exception.Message.TrimEnd(".") })
        return (New-SnakeOptimizerResult -Kind Failed -Detail "$reason; ficou como estava")
    }

    return (New-SnakeOptimizerResult -Kind Ok -Detail "guardado como $backupName" -Data @{ Backup = $backup })
}


function Remove-SnakeOptimizerUpdateCacheBackup {
    <#
    Apaga uma cópia posta de lado. Directory.Delete não entra em atalhos (junções) que estejam dentro dela, ao contrário
    de Remove-Item -Recurse no Windows PowerShell 5.1, que apagaria o que está do outro lado. Uma cópia que é ela mesma
    um atalho não é apagada. $true quando apagou.
    #>
    param ([Parameter(Mandatory)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop

        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }

        [System.IO.Directory]::Delete($item.FullName, $true)
        return $true
    }
    catch {
        Write-Verbose "Cópia $Path ficou: $($_.Exception.Message)"
        return $false
    }
}


function Get-SnakeOptimizerServiceNamesText {
    # "o serviço Windows Update" ou "os serviços Windows Update e BITS", com o verbo que vem depois concordando.
    param (
        [Parameter(Mandatory)][string[]]$Labels,
        [string]$One = "",
        [string]$Many = ""
    )

    $list = Join-SnakeOptimizerList -Items $Labels

    if ($Labels.Count -eq 1) { return ("o serviço $list $One").TrimEnd() }

    return ("os serviços $list $Many").TrimEnd()
}


function Repair-SnakeOptimizerWindowsUpdate {
    <#
    O reparo do Windows Update que a Microsoft indica quando as atualizações falham ou travam: para os serviços, põe de
    lado o cache (Get-SnakeOptimizerWindowsUpdateCacheFolders) e liga os serviços de novo. Um serviço desativado (por um
    "otimizador" ou bloqueador) volta antes para o tipo de inicialização padrão do Windows; se não voltar, nada mais é
    feito, porque o cache refeito não adiantaria. Políticas não são mudadas: a tela só diz quando há uma. Os serviços
    voltam a ligar mesmo se algo falhar no meio (finally), e os downloads postos de lado só são apagados depois disso.
    #>
    $title = "Corrigir o Windows Update"

    Enter-SnakeOptimizerAction -Title $title

    $final = New-SnakeOptimizerResult -Kind Ok -Title $title

    try {
        if (-not (Test-SnakeOptimizerElevation -Reason "Corrigir o Windows Update exige privilégios de Administrador.")) {
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Failed -Detail "requer Administrador" -Title $title)
            return
        }

        Write-Progress -Activity $title -Status "lendo os serviços do Windows Update"

        try {
            $services = @(
                foreach ($service in Get-SnakeOptimizerWindowsUpdateServices) {
                    [PSCustomObject]@{ Name = $service.Name; Label = $service.Label; Default = $service.Default; Stop = $service.Stop; State = (Get-SnakeOptimizerServiceState -Name $service.Name) }
                }
            )
            $medic = Get-SnakeOptimizerServiceState -Name "WaaSMedicSvc"
            $pending = Test-SnakeOptimizerPendingReboot
            $busy = Test-SnakeOptimizerWindowsUpdateBusy
        }
        finally {
            Write-Progress -Activity $title -Completed
        }

        # Parar os serviços no meio interromperia a instalação.
        $busyText = "O Windows Update está instalando atualizações agora: espere terminar."
        $busyHint = "O andamento fica em Atualizações > Windows Update; se o problema continuar, volte aqui."
        $busyResult = "o Windows Update está instalando atualizações agora; espere terminar"

        # A faixa de quando o Windows Update está instalando: o botão abre o andamento dele.
        $busyView = {
            Set-SnakeOptimizerResultView -Result (New-SnakeOptimizerResult -Kind Skipped -Detail $busyResult -Title $title) -Headline "O Windows Update está instalando agora" `
                -Note "Espere terminar; se o problema continuar, volte aqui." -Next "updates.windows" -NextLabel "Ver o andamento"
        }

        if ($busy) {
            Write-SnakeOptimizerStatus -Type Warning -Message $busyText
            Write-SnakeOptimizerStatus -Type Info -Message $busyHint
            Exit-SnakeOptimizerAction -Result (& $busyView)
            return
        }

        # Um serviço que não existe mais (removido por um script de "limpeza") não volta com este reparo.
        $missing = @($services | Where-Object { [bool](Get-SnakeOptimizerJsonValue -Object $_.State -Name "Missing" -Default $false) })
        $unread = @($services | Where-Object { $null -eq $_.State })

        if ($missing.Count -gt 0) {
            $names = Get-SnakeOptimizerServiceNamesText -Labels @($missing | ForEach-Object { $_.Label }) -One "não existe" -Many "não existem"
            Write-SnakeOptimizerStatus -Type Error -Message "$($names.Substring(0, 1).ToUpper())$($names.Substring(1)) neste Windows, e este reparo não o recria."
            Write-SnakeOptimizerStatus -Type Info -Message "Reparo > Recuperação pode reinstalar o Windows mantendo os seus arquivos."
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Failed -Detail "$names neste Windows" -Title $title)
            return
        }

        if ($unread.Count -gt 0) {
            $names = Get-SnakeOptimizerServiceNamesText -Labels @($unread | ForEach-Object { $_.Label })
            Write-SnakeOptimizerStatus -Type Error -Message "O Windows não respondeu sobre $names."
            Write-SnakeOptimizerStatus -Type Info -Message "Isso costuma ser dano nos arquivos do Windows: use Reparo > Reparar o Windows (DISM + SFC)."
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Failed -Detail "o Windows não respondeu sobre $names" -Title $title)
            return
        }

        # O reparo desliga os serviços, põe de lado o cache (os downloads, o banco de dados e o catálogo de assinaturas) e
        # liga os serviços de novo, como a Microsoft indica. O que a pessoa precisa saber antes: o histórico some.
        Write-SnakeOptimizerStatus -Type Info -Message "Refaz o cache do Windows Update: as atualizações instaladas ficam, mas o histórico delas recomeça vazio."

        $disabled = @($services | Where-Object { $_.State.StartType -eq "Disabled" })

        foreach ($service in $disabled) {
            Write-SnakeOptimizerStatus -Type Warning -Message "O serviço $($service.Label) está desativado: ele volta para o padrão do Windows ($(if ($service.Default -eq 'Manual') { 'manual' } else { 'automático' }))."
        }

        if ([string](Get-SnakeOptimizerJsonValue -Object $medic -Name "StartType" -Default "") -eq "Disabled") {
            # O Medic conserta o Windows Update sozinho; o Windows o protege, e o SnakeOptimizer não mexe nele.
            Write-SnakeOptimizerStatus -Type Warning -Message "O serviço Windows Update Medic (WaaSMedicSvc) está desativado: desfaça pelo programa que o desativou."
        }

        $policyNote = Write-SnakeOptimizerWindowsUpdatePolicyNote
        $controlNote = Write-SnakeOptimizerWindowsUpdateControlNote
        if ($policyNote -or $controlNote) {
            Write-SnakeOptimizerStatus -Type Info -Message "O reparo não muda políticas: se uma delas explica o problema, desfaça por quem a criou (RMM, GPO, bloqueador)."
        }

        Write-Host ""

        if ($pending) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Há um reinício pendente: reinicie antes, muitas vezes isso já resolve."

            if (-not (Confirm-SnakeOptimizerAction -Message "Corrigir sem reiniciar?" -DefaultKey "N")) {
                Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
                Request-SnakeOptimizerRestartOffer -Reason "Reinicie agora e, se o problema continuar, abra Atualizações > Corrigir o Windows Update de novo." `
                    -Comment "Reinicialização solicitada pelo SnakeOptimizer (reinício pendente antes de corrigir o Windows Update)." `
                    -DeclinedMessage "Reinicialização não iniciada. Reinicie o PC e, se o problema continuar, volte aqui." `
                    -Fallback "Reinicie o PC e, se o problema continuar, volte aqui."
                Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title)
                return
            }
        }
        elseif (-not (Confirm-SnakeOptimizerAction -Message "Corrigir o Windows Update agora?" -DefaultKey "S")) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Operação cancelada."
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário" -Title $title)
            return
        }

        # A pergunta pode ter ficado aberta enquanto o Windows começava a instalar sozinho.
        if (Test-SnakeOptimizerWindowsUpdateBusy) {
            Write-SnakeOptimizerStatus -Type Warning -Message $busyText
            Write-SnakeOptimizerStatus -Type Info -Message $busyHint
            Exit-SnakeOptimizerAction -Result (& $busyView)
            return
        }

        $rows = @()
        $restored = @()
        $stillDisabled = @()

        # 1. Os serviços desativados voltam ao padrão. Se algum não voltar, o Windows Update continua sem funcionar, e
        # refazer o cache (que esvazia o histórico das Configurações) não adiantaria: para aqui.
        foreach ($service in $disabled) {
            try {
                Set-SnakeOptimizerServiceStartType -Name $service.Name -StartType $service.Default
                $restored += $service.Label
                $row = New-SnakeOptimizerResult -Kind Ok -Detail "voltou para $(if ($service.Default -eq 'Manual') { 'manual' } else { 'automático' })"
            }
            catch {
                $stillDisabled += $service.Label
                $row = New-SnakeOptimizerResult -Kind Failed -Detail "continua desativado: $($_.Exception.Message.TrimEnd('.'))"
            }

            $row.Etapa = "Serviço $($service.Label)"
            $rows += $row
        }

        if ($restored.Count -gt 0) {
            [void](Add-SnakeOptimizerChange -Action "Corrigir o Windows Update" -Text "$(Get-SnakeOptimizerServiceNamesText -Labels $restored -One 'voltou' -Many 'voltaram') ao padrão do Windows")
        }

        if ($stillDisabled.Count -gt 0) {
            $names = Get-SnakeOptimizerServiceNamesText -Labels $stillDisabled -One "continua desativado" -Many "continuam desativados"
            Write-SnakeOptimizerSection -Title "Resumo"
            Write-SnakeOptimizerResultTable -Results $rows
            Write-SnakeOptimizerStatus -Type Warning -Message "$($names.Substring(0, 1).ToUpper())$($names.Substring(1)), e sem $(if ($stillDisabled.Count -eq 1) { 'ele' } else { 'eles' }) o Windows Update não funciona; um bloqueador de atualizações pode estar travando isso."
            Exit-SnakeOptimizerAction -Result (New-SnakeOptimizerResult -Kind Warning -Detail "$names; o cache não foi mexido" -Title $title)
            return
        }

        # 2. Para os serviços e põe o cache de lado; 3. liga tudo de novo (finally); 4. apaga os downloads postos de lado.
        $stopping = @($services | Where-Object { $_.Stop })
        $restart = New-Object System.Collections.ArrayList
        $moved = @()
        $stopProblem = ""
        $cryptStuck = $false

        try {
            # Downloads presos na fila do BITS e na Otimização de Entrega (o "fica baixando e nunca termina").
            Write-Progress -Activity $title -Status "cancelando downloads presos"
            $rows += @(Clear-SnakeOptimizerUpdateTransferQueues)

            Write-Progress -Activity $title -Status "desligando os serviços do Windows Update"

            # Quem depende de um serviço para junto com ele (Stop-Service -Force): esses voltam a ligar no fim.
            foreach ($service in $stopping) {
                foreach ($dependent in @($service.State.Dependents)) { if (-not $restart.Contains($dependent)) { [void]$restart.Add($dependent) } }

                if (-not (Stop-SnakeOptimizerService -Name $service.Name)) {
                    # Os Serviços de Criptografia muitas vezes não param (outro programa os segura). Eles só são
                    # necessários para o catálogo de assinaturas: o resto do reparo (o cache que mais resolve) segue sem ele.
                    if ($service.Name -eq "cryptsvc") { $cryptStuck = $true; continue }

                    $stopProblem = "o serviço $($service.Label) não parou em 30 segundos"
                    break
                }
            }

            if (-not $stopProblem) {
                foreach ($folder in @(Get-SnakeOptimizerWindowsUpdateCacheFolders)) {
                    if ($cryptStuck -and $folder.Name -eq "catroot2") {
                        $row = New-SnakeOptimizerResult -Kind Skipped -Detail "ficou como estava: os Serviços de Criptografia não pararam (some depois de reiniciar)"
                        $row.Etapa = $folder.Label
                        $rows += $row
                        continue
                    }

                    Write-Progress -Activity $title -Status "pondo de lado: $($folder.Label)"

                    # Outro serviço (o orquestrador de atualizações) pode religar o Windows Update a qualquer momento.
                    foreach ($service in @($stopping | Where-Object { -not ($cryptStuck -and $_.Name -eq "cryptsvc") })) {
                        try { [void](Stop-SnakeOptimizerService -Name $service.Name -TimeoutSeconds 10) } catch { Write-Verbose "Parar $($service.Name): $($_.Exception.Message)" }
                    }

                    $row = Move-SnakeOptimizerUpdateCacheFolder -Folder $folder
                    $row.Etapa = $folder.Label
                    $rows += $row

                    if ($row.Kind -eq "Ok") { $moved += [PSCustomObject]@{ Folder = $folder; Row = $row } }
                }
            }
        }
        catch {
            $stopProblem = "não foi possível desligar os serviços: $($_.Exception.Message.TrimEnd('.'))"
        }
        finally {
            Write-Progress -Activity $title -Status "ligando os serviços de novo"
            $notStarted = @()
            $toStart = @(@("cryptsvc", "bits", "wuauserv") + @($restart))
            if (@($services | Where-Object { $_.Name -eq "UsoSvc" -and $restored -contains $_.Label }).Count -gt 0) { $toStart += "UsoSvc" }

            foreach ($name in $toStart) {
                try { Start-SnakeOptimizerService -Name $name } catch { $notStarted += $name }
            }

            Write-Progress -Activity $title -Completed
        }

        # Os downloads são só cache: a cópia sai depois que os serviços já estão ligados de novo.
        foreach ($entry in @($moved | Where-Object { -not $_.Folder.Keep })) {
            $backup = [string](Get-SnakeOptimizerResultData -Result $entry.Row -Name "Backup")
            $text = $(if (Remove-SnakeOptimizerUpdateCacheBackup -Path $backup) { "apagados; o Windows baixa de novo o que precisar" } else { "postos de lado em $(Split-Path -Leaf $backup)" })
            $entry.Row.Detail = $text
            $entry.Row.Status = "OK ($text)"
        }

        $movedNames = @($moved | ForEach-Object { [string]$_.Folder.Name })

        if ($movedNames.Count -gt 0) {
            [void](Add-SnakeOptimizerChange -Action "Corrigir o Windows Update" -Text "cache refeito ($(Join-SnakeOptimizerList -Items $movedNames))")
        }

        $labels = @{}
        foreach ($service in $services) { $labels[$service.Name] = $service.Label }
        $notStartedText = Join-SnakeOptimizerList -Items @($notStarted | ForEach-Object { if ($labels.ContainsKey($_)) { $labels[$_] } else { $_ } })

        if ($rows.Count -gt 0) {
            Write-SnakeOptimizerSection -Title "Resumo"
            Write-SnakeOptimizerResultTable -Results $rows
        }

        $folderFailed = @($rows | Where-Object { $_.Kind -eq "Failed" -and $_.Etapa -notlike "Serviço *" })
        $linked = @($rows | Where-Object { Test-SnakeOptimizerResultFlag -Result $_ -Name "Linked" })

        if ($stopProblem) {
            $touched = $(if ($movedNames.Count -gt 0) { "Só parte do cache foi refeita ($(Join-SnakeOptimizerList -Items $movedNames))." } else { "Nada do cache foi mexido." })
            Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível terminar a correção: $stopProblem. $touched"
            Write-SnakeOptimizerStatus -Type Info -Message "Reinicie o PC e tente de novo."
            $final = New-SnakeOptimizerResult -Kind Failed -Detail "$stopProblem; $($touched.TrimEnd('.').ToLower())" -Title $title
        }
        elseif ($notStarted.Count -gt 0) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Não foi possível ligar de novo: $notStartedText. Reinicie o PC para o Windows ligá-los."
            $final = New-SnakeOptimizerResult -Kind Warning -Detail "cache refeito, mas não ligou de novo: $notStartedText; reinicie o PC" -Title $title -Data @{ RebootRequired = $true }
            Request-SnakeOptimizerRestartOffer -Reason "Reiniciar liga de novo os serviços do Windows Update." `
                -Comment "Reinicialização solicitada pelo SnakeOptimizer para ligar os serviços do Windows Update." `
                -DeclinedMessage "Reinicialização não iniciada. Os serviços voltam a ligar quando você reiniciar o PC."
        }
        elseif ($folderFailed.Count -gt 0) {
            $names = Join-SnakeOptimizerList -Items @($folderFailed | ForEach-Object { $_.Etapa })
            Write-SnakeOptimizerStatus -Type Info -Message "Reinicie o PC e rode a correção de novo."
            $final = New-SnakeOptimizerResult -Kind Warning -Detail "ficou como estava: $names" -Title $title
        }
        elseif ($linked.Count -gt 0) {
            $names = Join-SnakeOptimizerList -Items @($linked | ForEach-Object { $_.Etapa })
            # Quase sempre um programa que mudou o cache de disco; o SnakeOptimizer não mexe do outro lado.
            Write-SnakeOptimizerStatus -Type Info -Message "$names $(if ($linked.Count -eq 1) { 'aponta' } else { 'apontam' }) para outra pasta: desfaça pelo programa que mudou isso."
            $final = New-SnakeOptimizerResult -Kind Warning -Detail "cache refeito em parte; $names aponta para outro lugar e ficou como está" -Title $title
        }
        else {
            # Pede ao Windows uma busca nova, para as Configurações saírem da verificação antiga.
            Request-SnakeOptimizerWindowsUpdateScan

            Write-SnakeOptimizerStatus -Type Info -Message "Uma busca nova foi pedida ao Windows. Para instalar, use Atualizações > Instalar atualizações do Windows; a primeira busca demora mais."
            Write-SnakeOptimizerStatus -Type Info -Message "Se a versão nova (ex.: 26H2) continuar sem aparecer, a Microsoft libera aos poucos e segura em PCs com incompatibilidade conhecida; o Assistente de Instalação do Windows 11 (site da Microsoft) instala na hora."
            $final = New-SnakeOptimizerResult -Kind Ok -Detail "cache do Windows Update refeito e serviços ligados de novo" -Title $title
            [void](Set-SnakeOptimizerResultView -Result $final -Headline "Cache do Windows Update refeito" -Note "Os serviços estão ligados de novo. A primeira busca por atualizações demora mais." `
                    -Next "updates.install" -NextLabel "Procurar atualizações")
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível corrigir o Windows Update: $($_.Exception.Message.TrimEnd('.'))."
        $final = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message.TrimEnd(".") -Title $title
    }

    Exit-SnakeOptimizerAction -Result $final
}

Export-ModuleMember -Function *
