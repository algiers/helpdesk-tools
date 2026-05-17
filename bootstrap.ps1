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

# ===== Helper =====
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

# Attendre que le binaire sshd apparaisse
$sshdBin = $null
$elapsed = 0
while (!$sshdBin -and $elapsed -lt 60) {
    foreach ($p in @(
        "$env:SystemRoot\System32\OpenSSH\sshd.exe",
        "$env:ProgramFiles\OpenSSH\sshd.exe",
        "C:\Program Files\OpenSSH\OpenSSH-Win64\sshd.exe"
    )) { if (Test-Path $p) { $sshdBin = $p; break } }
    if (!$sshdBin) { Start-Sleep -Seconds 2; $elapsed += 2 }
}
if (!$sshdBin) { Die "OpenSSH install failed — sshd.exe introuvable." }
Log "sshd binary : $sshdBin"

# ===== Trouver ssh-keygen =====
$sshKeygen = $null
$kCmd = Get-Command ssh-keygen -ea 0
if ($kCmd) { $sshKeygen = $kCmd.Source }
if (!$sshKeygen) {
    foreach ($p in @(
        "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe",
        "$env:ProgramFiles\OpenSSH\ssh-keygen.exe",
        "C:\Program Files\OpenSSH\OpenSSH-Win64\ssh-keygen.exe"
    )) { if (Test-Path $p) { $sshKeygen = $p; break } }
}
if (!$sshKeygen) { Die "ssh-keygen introuvable." }
Log "ssh-keygen  : $sshKeygen"

# ===== Host keys — reset propre =====
$sshdDataDir = "C:\ProgramData\ssh"
if (!(Test-Path $sshdDataDir)) { New-Item -ItemType Directory -Force -Path $sshdDataDir | Out-Null }

Push-Location $sshdDataDir
& $sshKeygen -A 2>$null
Pop-Location

# Permissions strictes : SYSTEM + Administrators uniquement
Get-ChildItem "$sshdDataDir\ssh_host_*_key" -ea 0 | ForEach-Object {
    cmd.exe /c "icacls `"$($_.FullName)`" /inheritance:r /grant `"NT AUTHORITY\SYSTEM:F`" /grant `"BUILTIN\Administrators:F`"" | Out-Null
}
Log "Host keys OK"

# ===== Détecter port libre (évite conflits AnyDesk etc.) =====
$usedPorts = (netstat -an | Select-String 'LISTENING' | ForEach-Object {
    if ($_ -match ':(\d+)\s') { [int]$matches[1] }
})
$sshPort = 22
if ($usedPorts -contains 22) {
    $sshPort = 2222
    while ($usedPorts -contains $sshPort) { $sshPort++ }
    Log "Port 22 occupé — utilisation du port $sshPort" "Yellow"
} else {
    Log "Port 22 libre ✅"
}

# ===== sshd_config =====
$config = "$sshdDataDir\sshd_config"
@"
Port $sshPort
PubkeyAuthentication yes
PasswordAuthentication no
"@ | Set-Content $config
Log "sshd_config écrit"

# ===== Firewall =====
$ruleName = "sshd-port-$sshPort"
if (!(Get-NetFirewallRule -Name $ruleName -ea 0)) {
    New-NetFirewallRule -Name $ruleName -DisplayName $ruleName `
        -Direction Inbound -Protocol TCP -Action Allow -LocalPort $sshPort | Out-Null
}
Log "Firewall port $sshPort ouvert"

# ===== Démarrer sshd — service puis fallback tâche planifiée =====
$sshdRunning = $false

# Tentative via service Windows
if (Get-Service sshd -ea 0) {
    sc.exe delete sshd 2>$null | Out-Null
    Start-Sleep -Seconds 1
}
sc.exe create sshd binPath="`"$sshdBin`"" start=auto obj=LocalSystem displayname="OpenSSH SSH Server" | Out-Null
sc.exe start sshd | Out-Null
Start-Sleep -Seconds 3
if ((Get-Service sshd -ea 0).Status -eq 'Running') {
    $sshdRunning = $true
    Log "sshd démarré via service Windows ✅" "Green"
}

# Fallback : tâche planifiée
if (!$sshdRunning) {
    Log "Service Windows échoué — fallback tâche planifiée..." "Yellow"
    $action    = New-ScheduledTaskAction -Execute $sshdBin
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "OpenSSH-sshd" -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName "OpenSSH-sshd"
    Start-Sleep -Seconds 3
}

# Vérifier que le port écoute
$portCheck = netstat -an | findstr ":$sshPort"
if (!$portCheck) {
    Die "sshd ne répond pas sur le port $sshPort — vérifie l'Observateur d'événements."
}
Log "Port $sshPort en écoute ✅" "Green"

# ===== SSH Key setup =====
$sshDir = "$env:USERPROFILE\.ssh"
$key    = "$sshDir\id_rsa"
$pub    = "$key.pub"
$auth   = "$sshDir\authorized_keys"

# Takeown si dossier verrouillé
if (Test-Path $sshDir) {
    cmd.exe /c "takeown /f `"$sshDir`" /r /d y 2>nul" | Out-Null
    cmd.exe /c "icacls `"$sshDir`" /grant Administrators:F /t 2>nul" | Out-Null
    cmd.exe /c "icacls `"$sshDir`" /grant `"$env:USERNAME`:F`" /t 2>nul" | Out-Null
}
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

if (!(Test-Path $key)) {
    & $sshKeygen -t rsa -b 4096 -N '""' -f $key | Out-Null
}

$pubContent = (Get-Content $pub -Raw).Trim()
if (!(Test-Path $auth)) { New-Item -ItemType File -Force -Path $auth | Out-Null }
$existing = Get-Content $auth -Raw -ea 0
if (!$existing -or $existing -notmatch [regex]::Escape($pubContent)) {
    $pubContent | Add-Content $auth
}

# Permissions après écriture
icacls $sshDir /inheritance:r                     | Out-Null
icacls $sshDir /grant "$env:USERNAME`:(OI)(CI)F" | Out-Null
icacls $auth /inheritance:r                       | Out-Null
icacls $auth /grant "$env:USERNAME`:F"            | Out-Null
Log "SSH keys OK"

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
