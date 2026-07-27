#!/usr/bin/env bash
# =============================================================================
#  run-with-robot.sh — THE single entry point to drive the robot by voice.
#  It makes sure EVERYTHING is operational, in order, and keeps it that way:
#    0) Pre-flight checks: Docker daemon, the devcontainer, the DDS network
#       interface (e.g. enp4s0 UP) and whether the robot answers on the LAN.
#    1) The unitree_ros2 devcontainer (started if down).
#    2) The robot_executor inside it — ALWAYS restarted fresh so the latest code
#       is loaded and no stale/wedged process lingers (a dead executor still
#       answers /health, so "already running" is never trusted).
#    3) The robot_camera_bridge inside it (idle until the UI turns the stream on).
#    4) A WATCHDOG that re-checks the executor + camera every few seconds and
#       restarts either one if it stops answering — so a crash self-recovers.
#    5) The AI-VL stack (iacore + backend HTTPS + monitor) on the host (blocks).
#  Ctrl+C shuts everything down (watchdog + container processes + AI-VL stack).
#
#  Requirements: the Go2 connected over ethernet (DDS interface UP) so it actually
#  moves; Docker running; AI-VL installed (linux/install.sh).
#
#  Optional overrides:
#    DRY_RUN=true  ./linux/run-with-robot.sh    # executor logs, does NOT move the robot
#    SAFE_MODE=true ./linux/run-with-robot.sh   # executor fallback (the page still overrides)
#    UNITREE_ROS2_DIR=/path/to/unitree_ros2 ./linux/run-with-robot.sh
#    DDS_IFACE=enp3s0 ./linux/run-with-robot.sh # override the checked network interface
#    NO_WATCHDOG=1 ./linux/run-with-robot.sh    # disable the auto-restart watchdog
# =============================================================================
set -uo pipefail

# Resolve paths (this launcher lives in linux/, next to run.sh).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIVL_RUN="$SELF/run.sh"
[ -f "$AIVL_RUN" ] || AIVL_RUN="$(dirname "$SELF")/linux/run.sh"
UNITREE_ROS2_DIR="${UNITREE_ROS2_DIR:-$HOME/Desktop/unitree_ros2}"
CONTAINER="${EXECUTOR_CONTAINER:-unitree_ros2_devcontainer-devcontainer-humble-1}"
EXEC_PORT="${EXECUTOR_PORT:-8090}"
CAM_PORT="${CAMERA_CONTROL_PORT:-8091}"
WATCH_INTERVAL="${WATCH_INTERVAL:-10}"   # seconds between watchdog health checks
WATCH_THRESHOLD="${WATCH_THRESHOLD:-3}"  # consecutive misses before a restart

info(){ printf '\033[36m[ run+robot ] %s\033[0m\n' "$*"; }
ok(){   printf '\033[32m[ run+robot ] %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m[ run+robot ] %s\033[0m\n' "$*"; }

# --- Pre-flight: docker + the AI-VL launcher ---------------------------------
command -v docker >/dev/null 2>&1 || { warn "docker not found."; exit 1; }
docker info >/dev/null 2>&1 || {
  warn "The Docker daemon is not responding. Start Docker and retry"
  warn "(e.g. 'sudo systemctl start docker', or add yourself to the 'docker' group)."
  exit 1
}
[ -f "$AIVL_RUN" ] || { warn "Cannot find AI-VL run.sh ($AIVL_RUN)."; exit 1; }
[ -f "$UNITREE_ROS2_DIR/setup.sh" ] || warn "No setup.sh under $UNITREE_ROS2_DIR (is UNITREE_ROS2_DIR right?)."

# The DDS network interface the robot is on. Read it from the robot's setup.sh
# (CYCLONEDDS_URI) so this check always matches what the executor actually uses;
# fall back to enp4s0. Override with DDS_IFACE=... .
if [ -z "${DDS_IFACE:-}" ]; then
  DDS_IFACE="$(grep -oE 'NetworkInterface name="[^"]+"' "$UNITREE_ROS2_DIR/setup.sh" 2>/dev/null \
                | head -1 | sed -E 's/.*name="([^"]+)".*/\1/')"
  DDS_IFACE="${DDS_IFACE:-enp4s0}"
fi
# The robot's wired IP, for a reachability probe (informational). Read from the
# executor .env if present, else the Go2 default.
ROBOT_IP="$(grep -E '^ROBOT_IP=' "$UNITREE_ROS2_DIR/robot_executor/.env" 2>/dev/null \
            | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
ROBOT_IP="${ROBOT_IP:-192.168.123.161}"

health(){    curl -fsS --max-time 2 "http://localhost:$EXEC_PORT/health" >/dev/null 2>&1; }
camhealth(){ curl -fsS --max-time 2 "http://localhost:$CAM_PORT/health" >/dev/null 2>&1; }

# --- 0) Robot link checks (warn only — DRY_RUN doesn't need the robot) --------
if command -v ip >/dev/null 2>&1; then
  if ip -brief link show "$DDS_IFACE" 2>/dev/null | grep -qw UP; then
    ok "DDS interface $DDS_IFACE is UP."
  else
    warn "DDS interface $DDS_IFACE is DOWN or missing — the robot won't receive commands."
    warn "Connect the Go2 ethernet (or set DDS_IFACE=... to the right NIC)."
  fi
fi
if [ "${DRY_RUN:-}" != "true" ]; then
  if ping -c1 -W1 "$ROBOT_IP" >/dev/null 2>&1; then
    ok "Robot reachable at $ROBOT_IP."
  else
    warn "Robot did not answer a ping at $ROBOT_IP (commands may not move it)."
  fi
fi

