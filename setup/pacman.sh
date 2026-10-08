#!/usr/bin/env sh
# xcross host setup for Arch Linux and derivatives (pacman).
#
# Usage: sh pacman.sh [-y|--yes]
#
# Run it as your normal user: system packages go through sudo, while Swift
# (swiftly) and pymobiledevice3 (pipx) install into your home directory.
# Every third-party script or binary is announced with its name and URL and
# needs a "y" before it runs. -y (or XCROSS_SETUP_ASSUME_YES=1, which
# `xcross setup --yes` sets) accepts those prompts up front.
set -eu

assume_yes="${XCROSS_SETUP_ASSUME_YES:-0}"
for arg in "$@"; do
	case "$arg" in
	-y | --yes) assume_yes=1 ;;
	-h | --help)
		printf 'Usage: sh pacman.sh [-y|--yes]\n  -y, --yes  run third-party installers (swiftly) without asking\n'
		exit 0
		;;
	*)
		printf 'error: unknown argument: %s\n' "$arg" >&2
		exit 2
		;;
	esac
done

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# confirm <name> <url> <what it does>: ask before running remote code.
confirm() {
	printf '\nxcross setup wants to download and run %s\n' "$1"
	printf '  from: %s\n' "$2"
	printf '  what: %s\n' "$3"
	if [ "$assume_yes" = 1 ]; then
		printf 'Proceeding (--yes).\n'
		return 0
	fi
	# stdin is the script itself under `curl ... | sh`, so ask the terminal.
	# Probe in a subshell: a failed redirection on a builtin exits dash.
	if ! (exec </dev/tty) 2>/dev/null; then
		warn "no terminal to confirm $1; skipping it (re-run with --yes to accept)"
		return 1
	fi
	printf 'Run %s? [y/N] ' "$1" >/dev/tty
	read -r answer </dev/tty || answer=""
	case "$answer" in
	y | Y | yes | YES | Yes) return 0 ;;
	*)
		printf 'Skipped %s.\n' "$1"
		return 1
		;;
	esac
}

if [ "$(id -u)" -eq 0 ]; then
	if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != root ]; then
		die "run this script as $SUDO_USER, not through sudo; it calls sudo itself and installs Swift and pymobiledevice3 into your home directory"
	fi
	SUDO=""
elif command -v sudo >/dev/null 2>&1; then
	SUDO="sudo"
else
	die 'pacman setup requires root or sudo'
fi
command -v pacman >/dev/null 2>&1 || die 'pacman not found; use the setup script for your package manager'

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 130' HUP INT TERM

# xcross needs clang/lld/llvm, usbmuxd and libimobiledevice for devices, and
# python + pipx for pymobiledevice3. The rest are the Swift toolchain's own
# runtime and build dependencies (Arch ships headers in the main packages).
wanted="
clang lld llvm
python python-pip python-pipx
usbmuxd usbutils libimobiledevice usbip
binutils git gnupg pkgconf unzip curl
gcc glibc libedit ncurses sqlite libxml2 z3 zlib
"

# pacman refuses the whole transaction over one unknown target, so drop the
# names this host's sync databases do not know (derivatives differ).
# Word splitting is intentional in this section: each name is one argument.
# shellcheck disable=SC2086
missing="$(pacman -Si $wanted 2>&1 >/dev/null | sed -n "s/.*package '\([^']*\)' was not found.*/\1/p")"
packages=""
skipped=""
for name in $wanted; do
	if printf '%s\n' "$missing" | grep -Fqx "$name"; then
		skipped="$skipped $name"
	else
		packages="$packages $name"
	fi
done
[ -z "$skipped" ] || info "Not in the sync databases, skipped:$skipped"

info 'Installing pacman packages'
# Word splitting is intentional: each name is one argument.
# shellcheck disable=SC2086
if ! $SUDO pacman -S --needed --noconfirm $packages; then
	# A stale sync database is the usual cause. Arch does not support partial
	# upgrades (-Sy alone), so refresh and upgrade together.
	warn 'pacman -S failed; retrying with a full system upgrade (pacman -Syu)'
	$SUDO pacman -Syu --needed --noconfirm $packages
fi
hash -r 2>/dev/null || true

# Xcode 26 libc++ headers need Clang 20 builtins (notably __builtin_clzg).
min_clang=20
# LLVM 18 and older ld64.lld miswire `_objc_msgSend$<selector>` stubs, which
# breaks Objective-C plugins at runtime.
min_lld=19

