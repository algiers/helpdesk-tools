#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [string]$AuthKey
)

# ===== TLS + ExecutionPolicy =====
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# ===== Refresh PATH =====
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH","User")

# ===== PowerShell update =====
if (Get-Command winget -ea 0) {
    winget install Microsoft.PowerShell -e --source winget `
        --accept-package-agreements --accept-source-agreements | Out-Null
}

# ===== OpenSSH install =====
$cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
if ($cap.State -ne 'Installed') {
    Write-Host "  Installing OpenSSH..." -ForegroundColor Gray
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
}

# Attendre que le service sshd apparaisse (max 60s)
$elapsed = 0
while (!(Get-Service sshd -ea 0) -and $elapsed -lt 60) {
    Start-Sleep -Seconds 2; $elapsed += 2
}
if (!(Get-Service sshd -ea 0)) {
    Write-Host "❌ OpenSSH install failed." -ForegroundColor Red
    Read-Host "`nAppuie sur Entrée pour fermer"
    exit 1
}

# ===== Trouver ssh-keygen dynamiquement =====
$sshKeygen = $null
$kCmd = Get-Command ssh-keygen -ea 0
if ($kCmd) { $sshKeygen = $kCmd.Source }
if (!$sshKeygen) {
    foreach ($p in @(
        "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe",
        "$env:ProgramFiles\OpenSSH\ssh-keygen.exe",
        "$env:ProgramFiles\OpenSSH-Win64\ssh-keygen.exe",
        "C:\Program Files\OpenSSH\OpenSSH-Win64\ssh-keygen.exe"
    )) { if (Test-Path $p) { $sshKeygen = $p; break } }
}
Write-Host "  ssh-keygen : $sshKeygen" -ForegroundColor Gray

# ===== Générer les host keys =====
$sshdDataDir = "C:\ProgramData\ssh"
if (!(Test-Path $sshdDataDir)) { New-Item -ItemType Directory -Force -Path $sshdDataDir | Out-Null }

if ($sshKeygen) {
    Push-Location $sshdDataDir
    & $sshKeygen -A 2>$null
    Pop-Location
}

# Fixer les permissions des host keys
Get-ChildItem "$sshdDataDir\ssh_host_*_key" -ea 0 | ForEach-Object {
    icacls $_.FullName /inheritance:r                    | Out-Null
    icacls $_.FullName /grant "NT AUTHORITY\SYSTEM:F"    | Out-Null
    icacls $_.FullName /grant "BUILTIN\Administrators:F" | Out-Null
    icacls $_.FullName /grant "NT SERVICE\sshd:R"        | Out-Null
}

# ===== Démarrer sshd — attendre START_PENDING =====
sc.exe start sshd 2>$null

# Attendre jusqu'à Running (max 30s)
$elapsed = 0
while ((Get-Service sshd).Status -ne 'Running' -and $elapsed -lt 30) {
    Start-Sleep -Seconds 2; $elapsed += 2
}

if ((Get-Service sshd).Status -ne 'Running') {
    Write-Host "❌ sshd ne démarre pas. Statut : $((Get-Service sshd).Status)" -ForegroundColor Red
    Write-Host "   Vérifie l'Observateur d'événements > Journaux Windows > Système" -ForegroundColor Yellow
    Read-Host "`nAppuie sur Entrée pour fermer"
    exit 1
}

Write-Host "  ✅ sshd Running" -ForegroundColor Green
Set-Service sshd -StartupType Automatic

