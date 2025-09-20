#!/usr/bin/env bash
# lapdev-heal.sh — Repair sudo + man-db on Ubuntu (Focal-friendly), esp. in code-server/lap.dev envs.
# - Fixes ownership/permissions for sudo, sudoers, sudoers.d, sudo plugin, sudo.conf
# - Validates sudoers syntax with visudo before applying restrictive perms
# - Repairs man-db cache dir and (optionally) reinstalls man-db
# - Detects nosuid mounts that break sudo setuid
# - Logs everything, supports dry-run and targeted repairs

set -Eeuo pipefail

# ---------- Pretty output ----------
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
ok()    { printf "%s[✓]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf "%s[!]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
info()  { printf "%s[i]%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
err()   { printf "%s[x]%s %s\n" "$C_RED" "$C_RESET" "$*"; }
die()   { err "$*"; exit 1; }

# ---------- Defaults / flags ----------
DO_SUDO=1
DO_MAN=1
DRY_RUN=0
REINSTALL_MAN=0
LOG_DIR="/var/log"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/lapdev-heal-${TS}.log"

# Use your desired defaults; tune if needed
SUDO_BIN="/usr/bin/sudo"
SUDOERS="/etc/sudoers"
SUDOERS_D="/etc/sudoers.d"
SUDO_PLUGIN="/usr/lib/sudo/sudoers.so"     # typical on Ubuntu/Debian
SUDOCONF="/etc/sudo.conf"

# Permissions we want to enforce
MODE_SUDO_BIN=4755      # rwsr-xr-x (setuid root)
MODE_SUDOERS=0440
MODE_SUDOERS_D=0755
MODE_SUDOERS_D_FILES=0440
MODE_SUDO_PLUGIN=0644   # .so files do not need +x; readable is enough
MODE_SUDOCONF=0644

# man-db cache
MAN_CACHE="/var/cache/man"
MODE_MAN_DIR=0755
MAN_OWNER="man"
MAN_GROUP="man"

# ---------- Helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

run() {
  # run "command ..." and tee to log. Obeys DRY_RUN.
  if (( DRY_RUN )); then
    echo "# DRY: $*" | tee -a "$LOG_FILE"
  else
    echo "+ $*" | tee -a "$LOG_FILE"
    eval "$@" 2>&1 | tee -a "$LOG_FILE"
  fi
}

backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local b="${f}.bak.${TS}"
  if [[ -e "$b" ]]; then
    info "Backup exists for $f -> $b"
  else
    run "cp -a -- '$f' '$b'"
    ok "Backed up $f -> $b"
  fi
}

ensure_dir() {
  local d="$1" owner="$2" group="$3" mode="$4"
  if [[ ! -d "$d" ]]; then
    run "mkdir -p -- '$d'"
  fi
  run "chown $owner:$group -- '$d'"
  run "chmod $mode -- '$d'"
}

ensure_owner_mode() {
  local path="$1" owner="$2" group="$3" mode="$4"
  [[ -e "$path" ]] || { warn "$path missing; skipping"; return 0; }
  run "chown $owner:$group -- '$path'"
  run "chmod $mode -- '$path'"
}

add_line_once() {
  # ensure a line exists in a file (create file if missing), keep other content
  local file="$1" line="$2"
  if [[ ! -f "$file" ]]; then
    run "install -m $MODE_SUDOCONF /dev/null '$file'"
  fi
  if grep -qxF "$line" "$file" 2>/dev/null; then
    info "Line already present in $file: $line"
  else
    backup_file "$file"
    run "printf '%s\n' \"$line\" >> '$file'"
    ok "Inserted into $file: $line"
  fi
}

visudo_check() {
  local file="$1"
  if have visudo; then
    if visudo -c -q -f "$file" 2>>"$LOG_FILE"; then
      ok "visudo validation OK: $file"
      return 0
    else
      err "visudo validation FAILED for $file (see $LOG_FILE)"
      return 1
    fi
  else
    warn "visudo not found; cannot validate $file"
    return 0
  fi
}

findmnt_has_nosuid() {
  local path="$1"
  if have findmnt; then
    findmnt -no OPTIONS "$path" 2>/dev/null | grep -qw nosuid
  else
    # fallback: parse /proc/mounts
    awk -v p="$path" '$2==p {print $4}' /proc/mounts 2>/dev/null | grep -qw nosuid
  fi
}

# ---------- Argument parsing ----------
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --only-sudo         Only repair sudo bits
  --only-man          Only repair man-db cache
  --reinstall-man-db  Apt reinstall man-db (restores canonical perms)
  --dry-run           Show planned changes without applying
  --log FILE          Log file path (default: $LOG_FILE)
  -h, --help          Show this help

Notes:
- Run as root. If sudo is broken, use direct root shell from your provider.
- In containers/hosted IDEs, nosuid mounts can make sudo unusable no matter the file modes.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only-sudo) DO_SUDO=1; DO_MAN=0; shift;;
    --only-man) DO_SUDO=0; DO_MAN=1; shift;;
    --reinstall-man-db) REINSTALL_MAN=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --log) LOG_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  endesac
done

[[ $EUID -eq 0 ]] || die "Please run as root. (sudo may be broken; get a root shell from the host panel.)"