# ---------------------------------------------------------------------------
# Swift (swiftly)
# ---------------------------------------------------------------------------

min_swift=6.4
swift_version() {
	swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1
}
# version_ge <a.b> <c.d>
version_ge() {
	a_major="${1%%.*}" a_minor="${1#*.}" b_major="${2%%.*}" b_minor="${2#*.}"
	[ "$a_major" -gt "$b_major" ] || { [ "$a_major" -eq "$b_major" ] && [ "$a_minor" -ge "$b_minor" ]; }
}

load_swiftly_env() {
	env_sh="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
	[ -f "$env_sh" ] || return 0
	set +u
	# shellcheck disable=SC1090
	. "$env_sh"
	set -u
	hash -r 2>/dev/null || true
}

load_swiftly_env
if ! command -v swift >/dev/null 2>&1; then
	arch="$(uname -m)"
	swiftly_url="https://download.swift.org/swiftly/linux/swiftly-$arch.tar.gz"
	# swift.org publishes no Arch toolchain; swiftly has to be told which
	# supported platform's build to use. The Ubuntu 24.04 build runs on a
	# current Arch userland.
	if confirm "swiftly ($arch)" "$swiftly_url" "installs the swiftly toolchain manager and the latest Swift release (Ubuntu 24.04 build) into your home directory"; then
		curl -fsSL "$swiftly_url" -o "$work_dir/swiftly.tar.gz"
		curl -fsSL "$swiftly_url.sig" -o "$work_dir/swiftly.tar.gz.sig"
		# Verify against the Swift project's published signing keys.
		GNUPGHOME="$work_dir/gnupg"
		export GNUPGHOME
		mkdir -m 700 "$GNUPGHOME"
		# swift.org serves this file gzip-encoded regardless of Accept-Encoding.
		curl -fsSL --compressed https://www.swift.org/keys/all-keys.asc | gpg --batch --quiet --import
		gpg --batch --verify "$work_dir/swiftly.tar.gz.sig" "$work_dir/swiftly.tar.gz" ||
			die "swiftly signature verification failed"
		unset GNUPGHOME
		tar -xzf "$work_dir/swiftly.tar.gz" -C "$work_dir"
		"$work_dir/swiftly" init --assume-yes --quiet-shell-followup --platform ubuntu24.04
		load_swiftly_env
	fi
fi

# ---------------------------------------------------------------------------
# pymobiledevice3 (pipx)
# ---------------------------------------------------------------------------

info 'Installing pymobiledevice3 with pipx'
pipx install pymobiledevice3
pipx upgrade pymobiledevice3 || warn 'could not upgrade pymobiledevice3'
pipx ensurepath || warn 'pipx ensurepath failed; add ~/.local/bin to PATH'
PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

problems=""
clang_major="$(clang --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9]*\).*/\1/p')"
if [ -z "$clang_major" ] || [ "$clang_major" -lt "$min_clang" ]; then
	problems="$problems
  - clang on PATH is ${clang_major:-missing}; Clang $min_clang+ is required for Xcode 26 SDK headers (sudo pacman -Syu)"
fi
lld_path="$(command -v ld64.lld 2>/dev/null || true)"
lld_major="$([ -z "$lld_path" ] || "$lld_path" --version 2>&1 | sed -n 's/.*LLD \([0-9][0-9]*\)\..*/\1/p' | head -n 1)"
if [ -z "$lld_path" ]; then
	problems="$problems
  - no ld64.lld on PATH; the lld package must provide it"
elif [ -n "$lld_major" ] && [ "$lld_major" -lt "$min_lld" ]; then
	problems="$problems
  - $lld_path is LLD $lld_major; $min_lld or newer is required for Objective-C plugins"
fi
command -v llvm-ar >/dev/null 2>&1 || problems="$problems
  - llvm-ar is not on PATH"
swift_found="$(swift_version)"
if [ -z "$swift_found" ]; then
	problems="$problems
  - swift is not installed; see https://www.swift.org/install/linux/"
elif ! version_ge "$swift_found" "$min_swift"; then
	problems="$problems
  - Swift $swift_found is older than $min_swift; run: swiftly install latest"
fi
command -v pymobiledevice3 >/dev/null 2>&1 || problems="$problems
  - pymobiledevice3 is not on PATH"

if [ -n "$problems" ]; then
	printf '\nSetup finished with problems:%s\n' "$problems" >&2
	exit 1
fi
info 'xcross requirements installed. Open a new shell so PATH changes from swiftly and pipx take effect.'
