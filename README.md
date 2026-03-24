# ROS 2 Jazzy Docker Dev Environment (Linux X11)

Run ROS 2 Jazzy with native Linux desktop windows from inside Docker.
GUI apps like RViz2, rqt, and Gazebo Sim use host X11 forwarding (not VNC).

## Overview

This repository provides a ROS 2 Jazzy development container based on:
- Ubuntu Noble 24.04
- `osrf/ros:jazzy-desktop`
- Docker Compose for lifecycle management
- X11 socket forwarding for GUI

Current implementation details:
- No noVNC
- No x11vnc
- No Xvfb desktop pipeline
- GUI windows open directly on the host desktop through X11

## Architecture

Host (Linux X11 session)
- Host display server and `DISPLAY`
- Host X11 socket at `/tmp/.X11-unix`
- Optional `/dev/dri` for hardware OpenGL

Container (`ros_jazzy_dev`)
- ROS 2 Jazzy tools
- Gazebo Harmonic bridge (`ros-jazzy-ros-gz`)
- Mesa OpenGL stack
- Wrapper commands:
  - `rv` -> `rviz2`
  - `rq` -> `rqt`
  - `gz` -> `gz sim`

`run.sh` behavior:
- Grants X access via `xhost +local:root`
- Uses direct X11 mount on native Docker Engine
- On Docker Desktop Linux, can create a `socat` bridge in `~/.x11-bridge`
- Detects `/dev/dri` nodes and enables GPU override when available

## Requirements

- Linux host with an active X11 session
- Docker Engine or Docker Desktop for Linux
- Docker Compose plugin (`docker compose`)
- Git

Optional but recommended:
- `socat` (needed for Docker Desktop Linux X11 bridge mode)
- `x11-xserver-utils` (provides `xhost`)

## Quick Start

```bash
git clone https://github.com/WangodaFrancis667/Robot-Operating-System-via-Docker.git
cd Robot-Operating-System-via-Docker
chmod +x run.sh

# First-time build + start
./run.sh start
```

After startup:
- You are dropped into an interactive shell inside the container.
- Launch GUI apps from that shell:

```bash
rv
rq
gz
```

## Commands

```bash
./run.sh start
./run.sh shell
./run.sh build
./run.sh stop
./run.sh status
./run.sh logs
./run.sh gui
./run.sh help
```

What they do:
- `start`: Build image if missing, configure X11, start container, open shell
- `shell`: Open shell in running container as `ros`
- `build`: Force rebuild image without cache
- `stop`: Stop and remove container
- `status`: Show compose service status
- `logs`: Tail container logs
- `gui`: Print GUI diagnostics and quick checks

## GUI Notes

X11 forwarding is used, so GUI windows appear natively on the Linux host desktop.

Host-side checks:

```bash
echo "$DISPLAY"
ls -la /tmp/.X11-unix
xhost +local:root
```

Container-side checks:

```bash
echo "$DISPLAY"
xdpyinfo | head -5
glxinfo -B | grep -i 'OpenGL renderer'
```

## Docker Desktop Linux Notes

Docker Desktop Linux runs in a VM and often cannot mount `/tmp/.X11-unix` directly.

`run.sh` handles this by:
- Detecting `desktop-linux` context
- Using `socat` to bridge host X11 socket into `~/.x11-bridge`
- Mounting that bridge directory into the container

If `socat` is missing, install it:

```bash
sudo apt install socat
```

## Build and DNS Troubleshooting

If build fails at metadata pull stage with errors like:
- `lookup registry-1.docker.io ... i/o timeout`
- `failed to resolve source metadata for docker.io/osrf/ros:jazzy-desktop`

Important:
- This is a Docker daemon/buildkit DNS issue.
- It happens before Dockerfile `RUN` commands execute.

Current `run.sh` behavior:
- Performs a pre-build Docker Hub DNS check.
- If compose build fails on Docker Hub lookup patterns, it retries with:

```bash
docker build --network=host ...
```

Permanent host-level fix:

```bash
sudo mkdir -p /etc/docker
cat <<'EOF' | sudo tee /etc/docker/daemon.json
{
  "dns": ["1.1.1.1", "8.8.8.8", "8.8.4.4"]
}
EOF
sudo systemctl restart docker
```

Then rerun:

```bash
./run.sh build
```

## ROS Workspace Flow

Inside container:

```bash
cd /ros2_ws
rosdep install --from-paths src --ignore-src -r -y
cb
cs
```

Short aliases available in shell:
- `cb`: `colcon build --symlink-install`
- `ct`: `colcon test`
- `cs`: `source install/setup.bash`
- `rl`: `ros2 launch`
- `rr`: `ros2 run`
- `rt`: `ros2 topic`
- `rn`: `ros2 node`

## Project Structure

```text
.
├── Dockerfile
├── docker-compose.yml
├── docker-compose.gpu.yml
├── entrypoint.sh
├── run.sh
├── NETWORK_FIX.md
├── docs/
│   ├── linux.md
│   └── windows.md
└── src/
```

## Troubleshooting Quick Reference

1. GUI says cannot open display
- On host: `xhost +local:root`
- Ensure `DISPLAY` is set in host shell
- Verify `/tmp/.X11-unix/X0` (or your display number) exists

2. Docker Desktop Linux X11 mount fails
- Install `socat`
- Use `./run.sh start` so bridge setup runs automatically

3. No hardware OpenGL
- Check `/dev/dri/renderD*` exists on host
- Run `./run.sh gui` and `glxinfo -B` inside container

4. Build fails pulling base image from Docker Hub
- Apply daemon DNS config above
- Retry `./run.sh build`

## License

MIT License. See `LICENSE`.
