<#
.SYNOPSIS
    Define (ou troca) a senha da Área técnica do SnakeOptimizer.

.DESCRIPTION
    Pede a senha duas vezes e grava em config\tecnico.json só o hash dela (PBKDF2-SHA256, 200 mil rodadas, sal
    aleatório). A senha em si não é gravada em lugar nenhum; o hash pode ir para o GitHub sem expor a senha.

    Depois de rodar: faça commit e push do config\tecnico.json. Os PCs recebem o arquivo na próxima atualização.

.EXAMPLE
    .\tools\definir-senha-tecnica.ps1
#>

$ErrorActionPreference = "Stop"

function ConvertFrom-Secure ($secure) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

$first = ConvertFrom-Secure (Read-Host -Prompt "Nova senha técnica (mínimo 10 caracteres)" -AsSecureString)
if ($first.Length -lt 10) { Write-Host "Senha curta demais; nada foi gravado." -ForegroundColor Yellow; exit 1 }

$second = ConvertFrom-Secure (Read-Host -Prompt "Repita a senha" -AsSecureString)
if ($first -cne $second) { Write-Host "As senhas não conferem; nada foi gravado." -ForegroundColor Yellow; exit 1 }

$salt = New-Object byte[] 16
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($salt)
$rng.Dispose()

$iterations = 200000
$derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes ([Text.Encoding]::UTF8.GetBytes($first)), $salt, $iterations, ([System.Security.Cryptography.HashAlgorithmName]::SHA256)
$hash = $derive.GetBytes(32)
$derive.Dispose()
$first = $null; $second = $null

$folder = Join-Path (Split-Path -Parent $PSScriptRoot) "config"
if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory) }
$path = Join-Path $folder "tecnico.json"

$document = [ordered]@{
    Algorithm  = "PBKDF2-SHA256"
    Iterations = $iterations
    Salt       = [Convert]::ToBase64String($salt)
    Hash       = [Convert]::ToBase64String($hash)
    CreatedAt  = (Get-Date).ToString("yyyy-MM-dd")
}

[IO.File]::WriteAllText($path, ($document | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
Write-Host "Senha técnica definida: $path" -ForegroundColor Green
Write-Host "Agora faça commit e push desse arquivo (git add config\tecnico.json)." -ForegroundColor Green
