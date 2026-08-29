FROM ubuntu:resolute

# Set noninteractive environment globally
ENV DEBIAN_FRONTEND=noninteractive

#  Rusticl for AMD
ENV RUSTICL_ENABLE=radeonsi
RUN echo "RUSTICL_ENABLE=radeonsi" >> /etc/environment && \
    echo "export RUSTICL_ENABLE=radeonsi" >> /root/.bashrc
    

# Configure architecture, repositories, and upgrade base system
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends apt-utils software-properties-common && \
    add-apt-repository multiverse && \
    apt-get update && \
    apt-get -y upgrade

# Install consolidated packages logically grouped
RUN apt-get install -y --no-install-recommends \
    # Base Utilities & Networking
    adduser btop curl linux-tools-generic locales lynx mc net-tools wget \
    # X11, Desktop & VNC
    dbus-x11 novnc screen ssh-askpass-gnome tigervnc-scraping-server tightvncserver x11vnc xfce4 xfce4-goodies xrdp arc-theme xterm xvfb gnome-keyring \
    # Virtualization
    bridge-utils libvirt-clients libvirt-daemon-system open-vm-tools virt-manager \
    # Development, Libraries & Drivers
    ant clinfo vulkan-tools mesa-vulkan-drivers dkms freeglut3-dev git git-lfs unzip intel-gpu-tools intel-opencl-icd libegl1-mesa-dev libgl1-mesa-dev libgles2-mesa-dev libglvnd-dev libsdl1.2-dev lm-sensors mesa-opencl-icd mesa-utils ocl-icd-libopencl1 ocl-icd-opencl-dev opencl-headers openjdk-21-jdk pkg-config python3-pip python3-setuptools qv4l2

# Native HF xet support
RUN curl -sSfL https://hf.co/git-xet/install.sh | sh

# install chrome
RUN wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && apt install -y /tmp/chrome.deb && rm /tmp/chrome.deb

# Gnome-terminal invocation fix and layer cleanup
RUN apt-get remove -y gnome-terminal && \
    apt-get purge -y gnome-terminal && \
    apt-get install -y gnome-terminal && \
    apt-get -y remove xfce4-power-manager && \
    apt-get autoremove -y && \
    apt-get clean all && \
    rm -rf /var/lib/apt/lists/*

# Add user and set up necessary directories/files
RUN adduser --disabled-password --gecos "" thereminq && \
    cp /usr/share/novnc/vnc.html /usr/share/novnc/index.html && \
    mkdir -p /root/.vnc /root/.config/tigervnc

# Copy desktop background
COPY thereminq-wide.png /usr/share/backgrounds/xfce/xfce-verticals.png

# copy mesa fp16 
COPY build_mesa_rusticl_fp16.sh /root/build_mesa_rusticl_fp16.sh

# backwards compatibility until NVK driver matures
RUN echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd

# Copy scripts and configurations
COPY run /root/
RUN chmod 755 /root/run

COPY xorg.conf /usr/share/X11/xorg.conf.d/
COPY passwd xstartup /root/.vnc/

# Apply execute permissions
RUN chmod 755 /root/run /root/.vnc/xstartup

EXPOSE 3389 5900 6080
ENTRYPOINT ["/root/run"]
