#!/usr/bin/env sh
# xcross host setup for Debian and Ubuntu (apt).
#
# Usage: sh apt.sh [-y|--yes]
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
		printf 'Usage: sh apt.sh [-y|--yes]\n  -y, --yes  run third-party installers (llvm.sh, swiftly) without asking\n'
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
	die 'apt setup requires root or sudo'
fi
command -v apt-get >/dev/null 2>&1 || die 'apt-get not found; use the setup script for your package manager'

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 130' HUP INT TERM

# Never let a debconf dialog (tzdata, ...) stall an unattended install.
apt_install() {
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# xcross needs clang/lld/llvm, usbmuxd and libimobiledevice for devices, and
# python3 + pipx for pymobiledevice3. The rest are the Swift toolchain's own
# runtime and build dependencies. Names differ between releases (Debian ships
# usbip standalone, Ubuntu inside linux-tools-common; trixie dropped
# software-properties-common), so names this archive does not know are
# dropped instead of failing the whole transaction.
wanted="
clang lld llvm
python3 python3-pip python3-venv pipx
usbmuxd usbutils libimobiledevice-utils usbip linux-tools-common
binutils git gnupg2 pkg-config tzdata unzip curl ca-certificates
gcc g++ libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev
libpython3-dev libsqlite3-0 libxml2-dev libz3-dev zlib1g-dev
lsb-release wget software-properties-common
"

info 'Refreshing the apt package index'
$SUDO apt-get update

known="$(apt-cache pkgnames 2>/dev/null | sort -u)"
packages=""
skipped=""
for name in $wanted; do
	if [ -z "$known" ] || printf '%s\n' "$known" | grep -Fqx "$name"; then
		packages="$packages $name"
	else
		skipped="$skipped $name"
	fi
done
[ -z "$skipped" ] || info "Not in this archive, skipped:$skipped"

info 'Installing apt packages'
# Word splitting is intentional: each name is one argument.
# shellcheck disable=SC2086
apt_install $packages

# Xcode 26 libc++ headers need Clang 20 builtins (notably __builtin_clzg).
min_clang=20
# LLVM 18 and older ld64.lld miswire `_objc_msgSend$<selector>` stubs, which
# breaks Objective-C plugins at runtime.
min_lld=19

# newest_versioned <prefix>: highest N with an executable /usr/bin/<prefix>N.
newest_versioned() {
	best=0
	for bin in /usr/bin/"$1"[0-9]*; do
		[ -x "$bin" ] || continue
		version="${bin##*/"$1"}"
		case "$version" in '' | *[!0-9]*) continue ;; esac
		[ "$version" -gt "$best" ] && best="$version"
	done
	printf '%s\n' "$best"
}

# install_newest_from_archive <package-prefix> <minimum>
install_newest_from_archive() {
	candidate="$(apt-cache pkgnames "$1" 2>/dev/null |
		sed -n "s/^$1\([0-9][0-9]*\)\$/\1/p" | sort -rn | head -n 1)"
	if [ -n "$candidate" ] && [ "$candidate" -ge "$2" ]; then
		info "Installing $1$candidate from this archive"
		apt_install "$1$candidate" || warn "could not install $1$candidate"
	fi
}

if [ "$(newest_versioned clang-)" -lt "$min_clang" ] || [ "$(newest_versioned ld64.lld-)" -lt "$min_lld" ]; then
	# Prefer this distro's own archive (Ubuntu 24.04 carries lld-19 and
	# clang-20 in noble-updates) before adding a third-party repository.
	[ "$(newest_versioned clang-)" -ge "$min_clang" ] || install_newest_from_archive clang- "$min_clang"
	[ "$(newest_versioned ld64.lld-)" -ge "$min_lld" ] || install_newest_from_archive lld- "$min_lld"
fi

