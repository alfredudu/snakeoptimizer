# ---------------------------------------------------------------------------
# E-mail com o resumo (SMTP) e a área técnica
# ---------------------------------------------------------------------------
# O que fica onde:
#   - config\tecnico.json (no repositório, público): só o hash PBKDF2 da senha técnica, com o sal. A senha em si não fica
#     em lugar nenhum. Gerado por tools\definir-senha-tecnica.ps1.
#   - %ProgramData%\SnakeOptimizer\email.json (só no PC, nunca no GitHub): servidor, usuário, remetente, destinatários,
#     quando enviar e a senha do SMTP cifrada pelo Windows (DPAPI da máquina, para a manutenção automática, que roda como
#     SYSTEM, também conseguir enviar). O arquivo fica só com Administradores e SYSTEM.
#   - Exportar/Importar: um arquivo .snakemail cifrado com a senha técnica (AES-256 + HMAC), para configurar outros PCs
#     sem digitar o SMTP de novo.
# O envio usa um cliente SMTP próprio: o System.Net.Mail do .NET não fala SSL direto na porta 465 (só STARTTLS).

$script:SnakeOptimizerSmtpSource = @"
using System;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;

namespace SnakeOptimizer
{
    public class SmtpFailure : Exception
    {
        public int Code;
        public SmtpFailure(int code, string message) : base(message) { Code = code; }
    }

    public static class SmtpMailer
    {
        private static string ReadReply(StreamReader reader, out int code)
        {
            StringBuilder all = new StringBuilder();
            string line;
            code = 0;

            while ((line = reader.ReadLine()) != null)
            {
                all.AppendLine(line);
                if (line.Length >= 3) { int.TryParse(line.Substring(0, 3), out code); }
                if (line.Length < 4 || line[3] != '-') { break; }
            }

            return all.ToString().Trim();
        }

        private static string Command(Stream stream, StreamReader reader, string text, int expected, int alternative)
        {
            if (text != null)
            {
                byte[] bytes = Encoding.ASCII.GetBytes(text + "\r\n");
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush();
            }

            int code;
            string reply = ReadReply(reader, out code);
            if (code != expected && code != alternative) { throw new SmtpFailure(code, reply); }
            return reply;
        }

        private static string B64(string text) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(text)); }

        private static string Wrap(string base64)
        {
            StringBuilder lines = new StringBuilder();
            for (int i = 0; i < base64.Length; i += 76) { lines.Append(base64.Substring(i, Math.Min(76, base64.Length - i))).Append("\r\n"); }
            return lines.ToString();
        }

        private static string Header(string text)
        {
            foreach (char c in text) { if (c > 126 || c < 32) { return "=?utf-8?B?" + B64(text) + "?="; } }
            return text;
        }

        public static string BuildMessage(string from, string fromName, string[] to, string subject, string html, string text, string attachmentPath)
        {
            string mix = "mix_" + Guid.NewGuid().ToString("N");
            string alt = "alt_" + Guid.NewGuid().ToString("N");
            DateTimeOffset now = DateTimeOffset.Now;
            string zone = (now.Offset < TimeSpan.Zero ? "-" : "+") + now.Offset.ToString("hhmm");
            string domain = from.Contains("@") ? from.Substring(from.IndexOf('@') + 1) : "snakeoptimizer";

            StringBuilder m = new StringBuilder();
            m.Append("From: ").Append(string.IsNullOrEmpty(fromName) ? "" : Header(fromName) + " ").Append("<").Append(from).Append(">\r\n");
            m.Append("To: ").Append(string.Join(", ", to)).Append("\r\n");
            m.Append("Subject: ").Append(Header(subject)).Append("\r\n");
            m.Append("Date: ").Append(now.ToString("ddd, dd MMM yyyy HH:mm:ss ", System.Globalization.CultureInfo.InvariantCulture)).Append(zone).Append("\r\n");
            m.Append("Message-ID: <").Append(Guid.NewGuid().ToString("N")).Append("@").Append(domain).Append(">\r\n");
            m.Append("MIME-Version: 1.0\r\n");
            m.Append("X-Mailer: SnakeOptimizer\r\n");
            m.Append("Content-Type: multipart/mixed; boundary=\"").Append(mix).Append("\"\r\n\r\n");

            m.Append("--").Append(mix).Append("\r\n");
            m.Append("Content-Type: multipart/alternative; boundary=\"").Append(alt).Append("\"\r\n\r\n");
            m.Append("--").Append(alt).Append("\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n").Append(Wrap(B64(text ?? "")));
            m.Append("--").Append(alt).Append("\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n").Append(Wrap(B64(html ?? "")));
            m.Append("--").Append(alt).Append("--\r\n");

            if (!string.IsNullOrEmpty(attachmentPath) && File.Exists(attachmentPath))
            {
                string name = Path.GetFileName(attachmentPath);
                string type = name.EndsWith(".html", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".htm", StringComparison.OrdinalIgnoreCase) ? "text/html" : (name.EndsWith(".txt", StringComparison.OrdinalIgnoreCase) ? "text/plain" : "application/octet-stream");
                m.Append("--").Append(mix).Append("\r\n");
                m.Append("Content-Type: ").Append(type).Append("; name=\"").Append(Header(name)).Append("\"\r\n");
                m.Append("Content-Disposition: attachment; filename=\"").Append(Header(name)).Append("\"\r\n");
                m.Append("Content-Transfer-Encoding: base64\r\n\r\n");
                m.Append(Wrap(Convert.ToBase64String(File.ReadAllBytes(attachmentPath))));
            }

            m.Append("--").Append(mix).Append("--\r\n");
            return m.ToString();
        }

        // implicitTls = SSL direto (porta 465); senão, STARTTLS (587, 2525). Sem TLS, não envia (a senha iria aberta).
        public static void Send(string host, int port, bool implicitTls, string user, string password, string from, string[] to, string message, int timeoutMs)
        {
            using (TcpClient client = new TcpClient())
            {
                if (!client.ConnectAsync(host, port).Wait(timeoutMs)) { throw new SmtpFailure(0, "tempo esgotado ao conectar em " + host + ":" + port); }
                client.ReceiveTimeout = timeoutMs;
                client.SendTimeout = timeoutMs;

                Stream stream = client.GetStream();
                SslStream ssl = null;

                try
                {
                    if (implicitTls)
                    {
                        ssl = new SslStream(stream, false);
                        ssl.AuthenticateAsClient(host, null, SslProtocols.Tls12, true);
                        stream = ssl;
                    }

                    StreamReader reader = new StreamReader(stream, Encoding.ASCII);
                    string me = Environment.MachineName;

                    Command(stream, reader, null, 220, 220);
                    Command(stream, reader, "EHLO " + me, 250, 250);

                    if (!implicitTls)
                    {
                        Command(stream, reader, "STARTTLS", 220, 220);
                        ssl = new SslStream(stream, false);
                        ssl.AuthenticateAsClient(host, null, SslProtocols.Tls12, true);
                        stream = ssl;
                        reader = new StreamReader(stream, Encoding.ASCII);
                        Command(stream, reader, "EHLO " + me, 250, 250);
                    }

                    Command(stream, reader, "AUTH LOGIN", 334, 334);
                    Command(stream, reader, Convert.ToBase64String(Encoding.UTF8.GetBytes(user)), 334, 334);
                    Command(stream, reader, Convert.ToBase64String(Encoding.UTF8.GetBytes(password)), 235, 235);
                    Command(stream, reader, "MAIL FROM:<" + from + ">", 250, 250);
                    foreach (string rcpt in to) { Command(stream, reader, "RCPT TO:<" + rcpt + ">", 250, 251); }
                    Command(stream, reader, "DATA", 354, 354);

                    byte[] body = Encoding.ASCII.GetBytes(message + "\r\n.\r\n");
                    stream.Write(body, 0, body.Length);
                    stream.Flush();
                    Command(stream, reader, null, 250, 250);

                    try { Command(stream, reader, "QUIT", 221, 221); } catch { }
                }
                finally
                {
                    if (ssl != null) { ssl.Dispose(); }
                }
            }
        }
    }
}
"@


