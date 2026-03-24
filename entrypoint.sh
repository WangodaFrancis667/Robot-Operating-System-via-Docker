#!/bin/bash
# =============================================================================
# Container Entrypoint — ROS 2 Jazzy / X11 Forwarding Dev Environment
# =============================================================================
# Runs as root to configure the environment, then drops to the "ros" user.
#
# GUI: X11 forwarding — no Xvfb, no VNC, no noVNC.
#   DISPLAY and /tmp/.X11-unix are provided by docker-compose from the host.
#   run.sh runs `xhost +local:root` so the container can open windows on
#   the host desktop natively.
# =============================================================================

set -e

# ---------------------------------------------------------------------------
# 0. Core environment — guaranteed present for every child process.
#    DISPLAY is injected by docker-compose from the host X11 session.
#    /dev/dri is mounted by docker-compose for hardware GPU access.
# ---------------------------------------------------------------------------
export __GLX_VENDOR_LIBRARY_NAME=mesa
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json

# Tell OGRE/RViz2 that GL 3.3 is available (hardware or software).
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330

export QT_X11_NO_MITSHM=1

# OGRE/RViz2 and Qt settings
export OGRE_RTT_MODE=Copy
export QT_QPA_PLATFORM=xcb

# ---------------------------------------------------------------------------
# Gazebo Harmonic — include the versioned gz-sim share directory so bundled
# resources (worlds, textures) are resolved correctly.
# Without this, SystemPaths prints "Could not resolve file [texture.png]".
# ---------------------------------------------------------------------------
_GZ_SIM_SHARE=$(find /usr/share/gz -maxdepth 1 -type d -name 'gz-sim*' 2>/dev/null | sort -V | tail -1)
export GZ_SIM_RESOURCE_PATH="${_GZ_SIM_SHARE:+${_GZ_SIM_SHARE}:}/usr/share/gz"
unset _GZ_SIM_SHARE
export GZ_VERSION="harmonic"
export IGN_GAZEBO_RESOURCE_PATH="${GZ_SIM_RESOURCE_PATH}"

# XDG_RUNTIME_DIR — must be owned by the ros user (UID 1000), not root.
# Qt/QStandardPaths rejects directories not owned by the calling UID.
export XDG_RUNTIME_DIR=/tmp/runtime-ros
mkdir -p "$XDG_RUNTIME_DIR"
chown ros:ros "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Gazebo home — ensure the ros user can write logs, config, and fuel cache.
# The gz_fuel_cache named volume mounts at /home/ros/.gz/fuel as root-owned
# on first use; fix ownership here before dropping privileges.
mkdir -p /home/ros/.gz/sim
chown -R ros:ros /home/ros/.gz

# ---------------------------------------------------------------------------
# 1. Source ROS 2
# ---------------------------------------------------------------------------
source /opt/ros/jazzy/setup.bash

if [ -f "/ros2_ws/install/setup.bash" ]; then
    source /ros2_ws/install/setup.bash
fi

# ---------------------------------------------------------------------------
# 2. Welcome banner
# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     ROS 2 Jazzy — Docker Dev Environment (X11)          ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  ROS Distro : %-42s ║\n" "${ROS_DISTRO:-jazzy}"
printf "║  Workspace  : %-42s ║\n" "/ros2_ws"
printf "║  ROS Domain : %-42s ║\n" "${ROS_DOMAIN_ID:-0}"
printf "║  DISPLAY    : %-42s ║\n" "${DISPLAY:-not set}"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  GUI — windows open natively on the host desktop:       ║"
echo "║    rv  — rviz2       rq  — rqt       gz  — gz sim       ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  ROS 2 aliases:                                         ║"
echo "║    cb  — colcon build   cs  — source install/setup.bash ║"
echo "║    rl  — ros2 launch    rr  — ros2 run                  ║"
echo "║    rt  — ros2 topic     rn  — ros2 node                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  OpenGL: $(glxinfo -B 2>/dev/null | grep 'OpenGL renderer' || echo 'run: glxinfo -B')"
echo ""

# ---------------------------------------------------------------------------
# 3. Drop to interactive shell as the "ros" user.
#    -w passes key env vars so they are available in every shell opened.
# ---------------------------------------------------------------------------
if [ "$#" -eq 0 ] || [ "$1" = "bash" ]; then
    # Pass key env vars into the user shell explicitly
    exec su - ros --shell /bin/bash -w \
        DISPLAY,MESA_GL_VERSION_OVERRIDE,MESA_GLSL_VERSION_OVERRIDE,\
        OGRE_RTT_MODE,QT_QPA_PLATFORM,QT_X11_NO_MITSHM,XDG_RUNTIME_DIR,\
        GZ_SIM_RESOURCE_PATH,IGN_GAZEBO_RESOURCE_PATH,GZ_VERSION,\
        ROS_DOMAIN_ID,RCUTILS_COLORIZED_OUTPUT \
        -c 'exec bash --login -i'
else
    exec su - ros --shell /bin/bash -w \
        DISPLAY,MESA_GL_VERSION_OVERRIDE,MESA_GLSL_VERSION_OVERRIDE,\
        OGRE_RTT_MODE,QT_QPA_PLATFORM,QT_X11_NO_MITSHM,XDG_RUNTIME_DIR,\
        GZ_SIM_RESOURCE_PATH,IGN_GAZEBO_RESOURCE_PATH,GZ_VERSION,\
        ROS_DOMAIN_ID,RCUTILS_COLORIZED_OUTPUT \
        -c "exec $*"
fi