#!/usr/bin/env bash
# =============================================================================
#  AI-VL  -  INSTALL  (Linux)   ->  equivalente de ../win/install.ps1
#  Correr UNA vez despues de clonar / al cambiar de compu. Instala todo:
#    1) Programas base si faltan: Python 3 (+venv), Bun, Ollama.
#    2) venv de Python + deps para iacore (AI-VL-core) y backend (AI-VL-backend).
#    3) `bun install` para el frontend (AI-VL-frontend).
#    4) Baja el modelo de Ollama que usa iacore (de AI-VL-core/config.json).
#  NO toca git: respeta la rama/commit en la que este cada repo.
#  NO se auto-eleva: instala en el home del usuario y pide `sudo` solo cuando
#  el instalador lo necesita (apt/dnf/pacman, o el script oficial de ollama).
#
#  Uso:   ./install.sh
# =============================================================================
set -euo pipefail

# El launcher puede estar en la raiz del repo O en una subcarpeta (ej. linux/).
# Buscar la carpeta que realmente contiene los tres repos de las apps.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -d "$ROOT/AI-VL-core" ] && [ -d "$(dirname "$ROOT")/AI-VL-core" ]; then
    ROOT="$(dirname "$ROOT")"
fi
CORE="$ROOT/AI-VL-core"        # iacore
BACKEND="$ROOT/AI-VL-backend"
FRONTEND="$ROOT/AI-VL-frontend"

# --- Salida con color --------------------------------------------------------
if [ -t 1 ]; then C_INFO='\033[36m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_OFF='\033[0m'
else C_INFO=''; C_OK=''; C_WARN=''; C_OFF=''; fi
info() { printf "${C_INFO}[ AI-VL ] %s${C_OFF}\n" "$*"; }
ok()   { printf "${C_OK}[  OK  ] %s${C_OFF}\n" "$*"; }
warn() { printf "${C_WARN}[ WARN ] %s${C_OFF}\n" "$*"; }
die()  { warn "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Detecta el gestor de paquetes de la distro (para instalar python3 si falta).
detect_pkg_mgr() {
    if   have apt-get; then echo apt
    elif have dnf;     then echo dnf
    elif have pacman;  then echo pacman
    elif have zypper;  then echo zypper
    else echo ""; fi
}

# Asegura python3 + el modulo venv (en Debian/Ubuntu venv viene aparte).
ensure_python() {
    if have python3; then ok "Python 3 ya instalado ($(python3 --version 2>&1))."; return; fi
    local mgr; mgr="$(detect_pkg_mgr)"
    info "Instalando Python 3 (gestor: ${mgr:-desconocido}) ..."
    case "$mgr" in
        apt)    sudo apt-get update && sudo apt-get install -y python3 python3-venv python3-pip ;;
        dnf)    sudo dnf install -y python3 python3-pip ;;
        pacman) sudo pacman -Sy --noconfirm python python-pip ;;
        zypper) sudo zypper install -y python3 python3-pip ;;
        *)      warn "No reconoci el gestor de paquetes. Instala Python 3 a mano y volve a correr."; return ;;
    esac
    have python3 && ok "Python 3 instalado." || warn "python3 sigue sin aparecer en PATH."
}

ensure_bun() {
    export PATH="$HOME/.bun/bin:$PATH"
    if have bun; then ok "Bun ya instalado."; return; fi
    info "Instalando Bun (installer oficial) ..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
    have bun && ok "Bun instalado." || warn "bun no aparecio en PATH; abri una terminal nueva o agrega ~/.bun/bin al PATH."
}

ensure_ollama() {
    if have ollama; then ok "Ollama ya instalado."; return; fi
    info "Instalando Ollama (installer oficial; puede pedir sudo) ..."
    curl -fsSL https://ollama.com/install.sh | sh
    have ollama && ok "Ollama instalado." || warn "ollama no aparecio en PATH tras instalar."
}

