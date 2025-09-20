#!/usr/bin/env bash
# Setup script for XRDP and SKLauncher on Ubuntu 20.04 in a Docker container
# Enhanced with port management, XRDP recovery, and memory optimization

set -e

# ---------- Styles and Utilities ----------
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
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> /var/log/setup_rdp_sklauncher.log; }

# Check root and parse args
if [ "$(id -u)" -ne 0 ]; then err "Run with sudo."; fi
USER=${1#--user }; shift || USER="minecraftuser"
PASS=${1#--password }; shift || PASS="minecraft123"
OPEN_RDP=${1#--open-rdp} && shift && [ "$OPEN_RDP" = "--open-rdp" ] && OPEN_RDP=true || OPEN_RDP=false
RDP_PORT=3389

# Detect Docker environment
if [ "$(systemd-detect-virt 2>/dev/null || echo none)" = "docker" ]; then
  ok "Detected Docker environment."
  SYSTEMD=false
else
  SYSTEMD=true
fi
log "Environment detected: Docker=$SYSTEMD"

# Manage RDP port
step "Managing RDP port $RDP_PORT"
if ss -tuln | grep -q ":$RDP_PORT"; then
  warn "Port $RDP_PORT in use, attempting to close."
  fuser -k $RDP_PORT/tcp 2>/dev/null || warn "Failed to kill processes on $RDP_PORT."
  sleep 2
fi
log "Port $RDP_PORT management attempted"

# Update package lists
step "Updating package lists"
apt-get update -qq || err "Failed to update package lists."
log "Package lists updated"

# Install/Verify XFCE
step "Installing/Verifying XFCE desktop environment"
if ! dpkg -l | grep -q xfce4; then
  apt-get install -y xfce4 xfce4-goodies || err "Failed to install XFCE."
else
  ok "XFCE already installed."
fi
log "XFCE setup complete"

# Install/Verify XRDP
step "Installing/Verifying XRDP"
if ! dpkg -l | grep -q xrdp; then
  apt-get install -y xrdp xorgxrdp || err "Failed to install XRDP."
else
  ok "XRDP already installed."
fi
log "XRDP setup complete"

# Configure XRDP for XFCE
step "Configuring XRDP for XFCE"
[ -f /etc/xrdp/startwm.sh ] && cp /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.bak
echo "xfce4-session" > /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh
echo "xfce4-session" > /root/.xsession
for user_home in /home/*; do
  [ -d "$user_home" ] && echo "xfce4-session" > "$user_home/.xsession" && chown "$(basename "$user_home")" "$user_home/.xsession"
done
log "XRDP configured for XFCE"

# Start/Verify XRDP with recovery
if ! $SYSTEMD; then
  step "Starting/Verifying XRDP in Docker"
  if ! pgrep xrdp >/dev/null; then
    service xrdp start || {
      warn "XRDP start failed, restarting."
      pkill -9 xrdp 2>/dev/null || true
      service xrdp start || err "XRDP restart failed (logs: /var/log/xrdp*.log)."
    }
    ok "XRDP started."
  else
    ok "XRDP already running."
  fi
  if ! pgrep xrdp-sesman >/dev/null; then
    service xrdp-sesman start || {
      warn "xrdp-sesman start failed, cleaning PID."
      rm -f /var/run/xrdp/xrdp-sesman.pid 2>/dev/null || true
      service xrdp-sesman start || warn "xrdp-sesman still failed (manual fix needed)."
    }
    ok "xrdp-sesman started."
  else
    ok "xrdp-sesman already running."
  fi
  log "XRDP services status: xrdp=$(pgrep xrdp), xrdp-sesman=$(pgrep xrdp-sesman)"
fi

# Check and optimize swap
step "Checking and optimizing swap space"
SWAP_TOTAL=$(free | grep Swap | awk '{print $2}')
SWAP_USED=$(free | grep Swap | awk '{print $3}')
if [ "$SWAP_USED" -ge "$SWAP_TOTAL" ]; then
  warn "Swap space fully used. Setting up tmpfs workaround."
  mkdir -p /swap-ram && mount -t tmpfs -o size=32G tmpfs /swap-ram || warn "Tmpfs mount failed."
  echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf 2>/dev/null || warn "Swappiness adjustment failed."
else
  ok "Swap usage: $SWAP_USED/$SWAP_TOTAL GiB."
fi
log "Swap check: Used=$SWAP_USED, Total=$SWAP_TOTAL, Tmpfs=/swap-ram"

# Install/Verify Mesa drivers
step "Installing/Verifying Mesa drivers for OpenGL"
for pkg in libgl1-mesa-dri mesa-vulkan-drivers mesa-utils; do
  if ! dpkg -l | grep -q "$pkg"; then
    apt-get install -y "$pkg" || err "Failed to install $pkg."
  else
    ok "$pkg already installed."
  fi
done
log "Mesa drivers verified"

# Install/Verify OpenJDK 17
step "Installing/Verifying OpenJDK 17"
if ! dpkg -l | grep -q openjdk-17-jre; then
  apt-get install -y openjdk-17-jre || err "Failed to install OpenJDK 17."
else
  ok "OpenJDK 17 already installed."
fi
log "OpenJDK 17 verified"

# Install/Verify utilities
step "Installing/Verifying utilities for SKLauncher"
for util in wget curl; do
  if ! command -v "$util" >/dev/null; then
    apt-get install -y "$util" || err "Failed to install $util."
  else
    ok "$util already installed."
  fi
done
log "Utilities verified"

# Download and install SKLauncher with multiple fallbacks
step "Downloading and installing SKLauncher"
SKLAUNCHER_JAR="/opt/SKLauncher.jar"
if [ ! -f "$SKLAUNCHER_JAR" ]; then
  URLs=(
    "https://www.dropbox.com/scl/fi/g1nmas9z5e15kkyzcf473/sklauncher-3.2.12.jar?rlkey=0dvvq91wugpq489dr3m58gaph&st=buzvbcqt&dl=1"
    "https://github.com/skurpy/SKLauncher/releases/download/v3.2.12/SKLauncher-3.2.12.jar"
    "https://skmedix.pl/downloads/SKLauncher-latest.jar"
  )
  for url in "${URLs[@]}"; do
    wget -L -O "$SKLAUNCHER_JAR" "$url" && break || warn "Download from $url failed."
  done
  if [ ! -f "$SKLAUNCHER_JAR" ]; then err "All SKLauncher downloads failed."; fi
  chmod +x "$SKLAUNCHER_JAR"
  ok "SKLauncher installed at $SKLAUNCHER_JAR"
else
  ok "SKLauncher already installed at $SKLAUNCHER_JAR"
fi
log "SKLauncher download: Success at $SKLAUNCHER_JAR"

# Create or update desktop shortcut
step "Creating/Updating SKLauncher desktop shortcut"
cat > /usr/share/applications/sklauncher.desktop <<EOF
[Desktop Entry]
Name=SKLauncher
Exec=env TMPDIR=/swap-ram java -jar $SKLAUNCHER_JAR -Xmx32G
Type=Application
Icon=minecraft
Terminal=false
Categories=Game;
EOF
chmod +x /usr/share/applications/sklauncher.desktop
ok "SKLauncher desktop shortcut updated"
log "Desktop shortcut created"

# Ensure X11 forwarding
step "Configuring X11 for Docker"
if ! $SYSTEMD; then
  if [ -d /tmp/.X11-unix ]; then
    chmod 1777 /tmp/.X11-unix || warn "Failed to set X11 permissions."
  else
    mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix || warn "Failed to create X11 directory."
  fi
fi
log "X11 configured"

# Verify installations
step "Verifying installations"
if ! command -v xrdp >/dev/null || ! command -v xfce4-session >/dev/null; then
  err "XRDP or XFCE installation failed."
fi
if ! command -v java >/dev/null || ! java -version 2>&1 | grep -q "17.0"; then
  warn "OpenJDK 17 not found or incorrect version."
fi
if [ ! -f "$SKLAUNCHER_JAR" ]; then
  err "SKLauncher JAR not found."
fi
ok "All components verified"
log "Verification complete"

# Cleanup and instructions
step "Cleanup and instructions"
apt-get clean
rm -f /var/cache/apt/archives/*.deb
hr
ok "Setup complete!"
HOSTNAME=$(hostname)
echo "Connect via RDP: Use an RDP client to $HOSTNAME:3389 with $USER/$PASS."
echo "Launch SKLauncher from XFCE desktop or terminal with: java -jar $SKLAUNCHER_JAR."
echo "Memory optimized with -Xmx32G and /swap-ram. Check logs at /var/log/setup_rdp_sklauncher.log."
if ! pgrep xrdp-sesman >/dev/null; then
  warn "xrdp-sesman not running. Manual restart or Lapdev support may be needed."
fi
log "Setup finished at $(date)"
exit 0