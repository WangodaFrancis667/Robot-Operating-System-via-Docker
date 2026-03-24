#!/usr/bin/env bash
set -euo pipefail

export LANG=${LANG:-en_US.UTF-8}
export LC_ALL=${LC_ALL:-en_US.UTF-8}
export ROS_DISTRO=${ROS_DISTRO:-jazzy}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}
export RCUTILS_COLORIZED_OUTPUT=${RCUTILS_COLORIZED_OUTPUT:-1}
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
export QT_X11_NO_MITSHM=1
export WEBOTS_HOME=${WEBOTS_HOME:-/usr/local/webots}
export ROS2_WEBOTS_HOME=${ROS2_WEBOTS_HOME:-/usr/local/webots}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-ros}

mkdir -p "${XDG_RUNTIME_DIR}" /home/ros/.cache/Cyberbotics /home/ros/.config/Cyberbotics /home/ros/.gz
chown -R ros:ros "${XDG_RUNTIME_DIR}" /home/ros/.cache/Cyberbotics /home/ros/.config/Cyberbotics /home/ros/.gz
chmod 700 "${XDG_RUNTIME_DIR}"

if [ -f /opt/ros/jazzy/setup.bash ]; then
  set +u
  source /opt/ros/jazzy/setup.bash
  set -u
fi

if [ -f /ros2_ws/install/setup.bash ]; then
  set +u
  source /ros2_ws/install/setup.bash
  set -u
fi

echo ""
echo "============================================================"
echo "ROS 2 Jazzy + Gazebo Harmonic + Webots Docker Environment"
echo "============================================================"
echo "DISPLAY=${DISPLAY:-unset}"
echo "ROS_DOMAIN_ID=${ROS_DOMAIN_ID}"
echo "WEBOTS_HOME=${WEBOTS_HOME}"
echo "QT_QPA_PLATFORM=${QT_QPA_PLATFORM}"
echo "OpenGL: $(glxinfo -B 2>/dev/null | grep 'OpenGL renderer' || echo 'glxinfo unavailable')"
echo ""
echo "Helpers: rv  |  gzs  |  wb"
echo ""

if [ "$#" -eq 0 ] || [ "$1" = "bash" ]; then
  exec su - ros --shell /bin/bash -w DISPLAY,QT_QPA_PLATFORM,QT_X11_NO_MITSHM,XDG_RUNTIME_DIR,WEBOTS_HOME,ROS2_WEBOTS_HOME,ROS_DOMAIN_ID,RCUTILS_COLORIZED_OUTPUT -c 'source /opt/ros/jazzy/setup.bash && source /ros2_ws/install/setup.bash 2>/dev/null || true && exec bash --login -i'
else
  exec su - ros --shell /bin/bash -w DISPLAY,QT_QPA_PLATFORM,QT_X11_NO_MITSHM,XDG_RUNTIME_DIR,WEBOTS_HOME,ROS2_WEBOTS_HOME,ROS_DOMAIN_ID,RCUTILS_COLORIZED_OUTPUT -c "source /opt/ros/jazzy/setup.bash && source /ros2_ws/install/setup.bash 2>/dev/null || true && exec $*"
fi
