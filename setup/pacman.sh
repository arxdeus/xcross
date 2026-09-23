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

# Xcode 26 libc++ uses __builtin_clzg, first supported by Clang 20.
clang_major=$(clang --version | sed -n '1s/.*version \([0-9][0-9]*\).*/\1/p')
if [ -z "$clang_major" ] || [ "$clang_major" -lt 20 ]; then
	printf 'error: Clang 20+ is required for Xcode 26 SDK headers (found: %s). Run pacman -Syu and retry.\n' "${clang_major:-unknown}" >&2
	exit 1
fi

# Up to and including LLVM 18, ld64.lld miswires `_objc_msgSend$<selector>`
# stubs, which silently breaks Objective-C plugins at runtime, so make sure
# the ld64.lld this install leaves behind is new enough.
min_lld=19
lld_major() {
	"$1" --version 2>&1 | sed -n 's/.*\bLLD \([0-9][0-9]*\)\..*/\1/p' | head -n 1
}

found_lld="$(command -v ld64.lld 2>/dev/null || true)"
if [ -n "$found_lld" ]; then
	found_major="$(lld_major "$found_lld")"
	if [ -n "$found_major" ] && [ "$found_major" -lt "$min_lld" ]; then
		printf 'warning: %s is LLD %s; xcross needs %s or newer for Objective-C plugins.\n' \
			"$found_lld" "$found_major" "$min_lld" >&2
		printf 'warning: install a newer lld and put its ld64.lld ahead on PATH.\n' >&2
	fi
else
	printf 'warning: no ld64.lld on PATH after install; xcross cannot link for iOS.\n' >&2
fi

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
