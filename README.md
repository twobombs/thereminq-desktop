# Thereminq Desktop

This repository contains a Dockerfile to build a containerized XFCE desktop environment with VNC and RDP access. It is designed for development and virtualization tasks.

## Features

- **Base Image**: `ubuntu:resolute`
- **Desktop Environment**: XFCE4 with standard utilities (terminal, file manager, etc.)
- **Remote Access**:
  - **noVNC**: HTML5 VNC client accessible via browser on port `6080`.
  - **VNC**: Direct VNC access on port `5900`.
  - **RDP**: Remote Desktop Protocol access via `xrdp` on port `3389`.
- **Development Tools**:
  - OpenJDK 21
  - Python 3 with `pip`
  - OpenCL libraries and headers
  - Git, build tools (`ant`, `pkg-config`, `make`)
- **Virtualization Support**:
  - KVM/QEMU
  - Libvirt
  - `virt-manager`

## Usage

### Building the Image

To build the Docker image, run:

```bash
docker build -f Dockerfile-2604 -t thereminq-desktop .
```

### Running the Container

To run the container, map the necessary ports. For virtualization support, run in privileged mode:

```bash
docker run -d \
  -p 6080:6080 \
  -p 5900:5900 \
  -p 3389:3389 \
  --privileged \
  --name thereminq-desktop \
  thereminq-desktop
```

### Accessing the Desktop

1.  **Web Browser (noVNC)**: Open `http://localhost:6080` in your browser.
2.  **VNC Client**: Connect to `localhost:5900`.
3.  **RDP Client**: Connect to `localhost:3389`.

## Configuration

- **User**: The container runs as the `thereminq` user.
- **Resolution**: Default screen resolution is set to `2560x1440`.
- **Password**: The VNC/RDP password is pre-configured in the image.
