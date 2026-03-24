# =============================================================================
# ROS 2 Jazzy — Docker Development Image (Linux / X11 Forwarding)
# =============================================================================
# Base  : Official OSRF ROS 2 Jazzy Desktop (Ubuntu Noble 24.04)
#
# GUI Strategy — X11 Forwarding (native windows on host display):
#   The host X11 socket (/tmp/.X11-unix) is mounted into the container.
#   DISPLAY is passed from the host so every GUI app (Gazebo, RViz2, rqt)
#   opens as a real native window on the host desktop — no VNC, no browser,
#   no extra latency.
#
#   Stack:
#     - DISPLAY passed from host        → connects to host X11 server
#     - /tmp/.X11-unix socket mount     → X11 transport (Unix socket)
#     - QT_X11_NO_MITSHM=1              → disables SHM transport (not
#                                          available in containers)
#     - Mesa OpenGL (hardware or llvmpipe fallback) → handles GL calls
#
#   run.sh runs `xhost +local:root` before starting the container.
# =============================================================================

FROM osrf/ros:jazzy-desktop

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# DNS Configuration — ensure proper DNS resolution in container
# ---------------------------------------------------------------------------
RUN echo "nameserver 8.8.8.8" > /etc/resolv.conf.custom && \
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf.custom && \
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf.custom

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # --- X11 / virtual framebuffer ---
    x11-apps \
    x11-xserver-utils \
    xauth \
    dbus-x11 \
    # --- Qt xcb platform plugin runtime deps (Ubuntu Noble) ---
    # Without these Qt aborts with "could not load platform plugin xcb"
    libxcb-xinerama0 \
    libxcb-cursor0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-randr0 \
    libxcb-render-util0 \
    libxcb-shape0 \
    libxcb-xfixes0 \
    libxkbcommon-x11-0 \
    libx11-xcb1 \
    # --- Mesa software renderer (llvmpipe — OpenGL 4.5 capable) ---
    mesa-utils \
    libgl1 \
    libgl1-mesa-dri \
    libglu1-mesa \
    libegl-mesa0 \
    libegl1 \
    libglx-mesa0 \
    # --- ROS 2 toolchain ---
    python3-pip \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-vcstool \
    python3-argcomplete \
    ros-jazzy-ament-cmake \
    # --- Gazebo Harmonic + ROS 2 bridge ---
    ros-jazzy-ros-gz \
    # --- Developer utilities ---
    nano \
    vim \
    git \
    curl \
    wget \
    htop \
    tree \
    bash-completion \
    net-tools \
    iproute2 \
    iputils-ping \
    sudo \
    procps \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# rosdep initialisation
# Note: rosdep may show errors for ancient EOL distros (e.g., Fuerte) but
# successfully updates all current ROS 2 distros (Jazzy, Rolling, etc.)
# ---------------------------------------------------------------------------
RUN rosdep init 2>/dev/null || true \
    && (rosdep update || echo "WARN: rosdep update completed with some errors on EOL distros (safely ignored)")

# ---------------------------------------------------------------------------
# Developer user (UID/GID 1000) — avoids root-owned files in host volumes.
# Ubuntu Noble ships a default "ubuntu" user at UID 1000; we rename to "ros".
# ---------------------------------------------------------------------------
ARG USERNAME=ros
ARG USER_UID=1000
ARG USER_GID=1000

RUN existing_group="$(getent group  ${USER_GID} | cut -d: -f1 || true)" \
    && if   [ -z "$existing_group" ]; then \
         groupadd --gid ${USER_GID} ${USERNAME}; \
       elif [ "$existing_group" != "${USERNAME}" ]; then \
         groupmod -n ${USERNAME} "$existing_group"; \
       fi \
    && existing_user="$(getent passwd ${USER_UID} | cut -d: -f1 || true)" \
    && if   [ -z "$existing_user" ]; then \
         useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME}; \
       elif [ "$existing_user" != "${USERNAME}" ]; then \
         usermod -l ${USERNAME} -d /home/${USERNAME} -m "$existing_user"; \
       fi \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && (getent group render > /dev/null 2>&1 || groupadd --system render) \
    && usermod -aG video,render ${USERNAME}

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------
RUN mkdir -p /ros2_ws/src \
    && chown -R ${USERNAME}:${USERNAME} /ros2_ws

WORKDIR /ros2_ws

