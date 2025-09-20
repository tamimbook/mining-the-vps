#!/usr/bin/env bash
# Setup script for XRDP and SKLauncher on Ubuntu 20.04 in a Docker container
# Installs XFCE, XRDP, OpenJDK 17, Mesa drivers, and SKLauncher
# Optimized for a containerized environment without systemd

set -e

# ---------- Styles ----------
if [[ -t 1 ]]; then
  BOLD="$(tput bold || true)"; RESET="$(tput sgr0 || true)"
  RED="$(tput setaf 1 || true)"; GREEN="$(tput setaf 2 || true)"; YELLOW="$(tput setaf 3 || true)"
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""
fi
hr() { printf "%s\n" "──────────────────────────────────────────────────"; }
ok() { printf "%s[OK]%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"; }
err() { printf "%s[ERROR]%s %s\n" "$RED" "$RESET" "$*"; exit 1; }
step() { printf "\n%s%s%s\n" "$BOLD" "$*" "$RESET"; hr; }

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  err "This script must be run as root (use sudo)."
fi

# Check if running in Docker
if [ "$(systemd-detect-virt 2>/dev/null || echo none)" = "docker" ]; then
  ok "Detected Docker environment."
  SYSTEMD=false
else
  SYSTEMD=true
fi

# Update package lists
step "Updating package lists"
apt-get update || err "Failed to update package lists."

# Install XFCE desktop environment
step "Installing XFCE desktop environment"
apt-get install -y xfce4 xfce4-goodies || err "Failed to install XFCE."

# Install XRDP
step "Installing XRDP"
apt-get install -y xrdp xorgxrdp || err "Failed to install XRDP."

# Configure XRDP for XFCE
step "Configuring XRDP for XFCE"
echo "xfce4-session" > /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh
echo "xfce4-session" > /root/.xsession
if [ -d /home ]; then
  for user_home in /home/*; do
    if [ -d "$user_home" ]; then
      echo "xfce4-session" > "$user_home/.xsession"
      chown "$(basename "$user_home")" "$user_home/.xsession"
    fi
  done
fi

# Start XRDP in Docker (no systemd)
if ! $SYSTEMD; then
  step "Starting XRDP in Docker"
  service xrdp start || warn "Failed to start XRDP service (check logs in /var/log/xrdp*.log)."
  service xrdp-sesman start || warn "Failed to start XRDP session manager."
else
  step "Enabling and starting XRDP services"
  systemctl enable xrdp xrdp-sesman || warn "Failed to enable XRDP services."
  systemctl start xrdp xrdp-sesman || warn "Failed to start XRDP services."
fi

# Check swap space
step "Checking swap space"
if [ "$(free | grep Swap | awk '{print $3}')" -ge "$(free | grep Swap | awk '{print $2}')" ]; then
  warn "Swap space is fully used. Consider increasing swap for better performance."
fi

# Install Mesa drivers for OpenGL
step "Installing Mesa drivers for OpenGL"
apt-get install -y libgl1-mesa-dri mesa-vulkan-drivers mesa-utils || err "Failed to install Mesa drivers."

# Install OpenJDK 17 (SKLauncher prefers Java 17 for modern Minecraft versions)
step "Installing OpenJDK 17"
apt-get install -y openjdk-17-jre || err "Failed to install OpenJDK 17."

# Install additional utilities for SKLauncher
step "Installing utilities for SKLauncher"
apt-get install -y wget curl || err "Failed to install wget and curl."

# Download and install SKLauncher
step "Downloading and installing SKLauncher"
SKLAUNCHER_JAR="/opt/SKLauncher.jar"
if [ ! -f "$SKLAUNCHER_JAR" ]; then
  wget -O "$SKLAUNCHER_JAR" "https://skmedix.pl/downloads/SKLauncher.jar" || err "Failed to download SKLauncher."
fi
chmod +x "$SKLAUNCHER_JAR"
ok "SKLauncher installed at $SKLAUNCHER_JAR"

# Create desktop shortcut for SKLauncher
step "Creating SKLauncher desktop shortcut"
cat > /usr/share/applications/sklauncher.desktop <<EOF
[Desktop Entry]
Name=SKLauncher
Exec=java -jar $SKLAUNCHER_JAR
Type=Application
Icon=minecraft
Terminal=false
Categories=Game;
EOF
ok "SKLauncher desktop shortcut created."

# Ensure X11 forwarding is enabled for Docker
step "Configuring X11 for Docker"
if ! $SYSTEMD; then
  if [ -d /tmp/.X11-unix ]; then
    chmod 1777 /tmp/.X11-unix || warn "Failed to set permissions on /tmp/.X11-unix."
  else
    mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix || warn "Failed to create /tmp/.X11-unix."
  fi
fi

# Verify installations
step "Verifying installations"
if command -v xrdp >/dev/null && command -v xfce4-session >/dev/null; then
  ok "XRDP and XFCE are installed."
else
  err "XRDP or XFCE installation failed."
fi
if command -v java >/dev/null && java -version 2>&1 | grep -q "17.0"; then
  ok "OpenJDK 17 is installed."
else
  warn "OpenJDK 17 not found or incorrect version."
fi
if [ -f "$SKLAUNCHER_JAR" ]; then
  ok "SKLauncher JAR is present."
else
  err "SKLauncher JAR not found."
fi

# Instructions for use
hr
ok "Setup complete!"
if ! $SYSTEMD; then
  echo "To connect via RDP, use an RDP client (e.g., Microsoft Remote Desktop) to connect to this server's IP on port 3389."
  echo "In Docker, ensure XRDP is running: 'service xrdp status' or 'service xrdp start'."
else
  echo "To connect via RDP, use an RDP client to connect to this server's IP on port 3389."
  echo "Check XRDP status with: 'systemctl status xrdp'."
fi
echo "Launch SKLauncher via the XFCE desktop or run: 'java -jar $SKLAUNCHER_JAR'."
echo "If Minecraft performance is poor, consider adding more swap space or checking GPU driver support."

exit 0
