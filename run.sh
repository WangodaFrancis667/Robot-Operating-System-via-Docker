#!/usr/bin/env bash
# =============================================================================
# run.sh — ROS 2 Jazzy Docker Helper (Linux / X11 Forwarding)
# =============================================================================
# Manages the full lifecycle of your ROS 2 Docker development environment.
#
# Usage:
#   ./run.sh [command]
#
# Commands:
#   start   — Grant X11 access, build (if needed), launch container & open shell
#   shell   — Open an interactive shell in the already-running container
#   build   — Force-rebuild the Docker image from scratch
#   stop    — Stop and remove the container (data in ./src is preserved)
#   status  — Show the current state of the container
#   logs    — Tail the container logs
#   gui     — Show GUI diagnostic info and tips
#   help    — Show this help message (default)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour palette (graceful fallback if terminal has no colour support)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Script & project locations
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
GPU_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.gpu.yml"
CONTAINER_NAME="ros_jazzy_dev"
SERVICE_NAME="ros_dev"
SRC_DIR="${SCRIPT_DIR}/src"
IMAGE_NAME="ros2-jazzy-dev:latest"

# COMPOSE_ARGS is built dynamically by setup_gpu() — used in place of
# bare '-f ${COMPOSE_FILE}' throughout so the GPU override is included
# only when /dev/dri is present.
COMPOSE_ARGS=("-f" "${COMPOSE_FILE}")

