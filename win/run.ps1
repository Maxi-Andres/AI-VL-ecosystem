# =============================================================================
#  AI-VL  -  RUN  (invoked by run.bat)  -  phone/HTTPS mode (the only run mode)
#  Deja el celular usable como "camara del robot": el navegador del celu necesita
#  HTTPS (secure context) para la camara, y por IP de LAN eso no lo da el HTTP
#  comun. Este script:
#    1) Detecta la IP de tu PC en la LAN.
#    2) Genera un certificado autofirmado ("trucho") con esa IP en el SAN.
#    3) Abre el puerto HTTPS en el Firewall de Windows (por eso pide admin).
#    4) Hace `bun run build` del frontend (SPA de produccion).
#    5) Levanta iacore (:8001) y el backend por HTTPS (:8443) sirviendo el SPA
#       + /api + /ws en UN SOLO ORIGEN, apuntando a iacore local.
#  Despues, desde el celu (misma WiFi/red): https://<IP-de-tu-PC>:8443
#  El celu va a avisar que el cert no es de confianza -> "Avanzar / Continuar".
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
    Warn ("Faltan dependencias: " + ($missing -join ', ') + "  ->  corre install.bat primero.")
    exit 1
}

# --- 1) LAN IP (auto-detectada; o forzada con certs\ip.override.txt) --------
$override = Join-Path $certDir 'ip.override.txt'
if (Test-Path $override) {
    $ip = (Get-Content $override -Raw).Trim()
    Ok "IP forzada (certs\ip.override.txt): $ip"
} else {
    $ip = Get-LanIP
}
if (-not $ip) { Warn 'No pude detectar la IP de LAN. Conectate a una red y reintenta (o usa certs\ip.override.txt).'; exit 1 }
Ok "IP de tu PC en la LAN: $ip"

# --- 2) Firewall (necesita admin) -------------------------------------------
$ruleName = "AI-VL phone HTTPS $httpsPort"
try {
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $httpsPort -Profile Any | Out-Null
        Ok "Regla de firewall creada para el puerto $httpsPort."
    } else { Ok "Regla de firewall ya existe." }
} catch {
    Warn "No pude crear la regla de firewall (falta admin?). Si el celu no conecta, permiti el puerto $httpsPort manualmente."
}

# --- 3) Certificado autofirmado (regenera si falta o cambio la IP) ----------
$openssl = Resolve-Openssl
if (-not $openssl) { Warn 'No encontre openssl (viene con Git). Instala Git o agrega openssl al PATH.'; exit 1 }
if (-not (Test-Path $certDir)) { New-Item -ItemType Directory -Path $certDir | Out-Null }
$key = Join-Path $certDir 'key.pem'
$crt = Join-Path $certDir 'cert.pem'
$ipFile = Join-Path $certDir 'ip.txt'
$needCert = $true
if ((Test-Path $key) -and (Test-Path $crt) -and (Test-Path $ipFile)) {
    if ((Get-Content $ipFile -Raw).Trim() -eq $ip) { $needCert = $false }
}
if ($needCert) {
    Info "Generando certificado autofirmado para IP:$ip ..."
    # Git's openssl is an MSYS build that rewrites args starting with '/' into
    # Windows paths (would corrupt "/CN=..."). Disable that conversion.
    $env:MSYS_NO_PATHCONV = '1'
    & $openssl req -x509 -newkey rsa:2048 -sha256 -nodes -keyout $key -out $crt -days 825 `
        -subj "/CN=AI-VL PoC" -addext "subjectAltName=IP:$ip,IP:127.0.0.1,DNS:localhost"
    if ($LASTEXITCODE -ne 0) { Warn 'Fallo la generacion del certificado.'; exit 1 }
    Set-Content -Path $ipFile -Value $ip -Encoding ascii
    Ok 'Certificado listo.'
} else {
    Ok 'Certificado existente reutilizado (misma IP).'
}

# --- 4) Build del frontend ---------------------------------------------------
$bun = Resolve-Bun
if (-not $bun) { Warn 'No encontre bun.exe. Corre install.bat.'; exit 1 }
Info 'Compilando el frontend (bun run build) ...'
Push-Location $frontendDir
& $bun run build
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0) { Warn 'bun run build fallo.'; exit 1 }
$dist = Join-Path $frontendDir 'dist'
if (-not (Test-Path (Join-Path $dist 'index.html'))) { Warn "No se genero $dist\index.html"; exit 1 }
Ok 'Frontend compilado.'

# --- 5) Ollama arriba --------------------------------------------------------
$ollama = Resolve-Ollama
for ($i = 0; $i -lt 15; $i++) {
    try { Invoke-WebRequest -UseBasicParsing 'http://localhost:11434/api/version' -TimeoutSec 2 | Out-Null; break }
    catch { if ($i -eq 0 -and $ollama) { Start-Process -WindowStyle Hidden -FilePath $ollama -ArgumentList 'serve' -ErrorAction SilentlyContinue }; Start-Sleep 1 }
}

# --- 6) iacore (:8001) -------------------------------------------------------
Info 'Levantando iacore (:8001) ...'
Start-Process cmd.exe -ArgumentList '/k','title AI-VL iacore :8001 & .venv\Scripts\python.exe -m uvicorn service:app --host 0.0.0.0 --port 8001' -WorkingDirectory $coreDir

# --- 7) backend HTTPS (:8443), sirve el SPA + /api + /ws en un solo origen ---
Info "Levantando backend HTTPS (:$httpsPort) sirviendo el frontend ..."
$cmd = "title AI-VL phone backend HTTPS :$httpsPort & set IACORE_URL=http://localhost:8001 & set CORS_ORIGINS=* & set FRONTEND_DIST=$dist & .venv\Scripts\python.exe -m uvicorn app:app --host 0.0.0.0 --port $httpsPort --ssl-keyfile $key --ssl-certfile $crt"
Start-Process cmd.exe -ArgumentList '/k',$cmd -WorkingDirectory $backendDir

Write-Host ''
Ok 'MODO CELULAR LISTO.'
Write-Host ''
Write-Host "  Desde el celu (misma red/WiFi que la PC), abri:" -ForegroundColor White
Write-Host "        https://$ip`:$httpsPort" -ForegroundColor Green
Write-Host ''
Write-Host "  El celu va a avisar 'conexion no segura' (cert autofirmado):" -ForegroundColor Gray
Write-Host "    - Android/Chrome: 'Configuracion avanzada' -> 'Continuar'." -ForegroundColor Gray
Write-Host "    - iPhone/Safari:  'Mostrar detalles' -> 'visitar este sitio web'." -ForegroundColor Gray
Write-Host ''
Write-Host "  Requisitos: PC y celu en la MISMA red; y darle permiso de camara al abrir." -ForegroundColor Gray
Write-Host "  Para apagar: cerra las 2 ventanas (iacore y backend)." -ForegroundColor Gray
Write-Host ''
