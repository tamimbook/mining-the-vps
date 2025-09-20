#!/usr/bin/env bash
# Fastfetch build + install + cleanup for Ubuntu 20.04 (Focal)
# - Builds latest release (or specific tag via --tag vX.Y.Z)
# - Tries to create a .deb (preferred), falls back to cmake --install
# - Cleans build tree afterward
# - Stores uninstall instructions if .deb isn’t used

set -Eeuo pipefail

REPO_URL="https://github.com/fastfetch-cli/fastfetch.git"
PREFIX="${PREFIX:-/usr/local}"
TAG_OVERRIDE=""
KEEP_BUILD="0"

usage() {
  cat <<EOF
Usage: $0 [--tag vX.Y.Z] [--prefix /path] [--keep-build]
  --tag        Build a specific release tag (default: latest GitHub release)
  --prefix     Install prefix (default: ${PREFIX})
  --keep-build Keep build directory (default: delete it)
Examples:
  $0
  PREFIX=/opt $0 --tag v2.48.1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG_OVERRIDE="${2:-}"; shift 2;;
    --prefix) PREFIX="${2:-/usr/local}"; shift 2;;
    --keep-build) KEEP_BUILD="1"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "20.04" ]]; then
    echo "Warning: This script is tuned for Ubuntu 20.04 (Focal). Detected: ${PRETTY_NAME:-unknown}."
  fi
fi

# Sudo helper
SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Please run as root or install sudo."
    exit 1
  fi
fi

echo "[1/6] Installing build prerequisites..."
$SUDO apt-get update -y
$SUDO apt-get install -y --no-install-recommends \
  build-essential cmake git pkg-config curl ca-certificates \
  # Optional libraries for richer detection/output (best-effort):
  libxcb-randr0-dev libxrandr-dev libwayland-dev libdrm-dev libdbus-1-dev \
  libsqlite3-dev libelf-dev libpulse-dev libvulkan-dev mesa-common-dev \
  libegl1-mesa-dev ocl-icd-opencl-dev zlib1g-dev libchafa-dev || true

# ImageMagick dev package name differs across Ubuntu releases; try both
if apt-cache show libmagickcore-dev >/dev/null 2>&1; then
  $SUDO apt-get install -y --no-install-recommends libmagickcore-dev || true
elif apt-cache show libmagickcore-6.q16-dev >/dev/null 2>&1; then
  $SUDO apt-get install -y --no-install-recommends libmagickcore-6.q16-dev || true
fi

echo "[2/6] Resolving release tag..."
LATEST_TAG=""
if [[ -n "$TAG_OVERRIDE" ]]; then
  LATEST_TAG="$TAG_OVERRIDE"
else
  # Try GitHub API first (no jq dependency)
  LATEST_TAG="$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+' || true)"
  # Fallback via git if API fails/rate-limited
  if [[ -z "$LATEST_TAG" ]]; then
    LATEST_TAG="$(git ls-remote --tags --refs "$REPO_URL" \
      | awk -F/ '{print $NF}' | sed 's/^v//' | sort -V | tail -1 | sed 's/^/v/')"
  fi
fi

if [[ -z "$LATEST_TAG" ]]; then
  echo "Could not determine latest release tag. You can specify one with --tag vX.Y.Z"
  exit 1
fi
echo "Using tag: $LATEST_TAG"

WORKDIR="$(mktemp -d -t fastfetch-build-XXXXXXXX)"
SRC_DIR="${WORKDIR}/fastfetch"
BUILD_DIR="${SRC_DIR}/build"
DEB_OUT_DIR="${WORKDIR}/out"
mkdir -p "$DEB_OUT_DIR"

cleanup() {
  if [[ "$KEEP_BUILD" = "1" ]]; then
    echo "Keeping build directory: $WORKDIR"
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

echo "[3/6] Cloning source..."
git clone --depth 1 --branch "$LATEST_TAG" "$REPO_URL" "$SRC_DIR"

echo "[4/6] Configuring with CMake..."
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"

echo "[5/6] Building..."
cmake --build "$BUILD_DIR" --target fastfetch -j"$(nproc)"

# Try to package (produces .deb via CPack if project provides it)
echo "[5b/6] Attempting to create .deb (optional)..."
if cmake --build "$BUILD_DIR" --target package; then
  # Move any .deb into out dir
  find "$BUILD_DIR" -maxdepth 1 -type f -name "*.deb" -exec mv -v {} "$DEB_OUT_DIR"/ \; || true
fi

echo "[6/6] Installing..."
DEB_FILE="$(find "$DEB_OUT_DIR" -maxdepth 1 -type f -name "*.deb" | head -n1 || true)"
if [[ -n "$DEB_FILE" ]]; then
  echo "Installing via dpkg: $DEB_FILE"
  $SUDO dpkg -i "$DEB_FILE" || $SUDO apt-get -f install -y
  echo "Installed package: $(basename "$DEB_FILE")"
  echo "Tip: Uninstall later with: sudo dpkg -r fastfetch"
else
  echo "No .deb found, installing via CMake..."
  # Capture install manifest if generated, for manual uninstall later
  cmake --build "$BUILD_DIR" --target install || cmake --install "$BUILD_DIR"
  if [[ -f "$BUILD_DIR/install_manifest.txt" ]]; then
    MANIFEST_DIR="${PREFIX%/}/share/fastfetch"
    $SUDO mkdir -p "$MANIFEST_DIR"
    $SUDO install -m 0644 "$BUILD_DIR/install_manifest.txt" "$MANIFEST_DIR/install_manifest.txt"
    echo "Uninstall manifest saved to: $MANIFEST_DIR/install_manifest.txt"
    echo "Manual uninstall (as root): xargs -a $MANIFEST_DIR/install_manifest.txt rm -vf"
  fi
fi

echo
echo "Verification:"
if command -v fastfetch >/dev/null 2>&1; then
  fastfetch --version || true
  echo "Run: fastfetch"
else
  echo "fastfetch not found on PATH; ensure ${PREFIX}/bin is in your PATH."
fi

echo "Done."
