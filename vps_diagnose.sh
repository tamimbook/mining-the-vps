#!/usr/bin/env bash
# Creates a detailed diagnostic output about this Ubuntu VPS, printed to terminal
# and saved to a single .log file.
# Safe to run multiple times. Does not change system settings.

set -u

# ---------- Styles ----------
if [[ -t 1 ]]; then
  BOLD="$(tput bold || true)"; DIM="$(tput dim || true)"; RESET="$(tput sgr0 || true)"
  RED="$(tput setaf 1 || true)"; GREEN="$(tput setaf 2 || true)"; YELLOW="$(tput setaf 3 || true)"
  BLUE="$(tput setaf 4 || true)"; MAGENTA="$(tput setaf 5 || true)"; CYAN="$(tput setaf 6 || true)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
fi
hr() { printf "%s\n" "────────────────────────────────────────────────────────────────────────"; }
title() { printf "\n%s%s%s %s\n" "$BOLD" "$1" "$RESET" "${2:-}"; hr; }
ok() { printf "%s[OK]%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"; }
err() { printf "%s[ERR ]%s %s\n" "$RED" "$RESET" "$*"; }

TS="$(date +%Y%m%d-%H%M%S)"
LOGFILE="./vps-report-$TS.log"

# Redirect all output to both terminal and log file
exec 3>&1  # Save stdout to fd 3
exec > >(tee -a "$LOGFILE") 2>&1  # Tee output to terminal and log file

# Header
cat <<EOF
VPS diagnostic log
Created: $(date -Is)
Host: $(hostname -f 2>/dev/null || hostname)
User: $(id -un) (uid=$(id -u))
EOF
hr

# Run command (with timeout), print to terminal and log
run() {
  local label="$1"; shift
  title "$label"
  printf "%s\n$ %s\n\n" "$(date -Is)" "$*"
  if command -v timeout >/dev/null 2>&1; then
    timeout 20s bash -lc "$*" || true
  else
    bash -lc "$*" || true
  fi
  echo
}

title "System basics"
run "os-release" "cat /etc/os-release || true"
run "uname" "uname -a || true"
run "lsb_release" "lsb_release -a || true"
run "uptime" "uptime -p; who -a || true"
run "timedate" "timedatectl 2>/dev/null || true"

title "Hardware and virtualization"
run "cpu" "lscpu || true"
run "mem" "free -h || true"
run "virt" "systemd-detect-virt || true"
run "pci-gpu" "lspci -nn | egrep -i 'vga|3d|display' || true"
run "modules-kvm" "lsmod | grep -i kvm || true"

title "Disks and filesystem"
run "df-root" "df -hT / || true"
run "df-all" "df -hT || true"
run "mounts" "mount | sed -n '1,200p' || true"
run "swap" "swapon --show || true"

title "Networking"
run "ip-addr" "ip addr || true"
run "ip-route" "ip route || true"
run "resolv-conf" "nl -ba /etc/resolv.conf || true"
run "resolvectl" "resolvectl status || systemd-resolve --status || true"
run "listen-ports" "ss -tulpen || netstat -tulpen || true"

title "Network reachability (IPv4 quick tests)"
run "dns-lookup-github" "getent hosts github.com || true"
run "https-github" "curl -4Is --max-time 8 https://github.com | head -n 20 || true"
run "https-ubuntu" "curl -4Is --max-time 8 https://archive.ubuntu.com | head -n 20 || true"

title "Apt configuration"
run "apt-sources" "grep -R --no-color -nH '^[^#].*deb' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true"
run "apt-policy-core" "apt-cache policy xrdp xfce4 xorgxrdp mesa-utils libgl1-mesa-dri mesa-vulkan-drivers openjdk-17-jre || true"
run "apt-update" "apt update || true"

title "Graphics and Java"
run "glxinfo" "glxinfo -B || true"
run "vulkaninfo" "vulkaninfo --summary || true"
run "java-version" "java -version || true"

title "Desktop / XRDP (if present)"
run "xrdp-status" "systemctl status xrdp xrdp-sesman --no-pager || service xrdp status || true"
run "xrdp-logs" "journalctl -u xrdp -u xrdp-sesman --no-pager -n 300 || true"
run "xsession" "ls -la ~ | egrep -i '\\.xsession|\\.Xsession' || true"
run "ps-xrdp" "ps aux | egrep -i 'xrdp|Xorg|xfce|startx' | egrep -v egrep || true"

title "Security / Firewall"
run "ufw" "ufw status verbose || true"
run "nftables" "nft list ruleset || true"
run "iptables" "iptables -S || true"

title "Fastfetch (if installed)"
run "fastfetch" "command -v fastfetch && fastfetch || echo 'fastfetch not found'"

title "Package inventory (short)"
run "dpkg-list" "dpkg -l | sed -n '1,500p'; echo '... full list available via dpkg -l'"

hr
ok "Diagnostic log saved to: $LOGFILE"
echo "Share the contents of $LOGFILE for analysis."

# Restore stdout and close fd 3
exec 1>&3 3>&-
exit 0