# ---------------------------------------------------------------------------
# System-wide GUI wrapper scripts — /usr/local/bin/ (works in all shell types)
#
# X11 forwarding: DISPLAY is inherited from the host via docker-compose.
# /dev/dri is mounted by docker-compose for hardware GPU access.
# Mesa auto-selects the best renderer: hardware GPU via DRI, or llvmpipe if
# no GPU device is available. No LIBGL_ALWAYS_SOFTWARE override needed.
# ---------------------------------------------------------------------------
RUN printf '%s\n' \
    '#!/bin/bash' \
    'export DISPLAY=${DISPLAY}' \
    'export __GLX_VENDOR_LIBRARY_NAME=mesa' \
    'export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json' \
    'export MESA_GL_VERSION_OVERRIDE=3.3' \
    'export MESA_GLSL_VERSION_OVERRIDE=330' \
    'export OGRE_RTT_MODE=Copy' \
    'export QT_QPA_PLATFORM=xcb' \
    'export QT_X11_NO_MITSHM=1' \
    'export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-ros}' \
    'mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"' \
    'exec rviz2 "$@"' \
    > /usr/local/bin/rv \
    && printf '%s\n' \
    '#!/bin/bash' \
    'export DISPLAY=${DISPLAY}' \
    'export __GLX_VENDOR_LIBRARY_NAME=mesa' \
    'export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json' \
    'export QT_QPA_PLATFORM=xcb' \
    'export QT_X11_NO_MITSHM=1' \
    'export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-ros}' \
    'mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"' \
    'exec rqt "$@"' \
    > /usr/local/bin/rq \
    && printf '%s\n' \
    '#!/bin/bash' \
    'export DISPLAY=${DISPLAY}' \
    'export __GLX_VENDOR_LIBRARY_NAME=mesa' \
    'export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json' \
    'export MESA_GL_VERSION_OVERRIDE=3.3' \
    'export MESA_GLSL_VERSION_OVERRIDE=330' \
    'export QT_QPA_PLATFORM=xcb' \
    'export QT_X11_NO_MITSHM=1' \
    'export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-ros}' \
    'mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"' \
    '# Gazebo Harmonic — dynamically include versioned gz-sim share directory' \
    '# so bundled textures/worlds are found (fixes "Could not resolve texture.png").' \
    '_GZ_SIM_SHARE=$(find /usr/share/gz -maxdepth 1 -type d -name "gz-sim*" 2>/dev/null | sort -V | tail -1)' \
    'export GZ_SIM_RESOURCE_PATH="${_GZ_SIM_SHARE:+${_GZ_SIM_SHARE}:}/usr/share/gz"' \
    'unset _GZ_SIM_SHARE' \
    'export GZ_VERSION="harmonic"' \
    'export IGN_GAZEBO_RESOURCE_PATH="${GZ_SIM_RESOURCE_PATH}"' \
    'GZ_BIN=$(command -v gz 2>/dev/null)' \
    'if [ -z "$GZ_BIN" ] || [ "$GZ_BIN" = "/usr/local/bin/gz" ]; then' \
    '    GZ_BIN=$(find /usr /opt -maxdepth 8 -name "gz" ! -path "/usr/local/bin/gz" -type f 2>/dev/null | head -1)' \
    'fi' \
    'if [ -z "$GZ_BIN" ]; then echo "Error: gz binary not found" >&2; exit 1; fi' \
    '# If user already typed "gz sim", do not prefix again (avoids "gz sim sim").' \
    'if [ "${1:-}" = "sim" ]; then exec "$GZ_BIN" "$@"; else exec "$GZ_BIN" sim "$@"; fi' \
    > /usr/local/bin/gz \
    && chmod +x /usr/local/bin/rv /usr/local/bin/rq /usr/local/bin/gz

