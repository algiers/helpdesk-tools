#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [string]$AuthKey
)

# ===== PowerShell update =====
if (Get-Command winget -ea 0) {
    winget install Microsoft.PowerShell -e --source winget `
        --accept-package-agreements --accept-source-agreements | Out-Null
}

# ===== OpenSSH =====
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
Start-Service sshd
Set-Service sshd -StartupType Automatic

if (!(Get-NetFirewallRule -Name sshd -ea 0)) {
    New-NetFirewallRule -Name sshd -DisplayName sshd `
        -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# ===== SSH Key setup =====
$sshDir = "$env:USERPROFILE\.ssh"
$key    = "$sshDir\id_rsa"
$pub    = "$key.pub"
$auth   = "$sshDir\authorized_keys"

if (!(Test-Path $key)) {
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    ssh-keygen -t rsa -b 4096 -N '""' -f $key | Out-Null
}

# Authorize own key — idempotent
$pubContent = (Get-Content $pub -Raw).Trim()
$alreadyIn  = (Test-Path $auth) -and ((Get-Content $auth -Raw) -match [regex]::Escape($pubContent))
if (!$alreadyIn) { $pubContent | Add-Content $auth }

# Fix permissions
icacls $sshDir /inheritance:r                     | Out-Null
icacls $sshDir /grant "$env:USERNAME`:(OI)(CI)F" | Out-Null
icacls $auth /inheritance:r                       | Out-Null
icacls $auth /grant "$env:USERNAME`:F"            | Out-Null

# ===== sshd_config =====
$config = "C:\ProgramData\ssh\sshd_config"
if (Test-Path $config) {
    $c = Get-Content $config
    $c = $c -replace '^\s*#?\s*PubkeyAuthentication\s+\w+',  'PubkeyAuthentication yes'
    $c = $c -replace '^\s*#?\s*PasswordAuthentication\s+\w+', 'PasswordAuthentication no'
    $c = $c -replace '^(Match Group administrators)',          '#$1'
    $c = $c -replace '^\s*(AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)', '#       $1'
    $c | Set-Content $config
}
Restart-Service sshd

# ===== Network info =====
$hostname = $env:COMPUTERNAME
$localIP  = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } |
    Select-Object -First 1 -ExpandProperty IPAddress)

try   { $publicIP = (Invoke-RestMethod "https://api.ipify.org") }
catch { $publicIP = "N/A" }

# ===== Tailscale — auth automatique via paramètre =====
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