# --- 1) Devcontainer up ------------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  ok "Devcontainer already running."
else
  info "Starting the devcontainer…"
  docker start "$CONTAINER" >/dev/null 2>&1 \
    || docker compose -p unitree_ros2_devcontainer \
         -f "$UNITREE_ROS2_DIR/.devcontainer/docker-compose.yml" up -d \
    || { warn "Could not start the devcontainer."; exit 1; }
fi

# --- Start helpers (used at boot AND by the watchdog) ------------------------
# Only forward overrides that are actually set (don't clobber the .env with empties).
executor_env_args(){
  local a=()
  [ -n "${DRY_RUN:-}" ]   && a+=(-e "DRY_RUN=$DRY_RUN")
  [ -n "${SAFE_MODE:-}" ] && a+=(-e "SAFE_MODE=$SAFE_MODE")
  printf '%s\n' "${a[@]:-}"
}

start_executor(){
  # Kill any existing instance first so we always load the current code and never
  # inherit a wedged process (a dead executor keeps answering /health otherwise).
  # It runs as root in the container and can survive from a PREVIOUS run holding
  # the port, so kill it as root with SIGKILL — a plain SIGTERM did not reliably
  # free :$EXEC_PORT. The '[r]' bracket keeps the pattern from matching a shell.
  docker exec -u root "$CONTAINER" pkill -9 -f '[r]obot_executor_service\.py' >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do health || break; sleep 0.3; done
  mapfile -t env_args < <(executor_env_args)
  docker exec -d ${env_args[0]:+"${env_args[@]}"} "$CONTAINER" \
    bash -lc 'bash /workspace/robot_executor/run_executor.sh >/tmp/robot_executor.log 2>&1'
  for _ in $(seq 1 20); do health && return 0; sleep 1; done
  return 1
}

start_camera(){
  docker exec -u root "$CONTAINER" pkill -9 -f '[r]obot_camera_bridge\.py' >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do camhealth || break; sleep 0.3; done
  docker exec -d "$CONTAINER" \
    bash -lc 'bash /workspace/robot_camera_bridge/run_camera_bridge.sh >/tmp/robot_camera_bridge.log 2>&1'
  for _ in $(seq 1 20); do camhealth && return 0; sleep 1; done
  return 1
}

# --- 2) robot_executor inside the container (fresh) --------------------------
info "Starting robot_executor inside the container (fresh)…"
if start_executor; then
  ok "Executor OK on :$EXEC_PORT."
else
  warn "Executor did not answer. Log: docker exec $CONTAINER cat /tmp/robot_executor.log"
  warn "(Usually the Go2 isn't connected -> $DDS_IFACE DOWN, or a build/env error.)"
  docker exec "$CONTAINER" tail -n 15 /tmp/robot_executor.log 2>/dev/null | sed 's/^/    │ /' || true
fi

# --- 3) robot_camera_bridge inside the container (fresh) ---------------------
# Started but idle (streaming OFF): the "Use robot camera" button turns it on.
info "Starting robot_camera_bridge inside the container (fresh)…"
if start_camera; then
  ok "Camera bridge OK on :$CAM_PORT."
else
  warn "Camera bridge did not answer. Log: docker exec $CONTAINER cat /tmp/robot_camera_bridge.log"
  docker exec "$CONTAINER" tail -n 15 /tmp/robot_camera_bridge.log 2>/dev/null | sed 's/^/    │ /' || true
fi

# --- 4) Watchdog: keep the executor + camera alive ---------------------------
# The executor self-heals its ROS2 node in-process (a DDS blip never wedges it),
# so this only ever fires if a process actually dies/hangs. It waits for
# WATCH_THRESHOLD consecutive misses before restarting, to ignore brief hiccups.
WATCH_PID=""
watchdog(){
  local ef=0 cf=0
  while sleep "$WATCH_INTERVAL"; do
    if health; then ef=0; else
      ef=$((ef+1))
      if [ "$ef" -ge "$WATCH_THRESHOLD" ]; then
        warn "Executor unresponsive (${ef}x) — restarting…"
        start_executor && ok "Executor restarted." || warn "Executor restart failed."
        ef=0
      fi
    fi
    if camhealth; then cf=0; else
      cf=$((cf+1))
      if [ "$cf" -ge "$WATCH_THRESHOLD" ]; then
        warn "Camera bridge unresponsive (${cf}x) — restarting…"
        start_camera && ok "Camera bridge restarted." || warn "Camera bridge restart failed."
        cf=0
      fi
    fi
  done
}
if [ "${NO_WATCHDOG:-}" != "1" ]; then
  watchdog &
  WATCH_PID=$!
  ok "Watchdog on (every ${WATCH_INTERVAL}s, restart after ${WATCH_THRESHOLD} misses)."
fi

# --- 5) Stop everything on exit ----------------------------------------------
cleaned=0
cleanup(){
  [ "$cleaned" = 1 ] && return; cleaned=1
  printf '\n'; info "Stopping watchdog + robot_executor + robot_camera_bridge…"
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" >/dev/null 2>&1 || true
  # SIGKILL as root so nothing lingers on :$EXEC_PORT/:$CAM_PORT for the next run.
  docker exec -u root "$CONTAINER" pkill -9 -f '[r]obot_executor_service\.py' >/dev/null 2>&1 || true
  docker exec -u root "$CONTAINER" pkill -9 -f '[r]obot_camera_bridge\.py' >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

# --- 6) AI-VL stack (blocks; Ctrl+C stops everything) ------------------------
info "Starting AI-VL (iacore + backend + monitor). Ctrl+C stops EVERYTHING."
bash "$AIVL_RUN"