# Firewall
if (!(Get-NetFirewallRule -Name sshd -ea 0)) {
    New-NetFirewallRule -Name sshd -DisplayName sshd `
        -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# ===== SSH Key setup =====
$sshDir = "$env:USERPROFILE\.ssh"
$key    = "$sshDir\id_rsa"
$pub    = "$key.pub"
$auth   = "$sshDir\authorized_keys"

# Reprendre ownership via cmd.exe
if (Test-Path $sshDir) {
    cmd.exe /c "takeown /f `"$sshDir`" /r /d y" 2>$null
    cmd.exe /c "icacls `"$sshDir`" /grant Administrators:F /t" 2>$null
    cmd.exe /c "icacls `"$sshDir`" /grant `"$env:USERNAME`:F`" /t" 2>$null
}

New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

# Générer la clé
if (!(Test-Path $key)) {
    if ($sshKeygen) { & $sshKeygen -t rsa -b 4096 -N '""' -f $key | Out-Null }
    else            { ssh-keygen -t rsa -b 4096 -N '""' -f $key | Out-Null }
}

# Écrire authorized_keys — idempotent
$pubContent = (Get-Content $pub -Raw).Trim()
if (!(Test-Path $auth)) { New-Item -ItemType File -Force -Path $auth | Out-Null }
$existing = Get-Content $auth -Raw -ea 0
if (!$existing -or $existing -notmatch [regex]::Escape($pubContent)) {
    $pubContent | Add-Content $auth
}

# Fixer les permissions APRÈS écriture
icacls $sshDir /inheritance:r                     | Out-Null
icacls $sshDir /grant "$env:USERNAME`:(OI)(CI)F" | Out-Null
icacls $auth /inheritance:r                       | Out-Null
icacls $auth /grant "$env:USERNAME`:F"            | Out-Null

# ===== sshd_config =====
$config = "$sshdDataDir\sshd_config"
if (!(Test-Path $config)) {
@"
Port 22
PubkeyAuthentication yes
PasswordAuthentication no
"@ | Set-Content $config
}

$c = Get-Content $config
$c = $c -replace '^\s*#?\s*PubkeyAuthentication\s+\w+',  'PubkeyAuthentication yes'
$c = $c -replace '^\s*#?\s*PasswordAuthentication\s+\w+', 'PasswordAuthentication no'
$c = $c -replace '^(Match Group administrators)',          '#$1'
$c = $c -replace '^\s*(AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)', '#       $1'
$c | Set-Content $config

Restart-Service sshd

# ===== Network info =====
$hostname = $env:COMPUTERNAME
$localIP  = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } |
    Select-Object -First 1 -ExpandProperty IPAddress)

try   { $publicIP = (Invoke-RestMethod "https://api.ipify.org") }
catch {
    try   { $publicIP = (Invoke-RestMethod "https://ifconfig.me/ip") }
    catch { $publicIP = "N/A" }
}

# ===== Tailscale =====
if (Get-Command winget -ea 0) {
    winget install tailscale --accept-package-agreements --accept-source-agreements | Out-Null
}

& tailscale up --authkey=$AuthKey --accept-routes 2>$null
Start-Sleep -Seconds 5

try   { $tailscaleIP = (tailscale ip -4 | Select-Object -First 1) }
catch { $tailscaleIP = "N/A" }

# ===== Output =====
$user      = $env:USERNAME
$cmdLocal  = "ssh $user@$localIP"
$cmdPublic = "ssh $user@$publicIP"
$cmdTail   = "ssh $user@$tailscaleIP"

Write-Host "`n✅ READY TO CONNECT:" -ForegroundColor Green
Write-Host "   🖥️  Hostname : $hostname" -ForegroundColor White
Write-Host "`n📡 LOCAL:" -ForegroundColor Cyan
Write-Host "   $cmdLocal" -ForegroundColor Yellow
Write-Host "`n🌍 PUBLIC (port forwarding required):" -ForegroundColor Cyan
Write-Host "   $cmdPublic" -ForegroundColor Yellow
Write-Host "`n🔒 TAILSCALE (recommended):" -ForegroundColor Cyan
Write-Host "   $cmdTail" -ForegroundColor Yellow

Set-Clipboard $cmdTail
Write-Host "`n📋 Tailscale SSH command copied to clipboard!`n" -ForegroundColor Green

Read-Host "Appuie sur Entrée pour fermer"