if [ "$(newest_versioned clang-)" -lt "$min_clang" ] || [ "$(newest_versioned ld64.lld-)" -lt "$min_lld" ]; then
	llvm_url=https://apt.llvm.org/llvm.sh
	if confirm llvm.sh "$llvm_url" "adds the apt.llvm.org repository and installs the current stable clang, lld and lldb (as root)"; then
		if curl -fsSL "$llvm_url" -o "$work_dir/llvm.sh"; then
			# bash, not ./llvm.sh: the script is bash-only and /tmp may be noexec.
			$SUDO env DEBIAN_FRONTEND=noninteractive bash "$work_dir/llvm.sh" ||
				warn "llvm.sh failed; see its output above"
		else
			warn "could not download $llvm_url"
		fi
	fi
fi

best_clang="$(newest_versioned clang-)"
best_lld="$(newest_versioned ld64.lld-)"

# Point a stable name at a versioned binary, unless something xcross did not
# create already owns that path.
# link_managed <stable path> <target> <pattern a managed link points at>
link_managed() {
	if [ ! -e "$1" ] && [ ! -L "$1" ]; then
		:
	elif [ -L "$1" ]; then
		# $3 is a glob on purpose.
		# shellcheck disable=SC2254
		case "$(readlink "$1")" in
		$3) ;;
		*)
			warn "$1 is not managed by xcross; leaving it alone (wanted $2)"
			return 0
			;;
		esac
	else
		warn "$1 is not managed by xcross; leaving it alone (wanted $2)"
		return 0
	fi
	[ "$(readlink "$1" 2>/dev/null || true)" = "$2" ] && return 0
	$SUDO ln -sfn "$2" "$1"
	info "$1 -> $2"
}

$SUDO mkdir -p /usr/local/bin
if [ "$best_clang" -ge "$min_clang" ]; then
	for tool in clang clang++ llvm-ar; do
		[ -x "/usr/bin/$tool-$best_clang" ] || continue
		link_managed "/usr/local/bin/$tool" "/usr/bin/$tool-$best_clang" "/usr/bin/$tool-[0-9]*"
	done
fi
if [ "$best_lld" -ge "$min_lld" ]; then
	link_managed /usr/local/bin/ld64.lld "/usr/bin/ld64.lld-$best_lld" '*/ld64.lld-[0-9]*'
	# The ELF driver (`clang -fuse-ld=lld`) needs an unversioned entry point too.
	if [ -x "/usr/bin/ld.lld-$best_lld" ] && command -v update-alternatives >/dev/null 2>&1; then
		$SUDO update-alternatives --install /usr/bin/ld.lld ld.lld \
			"/usr/bin/ld.lld-$best_lld" "$best_lld" >/dev/null ||
			warn "could not register /usr/bin/ld.lld-$best_lld with update-alternatives"
	fi
fi
hash -r 2>/dev/null || true

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
	if confirm "swiftly ($arch)" "$swiftly_url" "installs the swiftly toolchain manager and the latest Swift release into your home directory"; then
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
		"$work_dir/swiftly" init --assume-yes --quiet-shell-followup
		load_swiftly_env
	fi
fi

# ---------------------------------------------------------------------------
# pymobiledevice3 (pipx)
# ---------------------------------------------------------------------------

if command -v pipx >/dev/null 2>&1; then
	pipx_cmd=pipx
else
	# Releases without a pipx package (Ubuntu 20.04, Debian 11).
	info 'Installing pipx with pip'
	python3 -m pip install --user pipx 2>/dev/null ||
		python3 -m pip install --user --break-system-packages pipx
	pipx_cmd="python3 -m pipx"
fi
info 'Installing pymobiledevice3 with pipx'
$pipx_cmd install pymobiledevice3
$pipx_cmd upgrade pymobiledevice3 || warn 'could not upgrade pymobiledevice3'
$pipx_cmd ensurepath || warn 'pipx ensurepath failed; add ~/.local/bin to PATH'
PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

problems=""
clang_major="$(clang --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9]*\).*/\1/p')"
if [ -z "$clang_major" ] || [ "$clang_major" -lt "$min_clang" ]; then
	problems="$problems
  - clang on PATH is ${clang_major:-missing}; Clang $min_clang+ is required for Xcode 26 SDK headers (newest installed: /usr/bin/clang-$best_clang)"
fi
if [ "$best_lld" -lt "$min_lld" ]; then
	problems="$problems
  - no ld64.lld $min_lld+ found; install lld-$min_lld or newer (https://apt.llvm.org)"
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