function Initialize-SnakeOptimizerSmtp {
    if ("SnakeOptimizer.SmtpMailer" -as [type]) { return $true }

    try {
        Add-Type -TypeDefinition $script:SnakeOptimizerSmtpSource -ErrorAction Stop
        return $true
    }
    catch {
        Write-Verbose "SMTP: $($_.Exception.Message)"
        return $false
    }
}


# ---------------------------------------------------------------------------
# Onde as coisas ficam
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerEmailConfigPath {
    $root = Join-Path $env:ProgramData "SnakeOptimizer"
    if (-not (Test-Path -LiteralPath $root)) { [void](New-Item -Path $root -ItemType Directory -Force) }
    return (Join-Path $root "email.json")
}


function Get-SnakeOptimizerTechnicianHashPath {
    return (Join-Path (Split-Path -Parent $PSScriptRoot) "config\tecnico.json")
}


function Get-SnakeOptimizerEmailDefaults {
    # SMTP2GO com SSL direto na 465. Remetente e destinatários ficam em branco: são do técnico e não vão para o GitHub.
    return [PSCustomObject]@{
        Enabled      = $false
        Host         = "mail.smtp2go.com"
        Port         = 465
        Security     = "SSL"
        User         = ""
        Password     = ""
        From         = ""
        FromName     = "SnakeOptimizer"
        To           = @()
        Optimize     = $true
        Automatic    = $true
        Standalone   = $false
        OnlyProblems = $false
    }
}


# ---------------------------------------------------------------------------
# Senha técnica
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerPasswordHash {
    # PBKDF2-SHA256 (o mesmo esquema de sites que guardam senhas). Devolve os bytes.
    param (
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][byte[]]$Salt,
        [int]$Iterations = 200000,
        [int]$Length = 32
    )

    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes ([Text.Encoding]::UTF8.GetBytes($Password)), $Salt, $Iterations, ([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return $derive.GetBytes($Length) } finally { $derive.Dispose() }
}


function Test-SnakeOptimizerTechnicianConfigured {
    return (Test-Path -LiteralPath (Get-SnakeOptimizerTechnicianHashPath) -PathType Leaf)
}


function Test-SnakeOptimizerTechnicianPassword {
    # Confere a senha com o hash de config\tecnico.json, em tempo constante.
    param ([Parameter(Mandatory)][AllowEmptyString()][string]$Password)

    if (-not $Password) { return $false }

    try {
        $document = Get-Content -LiteralPath (Get-SnakeOptimizerTechnicianHashPath) -Raw -Encoding UTF8 | ConvertFrom-Json
        $salt = [Convert]::FromBase64String([string]$document.Salt)
        $expected = [Convert]::FromBase64String([string]$document.Hash)
        $actual = Get-SnakeOptimizerPasswordHash -Password $Password -Salt $salt -Iterations ([int]$document.Iterations) -Length $expected.Length

        $difference = 0
        for ($i = 0; $i -lt $expected.Length; $i++) { $difference = $difference -bor ($expected[$i] -bxor $actual[$i]) }
        return ($difference -eq 0)
    }
    catch {
        return $false
    }
}


function ConvertFrom-SnakeOptimizerSecureText {
    param ($Secure)

    if ($null -eq $Secure) { return "" }
    if ($Secure -is [string]) { return $Secure }

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}


# ---------------------------------------------------------------------------
# Configuração do e-mail
# ---------------------------------------------------------------------------

function Protect-SnakeOptimizerSecret {
    param ([string]$Text)

    if (-not $Text) { return "" }
    Add-Type -AssemblyName System.Security
    $bytes = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Text), [Text.Encoding]::UTF8.GetBytes("SnakeOptimizer.Email"), [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($bytes)
}


function Unprotect-SnakeOptimizerSecret {
    param ([string]$Protected)

    if (-not $Protected) { return "" }
    Add-Type -AssemblyName System.Security
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Protected), [Text.Encoding]::UTF8.GetBytes("SnakeOptimizer.Email"), [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Text.Encoding]::UTF8.GetString($bytes)
}