# ---------------------------------------------------------------------------
# GPU detection
#
# If /dev/dri exists the docker-compose.gpu.yml override is appended to
# COMPOSE_ARGS so Mesa can use hardware OpenGL.
# If /dev/dri is absent (Docker Desktop VM, NVIDIA without DRI, or no GPU)
# we fall back to Mesa llvmpipe by injecting LIBGL_ALWAYS_SOFTWARE=1 into
# the container environment via a temporary override written to /tmp.
# ---------------------------------------------------------------------------
setup_gpu() {
    COMPOSE_ARGS=("-f" "${COMPOSE_FILE}")

    # Check for an actual DRI device node (renderD* or card*), not just the
    # directory.  /dev/dri can exist as an empty directory on systems where
    # the GPU driver isn't loaded or inside Docker Desktop's VM, which causes
    # Docker to fail with "no such file or directory" when trying to pass it.
    local dri_device
    dri_device=$(find /dev/dri -maxdepth 1 \( -name 'renderD*' -o -name 'card*' \) 2>/dev/null | head -1)

    if [ -n "${dri_device}" ]; then
        COMPOSE_ARGS+=("-f" "${GPU_COMPOSE_FILE}")
        success "GPU device (${dri_device}) found — hardware OpenGL enabled."
    else
        warn "No /dev/dri device — using Mesa llvmpipe software rendering."
        warn "(Docker Desktop VM, NVIDIA proprietary, or no DRI-capable GPU)"
        # Inject software-rendering env via an ephemeral override
        local sw_override="/tmp/ros2_docker_sw_render.yml"
        cat > "${sw_override}" <<'EOF'
services:
  ros_dev:
    environment:
      - LIBGL_ALWAYS_SOFTWARE=1
      - GALLIUM_DRIVER=llvmpipe
      - LIBGL_DRI3_DISABLE=1
      - LP_NUM_THREADS=4
EOF
        COMPOSE_ARGS+=("-f" "${sw_override}")
    fi
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
check_docker() {
    if ! command -v docker &>/dev/null; then
        die "Docker is not installed or not in PATH.\n  Install: https://docs.docker.com/desktop/"
    fi
    if ! docker info &>/dev/null; then
        die "Docker daemon is not running.\n  Start Docker Desktop and try again."
    fi
    success "Docker is running."
}

check_registry_dns() {
    # Build pulls the base image via Docker daemon/buildkit. If host DNS
    # cannot resolve Docker Hub, fail early with a clear diagnosis.
    if getent hosts registry-1.docker.io &>/dev/null; then
        success "Docker Hub DNS check passed (registry-1.docker.io resolves)."
    else
        warn "DNS could not resolve registry-1.docker.io from this host."
        warn "Build may fail while pulling base images from Docker Hub."
    fi
}

build_image() {
    local no_cache="${1:-false}"
    local build_log
    build_log="$(mktemp /tmp/ros2_build.XXXXXX.log)"

    info "Running compose build..."
    if [ "${no_cache}" = "true" ]; then
        if docker compose -f "${COMPOSE_FILE}" build --no-cache >"${build_log}" 2>&1; then
            cat "${build_log}"
            rm -f "${build_log}"
            return 0
        fi
    else
        if docker compose -f "${COMPOSE_FILE}" build >"${build_log}" 2>&1; then
            cat "${build_log}"
            rm -f "${build_log}"
            return 0
        fi
    fi

    cat "${build_log}"

    if grep -Eqi "registry-1\.docker\.io|lookup .*docker\.io|Temporary failure in name resolution|i/o timeout|no such host" "${build_log}"; then
        warn "Detected Docker Hub DNS/lookup failure during compose build."
        warn "Retrying with direct 'docker build --network=host' fallback..."

        if [ "${no_cache}" = "true" ]; then
            docker build --network=host --no-cache -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
        else
            docker build --network=host -t "${IMAGE_NAME}" -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
        fi
    else
        rm -f "${build_log}"
        return 1
    fi

    rm -f "${build_log}"
}

# ---------------------------------------------------------------------------
# X11 forwarding helpers
#
# Docker Desktop for Linux runs inside a VM.  The host /tmp is NOT shared
# into the VM by default, so mounting /tmp/.X11-unix fails with:
#   "path /tmp/.X11-unix is not shared from the host"
#
# Detection: `docker context show` returns "desktop-linux" for Docker Desktop.
#
# Fix: create a socat bridge that re-exposes the X11 socket from $HOME
# (which Docker Desktop shares automatically) and mount that instead.
# If socat is not installed, print clear instructions.
# ---------------------------------------------------------------------------
X11_BRIDGE_DIR="${HOME}/.x11-bridge"
X11_BRIDGE_PID_FILE="${X11_BRIDGE_DIR}/.socat.pid"
X11_SOCKET_DIR="/tmp/.X11-unix"   # default (native Docker Engine)

is_docker_desktop() {
    docker context show 2>/dev/null | grep -qi 'desktop-linux'
}

_x11_disp_num() {
    # Extract the display number from $DISPLAY (e.g. ":0" → "0", ":1.0" → "1")
    local d="${DISPLAY:-:0}"
    d="${d##*:}"   # remove up to and including ':'
    echo "${d%%.*}" # remove screen suffix
}

setup_x11() {
    # Always grant xhost access first
    if command -v xhost &>/dev/null; then
        xhost +local:root >/dev/null 2>&1 \
            && success "X11 access granted (xhost +local:root)." \
            || warn "xhost failed — GUI apps may not appear on your display."
    else
        warn "xhost not found. Install x11-xserver-utils for best results."
    fi

    if ! is_docker_desktop; then
        # Native Docker Engine — direct Unix socket mount works
        export X11_SOCKET_DIR="/tmp/.X11-unix"
        return 0
    fi

    # ---- Docker Desktop for Linux ----------------------------------------
    warn "Docker Desktop detected. /tmp/.X11-unix cannot be mounted directly."

    if ! command -v socat &>/dev/null; then
        warn "'socat' is not installed. Cannot create X11 bridge automatically."
        warn ""
        warn "To fix, choose ONE option:"
        warn "  Option A (recommended): install socat and retry:"
        warn "    sudo apt install socat && ./run.sh start"
        warn ""
        warn "  Option B: add /tmp to Docker Desktop file sharing:"
        warn "    Docker Desktop → Settings → Resources → File Sharing → add /tmp"
        warn "    Then restart Docker Desktop and run ./run.sh start again."
        export X11_SOCKET_DIR="/tmp/.X11-unix"  # will fail cleanly with a clear message
        return 1
    fi

    # Create bridge directory inside $HOME (Docker Desktop shares $HOME by default)
    mkdir -p "${X11_BRIDGE_DIR}"
    chmod 1777 "${X11_BRIDGE_DIR}"

    local disp="$(_x11_disp_num)"
    local host_socket="/tmp/.X11-unix/X${disp}"
    local bridge_socket="${X11_BRIDGE_DIR}/X${disp}"

    if [ ! -S "${host_socket}" ]; then
        warn "X11 socket ${host_socket} not found. Is DISPLAY=${DISPLAY:-:0} correct?"
        export X11_SOCKET_DIR="/tmp/.X11-unix"
        return 1
    fi

    # Kill any stale bridge from a previous run
    teardown_x11_bridge

    # Remove stale socket file if present
    rm -f "${bridge_socket}" 2>/dev/null || true

    # Start the socat bridge: listen on $HOME/.x11-bridge/X<n>, forward to real socket
    socat \
        "UNIX-LISTEN:${bridge_socket},fork,mode=777,unlink-early" \
        "UNIX-CONNECT:${host_socket}" \
        >/dev/null 2>&1 &
    local socat_pid=$!
    echo "${socat_pid}" > "${X11_BRIDGE_PID_FILE}"

    # Wait briefly for the socket to appear
    local waited=0
    while [ ! -S "${bridge_socket}" ] && [ ${waited} -lt 20 ]; do
        sleep 0.1
        waited=$(( waited + 1 ))
    done

    if [ ! -S "${bridge_socket}" ]; then
        warn "socat bridge did not start in time. Falling back to direct mount (may fail)."
        export X11_SOCKET_DIR="/tmp/.X11-unix"
        return 1
    fi

    export X11_SOCKET_DIR="${X11_BRIDGE_DIR}"
    success "X11 bridge created: ${bridge_socket} → ${host_socket} (PID ${socat_pid})"
}

teardown_x11_bridge() {
    if [ -f "${X11_BRIDGE_PID_FILE}" ]; then
        local old_pid
        old_pid=$(cat "${X11_BRIDGE_PID_FILE}" 2>/dev/null || true)
        if [ -n "${old_pid}" ] && kill -0 "${old_pid}" 2>/dev/null; then
            kill "${old_pid}" 2>/dev/null || true
        fi
        rm -f "${X11_BRIDGE_PID_FILE}" 2>/dev/null || true
    fi
    # Also clean up any stale socat processes for this bridge dir
    pkill -f "socat.*x11-bridge" 2>/dev/null || true
}

ensure_src_dir() {
    if [ ! -d "${SRC_DIR}" ]; then
        info "Creating ./src directory for your ROS 2 packages..."
        mkdir -p "${SRC_DIR}"
        success "Created ${SRC_DIR}"
    fi
}

# ---------------------------------------------------------------------------
# Command implementations
# ---------------------------------------------------------------------------
cmd_help() {
    echo ""
    echo -e "${BOLD}ROS 2 Jazzy Cross-Platform Docker Helper${RESET}"
    echo ""
    echo -e "  ${CYAN}./run.sh start${RESET}   — Build (if needed) & start container, then open shell"
    echo -e "  ${CYAN}./run.sh shell${RESET}   — Attach an interactive shell to the running container"
    echo -e "  ${CYAN}./run.sh build${RESET}   — Force-rebuild the Docker image from scratch"
    echo -e "  ${CYAN}./run.sh stop${RESET}    — Stop & remove the container (./src data preserved)"
    echo -e "  ${CYAN}./run.sh status${RESET}  — Show current container state"
    echo -e "  ${CYAN}./run.sh logs${RESET}    — Tail container logs (Ctrl-C to exit)"
    echo -e "  ${CYAN}./run.sh gui${RESET}     — Show GUI access info and diagnostic tips"
    echo -e "  ${CYAN}./run.sh help${RESET}    — Show this message"
    echo ""
    echo -e "  ${BOLD}GUI (X11 forwarding — native windows on host):${RESET}"
    echo -e "    ${CYAN}rv${RESET}  —  rviz2   ${CYAN}rq${RESET}  —  rqt   ${CYAN}gz${RESET}  —  Gazebo Sim"
    echo ""
}

cmd_build() {
    check_docker
    check_registry_dns
    info "Building Docker image '${IMAGE_NAME}' (this takes a few minutes on first run)..."
    build_image true
    success "Image built successfully."
}

cmd_start() {
    check_docker
    check_registry_dns
    ensure_src_dir

    if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
        info "Image not found — building for the first time (this may take 5–10 min)..."
        build_image false
    fi

    info "Setting up X11 forwarding..."
    setup_x11

    info "Detecting GPU capabilities..."
    setup_gpu

    info "Starting container '${CONTAINER_NAME}'..."
    docker compose "${COMPOSE_ARGS[@]}" up -d

    sleep 1

    success "Container is up."
    echo ""
    echo -e "  ${BOLD}GUI apps open as native windows on your desktop:${RESET}"
    echo -e "    ${CYAN}rv${RESET}  —  RViz2   ${CYAN}rq${RESET}  —  rqt   ${CYAN}gz${RESET}  —  Gazebo"
    echo ""
    info "Opening interactive shell — type 'exit' to leave (container keeps running)."
    echo ""

    cmd_shell
}

cmd_shell() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        die "Container '${CONTAINER_NAME}' is not running.\n  Run './run.sh start' first."
    fi
    docker compose -f "${COMPOSE_FILE}" exec -u ros "${SERVICE_NAME}" bash --login -i
}

