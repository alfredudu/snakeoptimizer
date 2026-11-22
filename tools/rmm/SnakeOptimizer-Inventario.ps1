<#
SnakeOptimizer - Inventario para o Tactical RMM

Coleta a situacao do PC (Windows, discos, protecao e manutencao) e escreve UMA linha: a do campo pedido em -Campo.
Cada campo personalizado do Tactical e preenchido por uma tarefa coletora que roda este script com o seu -Campo; a
coleta e feita uma vez e guardada por 20 minutos (as outras tarefas so leem). -Campo check devolve a situacao e sai
com 0 (ok), 1 (atencao) ou 2 (critico), para o check de script do Tactical.

Roda como SYSTEM (o agente do Tactical). Compativel com o PowerShell 2.0 (Windows 7 / Server 2008 R2): sem CIM, sem
ConvertFrom-Json. O arquivo fica so com ASCII (o Tactical grava o script sem BOM, e o PowerShell 5.1 o leria como
ANSI): os acentos das mensagens vem de escapes \uXXXX (funcao T).

Nada aqui manda dados para fora: o que sai e o texto que o proprio agente do Tactical entrega ao servidor.
#>
param ([string]$Campo = "situacao", [switch]$Novo)

$ErrorActionPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

function T([string]$Text) { return [regex]::Unescape($Text) }

