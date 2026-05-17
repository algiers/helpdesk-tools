#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [string]$AuthKey
)

# ===== TLS + ExecutionPolicy =====
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# ===== Clé publique Youcef =====
$HELPDESK_PUBKEY = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCuPtRsXaE2sliLNNvpGoDmJztf+s8G8iXaiOT5YvuNxQysbKw8vCW/oBrjBn/p/Ty1eht6sGwhuCMM2vwBtuW+0xX6EdzKvcXAznaxhw2y1kZE6C4408zeXo/BVkCNJjrRsprUtq+8BvSai1f6ucfBZHYDArtinmeS+Cp6MaY34ZleGjrFbPezMhG9hlGcRsYwd7iNAjHK1BdO6hg4qyv8XvJkJuxnTjHq8ZbJpC+Kw9kAfrWFE4kDP2cFQ6g2n9cX1Z0yX7gkwkQThVAcTSjMYqvQDHYHC01Y3fLPHsyX3OXvuvxl03yQ6WgryVZDVfZYWpwiC/gZgTWuCWBa8h7eJxwSi9+a6rVfSqu1BagZ2bAmwB3DNU0sNMiATBhHLQLudt7Z5i7G0CS8f26DD7uvGcQo2awBTP5KTicOw/ddiAWQT++pCu3hNWppRlau0WAEV05QwrM29LAu0WnvKx6jaSPOEu0ppNuKRBJmaH0sISQrxUgafiT9UTFve9i3jmhHtot/tkO/DUQTJSVxZbpGRcrsq1fLuM+Qq4UxNyOXKrjPfCC9X5YLsHRaiBgI2uWGpFbURE1abYsHnQd18PrCyxctYXXW7AiHukniFgZQVQkpAnOKptI4GGtmT2LgwtHN/5Jni/fmcaVp0nTwZpFvVXYKoLCjf1GMuOUBsvUU7w== youcef@Latitude7310"

# ===== Refresh PATH =====
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH","User")

function Log($msg, $color="Gray") { Write-Host "  $msg" -ForegroundColor $color }
function Die($msg) {
    Write-Host "`n❌ $msg" -ForegroundColor Red
    Read-Host "Appuie sur Entrée pour fermer"
    exit 1
}

# ===== PowerShell update =====
if (Get-Command winget -ea 0) {
    winget install Microsoft.PowerShell -e --source winget `
        --accept-package-agreements --accept-source-agreements | Out-Null
}

# ===== OpenSSH install =====
$cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
if ($cap.State -ne 'Installed') {
    Log "Installing OpenSSH..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
}

# Trouver sshd.exe
$sshdBin = $null
$elapsed = 0
while (!$sshdBin -and $elapsed -lt 60) {
    foreach ($p in @(
        "$env:SystemRoot\System32\OpenSSH\sshd.exe",
        "C:\Program Files\OpenSSH\OpenSSH-Win64\sshd.exe",
        "$env:ProgramFiles\OpenSSH\sshd.exe"
    )) { if (Test-Path $p) { $sshdBin = $p; break } }
    if (!$sshdBin) { Start-Sleep -Seconds 2; $elapsed += 2 }
}
if (!$sshdBin) { Die "sshd.exe introuvable après 60s." }
Log "sshd binary : $sshdBin"

# Trouver ssh-keygen
$sshKeygen = $null
$k = Get-Command ssh-keygen -ea 0
if ($k) { $sshKeygen = $k.Source }
if (!$sshKeygen) {
    foreach ($p in @(
        "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe",
        "C:\Program Files\OpenSSH\OpenSSH-Win64\ssh-keygen.exe",
        "$env:ProgramFiles\OpenSSH\ssh-keygen.exe"
    )) { if (Test-Path $p) { $sshKeygen = $p; break } }
}
if (!$sshKeygen) { Die "ssh-keygen introuvable." }
Log "ssh-keygen  : $sshKeygen"

# ===== Host keys =====
$sshdDataDir = "C:\ProgramData\ssh"
if (!(Test-Path $sshdDataDir)) { New-Item -ItemType Directory -Force -Path $sshdDataDir | Out-Null }
Push-Location $sshdDataDir
& $sshKeygen -A 2>$null
Pop-Location

Get-ChildItem "$sshdDataDir\ssh_host_*_key" -ea 0 | ForEach-Object {
    cmd.exe /c "icacls `"$($_.FullName)`" /inheritance:r /grant `"NT AUTHORITY\SYSTEM:F`" /grant `"BUILTIN\Administrators:F`"" | Out-Null
}
Log "Host keys OK"

# ===== Port libre =====
$usedPorts = netstat -an | Select-String 'LISTENING' | ForEach-Object {
    if ($_ -match ':(\d+)\s') { [int]$matches[1] }
}
$sshPort = 22
if ($usedPorts -contains 22) {
    $sshPort = 2222
    while ($usedPorts -contains $sshPort) { $sshPort++ }
    Log "Port 22 occupé — port $sshPort sélectionné" "Yellow"
} else { Log "Port 22 libre" }

# ===== sshd_config =====
$config = "$sshdDataDir\sshd_config"
@"
Port $sshPort
PubkeyAuthentication yes
PasswordAuthentication no
"@ | Set-Content $config
Log "sshd_config écrit (port $sshPort)"

# ===== Firewall =====
$ruleName = "sshd-port-$sshPort"
if (!(Get-NetFirewallRule -Name $ruleName -ea 0)) {
    New-NetFirewallRule -Name $ruleName -DisplayName $ruleName `
        -Direction Inbound -Protocol TCP -Action Allow -LocalPort $sshPort | Out-Null
}
Log "Firewall OK"

