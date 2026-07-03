#!/usr/bin/env bash
# =============================================================================
#  AI-VL  -  INSTALL  (Linux)   ->  equivalent of ../win/install.ps1
#  Run ONCE after cloning / when switching machines. Installs everything:
#    1) Base tools if missing: Python 3 (+venv), Bun, Ollama.
#    2) Python venv + deps for iacore (AI-VL-core) and backend (AI-VL-backend).
#    3) `bun install` for the frontend (AI-VL-frontend).
#    4) Pulls the Ollama model iacore uses (from AI-VL-core/config.json).
#  Does NOT touch git: it respects whatever branch/commit each repo is on.
#  Does NOT auto-elevate: installs into the user's home and only asks for `sudo`
#  when the installer needs it (apt/dnf/pacman, or Ollama's official script).
#
#  Usage:   ./install.sh
# =============================================================================
set -euo pipefail

# The launcher may sit at the repo root OR in a subfolder (e.g. linux/). Find the
# folder that actually contains the three app repos.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -d "$ROOT/AI-VL-core" ] && [ -d "$(dirname "$ROOT")/AI-VL-core" ]; then
    ROOT="$(dirname "$ROOT")"
fi
CORE="$ROOT/AI-VL-core"        # iacore
BACKEND="$ROOT/AI-VL-backend"
FRONTEND="$ROOT/AI-VL-frontend"

# --- Colored output ----------------------------------------------------------
if [ -t 1 ]; then C_INFO='\033[36m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_OFF='\033[0m'
else C_INFO=''; C_OK=''; C_WARN=''; C_OFF=''; fi
info() { printf "${C_INFO}[ AI-VL ] %s${C_OFF}\n" "$*"; }
ok()   { printf "${C_OK}[  OK  ] %s${C_OFF}\n" "$*"; }
warn() { printf "${C_WARN}[ WARN ] %s${C_OFF}\n" "$*"; }
die()  { warn "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Detect the distro's package manager (to install python3 if missing).
detect_pkg_mgr() {
    if   have apt-get; then echo apt
    elif have dnf;     then echo dnf
    elif have pacman;  then echo pacman
    elif have zypper;  then echo zypper
    else echo ""; fi
}

# Ensure python3 + the venv module (on Debian/Ubuntu venv ships separately).
ensure_python() {
    if have python3; then ok "Python 3 already installed ($(python3 --version 2>&1))."; return; fi
    local mgr; mgr="$(detect_pkg_mgr)"
    info "Installing Python 3 (manager: ${mgr:-unknown}) ..."
    case "$mgr" in
        apt)    sudo apt-get update && sudo apt-get install -y python3 python3-venv python3-pip ;;
        dnf)    sudo dnf install -y python3 python3-pip ;;
        pacman) sudo pacman -Sy --noconfirm python python-pip ;;
        zypper) sudo zypper install -y python3 python3-pip ;;
        *)      warn "Could not recognize the package manager. Install Python 3 by hand and re-run."; return ;;
    esac
    have python3 && ok "Python 3 installed." || warn "python3 still not on PATH."
}

ensure_bun() {
    export PATH="$HOME/.bun/bin:$PATH"
    if have bun; then ok "Bun already installed."; return; fi
    info "Installing Bun (official installer) ..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
    have bun && ok "Bun installed." || warn "bun not on PATH; open a new terminal or add ~/.bun/bin to PATH."
}

ensure_ollama() {
    if have ollama; then ok "Ollama already installed."; return; fi
    info "Installing Ollama (official installer; may ask for sudo) ..."
    curl -fsSL https://ollama.com/install.sh | sh
    have ollama && ok "Ollama installed." || warn "ollama not on PATH after installing."
}

# Resolve the ollama binary even if it isn't on PATH yet.
resolve_ollama() {
    if have ollama; then command -v ollama; return; fi
    for p in "$HOME/.ollama/bin/ollama" /usr/local/bin/ollama /usr/bin/ollama; do
        [ -x "$p" ] && { echo "$p"; return; }
    done
    echo ""
}

# Create a venv in $1 and install its requirements.txt. Reuses the robust pattern
# from AI-VL-core/setup.sh: if the venv ships without pip (PEP 668 / no ensurepip),
# rebuild it with --without-pip and bootstrap with get-pip.py (no apt/sudo).
setup_py_project() {
    local dir="$1" label="$2"
    local venv="$dir/.venv" py="$dir/.venv/bin/python"
    info "$label : preparing venv ..."
    local need_bootstrap=0
    if [ ! -x "$py" ]; then
        python3 -m venv "$venv" 2>/dev/null || need_bootstrap=1
    fi
    if [ "$need_bootstrap" = 1 ] || ! "$py" -m pip --version >/dev/null 2>&1; then
        info "$label : the venv has no pip (no ensurepip) -> bootstrapping with get-pip.py."
        rm -rf "$venv"
        python3 -m venv --without-pip "$venv"
        if have curl;   then curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$py"
        elif have wget; then wget -qO- https://bootstrap.pypa.io/get-pip.py | "$py"
        else die "Need curl or wget to bootstrap pip in $label."; fi
    fi
    "$py" -m pip install --upgrade pip
    info "$label : installing dependencies (may take a while; iacore includes torch/ultralytics) ..."
    "$py" -m pip install -r "$dir/requirements.txt" || die "pip install failed in $label."
    ok "$label ready."
}

