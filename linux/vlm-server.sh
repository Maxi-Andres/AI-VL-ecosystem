#!/usr/bin/env bash
# =============================================================================
#  vlm-server.sh — serve the VLM with llama-server, vision encoder ON THE GPU.
#
#  Why not Ollama: Ollama 0.30.6 runs qwen3-vl's vision encoder on the CPU (it starts
#  its own llama-server with --no-mmproj-offload). On the RTX 5060 that cost 6.4 s per
#  768 px photo; here it is ~0.1 s. Full story: AI-VL-core/src/vlm_common.py, top.
#
#  run.sh starts this with the app and stops it with the app; it can also be run by
#  hand (e.g. for the benchmark):
#
#      ./vlm-server.sh                      # the model in AI-VL-core/config.json
#      ./vlm-server.sh MODEL.gguf MMPROJ.gguf [ALIAS]
#
#  Env: VLM_PORT (8081), VLM_CTX (4096), VLM_MODEL + VLM_MMPROJ (another model for this run
#  instead of config.json's, paths relative to AI-VL-core — e.g. the 2B to try something with
#  more room; the alias is the file name), LLAMA_SERVER (binary; default: one on PATH,
#  else the one Ollama ships in /usr/local/lib/ollama), VLM_IMAGE_MIN_TOKENS (the
#  fewest tokens a photo may become; default: the model's own, see below), VLM_NGL
#  (layers on the GPU, 99 = all; lower only to squeeze in a model that does not fit).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -d "$ROOT/AI-VL-core" ] || ROOT="$(dirname "$ROOT")"
CORE="$ROOT/AI-VL-core"
PORT="${VLM_PORT:-8081}"
CTX="${VLM_CTX:-4096}"

# config.json merged with iacore's defaults (vlm_common.load_config), one value per key.
config() {
    local py="$CORE/.venv/bin/python"
    [ -x "$py" ] || py=python3
    (cd "$CORE/src" && "$py" -c 'import sys; from vlm_common import load_config
c = load_config(); print(" ".join(str(c.get(k) or "") for k in sys.argv[1:]))' "$@")
}

# --- Which model: arguments, else config.json (paths relative to AI-VL-core) ---
if [ $# -ge 2 ]; then
    MODEL="$1"; MMPROJ="$2"; ALIAS="${3:-$(basename "$1" .gguf)}"
elif [ -n "${VLM_MODEL:-}" ] && [ -n "${VLM_MMPROJ:-}" ]; then
    MODEL="$VLM_MODEL"; MMPROJ="$VLM_MMPROJ"; ALIAS="$(basename "$VLM_MODEL" .gguf)"
    case "$MODEL" in /*) ;; *) MODEL="$CORE/$MODEL" ;; esac
    case "$MMPROJ" in /*) ;; *) MMPROJ="$CORE/$MMPROJ" ;; esac
else
    read -r MODEL MMPROJ ALIAS < <(config llamacpp_model llamacpp_mmproj llamacpp_alias)
    case "$MODEL" in /*) ;; *) MODEL="$CORE/$MODEL" ;; esac
    case "$MMPROJ" in /*) ;; *) MMPROJ="$CORE/$MMPROJ" ;; esac
fi

# --image-min-tokens: a small photo is upscaled to at least this many tokens. Ollama
# forces 1024; the model's own floor is lower, so a 768 px frame becomes ~430 tokens
# and small print reads worse. The env wins; else, when the model also comes from
# config.json, its llamacpp_image_min_tokens (explicit model arguments skip config.json
# entirely, so a benchmark row is never tuned by the app's settings).
if [ -z "${VLM_IMAGE_MIN_TOKENS+x}" ] && [ $# -lt 2 ]; then
    VLM_IMAGE_MIN_TOKENS="$(config llamacpp_image_min_tokens)"
fi
EXTRA=()
[ -n "${VLM_IMAGE_MIN_TOKENS:-}" ] && EXTRA+=(--image-min-tokens "$VLM_IMAGE_MIN_TOKENS")

for f in "$MODEL" "$MMPROJ"; do
    [ -s "$f" ] || { echo "vlm-server: missing $f (run linux/install.sh)" >&2; exit 2; }
done

# --- Which binary -------------------------------------------------------------
BIN="${LLAMA_SERVER:-$(command -v llama-server || true)}"
[ -n "$BIN" ] || BIN=/usr/local/lib/ollama/llama-server
[ -x "$BIN" ] || { echo "vlm-server: no llama-server (install llama.cpp or Ollama)" >&2; exit 2; }

# Ollama's copy loads its CUDA backend from a sibling folder it would normally point it
# at itself: without these it says "no usable GPU found" and runs everything on the CPU.
LIBDIR="$(dirname "$BIN")"
if [ -d "$LIBDIR/cuda_v12" ] || [ -d "$LIBDIR/cuda_v13" ]; then
    cuda_major="$(nvidia-smi 2>/dev/null | grep -o 'CUDA Version: [0-9]*' | grep -o '[0-9]*$' || echo 0)"
    CUDA_DIR="$LIBDIR/cuda_v12"
    if [ "${cuda_major:-0}" -ge 13 ] && [ -f "$LIBDIR/cuda_v13/libggml-cuda.so" ]; then
        CUDA_DIR="$LIBDIR/cuda_v13"
    fi
    export LD_LIBRARY_PATH="$CUDA_DIR:$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export GGML_BACKEND_PATH="$CUDA_DIR/libggml-cuda.so"
fi

# -ngl 99: every layer on the GPU (VLM_NGL lowers it). The vision encoder goes there
# too: llama-server offloads the --mmproj by default, which is the whole point of this
# script.
# -np 1: one request at a time, one KV cache — the 8 GB card is shared with YOLO.
exec "$BIN" --model "$MODEL" --mmproj "$MMPROJ" --alias "$ALIAS" \
    --host 127.0.0.1 --port "$PORT" -c "$CTX" -ngl "${VLM_NGL:-99}" -np 1 \
    --flash-attn auto --no-webui --offline "${EXTRA[@]}"
