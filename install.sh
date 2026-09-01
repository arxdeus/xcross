#!/usr/bin/env sh
#
# xcross installer for Linux
# ==========================
#
# WHAT THIS DOES
#   1. Works out which prebuilt release asset matches this machine.
#   2. Downloads that asset (plus the ADI license notice) from GitHub Releases,
#      or with --local builds the equivalent bundle from this checkout.
#   3. Stages it for installation, using sudo only if the target dirs need it.
#   4. Runs `xcross --help` to prove the install works.
#   5. Adds the install dir to your PATH and lists any missing prerequisites.
#
#   No Dart toolchain is required: the release ships an ahead-of-time compiled
#   binary together with the native libraries it dlopen()s at runtime.
#
# USAGE
#   curl -fsSL \
#     https://raw.githubusercontent.com/arxdeus/xcross/main/install.sh | sh
#
#   # Pin a version and/or install somewhere else:
#   XCROSS_VERSION=v1.2.3 INSTALL_DIR="$HOME/.local/bin" sh install.sh
#
#   # Build and install the current checkout instead of downloading a release:
#   ./install.sh --local
#
# OPTIONS
#   --local             Build xcross and its native libraries from this checkout.
#
# ENVIRONMENT VARIABLES
#   XCROSS_VERSION      Release tag to install, e.g. v1.2.3.  Default: latest
#   INSTALL_DIR         Directory the `xcross` binary lands in.
#                       Default: /usr/local/bin
#   XCROSS_LICENSE_DIR  Directory for third-party license notices.
#                       Default: <prefix>/share/licenses/xcross
#
# EXIT STATUS
#   0 on success, 1 with an `error: ...` line on stderr otherwise.

# -e: stop at the first failing command.  -u: treat unset variables as errors.
# (No `pipefail`: this script must stay POSIX sh, not bash.)
set -eu

local_install=false
for arg in "$@"; do
	case "$arg" in
	--local) local_install=true ;;
	-h | --help)
		printf 'Usage: %s [--local]\n' "$0"
		exit 0
		;;
	*)
		printf 'error: unknown option: %s\n' "$arg" >&2
		printf 'Usage: %s [--local]\n' "$0" >&2
		exit 1
		;;
	esac
done

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# GitHub repository that publishes the releases.
REPO="arxdeus/xcross"

# Name of the executable inside the release archive and after installation.
BINARY_NAME="xcross"

# Standalone release asset: the license notice for the bundled provision-dart
# code.  It is published next to the archives rather than inside them.
LICENSE_ASSET="ADI_LICENSE"

# Where the binary goes.  `/usr/local/bin` is the conventional location for
# software installed outside the distro package manager.
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

# The "prefix" is the parent of INSTALL_DIR: /usr/local/bin -> /usr/local.
# Everything else we install is placed relative to it, which is what keeps the
# runtime library lookup described in `Install layout` below working.
INSTALL_PREFIX="$(dirname "$INSTALL_DIR")"

# Native libraries (*.so) that the binary loads at runtime.
NATIVE_LIB_DIR="$INSTALL_PREFIX/lib"

# Third-party license notices.
LICENSE_DIR="${XCROSS_LICENSE_DIR:-$INSTALL_PREFIX/share/licenses/xcross}"

# Release to install: a tag such as `v1.2.3`, or `latest`.
VERSION="${XCROSS_VERSION:-latest}"

# ---------------------------------------------------------------------------
# Install layout
# ---------------------------------------------------------------------------
#
# `dart build cli` produces a bundle shaped like this:
#
#   bundle/
#     bin/xcross          the AOT-compiled executable
#     lib/*.so            native assets it dlopen()s at startup
#
# At runtime the binary resolves those libraries relative to itself, as
# `../lib/*.so`.  So the two directories must stay siblings under one prefix:
#
#   $INSTALL_PREFIX/bin/xcross   ->  looks for  ../lib/*.so
#   $INSTALL_PREFIX/lib/*.so     <-  found here
#
# With the default INSTALL_DIR=/usr/local/bin that means /usr/local/lib.
# If you override INSTALL_DIR, keep it named `bin` (e.g. ~/.local/bin) so the
# derived lib directory (~/.local/lib) is the sibling the binary expects.

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# Print a progress step.
info() { printf '==> %s\n' "$1"; }

# Print an error to stderr and abort the installation.
err() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Step 1 — check that this machine can run a prebuilt release
# ---------------------------------------------------------------------------

# Only Linux binaries are published.  macOS users build from source; Windows
# users run install.ps1 instead.
os_name="$(uname -s)"
[ "$os_name" = "Linux" ] ||
	err "prebuilt releases are Linux-only (got: $os_name); build from source"

