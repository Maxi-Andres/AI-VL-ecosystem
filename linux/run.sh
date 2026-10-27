#!/usr/bin/env bash
# =============================================================================
#  AI-VL  -  RUN  (Linux)  ->  equivalent of ../win/run.ps1  -  phone mode (HTTPS)
#  Makes the phone usable as the "robot camera": the phone browser needs HTTPS
#  (a secure context) for the camera, and plain HTTP over a LAN IP does not give
#  that. This script:
#    1) Detects your PC's LAN IP.
#    2) Generates a self-signed certificate with that IP in the SAN.
#    3) Opens the HTTPS port in the firewall (ufw/firewalld) if available.
#    4) Runs `bun run build` of the frontend (production SPA).
#    5) Starts iacore (:8001) and the backend over HTTPS (:8443) serving the SPA
#       + /api + /ws on ONE ORIGIN, pointing at local iacore.
#  Then, from the phone (same WiFi/network): https://<YOUR-PC-IP>:8443
#  The phone will warn the cert is untrusted -> "Advanced / Continue".
#  Requires ./install.sh to have been run first.  Stop: Ctrl+C.
# =============================================================================
set -euo pipefail

# The launcher may sit at the repo root OR in a subfolder (e.g. linux/).
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
    warn "Missing dependencies: ${missing[*]}  ->  run ./install.sh first."
    exit 1
fi

# --- 1) LAN IP (auto-detected; or forced via certs/ip.override.txt) ----------
ip=""
if [ -f "$CERTDIR/ip.override.txt" ]; then
    ip="$(tr -d '[:space:]' < "$CERTDIR/ip.override.txt")"
    ok "Forced IP (certs/ip.override.txt): $ip"
else
    # IP of the interface with the default gateway (skips virtual adapters with no route).
    if have ip; then
        ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)"
    fi
    # Fallback: first private IP from hostname -I.
    if [ -z "$ip" ] && have hostname; then
        ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.' | head -1)"
    fi
fi
if [ -z "$ip" ]; then
    warn 'Could not detect the LAN IP. Connect to a network and retry (or use certs/ip.override.txt).'
    exit 1
fi
ok "Your PC's LAN IP: $ip"

# --- 2) Firewall (optional; may ask for sudo) --------------------------------
if have ufw; then
    if sudo ufw allow "$HTTPS_PORT/tcp" >/dev/null 2>&1; then ok "Port $HTTPS_PORT opened in ufw."
    else warn "Could not open the port in ufw (missing sudo?). If the phone can't connect, open it by hand."; fi
elif have firewall-cmd; then
    if sudo firewall-cmd --add-port="$HTTPS_PORT/tcp" >/dev/null 2>&1; then ok "Port $HTTPS_PORT opened in firewalld (temporary)."
    else warn "Could not open the port in firewalld (missing sudo?). If the phone can't connect, open it by hand."; fi
else
    warn "No ufw/firewalld; skipping. If the phone can't connect, allow port $HTTPS_PORT by hand."
fi

# --- 3) Self-signed certificate (regenerate if missing or the IP changed) ----
have openssl || { warn 'openssl not found. Install it (e.g. apt install openssl) and retry.'; exit 1; }
mkdir -p "$CERTDIR"
KEY="$CERTDIR/key.pem"; CRT="$CERTDIR/cert.pem"; IPFILE="$CERTDIR/ip.txt"
need_cert=1
if [ -f "$KEY" ] && [ -f "$CRT" ] && [ -f "$IPFILE" ] && [ "$(tr -d '[:space:]' < "$IPFILE")" = "$ip" ]; then
    need_cert=0
fi
if [ "$need_cert" = 1 ]; then
    info "Generating self-signed certificate for IP:$ip ..."
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -keyout "$KEY" -out "$CRT" -days 825 \
        -subj "/CN=AI-VL PoC" -addext "subjectAltName=IP:$ip,IP:127.0.0.1,DNS:localhost" \
        || { warn 'Certificate generation failed.'; exit 1; }
    printf '%s' "$ip" > "$IPFILE"
    ok 'Certificate ready.'
else
    ok 'Reusing existing certificate (same IP).'
fi

