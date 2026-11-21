# ---------------------------------------------------------------------------
# Arquivos presos e perfis de usuário
# ---------------------------------------------------------------------------
# Apagar o que o Windows não deixa: um arquivo ou pasta "em uso" ou "sem permissão", e as pastas de perfis antigos em
# C:\Users (contas que saíram da empresa, perfis de domínio, pastas que sobraram de outro Windows).
#
# A escada para apagar (Remove-SnakeOptimizerLockedPath), do mais leve ao mais forte:
#   1. apagar normalmente, sem seguir atalhos de pasta (junções);
#   2. tomar posse (o grupo Administradores vira dono e ganha controle total) e apagar com o rd do Windows, que alcança
#      caminhos longos (\\?\) e também não segue junções;
#   3. perguntar ao Gerenciador de Reinicialização do Windows (Restart Manager, a mesma API dos instaladores) quais
#      programas seguram o que sobrou, fechar esses programas e apagar de novo;
#   4. o que ainda estiver preso (um serviço, o antivírus) fica marcado para o Windows apagar ao reiniciar, antes de
#      qualquer programa abrir (MoveFileEx com MOVEFILE_DELAY_UNTIL_REBOOT).
# O Unlocker faz parecido, mas fecha as alças de arquivo dentro de outros programas, o que pode corromper o que eles
# estão gravando. Aqui o programa que segura é fechado inteiro (o Explorador volta sozinho) e o que não pode ser fechado
# espera o reinício.

$script:SnakeOptimizerFileLocksSource = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace SnakeOptimizer
{
    public class FileLocker
    {
        public int ProcessId;
        public string Name;
        public string Service;
        public int Kind;
    }

    public static class FileLocks
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct RM_UNIQUE_PROCESS
        {
            public int dwProcessId;
            public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct RM_PROCESS_INFO
        {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
            public int ApplicationType;
            public uint AppStatus;
            public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, System.Text.StringBuilder strSessionKey);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint pSessionHandle);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);

        // Os programas e serviços que estão com algum dos arquivos aberto. Kind: 1 janela, 2 programa, 3 serviço,
        // 4 Explorador, 5 console, 1000 crítico (o Windows não deixa fechar).
        public static List<FileLocker> GetLockers(string[] files)
        {
            List<FileLocker> result = new List<FileLocker>();
            if (files == null || files.Length == 0) { return result; }

            uint handle;
            System.Text.StringBuilder key = new System.Text.StringBuilder(64);
            if (RmStartSession(out handle, 0, key) != 0) { return result; }

            try
            {
                if (RmRegisterResources(handle, (uint)files.Length, files, 0, null, 0, null) != 0) { return result; }

                uint needed = 0;
                uint count = 0;
                uint reasons = 0;
                int status = RmGetList(handle, out needed, ref count, null, ref reasons);

                if (status == 234 && needed > 0)
                {
                    RM_PROCESS_INFO[] info = new RM_PROCESS_INFO[needed];
                    count = needed;
                    status = RmGetList(handle, out needed, ref count, info, ref reasons);

                    if (status == 0)
                    {
                        for (int i = 0; i < count; i++)
                        {
                            FileLocker locker = new FileLocker();
                            locker.ProcessId = info[i].Process.dwProcessId;
                            locker.Name = info[i].strAppName;
                            locker.Service = info[i].strServiceShortName;
                            locker.Kind = info[i].ApplicationType;
                            result.Add(locker);
                        }
                    }
                }
            }
            finally
            {
                RmEndSession(handle);
            }

            return result;
        }

        // Marca para o Windows apagar ao reiniciar (exige Administrador). Uma pasta só sai se estiver vazia nessa hora:
        // marque o conteúdo antes, do mais fundo para cima.
        public static bool DeleteOnReboot(string path)
        {
            return MoveFileEx(path, null, 4);
        }
    }
}
"@


function Initialize-SnakeOptimizerFileLocks {
    # Compila a ponte com o Restart Manager uma vez por processo. Devolve $false se não foi possível.
    if ("SnakeOptimizer.FileLocks" -as [type]) { return $true }

    try {
        Add-Type -TypeDefinition $script:SnakeOptimizerFileLocksSource -ErrorAction Stop
        return $true
    }
    catch {
        Write-Verbose "Restart Manager: $($_.Exception.Message)"
        return $false
    }
}