cmd_stop() {
    check_docker
    info "Stopping container '${CONTAINER_NAME}'..."

    local compose_resources
    compose_resources="$(docker compose -f "${COMPOSE_FILE}" ps -q 2>/dev/null || true)"

    if [ -n "${compose_resources}" ]; then
        docker compose -f "${COMPOSE_FILE}" down
    else
        info "No running compose resources found for this project."
    fi

    xhost -local:root >/dev/null 2>&1 || true
    teardown_x11_bridge
    rm -f /tmp/ros2_docker_sw_render.yml 2>/dev/null || true
    success "Container stopped and removed."
}

cmd_status() {
    check_docker
    echo ""
    echo -e "${BOLD}Container status:${RESET}"
    docker compose -f "${COMPOSE_FILE}" ps
    echo ""
}

cmd_logs() {
    check_docker
    info "Tailing logs for '${CONTAINER_NAME}' (Ctrl-C to exit)..."
    docker compose -f "${COMPOSE_FILE}" logs -f
}

cmd_gui() {
    echo ""
    info "GUI uses X11 forwarding — apps open as native windows on your host desktop."
    echo ""
    echo -e "  ${CYAN}Host prerequisite${RESET}"
    echo -e "    X11 access is granted automatically by './run.sh start'."
    echo -e "    To grant manually:  ${CYAN}xhost +local:root${RESET}"
    echo -e "    Your host DISPLAY : ${CYAN}${DISPLAY:-not set}${RESET}"
    echo ""
    info "Run GUI apps from the container shell:"
    echo -e "  ${CYAN}xeyes${RESET}               — Basic X11 connectivity test"
    echo -e "  ${CYAN}glxgears${RESET}             — OpenGL test (hardware GL or Mesa llvmpipe)"
    echo -e "  ${CYAN}glxinfo | head -30${RESET}   — Check OpenGL renderer and version"
    echo -e "  ${CYAN}rv${RESET}                   — RViz2"
    echo -e "  ${CYAN}rq${RESET}                   — rqt"
    echo -e "  ${CYAN}gz${RESET}                   — Gazebo Harmonic Sim"
    echo ""
    warn "Troubleshooting:"
    warn "  'cannot open display'    → run on host:  xhost +local:root"
    warn "  'could not connect'      → check DISPLAY is set:  echo \$DISPLAY"
    warn "  Black/blank window       → OpenGL issue; try inside container:"
    warn "                              export LIBGL_ALWAYS_SOFTWARE=1 && gz"
    warn "  Inside container checks:"
    warn "    echo \$DISPLAY          — must match host (e.g. :0 or :1)"
    warn "    xdpyinfo | head -5     — verifies X11 connection"
    warn "    glxinfo | grep renderer"
    echo ""
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
COMMAND="${1:-help}"

case "${COMMAND}" in
    start)          cmd_start  ;;
    shell)          cmd_shell  ;;
    build)          cmd_build  ;;
    stop)           cmd_stop   ;;
    status)         cmd_status ;;
    logs)           cmd_logs   ;;
    gui)            cmd_gui    ;;
    help|--help|-h) cmd_help   ;;
    *)
        error "Unknown command: '${COMMAND}'"
        cmd_help
        exit 1
        ;;
esac