# --- 4) Frontend build -------------------------------------------------------
have bun || { warn 'bun not found. Run ./install.sh.'; exit 1; }
info 'Building the frontend (bun run build) ...'
( cd "$FRONTEND" && bun run build ) || { warn 'bun run build failed.'; exit 1; }
DIST="$FRONTEND/dist"
[ -f "$DIST/index.html" ] || { warn "$DIST/index.html was not generated"; exit 1; }
ok 'Frontend built.'

# --- 5) Ollama up ------------------------------------------------------------
if ! curl -fsS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1; then
    have ollama && ollama serve >/dev/null 2>&1 &
    for i in $(seq 1 15); do
        curl -fsS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1 && break
        sleep 1
    done
fi

# --- 6) Start iacore (:8001) and backend HTTPS (:8443) -----------------------
# On Linux we run both in the background with a trap so Ctrl+C shuts both down
# cleanly (the equivalent of "closing the 2 windows" on Windows). Each service's
# output (uvicorn logs: GET/POST, who connects, etc.) streams LIVE to this
# terminal, prefixed with [iacore]/[backend] to tell them apart.
# Trick: `> >(sed ...)` (process substitution) prefixes without breaking the PID
# -> $! stays the python one, so the trap can kill it; sed exits only at EOF.
pids=()
cleanup() {
    printf '\n'
    info 'Shutting down iacore, the backend and the VLM server ...'
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# --- 6a) The VLM server, when vlm_backend is "llamacpp" -------------------------
# llama-server with the vision encoder on the GPU (vlm-server.sh says why: Ollama runs
# it on the CPU, ~6 s per photo). It lives exactly as long as this script: started
# here, killed by the trap like the other two, so the 4-5 GB of VRAM it holds are
# only taken while the app runs. Its own log is chatty (one block per request), so
# it goes to a file. If it does not come up, iacore falls back to Ollama.
# vlm_backend: config.json (over iacore's defaults); VLM_BACKEND=ollama ./run.sh skips it.
VLM_PORT=8081
VLM_LOG="${TMPDIR:-/tmp}/ai-vl-vlm-server.log"
vlm_backend="$(cd "$CORE/src" && "$CORE/.venv/bin/python" -c 'from vlm_common import vlm_backend; print(vlm_backend())' 2>/dev/null || echo ollama)"
if [ "$vlm_backend" = "llamacpp" ]; then
    info "Starting the VLM server (llama-server, :$VLM_PORT; log: $VLM_LOG) ..."
    VLM_PORT="$VLM_PORT" "$ROOT/linux/vlm-server.sh" > "$VLM_LOG" 2>&1 &
    pids+=($!)
    vlm_up=0
    for _ in $(seq 1 90); do
        if curl -fsS --max-time 2 "http://127.0.0.1:$VLM_PORT/health" 2>/dev/null | grep -q '"ok"'; then
            vlm_up=1; break
        fi
        kill -0 "${pids[-1]}" 2>/dev/null || break      # it died: no point waiting
        sleep 1
    done
    if [ "$vlm_up" = 1 ]; then
        ok "VLM server up (vision on the GPU)."
        export VLM_BACKEND=llamacpp VLM_URL="http://127.0.0.1:$VLM_PORT"
    else
        warn "The VLM server did not start (see $VLM_LOG): falling back to Ollama."
        export VLM_BACKEND=ollama
    fi
fi

info 'Starting iacore (:8001) ...'
(
    cd "$CORE"
    export PYTHONUNBUFFERED=1      # emit logs immediately, no buffering
    # Speech-to-text (Whisper) knobs: small on the GPU in int8. Measured 2026-10-16 on
    # 30 Argentine speakers: 2.6 % WER in 0.16 s with 482 MB of VRAM, against 8.0 % in
    # 0.47 s for the old base/CPU (AI-VL-core/src/asr_common.py has the full table).
    # With no usable GPU it drops to the CPU by itself. Old behavior:
    #   ASR_MODEL=base ASR_DEVICE=cpu ASR_COMPUTE_TYPE=int8 ./run.sh
    export ASR_MODEL="${ASR_MODEL:-small}"
    export ASR_DEVICE="${ASR_DEVICE:-cuda}"
    export ASR_COMPUTE_TYPE="${ASR_COMPUTE_TYPE:-int8_float16}"
    # Neural text-to-speech. Default voice (Kokoro's Alex, picked 2026-10-19); override with
    # TTS_VOICE=<name> — any name /tts/voices lists. Runs on CPU.
    export TTS_VOICE="${TTS_VOICE:-em_alex}"
    exec .venv/bin/python -m uvicorn service:app --host 0.0.0.0 --port 8001
) > >(sed -u 's/^/[iacore]  /') 2>&1 &
pids+=($!)

info "Starting backend HTTPS (:$HTTPS_PORT) serving the frontend ..."
(
    cd "$BACKEND"
    export PYTHONUNBUFFERED=1
    export IACORE_URL="http://localhost:8001"
    export CORS_ORIGINS="*"
    export FRONTEND_DIST="$DIST"
    # This install's own settings, kept out of the repo: e.g. TRUSTED_PROXIES=<the office
    # nginx's LAN address> once Pilot is published through it (docs/PUBLIC_ACCESS.md).
    PILOT_ENV="${PILOT_ENV:-$HOME/.pilot/pilot.env}"
    if [ -f "$PILOT_ENV" ]; then set -a; . "$PILOT_ENV"; set +a; fi
    exec .venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port "$HTTPS_PORT" \
        --ssl-keyfile "$KEY" --ssl-certfile "$CRT"
) > >(sed -u 's/^/[backend] /') 2>&1 &
pids+=($!)

APP_URL="https://localhost:$HTTPS_PORT/"

# --- 7) Open the app in this PC's browser ------------------------------------
# There is no separate /monitor page any more: it was folded into Live, which now
# has a source picker — "My camera", "Robot camera", "View only". The last one is
# the old monitor: a read-only mirror of whatever the phone is streaming. Nothing
# is captured or streamed until you pick a source, so opening this is free. We
# wait for the HTTPS backend to answer and then open it. Best-effort: with no
# browser/graphical environment nothing happens (the URL is still printed below).
#
# DETACHED, in a session of its own (setsid). Started as a plain background job, a browser that
# was not already running became part of THIS terminal's process group — so the Ctrl+C that
# stops the stack (or closing the terminal: SIGHUP) reached it too, and it quit with every tab
# the user had open (2026-10-16). setsid takes it out of the group and the session, so no
# signal meant for these services can reach it.
detached() {
    if have setsid; then setsid -f "$@" >/dev/null 2>&1 </dev/null
    else nohup "$@" >/dev/null 2>&1 </dev/null & fi
}
open_browser() {
    local url="$1"
    if have xdg-open;        then detached xdg-open        "$url"
    elif have gio;           then detached gio open        "$url"
    elif have sensible-browser; then detached sensible-browser "$url"
    else return 1; fi
}
(
    # Wait (up to ~20s) for the backend to answer over HTTPS (self-signed cert
    # -> curl -k). Only then open it, so we don't hit it before it is up.
    # /api/auth/state, not /api/health: health needs a signed-in session, so the probe
    # got 401 on every try, logged it, and always waited the full 20 s.
    for _ in $(seq 1 40); do
        curl -k -fsS --max-time 2 "https://localhost:$HTTPS_PORT/api/auth/state" >/dev/null 2>&1 && break
        sleep 0.5
    done
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && open_browser "$APP_URL"; then
        info "App opened in the browser: $APP_URL"
    else
        warn "Could not open the browser automatically. Open it by hand: $APP_URL"
    fi
) &

printf '\n'
ok 'PHONE MODE READY.'
printf '\n'
printf "  From the phone (same network/WiFi as the PC), open:\n"
printf "        ${C_GRN}https://%s:%s${C_OFF}\n" "$ip" "$HTTPS_PORT"
printf '\n'
printf "  On THIS PC the app opens on its own, or open it by hand:\n"
printf "        ${C_GRN}%s${C_OFF}\n" "$APP_URL"
printf "  Nothing is captured until you pick a source on the Live page. To watch what\n"
printf "  the phone is streaming, press 'View only' (that is the old monitor).\n"
printf '\n'
printf "  The phone will warn 'connection not secure' (self-signed cert):\n"
printf "    - Android/Chrome: 'Advanced' -> 'Continue'.\n"
printf "    - iPhone/Safari:  'Show details' -> 'visit this website'.\n"
printf '\n'
printf "  Requirements: PC and phone on the SAME network; grant camera permission on open.\n"
printf "  Below, each service's logs stream LIVE (GET/POST, connections),\n"
printf "  prefixed with [iacore] / [backend]. To stop everything: Ctrl+C here.\n"
printf '\n'

# Wait for the processes; if one dies, the trap cleans up the other.
wait