# ===== NSSM — téléchargement =====
$nssmDir = "$sshdDataDir\nssm"
$nssmExe = "$nssmDir\nssm.exe"

if (!(Test-Path $nssmExe)) {
    Log "Téléchargement NSSM..."
    try {
        Invoke-WebRequest "https://nssm.cc/release/nssm-2.24.zip" `
            -OutFile "$env:TEMP\nssm.zip" -UseBasicParsing
        Expand-Archive "$env:TEMP\nssm.zip" -DestinationPath "$env:TEMP\nssm-extract" -Force
        New-Item -ItemType Directory -Force -Path $nssmDir | Out-Null
        Copy-Item "$env:TEMP\nssm-extract\nssm-2.24\win64\nssm.exe" $nssmExe -Force
        Log "NSSM téléchargé ✅"
    } catch {
        Die "Impossible de télécharger NSSM : $_"
    }
} else {
    Log "NSSM déjà présent ✅"
}

# ===== NSSM — installer sshd comme vrai service Windows =====
$svcName = "OpenSSH-sshd"

# Supprimer l'ancien service si présent
if (Get-Service $svcName -ea 0) {
    & $nssmExe stop $svcName 2>$null
    & $nssmExe remove $svcName confirm 2>$null
    Start-Sleep -Seconds 2
}
Stop-Process -Name sshd -Force -ea 0

# Créer le service avec NSSM
& $nssmExe install $svcName $sshdBin "-D -p $sshPort -f `"$config`"" | Out-Null
& $nssmExe set $svcName AppNoConsole 1              | Out-Null
& $nssmExe set $svcName DisplayName "OpenSSH Server" | Out-Null
& $nssmExe set $svcName Start SERVICE_AUTO_START     | Out-Null
& $nssmExe set $svcName AppRestartDelay 3000         | Out-Null
& $nssmExe start $svcName                            | Out-Null

# Attendre que le port écoute (max 30s)
$elapsed = 0; $portOk = $false
while ($elapsed -lt 30) {
    Start-Sleep -Seconds 2; $elapsed += 2
    if (netstat -an | findstr ":$sshPort") { $portOk = $true; break }
}
if (!$portOk) { Die "sshd ne répond pas sur le port $sshPort." }
Log "sshd en écoute sur port $sshPort ✅" "Green"

# ===== authorized_keys =====
$sshDir = "$env:USERPROFILE\.ssh"
$auth   = "$sshDir\authorized_keys"

if (Test-Path $sshDir) {
    cmd.exe /c "takeown /f `"$sshDir`" /r /d y 2>nul" | Out-Null
    cmd.exe /c "icacls `"$sshDir`" /grant Administrators:F /t 2>nul" | Out-Null
    cmd.exe /c "icacls `"$sshDir`" /grant `"$env:USERNAME`:F`" /t 2>nul" | Out-Null
}
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
if (!(Test-Path $auth)) { New-Item -ItemType File -Force -Path $auth | Out-Null }

$existing = Get-Content $auth -Raw -ea 0
if (!$existing -or $existing -notmatch [regex]::Escape($HELPDESK_PUBKEY)) {
    $HELPDESK_PUBKEY | Add-Content $auth
    Log "Clé helpdesk ajoutée ✅"
} else { Log "Clé helpdesk déjà présente ✅" }

icacls $sshDir /inheritance:r                     | Out-Null
icacls $sshDir /grant "$env:USERNAME`:(OI)(CI)F" | Out-Null
icacls $auth /inheritance:r                       | Out-Null
icacls $auth /grant "$env:USERNAME`:F"            | Out-Null
Log "Permissions SSH OK"

# ===== Network =====
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
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
}
& tailscale up --authkey=$AuthKey --accept-routes 2>$null
Start-Sleep -Seconds 5
try   { $tailscaleIP = (tailscale ip -4 | Select-Object -First 1) }
catch { $tailscaleIP = "N/A" }

# ===== Output =====
$portSuffix = if ($sshPort -ne 22) { " -p $sshPort" } else { "" }
$user       = $env:USERNAME
$cmdLocal   = "ssh $user@$localIP$portSuffix"
$cmdPublic  = "ssh $user@$publicIP$portSuffix"
$cmdTail    = "ssh $user@$tailscaleIP$portSuffix"

Write-Host "`n✅ READY TO CONNECT:" -ForegroundColor Green
Write-Host "   🖥️  Hostname : $hostname  |  Port SSH : $sshPort" -ForegroundColor White
Write-Host "`n📡 LOCAL:" -ForegroundColor Cyan
Write-Host "   $cmdLocal" -ForegroundColor Yellow
Write-Host "`n🌍 PUBLIC (port forwarding required):" -ForegroundColor Cyan
Write-Host "   $cmdPublic" -ForegroundColor Yellow
Write-Host "`n🔒 TAILSCALE (recommended):" -ForegroundColor Cyan
Write-Host "   $cmdTail" -ForegroundColor Yellow

Set-Clipboard $cmdTail
Write-Host "`n📋 Tailscale SSH command copied to clipboard!`n" -ForegroundColor Green
Read-Host "Appuie sur Entrée pour fermer"