# ---------------------------------------------------------------------------
# User shell environment — ~/.bashrc
# ---------------------------------------------------------------------------
RUN echo '' >> /home/${USERNAME}/.bashrc && \
    echo '# ── ROS 2 Jazzy ──────────────────────────────────────────────────────────' >> /home/${USERNAME}/.bashrc && \
    echo 'source /opt/ros/jazzy/setup.bash' >> /home/${USERNAME}/.bashrc && \
    echo 'source /ros2_ws/install/setup.bash 2>/dev/null || true' >> /home/${USERNAME}/.bashrc && \
    echo 'export ROS_DOMAIN_ID=0' >> /home/${USERNAME}/.bashrc && \
    echo 'export RCUTILS_COLORIZED_OUTPUT=1' >> /home/${USERNAME}/.bashrc && \
    echo '' >> /home/${USERNAME}/.bashrc && \
    echo '# ── Display / X11 forwarding ──────────────────────────────────────────────' >> /home/${USERNAME}/.bashrc && \
    echo '# DISPLAY is injected from the host. /dev/dri is mounted for GPU access.' >> /home/${USERNAME}/.bashrc && \
    echo '# Mesa auto-selects: hardware GPU (DRI) or llvmpipe fallback.' >> /home/${USERNAME}/.bashrc && \
    echo 'export MESA_GL_VERSION_OVERRIDE=3.3' >> /home/${USERNAME}/.bashrc && \
    echo 'export MESA_GLSL_VERSION_OVERRIDE=330' >> /home/${USERNAME}/.bashrc && \
    echo '' >> /home/${USERNAME}/.bashrc && \
    echo '# OGRE/RViz2 and Qt settings' >> /home/${USERNAME}/.bashrc && \
    echo 'export OGRE_RTT_MODE=Copy' >> /home/${USERNAME}/.bashrc && \
    echo 'export QT_QPA_PLATFORM=xcb' >> /home/${USERNAME}/.bashrc && \
    echo 'export QT_X11_NO_MITSHM=1' >> /home/${USERNAME}/.bashrc && \
    echo '' >> /home/${USERNAME}/.bashrc && \
    echo '# Gazebo Harmonic — dynamically include versioned gz-sim share directory' >> /home/${USERNAME}/.bashrc && \
    echo '# so bundled textures/worlds are found (fixes "Could not resolve texture.png").' >> /home/${USERNAME}/.bashrc && \
    echo '_GZ_SIM_SHARE=$(find /usr/share/gz -maxdepth 1 -type d -name "gz-sim*" 2>/dev/null | sort -V | tail -1)' >> /home/${USERNAME}/.bashrc && \
    echo 'export GZ_SIM_RESOURCE_PATH="${_GZ_SIM_SHARE:+${_GZ_SIM_SHARE}:}/usr/share/gz"' >> /home/${USERNAME}/.bashrc && \
    echo 'unset _GZ_SIM_SHARE' >> /home/${USERNAME}/.bashrc && \
    echo 'export GZ_VERSION="harmonic"' >> /home/${USERNAME}/.bashrc && \
    echo 'export IGN_GAZEBO_RESOURCE_PATH="${GZ_SIM_RESOURCE_PATH}"' >> /home/${USERNAME}/.bashrc && \
    echo '' >> /home/${USERNAME}/.bashrc && \
    echo 'export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-ros}' >> /home/${USERNAME}/.bashrc && \
    echo 'mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true' >> /home/${USERNAME}/.bashrc && \
    echo '' >> /home/${USERNAME}/.bashrc && \
    echo '# ── Colcon / ROS aliases ──────────────────────────────────────────────────' >> /home/${USERNAME}/.bashrc && \
    echo "alias cb='colcon build --symlink-install'" >> /home/${USERNAME}/.bashrc && \
    echo "alias ct='colcon test'" >> /home/${USERNAME}/.bashrc && \
    echo "alias cs='source install/setup.bash'" >> /home/${USERNAME}/.bashrc && \
    echo "alias rl='ros2 launch'" >> /home/${USERNAME}/.bashrc && \
    echo "alias rr='ros2 run'" >> /home/${USERNAME}/.bashrc && \
    echo "alias rt='ros2 topic'" >> /home/${USERNAME}/.bashrc && \
    echo "alias rn='ros2 node'" >> /home/${USERNAME}/.bashrc

# Root sessions (build-time checks)
RUN echo "source /opt/ros/jazzy/setup.bash" >> /root/.bashrc

# ---------------------------------------------------------------------------
# Gazebo Fuel cache config — pre-create the cache directory and config so
# that first-run Fuel lookups work correctly and cache lands in the right
# place for the ros user.  The config.yaml also records the cache path so
# Fuel never falls back to /root/.gz/fuel when running as the ros user.
# ---------------------------------------------------------------------------
RUN mkdir -p /home/${USERNAME}/.gz/fuel \
    && printf '%s\n' \
       '---' \
       'servers:' \
       '  - name: Gazebo Fuel' \
       '    url: https://fuel.gazebosim.org' \
       '' \
       'cache:' \
       '  path: /home/ros/.gz/fuel' \
       > /home/${USERNAME}/.gz/fuel/config.yaml \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.gz

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Note: Do NOT set USER here - entrypoint runs as root and drops to user

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]