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
NOTICE="ZSIGN_LICENSE.txt"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
# Native-assets .so must sit at dirname(INSTALL_DIR)/lib so bin/xcross finds
# ../lib/*.so (same layout as `dart build cli`'s bundle/).
LICENSE_DIR="${XCROSS_LICENSE_DIR:-$(dirname "$INSTALL_DIR")/share/licenses/xcross}"
VERSION="${XCROSS_VERSION:-latest}"

err() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}
info() { printf '==> %s\n' "$1"; }

# --- detect OS (releases are Linux-only) -----------------------------------
os="$(uname -s)"
[ "$os" = "Linux" ] ||
	err "prebuilt releases are Linux-only (got: $os); build from source"

# --- detect architecture ---------------------------------------------------
arch="$(uname -m)"
case "$arch" in
x86_64 | amd64) asset="xcross-linux-x64.tar.gz" ;;
aarch64 | arm64) asset="xcross-linux-arm64.tar.gz" ;;
*) err "unsupported architecture: $arch (supported: x86_64, aarch64)" ;;
esac
info "Detected: $os/$arch -> $asset"

# --- resolve download URL --------------------------------------------------
if [ "$VERSION" = "latest" ]; then
	base_url="https://github.com/$REPO/releases/latest/download"
else
	base_url="https://github.com/$REPO/releases/download/$VERSION"
fi

# --- pick a downloader -----------------------------------------------------
if command -v curl >/dev/null 2>&1; then
	download() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
	download() { wget -qO "$2" "$1"; }
else
	err "need curl or wget to download"
fi

# --- download to a temp directory -----------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
url="$base_url/$asset"
notice_url="$base_url/$NOTICE"
info "Downloading $VERSION $asset..."
download "$url" "$tmp/$asset" || err "download failed: $url"
[ -s "$tmp/$asset" ] || err "downloaded file is empty: $url"
download "$notice_url" "$tmp/$NOTICE" || err "download failed: $notice_url"
[ -s "$tmp/$NOTICE" ] || err "downloaded file is empty: $notice_url"

tar -C "$tmp" -xzf "$tmp/$asset" || err "failed to extract $asset"
[ -x "$tmp/bin/xcross" ] || err "archive missing bin/xcross"
[ -d "$tmp/lib" ] || err "archive missing lib/"

# --- install (use sudo if the target dirs are not writable) ---------------
# Layout after install:
#   INSTALL_DIR/xcross          (from bin/xcross)
#   LIB_DIR/*.so                (from lib/) — must be INSTALL_DIR/../lib/xcross
# so the AOT loader's ../lib relative to bin/ still works when INSTALL_DIR is
# .../bin and LIB_DIR is .../lib/xcross. Prefer LIB_DIR = dirname(INSTALL_DIR)/lib.
lib_parent="$(dirname "$INSTALL_DIR")/lib"
target="$INSTALL_DIR/$BINARY"
notice_target="$LICENSE_DIR/zsign.txt"

install_tree() {
	mkdir -p "$INSTALL_DIR" "$lib_parent" "$LICENSE_DIR"
	install -m 0755 "$tmp/bin/xcross" "$target"
	# Place native assets at <prefix>/lib/ so bin/xcross finds ../lib/*.so
	rm -rf "$lib_parent/sysv_abi_bridge.so" "$lib_parent"/lib*.so 2>/dev/null || true
	cp -a "$tmp/lib/." "$lib_parent/"
	install -m 0644 "$tmp/$NOTICE" "$notice_target"
}

if mkdir -p "$INSTALL_DIR" "$lib_parent" "$LICENSE_DIR" 2>/dev/null &&
	[ -w "$INSTALL_DIR" ] && [ -w "$lib_parent" ] && [ -w "$LICENSE_DIR" ]; then
	install_tree
elif command -v sudo >/dev/null 2>&1; then
	info "Elevating with sudo to write $INSTALL_DIR and $lib_parent"
	sudo mkdir -p "$INSTALL_DIR" "$lib_parent" "$LICENSE_DIR"
	sudo install -m 0755 "$tmp/bin/xcross" "$target"
	sudo cp -a "$tmp/lib/." "$lib_parent/"
	sudo install -m 0644 "$tmp/$NOTICE" "$notice_target"
else
	err "cannot write install directories; set INSTALL_DIR and XCROSS_LICENSE_DIR"
fi

# --- verify ----------------------------------------------------------------
"$target" --help >/dev/null 2>&1 || err "installed xcross failed verification"
info "Installed and verified: $target (license: $notice_target)"

# --- put INSTALL_DIR on PATH persistently if it is not already -------------
path_has_dir() {
	case ":$PATH:" in
	*":$1:"*) return 0 ;;
	*) return 1 ;;
	esac
}

if ! path_has_dir "$INSTALL_DIR"; then
	case "${SHELL:-}" in
	*/zsh) profile="$HOME/.zshrc" ;;
	*/bash) profile="$HOME/.bashrc" ;;
	*) profile="$HOME/.profile" ;;
	esac
	path_line="export PATH=\"$INSTALL_DIR:\$PATH\""
	if [ -f "$profile" ] && grep -Fqx "$path_line" "$profile" 2>/dev/null; then
		info "$INSTALL_DIR already configured in $profile; restart your shell"
	else
		printf '\n# xcross\n%s\n' "$path_line" >>"$profile"
		info "Added $INSTALL_DIR to PATH via $profile (restart your shell)"
	fi
fi

# --- prerequisite hints ----------------------------------------------------
missing=""
command -v swift >/dev/null 2>&1 ||
	missing="$missing  Swift toolchain:  https://www.swift.org/install/\n"
command -v clang >/dev/null 2>&1 && command -v ld64.lld >/dev/null 2>&1 ||
	missing="$missing  LLVM (clang, ld64.lld):  https://releases.llvm.org/\n"
command -v flutter >/dev/null 2>&1 ||
	missing="$missing  Flutter:  https://flutter.dev/docs/get-started/install/linux\n"
command -v python3 >/dev/null 2>&1 ||
	missing="$missing  Python 3:  install via your package manager\n"
if [ -n "$missing" ]; then
	printf '\nMissing prerequisites:\n'
	printf '%b' "$missing"
fi

printf '\nNext steps:\n'
printf '  xcross setup                             # install apt deps & pymobiledevice3\n'
printf '  xcross sdk install ~/Downloads/Xcode.xip # once\n'
printf '  xcross auth --apple-id you@example.com\n'
printf '  xcross tunnel                            # needs root, per device reconnect\n'
printf '  xcross flutter run\n'