# Ensure log dir exists
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" || die "Cannot write log file: $LOG_FILE"
info "Logging to: $LOG_FILE"

# ---------- Environment report ----------
info "User: $(whoami)  UID:$(id -u) GID:$(id -g)  Kernel: $(uname -r)"
info "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"

if findmnt_has_nosuid /usr; then
  warn "/usr is mounted with nosuid — sudo setuid bit will NOT take effect on this mount."
fi
if findmnt_has_nosuid /; then
  warn "/ is mounted with nosuid — sudo setuid bit will NOT take effect on this mount."
fi

# ---------- Repairs ----------
repair_man() {
  info "Repairing man-db cache at $MAN_CACHE"
  if ! id -u "$MAN_OWNER" >/dev/null 2>&1; then
    warn "User '$MAN_OWNER' not found; will default to root:root for $MAN_CACHE"
    MAN_OWNER="root"; MAN_GROUP="root"
  fi

  ensure_dir "$MAN_CACHE" "$MAN_OWNER" "$MAN_GROUP" "$MODE_MAN_DIR"
  # Many environments have recursive permission issues; fix recursively but be explicit.
  if [[ -d "$MAN_CACHE" ]]; then
    run "chown -R $MAN_OWNER:$MAN_GROUP -- '$MAN_CACHE'"
    run "chmod -R $MODE_MAN_DIR -- '$MAN_CACHE'"
    ok "Fixed ownership/permissions for $MAN_CACHE"
  fi

  if (( REINSTALL_MAN )); then
    info "Reinstalling man-db to restore canonical ownership/perms (network required)"
    run "apt-get update -y"
    run "apt-get install -y --reinstall man-db"
  fi

  if have mandb; then
    info "Rebuilding man database (mandb -q)…"
    run "mandb -q" || warn "mandb returned non-zero; see $LOG_FILE"
  else
    warn "mandb not found; install man-db to rebuild caches."
  fi
}

repair_sudo() {
  info "Repairing sudo stack"

  # 1) sudo binary
  if [[ -e "$SUDO_BIN" ]]; then
    ensure_owner_mode "$SUDO_BIN" root root "$MODE_SUDO_BIN"
  else
    warn "$SUDO_BIN missing. Attempting to (re)install sudo…"
    run "apt-get update -y"
    run "apt-get install -y sudo"
  fi

  # 2) sudoers plugin (.so)
  if [[ -e "$SUDO_PLUGIN" ]]; then
    ensure_owner_mode "$SUDO_PLUGIN" root root "$MODE_SUDO_PLUGIN"
  else
    warn "$SUDO_PLUGIN not found. On some distros the path differs. Check 'sudo -V' after repair."
  fi

  # 3) sudo.conf: ensure plugin directive without nuking other settings
  add_line_once "$SUDOCONF" "Plugin sudoers_policy sudoers.so"
  ensure_owner_mode "$SUDOCONF" root root "$MODE_SUDOCONF"

  # 4) sudoers main file — validate before locking down perms
  if [[ -f "$SUDOERS" ]]; then
    backup_file "$SUDOERS"
    if visudo_check "$SUDOERS"; then
      ensure_owner_mode "$SUDOERS" root root "$MODE_SUDOERS"
    else
      warn "NOT changing $SUDOERS perms due to validation failure. Fix syntax, then re-run."
    fi
  else
    warn "$SUDOERS not found; creating minimal safe sudoers allowing root only."
    run "printf 'root ALL=(ALL:ALL) ALL\n# includedir /etc/sudoers.d\n' > '$SUDOERS'"
    ensure_owner_mode "$SUDOERS" root root "$MODE_SUDOERS"
  fi

  # 5) sudoers.d dir + files
  ensure_dir "$SUDOERS_D" root root "$MODE_SUDOERS_D"

  # Validate and fix each file found; skip non-regular files
  shopt -s nullglob
  for f in "$SUDOERS_D"/*; do
    [[ -f "$f" ]] || continue
    backup_file "$f"
    if visudo_check "$f"; then
      ensure_owner_mode "$f" root root "$MODE_SUDOERS_D_FILES"
    else
      warn "Validation failed for $f — leaving perms unchanged so you can fix it."
    fi
  done
  shopt -u nullglob

  # 6) Quick health checks
  if have sudo; then
    info "sudo -V (paths overview)…"
    run "sudo -V | sed -n '1,40p'"
  fi

  # If nosuid is present, warn explicitly after setting modes
  if findmnt_has_nosuid "$(dirname "$SUDO_BIN")"; then
    warn "nosuid mount detected for $(dirname "$SUDO_BIN"); setuid bit on sudo will be ignored."
  fi

  # Try a lightweight sudo self-test if possible
  if have sudo; then
    info "Attempting non-interactive sudo self-test: 'sudo -n true'"
    if (( DRY_RUN )); then
      info "DRY: would run 'sudo -n true'"
    else
      if sudo -n true 2>>"$LOG_FILE"; then
        ok "sudo functional for current user (policy permits 'sudo -n true')."
      else
        warn "sudo returned non-zero (policy or password req). Check 'sudo -l' or your sudoers rules."
      fi
    fi
  fi
}

# ---------- Execute ----------
if (( DO_MAN )); then repair_man; fi
if (( DO_SUDO )); then repair_sudo; fi

ok "All done. Detailed log: $LOG_FILE"