# Resuelve el binario de ollama aunque no este en PATH todavia.
resolve_ollama() {
    if have ollama; then command -v ollama; return; fi
    for p in "$HOME/.ollama/bin/ollama" /usr/local/bin/ollama /usr/bin/ollama; do
        [ -x "$p" ] && { echo "$p"; return; }
    done
    echo ""
}

# Crea un venv en $1 e instala su requirements.txt. Reusa el patron robusto de
# AI-VL-core/setup.sh: si la venv no trae pip (PEP 668 / sin ensurepip), la
# rehace con --without-pip y bootstrapea con get-pip.py (sin apt/sudo).
setup_py_project() {
    local dir="$1" label="$2"
    local venv="$dir/.venv" py="$dir/.venv/bin/python"
    info "$label : preparando venv ..."
    local need_bootstrap=0
    if [ ! -x "$py" ]; then
        python3 -m venv "$venv" 2>/dev/null || need_bootstrap=1
    fi
    if [ "$need_bootstrap" = 1 ] || ! "$py" -m pip --version >/dev/null 2>&1; then
        info "$label : la venv no trae pip (sin ensurepip) -> bootstrap con get-pip.py."
        rm -rf "$venv"
        python3 -m venv --without-pip "$venv"
        if have curl;   then curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$py"
        elif have wget; then wget -qO- https://bootstrap.pypa.io/get-pip.py | "$py"
        else die "Necesito curl o wget para bootstrapear pip en $label."; fi
    fi
    "$py" -m pip install --upgrade pip
    info "$label : instalando dependencias (puede tardar; iacore incluye torch/ultralytics) ..."
    "$py" -m pip install -r "$dir/requirements.txt" || die "pip install fallo en $label."
    ok "$label listo."
}

# =============================================================================
printf '\n'
echo "============================================================"
echo "  AI-VL : instalando dependencias (Linux)"
echo "============================================================"
printf '\n'

info 'Paso 1/4 - Programas base (Python, Bun, Ollama)'
ensure_python
ensure_bun
ensure_ollama
have python3 || die "No encontre python3. Instalalo y volve a correr ./install.sh."

printf '\n'
info 'Paso 2/4 - Dependencias de Python (iacore + backend)'
setup_py_project "$CORE"    'AI-VL-core (iacore)'
setup_py_project "$BACKEND" 'AI-VL-backend'

printf '\n'
info 'Paso 3/4 - Dependencias del frontend (bun)'
export PATH="$HOME/.bun/bin:$PATH"
if have bun; then
    ( cd "$FRONTEND" && bun install ) || die "bun install fallo en el frontend."
    ok 'AI-VL-frontend listo.'
else
    warn 'bun no esta disponible; se omite bun install. Instala Bun y volve a correr ./install.sh.'
fi

printf '\n'
info 'Paso 4/4 - Modelo de Ollama'
MODEL='qwen3-vl:4b-instruct'
if [ -f "$CORE/config.json" ]; then
    m="$(grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]+"' "$CORE/config.json" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]+)"/\1/')"
    [ -n "$m" ] && MODEL="$m"
fi
OLLAMA="$(resolve_ollama)"
if [ -z "$OLLAMA" ]; then
    warn "No encontre el binario de ollama. Si recien lo instalaste, abri una terminal nueva y volve a correr ./install.sh."
else
    info "Asegurando que el servidor de Ollama este arriba ..."
    up=0
    for i in $(seq 1 30); do
        if curl -fsS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1; then up=1; break; fi
        [ "$i" = 1 ] && "$OLLAMA" serve >/dev/null 2>&1 &
        sleep 1
    done
    if [ "$up" = 1 ]; then
        info "Descargando modelo '$MODEL' (varios GB, una sola vez) ..."
        if "$OLLAMA" pull "$MODEL"; then ok "Modelo '$MODEL' listo."
        else warn "No se pudo bajar '$MODEL'. Podes bajarlo luego con: ollama pull $MODEL"; fi
    else
        warn "El servidor de Ollama no respondio en :11434; se omite la descarga. Luego: ollama pull $MODEL"
    fi
fi

printf '\n'
ok 'INSTALACION COMPLETA. Ahora usa ./run.sh para prender todo.'
printf '\n'
