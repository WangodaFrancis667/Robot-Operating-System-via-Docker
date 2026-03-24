FROM osrf/ros:jazzy-desktop

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    ROS_DISTRO=jazzy

ARG USERNAME=ros
ARG USER_UID=1000
ARG USER_GID=1000
ARG WEBOTS_VERSION=R2025a
ARG WEBOTS_DEB=webots_2025a_amd64.deb

RUN apt-get update && apt-get install -y --no-install-recommends \
    locales \
    ca-certificates \
    curl \
    wget \
    gnupg2 \
    lsb-release \
    sudo \
    git \
    nano \
    vim \
    htop \
    tree \
    bash-completion \
    iproute2 \
    iputils-ping \
    net-tools \
    procps \
    x11-apps \
    x11-xserver-utils \
    xauth \
    dbus-x11 \
    mesa-utils \
    libgl1 \
    libgl1-mesa-dri \
    libegl1 \
    libglu1-mesa \
    libx11-xcb1 \
    libxcb-cursor0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-randr0 \
    libxcb-render-util0 \
    libxcb-shape0 \
    libxcb-xfixes0 \
    libxcb-xinerama0 \
    libxkbcommon-x11-0 \
    libnss3 \
    libasound2t64 \
    libxtst6 \
    libxrender1 \
    libxi6 \
    libfontconfig1 \
    libfreetype6 \
    python3-pip \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-vcstool \
    python3-argcomplete \
    ros-dev-tools \
    ros-jazzy-ros-gz \
    ros-jazzy-ros-gz-sim \
    ros-jazzy-ros-gz-bridge \
    ros-jazzy-ros-gz-interfaces \
    ros-jazzy-webots-ros2 \
    ros-jazzy-rqt \
    && locale-gen en_US en_US.UTF-8 \
    && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Install a current Webots build that supports Ubuntu 24.04 and ROS 2 Jazzy.
RUN wget -O /tmp/${WEBOTS_DEB} https://github.com/cyberbotics/webots/releases/download/${WEBOTS_VERSION}/${WEBOTS_DEB} \
    && apt-get update \
    && apt-get install -y /tmp/${WEBOTS_DEB} \
    && rm -f /tmp/${WEBOTS_DEB} \
    && rm -rf /var/lib/apt/lists/*

RUN rosdep init 2>/dev/null || true && rosdep update

RUN set -eux; \
    existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1 || true)"; \
    existing_group="$(getent group "${USER_GID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_group}" ] && [ "${existing_group}" != "${USERNAME}" ]; then \
        groupmod -n "${USERNAME}" "${existing_group}"; \
    elif [ -z "${existing_group}" ]; then \
        groupadd --gid "${USER_GID}" "${USERNAME}"; \
    fi; \
    if id -u "${USERNAME}" >/dev/null 2>&1; then \
        usermod --uid "${USER_UID}" --gid "${USER_GID}" -m -d "/home/${USERNAME}" -s /bin/bash "${USERNAME}"; \
    elif [ -n "${existing_user}" ]; then \
        usermod -l "${USERNAME}" "${existing_user}"; \
        usermod --uid "${USER_UID}" --gid "${USER_GID}" -m -d "/home/${USERNAME}" -s /bin/bash "${USERNAME}"; \
    else \
        useradd --uid "${USER_UID}" --gid "${USER_GID}" -m -s /bin/bash "${USERNAME}"; \
    fi; \
    usermod -aG sudo,video,render "${USERNAME}"; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

RUN mkdir -p /ros2_ws/src /home/${USERNAME}/.cache/Cyberbotics /home/${USERNAME}/.config/Cyberbotics /home/${USERNAME}/.gz \
    && chown -R ${USERNAME}:${USERNAME} /ros2_ws /home/${USERNAME}

WORKDIR /ros2_ws

RUN cat > /usr/local/bin/rv <<'EOS'
#!/usr/bin/env bash
set -e
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
export QT_X11_NO_MITSHM=1
exec rviz2 "$@"
EOS
RUN cat > /usr/local/bin/gzs <<'EOS'
#!/usr/bin/env bash
set -e
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
export QT_X11_NO_MITSHM=1
exec gz sim "$@"
EOS
RUN cat > /usr/local/bin/wb <<'EOS'
#!/usr/bin/env bash
set -e
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
export QT_X11_NO_MITSHM=1
export WEBOTS_HOME=${WEBOTS_HOME:-/usr/local/webots}
export ROS2_WEBOTS_HOME=${ROS2_WEBOTS_HOME:-/usr/local/webots}
exec /usr/local/webots/webots "$@"
EOS
RUN chmod +x /usr/local/bin/rv /usr/local/bin/gzs /usr/local/bin/wb

RUN cat >> /home/${USERNAME}/.bashrc <<'EOS'
source /opt/ros/jazzy/setup.bash
source /ros2_ws/install/setup.bash 2>/dev/null || true
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}
export RCUTILS_COLORIZED_OUTPUT=1
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
export QT_X11_NO_MITSHM=1
export WEBOTS_HOME=${WEBOTS_HOME:-/usr/local/webots}
export ROS2_WEBOTS_HOME=${ROS2_WEBOTS_HOME:-/usr/local/webots}
alias cb='colcon build --symlink-install'
alias cs='source /ros2_ws/install/setup.bash'
alias rr='ros2 run'
alias rl='ros2 launch'
alias rt='ros2 topic'
alias rv='rv'
alias gzsim='gzs'
alias wb='wb'
EOS

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