# Map the CPU architecture reported by the kernel onto a release asset name.
# `uname -m` spells the same architecture differently across distros, hence the
# pairs below.
cpu_arch="$(uname -m)"
case "$cpu_arch" in
x86_64 | amd64) archive_name="xcross-linux-x64.tar.gz" ;;
aarch64 | arm64) archive_name="xcross-linux-arm64.tar.gz" ;;
*) err "unsupported architecture: $cpu_arch (supported: x86_64, aarch64)" ;;
esac
info "Detected: $os_name/$cpu_arch -> $archive_name"

# ---------------------------------------------------------------------------
# Step 2 — stage a release bundle in a scratch directory
# ---------------------------------------------------------------------------

# Everything is staged in a temp dir that is removed on any exit path, so a
# failed install never leaves half-downloaded files behind.
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM

if [ "$local_install" = true ]; then
	command -v dart >/dev/null 2>&1 || err "need Dart to build with --local"
	script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	package_dir="$script_dir/packages/xcross"
	license_source="$script_dir/packages/apple_developer_kit/$LICENSE_ASSET"
	[ -f "$package_dir/tool/build_xcross.dart" ] ||
		err "--local must be run from an xcross repository checkout"
	[ -f "$license_source" ] || err "local checkout missing $LICENSE_ASSET"

	info "Building xcross from $script_dir..."
	(cd "$script_dir" && dart pub get) || err "dart pub get failed"
	(cd "$package_dir" && dart run -DXCROSS_VERSION=unreleased \
		-DXCROSS_RELEASED=false tool/build_xcross.dart) || err "local build failed"

	bundle_bin=$(find "$package_dir/build/cli" -type f \
		-path '*/bundle/bin/xcross' -print 2>/dev/null | head -n 1)
	[ -n "$bundle_bin" ] || err "local build did not produce bin/xcross"
	bundle_dir=$(dirname "$(dirname "$bundle_bin")")
	mkdir -p "$staging_dir/bin" "$staging_dir/lib"
	cp -a "$bundle_dir/bin/." "$staging_dir/bin/"
	cp -a "$bundle_dir/lib/." "$staging_dir/lib/"
	cp "$license_source" "$staging_dir/$LICENSE_ASSET"
else
	# GitHub exposes the newest release under a stable `/latest/download/` path,
	# while pinned versions live under `/download/<tag>/`.
	if [ "$VERSION" = "latest" ]; then
		base_url="https://github.com/$REPO/releases/latest/download"
	else
		base_url="https://github.com/$REPO/releases/download/$VERSION"
	fi

	# Define `download <url> <output-file>` on top of whichever fetcher exists.
	if command -v curl >/dev/null 2>&1; then
		download() { curl -fsSL "$1" -o "$2"; }
	elif command -v wget >/dev/null 2>&1; then
		download() { wget -qO "$2" "$1"; }
	else
		err "need curl or wget to download"
	fi

	info "Downloading $VERSION $archive_name..."
	download "$base_url/$archive_name" "$staging_dir/$archive_name" ||
		err "download failed: $base_url/$archive_name"
	[ -s "$staging_dir/$archive_name" ] ||
		err "downloaded file is empty: $base_url/$archive_name"
	download "$base_url/$LICENSE_ASSET" "$staging_dir/$LICENSE_ASSET" ||
		err "download failed: $base_url/$LICENSE_ASSET"
	[ -s "$staging_dir/$LICENSE_ASSET" ] ||
		err "downloaded file is empty: $base_url/$LICENSE_ASSET"
	tar -C "$staging_dir" -xzf "$staging_dir/$archive_name" ||
		err "failed to extract $archive_name"
fi

# ---------------------------------------------------------------------------
# Step 3 — sanity-check the staged bundle
# ---------------------------------------------------------------------------

# Verify the bundle really has both halves before touching the system, so a
# malformed release cannot leave a binary installed without its libraries.
[ -x "$staging_dir/bin/$BINARY_NAME" ] || err "archive missing bin/$BINARY_NAME"
[ -x "$staging_dir/bin/xcrun" ] || err "archive missing bin/xcrun"
[ -d "$staging_dir/lib" ] || err "archive missing lib/"

# ---------------------------------------------------------------------------
# Step 4 — install
# ---------------------------------------------------------------------------

installed_binary="$INSTALL_DIR/$BINARY_NAME"
installed_license="$LICENSE_DIR/provision-dart.txt"

# Try to create the target directories as the current user.  If that works and
# all of them are writable we install directly; otherwise we retry every step
# through sudo.  `run_privileged` is the single switch between those two modes,
# so both paths execute exactly the same commands.
if mkdir -p "$INSTALL_DIR" "$NATIVE_LIB_DIR" "$LICENSE_DIR" 2>/dev/null &&
	[ -w "$INSTALL_DIR" ] && [ -w "$NATIVE_LIB_DIR" ] && [ -w "$LICENSE_DIR" ]; then
	run_privileged() { "$@"; }
elif command -v sudo >/dev/null 2>&1; then
	info "Elevating with sudo to write $INSTALL_DIR and $NATIVE_LIB_DIR"
	run_privileged() { sudo "$@"; }