$pt = New-Object System.Globalization.CultureInfo "pt-BR"
function Format-Day($When) { if ($null -eq $When) { return "" }; return ([datetime]$When).ToString("dd/MM/yyyy", $pt) }
function Format-Gb([double]$Bytes) { return ([Math]::Round($Bytes / 1GB, 0)).ToString("N0", $pt) }
function Format-Number([double]$Value) { return $Value.ToString("N0", $pt) }
function Get-Wmi([string]$Class, [string]$Namespace = "root\cimv2", [string]$Filter = "") {
    try {
        if ($Filter) { return @(Get-WmiObject -Class $Class -Namespace $Namespace -Filter $Filter -ErrorAction Stop) }
        return @(Get-WmiObject -Class $Class -Namespace $Namespace -ErrorAction Stop)
    }
    catch { return @() }
}
function Get-RegValue([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}
function New-Obj($Hash) { return (New-Object PSObject -Property $Hash) }

$dataDir = Join-Path $env:ProgramData "SnakeOptimizer\rmm"
$cachePath = Join-Path $dataDir "inventario.xml"

# ---------------------------------------------------------------------------------------------------------------------
# Ciclo de vida do Windows (mesmas datas do catalogo do SnakeOptimizer, atualizado em 15/11/2026)
# Build -> Nome, fim Home/Pro, fim Enterprise/Education, fim LTSC, fim ESU, 1a revisao do ESU, revisao mensal, data dela
# ---------------------------------------------------------------------------------------------------------------------
$lifecycle = @{
    14393 = @("Windows 10 1607", "2018-04-10", "2019-04-09", "2026-10-13", "", 0, 9612, "2026-10-13")
    17763 = @("Windows 10 1809", "2020-11-10", "2021-05-11", "2029-01-09", "", 0, 9376, "2026-10-13")
    19044 = @("Windows 10 21H2", "2023-06-13", "2024-06-11", "2027-01-12", "", 0, 7807, "2026-10-13")
    19045 = @("Windows 10 22H2", "2025-10-14", "2025-10-14", "", "2027-10-12", 6575, 7807, "2026-10-13")
    22000 = @("Windows 11 21H2", "2023-10-10", "2024-10-08", "", "", 0, 0, "")
    22621 = @("Windows 11 22H2", "2024-10-08", "2025-10-14", "", "", 0, 0, "")
    22631 = @("Windows 11 23H2", "2025-11-11", "2026-11-10", "", "", 0, 7652, "2026-10-13")
    26100 = @("Windows 11 24H2", "2026-10-13", "2027-10-12", "2029-10-09", "", 0, 9711, "2026-10-13")
    26200 = @("Windows 11 25H2", "2027-10-12", "2028-10-10", "", "", 0, 9711, "2026-10-13")
    26300 = @("Windows 11 26H2", "2028-10-10", "2029-10-09", "", "", 0, 9711, "2026-10-13")
    28000 = @("Windows 11 26H1", "2028-03-14", "2029-03-13", "", "", 0, 3231, "2026-10-13")
}
# Servidores (e o Windows 7/8.1): fim do suporte estendido.
$serverEnd = @{ 7601 = "2020-01-14"; 9200 = "2023-10-10"; 9600 = "2023-10-10"; 14393 = "2027-01-12"; 17763 = "2029-01-09"; 20348 = "2031-10-14"; 26100 = "2034-10-10" }
$catalogDate = [datetime]"2026-11-15"

$nvmeSource = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SnakeRmmNvme
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle device, uint code, byte[] input, int inputSize, byte[] output, int outputSize, out int returned, IntPtr overlapped);
    public static byte[] Read(int diskNumber)
    {
        using (SafeFileHandle device = CreateFile(@"\\.\PhysicalDrive" + diskNumber, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (device.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            int size = 8 + 40 + 512;
            byte[] input = new byte[size];
            byte[] output = new byte[size];
            BitConverter.GetBytes(50).CopyTo(input, 0);
            BitConverter.GetBytes(0).CopyTo(input, 4);
            BitConverter.GetBytes(3).CopyTo(input, 8);
            BitConverter.GetBytes(2).CopyTo(input, 12);
            BitConverter.GetBytes(2).CopyTo(input, 16);
            BitConverter.GetBytes(0).CopyTo(input, 20);
            BitConverter.GetBytes(40).CopyTo(input, 24);
            BitConverter.GetBytes(512).CopyTo(input, 28);
            int returned;
            if (!DeviceIoControl(device, 0x002D1400, input, size, output, size, out returned, IntPtr.Zero)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            int offset = BitConverter.ToInt32(output, 8 + 16);
            int length = BitConverter.ToInt32(output, 8 + 20);
            if (length < 192 || offset < 0 || 8 + offset + 192 > output.Length) { throw new InvalidOperationException("sem registro de saude"); }
            byte[] log = new byte[512];
            Array.Copy(output, 8 + offset, log, 0, Math.Min(512, Math.Min(length, output.Length - 8 - offset)));
            return log;
        }
    }
}
"@

# ---------------------------------------------------------------------------------------------------------------------
# Coleta
# ---------------------------------------------------------------------------------------------------------------------
function Get-WindowsPart($Notes) {
    $os = @(Get-Wmi "Win32_OperatingSystem")[0]
    $build = [int]$os.BuildNumber
    $cv = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $ubr = Get-RegValue $cv "UBR"
    $display = Get-RegValue $cv "DisplayVersion"
    if (-not $display) { $display = Get-RegValue $cv "ReleaseId" }
    $edition = [string](Get-RegValue $cv "EditionID")
    $server = ([int]$os.ProductType -ne 1)
    $caption = ([string]$os.Caption) -replace '^Microsoft\s+', '' -replace '\s+$', ''

    $text = $caption
    if ($display -and -not $server) { $text += " $display" }
    $text += " ($build$(if ($ubr) { ".$ubr" }))"
    $parts = @($text)

    # Fim do suporte.
    $end = $null; $esu = $false
    if ($server -or $build -lt 10240) {
        if ($serverEnd.ContainsKey($build)) { $end = [datetime]$serverEnd[$build] }
    }
    elseif ($lifecycle.ContainsKey($build)) {
        $row = $lifecycle[$build]
        if ($edition -match 'LTS' -and $row[3]) { $end = [datetime]$row[3] }
        elseif ($edition -match 'Enterprise|Education') { $end = [datetime]$row[2] }
        else { $end = [datetime]$row[1] }
        if ($row[4] -and [int]$row[5] -gt 0 -and $ubr -and [int]$ubr -ge [int]$row[5]) { $end = [datetime]$row[4]; $esu = $true }

        # Atualizacao mensal atrasada (so com o catalogo recente: datas velhas acusariam todo mundo).
        if ([int]$row[6] -gt 0 -and $ubr -and [int]$ubr -lt [int]$row[6] -and ((Get-Date) - $catalogDate).TotalDays -lt 60 -and ((Get-Date) - [datetime]$row[7]).TotalDays -gt 35) {
            $parts += (T "atualiza\u00e7\u00e3o mensal atrasada")
            $Notes.Warn += (T "Windows sem a atualiza\u00e7\u00e3o mensal")
        }
    }

    if ($null -ne $end) {
        $days = ($end - (Get-Date).Date).TotalDays
        if ($days -lt 0) {
            $parts += (T "SEM SUPORTE desde $(Format-Day $end)")
            $Notes.Crit += (T "Windows sem suporte desde $(Format-Day $end)")
        }
        else {
            $parts += (T "suporte at\u00e9 $(Format-Day $end)$(if ($esu) { ' (ESU)' })")
            if ($days -lt 90) { $Notes.Warn += (T "suporte do Windows acaba em $(Format-Day $end)") }
        }
    }

    # Atualizacoes pendentes (Windows Update), com limite de 3 minutos.
    $job = Start-Job -ScriptBlock {
        try {
            $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
            $searcher.Online = $false
            $found = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
            $n = 0; foreach ($u in $found.Updates) { if (-not ($u.Title -match 'Preview|Pr\S*via')) { $n++ } }
            $n
        }
        catch { -1 }
    }
    $pending = -1
    if (Wait-Job $job -Timeout 180) { $pending = [int](@(Receive-Job $job))[-1] }
    Remove-Job $job -Force
    if ($pending -gt 0) { $parts += (T "$pending atualiza\u00e7$(if ($pending -eq 1) { '\u00e3o pendente' } else { '\u00f5es pendentes' })") }
    elseif ($pending -eq 0) { $parts += (T "sem atualiza\u00e7\u00f5es pendentes") }

    $reboot = (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") -or
        (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
    if ($reboot) { $parts += (T "rein\u00edcio pendente"); $Notes.Warn += (T "rein\u00edcio pendente") }

    try {
        $boot = $os.ConvertToDateTime($os.LastBootUpTime)
        $up = [int]((Get-Date) - $boot).TotalDays
        $parts += (T "ligado h\u00e1 $up dia$(if ($up -ne 1) { 's' })")
        if ($up -ge 30) { $Notes.Warn += (T "ligado h\u00e1 $up dias sem reiniciar") }
    }
    catch { }

    return ($parts -join " | ")
}

function Get-DiskPart($Notes) {
    $parts = @()

    # Unidades (espaco livre).
    $systemDrive = $env:SystemDrive
    $volumes = @()
    foreach ($v in @(Get-Wmi "Win32_LogicalDisk" -Filter "DriveType=3" | Sort-Object DeviceID)) {
        if (-not $v.Size -or [double]$v.Size -le 0) { continue }
        $free = [double]$v.FreeSpace; $size = [double]$v.Size
        $pct = [int][Math]::Round($free * 100 / $size)
        $volumes += "$($v.DeviceID) $(Format-Gb $free) de $(Format-Gb $size) GB livres ($pct%)"
        $isSystem = ($v.DeviceID -eq $systemDrive)
        # Porcentagem e GB juntos: 8% de um disco de 8 TB ainda sao 600 GB livres.
        if (($isSystem -and ($free -lt 5GB -or ($pct -lt 5 -and $free -lt 20GB))) -or ($pct -lt 3 -and $free -lt 10GB)) { $Notes.Crit += (T "disco $($v.DeviceID) quase cheio ($(Format-Gb $free) GB livres)") }
        elseif ($free -lt 15GB -or ($pct -lt 10 -and $free -lt 50GB)) { $Notes.Warn += (T "disco $($v.DeviceID) com pouco espa\u00e7o ($(Format-Gb $free) GB livres)") }
    }
    if ($volumes.Count -gt 0) { $parts += ($volumes -join " ; ") }

    # Discos fisicos: saude.
    $physical = @()
    $msft = @(Get-Wmi "MSFT_PhysicalDisk" "root\Microsoft\Windows\Storage")
    $canNvme = ($PSVersionTable.PSVersion.Major -ge 3 -and [Environment]::OSVersion.Version.Major -ge 10)
    if ($canNvme) { try { if (-not ("SnakeRmmNvme" -as [type])) { Add-Type -TypeDefinition $nvmeSource -ErrorAction Stop } } catch { $canNvme = $false } }

    if ($msft.Count -gt 0) {
        foreach ($d in ($msft | Sort-Object { [int]$_.DeviceId })) {
            $bus = switch ([int]$d.BusType) { 17 { "NVMe" } 11 { "SATA" } 7 { "USB" } 8 { "RAID" } 10 { "SAS" } 3 { "ATA" } default { "" } }
            if ($bus -eq "USB") { continue }
            $media = switch ([int]$d.MediaType) { 4 { "SSD" } 3 { "HD" } default { "" } }
            $kind = (@($bus, $media) | Where-Object { $_ }) -join " "
            $name = ([string]$d.FriendlyName).Trim()
            $line = "$name$(if ($kind) { " ($kind)" })"
            $detail = @()

            if ($bus -eq "NVMe" -and $canNvme) {
                try {
                    $log = [SnakeRmmNvme]::Read([int]$d.DeviceId)
                    $used = [int]$log[5]; $spare = [int]$log[3]; $critical = [int]$log[0]
                    $score = 100 - [Math]::Min(100, $used)
                    if ($spare -ge 0 -and $spare -le 100) { $score = [Math]::Min($score, $spare) }
                    if (($critical -band 0x0D) -ne 0) { $score = [Math]::Min($score, 10) }
                    $hours = [double][BitConverter]::ToUInt64($log, 128)
                    $mediaErrors = [double][BitConverter]::ToUInt64($log, 160)
                    $detail += (T "sa\u00fade $score%")
                    $detail += "$(Format-Number $hours) h"
                    if ($mediaErrors -gt 0) { $detail += (T "$(Format-Number $mediaErrors) erros de m\u00eddia") }
                    if ($critical -ne 0 -or $score -le 30) { $Notes.Crit += (T "SSD $name com sa\u00fade $score%") }
                    elseif ($score -lt 80) { $Notes.Warn += (T "SSD $name com sa\u00fade $score%") }
                    if ($mediaErrors -gt 0) { $Notes.Warn += (T "SSD $name com erros de m\u00eddia") }
                }
                catch { }
            }

            $hs = [int]$d.HealthStatus
            if ($hs -eq 2) { $detail += "com falha"; $Notes.Crit += (T "disco $name com falha (Windows)") }
            elseif ($hs -eq 1) { $detail += (T "aten\u00e7\u00e3o"); $Notes.Warn += (T "disco $name em aten\u00e7\u00e3o (Windows)") }
            elseif ($detail.Count -eq 0) { $detail += "OK" }

            $physical += "${line}: $($detail -join ', ')"
        }
    }
    else {
        # Windows 7 / 2008 R2: o modelo e o aviso de falha do SMART.
        $predict = @(Get-Wmi "MSStorageDriver_FailurePredictStatus" "root\wmi")
        foreach ($d in @(Get-Wmi "Win32_DiskDrive" | Where-Object { $_.InterfaceType -ne "USB" })) {
            $fail = @($predict | Where-Object { $_.PredictFailure }).Count -gt 0
            $physical += "$(([string]$d.Model).Trim()): $(if ($fail) { 'SMART prev\u00ea falha' } else { 'OK' })"
            if ($fail) { $Notes.Crit += (T "disco $(([string]$d.Model).Trim()): SMART prev\u00ea falha") }
        }
        $physical = @($physical | ForEach-Object { T $_ })
    }
    if ($physical.Count -gt 0) { $parts += ($physical -join " ; ") }

    return ($parts -join " | ")
}

function Get-ProtectionPart($Notes, [bool]$Server) {
    $parts = @()
    $found = $false

    # Estacoes: a Central de Seguranca do Windows. Os desligados so aparecem quando nenhum esta ativo (um antivirus
    # instalado desliga o Defender, e um antigo esquecido fica registrado como desligado).
    $off = @()
    foreach ($av in @(Get-Wmi "AntiVirusProduct" "root\SecurityCenter2")) {
        $state = [int]$av.productState
        $on = ((($state -shr 12) -band 0xF) -eq 1)
        $current = ((($state -shr 4) -band 0xF) -eq 0)
        $name = [string]$av.displayName
        if (-not $on) { $off += "${name}: desligado"; continue }
        $found = $true
        $parts += "${name}: ativo$(if (-not $current) { ', desatualizado' })"
        if (-not $current) { $Notes.Warn += "$name desatualizado" }
    }
    if (-not $found) { $parts += $off }

    # Servidores (sem a Central de Seguranca): o Defender e os antivirus mais comuns pelo processo.
    if ($parts.Count -eq 0) {
        $mp = @(Get-Wmi "MSFT_MpComputerStatus" "root\Microsoft\Windows\Defender")[0]
        if ($mp -and $mp.AntivirusEnabled) {
            $age = [int]$mp.AntivirusSignatureAge
            $parts += "Microsoft Defender: ativo$(if ($age -gt 3) { (T ", assinaturas de $age dias") })"
            if ($age -gt 7) { $Notes.Warn += (T "Defender com assinaturas de $age dias") }
            $found = $true
        }
        $known = @{ "avp" = "Kaspersky"; "klnagent" = "Kaspersky (agente)"; "ekrn" = "ESET"; "bdservicehost" = "Bitdefender"; "SophosHealth" = "Sophos"; "SentinelAgent" = "SentinelOne"; "CSFalconService" = "CrowdStrike"; "avgsvc" = "AVG"; "AvastSvc" = "Avast"; "WRSA" = "Webroot"; "ccSvcHst" = "Norton/Symantec" }
        foreach ($proc in $known.Keys) {
            if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { $parts += "$($known[$proc]): ativo"; $found = $true }
        }
    }

    if (-not $found) {
        $parts += (T "nenhum antiv\u00edrus ativo identificado")
        if ($Server) { $Notes.Warn += (T "antiv\u00edrus n\u00e3o identificado") } else { $Notes.Crit += (T "nenhum antiv\u00edrus ativo") }
    }

    # BitLocker do disco do sistema.
    $bl = @(Get-Wmi "Win32_EncryptableVolume" "root\cimv2\Security\MicrosoftVolumeEncryption" "DriveLetter='$($env:SystemDrive)'")[0]
    if ($bl) { $parts += "BitLocker $($env:SystemDrive) $(if ([int]$bl.ProtectionStatus -eq 1) { 'ligado' } else { 'desligado' })" }

    return ($parts -join " | ")
}

function Get-MaintenancePart($Notes) {
    $root = Join-Path $env:ProgramData "SnakeOptimizer"
    $core = Join-Path $root "app\modules\Core.psm1"
    if (-not (Test-Path $core)) { return (T "SnakeOptimizer n\u00e3o instalado") }

    $build = ""
    try { $m = [regex]::Match([IO.File]::ReadAllText($core), 'SnakeOptimizerBuild\s*=\s*"([^"]+)"'); if ($m.Success) { $build = $m.Groups[1].Value } } catch { }
    $parts = @("SnakeOptimizer $build".Trim())

    # A manutencao mais recente: a automatica (ProgramData) ou a feita na janela por alguma conta.
    $latest = $null; $latestText = ""
    $auto = Join-Path $root "historico-automatico.json"
    if (Test-Path $auto) {
        try {
            $json = [IO.File]::ReadAllText($auto)
            $at = [regex]::Match($json, '"At"\s*:\s*"([^"]+)"'); $code = [regex]::Match($json, '"Code"\s*:\s*(\d+)')
            if ($at.Success) {
                $latest = [datetime]::Parse($at.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
                $result = $(if ($code.Success -and [int]$code.Groups[1].Value -eq 0) { "ok" } elseif ($code.Success -and [int]$code.Groups[1].Value -eq 1) { T "com aten\u00e7\u00e3o" } else { "com falha" })
                $latestText = T "\u00faltima manuten\u00e7\u00e3o $(Format-Day $latest) $result (autom\u00e1tica)"
            }
        }
        catch { }
    }
    foreach ($file in @(Get-ChildItem -Path "$env:SystemDrive\Users\*\AppData\Local\SnakeOptimizer\last-maintenance.json" -ErrorAction SilentlyContinue)) {
        try {
            $json = [IO.File]::ReadAllText($file.FullName)
            $at = [regex]::Match($json, '"StartedAt"\s*:\s*"([^"]+)"')
            if (-not $at.Success) { continue }
            $when = [datetime]::Parse($at.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
            if ($null -ne $latest -and $when -le $latest) { continue }
            $failed = [regex]::Matches($json, '"Kind"\s*:\s*"Failed"').Count
            $warned = [regex]::Matches($json, '"Kind"\s*:\s*"Warning"').Count
            $result = $(if ($failed -gt 0) { "com $failed falha$(if ($failed -gt 1) { 's' })" } elseif ($warned -gt 0) { T "com $warned etapa$(if ($warned -gt 1) { 's' }) em aten\u00e7\u00e3o" } else { "ok" })
            $latest = $when
            $latestText = T "\u00faltima manuten\u00e7\u00e3o $(Format-Day $when) $result"
        }
        catch { }
    }

    if ($latestText) {
        $parts += $latestText
        if (((Get-Date) - $latest).TotalDays -gt 60) { $Notes.Warn += (T "sem manuten\u00e7\u00e3o h\u00e1 mais de 60 dias") }
    }
    else { $parts += (T "nenhuma manuten\u00e7\u00e3o registrada") }

    $updater = Join-Path $root "versao-instalada.json"
    if (Test-Path $updater) {
        try {
            $m = [regex]::Match([IO.File]::ReadAllText($updater), '"InstalledAt"\s*:\s*"([^"]+)"')
            if ($m.Success) { $parts += "atualizado em $(Format-Day ([datetime]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)))" }
        }
        catch { }
    }

    return ($parts -join " | ")
}

function Get-Inventory {
    $notes = New-Obj @{ Crit = @(); Warn = @() }
    $server = ([int](@(Get-Wmi "Win32_OperatingSystem")[0]).ProductType -ne 1)

    $windows = Get-WindowsPart $notes
    $disks = Get-DiskPart $notes
    $protection = Get-ProtectionPart $notes $server
    $maintenance = Get-MaintenancePart $notes

    $level = $(if (@($notes.Crit).Count -gt 0) { 2 } elseif (@($notes.Warn).Count -gt 0) { 1 } else { 0 })
    $stamp = (Get-Date).ToString("dd/MM HH:mm", $pt)
    $status = switch ($level) {
        2 { (T "CR\u00cdTICO: ") + ((@($notes.Crit) + @($notes.Warn)) -join "; ") }
        1 { (T "ATEN\u00c7\u00c3O: ") + (@($notes.Warn) -join "; ") }
        default { "OK" }
    }

    return (New-Obj @{
        At = Get-Date; Level = $level
        situacao = "$status (coletado $stamp)"
        windows = $windows; discos = $disks; protecao = $protection; manutencao = $maintenance
    })
}

# ---------------------------------------------------------------------------------------------------------------------
# Uma coleta por vez; as tarefas que chegam juntas esperam e usam a mesma.
# ---------------------------------------------------------------------------------------------------------------------
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

$mutex = New-Object System.Threading.Mutex($false, "Global\SnakeOptimizerRmmInventario")
$owned = $false
try { $owned = $mutex.WaitOne(600000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }

try {
    $inv = $null
    if (-not $Novo -and (Test-Path $cachePath)) {
        try {
            $cached = Import-Clixml $cachePath
            if (((Get-Date) - [datetime]$cached.At).TotalMinutes -lt 20) { $inv = $cached }
        }
        catch { }
    }
    if ($null -eq $inv) {
        $inv = Get-Inventory
        try { $inv | Export-Clixml -Path $cachePath } catch { }
    }
}
finally {
    if ($owned) { $mutex.ReleaseMutex() }
}

switch ($Campo.ToLowerInvariant()) {
    "check" { Write-Output $inv.situacao; exit ([int]$inv.Level) }
    "tudo" {
        foreach ($name in @("situacao", "windows", "discos", "protecao", "manutencao")) { Write-Output "$($name): $($inv.$name)" }
        exit ([int]$inv.Level)
    }
    default {
        $value = $inv.($Campo.ToLowerInvariant())
        if ($null -eq $value) { Write-Output "campo desconhecido: $Campo (use situacao, windows, discos, protecao, manutencao, check ou tudo)"; exit 4 }
        Write-Output $value
        exit 0
    }
}
