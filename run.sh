#!/usr/bin/env bash
set -euo pipefail

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
GPU_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.gpu.yml"
CONTAINER_NAME="ros2_jazzy_sim"
SERVICE_NAME="ros_dev"
SRC_DIR="${SCRIPT_DIR}/src"
COMPOSE_ARGS=("-f" "${COMPOSE_FILE}")
SW_OVERRIDE="/tmp/ros2_sim_sw.yml"
MESA_OVERRIDE="/tmp/ros2_sim_mesa.yml"

check_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed or not in PATH."
  docker info >/dev/null 2>&1 || die "Docker daemon is not running."
  success "Docker is running."
}

ensure_native_linux() {
  local os="$(uname -s)"
  [ "${os}" = "Linux" ] || die "This stack is tuned for native Linux hosts."
}

ensure_src_dir() {
  mkdir -p "${SRC_DIR}"
}

setup_x11() {
  [ -n "${DISPLAY:-}" ] || die "DISPLAY is not set on the host."
  [ -d /tmp/.X11-unix ] || die "/tmp/.X11-unix is missing on the host."
  if command -v xhost >/dev/null 2>&1; then
    xhost +SI:localuser:root >/dev/null 2>&1 || true
    xhost +SI:localuser:"$(id -un)" >/dev/null 2>&1 || true
    success "Granted X11 access for local root and current user."
  else
    warn "xhost not found; GUI applications may fail."
  fi
}

cleanup_temp_overrides() {
  rm -f "${SW_OVERRIDE}" "${MESA_OVERRIDE}"
}

setup_rendering() {
  cleanup_temp_overrides
  COMPOSE_ARGS=("-f" "${COMPOSE_FILE}")

  if command -v nvidia-smi >/dev/null 2>&1 && docker info 2>/dev/null | grep -qi 'nvidia'; then
    COMPOSE_ARGS+=("-f" "${GPU_COMPOSE_FILE}")
    success "NVIDIA runtime detected; enabling GPU override."
    return 0
  fi

  if compgen -G '/dev/dri/renderD*' >/dev/null 2>&1; then
    local video_gid render_gid
    video_gid="$(getent group video | cut -d: -f3 || true)"
    render_gid="$(getent group render | cut -d: -f3 || true)"
    cat > "${MESA_OVERRIDE}" <<EOM
services:
  ros_dev:
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "${video_gid:-44}"
      - "${render_gid:-109}"
EOM
    COMPOSE_ARGS+=("-f" "${MESA_OVERRIDE}")
    success "DRI devices detected; enabling Mesa hardware rendering."
    return 0
  fi

  cat > "${SW_OVERRIDE}" <<'EOM'
services:
  ros_dev:
    environment:
      LIBGL_ALWAYS_SOFTWARE: "1"
      GALLIUM_DRIVER: llvmpipe
EOM
  COMPOSE_ARGS+=("-f" "${SW_OVERRIDE}")
  warn "No NVIDIA runtime or /dev/dri found; using software rendering."
}

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

cmd_build() {
  check_docker
  ensure_native_linux
  ensure_src_dir
  setup_rendering
  compose build --pull --no-cache
}

cmd_start() {
  check_docker
  ensure_native_linux
  ensure_src_dir
  setup_x11
  setup_rendering
  compose up -d --build
  success "Container is up."
  echo ""
  echo "Helpers inside the container: rv | gzs | wb"
  echo ""
  cmd_shell
}

cmd_shell() {
  docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" || die "Container is not running. Start it first."
  docker exec -it -u ros "${CONTAINER_NAME}" bash --login -i
}

cmd_stop() {
  check_docker
  setup_rendering || true
  compose down --remove-orphans || true
  cleanup_temp_overrides
  success "Container stopped."
}

cmd_status() {
  check_docker
  setup_rendering
  compose ps
}

cmd_logs() {
  check_docker
  setup_rendering
  compose logs -f
}

cmd_gui() {
  cat <<MSG
Host checks:
  echo \$DISPLAY
  xhost

Container GUI tests:
  xeyes
  glxinfo -B
  rv
  gzs shapes.sdf
  wb

ROS simulator examples:
  ros2 launch webots_ros2_universal_robot multirobot_launch.py
MSG
}

cmd_help() {
  cat <<MSG
Usage: ./run.sh <command>

Commands:
  start   Build and start the simulator container, then open a shell
  shell   Open a shell in the running container
  build   Rebuild the image from scratch
  stop    Stop the running container
  status  Show compose status
  logs    Tail logs
  gui     Show GUI and simulator test commands
  help    Show this help
MSG
}

case "${1:-help}" in
  start) cmd_start ;;
  shell) cmd_shell ;;
  build) cmd_build ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  gui) cmd_gui ;;
  help|--help|-h) cmd_help ;;
  *) die "Unknown command: ${1}" ;;
esac
