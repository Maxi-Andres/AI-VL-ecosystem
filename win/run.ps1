# =============================================================================
#  AI-VL  -  RUN  (invoked by run.bat)  -  phone/HTTPS mode (the only run mode)
#  Makes the phone usable as the "robot camera": the phone browser needs HTTPS
#  (a secure context) for the camera, and plain HTTP over a LAN IP does not give
#  that. This script:
#    1) Detects your PC's LAN IP.
#    2) Generates a self-signed certificate with that IP in the SAN.
#    3) Opens the HTTPS port in the Windows Firewall (that's why it needs admin).
#    4) Runs `bun run build` of the frontend (production SPA).
#    5) Starts iacore (:8001) and the backend over HTTPS (:8443) serving the SPA
#       + /api + /ws on ONE ORIGIN, pointing at local iacore.
#  Then, from the phone (same WiFi/network): https://<YOUR-PC-IP>:8443
#  The phone will warn the cert is untrusted -> "Advanced / Continue".
# =============================================================================
$ErrorActionPreference = 'Stop'
# The launcher may sit at the repo root OR in a subfolder (e.g. win/). Find the
# folder that actually contains the three app repos.
$root = $PSScriptRoot
if (-not (Test-Path (Join-Path $root 'AI-VL-core'))) {
    $parent = Split-Path $root
    if (Test-Path (Join-Path $parent 'AI-VL-core')) { $root = $parent }
}
$coreDir     = Join-Path $root 'AI-VL-core'       # iacore
$backendDir  = Join-Path $root 'AI-VL-backend'
$frontendDir = Join-Path $root 'AI-VL-frontend'
$certDir     = Join-Path $root 'certs'
$httpsPort   = 8443

