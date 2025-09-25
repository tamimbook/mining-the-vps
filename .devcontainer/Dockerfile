FROM ubuntu:20.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ARG LAPDEV_USER=unknown

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
COPY fastfetch_installation.sh /workspaces/fastfetch_installation.sh

# Create the SSH user assigned by lap.dev
RUN useradd -m -s /bin/bash mining-the-vps-9qtajn0flxdl \
    && echo "${LAPDEV_USER}:115790" | chpasswd \
    && usermod -aG sudo mining-the-vps-9qtajn0flxdl \
    && echo "${LAPDEV_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Configure XRDP to use XFCE
RUN echo "xfce4-session" > /etc/xrdp/startwm.sh \
    && chmod +x /etc/xrdp/startwm.sh \
    && adduser xrdp ssl-cert

# Start XRDP service
RUN service xrdp start

# Switch to non-root user
USER ${LAPDEV_USER}
WORKDIR /workspaces

# Expose RDP port
EXPOSE 3389
