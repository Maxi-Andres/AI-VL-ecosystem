#!/usr/bin/env bash
# =============================================================================
#  run-with-robot.sh — bring up EVERYTHING to drive the robot by voice:
#    1) the unitree_ros2 devcontainer (if down) + the robot_executor inside it,
#    2) the AI-VL stack (iacore + backend HTTPS + monitor) on the host.
#  Ctrl+C shuts everything down (the container executor + the AI-VL stack).
#
#  Requirements: the Go2 connected over ethernet (enp4s0 UP) so it actually moves;
#  Docker running; AI-VL installed (linux/install.sh).
#
#  Optional overrides:
#    DRY_RUN=true  ./linux/run-with-robot.sh    # executor logs, does NOT move the robot
#    SAFE_MODE=true ./linux/run-with-robot.sh   # executor fallback (the page still overrides)
#    UNITREE_ROS2_DIR=/path/to/unitree_ros2 ./linux/run-with-robot.sh
# =============================================================================
set -uo pipefail

# Resolve paths (this launcher lives in linux/, next to run.sh).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIVL_RUN="$SELF/run.sh"
[ -f "$AIVL_RUN" ] || AIVL_RUN="$(dirname "$SELF")/linux/run.sh"
UNITREE_ROS2_DIR="${UNITREE_ROS2_DIR:-$HOME/Desktop/unitree_ros2}"
CONTAINER="${EXECUTOR_CONTAINER:-unitree_ros2_devcontainer-devcontainer-humble-1}"
EXEC_PORT="${EXECUTOR_PORT:-8090}"

info(){ printf '\033[36m[ run+robot ] %s\033[0m\n' "$*"; }
ok(){   printf '\033[32m[ run+robot ] %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m[ run+robot ] %s\033[0m\n' "$*"; }

command -v docker >/dev/null 2>&1 || { warn "docker not found."; exit 1; }
[ -f "$AIVL_RUN" ] || { warn "Cannot find AI-VL run.sh ($AIVL_RUN)."; exit 1; }

health(){ curl -fsS --max-time 2 "http://localhost:$EXEC_PORT/health" >/dev/null 2>&1; }

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

# --- 2) robot_executor inside the container ----------------------------------
if health; then
  ok "Executor already running on :$EXEC_PORT."
else
  info "Starting robot_executor inside the container…"
  # Only forward overrides that are actually set (don't clobber the .env with empties).
  env_args=()
  [ -n "${DRY_RUN:-}" ]   && env_args+=(-e "DRY_RUN=$DRY_RUN")
  [ -n "${SAFE_MODE:-}" ] && env_args+=(-e "SAFE_MODE=$SAFE_MODE")
  docker exec -d ${env_args[@]+"${env_args[@]}"} "$CONTAINER" \
    bash -lc 'bash /workspace/robot_executor/run_executor.sh >/tmp/robot_executor.log 2>&1'
  for _ in $(seq 1 15); do health && break; sleep 1; done
  if health; then
    ok "Executor OK on :$EXEC_PORT."
  else
    warn "Executor did not answer. Log: docker exec $CONTAINER cat /tmp/robot_executor.log"
    warn "(Usually the Go2 isn't connected -> enp4s0 DOWN.)"
  fi
fi

# --- 3) Stop the executor on exit --------------------------------------------
cleaned=0
cleanup(){
  [ "$cleaned" = 1 ] && return; cleaned=1
  printf '\n'; info "Stopping robot_executor…"
  docker exec "$CONTAINER" pkill -f robot_executor_service.py >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

# --- 4) AI-VL stack (blocks; Ctrl+C stops everything) ------------------------
info "Starting AI-VL (iacore + backend + monitor). Ctrl+C stops EVERYTHING."
bash "$AIVL_RUN"
