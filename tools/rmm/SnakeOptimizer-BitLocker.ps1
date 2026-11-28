# SnakeOptimizer - chave de recuperacao do BitLocker para o Tactical RMM (ou outro RMM).
#
# Le a chave de recuperacao (senha numerica de 48 digitos) de cada unidade com BitLocker, pelo WMI
# (Win32_EncryptableVolume, funciona do Windows 7 em diante e em qualquer idioma), e:
#   -Campo                 escreve uma linha curta para um campo personalizado do RMM (ex.: "SO BitLocker"):
#                          "C: 123456-...-123456 (id 1A2B3C4D) | D: ..." ou "sem BitLocker"
#   -Nextcloud <link>      manda um .txt com as chaves para a pasta de um link do Nextcloud do tipo
#   [-Senha <senha>]       "Solicitar arquivos" (quem tem o link so envia, nao ve as chaves dos outros PCs).
#                          No Tactical, passe o link pelo Global Key Store: -Nextcloud {{global.SO_COFRE_URL}}
# Sem parametros, mostra as chaves na saida do script.
# Codigos de saida: 0 ok (ou sem BitLocker), 1 unidade criptografada sem chave de recuperacao, 2 falha.
# Texto so em ASCII no arquivo (os acentos saem pelo [regex]::Unescape), para o RMM nao estragar a codificacao.

param(
    [switch]$Campo,
    [string]$Nextcloud = "",
    [string]$Senha = ""
)

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
function T([string]$s) { return [regex]::Unescape($s) }

$volumes = @()
try {
    $volumes = @(Get-WmiObject -Namespace "root\cimv2\Security\MicrosoftVolumeEncryption" -Class Win32_EncryptableVolume -ErrorAction Stop)
}
catch {
    # Acesso negado (rodando sem Administrador/SYSTEM) nao e o mesmo que nao ter BitLocker.
    $denied = ($_.Exception.Message -match '0x80041003|negado|denied')
    if ($Campo) { if ($denied) { Write-Output "sem leitura (rode como SYSTEM)"; exit 2 } else { Write-Output "sem BitLocker" } } else { Write-Output (T "BitLocker n\u00e3o dispon\u00edvel neste Windows: $($_.Exception.Message)") }
    exit 0
}

$found = @()
$missing = @()

foreach ($volume in $volumes) {
    $letter = [string]$volume.DriveLetter
    if (-not $letter) { continue }

    $status = $volume.GetConversionStatus()
    $encrypted = ($status.ConversionStatus -ne 0)
    $ids = @()
    try { $ids = @($volume.GetKeyProtectors(3).VolumeKeyProtectorID) } catch { }

    $keys = @()
    foreach ($id in ($ids | Where-Object { $_ })) {
        try {
            $password = [string]$volume.GetKeyProtectorNumericalPassword($id).NumericalPassword
            if ($password) { $keys += New-Object PSObject -Property @{ Id = ([string]$id).Trim('{', '}'); Password = $password } }
        }
        catch { }
    }

    if ($keys.Count -gt 0) { $found += New-Object PSObject -Property @{ Letter = $letter; Keys = $keys } }
    elseif ($encrypted) { $missing += $letter }
}

if ($Campo) {
    if ($found.Count -eq 0) {
        if ($missing.Count -gt 0) { Write-Output (T "criptografado SEM chave de recupera\u00e7\u00e3o: $($missing -join ', ')") } else { Write-Output "sem BitLocker" }
    }
    else {
        $parts = @(foreach ($f in $found) { foreach ($k in $f.Keys) { "$($f.Letter) $($k.Password) (id $($k.Id.Substring(0, 8)))" } })
        Write-Output ($parts -join " | ")
    }
    if ($missing.Count -gt 0) { exit 1 } else { exit 0 }
}

$serial = ""
$model = ""
try { $serial = ([string](Get-WmiObject Win32_BIOS | Select-Object -First 1).SerialNumber).Trim() } catch { }
try { $cs = Get-WmiObject Win32_ComputerSystem | Select-Object -First 1; $model = ("$($cs.Manufacturer) $($cs.Model)").Trim() } catch { }

$lines = @()
$lines += T "Chaves de recupera\u00e7\u00e3o do BitLocker"
$lines += ""
$lines += "Computador : $env:COMPUTERNAME"
if ($model) { $lines += "Modelo     : $model" }
if ($serial) { $lines += "Serial     : $serial" }
$lines += "Lido em    : $((Get-Date).ToString('dd/MM/yyyy HH:mm'))"
$lines += ""
foreach ($f in $found) {
    foreach ($k in $f.Keys) {
        $lines += "Unidade $($f.Letter)"
        $lines += T "  Identifica\u00e7\u00e3o da chave : $($k.Id)"
        $lines += T "  Chave de recupera\u00e7\u00e3o   : $($k.Password)"
        $lines += ""
    }
}
foreach ($m in $missing) { $lines += T "Unidade $m criptografada SEM chave de recupera\u00e7\u00e3o num\u00e9rica." }
$lines += "Gerado pelo SnakeOptimizer (RMM)."
$text = $lines -join "`r`n"

if (-not $Nextcloud) {
    Write-Output $text
    if ($missing.Count -gt 0) { exit 1 } else { exit 0 }
}

if ($found.Count -eq 0) {
    Write-Output (T "Nada para enviar: nenhuma unidade com chave de recupera\u00e7\u00e3o.")
    if ($missing.Count -gt 0) { exit 1 } else { exit 0 }
}

if ($Nextcloud -notmatch '^(?<base>https://[^\s?#]+?)(/index\.php)?/s/(?<token>[A-Za-z0-9]+)/?(\?.*)?$') {
    Write-Output (T "O link n\u00e3o parece um compartilhamento do Nextcloud (https://servidor/s/codigo).")
    exit 2
}
$base = $Matches['base'].TrimEnd('/')
$token = $Matches['token']

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$name = (($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]', '_') + "_" + (Get-Date).ToString("yyyy-MM-dd_HHmm") + "_BitLocker.txt")
$bytes = (New-Object System.Text.UTF8Encoding $true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes($text)
# Endereco novo (Nextcloud 29+) e, se nao existir, o antigo. O X-NC-Nickname (nome do PC) e exigido pelo
# "Solicitar arquivos" do Nextcloud 30+, que guarda cada PC numa subpasta com esse nome.
$routes = @(
    @("$base/public.php/dav/files/$token/$([Uri]::EscapeDataString($name))", "anonymous", [bool]$Senha),
    @("$base/public.php/webdav/$([Uri]::EscapeDataString($name))", $token, $true)
)
$problem = ""
foreach ($route in $routes) {
    try {
        $request = [System.Net.HttpWebRequest]::Create($route[0])
        $request.Method = "PUT"
        $request.Timeout = 30000
        $request.ContentType = "text/plain; charset=utf-8"
        $request.UserAgent = "SnakeOptimizer"
        $request.Headers.Add("X-Requested-With", "XMLHttpRequest")
        $request.Headers.Add("X-NC-Nickname", $env:COMPUTERNAME)
        if ($route[2]) { $request.Headers.Add("Authorization", "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($route[1]):$Senha"))) }
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream(); $stream.Write($bytes, 0, $bytes.Length); $stream.Close()
        $response = $request.GetResponse(); $response.Close()
        Write-Output "Chave enviada para o cofre: $name"
        if ($missing.Count -gt 0) { exit 1 } else { exit 0 }
    }
    catch {
        $problem = $_.Exception.Message
    }
}
Write-Output (T "N\u00e3o foi poss\u00edvel enviar ao cofre: $problem")
exit 2