function ConvertTo-SnakeOptimizerLongPath {
    # O caminho no formato \\?\ que passa do limite de 260 caracteres (\\?\UNC\ para a rede).
    param ([Parameter(Mandatory)][string]$Path)

    if ($Path.StartsWith("\\?\")) { return $Path }
    if ($Path.StartsWith("\\")) { return "\\?\UNC\" + $Path.Substring(2) }
    return "\\?\" + $Path
}


function Test-SnakeOptimizerLockedPathAllowed {
    <#
    A trava de segurança do desbloqueio: nunca a raiz de um disco, o Windows (nem nada dentro dele), Arquivos de
    Programas e ProgramData inteiros, a pasta dos perfis (C:\Users) inteira, nem o seu perfil ou algo que o contenha.
    Dentro de Arquivos de Programas ou de outro perfil, pode. Devolve o motivo da recusa, ou vazio quando pode.
    #>
    param ([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "caminho vazio" }

    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return "caminho inválido" }

    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    if (-not $full -or $full -eq $root) { return "é a raiz de um disco" }

    $normalize = {
        param ($value)
        if ([string]::IsNullOrWhiteSpace($value)) { return "" }
        if ($value -match '^[A-Za-z]:$') { $value += "\" }
        try { return [IO.Path]::GetFullPath($value).TrimEnd('\', '/') } catch { return "" }
    }

    $windows = & $normalize $env:WINDIR
    if ($windows -and ($full -eq $windows -or $full.StartsWith("$windows\", [StringComparison]::OrdinalIgnoreCase))) { return "fica dentro da pasta do Windows" }

    $profilesRoot = & $normalize (Get-SnakeOptimizerProfilesDirectory)
    $whole = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $profilesRoot, $env:SystemDrive)

    foreach ($candidate in $whole) {
        $value = & $normalize $candidate
        if ($value -and $full -eq $value) { return "é uma pasta do sistema inteira" }
    }

    $mine = & $normalize $env:USERPROFILE
    if ($mine -and ($full -eq $mine -or $mine.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase))) { return "é o seu perfil (ou o contém)" }

    return ""
}


function Get-SnakeOptimizerRemainingFiles {
    # Os arquivos e pastas que ainda existem dentro de um caminho, sem seguir junções. Devolve Files e Folders (as pastas
    # da mais funda para cima). Pára em -Limit arquivos.
    param (
        [Parameter(Mandatory)][string]$Path,
        [int]$Limit = 5000
    )

    $files = New-Object System.Collections.Generic.List[string]
    $folders = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $Path)) { return [PSCustomObject]@{ Files = @(); Folders = @() } }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [PSCustomObject]@{ Files = @(); Folders = @() } }

    if (-not $item.PSIsContainer) {
        $files.Add($item.FullName)
        return [PSCustomObject]@{ Files = @($files); Folders = @() }
    }

    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($item.FullName)

    while ($pending.Count -gt 0 -and $files.Count -lt $Limit) {
        $current = $pending.Pop()
        $folders.Add($current)

        try {
            foreach ($child in ([IO.DirectoryInfo]$current).EnumerateFileSystemInfos()) {
                if (($child.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    # Uma junção conta como "arquivo" a apagar (sai como atalho), sem entrar nela.
                    if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $folders.Add($child.FullName) }
                    else { $pending.Push($child.FullName) }
                }
                else {
                    $files.Add($child.FullName)
                }
            }
        }
        catch {
            Write-Verbose "Listar ${current}: $($_.Exception.Message)"
        }
    }

    $ordered = @($folders | Sort-Object -Property { $_.Length } -Descending)
    return [PSCustomObject]@{ Files = @($files); Folders = $ordered }
}


function Stop-SnakeOptimizerFileLockers {
    <#
    Fecha os programas que seguram os arquivos (Restart Manager). Ficam de fora os críticos do Windows, os serviços (um
    serviço parado à força pode levar outros junto) e este próprio processo. O Explorador é fechado e aberto de novo.
    Devolve Closed (nomes fechados) e Kept (os que continuam segurando).
    #>
    param (
        [string[]]$Files = @(),
        [switch]$Ask
    )

    $none = [PSCustomObject]@{ Closed = @(); Kept = @() }
    if ($Files.Count -eq 0 -or -not (Initialize-SnakeOptimizerFileLocks)) { return $none }

    $lockers = @()
    # O Restart Manager aceita listas grandes, mas fica lento: em blocos de 500.
    for ($i = 0; $i -lt $Files.Count; $i += 500) {
        $chunk = @($Files[$i..([Math]::Min($i + 499, $Files.Count - 1))])
        try { $lockers += @([SnakeOptimizer.FileLocks]::GetLockers([string[]]$chunk)) } catch { Write-Verbose "Restart Manager: $($_.Exception.Message)" }
    }

    $lockers = @($lockers | Sort-Object -Property ProcessId -Unique)
    if ($lockers.Count -eq 0) { return $none }

    $critical = @("System", "Idle", "smss", "csrss", "wininit", "winlogon", "services", "lsass", "svchost", "dwm", "fontdrvhost", "MsMpEng", "MsSense", "SecurityHealthService", "Registry", "Memory Compression")
    $closable = @()
    $kept = @()

    foreach ($locker in $lockers) {
        $process = Get-Process -Id $locker.ProcessId -ErrorAction SilentlyContinue
        $name = $(if ($process) { $process.ProcessName } else { [string]$locker.Name })
        $label = $(if ($locker.Name) { "$($locker.Name) ($name)" } else { $name })

        if ($null -eq $process -or $locker.ProcessId -le 4 -or $locker.ProcessId -eq $PID -or $locker.Kind -eq 3 -or $locker.Kind -eq 1000 -or $critical -contains $name) {
            $kept += $label
        }
        else {
            $closable += [PSCustomObject]@{ Process = $process; Label = $label; Explorer = ($name -eq "explorer") }
        }
    }

    if ($closable.Count -gt 0) {
        Write-SnakeOptimizerStatus -Type Info -Message "Programas segurando os arquivos: $(Join-SnakeOptimizerList -Items @($closable | ForEach-Object { $_.Label }))."

        if ($Ask -and -not (Confirm-SnakeOptimizerAction "Fechar esses programas para apagar? O que não estiver salvo neles se perde." -DefaultKey S)) {
            return [PSCustomObject]@{ Closed = @(); Kept = @($kept + @($closable | ForEach-Object { $_.Label })) }
        }
    }

    $closed = @()
    $restartExplorer = $false

    foreach ($entry in $closable) {
        try {
            Stop-Process -Id $entry.Process.Id -Force -ErrorAction Stop
            $closed += $entry.Label
            if ($entry.Explorer) { $restartExplorer = $true }
        }
        catch {
            $kept += $entry.Label
        }
    }

    if ($closed.Count -gt 0) { Start-Sleep -Milliseconds 800 }

    if ($restartExplorer -and -not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        try { Start-Process -FilePath "explorer.exe" } catch { Write-Verbose "Explorador: $($_.Exception.Message)" }
    }

    return [PSCustomObject]@{ Closed = @($closed); Kept = @($kept) }
}


function Remove-SnakeOptimizerLockedPath {
    <#
    Apaga um arquivo ou pasta pela escada descrita no topo do módulo. Devolve Removed (sumiu de vez), Pending (quantos
    itens ficaram marcados para apagar ao reiniciar), Closed e Kept (programas fechados e os que não puderam ser).
    -Ask pergunta antes de fechar programas; sem ele (perfis já confirmados, modo automático), fecha direto.
    #>
    param (
        [Parameter(Mandatory)][string]$Path,
        [switch]$Ask
    )

    $outcome = [PSCustomObject]@{ Removed = $false; Pending = 0; Closed = @(); Kept = @() }

    if (-not (Test-Path -LiteralPath $Path)) { $outcome.Removed = $true; return $outcome }

    $refusal = Test-SnakeOptimizerLockedPathAllowed -Path $Path
    if ($refusal) { throw "caminho recusado por segurança ($refusal): $Path" }

    $isFolder = Test-Path -LiteralPath $Path -PathType Container
    $long = ConvertTo-SnakeOptimizerLongPath -Path $Path

    $tryRemove = {
        try { Remove-SnakeOptimizerItem -Path $Path } catch { Write-Verbose "Apagar: $($_.Exception.Message)" }

        if (Test-Path -LiteralPath $Path) {
            if ($isFolder) { [void](Invoke-SnakeOptimizerCapture -FilePath "cmd.exe" -Arguments @("/d", "/c", "rd", "/s", "/q", $long)) }
            else { [void](Invoke-SnakeOptimizerCapture -FilePath "cmd.exe" -Arguments @("/d", "/c", "del", "/f", "/q", "/a", $long)) }
        }

        -not (Test-Path -LiteralPath $Path)
    }

    # 1. Normal.
    if (& $tryRemove) { $outcome.Removed = $true; return $outcome }

    # 2. Posse e permissão (o takeown /R e o icacls /T não entram em junções), sem somente leitura e sistema.
    Write-SnakeOptimizerStatus -Type Info -Message "Sem permissão ou em uso; tomando posse de $Path."
    try { Grant-SnakeOptimizerAdminAccess -Path $Path } catch { Write-Verbose "Posse: $($_.Exception.Message)" }
    [void](Invoke-SnakeOptimizerCapture -FilePath "attrib.exe" -Arguments $(if ($isFolder) { @("-r", "-s", "-h", "$Path\*", "/s", "/d") } else { @("-r", "-s", "-h", $Path) }))

    if (& $tryRemove) { $outcome.Removed = $true; return $outcome }

    # 3. Quem segura o que sobrou.
    $left = Get-SnakeOptimizerRemainingFiles -Path $Path
    $stopped = Stop-SnakeOptimizerFileLockers -Files @($left.Files) -Ask:$Ask
    $outcome.Closed = @($stopped.Closed)
    $outcome.Kept = @($stopped.Kept)

    if ($stopped.Closed.Count -gt 0 -and (& $tryRemove)) { $outcome.Removed = $true; return $outcome }

    # 4. Ao reiniciar: os arquivos primeiro, depois as pastas da mais funda para cima.
    $left = Get-SnakeOptimizerRemainingFiles -Path $Path
    $pending = 0

    if (Initialize-SnakeOptimizerFileLocks) {
        foreach ($entry in @($left.Files) + @($left.Folders)) {
            try { if ([SnakeOptimizer.FileLocks]::DeleteOnReboot((ConvertTo-SnakeOptimizerLongPath -Path $entry))) { $pending++ } } catch { Write-Verbose "Ao reiniciar: $($_.Exception.Message)" }
        }
    }

    $outcome.Pending = $pending
    return $outcome
}


function Invoke-SnakeOptimizerUnlockDelete {
    <#
    "Apagar arquivo ou pasta presa": a pessoa cola o caminho, a tela mostra o tamanho e quem segura, confirma e apaga pela
    escada (Remove-SnakeOptimizerLockedPath). O que não sair agora sai ao reiniciar.
    #>
    param (
        [switch]$Embedded,
        [switch]$PassThru,
        [string]$Path = ""
    )

    $title = "Apagar arquivo ou pasta presa"
    Enter-SnakeOptimizerAction -Title $title -Embedded:$Embedded
    $result = $null

    try {
        if (-not (Test-SnakeOptimizerElevation -Reason "Apagar o que está preso exige privilégios de Administrador.")) {
            $result = New-SnakeOptimizerResult -Kind Failed -Detail "requer Administrador"
        }

        if ($null -eq $result -and [string]::IsNullOrWhiteSpace($Path)) {
            Write-SnakeOptimizerStatus -Type Info -Message "No Explorador, clique com o botão direito no arquivo ou pasta e escolha ""Copiar como caminho""; depois cole aqui."
            $Path = Read-SnakeOptimizerText -Message "Caminho do arquivo ou pasta (vazio = cancelar)"
        }

        $Path = ([string]$Path).Trim().Trim('"')

        if ($null -eq $result -and -not $Path) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Nenhum caminho informado; nada foi apagado."
            $result = New-SnakeOptimizerResult -Kind Skipped -Detail "nenhum caminho informado"
        }
        elseif ($null -eq $result -and -not (Test-Path -LiteralPath $Path)) {
            Write-SnakeOptimizerStatus -Type Warning -Message "Não encontrei: $Path"
            $result = New-SnakeOptimizerResult -Kind Skipped -Detail "caminho não encontrado"
        }

        if ($null -eq $result) {
            $refusal = Test-SnakeOptimizerLockedPathAllowed -Path $Path

            if ($refusal) {
                Write-SnakeOptimizerStatus -Type Error -Message "Recusado por segurança: o caminho $refusal."
                $result = New-SnakeOptimizerResult -Kind Failed -Detail "recusado por segurança ($refusal)"
            }
        }

        if ($null -eq $result) {
            $size = Get-SnakeOptimizerTreeSize -Path $Path
            Write-SnakeOptimizerKeyValue -Label "Caminho" -Value $Path
            Write-SnakeOptimizerKeyValue -Label "Tamanho" -Value (Format-SnakeOptimizerBytes -Bytes $size -ZeroText "0 B")
            Write-Host ""
            Write-SnakeOptimizerStatus -Type Warning -Notice -Message "Não vai para a Lixeira e não tem como desfazer."

            if (-not (Confirm-SnakeOptimizerAction "Apagar de vez?" -DefaultKey N)) {
                Write-SnakeOptimizerStatus -Type Warning -Message "Nada foi apagado."
                $result = New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário"
            }
            else {
                $outcome = Remove-SnakeOptimizerLockedPath -Path $Path -Ask
                $freed = [int64][Math]::Max(0, $size - (Get-SnakeOptimizerTreeSize -Path $Path))
                $freedText = Format-SnakeOptimizerBytes -Bytes $freed -ZeroText "0 B"

                if ($outcome.Closed.Count -gt 0) { Write-SnakeOptimizerStatus -Type Info -Message "Programas fechados: $(Join-SnakeOptimizerList -Items @($outcome.Closed))." }

                if ($outcome.Removed) {
                    Write-SnakeOptimizerStatus -Type Success -Message "Apagado ($freedText)."
                    $result = New-SnakeOptimizerResult -Kind Ok -Detail "apagado ($freedText)" -Data @{ FreedBytes = $freed }
                }
                elseif ($outcome.Pending -gt 0) {
                    if ($outcome.Kept.Count -gt 0) { Write-SnakeOptimizerStatus -Type Info -Message "Ainda segurando: $(Join-SnakeOptimizerList -Items @($outcome.Kept))." }
                    Write-SnakeOptimizerStatus -Type Warning -Message "Saiu $freedText agora; $(Format-SnakeOptimizerCount -Count $outcome.Pending -One 'item preso fica' -Many 'itens presos ficam') para o Windows apagar ao reiniciar."
                    $result = New-SnakeOptimizerResult -Kind Warning -Detail "o resto sai ao reiniciar o PC" -Data @{ FreedBytes = $freed; RebootRequired = $true }
                }
                else {
                    if ($outcome.Kept.Count -gt 0) { Write-SnakeOptimizerStatus -Type Info -Message "Ainda segurando: $(Join-SnakeOptimizerList -Items @($outcome.Kept))." }
                    Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível apagar tudo; saiu $freedText."
                    $result = New-SnakeOptimizerResult -Kind Warning -Detail "parte não saiu ($freedText liberados)" -Data @{ FreedBytes = $freed }
                }
            }
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível apagar: $($_.Exception.Message)"
        $result = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message
    }

    $result.Etapa = $title
    Exit-SnakeOptimizerAction -Embedded:$Embedded -Result $result
    if ($PassThru) { return $result }
}


# ---------------------------------------------------------------------------
# Perfis de usuário
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerProfilesDirectory {
    # A pasta dos perfis (normalmente C:\Users), como o Windows a registra.
    $value = ""
    try { $value = [string](Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -Name "ProfilesDirectory" -ErrorAction Stop) } catch { $value = "" }
    if ($value) { $value = [Environment]::ExpandEnvironmentVariables($value) }
    if (-not $value) { $value = Join-Path $env:SystemDrive "Users" }
    return $value.TrimEnd('\')
}


function Get-SnakeOptimizerUserProfiles {
    <#
    Os perfis em C:\Users. Cada um: Id, Folder, Sid, Account, LastUse, Loaded (alguém conectado com ele agora), Current (o
    seu), Orphan (pasta sem registro no Windows), Missing (registro sem pasta) e Cim (para o DeleteProfile do Windows).
    Ficam de fora os perfis do sistema e as pastas padrão (Public, Default, All Users).
    #>
    $root = Get-SnakeOptimizerProfilesDirectory
    $currentSid = ""
    try { $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $currentSid = "" }

    $list = New-Object System.Collections.Generic.List[object]
    $known = @{}

    $cims = @()
    # Sem a lista do Windows, toda pasta pareceria "sem conta", inclusive a de quem está conectado: pára aqui.
    try { $cims = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special }) }
    catch { throw "o Windows não respondeu a lista de perfis ($(([string]$_.Exception.Message).Trim().TrimEnd('.')))" }

    foreach ($cim in $cims) {
        $folder = ([string]$cim.LocalPath).TrimEnd('\')
        if (-not $folder) { continue }
        $parent = Split-Path -Path $folder -Parent
        if ($parent -ne $root) { continue }

        $sid = [string]$cim.SID
        $account = ""
        try { $account = ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value } catch { $account = "" }

        $exists = Test-Path -LiteralPath $folder -PathType Container
        $lastUse = $null
        $hive = Join-Path $folder "NTUSER.DAT"
        try { if (Test-Path -LiteralPath $hive) { $lastUse = (Get-Item -LiteralPath $hive -Force -ErrorAction Stop).LastWriteTime } } catch { $lastUse = $null }

        $known[$folder.ToLowerInvariant()] = $true
        $list.Add([PSCustomObject]@{
                Id = $sid; Folder = $folder; Name = (Split-Path -Path $folder -Leaf); Sid = $sid; Account = $account
                LastUse = $lastUse; Loaded = [bool]$cim.Loaded; Current = ($sid -eq $currentSid); Orphan = $false; Missing = (-not $exists)
                Cim = $cim; Size = [int64]0
            })
    }

    $skip = @("public", "default", "default user", "all users", "defaultapppool", "wdagutilityaccount")

    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($skip -contains $dir.Name.ToLowerInvariant()) { continue }
        if ($known.ContainsKey($dir.FullName.TrimEnd('\').ToLowerInvariant())) { continue }

        $lastUse = $null
        try { $lastUse = $dir.LastWriteTime } catch { $lastUse = $null }

        $list.Add([PSCustomObject]@{
                Id = "folder:$($dir.Name)"; Folder = $dir.FullName.TrimEnd('\'); Name = $dir.Name; Sid = ""; Account = ""
                LastUse = $lastUse; Loaded = $false; Current = $false; Orphan = $true; Missing = $false; Cim = $null; Size = [int64]0
            })
    }

    return @($list | Sort-Object -Property Name)
}


function Get-SnakeOptimizerUserProfileLabel {
    # A descrição de uma linha da lista: a conta, o último uso e o tamanho.
    param ([Parameter(Mandatory)]$Entry)

    $parts = @()

    if ($entry.Orphan) { $parts += "pasta sem conta no Windows (sobra de outro Windows ou de uma conta já removida)" }
    elseif ($entry.Missing) { $parts += "só o registro no Windows; a pasta já não existe" }
    elseif ($entry.Account) { $parts += "conta $($entry.Account)" }
    else { $parts += "conta que não existe mais ou de um domínio fora de alcance" }

    if ($null -ne $entry.LastUse) { $parts += "último uso em $($entry.LastUse.ToString('dd/MM/yyyy'))" }

    return ($parts -join " · ")
}


function Invoke-SnakeOptimizerUserProfileCleanup {
    <#
    Limpeza de perfis de usuário: lista as pastas de C:\Users (menos a sua e as de quem está conectado agora), com o tamanho,
    a conta e o último uso; apaga as marcadas por inteiro. Primeiro pelo próprio Windows (DeleteProfile, que também tira o
    registro do perfil); o que sobrar sai pela escada de Remove-SnakeOptimizerLockedPath (posse, programas que seguram,
    ao reiniciar). A conta em si não é apagada: se a pessoa entrar de novo no PC, o Windows cria um perfil novo e vazio.
    #>
    param (
        [switch]$Embedded,
        [switch]$PassThru
    )

    $title = "Limpar perfis de usuário"
    Enter-SnakeOptimizerAction -Title $title -Embedded:$Embedded
    $result = $null

    try {
        if (-not (Test-SnakeOptimizerElevation -Reason "Apagar perfis de outros usuários exige privilégios de Administrador.")) {
            $result = New-SnakeOptimizerResult -Kind Failed -Detail "requer Administrador"
        }

        $profiles = @()
        $candidates = @()

        if ($null -eq $result) {
            $profiles = @(Get-SnakeOptimizerUserProfiles)
            $mine = @($profiles | Where-Object { $_.Current })
            $inUse = @($profiles | Where-Object { $_.Loaded -and -not $_.Current })
            $candidates = @($profiles | Where-Object { -not $_.Current -and -not $_.Loaded })

            Write-SnakeOptimizerKeyValue -Label "Pasta dos perfis" -Value (Get-SnakeOptimizerProfilesDirectory)
            if ($mine.Count -gt 0) { Write-SnakeOptimizerKeyValue -Label "Seu perfil (fica)" -Value $mine[0].Name }
            if ($inUse.Count -gt 0) { Write-SnakeOptimizerKeyValue -Label "Conectados agora (ficam)" -Value (($inUse | ForEach-Object { $_.Name }) -join ", ") }
            Write-Host ""

            if ($candidates.Count -eq 0) {
                Write-SnakeOptimizerStatus -Type Success -Message "Não há outros perfis neste PC."
                $result = New-SnakeOptimizerResult -Kind Skipped -Detail "não há outros perfis"
                [void](Set-SnakeOptimizerResultView -Result $result -Headline "Nenhum outro perfil" -Note "Em $(Get-SnakeOptimizerProfilesDirectory) só estão o seu perfil e os de quem está conectado.")
            }
        }

        $chosen = @()

        if ($null -eq $result) {
            $activity = "Medindo os perfis"
            $position = 0

            foreach ($entry in $candidates) {
                $position++
                Write-Progress -Activity $activity -Status "$($entry.Name) ($position de $($candidates.Count))" -PercentComplete ([int](($position - 1) * 100 / $candidates.Count))
                try { $entry.Size = Get-SnakeOptimizerTreeSize -Path $entry.Folder } catch { $entry.Size = [int64]0 }
            }

            Write-Progress -Activity $activity -Completed

            $options = @(
                foreach ($entry in $candidates) {
                    @{ Key = $entry.Id; Label = "$($entry.Name) · $(Format-SnakeOptimizerBytes -Bytes ([int64]$entry.Size) -ZeroText '0 B')"; Description = (Get-SnakeOptimizerUserProfileLabel -Entry $entry); Selected = $false }
                }
            )

            Write-SnakeOptimizerStatus -Type Info -Message "Tudo o que está na pasta do perfil marcado sai: Área de Trabalho, Documentos, Downloads, arquivos do Outlook e as configurações dos programas."
            Write-Host ""

            $picked = @(Read-SnakeOptimizerMultiSelect -Message "Marque os perfis que deseja apagar" -Options $options -NoSelectAll -ConfirmLabel "Apagar")
            $chosen = @($candidates | Where-Object { $picked -contains $_.Id })

            if ($chosen.Count -eq 0) {
                Write-SnakeOptimizerStatus -Type Warning -Message "Nada foi marcado; nenhum perfil foi apagado."
                $result = New-SnakeOptimizerResult -Kind Skipped -Detail "nada marcado"
            }
            else {
                $total = [int64]0
                foreach ($entry in $chosen) { $total += [int64]$entry.Size }

                Write-Host ""
                Write-SnakeOptimizerStatus -Type Warning -Notice -Message "Não vai para a Lixeira e não tem como desfazer. Copie antes o que alguém ainda precisar."
                $what = $(if ($chosen.Count -eq 1) { "o perfil $($chosen[0].Name)" } else { "os $($chosen.Count) perfis marcados" })

                if (-not (Confirm-SnakeOptimizerAction "Apagar $what ($(Format-SnakeOptimizerBytes -Bytes $total -ZeroText '0 B')) de vez?" -DefaultKey N)) {
                    Write-SnakeOptimizerStatus -Type Warning -Message "Nenhum perfil foi apagado."
                    $result = New-SnakeOptimizerResult -Kind Skipped -Detail "cancelado pelo usuário"
                }
            }
        }

        if ($null -eq $result) {
            $freed = [int64]0
            $pendingTotal = 0
            $problems = New-Object System.Collections.Generic.List[string]
            $done = 0

            foreach ($entry in $chosen) {
                Write-SnakeOptimizerSection -Title "Perfil $($entry.Name)"

                # Programas que ainda rodam a partir da pasta (um atualizador, um OneDrive esquecido).
                foreach ($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith("$($entry.Folder)\", [StringComparison]::OrdinalIgnoreCase) })) {
                    try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop; Write-SnakeOptimizerStatus -Type Info -Message "Fechado: $($process.Name)." } catch { Write-Verbose "Fechar: $($_.Exception.Message)" }
                }

                # 1. Pelo Windows: tira o perfil do registro e apaga a pasta.
                if ($null -ne $entry.Cim) {
                    try {
                        Remove-CimInstance -InputObject $entry.Cim -ErrorAction Stop
                        Write-SnakeOptimizerStatus -Type Info -Message "O Windows removeu o registro do perfil."
                    }
                    catch {
                        Write-SnakeOptimizerStatus -Type Info -Message "O Windows não apagou tudo ($(([string]$_.Exception.Message).Trim().TrimEnd('.'))); seguindo com o desbloqueio."
                    }
                }

                # 2. O que sobrou na pasta.
                $outcome = $null

                try {
                    $outcome = Remove-SnakeOptimizerLockedPath -Path $entry.Folder
                }
                catch {
                    Write-SnakeOptimizerStatus -Type Error -Message "$($entry.Name): $($_.Exception.Message.TrimEnd('.'))."
                    $problems.Add($entry.Name)
                }

                # 3. Um registro de perfil sem pasta faria o Windows entrar com um perfil temporário: sai também.
                if ($entry.Sid -and -not (Test-Path -LiteralPath $entry.Folder)) {
                    foreach ($key in @($entry.Sid, "$($entry.Sid).bak")) {
                        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$key"
                        if (Test-Path -LiteralPath $regPath) { try { Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction Stop } catch { Write-Verbose "Registro: $($_.Exception.Message)" } }
                    }
                }

                $left = Get-SnakeOptimizerTreeSize -Path $entry.Folder
                $freed += [int64][Math]::Max(0, [int64]$entry.Size - $left)

                if ($null -ne $outcome) {
                    if ($outcome.Closed.Count -gt 0) { Write-SnakeOptimizerStatus -Type Info -Message "Programas fechados: $(Join-SnakeOptimizerList -Items @($outcome.Closed))." }

                    if ($outcome.Removed) {
                        Write-SnakeOptimizerStatus -Type Success -Message "Perfil $($entry.Name) apagado."
                        $done++
                    }
                    elseif ($outcome.Pending -gt 0) {
                        $pendingTotal += $outcome.Pending
                        Write-SnakeOptimizerStatus -Type Warning -Message "Perfil $($entry.Name): o que ficou preso sai ao reiniciar o PC."
                        $done++
                    }
                    else {
                        Write-SnakeOptimizerStatus -Type Warning -Message "Perfil $($entry.Name): parte não saiu."
                        $problems.Add($entry.Name)
                    }
                }
            }

            $freedText = Format-SnakeOptimizerBytes -Bytes $freed -ZeroText "0 B"
            Write-SnakeOptimizerSection -Title "Resumo"
            Write-SnakeOptimizerKeyValue -Label "Perfis apagados" -Value "$done de $($chosen.Count)"
            Write-SnakeOptimizerKeyValue -Label "Espaço liberado" -Value $freedText

            $data = @{ FreedBytes = $freed }
            if ($pendingTotal -gt 0) { $data.RebootRequired = $true }

            if ($problems.Count -gt 0) {
                $result = New-SnakeOptimizerResult -Kind Warning -Detail "liberou $freedText; não saiu por inteiro: $(Join-SnakeOptimizerList -Items @($problems))" -Data $data
            }
            elseif ($pendingTotal -gt 0) {
                $result = New-SnakeOptimizerResult -Kind Warning -Detail "liberou $freedText; o resto sai ao reiniciar o PC" -Data $data
            }
            else {
                $result = New-SnakeOptimizerResult -Kind Ok -Detail "$(Format-SnakeOptimizerCount -Count $done -One 'perfil apagado' -Many 'perfis apagados'); liberou $freedText" -Data $data
            }
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Ocorreu um erro na limpeza de perfis: $($_.Exception.Message)"
        $result = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message
    }

    $result.Etapa = $title
    Exit-SnakeOptimizerAction -Embedded:$Embedded -Result $result
    if ($PassThru) { return $result }
}


Export-ModuleMember -Function *
