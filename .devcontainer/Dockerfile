FROM ubuntu:20.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install essentials, XRDP, XFCE, Java, and Mesa for software rendering, including apt-utils
RUN apt-get update && apt-get install -y \
    apt-utils \
    sudo \
    curl \
    wget \
    xrdp \
    xfce4 \
    xfce4-goodies \
    xorgxrdp \
    mesa-utils \
    libgl1-mesa-dri \
    libgl1-mesa-glx \
    openjdk-17-jre \
    net-tools \
    && rm -rf /var/lib/apt/lists/*

# Copy the heal script from the .devcontainer folder
COPY lapdev_heal.sh /workspaces/lapdev_heal.sh

# Create non-root user for RDP
RUN useradd -m -s /bin/bash minecraftuser \
    && echo "minecraftuser:minecraft123" | chpasswd \
    && usermod -aG sudo minecraftuser \
    && echo "minecraftuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Configure XRDP to use XFCE
RUN echo "xfce4-session" > /etc/xrdp/startwm.sh \
    && chmod +x /etc/xrdp/startwm.sh \
    && adduser xrdp ssl-cert

# Start XRDP service
RUN service xrdp start

# Switch to non-root user
USER minecraftuser
WORKDIR /workspaces

# Expose RDP port
EXPOSE 3389