function Get-SnakeOptimizerEmailConfig {
    # A configuração deste PC, com a senha já decifrada; os padrões quando não há (ou não dá para ler).
    $config = Get-SnakeOptimizerEmailDefaults

    try {
        $state = Read-SnakeOptimizerStateFile -Path (Get-SnakeOptimizerEmailConfigPath)
        if ($null -eq $state.Document) { return $config }
        $document = $state.Document

        foreach ($name in @("Enabled", "Host", "Port", "Security", "User", "From", "FromName", "Optimize", "Automatic", "Standalone", "OnlyProblems")) {
            $value = Get-SnakeOptimizerJsonValue -Object $document -Name $name
            if ($null -ne $value) { $config.$name = $value }
        }

        $config.To = @(@(Get-SnakeOptimizerJsonValue -Object $document -Name "To" -Default @()) | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $config.Password = Unprotect-SnakeOptimizerSecret -Protected ([string](Get-SnakeOptimizerJsonValue -Object $document -Name "PasswordProtected" -Default ""))
    }
    catch {
        Write-Verbose "Configuração de e-mail: $($_.Exception.Message)"
    }

    return $config
}


function Save-SnakeOptimizerEmailConfig {
    # Grava a configuração (senha cifrada) e deixa o arquivo só com Administradores e SYSTEM.
    param ([Parameter(Mandatory)]$Config)

    $path = Get-SnakeOptimizerEmailConfigPath
    $document = [ordered]@{
        Enabled           = [bool]$Config.Enabled
        Host              = [string]$Config.Host
        Port              = [int]$Config.Port
        Security          = [string]$Config.Security
        User              = [string]$Config.User
        PasswordProtected = (Protect-SnakeOptimizerSecret -Text ([string]$Config.Password))
        From              = [string]$Config.From
        FromName          = [string]$Config.FromName
        To                = @($Config.To)
        Optimize          = [bool]$Config.Optimize
        Automatic         = [bool]$Config.Automatic
        Standalone        = [bool]$Config.Standalone
        OnlyProblems      = [bool]$Config.OnlyProblems
    }

    Write-SnakeOptimizerStateJson -Path $path -InputObject $document

    foreach ($file in @($path, "$path.bak")) {
        if (Test-Path -LiteralPath $file) {
            [void](Invoke-SnakeOptimizerCapture -FilePath "icacls.exe" -Arguments @($file, "/inheritance:r", "/grant:r", "*S-1-5-32-544:F", "/grant:r", "*S-1-5-18:F", "/Q"))
        }
    }
}


function Test-SnakeOptimizerEmailReady {
    param ($Config)
    return ($null -ne $Config -and [bool]$Config.Enabled -and $Config.Host -and $Config.User -and $Config.Password -and $Config.From -and @($Config.To).Count -gt 0)
}


# ---------------------------------------------------------------------------
# O e-mail: modelo de dados, HTML e texto
# ---------------------------------------------------------------------------

function New-SnakeOptimizerEmailReport {
    <#
    O que vai no e-mail. Kind: Ok, Warning ou Failed. Steps: Name, Kind (Ok/Warning/Failed/Skipped), Detail, Duration e
    SpaceDelta (bytes; $null sem medição). Disk: FreeBefore, FreeAfter, TotalBytes (ou $null).
    #>
    param (
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Event,
        [string]$Kind = "Ok",
        [string]$Outcome = "",
        [datetime]$StartedAt = (Get-Date),
        [string]$Duration = "",
        $Disk = $null,
        [object[]]$Steps = @(),
        [string[]]$Attention = @(),
        [bool]$Reboot = $false,
        [string]$Attachment = "",
        [string]$Computer = $env:COMPUTERNAME,
        [string]$UserName = $env:USERNAME
    )

    $version = ""
    try { $version = [string](Get-SnakeOptimizerBuild) } catch { $version = "" }

    return [PSCustomObject]@{
        Title = $Title; Event = $Event; Kind = $Kind; Outcome = $Outcome; StartedAt = $StartedAt; Duration = $Duration
        Disk = $Disk; Steps = @($Steps); Attention = @($Attention | Where-Object { $_ }); Reboot = $Reboot; Attachment = $Attachment
        Computer = $Computer; UserName = $UserName; Version = $version
    }
}


function Get-SnakeOptimizerEmailKindText {
    param ([string]$Kind)
    switch ($Kind) { "Ok" { "tudo certo" } "Warning" { "com pontos de atenção" } "Failed" { "com falha" } "Skipped" { "pulado" } default { $Kind } }
}


function Get-SnakeOptimizerEmailSubject {
    param ([Parameter(Mandatory)]$Report)

    $parts = @("[SnakeOptimizer]", $Report.Computer, "·", $Report.Title, "·", (Get-SnakeOptimizerEmailKindText -Kind $Report.Kind))

    if ($null -ne $Report.Disk) {
        $delta = [int64]$Report.Disk.FreeAfter - [int64]$Report.Disk.FreeBefore
        if ([Math]::Abs($delta) -ge 1MB) { $parts += @("·", (Format-SnakeOptimizerSpaceDelta -Delta $delta)) }
    }

    if ($Report.Reboot) { $parts += @("·", "pede reinício") }
    return ($parts -join " ")
}


function ConvertTo-SnakeOptimizerHtmlText {
    param ([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}


function ConvertTo-SnakeOptimizerEmailHtml {
    <#
    O corpo em HTML, com CSS embutido em cada elemento (os programas de e-mail ignoram <style>), largura de 640 px e
    cores claras, que leem bem no Outlook, no Gmail e no celular.
    #>
    param ([Parameter(Mandatory)]$Report)

    $h = { param ($t) ConvertTo-SnakeOptimizerHtmlText -Text $t }
    $color = switch ($Report.Kind) { "Ok" { "#1a7f37" } "Warning" { "#9a6700" } "Failed" { "#cf222e" } default { "#57606a" } }
    $badge = switch ($Report.Kind) { "Ok" { "Tudo certo" } "Warning" { "Com pontos de atenção" } "Failed" { "Com falha" } default { "Concluído" } }
    $date = $Report.StartedAt.ToString("dd/MM/yyyy 'às' HH:mm", [Globalization.CultureInfo]::GetCultureInfo("pt-BR"))

    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>')
    [void]$html.Append('<body style="margin:0;padding:0;background:#f3f4f6;font-family:Segoe UI,Arial,sans-serif;color:#1f2328;">')
    [void]$html.Append('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 12px;"><tr><td align="center">')
    [void]$html.Append('<table role="presentation" width="640" cellpadding="0" cellspacing="0" style="max-width:640px;width:100%;background:#ffffff;border-radius:12px;border:1px solid #d0d7de;">')

    # Cabeçalho
    [void]$html.Append('<tr><td style="padding:20px 24px;border-bottom:1px solid #d0d7de;">')
    [void]$html.Append('<div style="font-size:12px;color:#57606a;letter-spacing:.04em;text-transform:uppercase;">SnakeOptimizer · Snake Tech</div>')
    [void]$html.Append("<div style=`"font-size:22px;font-weight:600;margin-top:6px;`">$(& $h $Report.Title)</div>")
    [void]$html.Append("<div style=`"margin-top:10px;`"><span style=`"display:inline-block;padding:4px 10px;border-radius:999px;background:$color;color:#ffffff;font-size:13px;font-weight:600;`">$badge</span>")
    if ($Report.Reboot) { [void]$html.Append('&nbsp;<span style="display:inline-block;padding:4px 10px;border-radius:999px;background:#9a6700;color:#ffffff;font-size:13px;font-weight:600;">Pede reinício</span>') }
    [void]$html.Append('</div>')
    if ($Report.Outcome) { [void]$html.Append("<div style=`"margin-top:10px;font-size:14px;color:#1f2328;`">$(& $h $Report.Outcome)</div>") }
    [void]$html.Append('</td></tr>')

    # O PC
    [void]$html.Append('<tr><td style="padding:16px 24px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;">')
    foreach ($row in @(@("Computador", $Report.Computer), @("Usuário", $Report.UserName), @("Quando", $date), @("Duração", $Report.Duration), @("Versão", $Report.Version))) {
        if (-not $row[1]) { continue }
        [void]$html.Append("<tr><td style=`"padding:3px 0;color:#57606a;width:140px;`">$($row[0])</td><td style=`"padding:3px 0;font-weight:600;`">$(& $h $row[1])</td></tr>")
    }
    [void]$html.Append('</table></td></tr>')

    # O disco
    if ($null -ne $Report.Disk) {
        $before = [int64]$Report.Disk.FreeBefore
        $after = [int64]$Report.Disk.FreeAfter
        $total = [int64]$Report.Disk.TotalBytes
        $delta = $after - $before
        $deltaColor = $(if ($delta -ge 1MB) { "#1a7f37" } elseif ($delta -le -1MB) { "#cf222e" } else { "#57606a" })
        $usedPct = $(if ($total -gt 0) { [int][Math]::Round(($total - $after) * 100.0 / $total) } else { -1 })

        [void]$html.Append('<tr><td style="padding:4px 24px 16px;"><div style="font-size:15px;font-weight:600;margin-bottom:8px;">Disco do sistema</div>')
        [void]$html.Append('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #d0d7de;border-radius:8px;"><tr>')
        [void]$html.Append("<td align=`"center`" style=`"padding:12px;border-right:1px solid #d0d7de;`"><div style=`"font-size:12px;color:#57606a;`">ANTES</div><div style=`"font-size:18px;font-weight:600;`">$(Format-SnakeOptimizerPreciseBytes -Bytes $before)</div><div style=`"font-size:12px;color:#57606a;`">livres</div></td>")
        [void]$html.Append("<td align=`"center`" style=`"padding:12px;border-right:1px solid #d0d7de;`"><div style=`"font-size:12px;color:#57606a;`">DEPOIS</div><div style=`"font-size:18px;font-weight:600;`">$(Format-SnakeOptimizerPreciseBytes -Bytes $after)</div><div style=`"font-size:12px;color:#57606a;`">livres</div></td>")
        [void]$html.Append("<td align=`"center`" style=`"padding:12px;`"><div style=`"font-size:12px;color:#57606a;`">DIFERENÇA</div><div style=`"font-size:18px;font-weight:600;color:$deltaColor;`">$(Format-SnakeOptimizerSpaceDelta -Delta $delta)</div><div style=`"font-size:12px;color:#57606a;`">$(if ($usedPct -ge 0) { "disco $usedPct% usado" } else { '&nbsp;' })</div></td>")
        [void]$html.Append('</tr></table></td></tr>')
    }

    # Atenção
    if (@($Report.Attention).Count -gt 0) {
        [void]$html.Append('<tr><td style="padding:4px 24px 16px;"><div style="background:#fff8c5;border:1px solid #d4a72c;border-radius:8px;padding:12px 14px;">')
        [void]$html.Append('<div style="font-size:15px;font-weight:600;margin-bottom:6px;">Pede atenção</div><ul style="margin:0;padding-left:18px;font-size:14px;">')
        foreach ($item in $Report.Attention) { [void]$html.Append("<li style=`"margin:3px 0;`">$(& $h $item)</li>") }
        [void]$html.Append('</ul></div></td></tr>')
    }

    # Etapas
    if (@($Report.Steps).Count -gt 0) {
        [void]$html.Append('<tr><td style="padding:4px 24px 20px;"><div style="font-size:15px;font-weight:600;margin-bottom:8px;">Etapas</div>')
        [void]$html.Append('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:13px;border-collapse:collapse;">')
        [void]$html.Append('<tr style="background:#f6f8fa;"><td style="padding:8px;border-bottom:1px solid #d0d7de;font-weight:600;">Etapa</td><td style="padding:8px;border-bottom:1px solid #d0d7de;font-weight:600;">Resultado</td><td align="right" style="padding:8px;border-bottom:1px solid #d0d7de;font-weight:600;">Espaço</td><td align="right" style="padding:8px;border-bottom:1px solid #d0d7de;font-weight:600;">Tempo</td></tr>')

        foreach ($step in $Report.Steps) {
            $mark = switch ([string]$step.Kind) { "Ok" { '<span style="color:#1a7f37;">●</span>' } "Warning" { '<span style="color:#9a6700;">●</span>' } "Failed" { '<span style="color:#cf222e;">●</span>' } default { '<span style="color:#8c959f;">○</span>' } }
            $space = ""
            if ($null -ne $step.SpaceDelta -and [Math]::Abs([int64]$step.SpaceDelta) -ge 1MB) { $space = Format-SnakeOptimizerSpaceDelta -Delta ([int64]$step.SpaceDelta) }
            $detail = $(if ($step.Detail) { $step.Detail } else { Get-SnakeOptimizerEmailKindText -Kind $step.Kind })
            [void]$html.Append("<tr><td style=`"padding:7px 8px;border-bottom:1px solid #eaeef2;vertical-align:top;`">$mark&nbsp;$(& $h $step.Name)</td><td style=`"padding:7px 8px;border-bottom:1px solid #eaeef2;color:#57606a;vertical-align:top;`">$(& $h $detail)</td><td align=`"right`" style=`"padding:7px 8px;border-bottom:1px solid #eaeef2;white-space:nowrap;vertical-align:top;`">$(& $h $space)</td><td align=`"right`" style=`"padding:7px 8px;border-bottom:1px solid #eaeef2;white-space:nowrap;color:#57606a;vertical-align:top;`">$(& $h $step.Duration)</td></tr>")
        }

        [void]$html.Append('</table></td></tr>')
    }

    # Rodapé
    [void]$html.Append('<tr><td style="padding:14px 24px;border-top:1px solid #d0d7de;font-size:12px;color:#57606a;">')
    if ($Report.Attachment) { [void]$html.Append('O relatório completo do PC vai em anexo. ') }
    [void]$html.Append('E-mail automático do SnakeOptimizer. Para mudar o que é enviado: SnakeOptimizer &gt; Área técnica.</td></tr>')
    [void]$html.Append('</table></td></tr></table></body></html>')

    return $html.ToString()
}


function ConvertTo-SnakeOptimizerEmailText {
    # A versão em texto puro (para quem lê sem HTML).
    param ([Parameter(Mandatory)]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("SnakeOptimizer - $($Report.Title): $(Get-SnakeOptimizerEmailKindText -Kind $Report.Kind)")
    if ($Report.Outcome) { $lines.Add($Report.Outcome) }
    $lines.Add("")
    $lines.Add("Computador: $($Report.Computer)")
    $lines.Add("Usuário: $($Report.UserName)")
    $lines.Add("Quando: $($Report.StartedAt.ToString('dd/MM/yyyy HH:mm'))")
    if ($Report.Duration) { $lines.Add("Duração: $($Report.Duration)") }
    if ($Report.Reboot) { $lines.Add("PEDE REINÍCIO") }

    if ($null -ne $Report.Disk) {
        $lines.Add("")
        $lines.Add("Disco do sistema")
        $lines.Add("  Antes:  $(Format-SnakeOptimizerFreeSpaceText -FreeBytes $Report.Disk.FreeBefore -TotalBytes $Report.Disk.TotalBytes)")
        $lines.Add("  Depois: $(Format-SnakeOptimizerFreeSpaceText -FreeBytes $Report.Disk.FreeAfter -TotalBytes $Report.Disk.TotalBytes)")
        $lines.Add("  Diferença: $(Format-SnakeOptimizerSpaceDelta -Delta ([int64]$Report.Disk.FreeAfter - [int64]$Report.Disk.FreeBefore))")
    }

    if (@($Report.Attention).Count -gt 0) {
        $lines.Add("")
        $lines.Add("Pede atenção")
        foreach ($item in $Report.Attention) { $lines.Add("  - $item") }
    }

    if (@($Report.Steps).Count -gt 0) {
        $lines.Add("")
        $lines.Add("Etapas")
        foreach ($step in $Report.Steps) {
            $space = $(if ($null -ne $step.SpaceDelta -and [Math]::Abs([int64]$step.SpaceDelta) -ge 1MB) { " · $(Format-SnakeOptimizerSpaceDelta -Delta ([int64]$step.SpaceDelta))" } else { "" })
            $detail = $(if ($step.Detail) { $step.Detail } else { Get-SnakeOptimizerEmailKindText -Kind $step.Kind })
            $lines.Add("  [$($step.Kind)] $($step.Name): $detail$space$(if ($step.Duration) { " · $($step.Duration)" })")
        }
    }

    $lines.Add("")
    $lines.Add("E-mail automático do SnakeOptimizer $($Report.Version).")
    return ($lines -join "`r`n")
}


# ---------------------------------------------------------------------------
# Envio
# ---------------------------------------------------------------------------

function Get-SnakeOptimizerSmtpProblem {
    # O erro do servidor em português, para a tela e o log.
    param ($ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception.InnerException -and -not ($exception -is [SnakeOptimizer.SmtpFailure])) { $exception = $exception.InnerException }

    $message = ([string]$exception.Message).Trim()
    $code = $(if ($exception -is [SnakeOptimizer.SmtpFailure]) { [int]$exception.Code } else { 0 })

    switch ($code) {
        535 { return "usuário ou senha do SMTP recusados ($message)" }
        550 { return "o servidor recusou o remetente ou o destinatário ($message)" }
        553 { return "remetente não autorizado nesse servidor ($message)" }
        554 { return "o servidor recusou a mensagem ($message)" }
    }

    if ($message -match '(?i)tempo esgotado|timed out|tempo limite') { return "o servidor não respondeu a tempo; confira o endereço, a porta e se a internet ou o firewall liberam a saída" }
    if ($message -match '(?i)certificate|certificado|authentication failed because') { return "falha na conexão segura (SSL): confira a porta e o tipo de segurança" }
    return $message
}


function Send-SnakeOptimizerEmail {
    # Envia um relatório com a configuração dada (ou a deste PC). Devolve Sent e Problem; nunca lança erro.
    param (
        [Parameter(Mandatory)]$Report,
        $Config = $null
    )

    if ($null -eq $Config) { $Config = Get-SnakeOptimizerEmailConfig }

    try {
        if (-not (Initialize-SnakeOptimizerSmtp)) { throw "o envio de e-mail não pôde ser preparado neste PC" }

        $subject = Get-SnakeOptimizerEmailSubject -Report $Report
        $message = [SnakeOptimizer.SmtpMailer]::BuildMessage([string]$Config.From, [string]$Config.FromName, [string[]]@($Config.To), $subject, (ConvertTo-SnakeOptimizerEmailHtml -Report $Report), (ConvertTo-SnakeOptimizerEmailText -Report $Report), [string]$Report.Attachment)
        [SnakeOptimizer.SmtpMailer]::Send([string]$Config.Host, [int]$Config.Port, ([string]$Config.Security -eq "SSL"), [string]$Config.User, [string]$Config.Password, [string]$Config.From, [string[]]@($Config.To), $message, 20000)

        return [PSCustomObject]@{ Sent = $true; Problem = "" }
    }
    catch {
        return [PSCustomObject]@{ Sent = $false; Problem = (Get-SnakeOptimizerSmtpProblem -ErrorRecord $_) }
    }
}


function Send-SnakeOptimizerRunEmail {
    <#
    O ponto de envio que o Otimizar, a manutenção automática e as ações avulsas chamam no fim. Respeita o que está ligado
    (Optimize, Automatic, Standalone) e o "só quando houver problema". Sem configuração, não faz nada nem escreve nada.
    Nunca interrompe quem chamou.
    #>
    param ([Parameter(Mandatory)]$Report)

    try {
        $config = Get-SnakeOptimizerEmailConfig
        if (-not (Test-SnakeOptimizerEmailReady -Config $config)) { return }

        $wanted = switch ([string]$Report.Event) { "Optimize" { [bool]$config.Optimize } "Automatic" { [bool]$config.Automatic } "Standalone" { [bool]$config.Standalone } default { $false } }
        if (-not $wanted) { return }

        if ([bool]$config.OnlyProblems -and [string]$Report.Kind -eq "Ok" -and -not $Report.Reboot -and @($Report.Attention).Count -eq 0) { return }

        $sent = Send-SnakeOptimizerEmail -Report $Report -Config $config

        if ($sent.Sent) { Write-SnakeOptimizerStatus -Type Info -Message "Resumo enviado por e-mail para $(@($config.To) -join ', ')." }
        else { Write-SnakeOptimizerStatus -Type Warning -Notice -Message "O resumo não foi enviado por e-mail: $($sent.Problem)." }
    }
    catch {
        Write-Verbose "E-mail: $($_.Exception.Message)"
    }
}


function ConvertTo-SnakeOptimizerEmailSteps {
    # As etapas de SnakeOptimizer.Result (Etapa, Kind, Detail, Duracao, FreeBefore, FreeAfter) no formato do e-mail.
    param ([object[]]$Results = @())

    return @(
        foreach ($result in @($Results | Where-Object { $null -ne $_ })) {
            $before = Get-SnakeOptimizerJsonValue -Object $result -Name "FreeBefore"
            $after = Get-SnakeOptimizerJsonValue -Object $result -Name "FreeAfter"
            [PSCustomObject]@{
                Name       = [string](Get-SnakeOptimizerJsonValue -Object $result -Name "Etapa" -Default "")
                Kind       = [string](Get-SnakeOptimizerJsonValue -Object $result -Name "Kind" -Default "")
                Detail     = [string](Get-SnakeOptimizerJsonValue -Object $result -Name "Detail" -Default "")
                Duration   = [string](Get-SnakeOptimizerJsonValue -Object $result -Name "Duracao" -Default "")
                SpaceDelta = $(if ($null -ne $before -and $null -ne $after) { [int64]$after - [int64]$before } else { $null })
            }
        }
    )
}


function Get-SnakeOptimizerEmailAttention {
    # "Etapa: o que aconteceu" de cada etapa com ressalva ou falha (as falhas primeiro).
    param ([object[]]$Steps = @())

    $ordered = @($Steps | Where-Object { $_.Kind -eq "Failed" }) + @($Steps | Where-Object { $_.Kind -eq "Warning" })
    return @($ordered | ForEach-Object { if ($_.Detail) { "$($_.Name): $($_.Detail)" } else { "$($_.Name): $(Get-SnakeOptimizerEmailKindText -Kind $_.Kind)" } })
}


function Send-SnakeOptimizerOptimizeEmail {
    # O e-mail do fim do Otimizar (chamado por Invoke-SnakeOptimizerRecommendedMaintenance).
    param (
        [object[]]$Results = @(),
        [datetime]$StartedAt,
        $Before,
        $After,
        $Outcome
    )

    try {
        $steps = @(ConvertTo-SnakeOptimizerEmailSteps -Results $Results)
        $space = Get-SnakeOptimizerSystemDriveSpace
        $disk = $null
        if ($null -ne $Before -and $null -ne $After -and $null -ne $Before.FreeBytes -and $null -ne $After.FreeBytes) {
            $disk = [PSCustomObject]@{ FreeBefore = [int64]$Before.FreeBytes; FreeAfter = [int64]$After.FreeBytes; TotalBytes = $(if ($space) { $space.TotalBytes } else { 0 }) }
        }

        $reboot = [bool](Get-SnakeOptimizerResultData -Result $Outcome -Name "RebootRequired")
        $kind = $(if ($Outcome -and $Outcome.Kind) { [string]$Outcome.Kind } else { "Ok" })

        $report = New-SnakeOptimizerEmailReport -Title "Otimizar" -Event Optimize -Kind $kind -Outcome ([string]$Outcome.Detail) -StartedAt $StartedAt `
            -Duration (Format-SnakeOptimizerDuration -Span ((Get-Date) - $StartedAt)) -Disk $disk -Steps $steps -Attention (Get-SnakeOptimizerEmailAttention -Steps $steps) -Reboot $reboot
        Send-SnakeOptimizerRunEmail -Report $report
    }
    catch {
        Write-Verbose "E-mail do Otimizar: $($_.Exception.Message)"
    }
}


function Send-SnakeOptimizerStandaloneEmail {
    # O e-mail de uma limpeza (ou outra ação que mudou o espaço) rodada sozinha (chamado por Write-SnakeOptimizerActionSpace).
    param (
        [Parameter(Mandatory)][string]$Title,
        $Result,
        $Before,
        $After,
        $StartedAt
    )

    try {
        if ($null -eq $StartedAt) { $StartedAt = Get-Date }
        $kind = $(if ($Result -and $Result.Kind -and [string]$Result.Kind -ne "Skipped") { [string]$Result.Kind } else { "Ok" })
        $detail = $(if ($Result) { [string]$Result.Detail } else { "" })
        $outcome = $(if ($detail) { $detail.Substring(0, 1).ToUpperInvariant() + $detail.Substring(1) + "." } else { "" })
        $disk = [PSCustomObject]@{ FreeBefore = [int64]$Before.FreeBytes; FreeAfter = [int64]$After.FreeBytes; TotalBytes = [int64]$After.TotalBytes }
        $attention = $(if ($kind -ne "Ok" -and $detail) { @("$($Title): $detail") } else { @() })

        $report = New-SnakeOptimizerEmailReport -Title $Title -Event Standalone -Kind $kind -Outcome $outcome -StartedAt ([datetime]$StartedAt) `
            -Duration (Format-SnakeOptimizerDuration -Span ((Get-Date) - [datetime]$StartedAt)) -Disk $disk -Attention $attention `
            -Reboot ([bool](Get-SnakeOptimizerResultData -Result $Result -Name "RebootRequired"))
        Send-SnakeOptimizerRunEmail -Report $report
    }
    catch {
        Write-Verbose "E-mail da ação avulsa: $($_.Exception.Message)"
    }
}


# ---------------------------------------------------------------------------
# Exportar e importar (para configurar outros PCs)
# ---------------------------------------------------------------------------

function Export-SnakeOptimizerEmailConfig {
    # Cifra a configuração (com a senha do SMTP) com a senha técnica: AES-256-CBC e HMAC-SHA256 por cima.
    param (
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Path
    )

    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt); $rng.GetBytes($iv); $rng.Dispose()

    $keys = Get-SnakeOptimizerPasswordHash -Password $Password -Salt $salt -Length 64
    $plain = [Text.Encoding]::UTF8.GetBytes(($Config | Select-Object Host, Port, Security, User, Password, From, FromName, To, Optimize, Automatic, Standalone, OnlyProblems | ConvertTo-Json -Depth 4))

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $keys[0..31]; $aes.IV = $iv
    $cipher = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    $aes.Dispose()

    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (, [byte[]]$keys[32..63])
    $mac = $hmac.ComputeHash([byte[]]($iv + $cipher))
    $hmac.Dispose()

    $document = [ordered]@{ Format = "SnakeOptimizer.EmailConfig"; Version = 1; Salt = [Convert]::ToBase64String($salt); IV = [Convert]::ToBase64String($iv); Data = [Convert]::ToBase64String($cipher); Mac = [Convert]::ToBase64String($mac) }
    [IO.File]::WriteAllText($Path, ($document | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}


function Import-SnakeOptimizerEmailConfig {
    # Lê um .snakemail com a senha técnica. Devolve a configuração (com Enabled ligado) ou lança erro.
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Password
    )

    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$document.Format -ne "SnakeOptimizer.EmailConfig") { throw "o arquivo não é uma configuração de e-mail do SnakeOptimizer" }

    $salt = [Convert]::FromBase64String($document.Salt)
    $iv = [Convert]::FromBase64String($document.IV)
    $cipher = [Convert]::FromBase64String($document.Data)
    $keys = Get-SnakeOptimizerPasswordHash -Password $Password -Salt $salt -Length 64

    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (, [byte[]]$keys[32..63])
    $mac = $hmac.ComputeHash([byte[]]($iv + $cipher))
    $hmac.Dispose()
    if ([Convert]::ToBase64String($mac) -ne [string]$document.Mac) { throw "a senha técnica não confere com a do arquivo, ou o arquivo foi alterado" }

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $keys[0..31]; $aes.IV = $iv
    $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)
    $aes.Dispose()

    $data = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
    $config = Get-SnakeOptimizerEmailDefaults
    foreach ($name in @("Host", "Port", "Security", "User", "Password", "From", "FromName", "Optimize", "Automatic", "Standalone", "OnlyProblems")) {
        if ($null -ne $data.$name) { $config.$name = $data.$name }
    }
    $config.To = @(@($data.To) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $config.Enabled = $true
    return $config
}


# ---------------------------------------------------------------------------
# A área técnica
# ---------------------------------------------------------------------------

function Read-SnakeOptimizerTechnicianField {
    # Um campo da configuração: ENTER mantém o valor de agora.
    param (
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Current = ""
    )

    $shown = $(if ($Current) { " (ENTER = manter: $Current)" } else { "" })
    $answer = Read-SnakeOptimizerText -Message "$Label$shown"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Current }
    return $answer.Trim()
}


function Write-SnakeOptimizerEmailConfigSummary {
    param ([Parameter(Mandatory)]$Config)

    $onOff = { param ($v) if ($v) { "sim" } else { "não" } }
    Write-SnakeOptimizerSection -Title "E-mail deste PC"
    Write-SnakeOptimizerKeyValue -Label "Envio" -Value $(if (Test-SnakeOptimizerEmailReady -Config $Config) { "ligado" } elseif ($Config.Enabled) { "ligado, mas a configuração está incompleta" } else { "desligado" }) -LabelWidth 30
    Write-SnakeOptimizerKeyValue -Label "Servidor" -Value "$($Config.Host):$($Config.Port) ($(if ($Config.Security -eq 'SSL') { 'SSL' } else { 'STARTTLS' }))" -LabelWidth 30
    Write-SnakeOptimizerKeyValue -Label "Usuário SMTP" -Value $(if ($Config.User) { $Config.User } else { "(vazio)" }) -LabelWidth 30
    Write-SnakeOptimizerKeyValue -Label "Senha SMTP" -Value $(if ($Config.Password) { "guardada (cifrada neste PC)" } else { "(vazia)" }) -LabelWidth 30
    Write-SnakeOptimizerKeyValue -Label "Remetente" -Value $(if ($Config.From) { "$($Config.FromName) <$($Config.From)>" } else { "(vazio)" }) -LabelWidth 30
    Write-SnakeOptimizerKeyValue -Label "Destinatários" -Value $(if (@($Config.To).Count -gt 0) { @($Config.To) -join ", " } else { "(nenhum)" }) -LabelWidth 30
    Write-SnakeOptimizerKeyValue -Label "Enviar no fim do Otimizar" -Value (& $onOff $Config.Optimize) -LabelWidth 30
    Write-SnakeOptimizerKeyValue -Label "Enviar na manutenção automática" -Value (& $onOff $Config.Automatic) -LabelWidth 30
    Write-SnakeOptimizerKeyValue -Label "Enviar nas limpezas avulsas" -Value (& $onOff $Config.Standalone) -LabelWidth 30
    Write-SnakeOptimizerKeyValue -Label "Só quando houver problema" -Value (& $onOff $Config.OnlyProblems) -LabelWidth 30
}


function New-SnakeOptimizerSampleEmailReport {
    # Um relatório de exemplo, para o e-mail de teste e os modelos.
    param ([ValidateSet("Optimize", "Automatic", "Standalone")][string]$Event = "Optimize")

    $now = Get-Date

    switch ($Event) {
        "Optimize" {
            return (New-SnakeOptimizerEmailReport -Title "Otimizar" -Event Optimize -Kind Warning -Outcome "Concluído com 1 etapa pedindo atenção." -StartedAt $now.AddMinutes(-74) -Duration "1h 14min" `
                    -Disk ([PSCustomObject]@{ FreeBefore = [int64]38.4GB; FreeAfter = [int64]46.9GB; TotalBytes = [int64]476GB }) `
                    -Attention @("Atualizar programas (winget): beszel-agent foi instalado só para o usuário; atualize sem Administrador.") `
                    -Steps @(
                        [PSCustomObject]@{ Name = "Criar ponto de restauração"; Kind = "Ok"; Detail = "ponto criado"; Duration = "18 s"; SpaceDelta = $null },
                        [PSCustomObject]@{ Name = "Verificar vírus"; Kind = "Ok"; Detail = "nenhuma ameaça encontrada"; Duration = "4 min"; SpaceDelta = $null },
                        [PSCustomObject]@{ Name = "Reparar o Windows (DISM + SFC)"; Kind = "Ok"; Detail = "nenhuma violação de integridade"; Duration = "21 min"; SpaceDelta = [int64]-12MB },
                        [PSCustomObject]@{ Name = "Limpar componentes do Windows (WinSxS)"; Kind = "Ok"; Detail = "componentes antigos removidos"; Duration = "9 min"; SpaceDelta = [int64]2.1GB },
                        [PSCustomObject]@{ Name = "Atualizar o Windows"; Kind = "Ok"; Detail = "2 atualizações instaladas"; Duration = "12 min"; SpaceDelta = [int64]-640MB },
                        [PSCustomObject]@{ Name = "Atualizar programas (winget)"; Kind = "Warning"; Detail = "25 de 26 atualizados"; Duration = "17 min"; SpaceDelta = [int64]-310MB },
                        [PSCustomObject]@{ Name = "Limpeza rápida"; Kind = "Ok"; Detail = "liberou 6,9 GB"; Duration = "2 min"; SpaceDelta = [int64]6.9GB },
                        [PSCustomObject]@{ Name = "Reparar rede e DNS"; Kind = "Ok"; Detail = "conexão funcionando"; Duration = "40 s"; SpaceDelta = $null },
                        [PSCustomObject]@{ Name = "Verificar o sistema de arquivos (CHKDSK)"; Kind = "Ok"; Detail = "nenhum problema"; Duration = "3 min"; SpaceDelta = $null }
                    ) -Computer "PC-RECEPCAO-01" -UserName "recepcao")
        }
        "Automatic" {
            return (New-SnakeOptimizerEmailReport -Title "Manutenção automática (completa)" -Event Automatic -Kind Ok -Outcome "Todas as tarefas terminaram bem." -StartedAt $now.AddMinutes(-38) -Duration "38 min" `
                    -Disk ([PSCustomObject]@{ FreeBefore = [int64]61.2GB; FreeAfter = [int64]64.8GB; TotalBytes = [int64]238GB }) -Reboot $true `
                    -Steps @(
                        [PSCustomObject]@{ Name = "ponto-restauracao"; Kind = "Ok"; Detail = "ponto criado"; Duration = "00:21"; SpaceDelta = $null },
                        [PSCustomObject]@{ Name = "limpeza-rapida"; Kind = "Ok"; Detail = "liberou 2,4 GB"; Duration = "01:52"; SpaceDelta = [int64]2.4GB },
                        [PSCustomObject]@{ Name = "limpeza-avancada"; Kind = "Ok"; Detail = "liberou 1,3 GB"; Duration = "02:10"; SpaceDelta = [int64]1.3GB },
                        [PSCustomObject]@{ Name = "dism-sfc"; Kind = "Ok"; Detail = "imagem íntegra"; Duration = "19:40"; SpaceDelta = $null },
                        [PSCustomObject]@{ Name = "atualizacoes"; Kind = "Ok"; Detail = "1 atualização instalada; pede reinício"; Duration = "11:02"; SpaceDelta = [int64]-100MB },
                        [PSCustomObject]@{ Name = "verificar"; Kind = "Ok"; Detail = "relatório salvo"; Duration = "01:15"; SpaceDelta = $null }
                    ) -Computer "NOTE-FINANCEIRO" -UserName "SYSTEM")
        }
        default {
            return (New-SnakeOptimizerEmailReport -Title "Limpeza avançada" -Event Standalone -Kind Ok -Outcome "Liberou 3,2 GB." -StartedAt $now.AddMinutes(-3) -Duration "3 min" `
                    -Disk ([PSCustomObject]@{ FreeBefore = [int64]22.6GB; FreeAfter = [int64]25.8GB; TotalBytes = [int64]238GB }) -Computer "PC-ESTOQUE" -UserName "estoque")
        }
    }
}


function Invoke-SnakeOptimizerTechnicianArea {
    <#
    A área técnica: pede Administrador e a senha técnica (o hash em config\tecnico.json), e então configura o e-mail com
    o resumo: servidor, remetente, destinatários, quando enviar, teste, exportar e importar.
    #>
    $title = "Área técnica"
    Enter-SnakeOptimizerAction -Title $title
    $result = $null

    try {
        if (-not (Test-SnakeOptimizerElevation -Reason "A área técnica exige privilégios de Administrador.")) {
            $result = New-SnakeOptimizerResult -Kind Failed -Detail "requer Administrador"
        }
        elseif (-not (Test-SnakeOptimizerTechnicianConfigured)) {
            Write-SnakeOptimizerStatus -Type Warning -Message "A senha técnica ainda não foi definida nesta versão do SnakeOptimizer."
            Write-SnakeOptimizerStatus -Type Info -Message "No PC do técnico, na pasta do projeto, rode tools\definir-senha-tecnica.ps1 e publique o config\tecnico.json gerado."
            $result = New-SnakeOptimizerResult -Kind Skipped -Detail "senha técnica não definida"
        }

        $password = ""

        if ($null -eq $result) {
            $ok = $false

            for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
                $password = ConvertFrom-SnakeOptimizerSecureText -Secure (Read-Host -Prompt "Senha técnica" -AsSecureString)
                if (-not $password) { break }
                $ok = Test-SnakeOptimizerTechnicianPassword -Password $password

                if (-not $ok) {
                    # Uma espera a cada erro deixa tentar senhas uma atrás da outra lento demais.
                    Start-Sleep -Seconds (2 * $attempt)
                    Write-SnakeOptimizerStatus -Type Warning -Message "Senha incorreta."
                }
            }

            if (-not $ok) {
                $password = ""
                $result = New-SnakeOptimizerResult -Kind Skipped -Detail "acesso não liberado"
            }
        }

        while ($null -eq $result) {
            $config = Get-SnakeOptimizerEmailConfig
            Write-SnakeOptimizerEmailConfigSummary -Config $config
            Write-Host ""

            $options = @(
                @{ Key = "1"; Label = "Configurar o servidor SMTP"; Description = "Servidor, porta, segurança, usuário e senha"; Accent = (-not $config.User) },
                @{ Key = "2"; Label = "Remetente e destinatários"; Description = "Quem envia e quem recebe (separe vários por vírgula)" },
                @{ Key = "3"; Label = "Quando enviar"; Description = "Otimizar, manutenção automática, limpezas avulsas, só com problema" },
                @{ Key = "4"; Label = "Enviar um e-mail de teste"; Description = "Um exemplo do resumo do Otimizar, com a configuração de agora" },
                @{ Key = "5"; Label = $(if ($config.Enabled) { "Desligar o envio" } else { "Ligar o envio" }); Description = "A configuração fica guardada" },
                @{ Key = "6"; Label = "Exportar a configuração"; Description = "Arquivo .snakemail protegido pela senha técnica, para outros PCs" },
                @{ Key = "7"; Label = "Importar a configuração"; Description = "De um .snakemail exportado em outro PC" },
                @{ Key = "8"; Label = "Apagar a configuração deste PC"; Description = "Tira o servidor, a senha e os destinatários" },
                @{ Key = "X"; Label = "Sair"; Exit = $true }
            )

            $answer = Read-SnakeOptimizerChoice -Message "O que fazer?" -Options $options -DefaultKey "X" -ShowMenu -TextPrompt "Opção (número, X = sair)"
            if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "X") { $result = New-SnakeOptimizerResult -Kind Ok -Detail "configuração revisada"; break }

            try {
                switch ($answer) {
                    "1" {
                        $config.Host = Read-SnakeOptimizerTechnicianField -Label "Servidor SMTP" -Current $config.Host
                        $port = Read-SnakeOptimizerTechnicianField -Label "Porta (465 = SSL; 587 ou 2525 = STARTTLS)" -Current ([string]$config.Port)
                        if ($port -match '^\d+$') { $config.Port = [int]$port }
                        $config.Security = $(if ([int]$config.Port -eq 465) { "SSL" } else { "STARTTLS" })
                        $config.User = Read-SnakeOptimizerTechnicianField -Label "Usuário SMTP" -Current $config.User
                        $secret = ConvertFrom-SnakeOptimizerSecureText -Secure (Read-Host -Prompt "Senha SMTP (vazio = manter a atual)" -AsSecureString)
                        if ($secret) { $config.Password = $secret }
                        $config.Enabled = $true
                        Save-SnakeOptimizerEmailConfig -Config $config
                        Write-SnakeOptimizerStatus -Type Success -Message "Servidor salvo. Use Enviar um e-mail de teste para conferir."
                    }
                    "2" {
                        $config.From = Read-SnakeOptimizerTechnicianField -Label "E-mail do remetente" -Current $config.From
                        $config.FromName = Read-SnakeOptimizerTechnicianField -Label "Nome do remetente" -Current $config.FromName
                        $to = Read-SnakeOptimizerTechnicianField -Label "Destinatários (separados por vírgula)" -Current (@($config.To) -join ", ")
                        $config.To = @($to -split '[,;\s]+' | Where-Object { $_ -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
                        Save-SnakeOptimizerEmailConfig -Config $config
                        Write-SnakeOptimizerStatus -Type Success -Message "Remetente e destinatários salvos."
                    }
                    "3" {
                        $picked = Read-SnakeOptimizerMultiSelect -Message "Quando enviar o resumo" -AllowNone -ConfirmLabel "Salvar" -Options @(
                                @{ Key = "Optimize"; Label = "No fim do Otimizar"; Description = "Um e-mail por execução, com as etapas e o espaço"; Selected = [bool]$config.Optimize },
                                @{ Key = "Automatic"; Label = "Na manutenção automática"; Description = "A leve e a completa, e as tarefas do RMM"; Selected = [bool]$config.Automatic },
                                @{ Key = "Standalone"; Label = "Nas limpezas avulsas"; Description = "Limpeza rápida, personalizada, avançada, perfis, WinSxS..."; Selected = [bool]$config.Standalone },
                                @{ Key = "OnlyProblems"; Label = "Só quando houver problema"; Description = "Falha, ponto de atenção ou reinício pendente"; Selected = [bool]$config.OnlyProblems }
                            )
                        if ($null -ne $picked) {
                            foreach ($name in @("Optimize", "Automatic", "Standalone", "OnlyProblems")) { $config.$name = (@($picked) -contains $name) }
                            Save-SnakeOptimizerEmailConfig -Config $config
                            Write-SnakeOptimizerStatus -Type Success -Message "Preferências de envio salvas."
                        }
                    }
                    "4" {
                        if (-not ($config.Host -and $config.User -and $config.Password -and $config.From -and @($config.To).Count -gt 0)) {
                            Write-SnakeOptimizerStatus -Type Warning -Message "Falta configurar o servidor, o remetente ou os destinatários."
                        }
                        else {
                            Write-Progress -Activity "E-mail de teste" -Status "enviando para $(@($config.To) -join ', ')"
                            $sample = New-SnakeOptimizerSampleEmailReport -Event Optimize
                            $sample.Title = "Teste · Otimizar"
                            $sent = Send-SnakeOptimizerEmail -Report $sample -Config $config
                            Write-Progress -Activity "E-mail de teste" -Completed
                            if ($sent.Sent) { Write-SnakeOptimizerStatus -Type Success -Message "E-mail de teste enviado para $(@($config.To) -join ', '). Confira a caixa de entrada (e o spam)." }
                            else { Write-SnakeOptimizerStatus -Type Error -Message "Não foi possível enviar: $($sent.Problem)." }
                        }
                    }
                    "5" {
                        $config.Enabled = -not [bool]$config.Enabled
                        Save-SnakeOptimizerEmailConfig -Config $config
                        Write-SnakeOptimizerStatus -Type Success -Message $(if ($config.Enabled) { "Envio ligado." } else { "Envio desligado; a configuração continua guardada." })
                    }
                    "6" {
                        $folder = [Environment]::GetFolderPath("Desktop")
                        $path = Join-Path $folder "SnakeOptimizer-email.snakemail"
                        Export-SnakeOptimizerEmailConfig -Config $config -Password $password -Path $path
                        Write-SnakeOptimizerStatus -Type Success -Message "Configuração exportada em $path. Ela só abre com a senha técnica; mesmo assim, não deixe o arquivo no PC do cliente."
                    }
                    "7" {
                        $path = (Read-SnakeOptimizerText -Message "Caminho do arquivo .snakemail (vazio = cancelar)").Trim('"')
                        if ($path) {
                            $imported = Import-SnakeOptimizerEmailConfig -Path $path -Password $password
                            Save-SnakeOptimizerEmailConfig -Config $imported
                            Write-SnakeOptimizerStatus -Type Success -Message "Configuração importada e envio ligado. Use Enviar um e-mail de teste para conferir."
                        }
                    }
                    "8" {
                        if (Confirm-SnakeOptimizerAction "Apagar a configuração de e-mail deste PC?" -DefaultKey N) {
                            $path = Get-SnakeOptimizerEmailConfigPath
                            foreach ($file in @($path, "$path.bak")) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
                            Write-SnakeOptimizerStatus -Type Success -Message "Configuração de e-mail apagada."
                        }
                    }
                }
            }
            catch {
                Write-SnakeOptimizerStatus -Type Error -Message "$($_.Exception.Message)"
            }

            Write-Host ""
        }
    }
    catch {
        Write-SnakeOptimizerStatus -Type Error -Message "Erro na área técnica: $($_.Exception.Message)"
        $result = New-SnakeOptimizerResult -Kind Failed -Detail $_.Exception.Message
    }
    finally {
        $password = $null
    }

    $result.Etapa = $title
    Exit-SnakeOptimizerAction -Result $result
}


Export-ModuleMember -Function *
