#!/usr/bin/env sh
set -eu

if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
elif command -v sudo >/dev/null 2>&1; then
	SUDO="sudo"
else
	printf '%s\n' 'error: pacman setup requires root or sudo' >&2
	exit 1
fi

packages="
clang lld llvm
python python-pip python-pipx
usbmuxd usbutils libimobiledevice usbip
pkgconf zlib libxml2 ncurses z3 gnupg glibc curl gcc
"

# Package expansion is intentional: each whitespace-delimited name is an argument.
# shellcheck disable=SC2086
$SUDO pacman -S --needed --noconfirm $packages

if ! command -v swift >/dev/null 2>&1; then
	swiftly_dir="$(mktemp -d)"
	trap 'rm -rf "$swiftly_dir"' EXIT HUP INT TERM
	curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" \
		-o "$swiftly_dir/swiftly.tar.gz"
	tar -xzf "$swiftly_dir/swiftly.tar.gz" -C "$swiftly_dir"
	"$swiftly_dir/swiftly" init --quiet-shell-followup
	. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
	hash -r
fi

pipx install --force pymobiledevice3
pipx ensurepath
