# =============================================================================
#  AI-VL  -  INSTALL  (invoked by install.bat)
#  Run ONCE after cloning / moving computers. Installs everything needed:
#    1) Base tools via winget if missing: Python 3.12, Bun, Ollama.
#    2) Python venv + deps for iacore (AI-VL-core) and backend (AI-VL-backend).
#    3) `bun install` for the frontend (AI-VL-frontend).
#    4) Pulls the Ollama model used by iacore (from AI-VL-core/config.json).
#  Does NOT touch git: it respects whatever branch/commit each repo is on.
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

function Info($m) { Write-Host "[ AI-VL ] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[  OK  ] $m"  -ForegroundColor Green }
function Warn($m) { Write-Host "[ WARN ] $m"  -ForegroundColor Yellow }

# Reload PATH from the registry so tools installed in THIS session are found.
function Update-Path {
    $machine = [System.Environment]::GetEnvironmentVariable('Path','Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = "$machine;$user"
}
function Have($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Ensure-WingetTool($cmd, $wingetId, $friendly) {
    Update-Path
    if (Have $cmd) { Ok "$friendly ya instalado."; return }
    Info "Instalando $friendly (winget: $wingetId) ..."
    winget install --id $wingetId -e --source winget `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    Update-Path
    if (Have $cmd) { Ok "$friendly instalado." }
    else { Warn "$cmd no aparecio en PATH tras instalar; puede requerir reiniciar la terminal/PC." }
}

function Resolve-Python {
    Update-Path
    if (Have 'py')     { return 'py' }
    if (Have 'python') { return 'python' }
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:ProgramFiles\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

# Ollama often is NOT on PATH right after a winget install (needs a new shell or
# reboot). Resolve its full exe path so we never depend on PATH.
function Resolve-Ollama {
    Update-Path
    $c = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    foreach ($p in @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe","$env:ProgramFiles\Ollama\ollama.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Bun (winget) lands in the WinGet Links dir, often not on PATH in a fresh shell.
function Resolve-Bun {
    Update-Path
    $c = (Get-Command bun -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    foreach ($p in @("$env:USERPROFILE\.bun\bin\bun.exe","$env:LOCALAPPDATA\Microsoft\WinGet\Links\bun.exe")) {
        if (Test-Path $p) { return $p }
    }
    $g = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter bun.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.FullName }
    return $null
}

# Create a venv in $dir and install its requirements.txt.
function Setup-PythonProject($dir, $pyLauncher, $label) {
    Info "$label : preparando venv ..."
    $venv   = Join-Path $dir '.venv'
    $venvPy = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path $venvPy)) {
        & $pyLauncher -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el venv en $dir" }
    }
    & $venvPy -m pip install --upgrade pip
    Info "$label : instalando dependencias (puede tardar; incluye torch/ultralytics en iacore) ..."
    & $venvPy -m pip install -r (Join-Path $dir 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw "pip install fallo en $label" }
    Ok "$label listo."
}

# =============================================================================
Write-Host ''
Info 'Paso 1/4 - Programas base (Python, Bun, Ollama)'
if (-not (Have 'winget')) { throw "winget no esta disponible. Actualiza 'App Installer' desde Microsoft Store." }
Ensure-WingetTool 'python' 'Python.Python.3.12' 'Python 3.12'
Ensure-WingetTool 'bun'    'Oven-sh.Bun'        'Bun'
Ensure-WingetTool 'ollama' 'Ollama.Ollama'      'Ollama'
$py = Resolve-Python
if (-not $py) { throw "No encontre Python tras instalar. Reinicia la PC y volve a correr install.bat." }
Ok "Python: usando '$py'."

Write-Host ''
Info 'Paso 2/4 - Dependencias de Python (iacore + backend)'
Setup-PythonProject $coreDir    $py 'AI-VL-core (iacore)'
Setup-PythonProject $backendDir $py 'AI-VL-backend'

Write-Host ''
Info 'Paso 3/4 - Dependencias del frontend (bun)'
$bun = Resolve-Bun
if ($bun) {
    Push-Location $frontendDir
    & $bun install
    $rc = $LASTEXITCODE
    Pop-Location
    if ($rc -ne 0) { throw "bun install fallo en el frontend" }
    Ok 'AI-VL-frontend listo.'
} else {
    Warn 'bun no esta disponible; se omite bun install. Instala Bun y volve a correr install.bat.'
}

Write-Host ''
Info 'Paso 4/4 - Modelo de Ollama'
$model = 'qwen3-vl:4b-instruct'
$cfg = Join-Path $coreDir 'config.json'
if (Test-Path $cfg) {
    try { $j = Get-Content $cfg -Raw | ConvertFrom-Json; if ($j.model) { $model = $j.model } } catch { }
}
$ollama = Resolve-Ollama
if (-not $ollama) {
    Warn "No encontre ollama.exe. Si recien lo instalaste, reinicia la PC y volve a correr install.bat."
} else {
    Info "Asegurando que el servidor de Ollama este arriba ..."
    $up = $false
    for ($i = 0; $i -lt 30; $i++) {
        try { Invoke-WebRequest -UseBasicParsing 'http://localhost:11434/api/version' -TimeoutSec 2 | Out-Null; $up = $true; break }
        catch { if ($i -eq 0) { Start-Process -WindowStyle Hidden -FilePath $ollama -ArgumentList 'serve' -ErrorAction SilentlyContinue }; Start-Sleep 1 }
    }
    if ($up) {
        Info "Descargando modelo '$model' (varios GB, una sola vez) ..."
        & $ollama pull $model
        if ($LASTEXITCODE -eq 0) { Ok "Modelo '$model' listo." }
        else { Warn "No se pudo bajar '$model'. Podes bajarlo luego con: ollama pull $model" }
    } else {
        Warn "El servidor de Ollama no respondio en :11434; se omite la descarga. Luego: ollama pull $model"
    }
}

Write-Host ''
Ok 'INSTALACION COMPLETA. Ahora usa start.bat para prender todo.'
Write-Host ''
