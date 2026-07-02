#!/usr/bin/env bash
# =============================================================================
#  AI-VL  -  RUN  (Linux)  ->  equivalente de ../win/run.ps1  -  modo celular (HTTPS)
#  Deja el celular usable como "camara del robot": el navegador del celu necesita
#  HTTPS (secure context) para la camara, y por IP de LAN eso no lo da el HTTP
#  comun. Este script:
#    1) Detecta la IP de tu PC en la LAN.
#    2) Genera un certificado autofirmado ("trucho") con esa IP en el SAN.
#    3) Abre el puerto HTTPS en el firewall (ufw/firewalld) si esta disponible.
#    4) Hace `bun run build` del frontend (SPA de produccion).
#    5) Levanta iacore (:8001) y el backend por HTTPS (:8443) sirviendo el SPA
#       + /api + /ws en UN SOLO ORIGEN, apuntando a iacore local.
#  Despues, desde el celu (misma WiFi/red): https://<IP-de-tu-PC>:8443
#  El celu va a avisar que el cert no es de confianza -> "Avanzar / Continuar".
#  Requiere haber corrido ./install.sh antes.  Apagar: Ctrl+C.
# =============================================================================
set -euo pipefail

# El launcher puede estar en la raiz del repo O en una subcarpeta (ej. linux/).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -d "$ROOT/AI-VL-core" ] && [ -d "$(dirname "$ROOT")/AI-VL-core" ]; then
    ROOT="$(dirname "$ROOT")"
fi
CORE="$ROOT/AI-VL-core"
BACKEND="$ROOT/AI-VL-backend"
FRONTEND="$ROOT/AI-VL-frontend"
CERTDIR="$ROOT/certs"
HTTPS_PORT=8443