function Info($m) { Write-Host "[ AI-VL ] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[  OK  ] $m"  -ForegroundColor Green }
function Warn($m) { Write-Host "[ WARN ] $m"  -ForegroundColor Yellow }
function Update-Path {
    $m = [System.Environment]::GetEnvironmentVariable('Path','Machine')
    $u = [System.Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = "$m;$u"
}

function Resolve-Ollama {
    $c = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    foreach ($p in @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe","$env:ProgramFiles\Ollama\ollama.exe")) { if (Test-Path $p) { return $p } }
    return $null
}
function Resolve-Bun {
    Update-Path
    $c = (Get-Command bun -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    foreach ($p in @("$env:USERPROFILE\.bun\bin\bun.exe","$env:LOCALAPPDATA\Microsoft\WinGet\Links\bun.exe")) { if (Test-Path $p) { return $p } }
    $g = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter bun.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.FullName }
    return $null
}
function Resolve-Openssl {
    $c = (Get-Command openssl -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if ($git) {
        $gitRoot = Split-Path (Split-Path $git)
        foreach ($rel in @('mingw64\bin\openssl.exe','usr\bin\openssl.exe')) { $p = Join-Path $gitRoot $rel; if (Test-Path $p) { return $p } }
    }
    foreach ($p in @("$env:ProgramFiles\Git\mingw64\bin\openssl.exe","$env:ProgramFiles\Git\usr\bin\openssl.exe","${env:ProgramFiles(x86)}\Git\mingw64\bin\openssl.exe")) { if (Test-Path $p) { return $p } }
    return $null
}

# Primary LAN IPv4: the interface that actually has a default gateway (skips the
# VMware/WSL virtual adapters, which have none).
function Get-LanIP {
    $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    if ($cfg) { return $cfg.IPv4Address.IPAddress }
    $a = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -match '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.' } | Select-Object -First 1
    if ($a) { return $a.IPAddress }
    return $null
}

# --- Pre-checks --------------------------------------------------------------
$coreVenv    = Join-Path $coreDir    '.venv\Scripts\python.exe'
$backendVenv = Join-Path $backendDir '.venv\Scripts\python.exe'
$missing = @()
if (-not (Test-Path $coreVenv))    { $missing += 'AI-VL-core/.venv' }
if (-not (Test-Path $backendVenv)) { $missing += 'AI-VL-backend/.venv' }
if (-not (Test-Path (Join-Path $frontendDir 'node_modules'))) { $missing += 'AI-VL-frontend/node_modules' }
if ($missing.Count -gt 0) {
    Warn ("Missing dependencies: " + ($missing -join ', ') + "  ->  run install.bat first.")
    exit 1
}

# --- 1) LAN IP (auto-detected; or forced via certs\ip.override.txt) ----------
$override = Join-Path $certDir 'ip.override.txt'
if (Test-Path $override) {
    $ip = (Get-Content $override -Raw).Trim()
    Ok "Forced IP (certs\ip.override.txt): $ip"
} else {
    $ip = Get-LanIP
}
if (-not $ip) { Warn 'Could not detect the LAN IP. Connect to a network and retry (or use certs\ip.override.txt).'; exit 1 }
Ok "Your PC's LAN IP: $ip"

# --- 2) Firewall (needs admin) ----------------------------------------------
$ruleName = "AI-VL phone HTTPS $httpsPort"
try {
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $httpsPort -Profile Any | Out-Null
        Ok "Firewall rule created for port $httpsPort."
    } else { Ok "Firewall rule already exists." }
} catch {
    Warn "Could not create the firewall rule (missing admin?). If the phone can't connect, allow port $httpsPort manually."
}

# --- 3) Self-signed certificate (regenerate if missing or the IP changed) ----
$openssl = Resolve-Openssl
if (-not $openssl) { Warn 'openssl not found (it ships with Git). Install Git or add openssl to PATH.'; exit 1 }
if (-not (Test-Path $certDir)) { New-Item -ItemType Directory -Path $certDir | Out-Null }
$key = Join-Path $certDir 'key.pem'
$crt = Join-Path $certDir 'cert.pem'
$ipFile = Join-Path $certDir 'ip.txt'
$needCert = $true
if ((Test-Path $key) -and (Test-Path $crt) -and (Test-Path $ipFile)) {
    if ((Get-Content $ipFile -Raw).Trim() -eq $ip) { $needCert = $false }
}
if ($needCert) {
    Info "Generating self-signed certificate for IP:$ip ..."
    # Git's openssl is an MSYS build that rewrites args starting with '/' into
    # Windows paths (would corrupt "/CN=..."). Disable that conversion.
    $env:MSYS_NO_PATHCONV = '1'
    & $openssl req -x509 -newkey rsa:2048 -sha256 -nodes -keyout $key -out $crt -days 825 `
        -subj "/CN=AI-VL PoC" -addext "subjectAltName=IP:$ip,IP:127.0.0.1,DNS:localhost"
    if ($LASTEXITCODE -ne 0) { Warn 'Certificate generation failed.'; exit 1 }
    Set-Content -Path $ipFile -Value $ip -Encoding ascii
    Ok 'Certificate ready.'
} else {
    Ok 'Reusing existing certificate (same IP).'
}

# --- 4) Frontend build -------------------------------------------------------
$bun = Resolve-Bun
if (-not $bun) { Warn 'bun.exe not found. Run install.bat.'; exit 1 }
Info 'Building the frontend (bun run build) ...'
Push-Location $frontendDir
& $bun run build
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0) { Warn 'bun run build failed.'; exit 1 }
$dist = Join-Path $frontendDir 'dist'
if (-not (Test-Path (Join-Path $dist 'index.html'))) { Warn "$dist\index.html was not generated"; exit 1 }
Ok 'Frontend built.'

# --- 5) Ollama up ------------------------------------------------------------
$ollama = Resolve-Ollama
for ($i = 0; $i -lt 15; $i++) {
    try { Invoke-WebRequest -UseBasicParsing 'http://localhost:11434/api/version' -TimeoutSec 2 | Out-Null; break }
    catch { if ($i -eq 0 -and $ollama) { Start-Process -WindowStyle Hidden -FilePath $ollama -ArgumentList 'serve' -ErrorAction SilentlyContinue }; Start-Sleep 1 }
}

# --- 6) iacore (:8001) -------------------------------------------------------
# Speech-to-text (Whisper) knobs. Defaults are CPU/int8/base so the ASR model does
# NOT compete with the VLM for the 8 GB GPU. Move it to the GPU by setting
# ASR_DEVICE=cuda / ASR_COMPUTE_TYPE=float16 before running run.bat.
$asrModel   = if ($env:ASR_MODEL)        { $env:ASR_MODEL }        else { 'base' }
$asrDevice  = if ($env:ASR_DEVICE)       { $env:ASR_DEVICE }       else { 'cpu' }
$asrCompute = if ($env:ASR_COMPUTE_TYPE) { $env:ASR_COMPUTE_TYPE } else { 'int8' }
# Neural text-to-speech (Piper) default voice; override with TTS_VOICE=<name>.
$ttsVoice   = if ($env:TTS_VOICE)        { $env:TTS_VOICE }        else { 'es_AR-daniela-high' }
Info 'Starting iacore (:8001) ...'
# Quote each `set` assignment so values with spaces don't break the cmd chain.
$iacoreCmd = "title AI-VL iacore :8001 & set `"ASR_MODEL=$asrModel`" & set `"ASR_DEVICE=$asrDevice`" & set `"ASR_COMPUTE_TYPE=$asrCompute`" & set `"TTS_VOICE=$ttsVoice`" & .venv\Scripts\python.exe -m uvicorn service:app --host 0.0.0.0 --port 8001"
Start-Process cmd.exe -ArgumentList '/k',$iacoreCmd -WorkingDirectory $coreDir

# --- 7) backend HTTPS (:8443), serves the SPA + /api + /ws on one origin ------
Info "Starting backend HTTPS (:$httpsPort) serving the frontend ..."
# Quote the `set` assignments and the cert/dist paths: $root (hence $dist/$key/
# $crt) may contain spaces, which would otherwise split the uvicorn arguments.
$cmd = "title AI-VL phone backend HTTPS :$httpsPort & set `"IACORE_URL=http://localhost:8001`" & set `"CORS_ORIGINS=*`" & set `"FRONTEND_DIST=$dist`" & .venv\Scripts\python.exe -m uvicorn app:app --host 0.0.0.0 --port $httpsPort --ssl-keyfile `"$key`" --ssl-certfile `"$crt`""
Start-Process cmd.exe -ArgumentList '/k',$cmd -WorkingDirectory $backendDir

Write-Host ''
Ok 'PHONE MODE READY.'
Write-Host ''
Write-Host "  From the phone (same network/WiFi as the PC), open:" -ForegroundColor White
Write-Host "        https://$ip`:$httpsPort" -ForegroundColor Green
Write-Host ''
Write-Host "  On THIS PC (monitor: view + control what the phone sees, streaming" -ForegroundColor White
Write-Host "  nothing until you press 'Activate'), open:" -ForegroundColor White
Write-Host "        https://localhost:$httpsPort/monitor" -ForegroundColor Green
Write-Host ''
Write-Host "  The phone will warn 'connection not secure' (self-signed cert):" -ForegroundColor Gray
Write-Host "    - Android/Chrome: 'Advanced' -> 'Continue'." -ForegroundColor Gray
Write-Host "    - iPhone/Safari:  'Show details' -> 'visit this website'." -ForegroundColor Gray
Write-Host ''
Write-Host "  Requirements: PC and phone on the SAME network; grant camera permission on open." -ForegroundColor Gray
Write-Host "  To stop: close the 2 windows (iacore and backend)." -ForegroundColor Gray
Write-Host ''