# =============================================================================
printf '\n'
echo "============================================================"
echo "  AI-VL : installing dependencies (Linux)"
echo "============================================================"
printf '\n'

info 'Step 1/4 - Base tools (Python, Bun, Ollama)'
ensure_python
ensure_bun
ensure_ollama
have python3 || die "python3 not found. Install it and re-run ./install.sh."

printf '\n'
info 'Step 2/4 - Python dependencies (iacore + backend)'
setup_py_project "$CORE"    'AI-VL-core (iacore)'
setup_py_project "$BACKEND" 'AI-VL-backend'

# Pre-download the Whisper (speech-to-text) weights so the first dictation works
# offline, like the Ollama pull below. Best-effort: faster-whisper also downloads
# the model lazily on first use, so a failure here is not fatal. Defaults match
# asr_common (CPU/int8/base) and can be overridden by exporting ASR_* before install.
ASR_MODEL_DL="${ASR_MODEL:-base}"
info "AI-VL-core (iacore) : pre-downloading Whisper '$ASR_MODEL_DL' weights (speech-to-text; one time) ..."
if "$CORE/.venv/bin/python" - <<PY 2>/dev/null
from faster_whisper import WhisperModel
WhisperModel("${ASR_MODEL_DL}", device="${ASR_DEVICE:-cpu}", compute_type="${ASR_COMPUTE_TYPE:-int8}")
PY
then ok "Whisper model '$ASR_MODEL_DL' ready."
else warn "Could not pre-download the Whisper model; it will download on the first dictation instead."; fi

# Piper TTS voices (neural text-to-speech). Downloaded once into iacore's
# piper_voices/. Best-effort: browser voices work without these, and you can drop
# more <name>.onnx (+ .onnx.json) files there later (browse rhasspy/piper-voices).
VOICES_DIR="$CORE/piper_voices"
PIPER_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main"
mkdir -p "$VOICES_DIR"
dl_voice() {
    local rel="$1" name="$2"
    if [ -f "$VOICES_DIR/$name.onnx" ] && [ -f "$VOICES_DIR/$name.onnx.json" ]; then
        ok "Piper voice '$name' already present."; return
    fi
    info "Downloading Piper voice '$name' ..."
    if curl -fsSL "$PIPER_BASE/$rel/$name.onnx" -o "$VOICES_DIR/$name.onnx" \
       && curl -fsSL "$PIPER_BASE/$rel/$name.onnx.json" -o "$VOICES_DIR/$name.onnx.json"; then
        ok "Piper voice '$name' ready."
    else
        warn "Could not download Piper voice '$name'; add .onnx files to $VOICES_DIR later."
        rm -f "$VOICES_DIR/$name.onnx" "$VOICES_DIR/$name.onnx.json"
    fi
}
dl_voice "es/es_AR/daniela/high"   "es_AR-daniela-high"     # Rioplatense (default)
dl_voice "es/es_ES/sharvard/medium" "es_ES-sharvard-medium"  # Castilian (alternative)

printf '\n'
info 'Step 3/4 - Frontend dependencies (bun)'
export PATH="$HOME/.bun/bin:$PATH"
if have bun; then
    ( cd "$FRONTEND" && bun install ) || die "bun install failed in the frontend."
    ok 'AI-VL-frontend ready.'
else
    warn 'bun not available; skipping bun install. Install Bun and re-run ./install.sh.'
fi

printf '\n'
info 'Step 4/4 - Ollama model'
MODEL='qwen3-vl:4b-instruct'
if [ -f "$CORE/config.json" ]; then
    m="$(grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]+"' "$CORE/config.json" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]+)"/\1/')"
    [ -n "$m" ] && MODEL="$m"
fi
OLLAMA="$(resolve_ollama)"
if [ -z "$OLLAMA" ]; then
    warn "ollama binary not found. If you just installed it, open a new terminal and re-run ./install.sh."
else
    info "Making sure the Ollama server is up ..."
    up=0
    for i in $(seq 1 30); do
        if curl -fsS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1; then up=1; break; fi
        [ "$i" = 1 ] && "$OLLAMA" serve >/dev/null 2>&1 &
        sleep 1
    done
    if [ "$up" = 1 ]; then
        info "Pulling model '$MODEL' (several GB, one time only) ..."
        if "$OLLAMA" pull "$MODEL"; then ok "Model '$MODEL' ready."
        else warn "Could not pull '$MODEL'. You can pull it later with: ollama pull $MODEL"; fi
    else
        warn "The Ollama server did not answer on :11434; skipping the pull. Later: ollama pull $MODEL"
    fi
fi

printf '\n'
ok 'INSTALL COMPLETE. Now use ./run.sh to start everything.'
printf '\n'