if [ -t 1 ]; then C_INFO='\033[36m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_GRN='\033[92m'; C_OFF='\033[0m'
else C_INFO=''; C_OK=''; C_WARN=''; C_GRN=''; C_OFF=''; fi
info() { printf "${C_INFO}[ AI-VL ] %s${C_OFF}\n" "$*"; }
ok()   { printf "${C_OK}[  OK  ] %s${C_OFF}\n" "$*"; }
warn() { printf "${C_WARN}[ WARN ] %s${C_OFF}\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
export PATH="$HOME/.bun/bin:$PATH"

# --- Pre-checks --------------------------------------------------------------
missing=()
[ -x "$CORE/.venv/bin/python" ]    || missing+=("AI-VL-core/.venv")
[ -x "$BACKEND/.venv/bin/python" ] || missing+=("AI-VL-backend/.venv")
[ -d "$FRONTEND/node_modules" ]    || missing+=("AI-VL-frontend/node_modules")
if [ "${#missing[@]}" -gt 0 ]; then
    warn "Faltan dependencias: ${missing[*]}  ->  corre ./install.sh primero."
    exit 1
fi

# --- 1) IP de LAN (auto-detectada; o forzada con certs/ip.override.txt) ------
ip=""
if [ -f "$CERTDIR/ip.override.txt" ]; then
    ip="$(tr -d '[:space:]' < "$CERTDIR/ip.override.txt")"
    ok "IP forzada (certs/ip.override.txt): $ip"
else
    # IP de la interfaz con gateway por defecto (ignora adaptadores virtuales sin ruta).
    if have ip; then
        ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)"
    fi
    # Fallback: primera IP privada de hostname -I.
    if [ -z "$ip" ] && have hostname; then
        ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.' | head -1)"
    fi
fi
if [ -z "$ip" ]; then
    warn 'No pude detectar la IP de LAN. Conectate a una red y reintenta (o usa certs/ip.override.txt).'
    exit 1
fi
ok "IP de tu PC en la LAN: $ip"

# --- 2) Firewall (opcional; puede pedir sudo) --------------------------------
if have ufw; then
    if sudo ufw allow "$HTTPS_PORT/tcp" >/dev/null 2>&1; then ok "Puerto $HTTPS_PORT abierto en ufw."
    else warn "No pude abrir el puerto en ufw (falta sudo?). Si el celu no conecta, abrilo a mano."; fi
elif have firewall-cmd; then
    if sudo firewall-cmd --add-port="$HTTPS_PORT/tcp" >/dev/null 2>&1; then ok "Puerto $HTTPS_PORT abierto en firewalld (temporal)."
    else warn "No pude abrir el puerto en firewalld (falta sudo?). Si el celu no conecta, abrilo a mano."; fi
else
    warn "No hay ufw/firewalld; se omite. Si el celu no conecta, permiti el puerto $HTTPS_PORT a mano."
fi

# --- 3) Certificado autofirmado (regenera si falta o cambio la IP) -----------
have openssl || { warn 'No encontre openssl. Instalalo (ej. apt install openssl) y reintenta.'; exit 1; }
mkdir -p "$CERTDIR"
KEY="$CERTDIR/key.pem"; CRT="$CERTDIR/cert.pem"; IPFILE="$CERTDIR/ip.txt"
need_cert=1
if [ -f "$KEY" ] && [ -f "$CRT" ] && [ -f "$IPFILE" ] && [ "$(tr -d '[:space:]' < "$IPFILE")" = "$ip" ]; then
    need_cert=0
fi
if [ "$need_cert" = 1 ]; then
    info "Generando certificado autofirmado para IP:$ip ..."
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -keyout "$KEY" -out "$CRT" -days 825 \
        -subj "/CN=AI-VL PoC" -addext "subjectAltName=IP:$ip,IP:127.0.0.1,DNS:localhost" \
        || { warn 'Fallo la generacion del certificado.'; exit 1; }
    printf '%s' "$ip" > "$IPFILE"
    ok 'Certificado listo.'
else
    ok 'Certificado existente reutilizado (misma IP).'
fi

# --- 4) Build del frontend ---------------------------------------------------
have bun || { warn 'No encontre bun. Corre ./install.sh.'; exit 1; }
info 'Compilando el frontend (bun run build) ...'
( cd "$FRONTEND" && bun run build ) || { warn 'bun run build fallo.'; exit 1; }
DIST="$FRONTEND/dist"
[ -f "$DIST/index.html" ] || { warn "No se genero $DIST/index.html"; exit 1; }
ok 'Frontend compilado.'

# --- 5) Ollama arriba --------------------------------------------------------
if ! curl -fsS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1; then
    have ollama && ollama serve >/dev/null 2>&1 &
    for i in $(seq 1 15); do
        curl -fsS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1 && break
        sleep 1
    done
fi

# --- 6) Levantar iacore (:8001) y backend HTTPS (:8443) ----------------------
# En Linux corremos ambos en background y con un trap para que Ctrl+C apague los
# dos limpiamente (equivalente a "cerrar las 2 ventanas" de Windows). La salida
# de cada servicio (los logs de uvicorn: GET/POST, quien se conecta, etc.) va EN
# VIVO a esta terminal, prefijada con [iacore]/[backend] para distinguirlos.
# Truco: `> >(sed ...)` (process substitution) prefija sin romper el PID -> $!
# sigue siendo el del python, asi el trap puede matarlo; sed corta solo al EOF.
pids=()
cleanup() {
    printf '\n'
    info 'Apagando iacore y backend ...'
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

info 'Levantando iacore (:8001) ...'
(
    cd "$CORE"
    export PYTHONUNBUFFERED=1      # que los logs salgan al toque, sin buffering
    exec .venv/bin/python -m uvicorn service:app --host 0.0.0.0 --port 8001
) > >(sed -u 's/^/[iacore]  /') 2>&1 &
pids+=($!)

info "Levantando backend HTTPS (:$HTTPS_PORT) sirviendo el frontend ..."
(
    cd "$BACKEND"
    export PYTHONUNBUFFERED=1
    export IACORE_URL="http://localhost:8001"
    export CORS_ORIGINS="*"
    export FRONTEND_DIST="$DIST"
    exec .venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port "$HTTPS_PORT" \
        --ssl-keyfile "$KEY" --ssl-certfile "$CRT"
) > >(sed -u 's/^/[backend] /') 2>&1 &
pids+=($!)

printf '\n'
ok 'MODO CELULAR LISTO.'
printf '\n'
printf "  Desde el celu (misma red/WiFi que la PC), abri:\n"
printf "        ${C_GRN}https://%s:%s${C_OFF}\n" "$ip" "$HTTPS_PORT"
printf '\n'
printf "  El celu va a avisar 'conexion no segura' (cert autofirmado):\n"
printf "    - Android/Chrome: 'Configuracion avanzada' -> 'Continuar'.\n"
printf "    - iPhone/Safari:  'Mostrar detalles' -> 'visitar este sitio web'.\n"
printf '\n'
printf "  Requisitos: PC y celu en la MISMA red; y darle permiso de camara al abrir.\n"
printf "  Abajo salen EN VIVO los logs de cada servicio (GET/POST, conexiones),\n"
printf "  prefijados con [iacore] / [backend]. Para apagar todo: Ctrl+C aca.\n"
printf '\n'

# Esperar a los procesos; si uno muere, el trap limpia el otro.
wait