else
	err "cannot write install directories; set INSTALL_DIR and XCROSS_LICENSE_DIR"
fi

run_privileged mkdir -p "$INSTALL_DIR" "$NATIVE_LIB_DIR" "$LICENSE_DIR"

# 0755: everyone may read and execute, only the owner may write.
run_privileged install -m 0755 "$staging_dir/bin/$BINARY_NAME" "$installed_binary"
run_privileged install -m 0755 "$staging_dir/bin/xcrun" "$INSTALL_DIR/xcrun"

# Copy the native libraries next to the prefix, preserving permissions and
# symlinks (`cp -a`).  Existing files with the same name are overwritten, which
# is what makes re-running the installer an in-place upgrade.
run_privileged cp -a "$staging_dir/lib/." "$NATIVE_LIB_DIR/"

# 0644: world-readable, non-executable — the right mode for a text notice.
run_privileged install -m 0644 "$staging_dir/$LICENSE_ASSET" "$installed_license"

# ---------------------------------------------------------------------------
# Step 5 — verify the installed binary actually runs
# ---------------------------------------------------------------------------

# `--help` exercises startup, which includes loading the native libraries.
# If the lib/ layout were wrong, this is where it would surface.
"$installed_binary" --help >/dev/null 2>&1 ||
	err "installed xcross failed verification"
info "Installed and verified: $installed_binary (license: $installed_license)"

# ---------------------------------------------------------------------------
# Step 6 — make sure INSTALL_DIR is on PATH
# ---------------------------------------------------------------------------

# True when $1 appears as a complete entry in PATH.  Wrapping both sides in
# colons makes the match exact, so `/usr/local/bin` does not match a PATH that
# only contains `/usr/local/bin.d`.
path_contains() {
	case ":$PATH:" in
	*":$1:"*) return 0 ;;
	*) return 1 ;;
	esac
}

if ! path_contains "$INSTALL_DIR"; then
	# Append to the startup file of the user's login shell, falling back to
	# the POSIX-standard ~/.profile for anything we do not recognise.
	case "${SHELL:-}" in
	*/zsh) shell_profile="$HOME/.zshrc" ;;
	*/bash) shell_profile="$HOME/.bashrc" ;;
	*) shell_profile="$HOME/.profile" ;;
	esac

	path_export="export PATH=\"$INSTALL_DIR:\$PATH\""

	# Only append if that exact line is not already there, so repeated installs
	# do not pile up duplicate entries.
	if [ -f "$shell_profile" ] &&
		grep -Fqx "$path_export" "$shell_profile" 2>/dev/null; then
		info "$INSTALL_DIR already configured in $shell_profile; restart your shell"
	else
		printf '\n# xcross\n%s\n' "$path_export" >>"$shell_profile"
		info "Added $INSTALL_DIR to PATH via $shell_profile (restart your shell)"
	fi
fi

# ---------------------------------------------------------------------------
# Step 8 — report missing prerequisites
# ---------------------------------------------------------------------------
#
# xcross drives external toolchains; it cannot install them for you.  These are
# hints only — a missing tool is not an installation failure, because you may
# only need the subset relevant to your workflow.

missing_tools=""

# Compiles Swift sources when building iOS/macOS targets.
command -v swift >/dev/null 2>&1 ||
	missing_tools="$missing_tools  Swift toolchain:  https://www.swift.org/install/\n"

# clang compiles the C/ObjC side; ld64.lld is the Mach-O linker used to produce
# Apple-format binaries on Linux.  Both come from LLVM, so they are reported as
# one item.
command -v clang >/dev/null 2>&1 && command -v ld64.lld >/dev/null 2>&1 ||
	missing_tools="$missing_tools  LLVM (clang, ld64.lld):  https://releases.llvm.org/\n"

# Needed for `xcross flutter ...`.
command -v flutter >/dev/null 2>&1 ||
	missing_tools="$missing_tools  Flutter:  https://flutter.dev/docs/get-started/install/linux\n"

# Hosts pymobiledevice3, which talks to physical iOS devices.
command -v python3 >/dev/null 2>&1 ||
	missing_tools="$missing_tools  Python 3:  install via your package manager\n"

if [ -n "$missing_tools" ]; then
	printf '\nMissing prerequisites:\n'
	# `%b` so the \n escapes accumulated above are expanded.
	printf '%b' "$missing_tools"
fi

# ---------------------------------------------------------------------------
# Done — tell the user what to run next
# ---------------------------------------------------------------------------

printf '\nNext steps:\n'
printf '  xcross setup                             # install distro deps, pipx & pymobiledevice3\n'
printf '  xcross sdk install ~/Downloads/Xcode.xip # once\n'
printf '  xcross auth --apple-id you@example.com\n'
printf '  xcross tunnel                            # needs root, per device reconnect\n'
printf '  xcross flutter run\n'
