#!/usr/bin/env sh
# xcross installer — downloads the latest prebuilt binary from GitHub Releases
# and installs it system-wide. No local Dart toolchain required.
#
# Usage:
#   curl -fsSL \
#     https://raw.githubusercontent.com/arxdeus/xcross/main/install.sh | sh
#   # or, pin a version / change install dir:
#   XCROSS_VERSION=v1.2.3 INSTALL_DIR=/usr/local/bin sh install.sh
set -eu

REPO="arxdeus/xcross"
BINARY="xcross"
ZSIGN="zsign"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${XCROSS_VERSION:-latest}"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }
info() { printf '==> %s\n' "$1"; }

# --- detect OS (releases are Linux-only) -----------------------------------
os="$(uname -s)"
[ "$os" = "Linux" ] ||
  err "prebuilt releases are Linux-only (got: $os); build from source"

# --- detect architecture ---------------------------------------------------
arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64)
    asset="xcross-linux-x64"
    zsign_asset="zsign-linux-x64"
    ;;
  aarch64 | arm64)
    asset="xcross-linux-arm64"
    zsign_asset="zsign-linux-arm64"
    ;;
  *) err "unsupported architecture: $arch (supported: x86_64, aarch64)" ;;
esac
info "Detected: $os/$arch -> $asset + $zsign_asset"

# --- resolve download URLs --------------------------------------------------
if [ "$VERSION" = "latest" ]; then
  base_url="https://github.com/$REPO/releases/latest/download"
else
  base_url="https://github.com/$REPO/releases/download/$VERSION"
fi

# --- pick a downloader ------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  download() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  download() { wget -qO "$2" "$1"; }
else
  err "need curl or wget to download"
fi

# --- download to a temp directory ------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
for release_asset in "$asset" "$zsign_asset"; do
  url="$base_url/$release_asset"
  info "Downloading $VERSION $release_asset..."
  download "$url" "$tmp/$release_asset" || err "download failed: $url"
  [ -s "$tmp/$release_asset" ] || err "downloaded file is empty: $url"
done

# --- install (use sudo if the target dir is not writable) -------------------
target="$INSTALL_DIR/$BINARY"
zsign_target="$INSTALL_DIR/$ZSIGN"
if mkdir -p "$INSTALL_DIR" 2>/dev/null && [ -w "$INSTALL_DIR" ]; then
  install -m 0755 "$tmp/$asset" "$target"
  install -m 0755 "$tmp/$zsign_asset" "$zsign_target"
elif command -v sudo >/dev/null 2>&1; then
  info "Elevating with sudo to write $INSTALL_DIR"
  sudo mkdir -p "$INSTALL_DIR"
  sudo install -m 0755 "$tmp/$asset" "$target"
  sudo install -m 0755 "$tmp/$zsign_asset" "$zsign_target"
else
  err "cannot write to $INSTALL_DIR; set INSTALL_DIR to a writable path"
fi

# --- verify + PATH hint -----------------------------------------------------
"$target" --help >/dev/null 2>&1 || err "installed xcross failed verification"
"$zsign_target" -h >/dev/null 2>&1 || err "installed zsign failed verification"
info "Installed and verified: $target, $zsign_target"

if ! command -v "$BINARY" >/dev/null 2>&1 ||
  ! command -v "$ZSIGN" >/dev/null 2>&1
then
  info "Installed, but $INSTALL_DIR is not on your PATH. Add it:"
  printf '    export PATH="%s:$PATH"\n' "$INSTALL_DIR"
fi
